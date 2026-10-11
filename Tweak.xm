// ============================================================
// PageTurner v1.0.13 —— 录制日志"内存+文件"双写（日志页 100% 可见）
//
// v1.0.13（日志页不再可能空白 + 冲突提示自动换行）：
//   - 【日志双写】上一版改到 NSHomeDirectory()/Documents 仍空白 —— 不同 iOS
//     环境 NSHomeDirectory() 返回值不同（有的返回 /var/mobile 导致写失败）。
//     本版 SLog 改为：① 内存数组（日志页直接显示，不依赖文件系统，100% 可见）
//     + ② 文件多候选路径（沙盒 Documents → home/Documents → tmp → /var/mobile/Documents，
//     第一个可写的生效，并显示实际路径）
//   - 【提示换行】录制页状态提示改为大高度+自动换行，长内容碰屏幕边缘换行，
//     不再显示不全
//   - 录制逻辑仍是 v1.0.4 原版（addEvent 0x23/0x24，无过滤无锚定），没动
//
// v1.0.12（录制端日志路径修复 —— 上一版日志为空是因为写错了路径）：
//   - 【根因】v1.0.11 的录制日志写 /var/mobile/Documents/PageTurner.log，
//     但 iOS 沙盒只允许 Preferences 进程写自己的容器（NSHomeDirectory()/Documents），
//     外部路径打开必失败且错误被忽略 → 日志永远空。设置页"日志"页读的也是
//     这个死路径 → 用户看到"完全没有日志"
//   - 【修复】录制日志改写到 Preferences 沙盒容器 NSHomeDirectory()/Documents/PageTurner.log，
//     设置页"日志"页同步读同一路径 → 日志真正可见可复制
//   - 录制逻辑仍是 v1.0.4 原版（addEvent 0x23/0x24，无过滤无锚定），没动
//
// v1.0.11（录制端加日志 + 会话彻底复位 —— 定位"只能录1个后重复录入"）：
//   - 【录制端日志】Preferences 进程此前完全没有日志。本版录制全链路写
//     /var/mobile/Documents/PageTurner.log：hook 是否成功、每个 type=11 事件的
//     sender/dx/dy、会话结算的 phase/dir/dist、判重拒绝时的新旧特征对比 ——
//     录不到/重复录入一眼定位
//   - 【会话复位】学习页 viewDidLoad/viewDidDisappear 全量复位会话状态
//     （sSessActive/sSessSettled/轨迹），防止"录一半退出 → 残留状态 → 下次
//     新会话永不开始"
//   - 【判重提示】被拒时显示新旧特征详细对比（方向/位移/sender），确认是
//     真重复还是误判
//
// v1.0.10（录制端真正回滚 v1.0.4 原版 —— 修"v1.0.9 仍录不了"）：
//   - 【核心】v1.0.9 只是删了锚定，采集层仍是 v1.0.8 的 sendEvent 坐标版，
//     在 Preferences 进程收不到翻页器 → 还是录不了。本版把录制端 RootListController.m
//     整段还原成 v1.0.4 原版：hook _UIUpdateHIDDigitizerInput -addEvent:，
//     type=11 全收（无过滤无锚定），读 IOHIDEvent 相对位移 0x23/0x24 ——
//     用户实测这是唯一能正常录翻页器的版本
//   - 【学习页】恢复 v1.0.4 的"进入即 armed"（去掉 v1.0.7 的 1 秒武装延迟）
//   - 【轨迹】保留可视化（v1.0.9 新增）：按相对位移累积绘制路径，
//     起点=屏幕中心绿圈 → 沿线绿点 → 终点红点 + 蓝位移线 + Δ(x,y) 标注
//   - 日志自动建目录修复（v1.0.9）保留
//
// v1.0.9（录制回滚 v1.0.4 行为 + 学习轨迹可视化 + 日志修复）：见上，已被 v1.0.10 取代
// v1.0.8（拦截架构回滚到 sendEvent 层 —— 修复方向键完全没拦的根因）：
//   - 【核心】v1.0.5 把拦截搬到 _UIUpdateHIDDigitizerInput -addEvent: 读 0x23/0x24
//     是方向性错误：实测（HIDKeySniffer v1.0.8 日志）翻页器方向键在 addEvent 层
//     根本不是 type=11（无 DIG 打印），点击键 type=11 但 0x23/0x24 读出全 0 →
//     方向键完全没拦、位移全废 → 录制失败/运行失败/调试无绿点
//   - 回滚到 v1.0.4/v1.0.10 验证过的架构：hook UIApplication -sendEvent:，
//     从合成触摸的 _hidEvent 溯源 sender（手指触摸 sender=0 天然排除），
//     从 UITouch 屏幕坐标提取位移/方向（真实、画布验证过）
//   - 调试模式触摸特效：注入点触/翻页器合成=绿大圆点，手指=蓝小点（0.6s）
//   - gInjectSender 捕获改在 sendEvent 层（非翻页器、非空闲、非零）
//
// v1.0.7：录制锚定武装延迟 + 锁定状态显示 + 设置图标 29×29
// v1.0.6：注入 IOHIDEvent 补 senderID（gInjectSender）+ 调试特效 + keyWindow 兜底
// v1.0.5：拦截链路 HID 化（已被 v1.0.8 回滚）
//
// v1.0.1 架构修正（用户定稿）：
//   - 所有 UI（方案列表/方案页/学习页/动作设置）在【系统设置 → PageTurner 设置页】，
//     App 内零 UI，删除三指手势
//   - 来源 sender 录进特征，不写死设备：学什么拦什么
//   - 学习宿主 = Preferences 进程（设置页 bundle 内自 hook，roothide 空 Filter
//     不注入系统 App，tweak 不参与学习收集）
//
// 注入范围：仅生效 App（masterEnabled + enabledApps[bundleID]）
// 动作：PTFakeMetaTouch（点击/双击/滑动）+ AVSystemController（静音/音量±）
// 防递归：gIsInjecting；日志：App 容器 Documents/PageTurner.log
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
static void PTEnsureDir(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
}
static void PTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec; struct tm tmv; localtime_r(&sec, &tmv);
    char tbuf[64]; strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@\n", tbuf, (int)(tv.tv_usec/1000), msg];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    // ① 注入进程容器 Documents（生效 App 的日志主位置）
    if (gLogPath) {
        NSString *p = [NSString stringWithUTF8String:gLogPath];
        PTEnsureDir([p stringByDeletingLastPathComponent]);
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; } @catch (NSException *e) {} }
    }
    // ② 固定路径 /var/mobile/Documents/PageTurner.log
    //    （旧 bug：该目录在 iOS 上不存在 → 写入一直失败 → 日志永远空。现自动建目录）
    PTEnsureDir(@"/var/mobile/Documents");
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

