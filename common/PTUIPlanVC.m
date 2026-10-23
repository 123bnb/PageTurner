// ============================================================
// PTUIPlanVC.m —— 方案页实现（v1.0.77 共享版）
//
// 统一口径（原两侧漂移 → 本版裁定）：
//   · 排序：一律长按拖拽 Z 方案（deb v1.0.66 #5b：点按=编辑、长按不动=参数页、
//     长按并拖动=排序）；dylib 旧版右上角「排序」+ 系统编辑态手柄已删除
//   · 定位/写回：一律按 pid（PTUIPlanById / PTUIPlanIndexById / PTUISaveActionToPlan）
//   · 废案动作（tapManual/doubleTapManual）：一律弹提示不进编辑页（deb 口径；
//     dylib 旧版静默转换成 tap/doubleTap——会改坏旧配置语义，废弃）
//   · 覆盖页呈现：走每 target 的 PTUIPresentEditor（deb=全屏 modal 不透明；
//     dylib=独立 UIWindow 半透明 + 关/显菜单），保存逻辑统一
// ============================================================
#import "PTUIPlanVC.h"
#import "PTUICommon.h"
#import "PTDragSortHelper.h"
#import "PTUIFeaturesVC.h"     // 记录特征
#import "PTUILearnVC.h"        // 学习页入口
#import "PTUIActionParamVC.h"  // 动作参数页
#import "PTUITestVC.h"         // 测试页入口

@implementation PTUIPlanVC

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.35：统一成系统设置灰分组背景
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self reload];
}

// v1.0.29（问题2）：从动作设置页/参数页返回时重读动作，映射区立即显示新增/修改
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSDictionary *plan = PTUIPlanById(self.readCfg[@"plans"] ?: @[], self.planId);   // 按 pid 定位，重名不串
    if (!plan) { [self.navigationController popViewControllerAnimated:YES]; return; }
    self.planName = plan[@"name"] ?: @"";   // 仅作显示用
    self.actions = [NSMutableArray arrayWithArray:plan[@"actions"] ?: @[]];

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width;

    if (!self.nameLabel) {
        // v1.0.28：方案名一行显示「方案名： xxxxx」，点击弹框改名
        // v1.0.35：改白底圆角卡片样式（像系统设置输入框），文字居中，点击弹框改名
        self.nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top, w - 32, 40)];
        self.nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        self.nameLabel.backgroundColor = [UIColor systemBackgroundColor];
        self.nameLabel.layer.cornerRadius = 10;
        self.nameLabel.clipsToBounds = YES;
        self.nameLabel.textAlignment = NSTextAlignmentCenter;
        self.nameLabel.userInteractionEnabled = YES;
        [self.nameLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(renameTapped)]];
        [self.view addSubview:self.nameLabel];

        // 记录按钮：大按钮样式（蓝底白字），与下方「新增映射」视觉统一、紧凑
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

        // v1.0.34：增加特征按钮（紧挨记录按钮下方）——录单个特征，以最后一次为准
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

        // v1.0.28：映射区说明水平居中 + 字号 15
        UILabel *hv = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 32, 34)];
        hv.text = @"映射区：按一次该键 → 从上到下依次执行全部动作（点按=编辑，长按=参数，长按拖动=排序）";
        hv.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        hv.textColor = [UIColor labelColor];
        hv.textAlignment = NSTextAlignmentCenter;
        self.tv.tableHeaderView = hv;

        // v1.0.66(#5b)：Z 方案——动作行长按拖拽排序（共享助手，dylib 同交互）
        self.dragHelper = [[PTDragSortHelper alloc] initWithTableView:self.tv mode:PTDragAttachCells];
        __weak typeof(self) wself = self;
        self.dragHelper.canDragRow = ^BOOL(NSInteger row) {
            return row < (NSInteger)wself.actions.count;   // 「新增映射/测试」两行不拖
        };
        self.dragHelper.onDragRejected = ^(NSInteger row) {
            if (row >= (NSInteger)wself.actions.count) return;
            [wself showDeprecatedActionAlert:wself.actions[row][@"type"]];
        };
        self.dragHelper.onReorder = ^(NSArray *ordered) {
            wself.actions = [NSMutableArray arrayWithArray:ordered];
            [wself saveActions];
        };
        self.dragHelper.onLongPressStill = ^(NSInteger row) {
            // 长按不动 → 参数页
            PTUIActionParamVC *vc = [PTUIActionParamVC new];
            vc.planId = wself.planId;
            vc.actionIndex = row;
            vc.action = wself.actions[row];
            [wself.navigationController pushViewController:vc animated:YES];
        };
    }
    self.nameLabel.text = [NSString stringWithFormat:@"方案名： %@", self.planName];
    // v1.0.34：已录制显示特征条数，点击进特征列表页；未录显示新增记录
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

