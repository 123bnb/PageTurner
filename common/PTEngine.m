// ============================================================
// PTEngine.m —— PageTurner 引擎外壳（v1.0.71 拆分后）
//
// 本文件只保留「外壳」职责：hook 装配、运行拦截会话、调试可视化、手动录制、双指菜单。
// 核心逻辑（配置/匹配/学习样本/测试回放/连滑状态机/动作执行/日志）已全部移至
// common/PTEngineCore.m，经 PTEngineCore.h 以 extern 跨文件共享——三个编译目标
// （deb / dylib / Preferences）都链接 Core，但只有 deb 与 dylib 链接本外壳。
//
// 与拆分前（PTEngine.m 1700 行单文件）的行为差异：
//   · PTHandlePagerEvent 命中分支改调 Core 的 PTChainHandleHit（连滑状态机与测试页
//     共用同一份实现，修掉设置页侧曾漂移的「无连滑刹停/无倍速」问题）；
//   · sTestInjecting 删除（从未被赋值，恒为 NO 的死状态，读取处等价于 gInFakeTouch||gIsInjecting）；
//   · PTDylibInstallHooks 不再调 PTDylibLogRefreshCfg（PTDylibLog 每次入口已自行按 mtime 同步）；
//   · gInjectSender 实体移至 Core（ Compat.h extern 的唯一供给方，避免双定义链接错误）。
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/time.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <unistd.h>
#import "ptftouch/PTFakeMetaTouch.h"
#import "PTEngine.h"

// ============================================================
// dylib target 真符号的弱桩（roothide/deb 构建链接兜底）
// ============================================================
// v1.0.57：下列符号由 dylib target（PTDylibMain/PTDylibUI）提供「真实现」，此处给弱桩，
// 保证 roothide（deb）构建也能链接通过；dylib 构建时其强定义覆盖这些桩。
// 双指菜单 / 录制覆盖层 UI 是 dylib 专属，roothide 用 PreferenceLoader 设置页，不会触发。
__attribute__((weak)) void PTDylibShowMenu(void) {}
__attribute__((weak)) void PTDylibCloseMenu(void) {}
__attribute__((weak)) BOOL PTDylibIsMenuWindow(UIWindow *w) { return NO; }
// roothide 不装双指长按菜单（用系统设置页），dylib 注入后开启（PTDylibInstallHooks 内置 YES）
static BOOL gGestureMenuEnabled = NO;

// ============================================================
// 调试可视化（绿点 + 轨迹；只画 App 实际收到的触摸）
// ============================================================
@interface PTDebugDot : NSObject
@property (nonatomic) CGPoint pos;
@property (nonatomic) BOOL pager;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) NSMutableArray *trail;
@end
@implementation PTDebugDot
- (instancetype)initWithPoint:(CGPoint)p pager:(BOOL)pg parentView:(UIView *)pv {
    self = [super init];
    if (self) {
        _pos = p; _pager = pg;
        _trail = [NSMutableArray array];
        [_trail addObject:[NSValue valueWithCGPoint:p]];
        _dotView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        _dotView.center = p;
        _dotView.layer.cornerRadius = 22;
        _dotView.layer.borderWidth = 2;
        _dotView.layer.borderColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.8].CGColor;
        _dotView.backgroundColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.85];
        if (pg) {
            UILabel *lb = [[UILabel alloc] initWithFrame:_dotView.bounds];
            lb.text = @"P";
            lb.font = [UIFont boldSystemFontOfSize:20];
            lb.textColor = [UIColor blackColor];
            lb.textAlignment = NSTextAlignmentCenter;
            [_dotView addSubview:lb];
        }
        _trailLayer = [CAShapeLayer layer];
        _trailLayer.strokeColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.7].CGColor;
        _trailLayer.fillColor = [UIColor clearColor].CGColor;
        _trailLayer.lineWidth = 4;
        _trailLayer.lineCap = kCALineCapRound;
        [pv.layer addSublayer:_trailLayer];
        [pv addSubview:_dotView];
    }
    return self;
}
- (void)moveTo:(CGPoint)p {
    _pos = p;
    _dotView.center = p;
    [_trail addObject:[NSValue valueWithCGPoint:p]];
    if (_trail.count > 80) [_trail removeObjectAtIndex:0];
    CGMutablePathRef path = CGPathCreateMutable();
    BOOL first = YES;
    for (NSValue *v in _trail) {
        CGPoint q = v.CGPointValue;
        if (first) { CGPathMoveToPoint(path, NULL, q.x, q.y); first = NO; }
        else CGPathAddLineToPoint(path, NULL, q.x, q.y);
    }
    _trailLayer.path = path;
    CGPathRelease(path);
}
- (void)fadeOut {
    [_dotView.layer removeAllAnimations];
    [UIView animateWithDuration:0.5 animations:^{
        _dotView.alpha = 0.15;
    } completion:^(BOOL f) {
        [_dotView removeFromSuperview];
    }];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.toValue = @(0.0);
    fade.duration = 0.5;
    fade.removedOnCompletion = NO;
    fade.fillMode = kCAFillModeForwards;
    [_trailLayer addAnimation:fade forKey:@"fade"];
}
@end

