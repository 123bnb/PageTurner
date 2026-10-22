// ============================================================
// PTDylibUI.m —— PageTurnerDylib 设置 UI（v1.0.20）
//
// 从 deb 版 RootListController.m（v1.0.43）移植，改造：
//   · 基类 PSViewController/PSListController → UIViewController（不依赖 Preferences 框架）
//   · 删除主设置页（specifiers 总开关/指定App生效/探针）与 PTAppListVC——
//     dylib 无总开关、无指定 App 生效
//   · 配置读写走 PTDylibReadCfg/PTDylibWriteCfg（共享 deb 配置或独立配置）
//   · 日志走 PTDylibLog（v1.0.65 起巨魔形态只留内存 PTDylibLogLines()，不落盘任何文件）
//   · 学习/测试采集 hook 由 PTDylibCore 统一装配（不再单独 SCollectHook）
//   · 新增主菜单 PTDylibMenuVC（双指长按弹出，v1.0.12 起由三指改为双指）：
//     防抖间隔 / 记录与映射 / 调试可视化(开关) / 调试日志(开关) / 调试日志(入口)
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

// 配置读写 / 日志 / 工具统一走 core 实现
#define PTRead() PTDylibReadCfg()
#define PTWrite(c) PTDylibWriteCfg(c)
#define SLog(...) PTDylibLog(__VA_ARGS__)

// ---------- 全部页面接口（顶部集中声明） ----------
@interface PTDylibMenuVC : UITableViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface PTDebounceVC : UIViewController
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valLabel;
@end

@interface PTPlansVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray *plans;
@property (nonatomic, strong) UITableView *tv;
- (void)reload;
@end

@interface PTPlanVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *recStatus;
@property (nonatomic, strong) UILabel *addFeatureBtn;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray *actions;
- (void)reload;
@end

@interface PTFeaturesVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) NSMutableArray *features;
@property (nonatomic, strong) UITableView *tv;
- (void)reload;
@end

@interface PTLearnVC : UIViewController
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *dirLabel;
@property (nonatomic, strong) UILabel *distLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray *mem;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL limitExceeded;
@property (nonatomic, strong) NSDictionary *readyFt;
@property (nonatomic, assign) BOOL onceMode;
@property (nonatomic, assign) NSInteger replaceIndex;
@property (nonatomic, assign) int onceCount;
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) UIView *trailDot;
@property (nonatomic, strong) UILabel *trailLabel;
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end


// v1.0.12：手动录制改 keyWindow 上的半透明覆盖层（不再用全屏页面 VC）——
// 覆盖层不拦截触摸（穿透到 App 实地操作），"完成/取消"按钮行在顶部，以下为录制区。
// 支持 滑动(手动)/点击(手动)/双击(手动) 三种模式。

@interface PTActionParamVC : UIViewController
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, assign) NSInteger actionIndex;
@property (nonatomic, strong) NSDictionary *action;
@property (nonatomic, strong) NSArray *paramDefs;
@property (nonatomic, strong) NSMutableArray *sliders;
@property (nonatomic, strong) NSMutableArray *labels;
@property (nonatomic, strong) NSMutableArray *chips;
@end

@interface PTDebugLogVC : UIViewController
@end

@interface PTTestVC : UIViewController
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) UIView *trailDot;
@property (nonatomic, strong) UILabel *trailLabel;
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

// ---------- 常量 ----------
// v1.0.71：本文件原有的 7 份常量副本已删——统一用 common/PTEngineCore.h 的宏
//（kDirTolerance/kDistSlack/kTapDistSlack/kTapDxThresh/kLearnMin/kLearnMax/kConverge，
//  经 PTEngine.h re-export 可见）；PTLearnVC 判定用的 kLearnMin/kLearnMax 数值不变。

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
    [self.tableView reloadData];   // 返回时刷新防抖值/配置来源/日志入口行
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
    if (s == 0) return 2;
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
        } else {
            c.textLabel.text = @"记录与映射";
            c.detailTextLabel.text = @"录制翻页器按键特征 → 映射为动作序列（点击/滑动/音量等）";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
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
            c.detailTextLabel.text = @"总日志开关：记录注入/命中/执行全过程（每个日志文件循环 500 条）";
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
    else { cfg[@"debugLogEnabled"] = @(sw.on); PTDylibLogSetEnabled(sw.on); }   // v1.0.19：日志开关运行时即时生效
    PTWrite(cfg);
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        if (ip.row == 0) [self.navigationController pushViewController:[PTDebounceVC new] animated:YES];
        else [self.navigationController pushViewController:[PTPlansVC new] animated:YES];
    } else if (ip.section == 1 && ip.row == 2) {
        [self.navigationController pushViewController:[PTDebugLogVC new] animated:YES];
    }
}
@end

// ============================================================
// 防抖间隔页（滑杆 100~1000ms）
// ============================================================
@implementation PTDebounceVC

- (instancetype)init {
    self = [super init];
    if (self) self.title = @"防抖间隔";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 40;
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, top, self.view.bounds.size.width - 32, 60)];
    hint.text = @"连续按键最小间隔：\n按住翻页器不放时，防止按键反复触发（默认 300ms）";
    hint.font = [UIFont systemFontOfSize:14];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.numberOfLines = 0;
    [self.view addSubview:hint];

    self.valLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 48, self.view.bounds.size.width - 32, 30)];
    self.valLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
    [self.view addSubview:self.valLabel];

    self.slider = [[UISlider alloc] initWithFrame:CGRectMake(16, top + 88, self.view.bounds.size.width - 32, 34)];
    self.slider.minimumValue = 100;
    self.slider.maximumValue = 1000;
    double cur = [PTRead()[@"debounceMs"] doubleValue];
    self.slider.value = (cur > 0) ? cur : 300;
    [self.slider addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.slider];
    [self changed];
}

- (void)changed {
    self.valLabel.text = [NSString stringWithFormat:@"%.0f ms", self.slider.value];
    NSMutableDictionary *cfg = PTRead();
    cfg[@"debounceMs"] = @(self.slider.value);
    PTWrite(cfg);
}
@end

// ============================================================
// 方案列表页（左滑删除 / 新增方案）
// ============================================================
@implementation PTPlansVC

