// ============================================================
// PTEngineVolume.m —— 音量键机制（v1.0.80 新增）
//
// 整套移植 DirectVolumeTap v1.0.18~v1.0.22 音量基线（用户定稿「按了就是按了」：
// 无 hold / 无 double-tap 判定——iOS 音量键按住不放不产生新 delta，物理层
// 就没有「按住」语义；连按才多次，每次经去抖 + 双保险过滤后逐次触发）。
//
// 与 DVT 的差异（PageTurner 侧适配）：
//   · 触发目标不是 DVT 自己的 swipe/tap 回放，而是汇入 PageTurner 连滑状态机
//     PTChainOnHit（v1.0.67 起该状态机即 1:1 移植自 DVT v1.0.22 的音量键连滑，
//     「方向」→「方案」）——音量键 = 翻页器公民，连滑/升档/刹停/续滑全链路平权；
//   · delta 估算分治：序列含 swipe/recSwipe → n 恒 1（对齐 DVT 滑动模式
//     「一次触发一次回放」）；纯 tap 类才估算 n（1~8 封顶，连按合并也逐页翻）；
//   · 生效门控：masterEnabled + 本 App 勾选（与翻页器拦截同门控，由 target
//     入口决定调不调 PTVolumeStart）+ volEnabled 总闸（配置层，默认关）；
//     SpringBoard 天然旁路（不在勾选列表，符合 DVT「不注入 SB」结论）。
//
// 机制清单（DVT 实证结论，逐条对应其源码行）：
//   · KVO AVAudioSession.outputVolume（不 hook UIApplication 吞键——系统音量在
//     SpringBoard/音频守护进程的 App 进程外改写，UIKit 事件层处于下游，吞键无效，
//     DVT 1215-1217 行注释实锤）；
//   · 前台 setCategory:Ambient + setActive:YES（会话不激活 KVO 不触发，
//     DVT v1.0.15/16 事故实证）；退后台 setActive:NO（不保活，后台零音频痕迹）；
//   · 徘徊：启动/进前台对齐 1/16，随按键真实移动，>12/16 或触底 → 50ms 弹回
//     1/16（不钉死 0.5——DVT v1.0.18 替代方案）；
//   · 自我触发双保险：新值≈1/16 不触发；旧值越界且新值≈1/16 是插件拉的，不触发；
//   · 100ms 去抖（只合并单次按键的重复 KVO，不吞有意连按——DVT 1050-1052 注释）；
//   · HUD 抑制：离屏 MPVolumeView 挂 key window；写回 = slider setValue +
//     AVSystemController setVolumeTo:forCategory:（iOS 16.5 单参 API 已不存在，
//     必须 NSInvocation 传双参——DVT 1101-1103 注释）；
//   · 前台闸：applicationState != Active 忽略（后台回调也不影响其他 App 音量）。
// ============================================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "PTEngineCore.h"
#import "PTEngineInternal.h"
#import "PTEngineVolume.h"

// ---------- 常量（数值型统一宏在 PTCoreLogic.h：kVolStep/kVolMaxBurst/kVolBoundHigh/
// kVolBoundLow 随 PTVolEstimateCount/PTVolNeedsReset 下沉纯逻辑层，v1.0.80 #37）；
// 此处只留本文件私有 ----------
static const float kVolRest      = 1.0f / 16.0f;   // 徘徊目标 1/16
static const double kVolDebounce = 0.10;           // 去抖窗（DVT kTapDebounceSec）
static const float  kVolJitter   = 0.0005f;        // 抖动过滤阈值

BOOL gVolEnabled   = NO;    // 音量键模式总开关（volEnabled，默认关）——PTDylibLoadConfig 读写
BOOL gVolHudHidden = YES;   // 隐藏系统音量条（volHudHidden，默认开）——PTDylibLoadConfig 读写

@class PTVolumeObserver;    // 前向声明（@interface 在本文件下方——KVO 观察者要按真实类型持有，
                            // 否则 [gVolObs ptAppDidBecomeActive] 过不了 NSObject 静态类型检查）

static PTVolumeObserver *gVolObs = nil;   // KVO + 前后台通知观察者
static BOOL             gVolRunning = NO;   // 机制已注册（幂等）
static CFAbsoluteTime   gVolLastTap = 0;    // 去抖时间戳（DVT gLastTap）
static MPVolumeView    *gVolView     = nil; // 离屏 MPVolumeView（HUD 抑制）

