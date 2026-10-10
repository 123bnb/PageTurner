// ============================================================
// OverlayUI.m —— PageTurner 录制/映射面板（注入 App 内）
// 结构：
//   PTOverlay（窗口管理）
//   ├─ PTOverlayPlansVC   方案列表（左滑删除 / 新增方案）
//   ├─ PTOverlayPlanVC    方案页（名称 / 记录 / 映射区 / 新增映射）
//   ├─ PTOverlayLearnVC   学习页（大白屏录制）
//   └─ PTOverlayActionVC  动作设置（绿点①点击/双击；①②起点终点+速度滑动）
// ============================================================

#import "OverlayUI.h"
#import <objc/runtime.h>

// ---------- 面板子 VC 接口（供 PTOverlay 调用） ----------
@interface PTOverlayPlansVC : UIViewController
- (void)reload;
@end

@interface PTOverlayPlanVC : UIViewController
@property (nonatomic, strong) NSString *planName;
- (void)reload;
@end

@interface PTOverlayLearnVC : UIViewController
@property (nonatomic, strong) NSString *planName;
- (void)feedback:(int)count dir:(double)dir stable:(BOOL)stable rejected:(NSString *)rejected;
- (void)onStable;
- (void)onTooMany;
@end

@interface PTOverlayActionVC : UIViewController
@property (nonatomic, strong) NSString *actionType;
@property (nonatomic, strong) NSString *planName;
@end

static NSString *PTDirName(double dir) {
    if (dir >= 45 && dir <= 135) return @"下";
    if (dir > 135 || dir < -135) return @"左";
    if (dir >= -135 && dir < -45) return @"上";
    return @"右";
}

static NSString *PTActionText(NSDictionary *a) {
    NSString *t = a[@"type"];
    if ([t isEqualToString:@"tap"]) return [NSString stringWithFormat:@"点击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"doubleTap"]) return [NSString stringWithFormat:@"双击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%d,%d)→(%d,%d)", (int)[a[@"x1"] doubleValue], (int)[a[@"y1"] doubleValue], (int)[a[@"x2"] doubleValue], (int)[a[@"y2"] doubleValue]];
    if ([t isEqualToString:@"delay"]) return [NSString stringWithFormat:@"延迟 %.0fms", [a[@"ms"] doubleValue]];
    if ([t isEqualToString:@"volumeUp"]) return @"音量+";
    if ([t isEqualToString:@"volumeDown"]) return @"音量-";
    if ([t isEqualToString:@"muteToggle"]) return @"静音切换";
    return t;
}

#pragma mark - 窗口管理

static UIWindow *gWin = nil;
static UINavigationController *gNav = nil;

@implementation PTOverlay

+ (void)install {
    if (gWin) return;
    gWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gWin.windowLevel = UIWindowLevelStatusBar + 1;
    gWin.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];   // 半黑窗帘
    gWin.hidden = YES;
    gNav = [[UINavigationController alloc] initWithRootViewController:[PTOverlayPlansVC new]];
    gNav.navigationBar.tintColor = [UIColor systemBlueColor];
    gWin.rootViewController = gNav;
}

+ (BOOL)isVisible { return gWin && !gWin.hidden; }

+ (void)show {
    if (!gWin) [self install];
    // 从方案列表刷新进入
    [gNav setViewControllers:@[[PTOverlayPlansVC new]] animated:NO];
    gWin.hidden = NO;
}

+ (void)hide { gWin.hidden = YES; }

+ (void)toggle { [self isVisible] ? [self hide] : [self show]; }

+ (void)refreshPlans {
    // 若当前顶层是方案列表/方案页 → 刷新
    if (![self isVisible]) return;
    UIViewController *top = gNav.topViewController;
    if ([top isKindOfClass:[PTOverlayPlansVC class]]) [(PTOverlayPlansVC *)top reload];
    if ([top isKindOfClass:[PTOverlayPlanVC class]]) [(PTOverlayPlanVC *)top reload];
}

+ (void)learnFeedback:(int)count dir:(double)dir stable:(BOOL)stable rejected:(NSString *)rejected {
    UIViewController *top = gNav.topViewController;
    if ([top isKindOfClass:[PTOverlayLearnVC class]]) {
        [(PTOverlayLearnVC *)top feedback:count dir:dir stable:stable rejected:rejected];
    }
}

