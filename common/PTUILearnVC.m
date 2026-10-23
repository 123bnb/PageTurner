// ============================================================
// PTUILearnVC.m —— 学习页实现（v1.0.77 共享版）
//
// 统一口径：
//   · 采集 hook：调每 target 的 PTUIEnsureCollectHook（deb=bundle 内自 hook；
//     dylib=PTDylibCore 已统一装配）
//   · 方案定位/写回：一律按 pid（PTUIPlanById；新建方案即带 pid——
//     deb 旧版漏带 pid 靠惰性补发，dylib 旧版即带，统一为即带）
//   · 回退：经导航协议（PTUIPopToPlansList / PTUIPopToPlanPage）——
//     deb 侧列表页在桥接壳里，不能直接 isKindOfClass 扫描
// ============================================================
#import "PTUILearnVC.h"
#import "PTUICommon.h"
#import <QuartzCore/QuartzCore.h>

#define SLog(fmt, ...) PTDylibLog(fmt, ##__VA_ARGS__)

@implementation PTUILearnVC

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.34：增加特征模式（onceMode）——标题/提示不同，正常模式不变
    self.title = self.onceMode ? @"增加特征" : @"录制特征";
    // v1.0.31：深色模式适配——大白屏改系统自适应背景（浅色=白底黑字，深色=黑底白字）
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    // v1.0.29：右上角「保存」（录稳后变可点），名字用默认名以后再改
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.finished = NO;
    self.mem = [NSMutableArray array];

    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.22, w - 48, 60)];
    // v1.0.34：once 模式提示单次覆盖逻辑
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

    // v1.0.28：实时记录区（每次按键实时显示 sender/相位/方向/位移，眼见为实）
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
    PTUIEnsureCollectHook();
    SLog(@"learn: viewDidLoad 会话已复位，armed=YES");
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

