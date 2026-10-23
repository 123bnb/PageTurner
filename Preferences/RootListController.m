// ============================================================
// RootListController.m —— PageTurner 设置页（deb / roothide 注入形态）
//
// v1.0.77（设置页统一：8 个同名页一次性收编到 common/PTUI*，两侧不再各管各的）：
//   本文件原含 12 个类、2568 行——其中 8 个页面类（防抖/方案列表/方案页/特征列表/
//   学习页/动作参数/调试日志列表/日志内容/测试页）与 targets/dylib/PTDylibUI.m
//   里的同名类逐行重复（PTFeaturesVC/PTLearnVC/PTTestVC 重复度 95~98%），且已
//   双向漂移 8 处（delay 上限、排序交互、删除口径、pid 辅助、日志行数、废案提示
//   版本号、tapManual 处理、连滑开关有无）。本版把这些页面全部移到
//   common/PTUI*（PTUI 前缀，两侧编译同一份源码），本文件只留 deb 专属部分：
//     · RootListController  主设置页（总开关/指定App/防抖/记录与映射/连滑/调试）
//     · PTAppListVC         指定 App 生效列表（deb 独有——dylib 恒生效无总开关）
//     · 采集 hook           bundle 内自 hook（roothide 空 Filter 不注入系统 App）
//     · PTNavigatorDeb      导航协议实现（栈里找 PTShimPlansVC 回列表）
//     · PTUIPresentEditor   覆盖页呈现（deb=全屏 modal 不透明灰）
//     · PTUIEnsureCollectHook 采集 hook 装配（deb=bundle 内自 hook）
//   共享页经 Preferences/PTShimVC 桥接壳进 specifier detail（PSViewController
//   要求），日志数据源在 Preferences/PTLogSourceDeb.m。删除的旧类清单：
//   PTDebounceVC/PTPlansVC/PTPlanVC/PTFeaturesVC/PTLearnVC/PTActionParamVC/
//   PTDebugLogVC/PTLogContentVC/PTTestVC → common/PTUI* 同名共享版。
//
// v1.0.71（引擎核心化，删除 ~950 行重复实现）：常量/日志/样本/测试/数学工具/IOTool
//   全部移交 common/PTEngineCore.m；plist 读写走 Core 的 PTDylibReadCfg/PTWriteCfgTo
//   （本文件 PTWrite 双写经 PTSetCfgWriter 注入给 Core）。
// v1.0.66-fix：方案唯一身份 pid 贯通设置页（重名不串）；v1.0.66 #5/#5b：长按拖拽
//   排序（Z 方案）——两项均已随共享页移至 common/PTUI*。
// ============================================================

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/time.h>
#include <math.h>
#include <float.h>
#include <stdarg.h>
#import "PTFakeMetaTouch.h"
#import "PTEngineCore.h"   // 引擎核心（配置/匹配/样本/测试回放/连滑/工具）
#import "PTUICommon.h"     // 共享 UI 伞标题（导航/日志源/共享页助手）
#import "PTShimVC.h"       // 共享页桥接壳（specifier detail 入口）
#import "PTLogSourceDeb.h" // deb 日志数据源 + PTClearAllLogs/PTSettingsLogProbePath

@interface PSViewController (Private)
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier;
@end

// ---------- 页面接口（顶部集中声明） ----------
@interface RootListController : PSListController
@end

@interface PTAppListVC : PSViewController <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray *allApps;
@property (nonatomic, strong) NSMutableArray *shown;
@property (nonatomic, strong) NSMutableSet *selected;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UISearchBar *sb;
@end

// ---------- 工具 ----------
static NSString *PT_PREFS = @"/var/mobile/Library/Preferences/com.yourname.pageturner.plist";

