// ============================================================
// PageTurner v1.0.16 —— 翻页器按键拦截（学习模式 + 映射 + 动作执行）
//
// v1.0.16：整包回滚 v1.0.4（用户实测唯一能录多个不冲突的版本），
//   只加设置页日志系统（内存+文件双写），采集/判重/阈值逐字等于 v1.0.4。
//   本文件 = v1.0.4 原版运行端（addEvent 层吞已学 sender），未改动。
//
// v1.0.5 关键修复（用户反馈"指定 App 生效没用"根因）：
//   - 运行模式特征提取从 UIApplication -sendEvent:（依赖 UIKit 把鼠标移动合成
//     触摸事件，普通 App 不合成 → 收不到）搬到 _UIUpdateHIDDigitizerInput
//     -addEvent:（IOHIDEvent 层直接读相对位移 0x23/0x24），
//     已学 sender 的事件直接吞掉并执行映射 —— 所有 App 都能拦
//   - 新增调试模式（设置页开关）：拦截/特征/匹配/执行逐步日志
//
// v1.0.1 架构修正（用户定稿）：
//   - 所有 UI（方案列表/方案页/学习页/动作设置）在【系统设置 → PageTurner 设置页】，
//     App 内零 UI，删除三指手势
//   - 来源 sender 录进特征，不写死设备：学什么拦什么
//   - 学习宿主 = Preferences 进程（设置页 bundle 内自 hook，roothide 空 Filter
//     不注入系统 App，tweak 不参与学习收集）
//
// 注入范围：仅生效 App（masterEnabled + enabledApps[bundleID]）
//   - 学习收集：设置页 bundle 自 hook（Preferences 进程）
//   - 运行拦截：addEvent 层吞已学 sender 事件 → 提取特征 → 匹配 → 执行映射
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
static const double kPagerGapSec = 0.15;      // HID 事件间隔 >150ms 视为按键会话结束
static const double kTapDistThreshold = 30.0; // 位移 <30pt 判定 tap
static const double kDirTolerance = 15.0;     // 方向容差 ±15°
static const double kDistSlack = 30.0;        // 位移区间匹配裕度

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
static BOOL gDebugMode = NO;                // 调试模式（详细日志）

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
    gDebugMode = [gConfig[@"debugMode"] boolValue];
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
typedef double (*IOHIDEventGetFloatValue_t)(void *, uint32_t);
static IOHIDEventGetType_t pGetType = NULL;
static IOHIDEventGetSenderID_t pGetSender = NULL;
static IOHIDEventGetFloatValue_t pGetFloat = NULL;

static BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

// ============================================================
// 按键会话（addEvent 层，IOHIDEvent 相对位移）
// ============================================================
typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
} PagerFeature;

static void PTExecutePlan(NSString *name);                    // 前向声明（动作执行段定义）
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender); // 前向声明（事件处理段定义）
static void PTFinishHIDSession(void);                         // 前向声明

typedef struct {
    BOOL active;
    uint64_t sender;
    double lastEventAt;
    double totalDist;
    double firstMoveDir;
    BOOL hasMove;
    BOOL settled;   // 已结算防重复
} PagerHIDSession;
static PagerHIDSession gHID;

// 已学 sender 的 digitizer 事件：提取相对位移并累计
static void PTPagerAddDelta(double dx, double dy) {
    double now = PTNow();
    if (gHID.active && now - gHID.lastEventAt > kPagerGapSec) PTFinishHIDSession();
    if (!gHID.active) {
        gHID.active = YES;
        gHID.totalDist = 0;
        gHID.firstMoveDir = 0;
        gHID.hasMove = NO;
        gHID.settled = NO;
    }
    gHID.lastEventAt = now;
    double seg = hypot(dx, dy);
    if (seg > 0) {
        gHID.totalDist += seg;
        if (!gHID.hasMove && gHID.totalDist > 5) {
            gHID.hasMove = YES;
            gHID.firstMoveDir = atan2(dy, dx) * 180.0 / M_PI;
        }
    }
    if (gDebugMode) PTLog(@"[拦截] sender=0x%llx dx=%.1f dy=%.1f 累计=%.1f dir=%.1f",
                          gHID.sender, dx, dy, gHID.totalDist, gHID.firstMoveDir);
    // 事件流停止 250ms 后结算（事件流结束后没有新事件也能触发）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PTFinishHIDSession();
    });
}