- (instancetype)init {
    self = [super init];
    if (self) self.title = @"记录与映射";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 40;
    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width,
        self.view.bounds.size.height - top) style:UITableViewStyleGrouped];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.plans = [NSMutableArray arrayWithArray:PTRead()[@"plans"] ?: @[]];
    [self.tv reloadData];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.plans.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"plan";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (ip.row < (NSInteger)self.plans.count) {
        NSDictionary *p = self.plans[ip.row];
        c.textLabel.text = p[@"name"] ?: @"（未命名）";
        NSArray *fts = PTFeaturesOfPlan(p);
        NSArray *acts = p[@"actions"] ?: @[];
        if (fts.count) {
            NSDictionary *ft = fts.firstObject;
            NSString *d = PTDirName([ft[@"direction"] doubleValue]);
            NSString *ph = [ft[@"phase"] intValue] == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", d];
            c.detailTextLabel.text = [NSString stringWithFormat:@"来源%@ ｜ 特征 %lu 条（%@） ｜ 动作 %lu 条",
                ft[@"sender"], (unsigned long)fts.count, ph, (unsigned long)acts.count];
        } else {
            c.detailTextLabel.text = [NSString stringWithFormat:@"未录制 ｜ 动作 %lu 条", (unsigned long)acts.count];
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"新增方案";
        c.detailTextLabel.text = @"录制一个按键特征，映射为动作序列";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row < (NSInteger)self.plans.count) {
        PTPlanVC *vc = [PTPlanVC new];
        vc.planName = self.plans[ip.row][@"name"];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        NSString *name = [NSString stringWithFormat:@"新方案%lu", (unsigned long)(plans.count + 1)];
        [plans addObject:@{ @"name": name, @"actions": @[] }];
        cfg[@"plans"] = plans;
        PTWrite(cfg);
        PTPlanVC *vc = [PTPlanVC new];
        vc.planName = name;
        [self.navigationController pushViewController:vc animated:YES];
        [self reload];
    }
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.plans.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        NSDictionary *p = self.plans[ip.row];
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray array];
        for (NSDictionary *x in cfg[@"plans"] ?: @[]) {
            if (![x[@"name"] isEqualToString:p[@"name"]]) [plans addObject:x];
        }
        cfg[@"plans"] = plans;
        PTWrite(cfg);
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
@end

// ============================================================
// 方案页（名称 / 记录状态 / 映射区）
// ============================================================
@implementation PTPlanVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"排序"
        style:UIBarButtonItemStylePlain target:self action:@selector(toggleEdit)];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTRead()[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) { plan = p; break; }
    }
    if (!plan) { [self.navigationController popViewControllerAnimated:YES]; return; }
    self.actions = [NSMutableArray arrayWithArray:plan[@"actions"] ?: @[]];

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width;

    if (!self.nameLabel) {
        self.nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top, w - 32, 40)];
        self.nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        self.nameLabel.backgroundColor = [UIColor systemBackgroundColor];
        self.nameLabel.layer.cornerRadius = 10;
        self.nameLabel.clipsToBounds = YES;
        self.nameLabel.textAlignment = NSTextAlignmentCenter;
        self.nameLabel.userInteractionEnabled = YES;
        [self.nameLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(renameTapped)]];
        [self.view addSubview:self.nameLabel];

        self.recStatus = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 44, w - 32, 44)];
        self.recStatus.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.recStatus.textColor = [UIColor whiteColor];
        self.recStatus.backgroundColor = [UIColor systemBlueColor];
        self.recStatus.textAlignment = NSTextAlignmentCenter;
        self.recStatus.layer.cornerRadius = 10;
        self.recStatus.clipsToBounds = YES;
        self.recStatus.userInteractionEnabled = YES;
        [self.recStatus addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recordTapped)]];
        [self.view addSubview:self.recStatus];

        self.addFeatureBtn = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 96, w - 32, 44)];
        self.addFeatureBtn.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.addFeatureBtn.textColor = [UIColor whiteColor];
        self.addFeatureBtn.backgroundColor = [UIColor systemOrangeColor];
        self.addFeatureBtn.textAlignment = NSTextAlignmentCenter;
        self.addFeatureBtn.layer.cornerRadius = 10;
        self.addFeatureBtn.clipsToBounds = YES;
        self.addFeatureBtn.userInteractionEnabled = YES;
        [self.addFeatureBtn addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(addFeatureTapped)]];
        [self.view addSubview:self.addFeatureBtn];

        self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top + 148, w, self.view.bounds.size.height - top - 148)
            style:UITableViewStyleGrouped];
        self.tv.dataSource = self;
        self.tv.delegate = self;
        [self.view addSubview:self.tv];

        UILabel *hv = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 32, 34)];
        hv.text = @"映射区：按一次该键 → 从上到下依次执行全部动作（右上角「排序」可拖动调整）";
        hv.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        hv.textColor = [UIColor labelColor];
        hv.textAlignment = NSTextAlignmentCenter;
        self.tv.tableHeaderView = hv;
    }
    self.nameLabel.text = [NSString stringWithFormat:@"方案名： %@", self.planName];
    NSArray *fts = PTFeaturesOfPlan(plan);
    if (fts.count) {
        self.recStatus.text = [NSString stringWithFormat:@"✅ 已录制 %ld 条特征 · 点我查看", (long)fts.count];
        self.recStatus.backgroundColor = [UIColor systemGreenColor];
    } else {
        self.recStatus.text = @"＋ 新增记录（按翻页器同一键录特征）";
        self.recStatus.backgroundColor = [UIColor systemBlueColor];
    }
    self.addFeatureBtn.text = @"＋ 增加特征（录单个特征，以最后一次为准）";
    [self.tv reloadData];
}

