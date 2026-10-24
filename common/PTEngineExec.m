// ============================================================
// PTEngineExec.m —— 引擎核心·动作执行（v1.0.78 从 PTEngineCore.m 拆出）
//
// 内容：假触摸执行全家（PTFakeTap 同步短阻塞 / PTFakeSwipeAsync 异步分步 /
//       PTFakeRecSwipeAsync CADisplayLink 时间插值回放 + PTRunAction 单条动作
//       分发，令牌失配即抬手收尾）、执行态全局（gExecRunning/gInFakeTouch/
//       gExecToken）、测试回放执行链（PTTestOnEnded 结算 → PTTestExecPlan →
//       PTChainOnHit）。
// ⚠ PTTestTap / PTTestRunAction 是 v1.0.72 起的死代码（无调用方，测试执行已改走
//   PTChainOnHit → PTExecutePlan → 本文件的 PTRunAction，与运行端同一条回放
//   路径）——拆分不做行为改动故原样迁移并标记，改测试执行前认准活路径。
// ============================================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "ptftouch/PTFakeMetaTouch.h"
#import "PTEngineCore.h"
#import "PTEngineInternal.h"

// ============================================================
// 执行态全局（v1.0.78 拆文件落位：假触摸机制所在 → 定义随本文件）
// v1.0.66-fix4 起上移至全局区供测试页共用；三者均为 PTEngineCore.h extern
// （外壳 hook 与设置页 hook 跨文件读写，同进程内只有一个引擎镜像）——
// 定义只能在此一处。gIsInjecting 与注入引用计数在 PTEngineChain.m。
// ============================================================
BOOL gExecRunning = NO;
BOOL gInFakeTouch = NO;
int gExecToken = 0;

// ============================================================
// 动作执行（PTFakeMetaTouch ＋ 延迟；v1.0.5 音量动作已删除）
// ============================================================
static void PTFakeTap(CGPoint p, int pressMs) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    gInFakeTouch = YES;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    usleep(pressMs * 1000);
    gInFakeTouch = YES;
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    gInFakeTouch = NO;
}

// 滑动（异步分步；holdMs 按下停留，liftMs 弹起停留，noInertia 防惯性）
static void PTFakeSwipeAsync(CGPoint from, CGPoint to, double durationMs, int holdMs, int liftMs, BOOL noInertia, int token, void (^done)(void)) {
    double durSec = MAX(durationMs / 1000.0, 0.001);
    __block NSInteger pid = -1;
    __block BOOL began = NO;
    __block BOOL ended = NO;
    __block CGPoint lastP = from;
    __block void (^abortEnd)(void);
    __block void (^doEnd)(void);
    abortEnd = ^{
        if (ended) return;
        ended = YES;
        if (!began) { if (done) done(); return; }
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
        if (done) done();   // v1.0.66-fix3：旧代码此路径不回调 done，动作序列链悬挂
    };
    doEnd = ^{
        if (ended) { if (done) done(); return; }
        ended = YES;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
        if (done) done();
    };
    __block void (^stillAt)(CGPoint, int);
    stillAt = ^(CGPoint pos, int ms) {
        __block int n = MAX(ms, 0) / 16;
        __block void (^still)(void);
        still = ^(void) {
            // v1.0.76：abortEnd 内部已回调 done，旧代码外层再调一次 = 动作链双跑
            if (token != gExecToken) { abortEnd(); return; }
            if (n <= 0) { doEnd(); return; }
            n--;
            lastP = pos;
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
            gInFakeTouch = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
        };
        still();
    };
    __block CFAbsoluteTime t0;
    __block void (^step)(void);
    step = ^(void) {
        // v1.0.76：abortEnd 内部已回调 done，旧代码外层再调一次 = 动作链双跑
        if (token != gExecToken) { abortEnd(); return; }
        double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
        if (t >= 1.0) {
            if (noInertia) {
                stillAt(to, MAX(liftMs, 300));
            } else {
                if (liftMs > 0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                            // v1.0.76：abortEnd 内部已回调 done，旧代码外层再调一次 = 动作链双跑
                            if (token != gExecToken) { abortEnd(); return; }
                            doEnd();
                        });
                } else {
                    doEnd();
                }
            }
            return;
        }
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        lastP = p;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
        if (token != gExecToken) { if (done) done(); return; }
        began = YES;
        gInFakeTouch = YES;
        pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
        gInFakeTouch = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            t0 = CFAbsoluteTimeGetCurrent();
            step();
        });
    });
}

