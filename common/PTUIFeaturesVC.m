// ============================================================
// PTUIFeaturesVC.m —— 已录入特征列表页实现（v1.0.77 共享版）
// 行 = 特征详情；点击 = 详情/重新录制；左滑 = 删除；无新增入口
// ============================================================
#import "PTUIFeaturesVC.h"
#import "PTUICommon.h"

@implementation PTUIFeaturesVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"已录入特征";
    [self setupGroupedTableWithTop:0];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSDictionary *plan = PTUIPlanById(self.readCfg[@"plans"] ?: @[], self.planId);   // 按 pid 定位
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
        // v1.0.36：点击显示位移方向 + 大小
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
        // v1.0.36：点击详情显示位移方向 + 大小
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
        // 重录 = 进学习页（正常收敛模式），保存时替换这一条；返回不保存则原特征保留
        PTUILearnVC *vc = [PTUILearnVC new];
        vc.planId = self.planId;
        vc.replaceIndex = ip.row;
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

// 左滑删除（v1.0.34）
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.row < (NSInteger)self.features.count;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= (NSInteger)self.features.count) return;
    NSMutableDictionary *cfg = self.readCfg;
    NSMutableArray *plans = [NSMutableArray array];
    NSArray *raw = cfg[@"plans"] ?: @[];
    for (NSUInteger i = 0; i < raw.count; i++) {
        NSDictionary *p = raw[i];
        if ([p isKindOfClass:[NSDictionary class]] && [PTPlanPid(p, (NSInteger)i) isEqualToString:self.planId]) {   // 按 pid 删特征，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *fts = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(np)];
            [fts removeObjectAtIndex:ip.row];
            np[@"features"] = fts;
            [np removeObjectForKey:@"feature"];
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    [self writeCfg:cfg];
    [self reload];
}
@end