static UIView *gDotOverlay = nil;   // v1.0.12：可视化改为 keyWindow 上的覆盖层 view（不建独立窗口）
static NSMutableDictionary *gDotViews = nil;

// v1.0.12：可视化不再用独立 UIWindow——独立窗口存在就会参与系统状态栏样式计算
// （时间/信号电量变白根因）。改为直接叠加在当前 keyWindow 上的透明 view，
// 零窗口参与状态栏判定，状态栏彻底归系统/App 管。keyWindow 变化时由通知迁移。
static void PTDebugEnsureOverlay(void) {
    if (gDotOverlay) return;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    UIView *ov = [[UIView alloc] initWithFrame:kw.bounds];
    ov.userInteractionEnabled = NO;
    ov.backgroundColor = [UIColor clearColor];
    [kw addSubview:ov];
    gDotOverlay = ov;
    gDotViews = [NSMutableDictionary dictionary];
}

// v1.0.7：可视化开关关掉时销毁（不再永驻影响状态栏）。
// v1.0.71：改非静态——Core（PTDylibLoadConfig）以弱引用调用；Preferences 只链 Core 时为 NULL。
void PTDebugDestroyOverlay(void) {
    [gDotOverlay removeFromSuperview];
    gDotOverlay = nil;
    gDotViews = nil;
}

// v1.0.12：keyWindow 变化时把覆盖层迁到新窗口（旧覆盖层移除重建）
void PTDebugMigrateOverlay(void) {
    if (!gDotOverlay) return;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    if (gDotOverlay.superview == kw) return;
    PTDebugDestroyOverlay();
    PTDebugEnsureOverlay();
}

static void PTDebugUpdate(void *touchPtr, CGPoint p, UITouchPhase phase, BOOL pager) {
    if (!gDebugDots) return;
    if (![NSThread isMainThread]) return;
    PTDebugEnsureOverlay();
    if (!gDotOverlay) return;
    NSString *key = [NSString stringWithFormat:@"%p", touchPtr];
    PTDebugDot *dot = gDotViews[key];
    if (phase == UITouchPhaseBegan) {
        if (dot) return;
        dot = [[PTDebugDot alloc] initWithPoint:p pager:pager parentView:gDotOverlay];
        gDotViews[key] = dot;
    } else if (phase == UITouchPhaseMoved) {
        if (dot) [dot moveTo:p];
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        if (dot) {
            [dot moveTo:p];
            [dot fadeOut];
            [gDotViews removeObjectForKey:key];
        }
    }
}

// ============================================================
// 手动滑动录制开关（v1.0.8 起录制改为覆盖层 UIPanGestureRecognizer 抓取，
// 见 PTDylibUI.m 的 PTRecOnPan / PTOverlayPage；此处仅保留开关 + 回调槽）
// ============================================================
static BOOL gRecArmed = NO;                 // 录制覆盖层打开（v1.0.62 起由 common/PTOverlayPage 经 PTRecStart/PTRecStop 控制）
static void (^gRecDone)(NSArray *) = nil;    // 录制完成回调（UI 传入；UI 端用同块 gRecDoneUI）

void PTRecStart(NSString *mode, double topY, void (^done)(NSArray *pts)) {
    gRecArmed = YES;
    gRecDone = done;
}

void PTRecStop(void) {
    gRecArmed = NO;
    gRecDone = nil;
}

// ============================================================
// 运行拦截会话（已学 sender 的原始滑动整段吞掉：命中执行 / 未命中重放）
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
static NSMutableArray *gSessTrail = nil;

static uint64_t gCurSender = 0;
static double gPagerWindowUntil = 0;

static void PTReplayTrailAsync(void);

