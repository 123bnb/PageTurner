// ============================================================
// PageTurner v1.0.1 —— 翻页器按键拦截（学习模式 + 映射 + 动作执行）
//
// v1.0.1 架构修正（用户定稿）：
//   - 所有 UI（方案列表/方案页/学习页/动作设置）在【系统设置 → PageTurner 设置页】，
//     App 内零 UI，删除三指手势
//   - 来源 sender 录进特征，不写死设备：学什么拦什么
//   - 学习宿主 = Preferences 进程：学习页打开时 tweak 收集翻页器事件 → plist，
//     设置页轮询判定
//
// 注入范围：所有进程（roothide 黑名单默认）
//   - Preferences 进程：无条件 hook（学习收集随时可能开）
//   - 其它 App：运行时检查 masterEnabled + enabledApps[bundleID] 才 hook
//
// 事件链路：
//   _UIUpdateHIDDigitizerInput -addEvent:（IOHIDEvent 层，拿 sender）
//   → 学过的 sender / 学习模式 → 开窗口
//   → UIApplication -sendEvent:（UIEvent 层）会话 up 提取特征
//   → 学习模式（Preferences）：append 样本到 plist learningSamples，不吞
//   → 运行模式（生效 App）：sender+相位+方向+位移匹配唯一方案 → 吞 → 防抖 → 顺序执行
//
// 动作：PTFakeMetaTouch（点击/双击/滑动）+ AVSystemController（静音/音量±）
// 防递归：gIsInjecting
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

// ============================================================
// 常量
// ============================================================
static NSString *kPrefPath = @"/var/mobile/Library/Preferences/com.yourname.pageturner.plist";
static NSString *kPrefsBundleID = @"com.apple.Preferences";
static const double kPagerWindowSec = 0.05;      // HID 事件 → UIEvent 分发窗口
static const double kTapDistThreshold = 30.0;    // 位移 <30pt 判定 tap
static const double kDirTolerance = 15.0;        // 方向容差 ±15°
static const double kDistSlack = 30.0;           // 位移区间匹配裕度

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
// 配置（plist：masterEnabled / enabledApps[] / debounceMs / plans[] / learning / learningSamples）
// ============================================================
static NSString *gBundleID = nil;
static BOOL gIsPreferences = NO;
static NSDictionary *gConfig = nil;
static double gConfigMtime = 0;
static BOOL gMasterEnabled = NO;
static NSMutableSet *gEnabledApps = nil;
static double gDebounceMs = 300;
static NSMutableDictionary *gPlans = nil;   // name -> dict
static BOOL gLearnActive = NO;              // plist learning.active（Preferences 进程学习开关）

static uint64_t gLearnedSenders[32];        // 已学 sender 集合（运行时识别）
static int gLearnedSenderCount = 0;

// 原始读文件（不碰 mtime 缓存）
static NSMutableDictionary *PTReadFileRaw(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefPath];
    return d ? d : [NSMutableDictionary dictionary];
}

// 原子写（tmp + rename）
static void PTWriteFileRaw(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *tmp = [kPrefPath stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:kPrefPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kPrefPath error:nil];
}

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
    gLearnedSenderCount = 0;
    for (NSDictionary *p in gConfig[@"plans"] ?: @[]) {
        if (!p[@"name"]) continue;
        gPlans[p[@"name"]] = p;
        NSDictionary *ft = p[@"feature"];
        if (ft[@"sender"]) {
            unsigned long long s = 0;
            NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
            if ([sc scanHexLongLong:&s] && gLearnedSenderCount < 32) {
                gLearnedSenders[gLearnedSenderCount++] = s;
            }
        }
    }
    gLearnActive = [gConfig[@"learning"][@"active"] boolValue];
}

// 供设置页读取当前配置快照（Preferences 进程内）
NSDictionary *PTGetConfig(void) { PTLoadConfig(NO); return gConfig; }

// 供设置页写回完整配置
void PTSaveConfig(NSDictionary *cfg) { PTWriteFileRaw(cfg); }

// 学习模式开关（设置页学习页进入/退出时写 learning.active）
void PTSetLearning(BOOL on) {
    NSMutableDictionary *cfg = PTReadFileRaw();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTWriteFileRaw(cfg);
    PTLoadConfig(YES);
}

// ============================================================
// IOKit（sender 读取）
// ============================================================
typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
static IOHIDEventGetType_t pGetType = NULL;
static IOHIDEventGetSenderID_t pGetSender = NULL;

static uint64_t gCurSender = 0;              // 最近 digitizer 事件 sender
static double gPagerWindowUntil = 0;         // 翻页器活跃窗口

static BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

// ============================================================
// 触摸会话 + 特征
// ============================================================
typedef struct {
    BOOL active;
    int nEvents;
    CGPoint start, last;
    double totalDist;
    double firstMoveDir;
    BOOL hasMove;
} PagerSession;
static PagerSession gSession;

typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
} PagerFeature;

// ============================================================
// 事件处理（学习收集 / 运行匹配+吞）
// ============================================================
static void PTExecutePlan(NSString *name);   // 前向声明（定义在动作执行段）
// 学习模式（Preferences 进程）：append 样本到 plist，不吞
static void PTAppendLearnSample(PagerFeature f, uint64_t sender) {
    NSMutableDictionary *cfg = PTReadFileRaw();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sender],
        @"phase": @(f.phase),
        @"direction": @(f.direction),
        @"dist": @(f.dist),
    }];
    cfg[@"learningSamples"] = samples;
    PTWriteFileRaw(cfg);
    PTLog(@"[学习] 样本 sender=0x%llx phase=%d dir=%.1f dist=%.1f", sender, f.phase, f.direction, f.dist);
}