// v1.0.77：PTRead/PTWrite 收敛为 Core 入口的薄转发——
//   · 读：PTUIReadCfg（含 pid 惰性补发，三端同规则，取代本文件旧版自带补发）
//   · 写：PTUIWriteCfg → Core 注入写入器 = 下方 PTWrite（双写 jbroot + 普通路径）
// v1.0.71：方向容差/位移裕度/学习上下限等常量已统一为 common/PTEngineCore.h 的宏
// （kDirTolerance/kDistSlack/kTapDistSlack/kTapDxThresh/kLearnMin/kLearnMax/
// kConverge/PTLogMaxLines…），deb/dylib/引擎三目标共用同一份数值。
static NSMutableDictionary *PTRead(void) { return PTUIReadCfg(); }

// v1.0.71：双写（jbroot 真实偏好路径 App 侧读得到 + 普通路径兜底自己读）——逐路径调
// Core 的 PTWriteCfgTo（序列化+原子写单一实现）；本函数同时经 PTSetCfgWriter 注入给
// Core，于是 Core 内部所有配置写入（学习样本/学习开关/UI 侧 pid 补发）在设置进程同样双写。
static void PTWrite(NSDictionary *cfg) {
    NSMutableArray *targets = [NSMutableArray array];
    NSString *jb = PTJbrootRoot();
    if (jb.length) {
        [targets addObject:[jb stringByAppendingPathComponent:
            [@"var/mobile/Library/Preferences" stringByAppendingPathComponent:@"com.yourname.pageturner.plist"]]];
    }
    [targets addObject:PT_PREFS];
    for (NSString *p in targets) PTWriteCfgTo(p, cfg);
}

// ---------- 日志系统 ----------
// v1.0.71：内存+文件日志机制整体在 Core（PTDylibLog/PTDylibLogClearLines/
// PTSetLogPath/PTSetFileLogEnabled），SLog 降级为宏转发。
// v1.0.77：清空/路径探测迁至 Preferences/PTLogSourceDeb.m（extern 声明见其头文件）。
#define SLog(fmt, ...) PTDylibLog(fmt, ##__VA_ARGS__)

// ---------- 学习收集（bundle 内自 hook，不依赖 tweak 注入 Preferences 进程）----------
// 根因：roothide 空 Filter 不注入系统 App（Preferences），tweak 收集链路失效。
// bundle 必然被 PreferenceLoader 加载进 Preferences 进程，在这里自己 hook 事件收集样本。
static BOOL sHooked = NO;
static IMP gOrigAddEvent = NULL;
static IMP gOrigSendEvent = NULL;