// 进程内最近一次真实手指触摸的 senderID（模拟触摸注入必须用它，否则被系统丢弃）
uint64_t gInjectSender = 0;
// 空闲 digitizer sender（无触摸心跳，不算真实触摸）
#define kIdleDigitizerSender 0x8000000800a15173ull

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
static CGPoint gLastTouchPoint = {0, 0};

// 已学 sender 的合成触摸：按屏幕坐标增量累计会话
// （翻页器方向键 = 鼠标相对位移合成触摸，坐标在小范围内重复；点击键坐标不变）
static void PTPagerTouchPoint(CGPoint p, uint64_t sender) {
    double now = PTNow();
    if (gHID.active && now - gHID.lastEventAt > kPagerGapSec) PTFinishHIDSession();
    if (!gHID.active) {
        gHID.active = YES;
        gHID.sender = sender;
        gHID.totalDist = 0;
        gHID.firstMoveDir = 0;
        gHID.hasMove = NO;
        gHID.settled = NO;
        gLastTouchPoint = p;
    }
    gHID.lastEventAt = now;
    if (!CGPointEqualToPoint(gLastTouchPoint, p)) {
        double dx = p.x - gLastTouchPoint.x, dy = p.y - gLastTouchPoint.y;
        double seg = hypot(dx, dy);
        if (seg > 0) {
            gHID.totalDist += seg;
            if (!gHID.hasMove && gHID.totalDist > 5) {
                gHID.hasMove = YES;
                gHID.firstMoveDir = atan2(dy, dx) * 180.0 / M_PI;
            }
        }
    }
    gLastTouchPoint = p;
    if (gDebugMode) PTLog(@"[拦截] sender=0x%llx pt=(%.1f,%.1f) 累计=%.1f dir=%.1f",
                          sender, p.x, p.y, gHID.totalDist, gHID.firstMoveDir);
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

// 点击（同步短阻塞；keyWindow 兜底 windows.lastObject）
static void PTFakeTap(CGPoint p) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) w = [[UIApplication sharedApplication].windows lastObject];
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
// 调试模式触摸特效（VolumeKeyTapper 式）：点触处闪圆点，独立窗口不挡触摸
static UIWindow *gFxWindow = nil;
static void PTShowFx(CGPoint p, BOOL injected) {
    if (!gFxWindow) {
        gFxWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gFxWindow.windowLevel = 10000;
        gFxWindow.userInteractionEnabled = NO;
        gFxWindow.backgroundColor = [UIColor clearColor];
        gFxWindow.hidden = NO;
    }
    CGFloat d = injected ? 36 : 16;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    dot.center = p;
    dot.layer.cornerRadius = d / 2;
    dot.backgroundColor = injected
        ? [UIColor colorWithRed:0.15 green:0.85 blue:0.25 alpha:0.9]
        : [UIColor colorWithRed:0.25 green:0.55 blue:0.95 alpha:0.6];
    dot.layer.borderWidth = injected ? 2 : 1;
    dot.layer.borderColor = [UIColor whiteColor].CGColor;
    [gFxWindow addSubview:dot];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [dot removeFromSuperview];
    });
}