// 返回 YES = 吞（命中：防 App 同时收到翻页器滚动）；NO = 放行
static BOOL PTHandlePagerEvent(UIEvent *event) {
    if (![event respondsToSelector:@selector(allTouches)]) return NO;
    if (!PTIsLearnedSender(gCurSender)) return NO;
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
            gSessTrail = [NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:p]];
            return YES;
        }
        case UITouchPhaseMoved: {
            if (!gSession.active) return NO;
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
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            return YES;
        }
        case UITouchPhaseEnded: {
            if (!gSession.active) return NO;
            gSession.active = NO;
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            PagerFeature f;
            f.phase = (gSession.totalDist < kTapDistThreshold) ? 0 : 1;
            f.direction = gSession.hasMove ? gSession.firstMoveDir : 0;
            f.dist = gSession.totalDist;
            {
                double sx = gSession.start.x, ex = p.x;
                double dxv = ex - sx;
                f.tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
            }
            // v1.0.74：PTMatchPlan 返回值即方案 pid（引擎 gPlans 按 pid 索引，重名方案
            // 是两条独立记录，按 name 走会互相覆盖/串台）
            NSString *planId = PTMatchPlan(f, gCurSender);
            if (planId) {
                gSessTrail = nil;
                // v1.0.71：连滑判定（蓄力/升档/刹停）+ 起执行已抽至 Core 的 PTChainHandleHit，
                // 与测试页 PTTestExecPlan 共用同一套连滑状态机（修掉设置页侧旧版无连滑逻辑的漂移）。
                PTChainHandleHit(planId);
                return YES;
            }
            // v1.0.73：未命中 = 退出连滑 + 立刻停在飞动作（旧为 PTChainReset，只清链、动作照常播完）
            PTChainMiss();
            PTDylibLog(@"[会话] 未命中：sender=0x%llx phase=%d dir=%.1f dist=%.1f → 重放轨迹放行",
                gCurSender, f.phase, f.direction, f.dist);
            PTReplayTrailAsync();
            return YES;
        }
        case UITouchPhaseCancelled:
            gSession.active = NO;
            gSessTrail = nil;
            return NO;
        default:
            return NO;
    }
}

