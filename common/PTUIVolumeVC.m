// ============================================================
// PTUIVolumeVC.m —— 音量键模式页实现（v1.0.80）
//
// 布局（一屏看完 + 四重分开——用户定稿演示过的口径）：
//   ① 设置卡（系统设置风圆角卡片）：总开关「音量键模式」+「隐藏系统音量条」
//   ② 音量+ 映射区：绿区头（色条+标题+说明）+ 动作表（拖拽排序/左滑删/点按编辑）
//   ③ 音量- 映射区：红区头 + 同款动作表
//   ④ 底部唯一测试行：测试页通用（翻页器/音量键都能测）
// 分开手法：分组卡片 / 区头色条（绿 systemGreen / 红 systemRed）/ 区间距 /
// 区头文案（「按音量+ 键 → 依次执行」）四重叠加。
//
// 数据模型：两个 volSource 特殊方案（vol-up / vol-down，PTEnsureVolPlans 懒
// 创建空壳）——与翻页器方案同一 plans[]、同一执行链（PTChainOnHit），列表
// 页过滤不显示、本页不提供删除（只能清空动作）。UI 侧只写配置，不起停机制
// （App 进程 PTDylibLoadConfig 检测 mtime 变化热启停，见 PTEngineConfig.m）。
//
// 编辑器全家复用（「跟平时的一样」）：PTUIPresentEditor（五种动作模板）/
// PTUIActionParamVC（长按不动）/ PTDragSortHelper（长按拖拽排序）/ 左滑删除
// / delay 输入弹窗——逐项对照 PTUIPlanVC 同款逻辑，不新造交互。
// 深色模式：全程系统语义色（见 check_darkmode.sh 速查表）。
// ============================================================
#import "PTUIVolumeVC.h"
#import "PTUICommon.h"
#import "PTDragSortHelper.h"
#import "PTUIActionParamVC.h"   // 长按不动 → 参数页
#import "PTUITestVC.h"          // 底部测试行

static const CGFloat kRowH    = 44.0;   // 动作行行高（表高自适应按此算）
static const CGFloat kCardPad = 16.0;   // 页面左右边距
static const CGFloat kGap     = 18.0;   // 区间距（「分开」手法之一）
static const CGFloat kZoneH   = 56.0;   // 区头高（buildUI 游标推进用）

@implementation PTUIVolumeVC {
    UIScrollView *_scroll;
    UISwitch *_swEnabled;     // 总开关
    UISwitch *_swHud;         // 隐藏系统音量条
    UILabel  *_upHint;        // 音量+ 区副标题（总闸关闭时改文案）
    UILabel  *_downHint;
    UIView   *_downBar;       // 音量- 区头条（relayout 显式重排用）
    UIButton *_bottomBtn;     // 底部唯一测试行
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音量键模式";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self buildUI];
    [self reload];
}

// 基类 viewWillAppear 自动调 reload（返回即刷新）
- (void)reload {
    NSMutableDictionary *cfg = self.readCfg;
    // 总闸/音量条开关回显（v1.0.80：volHudHidden 默认开——nil 视为开）
    _swEnabled.on = [cfg[@"volEnabled"] boolValue];
    _swHud.on = (cfg[@"volHudHidden"] == nil) ? YES : [cfg[@"volHudHidden"] boolValue];
    // 两区动作（特殊方案可能还没懒创建——刚进页面且没开过闸时为空）
    NSString *upPid   = PTVolPlanPid(cfg[@"plans"] ?: @[], kVolSourceUp);
    NSString *downPid = PTVolPlanPid(cfg[@"plans"] ?: @[], kVolSourceDown);
    NSDictionary *up   = upPid   ? PTUIPlanById(cfg[@"plans"] ?: @[], upPid)   : nil;
    NSDictionary *down = downPid ? PTUIPlanById(cfg[@"plans"] ?: @[], downPid) : nil;
    self.upActions   = [NSMutableArray arrayWithArray:up[@"actions"]   ?: @[]];
    self.downActions = [NSMutableArray arrayWithArray:down[@"actions"] ?: @[]];
    self.dragUp.items   = self.upActions;
    self.dragDown.items = self.downActions;
    // 总闸未开：区副标题提示（仍可预先配动作——配好再开闸）
    NSString *offHint = @"总开关未开启（可先配好动作）";
    _upHint.text   = _swEnabled.on ? @"按音量+ 键 → 依次执行下列动作" : offHint;
    _downHint.text = _swEnabled.on ? @"按音量- 键 → 依次执行下列动作" : offHint;
    [self.tv reloadData];
    [self.tv2 reloadData];
    [self relayout];
}