// 从 UIEvent/UITouch 内部取回 IOHIDEvent 并读 sender（v1.0.10 验证：
// 屏幕手指触摸 sender=0，外部 HID（翻页器）sender≠0 —— 天然区分设备）
static uint64_t PTHIDEventSender(UIEvent *event) {
    if (!event || !pGetSender) return 0;
    id hid = nil;
    @try { hid = [event valueForKey:@"_hidEvent"]; } @catch (NSException *e) {}
    if (!hid) { @try { hid = [event valueForKey:@"hidEvent"]; } @catch (NSException *e) {} }
    if (!hid && event.type == UIEventTypeTouches) {
        UITouch *t = [event.allTouches anyObject];
        if (t) { @try { hid = [t valueForKey:@"_hidEvent"]; } @catch (NSException *e) {} }
    }
    if (!hid) return 0;
    @try { return pGetSender((__bridge void *)hid); } @catch (NSException *e) { return 0; }
}

static IMP gOrigSendEvent = NULL;
static void PTImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    PTLoadConfig(NO);   // 每次事件刷新配置（设置页改动即时生效）
    if (!event) { ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event); return; }
    uint64_t sender = PTHIDEventSender(event);

    // 调试模式：所有点触可视化（注入=绿大圆点，翻页器合成=绿大圆点，手指=蓝小点）
    if (gDebugMode && event.type == UIEventTypeTouches) {
        for (UITouch *t in event.allTouches) {
            if (!t.window) continue;
            CGPoint p = [t locationInView:t.window];
            if (gIsInjecting || PTIsLearnedSender(sender)) PTShowFx(p, YES);
            else PTShowFx(p, NO);
        }
    }

    if (!gIsInjecting && sender != 0 && PTIsLearnedSender(sender)) {
        // 翻页器合成触摸：提取屏幕坐标会话 → 吞掉（不进入 App）
        UITouch *t = [event.allTouches anyObject];
        if (t) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:nil];
            PTPagerTouchPoint(p, sender);
        }
        return;   // 吞
    }

    // 捕获进程内真实触摸 sender（供模拟触摸注入；非翻页器、非空闲、非零）
    if (!gIsInjecting && sender != 0 && sender != kIdleDigitizerSender && !PTIsLearnedSender(sender)) {
        gInjectSender = sender;
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
        PTLog(@"PageTurner v1.0.13 已注入 %@ (pid=%d) isPrefs=%d", bundleID, getpid(), gIsPreferences);
        PTLog(@"总开关=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu 已学sender=%d 调试=%d",
              gMasterEnabled, (unsigned long)gEnabledApps.count, gDebounceMs,
              (unsigned long)gPlans.count, gLearnedSenderCount, gDebugMode);
        if (gIsPreferences) {
            // 学习收集由设置页 bundle 内自 hook 负责（roothide 空 Filter 不注入系统 App，
            // tweak 在此进程收不到事件；bundle 必然被 PreferenceLoader 加载）。
            // tweak 不 hook，避免双收集。
            PTLog(@"Preferences 进程旁路：学习收集由设置页 bundle 负责");
        } else if (gMasterEnabled && [gEnabledApps containsObject:bundleID]) {
            // 生效 App：hook sendEvent 层 —— 翻页器合成触摸（_hidEvent 溯源 sender）
            // 直接吞掉并替换为映射动作；手指触摸（sender=0）放行
            PTHook(@"UIApplication", @"sendEvent:", (IMP)PTImpSendEvent, &gOrigSendEvent);
            PTLog(@"生效 App 就绪：已学 sender 按键将在触摸层被拦截并替换为映射动作");
        } else {
            PTLog(@"旁路：未生效 App（bundleID 不在列表或总开关关）");
        }
        PTLog(@"==================================================");
    }
}