- (void)renameTapped {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"修改方案名"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.planName;
        tf.placeholder = @"方案名";
    }];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *newName = [al.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!newName.length || [newName isEqualToString:self.planName]) return;
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray array];
        for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
            if ([p[@"name"] isEqualToString:self.planName]) {
                NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
                np[@"name"] = newName;
                [plans addObject:np];
            } else [plans addObject:p];
        }
        cfg[@"plans"] = plans;
        self.planName = newName;
        PTWrite(cfg);
        self.nameLabel.text = [NSString stringWithFormat:@"方案名： %@", newName];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)recordTapped {
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTRead()[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) { plan = p; break; }
    }
    if (PTFeaturesOfPlan(plan).count) {
        PTFeaturesVC *vc = [PTFeaturesVC new];
        vc.planName = self.planName;
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        PTLearnVC *vc = [PTLearnVC new];
        vc.planName = self.planName;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)addFeatureTapped {
    PTLearnVC *vc = [PTLearnVC new];
    vc.planName = self.planName;
    vc.onceMode = YES;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.actions.count + 2; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"act";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    if (ip.row < (NSInteger)self.actions.count) {
        c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(ip.row + 1), PTActionText(self.actions[ip.row])];
        c.accessoryType = UITableViewCellAccessoryNone;
        for (UIGestureRecognizer *g in c.gestureRecognizers)
            if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) [c removeGestureRecognizer:g];
        UILongPressGestureRecognizer *lg = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressAction:)];
        [c addGestureRecognizer:lg];
    } else if (ip.row == (NSInteger)self.actions.count) {
        c.textLabel.text = @"＋ 新增映射";
        c.textLabel.textColor = [UIColor systemBlueColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"▶ 测试本方案（大白屏 + 绿点点触验证）";
        c.textLabel.textColor = [UIColor systemGreenColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row < (NSInteger)self.actions.count) {
        NSDictionary *act = self.actions[ip.row];
        NSString *type = act[@"type"];
        // v1.0.5：已删除的音量动作（旧配置残留）→ 提示，不进编辑页
        if ([type isEqualToString:@"volumeUp"] || [type isEqualToString:@"volumeDown"] || [type isEqualToString:@"muteToggle"]) {
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"该动作已移除"
                message:@"音量+/音量-/静音切换已在 v1.0.5 删除（注入环境音量读取不可靠）。请在编辑中删除这个动作，换成其它动作。"
                preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
            return;
        }
        // v1.0.62：滑动(手动)已录动作再次点击 → 统一模板重录（预载已有轨迹）
        if ([type isEqualToString:@"recSwipe"]) {
            PTDylibPresentOverlay(PTOverlayModeRecSwipe, self.planName, ip.row, act);
            return;
        }
        if ([type isEqualToString:@"tapManual"]) type = @"tap";
        else if ([type isEqualToString:@"doubleTapManual"]) type = @"doubleTap";
        if (![type isEqualToString:@"delay"]) {
            PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                            : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
            PTDylibPresentOverlay(mode, self.planName, ip.row, act);
        } else {
            PTActionParamVC *vc = [PTActionParamVC new];
            vc.planName = self.planName;
            vc.actionIndex = ip.row;
            vc.action = act;
            [self.navigationController pushViewController:vc animated:YES];
        }
        return;
    }
    if (ip.row == (NSInteger)self.actions.count) { [self addActionMenu]; return; }
    PTTestVC *vc = [PTTestVC new];
    vc.planName = self.planName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)longPressAction:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)g.view;
    CGPoint loc = [g locationInView:cell];
    if (loc.x > cell.bounds.size.width - 56) return;
    NSIndexPath *ip = [self.tv indexPathForCell:cell];
    if (!ip || ip.row >= (NSInteger)self.actions.count) return;
    PTActionParamVC *vc = [PTActionParamVC new];
    vc.planName = self.planName;
    vc.actionIndex = ip.row;
    vc.action = self.actions[ip.row];
    [self.navigationController pushViewController:vc animated:YES];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.actions.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        [self.actions removeObjectAtIndex:ip.row];
        [self saveActions];
        [tv reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (void)toggleEdit {
    BOOL on = !self.tv.editing;
    [self.tv setEditing:on animated:YES];
    self.navigationItem.rightBarButtonItem.title = on ? @"完成" : @"排序";
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.row < (NSInteger)self.actions.count;
}
- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip {
    return ip.row < (NSInteger)self.actions.count;
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewCellEditingStyleNone;
}
- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip {
    return NO;
}
- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.row >= (NSInteger)self.actions.count) return;
    NSUInteger dest = MIN((NSUInteger)to.row, (NSUInteger)(self.actions.count - 1));
    id a = self.actions[from.row];
    [self.actions removeObjectAtIndex:from.row];
    [self.actions insertObject:a atIndex:dest];
    [self saveActions];
}

- (void)addActionMenu {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"新增映射"
        message:@"选择要添加的动作" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *items = @[
        @[@"点击", @"tap"], @[@"双击", @"doubleTap"], @[@"滑动", @"swipe"],
        @[@"滑动(手动)", @"recSwipe"],   // v1.0.14：点击(手动)/双击(手动)已删，仅保留滑动(手动)
        @[@"延迟", @"delay"]];   // v1.0.5：音量+/音量-/静音切换动作类型已删除
    for (NSArray *it in items) {
        [al addAction:[UIAlertAction actionWithTitle:it[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self configAction:it[1]];
        }]];
    }
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

// v1.0.62：统一模板呈现"新增映射"四页面（dylib：半透明覆盖窗口 + 关菜单保留导航栈；
// recStart/recStop 接引擎录制守卫）。取消/完成后重显菜单并回到方案页（修 bug B）。
static UIWindow *gOverlayWindow = nil;
static void PTDylibPresentOverlay(PTOverlayMode mode, NSString *planName, NSInteger editIndex, NSDictionary *editAction) {
    PTDylibHideMenuPreserving();   // 关菜单但保留导航栈（取消/完成后回到方案页，不改全局关菜单行为）
    PTOverlayPage *page = [PTOverlayPage new];
    page.mode = mode;
    page.planName = planName;
    page.editIndex = editIndex;
    page.editAction = editAction;
    page.translucent = YES;        // dylib 半透明黑，透出 App
    __weak typeof(page) wpage = page;
    page.onSave = ^(NSDictionary *a, NSInteger ei, NSDictionary *ea) {
        // dylib 保存（与引擎回放字段一致）
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray array];
        for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
            if ([p[@"name"] isEqualToString:planName]) {
                NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
                NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
                if (ei >= 0 && ea && ei < (NSInteger)acts.count) acts[ei] = a;
                else [acts addObject:a];
                np[@"actions"] = acts;
                [plans addObject:np];
            } else [plans addObject:p];
        }
        cfg[@"plans"] = plans;
        PTWrite(cfg);
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
            if ([vc isKindOfClass:[PTPlanVC class]] && [[(PTPlanVC *)vc planName] isEqualToString:planName]) {
                [(PTPlanVC *)vc reload];
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

- (void)configAction:(NSString *)type {
    if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.62：滑动(手动)——统一模板（半透明覆盖层实地录制，落盘 @{x,y,t} 与引擎回放一致）
        PTDylibPresentOverlay(PTOverlayModeRecSwipe, self.planName, -1, nil);
    } else if ([type isEqualToString:@"delay"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"延迟"
            message:@"输入延迟毫秒数（如 500 = 0.5 秒）" preferredStyle:UIAlertControllerStyleAlert];
        [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.keyboardType = UIKeyboardTypeNumberPad; tf.placeholder = @"500"; }];
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            double ms = [al.textFields.firstObject.text doubleValue];
            if (ms > 0) { [self.actions addObject:@{@"type": @"delay", @"ms": @(ms)}]; [self saveActions]; }
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else {
        PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                        : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
        PTDylibPresentOverlay(mode, self.planName, -1, nil);
    }
}