+ (void)learnStable {
    UIViewController *top = gNav.topViewController;
    if ([top isKindOfClass:[PTOverlayLearnVC class]]) [(PTOverlayLearnVC *)top onStable];
}

+ (void)learnTooMany {
    UIViewController *top = gNav.topViewController;
    if ([top isKindOfClass:[PTOverlayLearnVC class]]) [(PTOverlayLearnVC *)top onTooMany];
}

@end

#pragma mark - 方案列表

@implementation PTOverlayPlansVC {
    NSMutableArray *_plans;   // 字典数组
    UITableView *_table;
    UILabel *_hint;
}

- (instancetype)init { self = [super init]; if (self) self.title = @"记录与映射"; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"收起" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    [self reload];
}

- (void)close { [PTOverlay hide]; }

- (void)reload {
    NSDictionary *cfg = PTGetConfig();
    _plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
    if (!_table) {
        _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
        _table.dataSource = self;
        _table.delegate = self;
        [self.view addSubview:_table];
        _hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, self.view.bounds.size.width - 32, 44)];
        _hint.text = @"方案 = 一个被拦截的按键。左滑可删除方案。";
        _hint.font = [UIFont systemFontOfSize:12];
        _hint.textColor = [UIColor secondaryLabelColor];
        _table.tableHeaderView = _hint;
    }
    [_table reloadData];
}

#pragma mark UITableView
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec { return _plans.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"plan";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (ip.row < (NSInteger)_plans.count) {
        NSDictionary *p = _plans[ip.row];
        c.textLabel.text = p[@"name"] ?: @"（未命名）";
        NSDictionary *ft = p[@"feature"];
        NSArray *acts = p[@"actions"] ?: @[];
        if (ft) {
            NSString *d = PTDirName([ft[@"direction"] doubleValue]);
            NSString *ph = [ft[@"phase"] intValue] == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", d];
            c.detailTextLabel.text = [NSString stringWithFormat:@"特征：%@ ｜ 动作 %lu 条", ph, (unsigned long)acts.count];
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
    if (ip.row < (NSInteger)_plans.count) {
        PTOverlayPlanVC *vc = [PTOverlayPlanVC new];
        vc.planName = _plans[ip.row][@"name"];
        [gNav pushViewController:vc animated:YES];
    } else {
        // 新增方案：创建空方案并进入
        NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:PTGetConfig()];
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        NSString *name = [NSString stringWithFormat:@"新方案%lu", (unsigned long)(plans.count + 1)];
        [plans addObject:@{ @"name": name, @"actions": @[] }];
        cfg[@"plans"] = plans;
        PTSaveConfig(cfg);
        PTOverlayPlanVC *vc = [PTOverlayPlanVC new];
        vc.planName = name;
        [gNav pushViewController:vc animated:YES];
    }
}
// 左滑删除
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)_plans.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        NSDictionary *p = _plans[ip.row];
        NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:PTGetConfig()];
        NSMutableArray *plans = [NSMutableArray array];
        for (NSDictionary *x in cfg[@"plans"] ?: @[]) {
            if (![x[@"name"] isEqualToString:p[@"name"]]) [plans addObject:x];
        }
        cfg[@"plans"] = plans;
        PTSaveConfig(cfg);
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
@end

#pragma mark - 方案页

@implementation PTOverlayPlanVC {
    NSDictionary *_plan;
    UITextField *_nameField;
    UITableView *_table;
    UILabel *_recStatus;
    NSMutableArray *_actions;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self reload];
}