// ============================================================
// 系统音量写回（HUD 抑制下的隐身通道）
// ============================================================
static void PTVolSetSystemVolume(float v) {
    @try {
        // HUD 隐藏模式下若 MPVolumeView 尚未挂载（冷启动窗口未就绪），临时建一个
        // （DVT SetSystemVolume 同款守卫：显示模式不建——建了就等于抑制 HUD）
        if (!gVolView && gVolHudHidden) {
            gVolView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 0, 0)];
            UIWindow *w = [UIApplication sharedApplication].keyWindow;
            if (w) [w addSubview:gVolView];
        }
        // 通道一：离屏 MPVolumeView 内部 slider（旧版主通道，保留）
        if (gVolView) {
            for (UIView *sub in gVolView.subviews) {
                if ([sub isKindOfClass:[UISlider class]]) {
                    [(UISlider *)sub setValue:v animated:NO];
                    break;
                }
            }
        }
        // 通道二：AVSystemController setVolumeTo:forCategory:（iOS 16.5 单参版
        // 已不存在，float 参数必须 NSInvocation 正确传递——DVT 1101-1103 实锤）
        Class c = NSClassFromString(@"AVSystemController");
        if (c) {
            id controller = [c performSelector:NSSelectorFromString(@"sharedAVSystemController")];
            SEL sel = NSSelectorFromString(@"setVolumeTo:forCategory:");
            if (controller && [controller respondsToSelector:sel]) {
                NSMethodSignature *sig = [controller methodSignatureForSelector:sel];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:sel];
                    [inv setTarget:controller];
                    float fv = v;
                    [inv setArgument:&fv atIndex:2];
                    NSString *cat = @"Audio/Video";
                    [inv setArgument:&cat atIndex:3];
                    [inv invoke];
                }
            }
        }
    } @catch (NSException *e) {}
}

// ============================================================
// HUD 抑制：离屏 MPVolumeView 挂/摘
// ============================================================
static void ApplyVolumeHudHidden(BOOL hidden) {
    if (hidden) {
        if (!gVolView) gVolView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 0, 0)];
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w && !gVolView.superview) [w addSubview:gVolView];
    } else {
        if (gVolView) { [gVolView removeFromSuperview]; gVolView = nil; }
    }
}

void PTVolumeApplyHud(BOOL hidden) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApplyVolumeHudHidden(hidden); });
}

// ============================================================
// 徘徊（v1.0.18 方案，替代「钉死 0.5」）：不钉死，音量随按键真实移动；
// 仅超过 12/16 或触底时，50ms 延迟弹回 1/16（避开同帧竞态——DVT v1.0.8 同款）
// ============================================================
static void DoReset(float oldVol, float nowVol) {
    if (PTVolNeedsReset(nowVol) || PTVolNeedsReset(oldVol)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PTVolSetSystemVolume(kVolRest); });
    }
}

// ============================================================
// 音频会话（KVO 触发的必要条件——会话不激活则 outputVolume 不回调）
// ============================================================
static void PTVolActivateSession(void) {
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&err];
    // 无条件激活（DVT v1.0.15/16 曾误将本行塞进 if (err) 体导致映射全失效，勿再改回去）
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
}

static void PTVolDeactivateSession(void) {
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&err];
}

// ============================================================
// 单次音量键 → 汇入连滑状态机（去抖 + 估算 + 逐次派发）
// 派发目标 = PTChainHandleHitVolume → PTChainOnHit（与翻页器滑动命中
// 完全同一入口）：起播/续滑/升档/刹停/未命中由状态机按 pid 原样裁定。
// 同步 for 循环派发 n 次（DVT 1069 同款）：第 1 次起播后 gExecRunning=YES，
// 后续次数走「回放中累计」路径——与真实连按 5 次进连滑的行为逐字一致。
// （估算函数本体在 PTCoreLogic.m——纯判定，见其头注释；v1.0.80 #37 下沉）
// ============================================================
static void PTVolTapPoints(float delta) {
    // 整体上主队列：KVO 回调线程不定，而 PTChainOnHit/pill/状态机全局均要求主线程
    dispatch_async(dispatch_get_main_queue(), ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - gVolLastTap < kVolDebounce) return;   // 100ms 窗内的重复 KVO 合并（不吞有意连按）
        gVolLastTap = now;
        BOOL isPlus = (delta > 0);
        NSString *src = isPlus ? kVolSourceUp : kVolSourceDown;
        NSString *pid = nil;
        for (NSString *k in gPlans) {
            NSDictionary *p = gPlans[k];
            if ([p[@"volSource"] isEqualToString:src]) { pid = k; break; }
        }
        if (!pid) {
            PTDylibLog(@"[音量] %@ 未配置方案（音量键模式未设置动作），忽略", isPlus ? kVolNameUp : kVolNameDown);
            return;
        }
        // 直接传原始 actions 值（PTVolEstimateCount 内部对 nil/非数组/脏元素有容错）。
        // 踩坑记录（v1.0.80 CI 实证）：不要写成 [X ?: @[]]——GNU 省略中项的三元
        // 「?:」不能当**消息接收者**，clang 在该位置报 expected identifier；
        // 语句级/消息参数位（cfg[@"plans"] ?: @[]）则全仓沿用无碍。
        int n = PTVolEstimateCount(delta, gPlans[pid][@"actions"]);
        NSString *source = isPlus ? kVolNameUp : kVolNameDown;
        for (int i = 0; i < n; i++) PTChainHandleHitVolume(pid, source);
    });
}