- (void)saveActions {
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"actions"] = self.actions;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self.tv reloadData];
}
@end

// ============================================================
// 已录入特征列表页
// ============================================================
@implementation PTFeaturesVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"已录入特征";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTRead()[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) { plan = p; break; }
    }
    if (!plan) { [self.navigationController popViewControllerAnimated:YES]; return; }
    self.features = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(plan)];
    [self.tv reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return MAX((NSInteger)self.features.count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"ft";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (ip.row >= (NSInteger)self.features.count) {
        c.textLabel.text = @"还没有特征";
        c.detailTextLabel.text = @"点方案页【＋ 新增记录】正常录，或【＋ 增加特征】录单个";
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    NSDictionary *ft = self.features[ip.row];
    NSString *snd = ft[@"sender"] ?: @"—";
    int phase = [ft[@"phase"] intValue];
    NSString *ph = phase == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", PTDirName([ft[@"direction"] doubleValue])];
    c.textLabel.text = [NSString stringWithFormat:@"特征%ld  %@  sender=%@", (long)(ip.row + 1), ph, snd];
    if (phase == 0) {
        int dx = [ft[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ %@ %.1f pt · 录 %d 次", dxs,
            PTDirName([ft[@"direction"] doubleValue]), [ft[@"distMin"] doubleValue], [ft[@"recordCount"] intValue]];
    } else {
        c.detailTextLabel.text = [NSString stringWithFormat:@"方向 %.0f° · 位移 %.0f~%.0f pt · 录 %d 次",
            [ft[@"direction"] doubleValue], [ft[@"distMin"] doubleValue], [ft[@"distMax"] doubleValue],
            [ft[@"recordCount"] intValue]];
    }
    c.textLabel.textColor = [UIColor labelColor];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.features.count) return;
    NSDictionary *ft = self.features[ip.row];
    NSString *snd = ft[@"sender"] ?: @"—";
    int phase = [ft[@"phase"] intValue];
    NSString *ph = phase == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", PTDirName([ft[@"direction"] doubleValue])];
    NSString *detail;
    if (phase == 0) {
        int dx = [ft[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        detail = [NSString stringWithFormat:@"类型：%@\n来源：%@\n位移：%@ %.1f pt\n录制样本：%d 次",
            ph, snd, dxs, [ft[@"distMin"] doubleValue], [ft[@"recordCount"] intValue]];
    } else {
        detail = [NSString stringWithFormat:@"类型：%@\n来源：%@\n方向：%.0f°\n位移：%.0f ~ %.0f pt\n录制样本：%d 次",
            ph, snd, [ft[@"direction"] doubleValue], [ft[@"distMin"] doubleValue], [ft[@"distMax"] doubleValue],
            [ft[@"recordCount"] intValue]];
    }
    UIAlertController *al = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"特征%ld 详情", (long)(ip.row + 1)]
        message:detail preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"重新录制" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        PTLearnVC *vc = [PTLearnVC new];
        vc.planName = self.planName;
        vc.replaceIndex = ip.row;
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.row < (NSInteger)self.features.count;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= (NSInteger)self.features.count) return;
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *fts = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(np)];
            [fts removeObjectAtIndex:ip.row];
            np[@"features"] = fts;
            [np removeObjectForKey:@"feature"];
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self reload];
}
@end

// ============================================================
// 学习页（大白屏录特征）
// ============================================================
@implementation PTLearnVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.onceMode ? @"增加特征" : @"录制特征";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.finished = NO;
    self.mem = [NSMutableArray array];

    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.22, w - 48, 60)];
    self.status.text = self.onceMode ? @"按 1 次即可记录\n再按会覆盖上一条（以最后一下为准）"
                                     : @"请一直重复按同一个键\n直到提示特征已稳定";
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [self.view addSubview:self.status];

    self.countLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4, w - 48, 30)];
    self.countLabel.text = @"已录：0 次";
    self.countLabel.textAlignment = NSTextAlignmentCenter;
    self.countLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.countLabel];

    self.dirLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 34, w - 48, 30)];
    self.dirLabel.text = @"方向：—";
    self.dirLabel.textAlignment = NSTextAlignmentCenter;
    self.dirLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.dirLabel];

    self.distLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 68, w - 48, 30)];
    self.distLabel.text = @"位移：—";
    self.distLabel.textAlignment = NSTextAlignmentCenter;
    self.distLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.distLabel];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(16, h * 0.4 + 106, w - 32, h - (h * 0.4 + 106) - 30)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 10;
    self.logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.view addSubview:self.logView];
    [self appendLog:@"等待按键… 识别结果实时显示在这里"];

    PTDylibSetLearningLocal(YES);
    sCollectArmed = YES;
    sLastSampleAt = PTNowC();
    SLog(@"learn: viewDidLoad 会话已复位，armed=YES（采集由 PTDylibCore 统一 hook 处理）");
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
    sCollectArmed = NO;
    PTDylibSetLearningLocal(NO);
}

- (void)back {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)poll {
    if (!sCollectArmed) return;
    NSMutableDictionary *cfg = PTRead();
    NSArray *samples = cfg[@"learningSamples"] ?: @[];
    cfg[@"learningSamples"] = @[];
    PTWrite(cfg);
    if (!samples.count) {
        if (!self.finished && self.mem.count == 0 && PTNowC() - sLastSampleAt > 1.5) {
            self.status.text = @"⚠️ 未收到翻页器按键事件\n确认翻页器已连接、保持在前台按它";
            self.status.textColor = [UIColor systemOrangeColor];
        }
        return;
    }
    sLastSampleAt = PTNowC();
    for (NSDictionary *s in samples) [self judge:s];
}