// v1.0.55：滑动(手动)回放（CADisplayLink 驱动，照搬 DirectVolumeTap 的 DVTFakeSwipe）
// 每帧对齐 VSync，按真实经过时间插值出坐标注入一次 Moved，1:1 还原真实手指流畅感。
// pts 为 @{x,y,t} 字典（与录制/设置页/测试一致）。
@interface PTRecSwipeTickProxy : NSObject
@property (nonatomic, copy) void (^tick)(void);
- (void)onTick:(CADisplayLink *)link;
@end
@implementation PTRecSwipeTickProxy
- (void)onTick:(CADisplayLink *)link { if (_tick) _tick(); }
@end

// v1.0.78：PTRecSwipeInterp（按时间线性插值取坐标）已下沉 PTCoreLogic.m
// （纯逻辑层，tests/ 可链）——本文件 PTFakeRecSwipeAsync 经 PTCoreLogic.h 调用，行为不变。

static void PTFakeRecSwipeAsync(NSArray *pts, int token, double rate, void (^done)(void)) {
    if (!pts.count) { if (done) done(); return; }
    // 预解析 @{x,y,t} → 分离数组（避免每帧反复解包）
    NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array], *ts = [NSMutableArray array];
    for (NSDictionary *p in pts) {
        [xs addObject:@([p[@"x"] doubleValue])];
        [ys addObject:@([p[@"y"] doubleValue])];
        [ts addObject:@([p[@"t"] doubleValue])];
    }
    NSUInteger m = ts.count;
    if (m < 2) { if (done) done(); return; }
    double t0 = [ts[0] doubleValue];
    double totalMs = [ts[m-1] doubleValue] - t0;
    if (totalMs <= 0) totalMs = 1.0;
    double ratev = (rate > 0) ? rate : 1.0;   // v1.0.66(#6)：提速倍率（连滑时 >1）

    // v1.0.71：测试区轨迹可视化（设置页富版并入 Core）——新段回放开始：作废上一段余留的
    // 淡出令牌、重建尾巴、先画起点。sTestDot 为 nil（App 进程无测试页）时各钩子直接返回，零成本。
    sTestTrailToken++;
    sTestTrail = [NSMutableArray array];
    PTTestDrawTrailHead(CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]));

    __block NSInteger pid = -1;
    __block BOOL ended = NO;
    __block CGPoint lastCur = CGPointZero;   // v1.0.66-fix3：最后注入坐标，中断时在此抬手
    __block CFAbsoluteTime startT = CFAbsoluteTimeGetCurrent();
    __block CFAbsoluteTime lastTick = startT;
    __block double playMs = 0;   // v1.0.66(#6)：已播放毫秒（受 rate 与单帧封顶约束，单调推进）
    PTRecSwipeTickProxy *proxy = [PTRecSwipeTickProxy new];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(onTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    proxy.tick = ^{
        // v1.0.66-fix3：被新手势砍断（token 失配）→ 先在最后位置发 Ended 抬手，再 invalidate。
        // 旧代码只 invalidate 不发 Ended → 假手指粘半空、调试圆点永不消散、App 端叠成双指混乱。
        if (token != gExecToken) {
            if (pid >= 0 && !ended) {
                ended = YES;
                gInFakeTouch = YES;
                [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastCur withTouchPhase:UITouchPhaseEnded];
                gInFakeTouch = NO;
            }
            PTTestTrailFinish(lastCur, 0.3);   // v1.0.71：中断也要收尾（终点 P + 尾巴淡出），否则可视化残影
            [link invalidate]; if (done) done(); return;
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        double realMs = (now - startT) * 1000.0;
        double frameMs = (now - lastTick) * 1000.0;   // 距上次 tick 的真实间隔
        lastTick = now;
        // v1.0.66(#6)：看门狗——真实时间远超播放总时长（封顶 6x）仍没走完 → 强制结束，避免卡死
        if (realMs > totalMs * 6.0) frameMs = totalMs;
        double target = playMs + frameMs * ratev;      // 按 rate 推进目标
        if (target > totalMs) target = totalMs;
        // v1.0.66(#6)：单帧封顶——每帧最多推进 100ms，避免高 rate / 卡顿后瞬移
        double cap = playMs + 100.0;
        if (target > cap) target = cap;
        playMs = target;
        CGPoint cur = PTRecSwipeInterp(xs, ys, ts, t0 + playMs);   // 按推进量插值还原
        lastCur = cur;   // v1.0.66-fix3：记录最后坐标供中断抬手
        gInFakeTouch = YES;
        if (pid < 0) pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:cur withTouchPhase:UITouchPhaseBegan];
        else         [PTFakeMetaTouch fakeTouchId:pid AtPoint:cur withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        PTTestDrawTrailHead(cur);   // v1.0.71：逐帧追加尾巴（起点→…→当前）
        if (playMs >= totalMs && !ended) {
            CGPoint end = CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:end withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            ended = YES;
            [link invalidate];
            PTTestTrailFinish(end, totalMs / 1000.0);   // v1.0.71：终点 P + 尾巴保留后淡出
            if (done) done();
        }
    };
}

// 执行单条动作 → 完成后 next()
void PTRunAction(NSDictionary *a, int token, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        PTFakeTap(CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]), pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        int gapMs = [a[@"gapMs"] intValue] ?: 120;
        PTFakeTap(p, pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gapMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p, pressMs);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double speed = ([a[@"speed"] doubleValue] ?: 1000) * gSwipeBurstRate;   // v1.0.67：连滑档位(1/2/3) → 越快；单滑固定 1.0
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        double dist = hypot(to.x - from.x, to.y - from.y);
        double durMs = (dist / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 90) durMs = 90;   // v1.0.66-fix：保底时长，连滑提速也不低于此，确保 App 识别为滑动而非点按
        PTFakeSwipeAsync(from, to, durMs, holdMs, liftMs, noInertia, token, next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.8：滑动(手动)——按录制轨迹回放；v1.0.66(#6)：带连滑提速倍率
        PTFakeRecSwipeAsync(a[@"pts"], token, (double)gSwipeBurstRate, next);   // v1.0.67：连滑档位(1/2/3) → 越快
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}
// ============================================================
// 测试回放执行链（PTTestOnEnded 结算 → 匹配 → PTChainOnHit 统一判定）
// ============================================================
// ------------------------------------------------------------
// 死代码区（v1.0.78 拆分时原样迁移，保留备查）：
//   PTTestTap / PTTestRunAction 自 v1.0.72 起无任何调用方——测试执行已改走
//   PTTestExecPlan → PTChainOnHit → PTExecutePlan → PTRunAction（与运行端同一条
//   回放路径，见下方 PTTestExecPlan 与 PTEngineChain.m）。当时漏删旧分支，
//   本次拆分不做行为改动故原样保留；要改测试执行，先认准活路径是 PTRunAction。
// ------------------------------------------------------------
static void PTTestTap(CGPoint p, BOOL doubleTap) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    PTTestShowDot(p, p, NO, 0);
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    usleep(30000);
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    if (doubleTap) {
        usleep(120000);
        PTTestShowDot(p, p, NO, 0);
        NSInteger pid2 = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
        usleep(30000);
        [PTFakeMetaTouch fakeTouchId:pid2 AtPoint:p withTouchPhase:UITouchPhaseEnded];
    }
}
// v1.0.5（与 deb v1.0.48 同步）：音量动作类型（音量+/音量-/静音切换）整体删除——
// 第三方 App 进程无激活音频会话时，系统音量读取接口（AVSystemController get /
// AVAudioSession.outputVolume / MPVolumeView slider 同步读）全部返回假值（四版实测），
// 写也只能靠异步 slider 兜底 → 止损删除。旧配置兼容：已保存映射里的音量动作执行时
// 被 PTRunAction/PTTestRunAction 默认分支跳过（不崩溃）。

// 执行单条动作 → 完成后 next()
static void PTTestRunAction(NSDictionary *a, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double speed = ([a[@"speed"] doubleValue] ?: 1000) * gSwipeBurstRate;   // v1.0.67：测试页同样吃连滑档位(1/2/3)
        double distT = hypot(to.x - from.x, to.y - from.y);
        double durMs = (distT / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        PTTestShowDot(from, to, YES, durMs / 1000.0);
        double durSec = MAX(durMs / 1000.0, 0.001);
        int token = gExecToken;   // v1.0.66-fix：捕获本次令牌，中断上一段测试手势用
        __block NSInteger pid = -1;
        __block CGPoint lastP = from;   // 中止时在最后已知位置抬手，避免粘手
        __block void (^stillAt)(CGPoint, int);
        stillAt = ^(CGPoint pos, int ms) {
            __block int n = MAX(ms, 0) / 16;
            __block void (^still)(void);
        still = ^(void) {
            if (token != gExecToken) {   // v1.0.66-fix：被新手势中断 → 抬手收尾
                if (pid >= 0) [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseEnded];
                if (next) next();
                return;
            }
            if (n <= 0) {
                [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseEnded];
                if (next) next();
                return;
            }
                n--;
                [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
            };
            still();
        };
        __block CFAbsoluteTime t0;
        __block void (^step)(void);
        step = ^(void) {
            if (token != gExecToken) {   // v1.0.66-fix：被新手势中断 → 在最后位置抬手收尾
                if (pid >= 0) [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
                if (next) next();
                return;
            }
            double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
            if (t >= 1.0) {
                if (noInertia) {
                    stillAt(to, MAX(liftMs, 300));
                } else {
                    if (liftMs > 0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                            if (next) next();
                        });
                    } else {
                        [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                        if (next) next();
                    }
                }
                return;
            }
            CGPoint pp = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
            lastP = pp;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pp withTouchPhase:UITouchPhaseMoved];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }   // v1.0.66-fix：已中断则不落新手势
            pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                if (token != gExecToken) { if (pid >= 0) [PTFakeMetaTouch fakeTouchId:pid AtPoint:from withTouchPhase:UITouchPhaseEnded]; if (next) next(); return; }
                t0 = CFAbsoluteTimeGetCurrent();
                step();
            });
        });
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.13：测试区支持滑动(手动)回放——此前缺分支被 else 跳过，注入轨迹看不到
        // v1.0.20：补上测试页轨迹可视化——绿点沿录制起点→终点移动，时长对齐录制耗时，
        // 否则测试本方案里滑动(手动)虽正常注入、却看不到轨迹（与「滑动」类型表现一致）。
        NSArray *pts = a[@"pts"];
        if (pts.count) {
            CGPoint from = CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]);
            CGPoint to = CGPointMake([pts[pts.count - 1][@"x"] doubleValue], [pts[pts.count - 1][@"y"] doubleValue]);
            double t0 = [pts[0][@"t"] doubleValue];
            double t1 = [pts[pts.count - 1][@"t"] doubleValue];
            PTTestShowDot(from, to, YES, MAX(t1 - t0, 50) / 1000.0);
        }
        PTFakeRecSwipeAsync(pts, gExecToken, (double)gSwipeBurstRate, next);   // v1.0.67：测试页同样支持连滑档位(1/2/3)
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// 测试页命中方案：连滑判定 + 起执行/续档/刹停。
// v1.0.72 起与运行端共用 PTChainOnHit（文件末尾）——此前两处各写一份，已两次漂移：
//   · v1.0.71：设置页侧旧版无连滑逻辑（靠抽 PTChainHandleHit 对齐）；
//   · v1.0.72：蓄力窗口只认"回放中"，测试区执行期按键又被 hook 无条件吞掉（Bug 1），
//     连滑计数永远停在 1——提示"连滑 1/5"却一次只有一个动作。
// v1.0.74：入参 name → planId（方案 pid，PTTestMatchFeature 的返回值）。
static void PTTestExecPlan(NSString *planId) {
    PTChainOnHit(planId, YES);   // viaTest=YES：额外过测试页 0.3s 防抖（sLastTestExec）
}