- (void)reload {
    for (NSDictionary *p in PTGetConfig()[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) { _plan = p; break; }
    }
    if (!_plan) return;
    _actions = [NSMutableArray arrayWithArray:_plan[@"actions"] ?: @[]];

    if (!_nameField) {
        CGFloat w = self.view.bounds.size.width;
        _nameField = [[UITextField alloc] initWithFrame:CGRectMake(16, 12, w - 32, 36)];
        _nameField.borderStyle = UITextBorderStyleRoundedRect;
        _nameField.font = [UIFont systemFontOfSize:16];
        _nameField.placeholder = @"方案名称（如：左键）";
        [_nameField addTarget:self action:@selector(nameChanged) forControlEvents:UIControlEventEditingChanged];
        [self.view addSubview:_nameField];

        _recStatus = [[UILabel alloc] initWithFrame:CGRectMake(16, 54, w - 32, 30)];
        _recStatus.font = [UIFont systemFontOfSize:13];
        _recStatus.textColor = [UIColor labelColor];
        _recStatus.userInteractionEnabled = YES;
        [_recStatus addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recordTapped)]];
        [self.view addSubview:_recStatus];

        _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 90, w, self.view.bounds.size.height - 90) style:UITableViewStylePlain];
        _table.dataSource = self;
        _table.delegate = self;
        [self.view addSubview:_table];
        _table.tableHeaderView = [self headerView];
    }
    _nameField.text = self.planName;
    if (_plan[@"feature"]) {
        NSDictionary *ft = _plan[@"feature"];
        NSString *d = PTDirName([ft[@"direction"] doubleValue]);
        NSString *ph = [ft[@"phase"] intValue] == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", d];
        _recStatus.text = [NSString stringWithFormat:@"✅ 已录制完成：%@（%d次）—— 点我清空重录", ph, [ft[@"recordCount"] intValue]];
        _recStatus.textColor = [UIColor systemGreenColor];
    } else {
        _recStatus.text = @"【新增记录】点我进入录制";
        _recStatus.textColor = [UIColor systemBlueColor];
    }
    [_table reloadData];
}

- (UIView *)headerView {
    UIView *hv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, self.view.bounds.size.width - 32, 20)];
    l.text = @"映射区：按一次该键 → 从上到下依次执行全部动作";
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = [UIColor secondaryLabelColor];
    [hv addSubview:l];
    return hv;
}

- (void)nameChanged {
    NSString *newName = [_nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!newName.length || [newName isEqualToString:self.planName]) return;
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:PTGetConfig()];
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
    PTSaveConfig(cfg);
}

- (void)recordTapped {
    if (_plan[@"feature"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"重新录制？"
            message:@"将清空已录制的特征，重新进入录制页" preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"清空重录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:PTGetConfig()];
            NSMutableArray *plans = [NSMutableArray array];
            for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
                if ([p[@"name"] isEqualToString:self.planName]) {
                    NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
                    [np removeObjectForKey:@"feature"];
                    [plans addObject:np];
                } else [plans addObject:p];
            }
            cfg[@"plans"] = plans;
            PTSaveConfig(cfg);
            PTOverlayLearnVC *vc = [PTOverlayLearnVC new];
            vc.planName = self.planName;
            [gNav pushViewController:vc animated:YES];
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else {
        PTOverlayLearnVC *vc = [PTOverlayLearnVC new];
        vc.planName = self.planName;
        [gNav pushViewController:vc animated:YES];
    }
}

#pragma mark UITableView
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _actions.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"act";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    if (ip.row < (NSInteger)_actions.count) {
        c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(ip.row + 1), PTActionText(_actions[ip.row])];
        c.accessoryType = UITableViewCellAccessoryNone;
    } else {
        c.textLabel.text = @"新增映射";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)_actions.count) [self addActionMenu];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)_actions.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        [_actions removeObjectAtIndex:ip.row];
        [self saveActions];
        [tv reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (void)addActionMenu {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"新增映射"
        message:@"选择要添加的动作" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *items = @[
        @[@"点击", @"tap"], @[@"双击", @"doubleTap"], @[@"滑动", @"swipe"],
        @[@"延迟", @"delay"], @[@"静音", @"muteToggle"], @[@"音量+", @"volumeUp"], @[@"音量-", @"volumeDown"]];
    for (NSArray *it in items) {
        [al addAction:[UIAlertAction actionWithTitle:it[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self configAction:it[1]];
        }]];
    }
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)configAction:(NSString *)type {
    if ([type isEqualToString:@"delay"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"延迟"
            message:@"输入延迟毫秒数（如 500 = 0.5 秒）" preferredStyle:UIAlertControllerStyleAlert];
        [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.keyboardType = UIKeyboardTypeNumberPad; tf.placeholder = @"500"; }];
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            double ms = [al.textFields.firstObject.text doubleValue];
            if (ms > 0) { [_actions addObject:@{@"type": @"delay", @"ms": @(ms)}]; [self saveActions]; }
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else if ([type isEqualToString:@"volumeUp"] || [type isEqualToString:@"volumeDown"] || [type isEqualToString:@"muteToggle"]) {
        [_actions addObject:@{@"type": type}];
        [self saveActions];
    } else {
        PTOverlayActionVC *vc = [PTOverlayActionVC new];
        vc.actionType = type;
        vc.planName = self.planName;
        [gNav pushViewController:vc animated:YES];
    }
}