- (void)judge:(NSDictionary *)s {
    if (self.onceMode) { [self judgeOnce:s]; return; }
    if (self.finished) {
        if (![s[@"sender"] isEqualToString:self.readyFt[@"sender"]]) {
            [self appendLog:[NSString stringWithFormat:@"⚠ 正在增强当前特征，请继续按同一个键（当前来源 %@）",
                self.readyFt[@"sender"]]];
            return;
        }
        [self.mem addObject:s];
        NSString *sender = s[@"sender"];
        double dir = [s[@"direction"] doubleValue];
        double dist = [s[@"dist"] doubleValue];
        int count = 0;
        for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) count++;
        self.countLabel.text = [NSString stringWithFormat:@"已录：%d 次（来源 %@）", count, sender];
        self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
        if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", dist];
        else {
            int dx = [s[@"tapDx"] intValue];
            NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
            self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, dist];
        }
        [self appendLog:[NSString stringWithFormat:@"✓ 增强 %d 次  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            count, sender, [s[@"phase"] intValue], dir, dist]];
        [self drawTrailWithDirection:dir dist:dist phase:[s[@"phase"] intValue]];
        double lo = DBL_MAX, hi = 0;
        for (NSDictionary *m in self.mem) {
            if (![m[@"sender"] isEqualToString:sender]) continue;
            double v = [m[@"dist"] doubleValue];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        NSMutableDictionary *ft = [NSMutableDictionary dictionaryWithDictionary:self.readyFt];
        ft[@"distMin"] = @(lo);
        ft[@"distMax"] = @(hi);
        self.readyFt = ft;
        return;
    }
    NSArray *plans = PTRead()[@"plans"] ?: @[];
    NSString *dup = PTDuplicate(s, plans);
    if (dup) {
        SLog(@"judge: REJECT duplicate with '%@' — new{sender=%@ phase=%d dir=%.1f dist=%.1f}",
             dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]);
        self.status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", dup];
        self.status.textColor = [UIColor systemRedColor];
        [self.mem removeAllObjects];
        self.readyFt = nil;
        self.finished = NO;
        self.navigationItem.rightBarButtonItem.enabled = NO;
        self.countLabel.text = @"已录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        [self appendLog:[NSString stringWithFormat:@"✗ 拒绝（与『%@』重复）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]]];
        return;
    }
    self.status.textColor = [UIColor labelColor];
    [self.mem addObject:s];
    NSString *sender = s[@"sender"];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    int count = 0;
    for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) count++;
    SLog(@"judge: ACCEPT sender=%@ phase=%d dir=%.1f dist=%.1f count=%d", sender, [s[@"phase"] intValue], dir, dist, count);
    self.countLabel.text = [NSString stringWithFormat:@"已录：%d 次（来源 %@）", count, sender];
    self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
    if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", dist];
    else {
        int dx = [s[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, dist];
    }
    [self appendLog:[NSString stringWithFormat:@"✓ 已录 %d 次  sender=%@ phase=%d dir=%.1f° dist=%.1f",
        count, sender, [s[@"phase"] intValue], dir, dist]];
    [self drawTrailWithDirection:dir dist:dist phase:[s[@"phase"] intValue]];

    if (PTStable(self.mem, sender)) {
        self.status.text = @"✅ 特征已稳定，可以停止";
        self.status.textColor = [UIColor systemGreenColor];
        [self onStable:sender phase:[s[@"phase"] intValue] dir:dir];
    } else if (count >= kLearnMax && !self.limitExceeded) {
        [self onTooMany];
    } else {
        self.status.text = count < kLearnMin ? @"请继续按同一个键…" : @"特征收敛中，请继续…";
    }
}