// ============================================================
// KVO + 前后台观察者
// ============================================================
@interface PTVolumeObserver : NSObject
- (void)ptAppDidBecomeActive;      // 进前台（含冷启动/热重载）
- (void)ptAppDidEnterBackground;   // 退后台
@end

@implementation PTVolumeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"outputVolume"]) return;
    // 前台闸：仅本 App 前台时干预。退后台会话已停用，KVO 本就不该再来；双保险——
    // 即使后台仍收到回调（其他音频路径引起），也直接忽略，绝不影响其他 App 音量
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    NSNumber *oldN = change[NSKeyValueChangeOldKey];
    NSNumber *newN = change[NSKeyValueChangeNewKey];
    if (!oldN || !newN) return;
    float old = oldN.floatValue, now = newN.floatValue;
    float delta = now - old;
    if (fabsf(delta) < kVolJitter) return;                                    // 抖动过滤
    if (fabsf(now - kVolRest) < 0.001f) return;                               // 停在 1/16（含自己的对齐/弹回写回）→ 无动作
    if (PTVolNeedsReset(old) && fabsf(now - kVolRest) < 0.05f) return;        // 弹回副作用双保险：旧值越界且新值≈1/16 = 插件自己拉的
    PTVolTapPoints(delta);             // 用这次变化触发（+ / - 由 delta 符号决定）
    DoReset(old, now);                 // 触界才弹回 1/16（不钉死）
}

// v1.0.18：进前台（含冷启动）→ 激活音频会话 + 音量对齐 1/16
- (void)ptAppDidBecomeActive {
    PTVolActivateSession();
    PTVolSetSystemVolume(kVolRest);
}

// v1.0.18：退后台 → 停用音频会话（只是交出系统席位，不是「释放声音」；后台零音频痕迹）。
// 连滑/在飞动作的清理由引擎侧 PTDylibLoadConfig 已注册的 DidEnterBackground 观察者
// （PTChainStopAll）负责——两套机制不重复断链。
- (void)ptAppDidEnterBackground {
    PTVolDeactivateSession();
}
@end

// ============================================================
// 对外：启停 + HUD 热应用
// ============================================================
void PTVolumeStart(void) {
    if (!gVolEnabled) return;    // 总闸未开：零注册零开销
    if (gVolRunning) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gVolEnabled || gVolRunning) return;
        @autoreleasepool {
            gVolObs = [PTVolumeObserver new];
            [[AVAudioSession sharedInstance] addObserver:gVolObs
                                              forKeyPath:@"outputVolume"
                                                 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                                                 context:NULL];
            // v1.0.18：前后台感知——前台才激活音频会话并对齐音量；退后台立即释放
            [[NSNotificationCenter defaultCenter] addObserver:gVolObs selector:@selector(ptAppDidBecomeActive)
                                                         name:UIApplicationDidBecomeActiveNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:gVolObs selector:@selector(ptAppDidEnterBackground)
                                                         name:UIApplicationDidEnterBackgroundNotification object:nil];
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                [gVolObs ptAppDidBecomeActive];   // 注入时已在前台（晚注入/热重载）→ 立即生效
            }
            ApplyVolumeHudHidden(gVolHudHidden);  // 先尝试挂载（窗口可能尚未就绪，1s 后补挂）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (gVolRunning) ApplyVolumeHudHidden(gVolHudHidden); });
            gVolRunning = YES;
            PTDylibLog(@"[音量] 机制已启动：KVO + Ambient 会话 + 徘徊 1/16↔12/16 + 音量条%@",
                gVolHudHidden ? @"已隐藏" : @"显示");
        }
    });
}

void PTVolumeStop(void) {
    if (!gVolRunning) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gVolRunning) return;
        if (gVolObs) {
            @try { [[AVAudioSession sharedInstance] removeObserver:gVolObs forKeyPath:@"outputVolume"]; }
            @catch (NSException *e) {}
            [[NSNotificationCenter defaultCenter] removeObserver:gVolObs];
            gVolObs = nil;
        }
        PTVolDeactivateSession();      // 交出系统音频席位
        ApplyVolumeHudHidden(NO);      // 摘 MPVolumeView，恢复系统 HUD 正常弹出
        gVolRunning = NO;
        PTDylibLog(@"[音量] 机制已停止（总闸关闭）");
    });
}