// 运行模式：匹配（sender + 相位 + 方向±15° + 位移区间）→ 唯一方案
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender) {
    NSString *best = nil;
    double bestScore = DBL_MAX;
    for (NSString *name in gPlans) {
        NSDictionary *ft = gPlans[name][@"feature"];
        if (!ft) continue;
        if (ft[@"sender"]) {
            unsigned long long s = 0;
            NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
            if (![sc scanHexLongLong:&s] || s != sender) continue;   // sender 必须一致
        }
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

// 返回 YES = 吞（运行模式命中/未命中翻页器均吞）
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
            return gIsPreferences ? NO : YES;   // 学习宿主不吞（防锁死设置页）
        }
        case UITouchPhaseMoved: {
            if (!gSession.active) return gIsPreferences ? NO : YES;
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
            return gIsPreferences ? NO : YES;
        }
        case UITouchPhaseEnded: {
            if (!gSession.active) return gIsPreferences ? NO : YES;
            gSession.active = NO;
            PagerFeature f;
            f.phase = (gSession.totalDist < kTapDistThreshold) ? 0 : 1;
            f.direction = gSession.hasMove ? gSession.firstMoveDir : 0;
            f.dist = gSession.totalDist;
            if (gIsPreferences && gLearnActive) {
                PTAppendLearnSample(f, gCurSender);
                return NO;
            }
            NSString *plan = PTMatchPlan(f, gCurSender);
            if (plan) {
                PTExecutePlan(plan);
                return YES;
            }
            return YES;   // 翻页器事件一律吞（未匹配也不让 App 看到）
        }
        case UITouchPhaseCancelled:
            gSession.active = NO;
            return gIsPreferences ? NO : YES;
        default:
            return gIsPreferences ? NO : YES;
    }
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
    __block void (^step)(void);
    step = ^(void) {
        if (token != gExecToken) { if (done) done(); return; }
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
    gExecToken++;
    int token = gExecToken;
    gIsInjecting = YES;
    PTLog(@"[执行] 命中 %@，开始动作序列（%lu 条）", name, (unsigned long)actions.count);
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (token != gExecToken) { gIsInjecting = NO; return; }
        if (idx >= (int)actions.count) { gIsInjecting = NO; PTLog(@"[执行] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// ============================================================
// hook
// ============================================================
static IMP gOrigAddEvent = NULL;
static void PTImpAddEvent(id self, SEL _cmd, void *event) {
    PTLoadConfig(NO);   // 每次事件刷新配置（设置页改动即时生效）
    if (event && pGetSender && pGetType) {
        uint32_t type = pGetType(event);
        uint64_t sender = pGetSender(event);
        if (type == 11) {
            gCurSender = sender;
            if (gIsPreferences && gLearnActive) {
                gPagerWindowUntil = PTNow() + kPagerWindowSec;   // 学习：全部 digitizer
            } else if (PTIsLearnedSender(sender)) {
                gPagerWindowUntil = PTNow() + kPagerWindowSec;   // 运行：学过的 sender
            }
        }
    }
    ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

static IMP gOrigSendEvent = NULL;
static void PTImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    PTLoadConfig(NO);   // 每次事件刷新配置（设置页改动即时生效）
    if (gIsInjecting) {
        ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    if (event && PTNow() < gPagerWindowUntil) {
        if (PTHandlePagerEvent(event)) return;
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
        gIsPreferences = [bundleID isEqualToString:kPrefsBundleID];
        PTLoadConfig(YES);

        NSString *home = NSHomeDirectory();
        NSString *logPath = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"PageTurner.log"];
        gLogPath = strdup([logPath UTF8String]);

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            pGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
            pGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
        }
        PTLog(@"==================================================");
        PTLog(@"PageTurner v1.0.1 已注入 %@ (pid=%d) isPrefs=%d", bundleID, getpid(), gIsPreferences);
        PTLog(@"总开关=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu 已学sender=%d",
              gMasterEnabled, (unsigned long)gEnabledApps.count, gDebounceMs,
              (unsigned long)gPlans.count, gLearnedSenderCount);
        if (gIsPreferences) {
            // Preferences 进程：无条件 hook（学习收集随时可能开）
            PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTImpAddEvent, &gOrigAddEvent);
            PTHook(@"UIApplication", @"sendEvent:", (IMP)PTImpSendEvent, &gOrigSendEvent);
            PTLog(@"Preferences 进程就绪：学习页开启时自动收集翻页器样本");
        } else if (gMasterEnabled && [gEnabledApps containsObject:bundleID]) {
            // 生效 App：hook 拦截
            PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTImpAddEvent, &gOrigAddEvent);
            PTHook(@"UIApplication", @"sendEvent:", (IMP)PTImpSendEvent, &gOrigSendEvent);
            PTLog(@"生效 App 就绪：学过的 sender 按键将被拦截");
        } else {
            PTLog(@"旁路：未生效 App（bundleID 不在列表或总开关关）");
        }
        PTLog(@"==================================================");
    }
}