// 测试模式：Ended 结算 → 匹配 → 执行
void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *planId = PTTestMatchFeature(phase, dir, dist, sender, tapDx);
    if (planId) {
        NSString *pname = PTPlanNameForId(planId);
        PTDylibLog(@"[测试] 特征匹配 → 方案「%@」", pname);
        PTTestExecPlan(planId);
        // v1.0.74：按 pid 数动作条数（旧为按 name——重名时数到的是另一条记录）。
        // gPlans 查不到再退回实时配置（测试链路读实时 cfg，缓存可能未刷新）。
        NSDictionary *pp = gPlans[planId];
        if (!pp) {
            NSArray *plans = PTDylibReadCfg()[@"plans"] ?: @[];
            for (NSUInteger i = 0; i < plans.count; i++) {
                NSDictionary *p = plans[i];
                if ([p isKindOfClass:[NSDictionary class]] && [PTPlanPid(p, (NSInteger)i) isEqualToString:planId]) { pp = p; break; }
            }
        }
        if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) {
            [sTestLogSink appendLog:[NSString stringWithFormat:@"✓ 命中「%@」→ 映射 %lu 条动作（sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d）",
                pname, (unsigned long)(pp[@"actions"] ? [pp[@"actions"] count] : 0), sender, phase, dir, dist, tapDx]];
        }
    } else {
        PTDylibLog(@"[测试] 未匹配：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d（特征需先录制）", sender, phase, dir, dist, tapDx);
        if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) {
            [sTestLogSink appendLog:[NSString stringWithFormat:@"✗ 未命中（放行）：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d",
                sender, phase, dir, dist, tapDx]];
        }
        if ([sTestLogSink respondsToSelector:@selector(drawTrailWithDirection:dist:phase:)]) {
            [sTestLogSink drawTrailWithDirection:dir dist:dist phase:phase];
        }
        // v1.0.73：未命中 = 退出连滑 + 立刻停在飞动作（与运行端 PTHandlePagerEvent 共用 PTChainMiss，
        // 旧实现此处什么都不做 → 测试页连滑中按到没录入的键仍继续连滑，与 App 内不一致）
        PTChainMiss();
    }
}
