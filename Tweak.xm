// ============================================================
// PageTurner v1.0.0 —— 翻页器按键拦截（学习模式 + 映射 + 动作执行）
//
// 架构：
//   注入所有 App（roothide 黑名单默认）→ 运行时检查 bundleID + 总开关 → 旁路
//   事件来源判定：_UIUpdateHIDDigitizerInput -addEvent: 看 sender（翻页器=0x1000008ef，v1.0.7 实测）
//   特征提取：UIApplication -sendEvent:（UIEvent 层，UITouch 真实坐标）
//   会话：down→move→up 构建轨迹 → 特征{相位 tap/swipe, 方向角, 位移量}
//   学习模式：样本收集 → 下限5次 + 方向一致 + 位移收敛 → 上限15次；录制去重
//   运行模式：方向±15° + 位移区间 → 唯一方案 → 吞事件 → 防抖 → 顺序执行动作
//   执行中再按 = 中断当前序列（token 递增）
//   防递归：gIsInjecting 注入标志
//   三指同时按 0.4s → PTOverlay 调出面板
//   动作：PTFakeMetaTouch（点击/双击/滑动）+ AVSystemController（静音/音量±）
//
// 日志：App 容器 Documents/PageTurner.log + /var/mobile/Documents/PageTurner.log
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <float.h>
#include <dlfcn.h>
#include <sys/time.h>
#include <unistd.h>
#import "ptftouch/PTFakeMetaTouch.h"
#import "OverlayUI.h"

// ============================================================
// 常量
// ============================================================
static NSString *kPrefPath = @"/var/mobile/Library/Preferences/com.yourname.pageturner.plist";
static uint64_t kPagerSender = 0x1000008efull;   // v1.0.7 实测：翻页器 digitizer sender
static const double kPagerWindowSec = 0.05;      // HID 事件 → UIEvent 分发窗口
static const double kTapDistThreshold = 30.0;    // 位移 <30pt 判定 tap
static const double kDirTolerance = 15.0;        // 方向容差 ±15°
static const double kDistSlack = 30.0;           // 位移区间匹配裕度
static const int kLearnMin = 5;                  // 下限 5 次
static const int kLearnMax = 15;                 // 上限 15 次兜底
static const double kLearnConverge = 60.0;       // 位移收敛阈值（max-min）

// ============================================================
// 日志
// ============================================================
static const char *gLogPath = NULL;
static void PTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec; struct tm tmv; localtime_r(&sec, &tmv);
    char tbuf[64]; strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@\n", tbuf, (int)(tv.tv_usec/1000), msg];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (gLogPath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:[NSString stringWithUTF8String:gLogPath]];
        if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; } @catch (NSException *e) {} }
    }
    NSFileHandle *fh2 = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Documents/PageTurner.log"];
    if (fh2) { @try { [fh2 seekToEndOfFile]; [fh2 writeData:d]; [fh2 closeFile]; } @catch (NSException *e) {} }
}

static double PTNow(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// ============================================================
// 配置（plist：masterEnabled / enabledApps[] / debounceMs / plans[]）
// ============================================================
static NSString *gBundleID = nil;
static NSDictionary *gConfig = nil;
static double gConfigMtime = 0;
static BOOL gMasterEnabled = NO;
static NSMutableSet *gEnabledApps = nil;
static double gDebounceMs = 300;
static NSMutableDictionary *gPlans = nil;   // name -> dict（缓存，配置变化重读）

static void PTLoadConfig(BOOL force) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kPrefPath error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (!force && gConfig && mtime == gConfigMtime) return;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    gConfig = cfg ? cfg : @{};
    gConfigMtime = mtime;
    gMasterEnabled = [gConfig[@"masterEnabled"] boolValue];
    NSArray *apps = gConfig[@"enabledApps"];
    gEnabledApps = [NSMutableSet setWithArray:apps ? apps : @[]];
    double db = [gConfig[@"debounceMs"] doubleValue];
    gDebounceMs = (db > 0) ? db : 300;
    gPlans = [NSMutableDictionary dictionary];
    for (NSDictionary *p in gConfig[@"plans"] ?: @[]) {
        if (p[@"name"]) gPlans[p[@"name"]] = p;
    }
}