static void SImpAddEvent(id self, SEL _cmd, void *event) {
    @try {
        // v1.0.71：IOKit 符号解析在 Core（PTDylibInitIOKit → pGetType/pGetSender）；
        // 同时按 mtime 刷新 Core 配置缓存——测试执行走 Core 的 gPlans（见 PTTestExecPlan）。
        PTDylibLoadConfig(NO);
        if (pGetType && pGetSender && event) {
            uint32_t type = pGetType(event);
            if (type == 11) {
                uint64_t sender = pGetSender(event);
                // [日志观察] sender 变化才打（心跳同 sender 不打，防刷屏）
                static uint64_t sLastLoggedSender = 0;
                if (sender != sLastLoggedSender) {
                    sLastLoggedSender = sender;
                    SLog(@"addEvent: type=11 sender=0x%llx armed=%d", sender, sCollectArmed);
                }
                sCurSender = sender;
                // v1.0.71：采集窗口 0.05s → kCollectWindowSec(0.30s)，与引擎侧对齐
                // （旧值过短，系统繁忙时丢样本，"特征已稳定"迟迟达不到——漂移修复）
                if (sCollectArmed || sTestArmed) sWindowUntil = PTNowC() + kCollectWindowSec;
            }
        }
    } @catch (NSException *e) {}
    if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

static void SImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    @try {
        // v1.0.71：gTestInjecting 删除——Core 的动作执行统一置 gInFakeTouch/gIsInjecting。
        // v1.0.72（修实测 Bug 1）：注入/执行期不再无条件放行 + return，与运行端
        //   PTEngine.m:417-438 对齐——执行期遇到"不在假触摸池里的真实翻页器触摸"（用户又按了
        //   按键）时不 return，继续走下方采集分支，让这次按键进入连滑累计窗口。旧版无条件
        //   return 导致测试区执行中按键被吞：连滑计数永远停在 1，提示"连滑 1/5"却一次只有
        //   一个动作，必须等上一个完成才能再按（与 App 实地表现不一致）。
        if (gInFakeTouch || gIsInjecting) {
            BOOL realPagerDuringInject = NO;
            if (gIsInjecting && !gInFakeTouch && event &&
                [event respondsToSelector:@selector(allTouches)]) {
                for (UITouch *t in event.allTouches) {
                    if (![PTFakeMetaTouch isPoolTouch:t]) { realPagerDuringInject = YES; break; }
                }
            }
            if (!realPagerDuringInject) {
                ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
                return;
            }
            // realPagerDuringInject=YES → 不 return，继续走到下方采集分支
        }
        if ((sCollectArmed || sTestArmed) && event && PTNowC() < sWindowUntil) {
            NSSet *touches = [event respondsToSelector:@selector(allTouches)] ? event.allTouches : nil;
            UITouch *t = [touches anyObject];
            if (t && pGetSender) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                // [日志观察] 窗口内 UITouch 事件（量小，逐条打）
                SLog(@"sendEvent: phase=%ld pos=(%.1f,%.1f) sender=0x%llx sessActive=%d",
                     (long)t.phase, p.x, p.y, sCurSender, sSessActive);
                switch (t.phase) {
                    case UITouchPhaseBegan: {
                        sSessActive = YES; sSessDist = 0; sSessHasMove = NO; sSessFirstDir = 0;
                        sSessLast = p;
                        sSessStart = p;   // v1.0.36：记录会话起点
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
                            // v1.0.71：30.0 字面量 → kTapDistThreshold（Core 宏，与引擎同值）
                            int phase = (sSessDist < kTapDistThreshold) ? 0 : 1;
                            double dir = sSessHasMove ? sSessFirstDir : 0;
                            // v1.0.36：点击位移方向符号（x 分量，起点→终点）
                            int tapDx = 0;
                            {
                                double dxv = p.x - sSessStart.x;
                                tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
                            }
                            SLog(@"end: dist=%.1f dir=%.1f hasMove=%d → phase=%d tapDx=%d", sSessDist, sSessFirstDir, sSessHasMove, phase, tapDx);
                            if (sTestArmed) PTTestOnEnded(phase, dir, sSessDist, sCurSender, tapDx);
                            else PTSampleAppend(phase, dir, sSessDist, tapDx);   // v1.0.71：SAppendSample → Core
                        }
                        break;
                    }
                    case UITouchPhaseCancelled: sSessActive = NO; break;
                    default: break;
                }
            }
        }
    } @catch (NSException *e) {}
    if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

static void SCollectHook(void) {
    if (sHooked) return;
    @autoreleasepool {
        // v1.0.71：dlopen/dlsym 自行解析 IOKit 符号 → 统一调 Core 的 PTDylibInitIOKit
        //（dispatch_once 守护，符号落到 Core 的 pGetType/pGetSender）
        PTDylibInitIOKit();
        Class addCls = NSClassFromString(@"_UIUpdateHIDDigitizerInput");
        SEL addSel = sel_registerName("addEvent:");
        Method am = addCls ? class_getInstanceMethod(addCls, addSel) : NULL;
        if (am) { gOrigAddEvent = method_getImplementation(am); method_setImplementation(am, (IMP)SImpAddEvent); }

        Class appCls = NSClassFromString(@"UIApplication");
        SEL sendSel = sel_registerName("sendEvent:");
        Method sm = appCls ? class_getInstanceMethod(appCls, sendSel) : NULL;
        if (sm) { gOrigSendEvent = method_getImplementation(sm); method_setImplementation(sm, (IMP)SImpSendEvent); }

        sHooked = (gOrigAddEvent != NULL && gOrigSendEvent != NULL && pGetType != NULL && pGetSender != NULL);
        SLog(@"collect: sHooked=%d addEvent=%d sendEvent=%d getType=%d getSender=%d", sHooked, gOrigAddEvent!=NULL, gOrigSendEvent!=NULL, pGetType!=NULL, pGetSender!=NULL);
    }
}