- (void)saveActions {
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:PTGetConfig()];
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"actions"] = _actions;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTSaveConfig(cfg);
    [_table reloadData];
}
@end

#pragma mark - 学习页

@implementation PTOverlayLearnVC {
    UILabel *_status;
    UILabel *_countLabel;
    UILabel *_dirLabel;
    UILabel *_distLabel;
    BOOL _finished;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"录制特征";
    self.view.backgroundColor = [UIColor whiteColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    _finished = NO;

    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    _status = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.22, w - 48, 60)];
    _status.text = @"请一直重复按同一个键\n直到提示特征已稳定";
    _status.numberOfLines = 0;
    _status.textAlignment = NSTextAlignmentCenter;
    _status.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [self.view addSubview:_status];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4, w - 48, 30)];
    _countLabel.text = @"已录：0 次";
    _countLabel.textAlignment = NSTextAlignmentCenter;
    _countLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:_countLabel];

    _dirLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 34, w - 48, 30)];
    _dirLabel.text = @"方向：—";
    _dirLabel.textAlignment = NSTextAlignmentCenter;
    _dirLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:_dirLabel];

    _distLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 68, w - 48, 30)];
    _distLabel.text = @"位移：—";
    _distLabel.textAlignment = NSTextAlignmentCenter;
    _distLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:_distLabel];

    PTSetLearning(YES);
}

- (void)back {
    PTSetLearning(NO);
    [gNav popViewControllerAnimated:YES];
}

- (void)feedback:(int)count dir:(double)dir stable:(BOOL)stable rejected:(NSString *)rejected {
    _countLabel.text = [NSString stringWithFormat:@"已录：%d 次", count];
    if (rejected) {
        _status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", rejected];
        _status.textColor = [UIColor systemRedColor];
        return;
    }
    _status.textColor = [UIColor labelColor];
    _dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
    if (stable) {
        _status.text = @"✅ 特征已稳定，可以停止";
        _status.textColor = [UIColor systemGreenColor];
    } else {
        _status.text = count < 5 ? @"请继续按同一个键…" : @"特征收敛中，请继续…";
    }
}

- (void)onStable {
    if (_finished) return;
    _finished = YES;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"特征已稳定"
        message:@"给这个按键命名（将生成映射方案）" preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"如：左键";
        tf.text = self.planName.length ? self.planName : @"";
    }];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { _finished = NO; }]];
    [al addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [al.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!name.length) name = @"新按键";
        self.planName = name;
        PTFinishLearning(name);   // 写入特征（同名更新/新增）
        PTSetLearning(NO);
        PTOverlayPlanVC *vc = [PTOverlayPlanVC new];
        vc.planName = name;
        [gNav setViewControllers:@[[PTOverlayPlansVC new], vc] animated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)onTooMany {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"特征波动太大"
        message:@"已录 15 次仍未稳定，建议检查按键或重录" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"继续录" style:UIAlertActionStyleDefault handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"重录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        PTClearLearning();
        _countLabel.text = @"已录：0 次";
        _dirLabel.text = @"方向：—";
        _distLabel.text = @"位移：—";
        _status.textColor = [UIColor labelColor];
        _status.text = @"请一直重复按同一个键\n直到提示特征已稳定";
    }]];
    [self presentViewController:al animated:YES completion:nil];
}
@end

#pragma mark - 动作设置页