// 未命中：暂存轨迹重放给 App
static void PTReplayTrailAsync(void) {
    if (!gSessTrail || gSessTrail.count < 2) { gSessTrail = nil; return; }
    NSArray *pts = [gSessTrail copy];
    gSessTrail = nil;
    NSUInteger n = pts.count;
    // v1.0.18：回放「未命中」的原始轨迹时必须保持足够点密度，否则 UIScrollView 在
    // 两点之间收不到 Moved 事件而阶梯跳变（卡顿）。原先 k = MIN(n - 2, 10) 把轨迹
    // 砍到最多 10 个中间点 —— 这里改为全量回放原始采样点，密度跟随录制轨迹。
    CGPoint from = [pts.firstObject CGPointValue];
    CGPoint to = [pts.lastObject CGPointValue];
    NSMutableArray *mids = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 1; i < n - 1; i++) [mids addObject:pts[i]];

    // v1.0.73：保存旧值——重放与"在飞的方案回放"会并发（执行中按到没录入的键即走到这里），
    // 旧实现结束时硬置 NO，会把仍在跑的方案回放的注入标记提前清掉。
    BOOL prevInjecting = gIsInjecting;
    gIsInjecting = YES;
    gInFakeTouch = YES;
    // v1.0.73：动态分配 pointId（旧为硬编码 1）。方案回放（PTRunAction）也固定占用 touchAry[0]，
    // 两个序列共用一个 UITouch 会互相串台 → 滑动诡异中断 / 手势错乱 / 偶发不抬手。
    // getAvailablePointId 只把 phase==Ended/Stationary 的槽位当作空闲，故天然避开忙碌的 0 号槽。
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:0 AtPoint:from withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    if (pid <= 0) {   // 极端：pointId 全部被占用 → 放弃重放，恢复原状态（不留下脏标记）
        gIsInjecting = prevInjecting;
        return;
    }
    // v1.0.18：按屏幕刷新节奏（~60Hz，16.6ms/点）逐点推进，密度接近真实手指，
    // 不再把整段滑动压缩进 ~120ms。宗旨不变：未命中时仍把原始轨迹还原给 App。
    static const double kReplayStepSec = 1.0 / 60.0;
    __block NSUInteger i = 0;
    __block void (^step)(void);
    step = ^(void) {
        if (i >= mids.count) {
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            gIsInjecting = prevInjecting;   // v1.0.73：恢复而非硬置 NO
            PTDylibLog(@"[重放] 未命中：原始轨迹已重放给 App（%lu 点）", (unsigned long)mids.count);
            return;
        }
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:[mids[i] CGPointValue] withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        i++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReplayStepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReplayStepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

// ============================================================
// 合并 hook（学习/测试采集 + 运行拦截，同一对方法）
// ============================================================
static IMP gOrigAddEvent = NULL;
static IMP gOrigSendEvent = NULL;
// v1.0.57：拦截开关由 target 注入——roothide 按总开关+指定App 决定；dylib 注入即生效恒 YES
static BOOL gInterceptEnabled = NO;
void PTSetInterceptEnabled(BOOL b) { gInterceptEnabled = b; }
void PTSetOrigAddEvent(IMP o) { gOrigAddEvent = o; }
void PTSetOrigSendEvent(IMP o) { gOrigSendEvent = o; }

void PTDylibAddEvent(id self, SEL _cmd, void *event) {
    // v1.0.57：未启用拦截（roothide：总开关关 / 非指定App）→ 直接放行原始事件
    if (!gInterceptEnabled) {
        if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
        return;
    }
    PTDylibLoadConfig(NO);
    if (event && pGetSender && pGetType) {
        uint32_t type = pGetType(event);
        uint64_t sender = pGetSender(event);
        if (type == 11) {
            gCurSender = sender;      // 运行端
            sCurSender = sender;      // 采集端
            if (sCollectArmed || sTestArmed) sWindowUntil = PTNowC() + kCollectWindowSec;
            if (PTIsLearnedSender(sender)) {
                double dx = pGetFloat ? pGetFloat(event, 0x23) : 0;
                double dy = pGetFloat ? pGetFloat(event, 0x24) : 0;
                PTDylibLog(@"[addEvent] 已学 sender=0x%llx → 会话通道（HID 位移观察 dx=%.2f dy=%.2f）", sender, dx, dy);
                gPagerWindowUntil = PTNowC() + kPagerWindowSec;
            }
        }
    }
    if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

// v1.0.12：sendEvent 层双指长按检测——两指同时按下 0.5s 不动 → 弹菜单。
// sendEvent 是 App 所有触摸必经之路，任何页面/角落都能触发，不被 App 手势仲裁抢。
// 菜单窗口上的触摸不算；手指位移 >25pt 视为移动取消该指。
static NSMutableDictionary *gFingers = nil;
static BOOL gGestureFired = NO;

static void PTDylibGestureTick(UIEvent *event) {
    if (!event) return;
    if (gRecArmed || gInFakeTouch || gIsInjecting) return;   // v1.0.12：录制/注入中不触发双指
    if (!gFingers) gFingers = [NSMutableDictionary dictionary];
    for (UITouch *t in event.allTouches) {
        if (!t.window) continue;
        if (PTDylibIsMenuWindow(t.window)) continue;   // 菜单窗口上的触摸不参与
        NSString *key = [NSString stringWithFormat:@"%p", t];
        if (t.phase == UITouchPhaseBegan) {
            CGPoint p = [t locationInView:t.window];
            gFingers[key] = @{@"t": @(CACurrentMediaTime()), @"x": @(p.x), @"y": @(p.y)};
        } else if (t.phase == UITouchPhaseMoved) {
            NSDictionary *f = gFingers[key];
            if (f) {
                CGPoint p = [t locationInView:t.window];
                CGFloat dx = p.x - [f[@"x"] doubleValue], dy = p.y - [f[@"y"] doubleValue];
                if (dx * dx + dy * dy > 25.0 * 25.0) [gFingers removeObjectForKey:key];
            }
        } else if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) {
            [gFingers removeObjectForKey:key];
        }
    }
    if (gFingers.count >= 2 && !gGestureFired) {
        double now = CACurrentMediaTime();
        BOOL allHold = YES;
        for (NSDictionary *f in gFingers.allValues) {
            if (now - [f[@"t"] doubleValue] < 0.5) { allHold = NO; break; }
        }
        if (allHold) {
            gGestureFired = YES;
            PTDylibShowMenu();
        }
    } else if (gFingers.count == 0) {
        gGestureFired = NO;
    }
}

void PTDylibSendEvent(id self, SEL _cmd, UIEvent *event) {
    // v1.0.57：未启用拦截 → 直接放行原始事件
    if (!gInterceptEnabled) {
        if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    PTDylibLoadConfig(NO);
    // v1.0.12：双指长按检测（最前面，任何触摸都能触发）——仅 dylib 开启（roothide 用设置页）
    if (gGestureMenuEnabled) PTDylibGestureTick(event);
    // v1.0.66(#2)：调试绿点绘制移到「交付 App 之前」（见下方各交付分支），命中被吞的翻页器原始轨迹不再画点，
    // 只显示映射注入轨迹；未命中放行/注入态的触摸在各自交付处补画。
    // v1.0.20：已删除「sendEvent 钩子全局采集录制」——旧版录制覆盖层穿透到 App、靠全局 sendEvent 抓真实触摸。
    // 现改为覆盖层 UIPanGestureRecognizer 直接抓轨迹（见 PTDylibUI.m PTRecOnPan），不再在此处采集。
    // gRecArmed 仍保留（上方双指检测等处用其排除录制态）。
    // 注入触摸/执行中：放行（注入触摸没有 addEvent、sender 残留翻页器，走拦截会把映射触摸 Began 吞掉）
    if (gInFakeTouch || gIsInjecting) {
        // v1.0.66-fix：飞快势途中用户又按翻页器 → 该真实触摸不在 PTFakeMetaTouch 注入池中，
        // 放行到下方运行拦截(匹配/连滑/中断)；本次注入的假触摸(在池中)仍按原逻辑放行给 App。
        BOOL realPagerDuringInject = NO;
        if (gIsInjecting && !gInFakeTouch && event &&
            [event respondsToSelector:@selector(allTouches)]) {
            for (UITouch *t in event.allTouches) {
                if (![PTFakeMetaTouch isPoolTouch:t]) { realPagerDuringInject = YES; break; }
            }
        }
        if (!realPagerDuringInject) {
            if (gDebugDots && event) {   // v1.0.66(#2)：映射注入触摸照常画点（pager=NO），保证命中时可见的是映射轨迹而非翻页器原始轨迹
                for (UITouch *t in event.allTouches) {
                    CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                    PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
                }
            }
            if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
            return;
        }
        // realPagerDuringInject=YES → 不 return，继续走到下方运行拦截，让这次真实按键进入会话匹配
    }
    // 学习/测试激活：只采集放行，不拦截（即使按的是已学 sender 也不吞）
    if ((sCollectArmed || sTestArmed) && event && PTNowC() < sWindowUntil) {
        NSSet *touches = [event respondsToSelector:@selector(allTouches)] ? event.allTouches : nil;
        UITouch *t = [touches anyObject];
        if (t && pGetSender) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            switch (t.phase) {
                case UITouchPhaseBegan: {
                    sSessActive = YES; sSessDist = 0; sSessHasMove = NO; sSessFirstDir = 0;
                    sSessLast = p;
                    sSessStart = p;
                    break;
                }
                case UITouchPhaseMoved: {
                    if (sSessActive) {
                        double dx = p.x - sSessLast.x, dy = p.y - sSessLast.y;
                        double seg = hypot(dx, dy);
                        if (seg > 0) {
                            sSessDist += seg;
                            if (!sSessHasMove && sSessDist > 5) {
                                sSessHasMove = YES;
                                sSessFirstDir = atan2(dy, dx) * 180.0 / M_PI;
                            }
                        }
                        sSessLast = p;
                    }
                    break;
                }
                case UITouchPhaseEnded: {
                    if (sSessActive) {
                        sSessActive = NO;
                        int phase = (sSessDist < kTapDistThreshold) ? 0 : 1;
                        double dir = sSessHasMove ? sSessFirstDir : 0;
                        int tapDx = 0;
                        {
                            double dxv = p.x - sSessStart.x;
                            tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
                        }
                        if (sTestArmed) PTTestOnEnded(phase, dir, sSessDist, sCurSender, tapDx);
                        else PTSampleAppend(phase, dir, sSessDist, tapDx);
                    }
                    break;
                }
                case UITouchPhaseCancelled: sSessActive = NO; break;
                default: break;
            }
        }
        if (gDebugDots && event) {   // v1.0.66(#2)：学习/测试期 App 真实收到的触摸照常画点
            for (UITouch *t in event.allTouches) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
            }
        }
        if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    // 运行拦截：已学 sender 会话/窗口内 → 整段吞（命中执行/未命中重放），App 不收到原始触摸
    if (event && (PTNowC() < gPagerWindowUntil || gSession.active)) {
        if (PTHandlePagerEvent(event)) return;
    }
    // v1.0.67：DVT 式连滑无"超时被动刹停"——链只在异方案/退后台/关开关时清（见 PTChainHandleHit / 生命周期）。
    // 进连滑后自动无限续滑（无需再按键），直到异方案刹停或退后台。
    // 诊断：非注入触摸会话 Began 打一行 sender
    if (event) {
        for (UITouch *t in event.allTouches) {
            if (t.phase == UITouchPhaseBegan) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                PTDylibLog(@"[touch] sender=0x%llx phase=Began pos=(%.1f,%.1f)", gCurSender, p.x, p.y);
            }
        }
    }
    if (gDebugDots && event) {   // v1.0.66(#2)：最终交付 App 的触摸画点（含未命中放行的翻页器原始触摸）
        for (UITouch *t in event.allTouches) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
        }
    }
    if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