// 保存配置（UI 在 App 进程内调用，写后立即刷新）
void PTSaveConfig(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *tmp = [kPrefPath stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:kPrefPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kPrefPath error:nil];
    PTLoadConfig(YES);
    [PTOverlay refreshPlans];
}

// 当前配置整体读回（供 UI 编辑）
NSDictionary *PTGetConfig(void) { PTLoadConfig(NO); return gConfig; }

// ============================================================
// IOKit（sender 判定）
// ============================================================
typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
static IOHIDEventGetType_t pGetType = NULL;
static IOHIDEventGetSenderID_t pGetSender = NULL;

// 翻页器活跃窗口：最近一个翻页器 HID 事件后的这段时间内，UIEvent 视为翻页器
static double gPagerWindowUntil = 0;

// ============================================================
// 触摸会话 + 特征
// ============================================================
typedef struct {
    BOOL active;
    int nEvents;
    CGPoint start, last;
    double totalDist;
    double firstMoveDir;     // 第一个 move 的方向角（度）
    BOOL hasMove;
} PagerSession;
static PagerSession gSession;

typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction; // 度（swipe 才有意义）
    double dist;      // pt
} PagerFeature;

// ============================================================
// 学习状态
// ============================================================
static BOOL gLearning = NO;
static NSMutableArray *gLearnSamples = nil;   // 每项 @[@(phase), @(dir), @(dist)]
static BOOL gLearnRejected = NO;

static void PTLearnReset(void) {
    gLearnSamples = [NSMutableArray array];
    gLearnRejected = NO;
}

// 学习模式开关（由 Overlay UI 调）
void PTSetLearning(BOOL on) {
    gLearning = on;
    if (on) PTLearnReset();
}

// 录制去重：新样本与已有方案比对 → 高度相似返回已有方案名
static NSString *PTDuplicatePlan(int phase, double dir, double dist) {
    for (NSString *name in gPlans) {
        NSDictionary *ft = gPlans[name][@"feature"];
        if (!ft) continue;
        if ([ft[@"phase"] intValue] != phase) continue;
        double pd = [ft[@"direction"] doubleValue];
        double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
        if (d > kDirTolerance) continue;
        double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
        if (phase == 1 && (dist < lo - kDistSlack || dist > hi + kDistSlack)) continue;
        return name;   // 方向一致 + 位移接近 → 重复
    }
    return nil;
}

