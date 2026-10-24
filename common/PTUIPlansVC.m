// ============================================================
// PTUIPlansVC.m —— 方案列表页实现（v1.0.77 共享版）
//
// 统一口径（原两侧漂移 → 本版裁定）：
//   · 排序：一律长按拖拽（deb v1.0.66 #5 的 Z 交互，自定义浮层快照）
//   · 删除：一律按 pid（dylib v1.0.75 口径；deb 旧版按行索引——拖拽后行索引会错位）
//   · 打开：一律按 pid 定位（重名不串）
// ============================================================
#import "PTUIPlansVC.h"
#import "PTUIPlanVC.h"     // 打开方案详情页（按 pid 定位）
#import "PTUIVolumeVC.h"   // v1.0.80：列表入口行「音量键模式」
#import "PTUICommon.h"
#import "PTDragSortHelper.h"

@implementation PTUIPlansVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"记录与映射";
    [self setupGroupedTableWithTop:100];
    // v1.0.79-fix1：补 dataSource/delegate 赋值——v1.0.71「8 页收敛共享 VC」时
    // 漏了这两行（基类 setupGroupedTableWithTop 只建 table，不设数据源），
    // deb 装机实测「记录与映射」打开一片空白：numberOfRowsInSection 永不被调用，
    // 连「新增方案」行都不渲染。同类页（Features/DebugLog/Plan）均有赋值，唯此页漏。
    self.tv.dataSource = self;
    self.tv.delegate = self;
    // v1.0.66(#5)：长按方案行拖拽排序（自定义浮层，零三横线）
    self.dragHelper = [[PTDragSortHelper alloc] initWithTableView:self.tv mode:PTDragAttachTable];
    __weak typeof(self) wself = self;
    self.dragHelper.canDragRow = ^BOOL(NSInteger row) {
        return row < (NSInteger)wself.plans.count;   // 末行「新增方案」不参与拖拽
    };
    self.dragHelper.onReorder = ^(NSArray *ordered) {
        NSMutableDictionary *cfg = wself.readCfg;
        // v1.0.80：音量特殊方案不参与列表排序（列表里根本不可见）——重排时原样
        // 保留在 plans[] 末尾，不能被 ordered（仅可见方案）整体覆盖丢掉
        NSMutableArray *keep = [NSMutableArray array];
        for (id p in (cfg[@"plans"] ?: @[])) {
            if ([p isKindOfClass:[NSDictionary class]] && p[@"volSource"]) [keep addObject:p];
        }
        NSMutableArray *merged = [NSMutableArray arrayWithArray:ordered];
        [merged addObjectsFromArray:keep];
        cfg[@"plans"] = merged;
        [wself writeCfg:cfg];
        [wself reload];
    };
    [self.dragHelper attachToTable];
    [self reload];
}

// v1.0.28 BUG-3：返回本页时重新读配置（新方案/改名/删除即时可见，不用重进页面）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    // v1.0.80：音量特殊方案（volSource 字段）不在列表显示——它们有独立页面
    // 「音量键模式」，经列表入口行进入；这里过滤掉，避免露出「音量+」这种
    // 点进去是空方案页（无特征可录）的怪异行
    NSMutableArray *all = [NSMutableArray arrayWithArray:self.readCfg[@"plans"] ?: @[]];
    NSMutableArray *visible = [NSMutableArray array];
    for (id p in all) {
        if ([p isKindOfClass:[NSDictionary class]] && p[@"volSource"]) continue;
        [visible addObject:p];
    }
    self.plans = visible;
    self.dragHelper.items = self.plans;
    [self.tv reloadData];
}

#pragma mark UITableView
// v1.0.80：+1 = 「音量键模式」入口行（倒数第二，「新增方案」仍固定末行）
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.plans.count + 2; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"plan";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (ip.row < (NSInteger)self.plans.count) {
        NSDictionary *p = self.plans[ip.row];
        c.textLabel.text = p[@"name"] ?: @"（未命名）";
        // v1.0.43：用 PTFeaturesOfPlan 兼容新格式 features[]（旧代码只查 p[@"feature"]，
        // 多特征方案一律误显示「未录制」——方案列表页全未录制的 bug 根因）
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
    } else if (ip.row == (NSInteger)self.plans.count) {
        // v1.0.80：「音量键模式」入口行（倒数第二）——音量+ / 音量- 映射为动作序列
        c.textLabel.text = @"音量键模式";
        c.detailTextLabel.text = @"音量+ / 音量- 映射为动作序列（与翻页器同一套连滑规则）";
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
    if ([self.dragHelper consumeJustDragged]) return;   // 刚拖完排序，忽略松手误触
    if (ip.row < (NSInteger)self.plans.count) {
        PTUIPlanVC *vc = [PTUIPlanVC new];
        vc.planId = PTPlanPid(self.plans[ip.row], ip.row);   // 按 pid 定位，重名不串
        [self.navigationController pushViewController:vc animated:YES];
    } else if (ip.row == (NSInteger)self.plans.count) {
        // v1.0.80：「音量键模式」入口行 → 独立页（总开关 + 音量+/- 双区 + 测试行）
        PTUIVolumeVC *vc = [PTUIVolumeVC new];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        NSMutableDictionary *cfg = self.readCfg;
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        // v1.0.80：命名按可见方案数（raw 里含两个音量特殊方案，按它编号会跳号）
        NSString *name = [NSString stringWithFormat:@"新方案%lu", (unsigned long)(self.plans.count + 1)];
        NSString *newPid = [[NSUUID UUID] UUIDString];   // 新建即带唯一 pid
        [plans addObject:@{ @"name": name, @"pid": newPid, @"actions": @[] }];
        cfg[@"plans"] = plans;
        [self writeCfg:cfg];
        PTUIPlanVC *vc = [PTUIPlanVC new];
        vc.planId = newPid;
        [self.navigationController pushViewController:vc animated:YES];
        // v1.0.80：删此处多余的 [self reload]——用户实测「点击瞬间刷新」：
        // push 进行中再刷列表，新方案行会闪一下；viewWillAppear 返回时自会重读
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.plans.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        // 统一按 pid 删除（dylib v1.0.75 口径）——重名时只删划掉的这一个；
        // deb 旧版按行索引，拖拽排序后行索引与配置数组可能错位
        NSString *pid = PTPlanPid(self.plans[ip.row], ip.row);
        NSMutableDictionary *cfg = self.readCfg;
        NSMutableArray *plans = [NSMutableArray array];
        NSArray *raw = cfg[@"plans"] ?: @[];
        for (NSUInteger i = 0; i < raw.count; i++) {
            NSDictionary *x = raw[i];
            if (![x isKindOfClass:[NSDictionary class]] || ![PTPlanPid(x, (NSInteger)i) isEqualToString:pid]) [plans addObject:x];
        }
        cfg[@"plans"] = plans;
        [self writeCfg:cfg];
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
@end
