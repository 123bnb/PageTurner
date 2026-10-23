// ============================================================
// PTDylibUI.m —— PageTurnerDylib 设置 UI（v1.0.77）
//
// v1.0.77（设置页统一）：本文件原含 9 个类、1758 行——其中 8 个页面类与 deb 的
// Preferences/RootListController.m 同名类逐行重复（PTFeaturesVC/PTLearnVC/PTTestVC
// 重复度 95~98%），且已双向漂移 8 处（delay 上限 5000 vs 60000、排序用系统编辑态
// vs 长按拖拽、删除按 pid vs 行索引、日志 200 vs 500 行、废案提示版本号
// v1.0.5 vs v1.0.48、tapManual 静默转换 vs 弹提示、无连滑开关 vs 有）。
// 本版起这些页面全部移到 common/PTUI*（PTUI 前缀，两侧编译同一份源码），行为
// 以统一口径为准（长按拖拽/按 pid/500 行/废案弹提示/delay 60s/补连滑开关）。
// 本文件只留 dylib 专属部分：
//   · PTDylibMenuVC   双指长按主菜单（防抖/记录与映射/连滑提速/调试可视化/调试日志）
//   · PTDylibLogSource 内存日志数据源（v1.0.65 起不落盘，实现共享 PTUILogSource）
//   · PTNavigatorDylib 导航协议实现（回列表=找栈内 PTUIPlansVC）
//   · PTUIPresentEditor 覆盖页呈现（dylib=独立 UIWindow 半透明 + 关/显菜单）
//   · PTUIEnsureCollectHook 采集 hook（dylib=PTDylibCore 加载即装，空实现）
// ============================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/time.h>
#include <math.h>
#include <float.h>
#import "ptftouch/PTFakeMetaTouch.h"
#import "PTEngine.h"
#import "PTVersion.h"   // 版本横幅宏（scripts/gen_ptversion.sh 生成，勿手改）
#import "PTOverlayPage.h"   // v1.0.62：点击/双击/滑动/滑动(手动) 统一模板（与 deb 共用）
#import "PTUICommon.h"      // v1.0.77：共享 UI 伞标题（导航/日志源/共享页助手/per-target 函数声明）
#import "PTUIPlanVC.h"      // v1.0.77：覆盖页关闭后按 pid 刷新栈里的方案页

// v1.0.77：配置读写统一走 Core 的 UI 入口——
//   · 读：PTUIReadCfg（含 pid 惰性补发；旧本文件 PTUIRead 与 Core 逐字重复，已删）
//   · 写：PTUIWriteCfg → Core 的 PTWriteCfg（容器内独立配置单写）
#define PTRead()  PTUIReadCfg()
#define PTWrite(c) PTUIWriteCfg(c)
// 日志统一走 core 实现
#define SLog(...) PTDylibLog(__VA_ARGS__)

// ---------- 全部页面接口（顶部集中声明） ----------
@interface PTDylibMenuVC : UITableViewController <UITableViewDataSource, UITableViewDelegate>
@end

// v1.0.77：内存日志数据源（巨魔形态不落盘任何文件，只有 PTDylibLogLines()）
@interface PTDylibLogSource : NSObject <PTUILogSource>
@end

// v1.0.77：导航协议 dylib 实现
@interface PTNavigatorDylib : NSObject <PTUINavigator>
@end

// ============================================================
// 主菜单（双指长按弹出）
// ============================================================
@implementation PTDylibMenuVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        self.title = @"PageTurnerDylib";
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
            style:UIBarButtonItemStyleDone target:self action:@selector(closeTapped)];
    }
    return self;
}

// v1.0.7：状态栏样式透传——菜单窗口 windowLevel 高于状态栏会接管状态栏，导致
// 时间/信号电池颜色不再跟随 App。v1.0.10：直接透传系统当前实际状态栏样式/隐藏状态
// （比取 keyWindow rootViewController 更贴合 App 实时显示）。
- (UIStatusBarStyle)preferredStatusBarStyle {
    @try { return [UIApplication sharedApplication].statusBarStyle; } @catch (NSException *e) {}
    return UIStatusBarStyleDefault;
}
- (BOOL)prefersStatusBarHidden {
    @try { return [UIApplication sharedApplication].statusBarHidden; } @catch (NSException *e) {}
    return NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];   // 返回时刷新防抖值/开关态/日志入口行
}

- (void)closeTapped { PTDylibCloseMenu(); }