// ============================================================
// 每 target 实现一次的两个 extern 函数（deb 版）——共享 VC 只认签名
// ============================================================

// 采集 hook 装配：deb 形态=bundle 内自 hook（roothide 不注入系统 App，见上）
void PTUIEnsureCollectHook(void) { SCollectHook(); }

// 覆盖页呈现（deb：全屏 modal + 不透明灰；保存逻辑走共享 PTUISaveActionToPlan）
void PTUIPresentEditor(UIViewController *presenter,
                       PTOverlayMode mode,
                       NSString *planId,
                       NSInteger editIndex,
                       NSDictionary *editAction,
                       PTUIEditorSavedBlock onSave) {
    PTOverlayPage *page = [PTOverlayPage new];
    page.mode = mode;
    page.editIndex = editIndex;
    page.editAction = editAction;
    page.translucent = NO;   // deb 不透明灰
    __weak typeof(page) wpage = page;
    page.onSave = ^(NSDictionary *a, NSInteger ei, NSDictionary *ea) {
        PTUISaveActionToPlan(planId, a, ei);   // 共享写回（按 pid，重名不串）
        if (onSave) onSave();
    };
    page.onDismiss = ^(BOOL saved) {
        [wpage dismissViewControllerAnimated:NO completion:nil];
    };
    page.recStart = nil;
    page.recStop = nil;
    page.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:page animated:NO completion:nil];
}

// ============================================================
// 导航协议 deb 实现——栈手术按宿主分叉：
//   · 回方案列表：deb 栈里是桥接壳 PTShimPlansVC（共享页在壳里，不在栈上）
//   · 回方案页：两侧都是共享 PTUIPlanVC（直接入栈），走 PTUICommon 的共享函数
// ============================================================
@interface PTNavigatorDeb : NSObject <PTUINavigator>
@end

@implementation PTNavigatorDeb
- (void)ptPush:(UIViewController *)vc from:(UIViewController *)from animated:(BOOL)animated {
    [from.navigationController pushViewController:vc animated:animated];
}
- (void)ptPopFrom:(UIViewController *)from animated:(BOOL)animated {
    [from.navigationController popViewControllerAnimated:animated];
}
- (void)ptPopToPlansListFrom:(UIViewController *)from animated:(BOOL)animated {
    UINavigationController *nav = from.navigationController;
    if (nav) {
        for (UIViewController *vc in nav.viewControllers) {
            if ([vc isKindOfClass:[PTShimPlansVC class]]) {
                [nav popToViewController:vc animated:animated];
                return;
            }
        }
    }
    [from.navigationController popViewControllerAnimated:animated];
}
@end