// 稳定判定：最近连续 kLearnMin 个样本方向一致 + 位移收敛
static BOOL PTLearnStable(void) {
    if ((int)gLearnSamples.count < kLearnMin) return NO;
    NSInteger n = gLearnSamples.count;
    double dir = [gLearnSamples[n-1][1] doubleValue];
    for (NSInteger i = n - kLearnMin; i < n; i++) {
        double d = [gLearnSamples[i][1] doubleValue];
        double diff = fabs(fabs(dir - d)); if (diff > 180) diff = 360 - diff;
        if (diff > kDirTolerance) return NO;
    }
    if ([gLearnSamples[n-1][0] intValue] == 1) {   // swipe 才比位移收敛
        double lo = DBL_MAX, hi = 0;
        for (NSInteger i = n - kLearnMin; i < n; i++) {
            double v = [gLearnSamples[i][2] doubleValue];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (hi - lo > kLearnConverge) return NO;
    }
    return YES;
}

// 学习样本入库（引擎每次 up 调用）
static void PTLearnSample(PagerFeature f) {
    if (!gLearning) return;
    // 去重（新方案且首个样本即可判定方向）
    if (!gLearnRejected) {
        NSString *dup = PTDuplicatePlan(f.phase, f.direction, f.dist);
        if (dup) {
            gLearnRejected = YES;
            PTLog(@"[学习] 拒绝：与已有方案 %@ 高度相似（方向/位移接近），可能按错了键", dup);
            [PTOverlay learnFeedback:(int)gLearnSamples.count dir:f.direction stable:NO rejected:dup];
            return;
        }
    }
    [gLearnSamples addObject:@[@(f.phase), @(f.direction), @(f.dist)]];
    int count = (int)gLearnSamples.count;
    BOOL stable = PTLearnStable();
    PTLog(@"[学习] 样本#%d phase=%d dir=%.1f dist=%.1f stable=%d", count, f.phase, f.direction, f.dist, stable);
    if (count >= kLearnMax) {
        [PTOverlay learnFeedback:count dir:f.direction stable:NO rejected:nil];
        [PTOverlay learnTooMany];   // 上限：提示重录
        return;
    }
    if (stable) {
        [PTOverlay learnFeedback:count dir:f.direction stable:YES rejected:nil];
        [PTOverlay learnStable];    // 触发命名/保存流程
    } else {
        [PTOverlay learnFeedback:count dir:f.direction stable:NO rejected:nil];
    }
}

// 学习完成：生成特征区间（由 UI 在命名后调用；同名则更新 feature 保留 actions）
void PTFinishLearning(NSString *planName) {
    if (!gLearnSamples.count) return;
    NSInteger n = gLearnSamples.count;
    double dir = [gLearnSamples[n-1][1] doubleValue];
    int phase = [gLearnSamples[n-1][0] intValue];
    double lo = DBL_MAX, hi = 0;
    for (NSArray *s in gLearnSamples) {
        double v = [s[2] doubleValue];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    NSMutableDictionary *ft = [NSMutableDictionary dictionary];
    ft[@"phase"] = @(phase);
    ft[@"direction"] = @(dir);
    ft[@"distMin"] = @(lo);
    ft[@"distMax"] = @(hi);
    ft[@"recordCount"] = @(n);
    // 写入配置（同名更新 / 否则新增）
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:PTGetConfig()];
    NSMutableArray *plans = [NSMutableArray array];
    BOOL updated = NO;
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"feature"] = ft;
            [plans addObject:np];
            updated = YES;
        } else [plans addObject:p];
    }
    if (!updated) [plans addObject:@{@"name": planName, @"feature": ft, @"actions": @[]}];
    cfg[@"plans"] = plans;
    PTSaveConfig(cfg);
    PTLog(@"[学习] 方案 %@ 已保存 feature=%@", planName, ft);
    gLearning = NO;
}

// 清空重录（UI 调用）
void PTClearLearning(void) { PTLearnReset(); }

// ============================================================
// 匹配
// ============================================================
static NSString *PTMatchPlan(PagerFeature f) {
    NSString *best = nil;
    double bestScore = DBL_MAX;
    for (NSString *name in gPlans) {
        NSDictionary *ft = gPlans[name][@"feature"];
        if (!ft) continue;
        if ([ft[@"phase"] intValue] != f.phase) continue;
        double pd = [ft[@"direction"] doubleValue];
        double d = fabs(fabs(f.direction - pd)); if (d > 180) d = 360 - d;
        if (d > kDirTolerance) continue;
        double lo = 0, hi = 0;
        if (f.phase == 1) {
            lo = [ft[@"distMin"] doubleValue];
            hi = [ft[@"distMax"] doubleValue];
            if (f.dist < lo - kDistSlack || f.dist > hi + kDistSlack) continue;
        }
        double score = d + (f.phase == 1 ? fabs(f.dist - (lo + hi) / 2.0) / 100.0 : 0);
        if (score < bestScore) { bestScore = score; best = name; }
    }
    return best;
}

// ============================================================
// 动作执行（PTFakeMetaTouch + AVSystemController）
// ============================================================
static BOOL gIsInjecting = NO;
static int gExecToken = 0;
static double gLastExec = 0;
static float gMutedVolume = -1;   // 静音前音量（-1=未静音）

static float PTGetVolume(void) {
    @try {
        id c = [NSClassFromString(@"AVSystemController") performSelector:NSSelectorFromString(@"sharedAVSystemController")];
        id v = [c performSelector:NSSelectorFromString(@"getVolumeForCategory:") withObject:@"AVAudioSessionCategoryAmbient"];
        return v ? [v floatValue] : 0.5f;
    } @catch (NSException *e) { return 0.5f; }
}

static void PTSetVolume(float v) {
    @try {
        id c = [NSClassFromString(@"AVSystemController") performSelector:NSSelectorFromString(@"sharedAVSystemController")];
        // iOS16 双路径：先 forCategory 再单参数
        [c performSelector:NSSelectorFromString(@"setVolumeTo:forCategory:") withObject:@(v) withObject:@"AVAudioSessionCategoryAmbient"];
        [c performSelector:NSSelectorFromString(@"setVolumeTo:") withObject:@(v)];
    } @catch (NSException *e) {}
}