- (void)judgeOnce:(NSDictionary *)s {
    NSArray *plans = PTRead()[@"plans"] ?: @[];
    NSString *dup = PTDuplicate(s, plans);
    if (dup) {
        SLog(@"judgeOnce: REJECT duplicate with '%@' — new{sender=%@ phase=%d dir=%.1f dist=%.1f}",
             dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]);
        self.status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", dup];
        self.status.textColor = [UIColor systemRedColor];
        [self appendLog:[NSString stringWithFormat:@"✗ 拒绝（与『%@』重复）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]]];
        self.readyFt = nil;
        self.finished = NO;
        self.onceCount = 0;
        self.navigationItem.rightBarButtonItem.enabled = NO;
        self.countLabel.text = @"已记录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        return;
    }
    self.status.textColor = [UIColor labelColor];
    self.onceCount++;
    NSMutableDictionary *ft = [NSMutableDictionary dictionary];
    ft[@"sender"] = s[@"sender"];
    ft[@"phase"] = s[@"phase"];
    ft[@"direction"] = s[@"direction"];
    double d = [s[@"dist"] doubleValue];
    if ([s[@"phase"] intValue] == 1) { ft[@"distMin"] = @(d); ft[@"distMax"] = @(d); }
    else {
        ft[@"distMin"] = @(d); ft[@"distMax"] = @(d);
        ft[@"tapDx"] = s[@"tapDx"] ?: @0;
    }
    ft[@"recordCount"] = @(1);
    self.readyFt = ft;
    self.finished = YES;
    NSString *sender = s[@"sender"];
    double dir = [s[@"direction"] doubleValue];
    self.countLabel.text = [NSString stringWithFormat:@"已记录：第 %d 次（来源 %@，以最后为准）", self.onceCount, sender];
    self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
    if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", d];
    else {
        int dx = [s[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, d];
    }
    [self appendLog:[NSString stringWithFormat:@"✓ 记录 %d 次（覆盖上一条）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
        self.onceCount, sender, [s[@"phase"] intValue], dir, d]];
    [self drawTrailWithDirection:dir dist:d phase:[s[@"phase"] intValue]];
    self.status.text = [NSString stringWithFormat:@"✅ 已记录：来源 %@｜方向 %@｜位移 %.0f pt\n\n再按会覆盖，点右上角「保存」完成",
        sender, PTDirName(dir), d];
    self.status.textColor = [UIColor systemGreenColor];
    self.navigationItem.rightBarButtonItem.enabled = YES;
    SLog(@"learn(once): 已记录 %d 次 sender=%@ phase=%d dir=%.1f dist=%.1f（等右上角保存）",
        self.onceCount, sender, [s[@"phase"] intValue], dir, d);
}

- (void)onStable:(NSString *)sender phase:(int)phase dir:(double)dir {
    if (self.finished) return;
    self.finished = YES;
    double lo = DBL_MAX, hi = 0;
    for (NSDictionary *m in self.mem) {
        if (![m[@"sender"] isEqualToString:sender]) continue;
        double v = [m[@"dist"] doubleValue];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    NSMutableDictionary *ft = [NSMutableDictionary dictionary];
    ft[@"sender"] = sender;
    ft[@"phase"] = @(phase);
    ft[@"direction"] = @(dir);
    ft[@"distMin"] = @(lo);
    ft[@"distMax"] = @(hi);
    if (phase == 0) {
        int lastDx = 0;
        for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) lastDx = [m[@"tapDx"] intValue];
        ft[@"tapDx"] = @(lastDx);
    }
    ft[@"recordCount"] = @([self countForSender:sender]);
    self.readyFt = ft;
    if (phase == 0) {
        NSString *dxs = ([ft[@"tapDx"] intValue] > 0) ? @"向右" : (([ft[@"tapDx"] intValue] < 0) ? @"向左" : @"原地");
        self.status.text = [NSString stringWithFormat:@"✅ 特征已稳定\n来源 %@｜%@ %@｜位移 %.1f~%.1f pt\n\n点右上角「保存」完成录制", sender, dxs, PTDirName(dir), lo, hi];
    } else {
        self.status.text = [NSString stringWithFormat:@"✅ 特征已稳定\n来源 %@｜方向 %@｜位移 %.0f~%.0f pt\n\n点右上角「保存」完成录制", sender, PTDirName(dir), lo, hi];
    }
    self.status.textColor = [UIColor whiteColor];
    self.view.backgroundColor = [UIColor systemGreenColor];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.navigationItem.rightBarButtonItem.enabled = YES;
    SLog(@"learn: 特征已稳定（不弹框），可继续录或点右上角保存 sender=%@ phase=%d dir=%.1f dist=%.0f~%.0f tapDx=%d", sender, phase, dir, lo, hi, [ft[@"tapDx"] intValue]);
}

- (void)saveTapped {
    if (self.onceMode) { [self saveOnce]; return; }
    if (self.replaceIndex >= 0) { [self saveReplace]; return; }
    if (!self.finished || !self.readyFt) return;
    NSDictionary *ft = self.readyFt;
    NSArray *plans = PTRead()[@"plans"] ?: @[];
    NSString *name = nil;
    for (int i = 1; i < 1000; i++) {
        NSString *cand = [NSString stringWithFormat:@"新方案%d", i];
        BOOL dupName = NO;
        for (NSDictionary *p in plans) if ([p[@"name"] isEqualToString:cand]) { dupName = YES; break; }
        if (!dupName) { name = cand; break; }
    }
    if (!name) name = @"新按键";
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *nplans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
    [nplans addObject:@{@"name": name, @"features": @[ft], @"actions": @[]}];
    cfg[@"plans"] = nplans;
    PTWrite(cfg);
    PTDylibSetLearningLocal(NO);
    [self appendLog:[NSString stringWithFormat:@"已保存「%@」（名字可在方案页点方案名修改）", name]];
    NSMutableArray *stack = [NSMutableArray arrayWithArray:self.navigationController.viewControllers];
    NSUInteger base = NSNotFound;
    for (NSUInteger i = 0; i < stack.count; i++) {
        if ([stack[i] isKindOfClass:[PTPlansVC class]]) { base = i; break; }
    }
    if (base != NSNotFound) {
        [stack removeObjectsInRange:NSMakeRange(base + 1, stack.count - base - 1)];
        [self.navigationController setViewControllers:stack animated:YES];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)saveOnce {
    if (!self.readyFt) return;
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    BOOL done = NO;
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *fts = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(np)];
            [fts addObject:self.readyFt];
            np[@"features"] = fts;
            [np removeObjectForKey:@"feature"];
            [plans addObject:np];
            done = YES;
        } else [plans addObject:p];
    }
    if (!done) { [self.navigationController popViewControllerAnimated:YES]; return; }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    PTDylibSetLearningLocal(NO);
    NSUInteger total = 0;
    for (NSDictionary *p in plans) if ([p[@"name"] isEqualToString:self.planName]) { total = PTFeaturesOfPlan(p).count; break; }
    [self appendLog:[NSString stringWithFormat:@"已增加 1 条特征（共 %lu 条），回方案页", (unsigned long)total]];
    NSMutableArray *stack = [NSMutableArray arrayWithArray:self.navigationController.viewControllers];
    NSUInteger base = NSNotFound;
    for (NSUInteger i = 0; i < stack.count; i++) {
        if ([stack[i] isKindOfClass:[PTPlanVC class]]) { base = i; break; }
    }
    if (base != NSNotFound) {
        [stack removeObjectsInRange:NSMakeRange(base + 1, stack.count - base - 1)];
        [self.navigationController setViewControllers:stack animated:YES];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)saveReplace {
    if (!self.finished || !self.readyFt) return;
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    BOOL done = NO;
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *fts = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(np)];
            if (self.replaceIndex >= 0 && self.replaceIndex < (NSInteger)fts.count) {
                fts[self.replaceIndex] = self.readyFt;
            } else {
                [fts addObject:self.readyFt];
            }
            np[@"features"] = fts;
            [np removeObjectForKey:@"feature"];
            [plans addObject:np];
            done = YES;
        } else [plans addObject:p];
    }
    if (!done) { [self.navigationController popViewControllerAnimated:YES]; return; }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    PTDylibSetLearningLocal(NO);
    [self appendLog:@"已替换特征，回方案页"];
    NSMutableArray *stack = [NSMutableArray arrayWithArray:self.navigationController.viewControllers];
    NSUInteger base = NSNotFound;
    for (NSUInteger i = 0; i < stack.count; i++) {
        if ([stack[i] isKindOfClass:[PTPlanVC class]]) { base = i; break; }
    }
    if (base != NSNotFound) {
        [stack removeObjectsInRange:NSMakeRange(base + 1, stack.count - base - 1)];
        [self.navigationController setViewControllers:stack animated:YES];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase {
    [self.trailLayer removeFromSuperlayer];
    [self.trailDot removeFromSuperview];
    [self.trailLabel removeFromSuperview];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGPoint start = CGPointMake(w * 0.5, h * 0.38);
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    dot.layer.cornerRadius = 18;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.3];
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.center = start;
    [self.view addSubview:dot];
    self.trailDot = dot;
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    lb.text = @"P";
    lb.textAlignment = NSTextAlignmentCenter;
    lb.font = [UIFont boldSystemFontOfSize:18];
    lb.textColor = [UIColor whiteColor];
    lb.backgroundColor = [UIColor systemGreenColor];
    lb.layer.cornerRadius = 18;
    lb.clipsToBounds = YES;
    if (phase == 1) {
        double rad = dir * M_PI / 180.0;
        CGPoint end = CGPointMake(start.x + cos(rad) * dist, start.y + sin(rad) * dist);
        CAShapeLayer *l = [CAShapeLayer layer];
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, start.x, start.y);
        CGPathAddLineToPoint(path, NULL, end.x, end.y);
        l.path = path;
        CGPathRelease(path);
        l.strokeColor = [UIColor systemGreenColor].CGColor;
        l.fillColor = [UIColor clearColor].CGColor;
        l.lineWidth = 3;
        [self.view.layer addSublayer:l];
        self.trailLayer = l;
        lb.center = end;
    } else {
        lb.center = start;
    }
    [self.view addSubview:lb];
    self.trailLabel = lb;
}