// ============================================================
// 布局搭建（frame 布局，与仓库其余页面一致）
// ============================================================
- (void)buildUI {
    CGFloat w = self.view.bounds.size.width;
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    CGFloat top = self.view.safeAreaInsets.top + 12;
    CGFloat cw = w - kCardPad * 2;

    // ---------- ① 设置卡 ----------
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(kCardPad, top, cw, 108)];
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 12;
    card.clipsToBounds = YES;
    [_scroll addSubview:card];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, cw - 90, 22)];
    l1.text = @"音量键模式";
    l1.font = [UIFont systemFontOfSize:16];
    l1.textColor = [UIColor labelColor];
    [card addSubview:l1];
    _swEnabled = [[UISwitch alloc] initWithFrame:CGRectMake(cw - 16 - 51, 9, 51, 31)];
    [_swEnabled addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:_swEnabled];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(16, 51, cw - 32, 0.5)];
    sep.backgroundColor = [UIColor separatorColor];
    [card addSubview:sep];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, cw - 90, 22)];
    l2.text = @"隐藏系统音量条";
    l2.font = [UIFont systemFontOfSize:16];
    l2.textColor = [UIColor labelColor];
    [card addSubview:l2];
    UILabel *l2s = [[UILabel alloc] initWithFrame:CGRectMake(16, 82, cw - 90, 16)];
    l2s.text = @"开启后按音量键不弹出系统音量提示";
    l2s.font = [UIFont systemFontOfSize:12];
    l2s.textColor = [UIColor secondaryLabelColor];
    [card addSubview:l2s];
    _swHud = [[UISwitch alloc] initWithFrame:CGRectMake(cw - 16 - 51, 60, 51, 31)];
    [_swHud addTarget:self action:@selector(hudChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:_swHud];

    // ---------- ② 音量+ 区（绿区头 + 表1） ----------
    // 踩坑记录（v1.0.80 CI 实证）：hintOut:(UILabel **) 在 ARC 下隐含 __autoreleasing，
    // 不能直接 &ivar 写回（passing address of non-local object…write-back）——局部中转。
    top += 108 + kGap;
    UILabel *upHint = nil;
    [self addZoneHeaderAt:top color:[UIColor systemGreenColor] title:@"音量+ 映射区"
                    hint:@"按音量+ 键 → 依次执行下列动作" hintOut:&upHint];
    _upHint = upHint;
    top += kZoneH + 8;
    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(kCardPad, top, cw, 0)
                                          style:UITableViewStyleGrouped];
    self.tv.dataSource = self;   // v1.0.80：两个表都设（check_table_wiring 门禁 + 共享 VC 口径）
    self.tv.delegate = self;
    [_scroll addSubview:self.tv];

    // ---------- ③ 音量- 区（红区头 + 表2） ----------
    top += kGap;
    UILabel *downHint = nil;
    _downBar = [self addZoneHeaderAt:top color:[UIColor systemRedColor] title:@"音量- 映射区"
                              hint:@"按音量- 键 → 依次执行下列动作" hintOut:&downHint];
    _downHint = downHint;
    top += kZoneH + 8;
    self.tv2 = [[UITableView alloc] initWithFrame:CGRectMake(kCardPad, top, cw, 0)
                                           style:UITableViewStyleGrouped];
    self.tv2.dataSource = self;
    self.tv2.delegate = self;
    [_scroll addSubview:self.tv2];

    // ---------- ④ 底部唯一测试行（绿底白字，通用测试页） ----------
    top += kGap;
    _bottomBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _bottomBtn.frame = CGRectMake(kCardPad, top, cw, 50);
    _bottomBtn.backgroundColor = [UIColor systemGreenColor];
    _bottomBtn.layer.cornerRadius = 12;
    _bottomBtn.clipsToBounds = YES;
    [_bottomBtn setTitle:@"▶ 测试音量键（大白屏 + 绿点点触验证）" forState:UIControlStateNormal];
    [_bottomBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _bottomBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [_bottomBtn addTarget:self action:@selector(testTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_bottomBtn];

    // ---------- 拖拽助手（cells 模式：每区一个，天然不跨区混排） ----------
    __weak typeof(self) wself = self;

    self.dragUp = [[PTDragSortHelper alloc] initWithTableView:self.tv mode:PTDragAttachCells];
    self.dragUp.canDragRow = ^BOOL(NSInteger row) {
        return row < (NSInteger)wself.upActions.count;   // 末行「新增映射」不拖
    };
    self.dragUp.onReorder = ^(NSArray *ordered) {
        wself.upActions = [NSMutableArray arrayWithArray:ordered];
        [wself saveActionsForSource:kVolSourceUp actions:wself.upActions];
    };
    self.dragUp.onLongPressStill = ^(NSInteger row) {
        // 长按不动 → 参数页（与 PTUIPlanVC 同款）
        if (row >= (NSInteger)wself.upActions.count) return;
        PTUIActionParamVC *vc = [PTUIActionParamVC new];
        vc.planId = kVolPidUp;
        vc.actionIndex = row;
        vc.action = wself.upActions[row];
        [wself.navigationController pushViewController:vc animated:YES];
    };

    self.dragDown = [[PTDragSortHelper alloc] initWithTableView:self.tv2 mode:PTDragAttachCells];
    self.dragDown.canDragRow = ^BOOL(NSInteger row) {
        return row < (NSInteger)wself.downActions.count;
    };
    self.dragDown.onReorder = ^(NSArray *ordered) {
        wself.downActions = [NSMutableArray arrayWithArray:ordered];
        [wself saveActionsForSource:kVolSourceDown actions:wself.downActions];
    };
    self.dragDown.onLongPressStill = ^(NSInteger row) {
        if (row >= (NSInteger)wself.downActions.count) return;
        PTUIActionParamVC *vc = [PTUIActionParamVC new];
        vc.planId = kVolPidDown;
        vc.actionIndex = row;
        vc.action = wself.downActions[row];
        [wself.navigationController pushViewController:vc animated:YES];
    };

    [self relayout];
}

// 表高按内容自适应 + 垂直重排（显式持有各视图，不猜 subviews）：
// 表1（y 不变，高 = (动作数+1)*行高 + grouped 上下内边距余量；iOS 15+ grouped 有
// sectionHeaderTopPadding，余量给足防裁切）→ 音量- 区头条 → 表2 → 测试钮 → contentSize
- (void)relayout {
    CGFloat w  = self.view.bounds.size.width;
    CGFloat cw = w - kCardPad * 2;
    CGFloat h1 = (self.upActions.count + 1) * kRowH + 36;
    CGFloat h2 = (self.downActions.count + 1) * kRowH + 36;

    CGRect f1 = self.tv.frame;
    f1.size.height = h1;
    self.tv.frame = f1;

    CGFloat y = CGRectGetMaxY(self.tv.frame) + kGap;
    CGRect fb = _downBar.frame;
    fb.origin.y = y;
    _downBar.frame = fb;
    y += fb.size.height + 8;

    CGRect f2 = self.tv2.frame;
    f2.origin.y = y;
    f2.size.height = h2;
    self.tv2.frame = f2;

    y += h2 + kGap;
    CGRect ft = _bottomBtn.frame;
    ft.origin.y = y;
    _bottomBtn.frame = ft;

    _scroll.contentSize = CGSizeMake(w, y + ft.size.height + 28);
}

// 区头：左色条 + 标题 + 副标题（四重分开手法的「色带+文案」两重）
// 返回 bar（调用方显式持有——音量- 区头 relayout 要按引用重排，不遍历 subviews 猜）
- (UIView *)addZoneHeaderAt:(CGFloat)y color:(UIColor *)color title:(NSString *)title
                     hint:(NSString *)hint hintOut:(UILabel **)hintOut {
    CGFloat w = self.view.bounds.size.width - kCardPad * 2;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(kCardPad, y, w, kZoneH)];
    bar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    bar.layer.cornerRadius = 10;
    bar.clipsToBounds = YES;
    UIView *strip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5, kZoneH)];
    strip.backgroundColor = color;
    [bar addSubview:strip];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, w - 28, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    t.textColor = [UIColor labelColor];
    [bar addSubview:t];
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(14, 30, w - 28, 18)];
    h.text = hint;
    h.font = [UIFont systemFontOfSize:12];
    h.textColor = [UIColor secondaryLabelColor];
    [bar addSubview:h];
    if (hintOut) *hintOut = h;
    [_scroll addSubview:bar];
    return bar;
}