@implementation PTOverlayActionVC {
    UIView *_dot1, *_dot2;
    UILabel *_posLabel;
    UISlider *_speedSlider;
    BOOL _isSwipe;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _isSwipe = [self.actionType isEqualToString:@"swipe"];
    self.title = _isSwipe ? @"滑动设置" : ([self.actionType isEqualToString:@"doubleTap"] ? @"双击设置" : @"点击设置");
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat areaH = h - 200;

    _posLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, areaH + 8, w - 32, 30)];
    _posLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    [self.view addSubview:_posLabel];

    UIView *area = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, areaH)];
    area.backgroundColor = [UIColor secondarySystemBackgroundColor];
    area.userInteractionEnabled = YES;
    [self.view addSubview:area];

    _dot1 = [self makeDot:area label:@"1" color:[UIColor systemGreenColor]];
    _dot1.center = CGPointMake(w * 0.3, areaH * 0.4);

    if (_isSwipe) {
        _dot2 = [self makeDot:area label:@"2" color:[UIColor systemOrangeColor]];
        _dot2.center = CGPointMake(w * 0.7, areaH * 0.6);
        UILabel *speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, areaH + 44, 80, 30)];
        speedLabel.text = @"速度";
        speedLabel.font = [UIFont systemFontOfSize:14];
        [self.view addSubview:speedLabel];
        _speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(100, areaH + 44, w - 116, 30)];
        _speedSlider.minimumValue = 100; _speedSlider.maximumValue = 600; _speedSlider.value = 200;
        [self.view addSubview:_speedSlider];
    }
    [self updatePos];
}

- (UIView *)makeDot:(UIView *)area label:(NSString *)label color:(UIColor *)color {
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    dot.layer.cornerRadius = 22;
    dot.backgroundColor = [color colorWithAlphaComponent:0.35];
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = color.CGColor;
    UILabel *l = [[UILabel alloc] initWithFrame:dot.bounds];
    l.text = label;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor labelColor];
    l.font = [UIFont boldSystemFontOfSize:16];
    [dot addSubview:l];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [dot addGestureRecognizer:pan];
    [area addSubview:dot];
    return dot;
}

- (void)drag:(UIPanGestureRecognizer *)g {
    UIView *dot = g.view;
    CGPoint t = [g translationInView:dot.superview];
    dot.center = CGPointMake(dot.center.x + t.x, dot.center.y + t.y);
    // 边界约束
    CGFloat w = dot.superview.bounds.size.width, h = dot.superview.bounds.size.height;
    dot.center = CGPointMake(MAX(22, MIN(w - 22, dot.center.x)), MAX(22, MIN(h - 22, dot.center.y)));
    [g setTranslation:CGPointZero inView:dot.superview];
    [self updatePos];
}

- (void)updatePos {
    CGFloat w = self.view.bounds.size.width;
    if (_isSwipe) {
        _posLabel.text = [NSString stringWithFormat:@"滑动 起点(%d,%d) → 终点(%d,%d)",
            (int)_dot1.center.x, (int)_dot1.center.y, (int)_dot2.center.x, (int)_dot2.center.y];
        if (_speedSlider) _posLabel.text = [_posLabel.text stringByAppendingFormat:@"  速度%.0fms", _speedSlider.value];
    } else {
        _posLabel.text = [NSString stringWithFormat:@"%@(%d, %d)",
            [self.actionType isEqualToString:@"doubleTap"] ? @"双击" : @"点击",
            (int)_dot1.center.x, (int)_dot1.center.y];
    }
}

- (void)done {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    if (_isSwipe) {
        a[@"type"] = @"swipe";
        a[@"x1"] = @(_dot1.center.x); a[@"y1"] = @(_dot1.center.y);
        a[@"x2"] = @(_dot2.center.x); a[@"y2"] = @(_dot2.center.y);
        a[@"speed"] = @(_speedSlider.value);
    } else {
        a[@"type"] = self.actionType;
        a[@"x"] = @(_dot1.center.x); a[@"y"] = @(_dot1.center.y);
    }
    // 追加到方案 actions
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:PTGetConfig()];
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
            [acts addObject:a];
            np[@"actions"] = acts;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTSaveConfig(cfg);
    [gNav popViewControllerAnimated:YES];
}
@end