// hook 装配（dylib 用：method_getImplementation + method_setImplementation，无 ellekit）
void PTDylibInstallHooks(void) {
    static dispatch_once_t on;
    dispatch_once(&on, ^{
        @autoreleasepool {
            // v1.0.71：删 PTDylibLogRefreshCfg 调用——PTDylibLog 每次入口已按 mtime 自行同步
            // 调试日志开关（v1.0.65 修复），启动多种子一次属冗余。
            PTDylibInitIOKit();
            gInterceptEnabled = YES;  // dylib 注入即生效（roothide 由 target 按总开关+指定App 决定）
            gGestureMenuEnabled = YES;  // dylib：开启双指长按菜单
            Class addCls = NSClassFromString(@"_UIUpdateHIDDigitizerInput");
            if (!addCls) {
                // v1.0.19：私有类不存在（当前 iOS 版本可能已改名）→ 拦截完全失效，必须醒目提示
                NSLog(@"[PageTurnerDylib][严重] 核心钩子失败：私有类 _UIUpdateHIDDigitizerInput 不存在，翻页器输入拦截将完全失效（当前 iOS 可能已改名该私有类）。");
                PTDylibLog(@"[严重][核心钩子] 私有类 _UIUpdateHIDDigitizerInput 不存在 → 拦截失效");
            }
            SEL addSel = sel_registerName("addEvent:");
            Method am = addCls ? class_getInstanceMethod(addCls, addSel) : NULL;
            if (addCls && !am) {
                NSLog(@"[PageTurnerDylib][严重] 核心钩子失败：_UIUpdateHIDDigitizerInput 缺少 addEvent: 方法，翻页器输入拦截将完全失效。");
                PTDylibLog(@"[严重][核心钩子] _UIUpdateHIDDigitizerInput 缺少 addEvent: 方法 → 拦截失效");
            }
            if (am) { gOrigAddEvent = method_getImplementation(am); method_setImplementation(am, (IMP)PTDylibAddEvent); }

            Class appCls = NSClassFromString(@"UIApplication");
            SEL sendSel = sel_registerName("sendEvent:");
            Method sm = appCls ? class_getInstanceMethod(appCls, sendSel) : NULL;
            if (sm) { gOrigSendEvent = method_getImplementation(sm); method_setImplementation(sm, (IMP)PTDylibSendEvent); }

            BOOL ok = (gOrigAddEvent != NULL && gOrigSendEvent != NULL && pGetType != NULL && pGetSender != NULL);
            PTDylibLog(@"PTDylibInstallHooks: ok=%d addEvent=%d sendEvent=%d getType=%d getSender=%d",
                ok, gOrigAddEvent != NULL, gOrigSendEvent != NULL, pGetType != NULL, pGetSender != NULL);
            if (!ok) {
                // v1.0.19：单点失败兜底——任一核心符号缺失都导致功能静默失效，强制进 syslog 让用户可见
                NSLog(@"[PageTurnerDylib][严重] PTDylibInstallHooks 部分失败 ok=%d（addEvent=%d sendEvent=%d getType=%d getSender=%d）。翻页器拦截可能不工作，请核对当前 iOS 版本与私有 API 兼容性！",
                    ok, gOrigAddEvent != NULL, gOrigSendEvent != NULL, pGetType != NULL, pGetSender != NULL);
                PTDylibLog(@"[严重][核心钩子] 安装部分失败 ok=%d → 拦截可能不工作，核对 iOS 私有 API 兼容性", ok);
            }
        }
    });
}
