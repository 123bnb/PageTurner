// ============================================================
// PTUIPlansVC.m —— 方案列表页实现（v1.0.77 共享版）
//
// 统一口径（原两侧漂移 → 本版裁定）：
//   · 排序：一律长按拖拽（deb v1.0.66 #5 的 Z 交互，自定义浮层快照）
//   · 删除：一律按 pid（dylib v1.0.75 口径；deb 旧版按行索引——拖拽后行索引会错位）
//   · 打开：一律按 pid 定位（重名不串）
// ============================================================
#import "PTUIPlansVC.h"
#import "PTUICommon.h"
#import "PTDragSortHelper.h"

@implementation PTUIPlansVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"记录与映射";
    [self setupGroupedTableWithTop:100];
    // v1.0.66(#5)：长按方案行拖拽排序（自定义浮层，零三横线）
    self.dragHelper = [[PTDragSortHelper alloc] initWithTableView:self.tv mode:PTDragAttachTable];
    __weak typeof(self) wself = self;
    self.dragHelper.canDragRow = ^BOOL(NSInteger row) {
        return row < (NSInteger)wself.plans.count;   // 末行「新增方案」不参与拖拽
    };
    self.dragHelper.onReorder = ^(NSArray *ordered) {
        NSMutableDictionary *cfg = wself.readCfg;
        cfg[@"plans"] = ordered;
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
    self.plans = [NSMutableArray arrayWithArray:self.readCfg[@"plans"] ?: @[]];
    self.dragHelper.items = self.plans;
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
    } else {
        NSMutableDictionary *cfg = self.readCfg;
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        NSString *name = [NSString stringWithFormat:@"新方案%lu", (unsigned long)(plans.count + 1)];
        NSString *newPid = [[NSUUID UUID] UUIDString];   // 新建即带唯一 pid
        [plans addObject:@{ @"name": name, @"pid": newPid, @"actions": @[] }];
        cfg[@"plans"] = plans;
        [self writeCfg:cfg];
        PTUIPlanVC *vc = [PTUIPlanVC new];
        vc.planId = newPid;
        [self.navigationController pushViewController:vc animated:YES];
        [self reload];
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