// 点击（同步短阻塞，DVT 验证过的方案）
static void PTFakeTap(CGPoint p) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    usleep(30000);
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
}

// 滑动（异步分步，不阻塞主线程；完成后调 completion）
static void PTFakeSwipeAsync(CGPoint from, CGPoint to, double durationMs, int token, void (^done)(void)) {
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
    int steps = 12;
    double per = durationMs / steps / 1000.0;
    __block int i = 1;
    void (^step)(void) = ^(void) {
        if (token != gExecToken) { if (done) done(); return; }   // 被中断
        if (i > steps) {
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
            if (done) done();
            return;
        }
        double t = (double)i / steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseMoved];
        i++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(per * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

// 执行单条动作 → 完成后 next()
static void PTRunAction(NSDictionary *a, int token, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        PTFakeTap(CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTFakeTap(p);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double dur = [a[@"speed"] doubleValue] ?: 200;
        PTFakeSwipeAsync(from, to, dur, token, next);
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"volumeUp"]) {
        PTSetVolume(MIN(1.0, PTGetVolume() + 0.0625));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"volumeDown"]) {
        PTSetVolume(MAX(0.0, PTGetVolume() - 0.0625));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"muteToggle"]) {
        if (gMutedVolume < 0) { gMutedVolume = PTGetVolume(); PTSetVolume(0); }
        else { PTSetVolume(gMutedVolume); gMutedVolume = -1; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        if (next) next();
    }
}