- (int)countForSender:(NSString *)sender {
    int c = 0;
    for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) c++;
    return c;
}

- (void)onTooMany {
    sCollectArmed = NO;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"特征波动太大"
        message:@"已录 15 次仍未稳定，建议检查按键或重录" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"继续录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.limitExceeded = YES;
        sCollectArmed = YES;
        sLastSampleAt = PTNowC();
        self.status.textColor = [UIColor labelColor];
        self.status.text = @"已解除上限，继续按同一个键直到稳定…";
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"重录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        self.limitExceeded = NO;
        [self.mem removeAllObjects];
        self.countLabel.text = @"已录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        self.status.textColor = [UIColor labelColor];
        self.status.text = @"请一直重复按同一个键\n直到提示特征已稳定";
        NSMutableDictionary *cfg = PTRead();
        cfg[@"learningSamples"] = @[];
        PTWrite(cfg);
        sCollectArmed = YES;
        sLastSampleAt = PTNowC();
        [self appendLog:@"已重录：样本已清空"];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)appendLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", s] : s;
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}
@end




// ============================================================
// 动作参数调整页（滑块 + 预设值可点击）
// ============================================================
static NSDictionary *PTParamPresets(void) {
    return @{
        @"pressMs": @[ @10, @30, @50, @100, @200, @400 ],
        @"gapMs":   @[ @50, @120, @200, @300, @500 ],
        @"holdMs":  @[ @0, @20, @50, @100, @200 ],
        @"liftMs":  @[ @0, @100, @300, @500, @1000 ],
        @"speed":   @[ @100, @300, @500, @1000, @1500, @2000 ],
        @"steps":   @[ @6, @12, @24, @48, @96 ],
        @"ms":      @[ @50, @100, @300, @500, @1000, @3000 ],
    };
}
static void *PTParamSliderKey = &PTParamSliderKey;
static void *PTParamValueKey = &PTParamValueKey;

@implementation PTActionParamVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"动作参数";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    NSString *type = self.action[@"type"];
    NSArray *defs = nil;
    if ([type isEqualToString:@"tap"]) {
        defs = @[ @{@"key": @"pressMs", @"name": @"按下时长", @"unit": @"ms", @"min": @10, @"max": @500, @"def": @30} ];
    } else if ([type isEqualToString:@"doubleTap"]) {
        defs = @[ @{@"key": @"pressMs", @"name": @"按下时长", @"unit": @"ms", @"min": @10, @"max": @500, @"def": @30},
                  @{@"key": @"gapMs", @"name": @"两次间隔", @"unit": @"ms", @"min": @50, @"max": @800, @"def": @120} ];
    } else if ([type isEqualToString:@"swipe"]) {
        defs = @[ @{@"key": @"holdMs", @"name": @"按下停留", @"unit": @"ms", @"min": @0, @"max": @500, @"def": @20},
                  @{@"key": @"liftMs", @"name": @"弹起停留", @"unit": @"ms", @"min": @0, @"max": @2000, @"def": @0},
                  @{@"key": @"speed", @"name": @"滑动速度", @"unit": @"pt/s", @"min": @100, @"max": @2000, @"def": @1000},
                  @{@"key": @"steps", @"name": @"滑动分段", @"unit": @"段", @"min": @6, @"max": @96, @"def": @12},
                  @{@"key": @"noInertia", @"name": @"防惯性", @"type": @"switch", @"def": @YES} ];
    } else if ([type isEqualToString:@"delay"]) {
        defs = @[ @{@"key": @"ms", @"name": @"延迟时长", @"unit": @"ms", @"min": @50, @"max": @5000, @"def": @100} ];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.paramDefs = defs;
    self.sliders = [NSMutableArray array];
    self.labels = [NSMutableArray array];
    self.chips = [NSMutableArray array];
    NSDictionary *presets = PTParamPresets();

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width;
    CGFloat rowH = 104;
    for (int i = 0; i < (int)defs.count; i++) {
        NSDictionary *p = defs[i];
        CGFloat y = top + i * rowH;
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 26)];
        name.text = [NSString stringWithFormat:@"%@%@", p[@"name"],
            [p[@"type"] isEqualToString:@"switch"] ? @"" : [NSString stringWithFormat:@"（%@）", p[@"unit"]]];
        name.font = [UIFont systemFontOfSize:15];
        [self.view addSubview:name];
        if ([p[@"type"] isEqualToString:@"switch"]) {
            UISwitch *sw = [[UISwitch alloc] init];
            id v = self.action[p[@"key"]];
            sw.on = v ? [v boolValue] : [p[@"def"] boolValue];
            sw.frame = CGRectMake(w - 80, y - 2, 60, 34);
            [self.view addSubview:sw];
            [self.labels addObject:[NSNull null]];
            [self.sliders addObject:sw];
            [self.chips addObject:[NSMutableArray array]];
        } else {
            UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(w - 120, y, 100, 26)];
            val.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
            val.textAlignment = NSTextAlignmentRight;
            [self.view addSubview:val];
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(20, y + 54, w - 40, 34)];
            sl.minimumValue = [p[@"min"] doubleValue];
            sl.maximumValue = [p[@"max"] doubleValue];
            id vv0 = self.action[p[@"key"]];
            sl.value = vv0 ? [vv0 doubleValue] : [p[@"def"] doubleValue];
            [self.view addSubview:sl];
            [self.labels addObject:val];
            [self.sliders addObject:sl];
            NSArray *ps = presets[p[@"key"]];
            NSMutableArray *rowChips = [NSMutableArray array];
            if (ps.count) {
                CGFloat cw = (w - 40) / ps.count;
                for (int j = 0; j < (int)ps.count; j++) {
                    double vv = [ps[j] doubleValue];
                    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                    b.frame = CGRectMake(20 + j * cw, y + 28, cw - 4, 22);
                    [b setTitle:[NSString stringWithFormat:@"%.0f", vv] forState:UIControlStateNormal];
                    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
                    b.layer.cornerRadius = 6;
                    b.layer.borderWidth = 0.8;
                    b.layer.borderColor = [UIColor systemGray4Color].CGColor;
                    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
                    objc_setAssociatedObject(b, PTParamSliderKey, sl, OBJC_ASSOCIATION_ASSIGN);
                    objc_setAssociatedObject(b, PTParamValueKey, @(vv), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [b addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
                    [self.view addSubview:b];
                    [rowChips addObject:b];
                }
            }
            [self.chips addObject:rowChips];
            [sl addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
            [self changed:sl];
        }
    }
}