#pragma mark - 开关

// 总开关：写 volEnabled；首次开启时懒创建两个特殊方案空壳（PTEnsureVolPlans）
- (void)enabledChanged:(UISwitch *)sw {
    NSMutableDictionary *cfg = self.readCfg;
    cfg[@"volEnabled"] = @(sw.on);
    if (sw.on) PTEnsureVolPlans(cfg);   // 幂等：缺哪个建哪个空壳
    [self writeCfg:cfg];
    [self reload];
    if (sw.on) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"音量键模式已开启"
            message:@"在下方两个映射区添加动作。回到阅读 App 后按音量+ / 音量- 即触发（与翻页器同一套连滑规则）。"
            preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    }
}

// 隐藏系统音量条：只写配置——App 进程 PTDylibLoadConfig 检测到变化即热应用
- (void)hudChanged:(UISwitch *)sw {
    NSMutableDictionary *cfg = self.readCfg;
    cfg[@"volHudHidden"] = @(sw.on);
    [self writeCfg:cfg];
}

#pragma mark - 测试行（底部唯一，通用）

- (void)testTapped {
    PTUITestVC *vc = [PTUITestVC new];
    vc.planName = @"音量键模式";   // 仅显示用（测试页按特征匹配执行，不按 pid 写方案）
    vc.volumeMode = YES;          // v1.0.80：文案切「按音量+ / 音量- 键测试」
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - UITableView（两个表共用一份 dataSource，按表指针分发）

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    NSMutableArray *acts = [self actionsForTable:tv];
    return acts.count + 1;   // + 末行「新增映射」
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"volAct";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSMutableArray *acts = [self actionsForTable:tv];
    if (ip.row < (NSInteger)acts.count) {
        c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(ip.row + 1), PTActionText(acts[ip.row])];
        c.textLabel.textColor = [UIColor labelColor];   // v1.0.66：显式设色防复用串色
        c.accessoryType = UITableViewCellAccessoryNone;
        if (tv == self.tv) [self.dragUp attachToCell:c]; else [self.dragDown attachToCell:c];
    } else {
        c.textLabel.text = @"＋ 新增映射";
        c.textLabel.textColor = [UIColor systemBlueColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (tv == self.tv) { if ([self.dragUp consumeJustDragged]) return; }
    else               { if ([self.dragDown consumeJustDragged]) return; }
    NSMutableArray *acts = [self actionsForTable:tv];
    BOOL isUp = (tv == self.tv);
    NSString *pid = isUp ? kVolPidUp : kVolPidDown;
    NSString *src = isUp ? kVolSourceUp : kVolSourceDown;
    if (ip.row < (NSInteger)acts.count) {
        // 点行动作 → 编辑（逐项对照 PTUIPlanVC didSelect 的分发逻辑）
        NSDictionary *act = acts[ip.row];
        NSString *type = act[@"type"];
        if ([type isEqualToString:@"recSwipe"]) {
            PTUIPresentEditor(self, PTOverlayModeRecSwipe, pid, ip.row, act, [self refreshAfterSave]);
            return;
        }
        if (![type isEqualToString:@"delay"]) {
            PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                            : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
            PTUIPresentEditor(self, mode, pid, ip.row, act, [self refreshAfterSave]);
        } else {
            PTUIActionParamVC *vc = [PTUIActionParamVC new];
            vc.planId = pid;
            vc.actionIndex = ip.row;
            vc.action = act;
            [self.navigationController pushViewController:vc animated:YES];
        }
        return;
    }
    [self addActionMenuForSource:src pid:pid acts:acts];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSMutableArray *acts = [self actionsForTable:tv];
    if (ip.row >= (NSInteger)acts.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        [acts removeObjectAtIndex:ip.row];
        [self saveActionsForSource:(tv == self.tv ? kVolSourceUp : kVolSourceDown) actions:acts];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

#pragma mark - 新增映射（同 PTUIPlanVC 五种动作）

- (void)addActionMenuForSource:(NSString *)src pid:(NSString *)pid acts:(NSMutableArray *)acts {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"新增映射"
        message:@"选择要添加的动作" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *items = @[
        @[@"点击", @"tap"], @[@"双击", @"doubleTap"], @[@"滑动", @"swipe"],
        @[@"滑动(手动)", @"recSwipe"], @[@"延迟", @"delay"]];   // v1.0.48：音量动作类型已删除（音量键即触发源，不再作为动作）
    for (NSArray *it in items) {
        __weak typeof(self) wself = self;
        [al addAction:[UIAlertAction actionWithTitle:it[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [wself configAction:it[1] pid:pid src:src acts:acts];
        }]];
    }
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)configAction:(NSString *)type pid:(NSString *)pid src:(NSString *)src acts:(NSMutableArray *)acts {
    if ([type isEqualToString:@"recSwipe"]) {
        PTUIPresentEditor(self, PTOverlayModeRecSwipe, pid, -1, nil, [self refreshAfterSave]);
    } else if ([type isEqualToString:@"delay"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"延迟"
            message:@"输入延迟毫秒数（如 500 = 0.5 秒）" preferredStyle:UIAlertControllerStyleAlert];
        [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.keyboardType = UIKeyboardTypeNumberPad; tf.text = @"500"; }];
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            double ms = [al.textFields.firstObject.text doubleValue];
            if (ms > 0) {
                [acts addObject:@{@"type": @"delay", @"ms": @(ms)}];
                [self saveActionsForSource:src actions:acts];
            }
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else {
        PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                        : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
        PTUIPresentEditor(self, mode, pid, -1, nil, [self refreshAfterSave]);   // editIndex=-1 = 新增
    }
}

- (PTUIEditorSavedBlock)refreshAfterSave {
    __weak typeof(self) wself = self;
    return ^{ [wself reload]; };
}

#pragma mark - 配置写回（按 volSource 定位特殊方案，替换 actions）

- (void)saveActionsForSource:(NSString *)src actions:(NSArray *)actions {
    NSMutableDictionary *cfg = self.readCfg;
    NSMutableArray *plans = [NSMutableArray array];
    NSArray *raw = cfg[@"plans"] ?: @[];
    BOOL hit = NO;
    for (NSUInteger i = 0; i < raw.count; i++) {
        NSDictionary *p = raw[i];
        if ([p isKindOfClass:[NSDictionary class]] && [p[@"volSource"] isEqualToString:src]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"actions"] = actions;
            [plans addObject:np];
            hit = YES;
        } else [plans addObject:p];
    }
    if (!hit) return;   // 方案不存在（异常路径：没开过闸却写动作）——不凭空建
    cfg[@"plans"] = plans;
    [self writeCfg:cfg];
    [self.tv reloadData];
    [self.tv2 reloadData];
    [self relayout];
}

- (NSMutableArray *)actionsForTable:(UITableView *)tv {
    return (tv == self.tv) ? self.upActions : self.downActions;
}

@end