// 轮询配置：读走新样本 → 判定
- (void)poll {
    // v1.0.28 BUG-1：波动太大弹窗期间暂停收集（sCollectArmed=NO），不读样本不误报
    // v1.0.30（用户问题1）：稳定后不暂停——继续录增强特征，直到自己点保存
    if (!sCollectArmed) return;
    NSMutableDictionary *cfg = self.readCfg;
    NSArray *samples = cfg[@"learningSamples"] ?: @[];
    cfg[@"learningSamples"] = @[];   // 清空已读
    [self writeCfg:cfg];
    if (!samples.count) {
        // 诊断：一直没收到翻页器事件
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
    // v1.0.34：增加特征模式——单次覆盖逻辑（不走收敛判定）
    if (self.onceMode) { [self judgeOnce:s]; return; }
    // v1.0.30（用户问题1）：稳定后仍可继续录（增强精准性）——不再 return；
    // 只接受同一个 sender 继续累积，误按别的键给提示不混入
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
            // v1.0.36：点击显示位移方向 + 大小（不再笼统显示"无滑动"）
            int dx = [s[@"tapDx"] intValue];
            NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
            self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, dist];
        }
        [self appendLog:[NSString stringWithFormat:@"✓ 增强 %d 次  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            count, sender, [s[@"phase"] intValue], dir, dist]];
        [self drawTrailWithDirection:dir dist:dist phase:[s[@"phase"] intValue]];
        // 实时刷新特征区间（保存时用最新样本，录得越多越准）
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
    NSArray *plans = self.readCfg[@"plans"] ?: @[];
    // 去重：与已有方案高度相似 → 拒绝
    NSString *dup = PTDuplicate(s, plans);
    if (dup) {
        SLog(@"judge: REJECT duplicate with '%@' — new{sender=%@ phase=%d dir=%.1f dist=%.1f}",
             dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]);
        self.status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", dup];
        self.status.textColor = [UIColor systemRedColor];
        [self.mem removeAllObjects];
        // v1.0.43：重复特征 → 清空已记录 + 禁止保存（双保险，与增加特征模式一致）
        self.readyFt = nil;
        self.finished = NO;
        self.navigationItem.rightBarButtonItem.enabled = NO;
        self.countLabel.text = @"已录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        [self appendLog:[NSString stringWithFormat:@"✗ 拒绝（与『%@』重复）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]];
        return;
    }
    self.status.textColor = [UIColor labelColor];
    [self.mem addObject:s];
    NSString *sender = s[@"sender"];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    // 同 sender 计数
    int count = 0;
    for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) count++;
    SLog(@"judge: ACCEPT sender=%@ phase=%d dir=%.1f dist=%.1f count=%d", sender, [s[@"phase"] intValue], dir, dist, count);
    self.countLabel.text = [NSString stringWithFormat:@"已录：%d 次（来源 %@）", count, sender];
    self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
    if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", dist];
    else {
        // v1.0.36：点击显示位移方向 + 大小
        int dx = [s[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, dist];
    }
    [self appendLog:[NSString stringWithFormat:@"✓ 已录 %d 次  sender=%@ phase=%d dir=%.1f° dist=%.1f",
        count, sender, [s[@"phase"] intValue], dir, dist]];
    // v1.0.29：每次按键画调试可视化同款轨迹（方向线 + 绿点 + P 标记）
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

// v1.0.34：增加特征模式——每次按键直接覆盖 readyFt（以最后一下为准），至少 1 次可保存
- (void)judgeOnce:(NSDictionary *)s {
    // 去重：与已有特征（跨方案全部特征）高度相似 → 拒绝（沿用防重复规矩）
    NSArray *plans = self.readCfg[@"plans"] ?: @[];
    NSString *dup = PTDuplicate(s, plans);
    if (dup) {
        SLog(@"judgeOnce: REJECT duplicate with '%@' — new{sender=%@ phase=%d dir=%.1f dist=%.1f}",
             dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]);
        self.status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", dup];
        self.status.textColor = [UIColor systemRedColor];
        [self appendLog:[NSString stringWithFormat:@"✗ 拒绝（与『%@』重复）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]];
        // v1.0.43：重复特征 → 右上角禁止保存 + 已记录清空（防止把之前录的旧记录
        // 当新特征保存——旧版只提示，右上角仍可点，会把旧 readyFt 存进去）
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
        // v1.0.36：点击也存位移区间 + 方向符号（区分同 sender 的多个点击键）
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
        // v1.0.36：点击显示位移方向 + 大小
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
    // 计算位移区间（同 sender 样本）
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
    // v1.0.36：点击特征记录位移方向符号（用最后一次样本；点击方向稳定）
    if (phase == 0) {
        int lastDx = 0;
        for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) lastDx = [m[@"tapDx"] intValue];
        ft[@"tapDx"] = @(lastDx);
    }
    ft[@"recordCount"] = @([self countForSender:sender]);
    self.readyFt = ft;
    // v1.0.29：稳定后不弹框——背景绿色提示，你自己按够了点右上角「保存」；名字以后再改
    if (phase == 0) {
        NSString *dxs = ([ft[@"tapDx"] intValue] > 0) ? @"向右" : (([ft[@"tapDx"] intValue] < 0) ? @"向左" : @"原地");
        self.status.text = [NSString stringWithFormat:@"✅ 特征已稳定\n来源 %@｜%@ %@｜位移 %.1f~%.1f pt\n\n点右上角「保存」完成录制", sender, dxs, PTDirName(dir), lo, hi];
    } else {
        self.status.text = [NSString stringWithFormat:@"✅ 特征已稳定\n来源 %@｜方向 %@｜位移 %.0f~%.0f pt\n\n点右上角「保存」完成录制", sender, PTDirName(dir), lo, hi];
    }
    self.status.textColor = [UIColor whiteColor];
    self.view.backgroundColor = [UIColor systemGreenColor];
    // v1.0.31：深色模式适配——日志底改系统次级背景（绿底上白字保持）
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.navigationItem.rightBarButtonItem.enabled = YES;
    // v1.0.30（用户问题1）：稳定后不暂停收集——你还能继续按同一个键增强特征，
    // 按够了再点右上角「保存」；保存时用最新样本重算位移区间
    SLog(@"learn: 特征已稳定（不弹框），可继续录或点右上角保存 sender=%@ phase=%d dir=%.1f dist=%.0f~%.0f tapDx=%d", sender, phase, dir, lo, hi, [ft[@"tapDx"] intValue]);
}

// v1.0.29：右上角保存——默认名「新方案N」（N 跳过重名），保存后回记录与映射列表
- (void)saveTapped {
    // v1.0.34：增加特征模式——加 1 条进当前方案已录入特征，回方案页
    if (self.onceMode) { [self saveOnce]; return; }
    // v1.0.34：特征列表页重录——替换当前方案第 replaceIndex 条特征，回方案页
    if (self.replaceIndex >= 0) { [self saveReplace]; return; }
    if (!self.finished || !self.readyFt) return;
    NSDictionary *ft = self.readyFt;
    NSArray *plans = self.readCfg[@"plans"] ?: @[];
    NSString *name = nil;
    for (int i = 1; i < 1000; i++) {
        NSString *cand = [NSString stringWithFormat:@"新方案%d", i];
        BOOL dupName = NO;
        for (NSDictionary *p in plans) if ([p[@"name"] isEqualToString:cand]) { dupName = YES; break; }
        if (!dupName) { name = cand; break; }
    }
    if (!name) name = @"新按键";
    NSMutableDictionary *cfg = self.readCfg;
    NSMutableArray *nplans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
    // v1.0.34：新方案统一 features[] 数组存储（兼容旧 feature 单条读取）；
    // 新建即带唯一 pid（旧 deb 版漏带、靠读时惰性补发——统一为即带，与列表页新建同规则）
    [nplans addObject:@{@"name": name, @"pid": [[NSUUID UUID] UUIDString], @"features": @[ft], @"actions": @[]}];
    cfg[@"plans"] = nplans;
    [self writeCfg:cfg];
    PTDylibSetLearningLocal(NO);
    [self appendLog:[NSString stringWithFormat:@"已保存「%@」（名字可在方案页点方案名修改）", name]];
    // 回记录与映射列表（清掉学习页；列表刷新，立刻看到新方案）
    PTUIPopToPlansList(self);
}

// v1.0.34：增加特征保存——加 1 条进当前方案 features（不新建方案），回方案页
- (void)saveOnce {
    if (!self.readyFt) return;
    NSMutableDictionary *cfg = self.readCfg;
    NSMutableArray *plans = [NSMutableArray array];
    BOOL done = NO;
    NSArray *raw = cfg[@"plans"] ?: @[];
    for (NSUInteger i = 0; i < raw.count; i++) {
        NSDictionary *p = raw[i];
        if ([p isKindOfClass:[NSDictionary class]] && [PTPlanPid(p, (NSInteger)i) isEqualToString:self.planId]) {   // 按 pid 写回，重名不串
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
    [self writeCfg:cfg];
    PTDylibSetLearningLocal(NO);
    // 数一下该方案现在的特征数（写日志用，按 pid 取该方案）
    NSDictionary *saved = PTUIPlanById(plans, self.planId);
    NSUInteger total = PTFeaturesOfPlan(saved).count;
    [self appendLog:[NSString stringWithFormat:@"已增加 1 条特征（共 %lu 条），回方案页", (unsigned long)total]];
    // 回方案页（清掉学习页；方案页 viewWillAppear 自动刷新）
    PTUIPopToPlanPage(self);
}

// v1.0.34：特征列表重录保存——替换当前方案第 replaceIndex 条特征，回方案页
- (void)saveReplace {
    if (!self.finished || !self.readyFt) return;
    NSMutableDictionary *cfg = self.readCfg;
    NSMutableArray *plans = [NSMutableArray array];
    BOOL done = NO;
    NSArray *raw = cfg[@"plans"] ?: @[];
    for (NSUInteger i = 0; i < raw.count; i++) {
        NSDictionary *p = raw[i];
        if ([p isKindOfClass:[NSDictionary class]] && [PTPlanPid(p, (NSInteger)i) isEqualToString:self.planId]) {   // 按 pid 写回，重名不串
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
    [self writeCfg:cfg];
    PTDylibSetLearningLocal(NO);
    [self appendLog:@"已替换特征，回方案页"];
    // 回方案页
    PTUIPopToPlanPage(self);
}

// v1.0.29：调试可视化同款轨迹——起点绿点 + 方向线 + 终点 P 标记（点击只有 P 标记）
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase {
    [self.trailLayer removeFromSuperlayer];
    [self.trailDot removeFromSuperview];
    [self.trailLabel removeFromSuperview];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGPoint start = CGPointMake(w * 0.5, h * 0.38);   // 避开上方状态/标签区
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

// v1.0.28 BUG-1：弹窗出现 → 先暂停收集；继续录 = 不清空已录解除上限继续录（增强精准性）；
// 重录 = 清空已录 + 清样本重新录
- (void)onTooMany {
    sCollectArmed = NO;   // 弹窗期间暂停收集（poll 直接 return，不误报不误录）
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"特征波动太大"
        message:@"已录 15 次仍未稳定，建议检查按键或重录" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"继续录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.limitExceeded = YES;          // 解除 15 次上限，继续按同一键直到稳定
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
        NSMutableDictionary *cfg = self.readCfg;
        cfg[@"learningSamples"] = @[];
        [self writeCfg:cfg];
        sCollectArmed = YES;
        sLastSampleAt = PTNowC();
        [self appendLog:@"已重录：样本已清空"];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

// v1.0.28：实时记录区追加一行并滚动到底部
- (void)appendLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", s] : s;
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}
@end