#pragma mark UITableView
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"设置";
    if (s == 1) return @"调试";
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) {
        return [NSString stringWithFormat:@"%@\n独立版 · 注入即生效（无总开关）：把 PageTurnerDylib.dylib 用巨魔注入器注入任意 App，双指长按弹出本菜单。", PT_VERSION_STRING];
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 3;   // v1.0.77：补「连滑提速」开关（原 deb 独有，统一后两边都有）
    if (s == 1) {
        BOOL logOn = [PTRead()[@"debugLogEnabled"] boolValue];
        return logOn ? 3 : 2;   // 日志开关行 + (日志入口行，仅开关开时显示)
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"menu";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    c.detailTextLabel.text = nil;
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.textLabel.textColor = [UIColor labelColor];

    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = @"防抖间隔";
            double db = [PTRead()[@"debounceMs"] doubleValue];
            c.detailTextLabel.text = [NSString stringWithFormat:@"连续按键最小间隔 %.0f ms", (db > 0) ? db : 300];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            c.textLabel.text = @"记录与映射";
            c.detailTextLabel.text = @"录制翻页器按键特征 → 映射为动作序列（点击/双击/滑动/延迟）";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            // v1.0.77：连滑提速总开关（与 deb 主设置页同 key=chainEnabled，Core 从配置读）
            c.textLabel.text = @"连滑提速";
            c.detailTextLabel.text = @"同一方案连续翻页自动提速（满 5 次进入连滑，倍率最高 3x）";
            UISwitch *sw = [[UISwitch alloc] init];
            id v = PTRead()[@"chainEnabled"];
            sw.on = (v == nil) ? YES : [v boolValue];
            sw.tag = 12;
            [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
    } else if (ip.section == 1) {
        if (ip.row == 0) {
            c.textLabel.text = @"调试可视化";
            c.detailTextLabel.text = @"开启后所有触摸显示绿点+轨迹（翻页器带P标记）";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [PTRead()[@"debugDots"] boolValue];
            sw.tag = 10;
            [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        } else if (ip.row == 1) {
            c.textLabel.text = @"调试日志";
            c.detailTextLabel.text = @"总日志开关：记录注入/命中/执行全过程（内存循环 500 条）";
            UISwitch *sw = [[UISwitch alloc] init];
            id v = PTRead()[@"debugLogEnabled"];
            sw.on = (v == nil) ? YES : [v boolValue];
            sw.tag = 11;
            [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        } else {
            c.textLabel.text = @"调试日志";
            c.detailTextLabel.text = @"查看并复制最近日志（内存日志，100% 可见）";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return c;
}

- (void)switchToggled:(UISwitch *)sw {
    NSMutableDictionary *cfg = PTRead();
    if (sw.tag == 10) cfg[@"debugDots"] = @(sw.on);
    else if (sw.tag == 12) cfg[@"chainEnabled"] = @(sw.on);   // v1.0.77：连滑总开关（Core 从配置读）
    else {
        cfg[@"debugLogEnabled"] = @(sw.on);
        PTDylibLogSetEnabled(sw.on);   // v1.0.19：日志开关运行时即时生效
        // v1.0.77：关闭即清空（与 deb 主设置页同语义——「关闭则完全无日志」），
        // 经共享日志源抽象执行（dylib 源=清内存）
        if (!sw.on) {
            id<PTUILogSource> src = PTUILogSource.current;
            if ([src respondsToSelector:@selector(clearAllLogs)]) [src clearAllLogs];
        }
    }
    PTWrite(cfg);
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        if (ip.row == 0) [self.navigationController pushViewController:[PTUIDebounceVC new] animated:YES];
        else if (ip.row == 1) [self.navigationController pushViewController:[PTUIPlansVC new] animated:YES];
    } else if (ip.section == 1 && ip.row == 2) {
        [self.navigationController pushViewController:[PTUIDebugLogVC new] animated:YES];
    }
}
@end

// ============================================================
// 内存日志数据源（v1.0.77：巨魔形态不落盘，实现共享 PTUILogSource）
// 共享的 PTUIDebugLogVC/PTUILogContentVC 经本源读日志——显示口径与 deb 统一
// （尾部最多 PTLogMaxLines=500 行；旧 dylib 直接显示 200 行，已统一）
// ============================================================
@implementation PTDylibLogSource

- (NSArray<NSDictionary *> *)logItems {
    NSArray *lines = PTDylibLogLines();
    NSString *joined = [lines componentsJoinedByString:@"\n"];
    return @[ @{@"name": @"内存日志（不落盘，循环 500 条）", @"size": @(joined.length)} ];
}

- (NSString *)logContentAtIndex:(NSInteger)i {
    if (i != 0) return nil;
    NSArray *lines = PTDylibLogLines();
    NSUInteger n = lines.count;
    NSUInteger from = n > PTLogMaxLines ? n - PTLogMaxLines : 0;
    return [[lines subarrayWithRange:NSMakeRange(from, n - from)] componentsJoinedByString:@"\n"];
}

- (BOOL)canClearLogs { return YES; }

- (void)clearAllLogs { PTDylibLogClearLines(); }

@end

// ============================================================
// 导航协议 dylib 实现——栈手术按宿主分叉：
//   · 回方案列表：dylib 栈里就是共享的 PTUIPlansVC（直接 push，无壳）
//   · 回方案页：两侧都是共享 PTUIPlanVC，走 PTUICommon 的共享函数
// ============================================================
@implementation PTNavigatorDylib
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
            if ([vc isKindOfClass:[PTUIPlansVC class]]) {
                [nav popToViewController:vc animated:animated];
                return;
            }
        }
    }
    [nav popToRootViewControllerAnimated:animated];   // 兜底：菜单是根
}
@end

// ============================================================
// 每 target 实现一次的两个 extern 函数（dylib 版）
// ============================================================

// 采集 hook：dylib 形态由 PTDylibCore 在 dylib 加载时统一装配（双指检测/学习/测试
// 同一套 hook），共享页调用本函数只为签名一致——这里无需再做任何事
void PTUIEnsureCollectHook(void) {}

// 覆盖页呈现（dylib：半透明覆盖窗口 + 关菜单保留导航栈；recStart/recStop 接引擎录制守卫）。
// 保存逻辑统一走 PTUISaveActionToPlan（按 pid，重名不串）；取消/完成后重显菜单并
// 回到方案页（修 bug B），并按 pid 刷新栈里的方案页。
static UIWindow *gOverlayWindow = nil;
void PTUIPresentEditor(UIViewController *presenter,
                       PTOverlayMode mode,
                       NSString *planId,
                       NSInteger editIndex,
                       NSDictionary *editAction,
                       PTUIEditorSavedBlock onSave) {
    PTDylibHideMenuPreserving();   // 关菜单但保留导航栈（取消/完成后回到方案页，不改全局关菜单行为）
    PTOverlayPage *page = [PTOverlayPage new];
    page.mode = mode;
    page.editIndex = editIndex;
    page.editAction = editAction;
    page.translucent = YES;        // dylib 半透明黑，透出 App
    __weak typeof(page) wpage = page;
    page.onSave = ^(NSDictionary *a, NSInteger ei, NSDictionary *ea) {
        PTUISaveActionToPlan(planId, a, ei);   // 共享写回（按 pid，重名不串）
        if (onSave) onSave();
    };
    page.onDismiss = ^(BOOL saved) {
        // 移除覆盖层窗口 + 重显菜单（保留的导航栈回到方案页）+ 刷新方案页
        gOverlayWindow.hidden = YES;
        gOverlayWindow.rootViewController = nil;
        [gOverlayWindow removeFromSuperview];
        gOverlayWindow = nil;
        PTDylibShowMenu();
        UINavigationController *nav = (UINavigationController *)PTDylibMenuWindow().rootViewController;
        for (UIViewController *vc in nav.viewControllers) {
            // 按 pid 匹配栈里的方案页（重名时只刷新对应的那个）
            if ([vc isKindOfClass:[PTUIPlanVC class]] && [[(PTUIPlanVC *)vc planId] isEqualToString:planId]) {
                [(PTUIPlanVC *)vc reload];
                break;
            }
        }
    };
    // 录制守卫：仅 recSwipe 模式由 PTOverlayPage 内部调用（PTRecStart 置 gRecArmed 供引擎排除录制态）
    page.recStart = ^(NSString *m, double topY, void (^doneUI)(NSArray *pts)) { PTRecStart(m, topY, doneUI); };
    page.recStop = ^{ PTRecStop(); };

    UIWindow *ow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
            ow.windowScene = (UIWindowScene *)scene; break;
        }
    }
    ow.windowLevel = UIWindowLevelAlert + 1;
    ow.backgroundColor = [UIColor clearColor];
    ow.rootViewController = page;
    ow.hidden = NO;
    gOverlayWindow = ow;
}