// 已删除动作（旧配置残留）提示——统一不带版本号（旧 deb 写 v1.0.48 / 旧 dylib 写 v1.0.5，
// 同一个弹窗两套版本号，用户截图反馈对不上；行为本身不变）
- (void)showDeprecatedActionAlert:(NSString *)type {
    if ([type isEqualToString:@"volumeUp"] || [type isEqualToString:@"volumeDown"] || [type isEqualToString:@"muteToggle"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"该动作已移除"
            message:@"音量+/音量-/静音切换已删除（注入环境音量读取不可靠）。请在编辑中删除这个动作，换成其它动作。"
            preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
        return;
    }
    if ([type isEqualToString:@"tapManual"] || [type isEqualToString:@"doubleTapManual"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"该动作已删除"
            message:@"点击(手动)/双击(手动)已删除（废案）。请在编辑中删除这个动作，换成其它动作。"
            preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
        return;
    }
}

// v1.0.28：点「方案名： xxxxx」弹框改名（保留改名功能）
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
        NSMutableDictionary *cfg = self.readCfg;
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        // 按 pid 定位要改名的方案，只改这一个（重名时不会把所有同名都改掉）
        NSInteger idx = PTUIPlanIndexById(plans, self.planId);
        if (idx >= 0) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:plans[idx]];
            np[@"name"] = newName;
            plans[idx] = np;
            cfg[@"plans"] = plans;
            [self writeCfg:cfg];
        }
        self.planName = newName;
        self.nameLabel.text = [NSString stringWithFormat:@"方案名： %@", newName];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)recordTapped {
    NSDictionary *plan = PTUIPlanById(self.readCfg[@"plans"] ?: @[], self.planId);
    // v1.0.34：已录制 → 进特征列表页（查看/重录/左滑删）；未录制 → 正常学习页
    if (PTFeaturesOfPlan(plan).count) {
        PTUIFeaturesVC *vc = [PTUIFeaturesVC new];
        vc.planId = self.planId;
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        PTUILearnVC *vc = [PTUILearnVC new];
        vc.planId = self.planId;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

// v1.0.34：增加特征——单特征学习页（按 1 次记录，再按覆盖，以最后一下为准），保存后加入已录入特征
- (void)addFeatureTapped {
    PTUILearnVC *vc = [PTUILearnVC new];
    vc.planId = self.planId;
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
        c.textLabel.textColor = [UIColor labelColor];   // v1.0.66：动作行显式设色，避免复用「新增映射/测试本方案」cell 时串色（黑→绿/蓝）
        c.accessoryType = UITableViewCellAccessoryNone;
        [self.dragHelper attachToCell:c];   // v1.0.66(#5b)：长按手势（内部先去重再挂）
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
    if ([self.dragHelper consumeJustDragged]) return;   // v1.0.66(#5b)：刚拖完排序，忽略松手带来的误触
    if (ip.row < (NSInteger)self.actions.count) {
        // v1.0.29（问题6）：点击动作行 → 进动作设置页编辑（预填坐标，完成覆盖更新）
        NSDictionary *act = self.actions[ip.row];
        NSString *type = act[@"type"];
        if ([type isEqualToString:@"volumeUp"] || [type isEqualToString:@"volumeDown"] || [type isEqualToString:@"muteToggle"] ||
            [type isEqualToString:@"tapManual"] || [type isEqualToString:@"doubleTapManual"]) {
            [self showDeprecatedActionAlert:type];   // 旧配置残留 → 提示，不进编辑页
            return;
        }
        // v1.0.62：滑动(手动)再次点击 → 统一模板重录（预载已有轨迹）
        if ([type isEqualToString:@"recSwipe"]) {
            PTUIPresentEditor(self, PTOverlayModeRecSwipe, self.planId, ip.row, act, [self refreshAfterSave]);
            return;
        }
        if (![type isEqualToString:@"delay"]) {
            PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                            : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
            PTUIPresentEditor(self, mode, self.planId, ip.row, act, [self refreshAfterSave]);
        } else {
            PTUIActionParamVC *vc = [PTUIActionParamVC new];
            vc.planId = self.planId;
            vc.actionIndex = ip.row;
            vc.action = act;
            [self.navigationController pushViewController:vc animated:YES];
        }
        return;
    }
    if (ip.row == (NSInteger)self.actions.count) { [self addActionMenu]; return; }
    // 最后一行：测试本方案（大白屏 + 绿点点触验证）
    PTUITestVC *vc = [PTUITestVC new];
    vc.planName = self.planName;   // 仅显示用（测试页按特征匹配执行，不按 pid 写方案）
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

- (void)addActionMenu {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"新增映射"
        message:@"选择要添加的动作" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *items = @[
        @[@"点击", @"tap"], @[@"双击", @"doubleTap"], @[@"滑动", @"swipe"],
        @[@"滑动(手动)", @"recSwipe"],   // v1.0.55：滑动(手动)改为统一模板录制（无穿透）；点击(手动)/双击(手动)已删
        @[@"延迟", @"delay"]];   // v1.0.48：音量+/音量-/静音切换动作类型已删除
    for (NSArray *it in items) {
        [al addAction:[UIAlertAction actionWithTitle:it[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self configAction:it[1]];
        }]];
    }
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)configAction:(NSString *)type {
    if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.62：滑动(手动)——统一模板（录制，落盘 @{x,y,t} 与运行端回放一致）
        PTUIPresentEditor(self, PTOverlayModeRecSwipe, self.planId, -1, nil, [self refreshAfterSave]);
    } else if ([type isEqualToString:@"delay"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"延迟"
            message:@"输入延迟毫秒数（如 500 = 0.5 秒）" preferredStyle:UIAlertControllerStyleAlert];
        [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.keyboardType = UIKeyboardTypeNumberPad; tf.text = @"500"; }];   // v1.0.66：真实预填 500（非 placeholder），空按【添加】即添加 500
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
        [al addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            double ms = [al.textFields.firstObject.text doubleValue];
            if (ms > 0) { [self.actions addObject:@{@"type": @"delay", @"ms": @(ms)}]; [self saveActions]; }
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else {
        PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                        : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
        // v1.0.38：editIndex=-1 表示新增，避免 done 里误覆盖第 1 条映射
        PTUIPresentEditor(self, mode, self.planId, -1, nil, [self refreshAfterSave]);
    }
}

// 编辑页保存后刷新（deb modal / dylib 窗口两条呈现路径都会在落盘后回调它）
- (PTUIEditorSavedBlock)refreshAfterSave {
    __weak typeof(self) wself = self;
    return ^{ [wself reload]; };
}

// v1.0.62：保存整组动作到方案（排序/删除/新增延迟后写回）
- (void)saveActions {
    NSMutableDictionary *cfg = self.readCfg;
    NSMutableArray *plans = [NSMutableArray array];
    NSArray *raw = cfg[@"plans"] ?: @[];
    for (NSUInteger i = 0; i < raw.count; i++) {
        NSDictionary *p = raw[i];
        if ([p isKindOfClass:[NSDictionary class]] && [PTPlanPid(p, (NSInteger)i) isEqualToString:self.planId]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"actions"] = self.actions;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    [self writeCfg:cfg];
    [self.tv reloadData];
}

// v1.0.53：跨进程手动录制（startManualRec/pollRecResult/applyRecResult）已整体删除——
// deb 版背景是设置页，半透明实地录制无意义；滑动(手动)改回统一模板直接录。
@end