- (void)presetTapped:(UIButton *)b {
    UISlider *sl = objc_getAssociatedObject(b, PTParamSliderKey);
    NSNumber *v = objc_getAssociatedObject(b, PTParamValueKey);
    if (!sl || !v) return;
    sl.value = v.doubleValue;
    [self changed:sl];
}

- (void)changed:(UISlider *)sl {
    NSUInteger i = [self.sliders indexOfObject:sl];
    if (i == NSNotFound || i >= self.labels.count) return;
    ((UILabel *)self.labels[i]).text = [NSString stringWithFormat:@"%.0f", sl.value];
    NSArray *rowChips = (i < self.chips.count) ? self.chips[i] : @[];
    for (UIButton *b in rowChips) {
        double vv = [(NSNumber *)objc_getAssociatedObject(b, PTParamValueKey) doubleValue];
        BOOL near = fabs(sl.value - vv) < 1.0;
        [b setTitleColor:near ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor] forState:UIControlStateNormal];
        b.layer.borderColor = near ? [UIColor systemBlueColor].CGColor : [UIColor systemGray4Color].CGColor;
    }
}

- (void)done {
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
            if (self.actionIndex >= 0 && self.actionIndex < (NSInteger)acts.count) {
                NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:acts[self.actionIndex]];
                for (int i = 0; i < (int)self.sliders.count && i < (int)self.paramDefs.count; i++) {
                    NSString *key = self.paramDefs[i][@"key"];
                    if ([self.paramDefs[i][@"type"] isEqualToString:@"switch"]) {
                        a[key] = @(((UISwitch *)self.sliders[i]).on);
                    } else {
                        a[key] = @(roundf(((UISlider *)self.sliders[i]).value));
                    }
                }
                acts[self.actionIndex] = a;
            }
            np[@"actions"] = acts;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

// ============================================================
// 调试日志页（读内存日志尾部 + 复制）
// ============================================================
@implementation PTDebugLogVC

- (instancetype)init {
    self = [super init];
    if (self) self.title = @"调试日志";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:tv];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制"
        style:UIBarButtonItemStyleDone target:self action:@selector(copyLog)];

    NSArray *lines = PTDylibLogLines();
    if (lines.count) {
        NSUInteger n = lines.count;
        NSUInteger from = n > 200 ? n - 200 : 0;
        tv.text = [[lines subarrayWithRange:NSMakeRange(from, n - from)] componentsJoinedByString:@"\n"];
    } else {
        tv.text = @"日志为空。\n\n进「记录与映射」→ 新增方案 → 进方案页 → 新增记录（大白屏）后按翻页器同一键，再回到这里复制。";
    }
}

- (void)copyLog {
    UITextView *tv = [self.view.subviews firstObject];
    if (![tv isKindOfClass:[UITextView class]]) return;
    UIPasteboard.generalPasteboard.string = tv.text;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"已复制"
        message:@"日志已复制到剪贴板，可直接粘贴发送" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}
@end

// ============================================================
// 测试页（大白屏 + 绿点点触可视化）
// ============================================================
@implementation PTTestVC

- (instancetype)init {
    self = [super init];
    if (self) self.title = @"测试本方案";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 80, self.view.bounds.size.width - 32, 120)];
    tip.numberOfLines = 0;
    tip.textAlignment = NSTextAlignmentCenter;
    tip.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    tip.text = [NSString stringWithFormat:@"按翻页器按键测试方案「%@」\n\n匹配成功会执行动作序列，\n绿点 = 注入点触的位置\n（点击原地显示；滑动从起点到终点）", self.planName ?: @""];
    [self.view addSubview:tip];

    CGFloat h = self.view.bounds.size.height, w = self.view.bounds.size.width;
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, h - 210, w - 24, 190)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 10;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:self.logView];
    [self appendLog:@"等待按键… 命中/未命中实时显示在这里"];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 72, 72)];
    dot.layer.cornerRadius = 36;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.35];
    dot.layer.borderWidth = 3;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.hidden = YES;
    dot.userInteractionEnabled = NO;
    [self.view addSubview:dot];

    sTestDot = dot;
    sTestArmed = YES;
    sTestLogSink = self;
    SLog(@"test: viewDidLoad armed=YES（方案 %@），采集由 PTDylibCore 统一 hook 处理", self.planName ?: @"");
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // v1.0.71：改调 Core 的 PTTestReset——比旧实现多清 sTestLine/sTestP/sTestTrail 并
    // 作废尾巴淡出令牌（旧实现在 dylib 侧会漏留方向线/P 标记）
    PTTestReset();
}

- (void)appendLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", s] : s;
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}

// v1.0.73：原地改写最后一行——连滑续滑进度聚合显示用（逐轮 append 会刷爆记录区）
- (void)updateLastLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    if (!cur.length) { self.logView.text = s; return; }
    NSRange nl = [cur rangeOfString:@"\n" options:NSBackwardsSearch];
    NSString *head = (nl.location == NSNotFound) ? @"" : [cur substringToIndex:nl.location + 1];
    self.logView.text = [head stringByAppendingString:s];
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}

- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase {
    [self.trailLayer removeFromSuperlayer];
    [self.trailDot removeFromSuperview];
    [self.trailLabel removeFromSuperview];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGPoint start = CGPointMake(w * 0.5, h * 0.38);
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    dot.layer.cornerRadius = 18;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.3];
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.center = start;
    [self.view addSubview:dot];
    self.trailDot = dot;
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    lb.text = @"P";
    lb.textAlignment = NSTextAlignmentCenter;
    lb.font = [UIFont boldSystemFontOfSize:18];
    lb.textColor = [UIColor whiteColor];
    lb.backgroundColor = [UIColor systemGreenColor];
    lb.layer.cornerRadius = 18;
    lb.clipsToBounds = YES;
    if (phase == 1) {
        double rad = dir * M_PI / 180.0;
        CGPoint end = CGPointMake(start.x + cos(rad) * dist, start.y + sin(rad) * dist);
        CAShapeLayer *l = [CAShapeLayer layer];
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, start.x, start.y);
        CGPathAddLineToPoint(path, NULL, end.x, end.y);
        l.path = path;
        CGPathRelease(path);
        l.strokeColor = [UIColor systemGreenColor].CGColor;
        l.fillColor = [UIColor clearColor].CGColor;
        l.lineWidth = 3;
        [self.view.layer addSublayer:l];
        self.trailLayer = l;
        lb.center = end;
    } else {
        lb.center = start;
    }
    [self.view addSubview:lb];
    self.trailLabel = lb;
}
@end