// ============================================================
// 主设置页
// ============================================================
@implementation RootListController

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"PageTurner";
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"总开关"]];
        PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用 PageTurner"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [master setProperty:@"masterEnabled" forKey:@"key"];
        [master setProperty:@YES forKey:@"default"];
        [master setProperty:@"关闭后全部按键恢复原样（不拦截）" forKey:@"staticText"];
        [specs addObject:master];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"生效范围"]];
        PSSpecifier *apps = [PSSpecifier preferenceSpecifierNamed:@"指定 App 生效"
            target:self set:nil get:nil detail:NSClassFromString(@"PTAppListVC")
            cell:PSLinkCell edit:nil];
        [apps setProperty:@"勾选后，只有这些 App 内会拦截翻页器按键；未勾选的 App 完全放行。改动即时生效。" forKey:@"staticText"];
        [specs addObject:apps];

        PSSpecifier *debounce = [PSSpecifier preferenceSpecifierNamed:@"防抖间隔"
            target:self set:nil get:nil detail:NSClassFromString(@"PTShimDebounceVC")
            cell:PSLinkCell edit:nil];
        [debounce setProperty:@"连续按键最小间隔，防止按住不放死循环（默认 300ms）" forKey:@"staticText"];
        [specs addObject:debounce];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"记录与映射"]];
        PSSpecifier *plans = [PSSpecifier preferenceSpecifierNamed:@"记录与映射"
            target:self set:nil get:nil detail:NSClassFromString(@"PTShimPlansVC")
            cell:PSLinkCell edit:nil];
        [plans setProperty:@"新增方案：录制翻页器一个按键的特征（来源+方向+位移），再映射为动作序列。左滑可删除方案。" forKey:@"staticText"];
        [specs addObject:plans];

        // v1.0.66(#6)：连滑（变速+刹停）总开关
        PSSpecifier *chain = [PSSpecifier preferenceSpecifierNamed:@"连滑提速"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [chain setProperty:@"chainEnabled" forKey:@"key"];
        [chain setProperty:@YES forKey:@"default"];
        // v1.0.72：文案对齐实现——① 倍率最高 3x（旧文案写 2x，代码自 v1.0.66 起就是 1→2→3 循环）；
        //   ② 顶部提示只在最后两档（4/5、已进入连滑）与升档/刹停时出现，前 3 次静默（按得快≠要连滑）；
        //   ③ 1.2s 时间窗本版真正落地（旧版窗口="回放中"，点击等快动作永远蓄不满，连滑只对滑动类生效）。
        [chain setProperty:@"同一方案连续翻页自动提速（满 5 次进入连滑，倍率最高 3x，连滑中再按同方案循环升档）；换成其他方案或没命中即刹停。顶部提示只在最后两档（4/5、已进入连滑）与升档/刹停时出现。注：连续按键间隔需小于 1.2s 才累计，超过即视为新链重新蓄力。" forKey:@"staticText"];
        [specs addObject:chain];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"调试"]];
        // v1.0.57：注入探针开关已删除（旧版无法注入时的兜底弹窗，早已失效，见 commit）
        PSSpecifier *dots = [PSSpecifier preferenceSpecifierNamed:@"调试可视化"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [dots setProperty:@"debugDots" forKey:@"key"];
        [dots setProperty:@NO forKey:@"default"];
        [dots setProperty:@"开启后所有触摸显示绿点+轨迹（翻页器带P标记，映射执行也可见）。用于确认注入和点触生效。" forKey:@"staticText"];
        [specs addObject:dots];

        // v1.0.42：调试日志开关（放在日志页上方）；v1.0.59：关开关联动隐藏下方入口 + 清空日志
        NSDictionary *cfgNow = PTRead();
        BOOL logOn = (cfgNow[@"debugLogEnabled"] == nil) ? YES : [cfgNow[@"debugLogEnabled"] boolValue];
        PSSpecifier *logSw = [PSSpecifier preferenceSpecifierNamed:@"调试日志"
            target:self set:@selector(setLogEnabled:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [logSw setProperty:@"debugLogEnabled" forKey:@"key"];
        [logSw setProperty:@YES forKey:@"default"];
        [logSw setProperty:@"总日志开关：开启后记录注入/命中/执行全过程——每个日志文件循环保留最近 500 条；关闭则完全无日志，并立即清空已产生的全部日志（内存与文件）。设置页即时生效，目标 App 重启后生效。" forKey:@"staticText"];
        [specs addObject:logSw];

        // v1.0.59：仅在开关打开时显示「调试日志」详情入口（联动隐藏）
        if (logOn) {
            PSSpecifier *log = [PSSpecifier preferenceSpecifierNamed:@"调试日志"
                target:self set:nil get:nil detail:NSClassFromString(@"PTShimDebugLogVC")
                cell:PSLinkCell edit:nil];
            [log setProperty:@"选择要看哪份日志（设置页日志 / 各生效 App 的运行日志），查看并复制，发给开发者定位" forKey:@"staticText"];
            [specs addObject:log];
        }

        _specifiers = [specs copy];
    }
    return _specifiers;
}

// v1.0.60：版本号改为页面底部居中的 tableFooterView——没有灰框、字体固定（不再时大时小），
// 版本号动态读取 bundle 的 CFBundleShortVersionString（升版本只需改 Info.plist，代码不用动）
- (void)setupVersionFooter {
    if (self.table.tableFooterView) return;
    NSString *ver = [[NSBundle bundleForClass:self.class] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!ver.length) ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!ver.length) ver = @"?";
    CGFloat w = self.view.bounds.size.width ?: 320;
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
    foot.text = [NSString stringWithFormat:@"PageTurner v%@", ver];
    foot.textAlignment = NSTextAlignmentCenter;
    foot.font = [UIFont systemFontOfSize:13];
    foot.textColor = [UIColor secondaryLabelColor];
    foot.backgroundColor = [UIColor clearColor];
    self.table.tableFooterView = foot;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setupVersionFooter];
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    id val = PTRead()[key];
    if (!val) val = [spec propertyForKey:@"default"];
    return val ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSMutableDictionary *cfg = PTRead();
    cfg[[spec propertyForKey:@"key"]] = value;
    PTWrite(cfg);
    [self reloadSpecifiers];
}