// 执行方案动作序列（顺序全执行；防抖；中断旧序列）
static void PTExecutePlan(NSString *name) {
    double now = PTNow();
    if (now - gLastExec < gDebounceMs / 1000.0) {
        PTLog(@"[执行] 防抖：忽略 %@（%.0fms 内已执行）", name, gDebounceMs);
        return;
    }
    gLastExec = now;
    NSDictionary *p = gPlans[name];
    NSArray *actions = p[@"actions"] ?: @[];
    if (!actions.count) { PTLog(@"[执行] %@ 无动作，跳过", name); return; }
    gExecToken++;                 // 中断旧的
    int token = gExecToken;
    gIsInjecting = YES;
    PTLog(@"[执行] 命中 %@，开始动作序列（%lu 条）", name, (unsigned long)actions.count);
    __block int idx = 0;
    void (^runNext)(void) = ^(void) {
        if (token != gExecToken) { gIsInjecting = NO; return; }
        if (idx >= (int)actions.count) { gIsInjecting = NO; PTLog(@"[执行] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// ============================================================
// 翻页器事件处理（学习/匹配/吞）
// ============================================================
// 返回 YES = 吞掉（不调用原 sendEvent:）
static BOOL PTHandlePagerEvent(UIEvent *event) {
    if (![event respondsToSelector:@selector(allTouches)]) return NO;
    NSSet *touches = event.allTouches;
    if (!touches.count) return NO;
    UITouch *t = [touches anyObject];
    CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
    switch (t.phase) {
        case UITouchPhaseBegan: {
            gSession.active = YES;
            gSession.nEvents = 0;
            gSession.start = p;
            gSession.last = p;
            gSession.totalDist = 0;
            gSession.hasMove = NO;
            gSession.firstMoveDir = 0;
            return YES;   // 吞 down
        }
        case UITouchPhaseMoved: {
            if (!gSession.active) return YES;
            gSession.nEvents++;
            double dx = p.x - gSession.last.x, dy = p.y - gSession.last.y;
            double seg = hypot(dx, dy);
            if (seg > 0) {
                gSession.totalDist += seg;
                if (!gSession.hasMove && gSession.totalDist > 5) {
                    gSession.hasMove = YES;
                    gSession.firstMoveDir = atan2(dy, dx) * 180.0 / M_PI;
                }
            }
            gSession.last = p;
            return YES;   // 吞 move
        }
        case UITouchPhaseEnded: {
            if (!gSession.active) return YES;
            gSession.active = NO;
            PagerFeature f;
            f.phase = (gSession.totalDist < kTapDistThreshold) ? 0 : 1;
            f.direction = gSession.hasMove ? gSession.firstMoveDir : 0;
            f.dist = gSession.totalDist;
            if (gLearning) {
                PTLearnSample(f);
                return YES;   // 学习也吞（防误触 App 功能）
            }
            NSString *plan = PTMatchPlan(f);
            if (plan) {
                PTExecutePlan(plan);
                return YES;   // 吞
            }
            return YES;   // 翻页器事件一律吞（未匹配也不让 App 看到）
        }
        case UITouchPhaseCancelled:
            gSession.active = NO;
            return YES;
        default:
            return YES;
    }
}

// ============================================================
// 三指手势（手指触摸，非翻页器）
// ============================================================
static int gFingerCount = 0;
static double gThreeFingerSince = 0;

static void PTDetectThreeFinger(UIEvent *event) {
    if ([PTOverlay isVisible]) return;   // 面板已开不重复触发
    if (![event respondsToSelector:@selector(allTouches)]) return;
    for (UITouch *t in event.allTouches) {
        switch (t.phase) {
            case UITouchPhaseBegan:
                gFingerCount++;
                if (gFingerCount >= 3 && gThreeFingerSince == 0) gThreeFingerSince = PTNow();
                break;
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                gFingerCount--;
                if (gFingerCount < 3) gThreeFingerSince = 0;
                break;
            default: break;
        }
    }
    if (gFingerCount >= 3 && gThreeFingerSince > 0 && PTNow() - gThreeFingerSince > 0.4) {
        gThreeFingerSince = 0;
        PTLog(@"[手势] 三指 0.4s → 调出面板");
        [PTOverlay show];
    }
}

// ============================================================
// hook
// ============================================================
static IMP gOrigAddEvent = NULL;
static void PTImpAddEvent(id self, SEL _cmd, void *event) {
    if (event && pGetSender && pGetType) {
        uint32_t type = pGetType(event);
        uint64_t sender = pGetSender(event);
        if (type == 11 && sender == kPagerSender) {
            gPagerWindowUntil = PTNow() + kPagerWindowSec;
        }
    }
    ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

static IMP gOrigSendEvent = NULL;
static void PTImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (gIsInjecting) {   // 注入的触摸放行（防递归）
        ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    if (event && PTNow() < gPagerWindowUntil) {
        if (PTHandlePagerEvent(event)) return;   // 吞
    } else {
        PTDetectThreeFinger(event);   // 手指：三指手势
    }
    ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

// ---------- swizzle ----------
static void PTHook(NSString *clsName, NSString *selName, IMP newImp, IMP *origSlot) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { PTLog(@"[探测] 类不存在 %@ 跳过", clsName); return; }
    SEL sel = sel_registerName(selName.UTF8String);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PTLog(@"[探测] %@ -%@ 不存在，跳过", clsName, selName); return; }
    *origSlot = method_getImplementation(m);
    method_setImplementation(m, newImp);
    PTLog(@"[探测] %@ -%@ 已hook ✓", clsName, selName);
}

__attribute__((constructor))
static void PTInit() {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID.length) return;
        gBundleID = bundleID;
        PTLoadConfig(YES);
        // 未勾选或总开关关 → 旁路（零开销）
        if (!gMasterEnabled || ![gEnabledApps containsObject:bundleID]) return;

        NSString *home = NSHomeDirectory();
        NSString *logPath = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"PageTurner.log"];
        gLogPath = strdup([logPath UTF8String]);

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            pGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
            pGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
        }
        PTLog(@"==================================================");
        PTLog(@"PageTurner v1.0.0 已注入 %@ (pid=%d)", bundleID, getpid());
        PTLog(@"总开关=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu",
              gMasterEnabled, (unsigned long)gEnabledApps.count, gDebounceMs, (unsigned long)gPlans.count);
        PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTImpAddEvent, &gOrigAddEvent);
        PTHook(@"UIApplication", @"sendEvent:", (IMP)PTImpSendEvent, &gOrigSendEvent);
        // 面板窗口在首次三指调用 [PTOverlay show] 时懒创建（constructor 阶段 UIApplication 未就绪）
        PTLog(@"初始化完成。三指长按0.4s调出面板");
        PTLog(@"==================================================");
    }
}