// 结算按键会话：提取特征 → 匹配 → 执行
static void PTFinishHIDSession(void) {
    if (!gHID.active || gHID.settled) return;
    // 事件流必须真正停止（最后事件 +250ms）才结算，否则重新等待——
    // 避免连续按键时上一个结算块误结算/拆断新会话
    if (PTNow() - gHID.lastEventAt < 0.25) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            PTFinishHIDSession();
        });
        return;
    }
    gHID.settled = YES;
    uint64_t sender = gHID.sender;
    double dist = gHID.totalDist;
    PagerFeature f;
    f.phase = (dist < kTapDistThreshold) ? 0 : 1;
    f.direction = gHID.hasMove ? gHID.firstMoveDir : 0;
    f.dist = dist;
    gHID.active = NO;
    if (gDebugMode) PTLog(@"[特征] sender=0x%llx phase=%d dir=%.1f dist=%.1f", sender, f.phase, f.direction, f.dist);
    NSString *plan = PTMatchPlan(f, sender);
    if (plan) {
        PTLog(@"[匹配] 命中方案「%@」", plan);
        PTExecutePlan(plan);
    } else if (gDebugMode) {
        // 未命中原因排查
        if (gLearnedSenderCount == 0) PTLog(@"[匹配] 未命中：没有已学特征（先录制方案）");
        else if (!PTIsLearnedSender(sender)) PTLog(@"[匹配] 未命中：sender=0x%llx 不在已学特征（录的是 0x%llx）", sender, gLearnedSenders[0]);
        else PTLog(@"[匹配] 未命中：sender 对但相位/方向/位移不匹配（phase=%d dir=%.1f dist=%.1f）", f.phase, f.direction, f.dist);
    }
}

// ============================================================
// 事件处理（运行拦截：addEvent 层吞已学 sender + 特征提取 + 执行）
// ============================================================
static void PTExecutePlan(NSString *name);   // 前向声明（定义在动作执行段）

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
    if (gDebugMode) {
        if ([type isEqualToString:@"tap"]) PTLog(@"[执行] 点击(%@,%@)", a[@"x"], a[@"y"]);
        else if ([type isEqualToString:@"doubleTap"]) PTLog(@"[执行] 双击(%@,%@)", a[@"x"], a[@"y"]);
        else if ([type isEqualToString:@"swipe"]) PTLog(@"[执行] 滑动(%@,%@)→(%@,%@)", a[@"x1"], a[@"y1"], a[@"x2"], a[@"y2"]);
        else PTLog(@"[执行] %@", type);
    }
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
    if (event && pGetType && pGetSender) {
        uint32_t type = pGetType(event);
        if (type == 11) {   // Digitizer（触摸/翻页器鼠标位移）
            uint64_t sender = pGetSender(event);
            if (PTIsLearnedSender(sender)) {
                // 翻页器（已学 sender）：提取相对位移，吞掉不让 UIKit 看到
                double dx = pGetFloat ? pGetFloat(event, 0x23) : 0;
                double dy = pGetFloat ? pGetFloat(event, 0x24) : 0;
                gHID.sender = sender;
                PTPagerAddDelta(dx, dy);
                return;   // 吞：不调用原实现 → 事件不进入 App（无鼠标行为、无触摸）
            }
        }
    }
    ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

static IMP gOrigSendEvent = NULL;
static void PTImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (gIsInjecting) {
        // PTFakeMetaTouch 注入的触摸事件：放行给 App 处理
        ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    if (gDebugMode && event) {
        // 低频摘要：确认 App 侧收到的触摸事件（区分链路）
        static double sLastDump = 0;
        double now = PTNow();
        if (now - sLastDump > 1.0) {
            sLastDump = now;
            NSSet *ts = [event respondsToSelector:@selector(allTouches)] ? event.allTouches : nil;
            PTLog(@"[调试] sendEvent 收到 UIEvent touches=%lu", (unsigned long)(ts ? ts.count : 0));
        }
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
            pGetFloat = (IOHIDEventGetFloatValue_t)dlsym(iokit, "IOHIDEventGetFloatValue");
        }
        PTLog(@"==================================================");
        PTLog(@"PageTurner v1.0.16 已注入 %@ (pid=%d) isPrefs=%d", bundleID, getpid(), gIsPreferences);
        PTLog(@"总开关=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu 已学sender=%d 调试=%d",
              gMasterEnabled, (unsigned long)gEnabledApps.count, gDebounceMs,
              (unsigned long)gPlans.count, gLearnedSenderCount, gDebugMode);
        if (gIsPreferences) {
            // 学习收集由设置页 bundle 内自 hook 负责（roothide 空 Filter 不注入系统 App，
            // tweak 在此进程收不到事件；bundle 必然被 PreferenceLoader 加载）。
            // tweak 不 hook，避免双收集。
            PTLog(@"Preferences 进程旁路：学习收集由设置页 bundle 负责");
        } else if (gMasterEnabled && [gEnabledApps containsObject:bundleID]) {
            // 生效 App：hook addEvent 层（吞已学 sender 事件 + 提取特征）+ sendEvent（放行注入）
            PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTImpAddEvent, &gOrigAddEvent);
            PTHook(@"UIApplication", @"sendEvent:", (IMP)PTImpSendEvent, &gOrigSendEvent);
            PTLog(@"生效 App 就绪：已学 sender 按键将在 HID 层被拦截并替换为映射动作");
        } else {
            PTLog(@"旁路：未生效 App（bundleID 不在列表或总开关关）");
        }
        PTLog(@"==================================================");
    }
}