// v1.0.59：调试日志开关——关闭时立即清空全部日志，并联动隐藏/显示「调试日志」详情入口
- (void)setLogEnabled:(id)value specifier:(PSSpecifier *)spec {
    NSMutableDictionary *cfg = PTRead();
    cfg[[spec propertyForKey:@"key"]] = value;
    PTWrite(cfg);
    if (![value boolValue]) PTClearAllLogs();
    [self reloadSpecifiers];
}

@end

// ============================================================
// App 列表子页（枚举 + 搜索 + 勾选）——deb 独有（dylib 恒生效，无总开关/无指定App）
// ============================================================
@implementation PTAppListVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"指定 App 生效";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.35：统一成系统设置灰分组背景（与主设置页一致）
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    NSMutableSet *sel = [NSMutableSet setWithArray:PTRead()[@"enabledApps"] ?: @[]];
    self.selected = sel;
    self.allApps = [self enumerateApps];
    self.shown = [NSMutableArray arrayWithArray:[self buildShownFrom:self.allApps]];   // v1.0.66：勾选优先置顶（进入时才重排，打勾当下列表不动）

    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 40;

    self.sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width, 44)];
    self.sb.placeholder = @"搜索 App";
    self.sb.delegate = self;
    [self.view addSubview:self.sb];

    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top + 44, self.view.bounds.size.width,
        self.view.bounds.size.height - top - 44) style:UITableViewStyleGrouped];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
}

- (NSArray *)enumerateApps {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        SEL selWs = NSSelectorFromString(@"defaultWorkspace");
        if (wsCls && [wsCls respondsToSelector:selWs]) {
            id ws = [wsCls performSelector:selWs];
            SEL selApps = NSSelectorFromString(@"allApplications");
            if (ws && [ws respondsToSelector:selApps]) {
                for (id app in [ws performSelector:selApps]) {
                    NSString *bid = nil, *name = nil;
                    SEL s1 = NSSelectorFromString(@"bundleIdentifier");
                    if (app && [app respondsToSelector:s1]) bid = [app performSelector:s1];
                    SEL s2 = NSSelectorFromString(@"localizedName");
                    if (app && [app respondsToSelector:s2]) name = [app performSelector:s2];
                    if (!bid.length || !name.length) continue;
                    UIImage *icon = nil;
                    SEL s3 = NSSelectorFromString(@"icon");
                    if (app && [app respondsToSelector:s3]) icon = [app performSelector:s3];
                    [out addObject:@{ @"name": name, @"bundle": bid, @"icon": icon ?: (id)[NSNull null] }];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return out;
}

- (NSArray *)buildShownFrom:(NSArray *)src {
    // v1.0.66：勾选优先置顶——selected 排前、其余排后；src 已按名称排好，分区后拼接即得「勾选优先 + 名称序」
    NSMutableArray *sel = [NSMutableArray array], *rest = [NSMutableArray array];
    for (NSDictionary *a in src) {
        if ([self.selected containsObject:a[@"bundle"]]) [sel addObject:a]; else [rest addObject:a];
    }
    [sel addObjectsFromArray:rest];
    return sel;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSArray *base = self.allApps;
    if (searchText.length) {
        NSMutableArray *f = [NSMutableArray array];
        for (NSDictionary *a in self.allApps) {
            if ([a[@"name"] localizedCaseInsensitiveContainsString:searchText] ||
                [a[@"bundle"] localizedCaseInsensitiveContainsString:searchText]) [f addObject:a];
        }
        base = f;
    }
    self.shown = [NSMutableArray arrayWithArray:[self buildShownFrom:base]];   // v1.0.66：搜索结果内勾选项也优先置顶
    [self.tv reloadData];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.shown.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"app";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *a = self.shown[ip.row];
    c.textLabel.text = a[@"name"];
    c.detailTextLabel.text = a[@"bundle"];
    c.imageView.image = [a[@"icon"] isKindOfClass:[UIImage class]] ? a[@"icon"] : nil;
    c.accessoryType = [self.selected containsObject:a[@"bundle"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *bid = self.shown[ip.row][@"bundle"];
    if ([self.selected containsObject:bid]) [self.selected removeObject:bid];
    else [self.selected addObject:bid];
    NSMutableDictionary *cfg = PTRead();
    cfg[@"enabledApps"] = [[self.selected allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    PTWrite(cfg);
    [tv reloadData];
}
@end

// ============================================================
// 构造函数（v1.0.71：Core 注入 + 设置进程差异化配置；v1.0.77：+ 共享 UI 装配）
// ============================================================
// bundle 被 PreferenceLoader 加载进 Preferences 进程时执行：
//   ① PTSetCfgPath(PT_PREFS)：Core 的配置路径指向设置页主配置（与 PTRead/PTWrite 同一文件）；
//   ② PTSetCfgWriter(PTWrite)：Core 内部所有配置写入（学习样本/学习开关）改为设置页的
//      双写语义（jbroot 真实路径 + 普通路径兜底）——App 侧才读得到；
//   ③ PTSetLogPath + PTSetFileLogEnabled(YES)：设置页日志落盘（PageTurner.log），
//      内存+文件双写；注入镜像（Tweak.m 的 PTInit）在 Preferences 进程不再碰这两项
//      （v1.0.71 已把它的 PTSetFileLogEnabled/PTSetLogPath 移入非 Preferences 分支，
//      防两个构造函数竞态覆盖）；
//   ④ PTDylibLoadConfig(YES)：种子 Core 的配置缓存（gPlans 等）——测试执行
//      （PTTestExecPlan → PTExecutePlan）读的是它，后续由 SImpAddEvent 按 mtime 刷新。
//   ⑤ v1.0.77：PTUINavigator.current / PTUILogSource.current 各设一次——
//      共享页（common/PTUI*）经这两个协议口拿宿主的导航与日志能力。
__attribute__((constructor))
static void PTPrefsEngineInit(void) {
    @autoreleasepool {
        PTSetCfgPath(PT_PREFS);
        PTSetCfgWriter(PTWrite);
        NSString *lp = PTSettingsLogProbePath();
        if (lp) {
            PTSetLogPath(lp);
            PTSetFileLogEnabled(YES);
        } else {
            PTDylibLog(@"[SLog] ⚠️ 所有候选路径都不可写（仅内存日志）");
        }
        PTDylibLoadConfig(YES);
        PTUINavigator.current = [PTNavigatorDeb new];
        PTUILogSource.current = [PTLogSourceDeb new];
        PTDylibLog(@"[prefs] Core 就绪：cfg=%@ writer=双写 log=%@ navigator/logSource=已装配", PT_PREFS, lp ?: @"(仅内存)");
    }
}
