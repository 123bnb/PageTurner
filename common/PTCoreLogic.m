// ============================================================
// PTCoreLogic.m —— 引擎纯逻辑层实现（v1.0.78 抽取，逐字迁移零行为改动）
//
// 迁移来源：
//   · PTEngineMatch.m 的工具区（PTPlanPid…PTIsLearnedSender）与 PTTestMatchFeature
//   · PTEngineExec.m 的 PTRecSwipeInterp（原 static，因测试可链升为层内 API）
//   · PTEngineConfig.m 的 PTWriteCfgTo
// 本层依赖（宿主持有定义，只引用不定义）：
//   · gPlans / gLearnedSenders / gLearnedSenderCount —— PTEngineConfig.m（声明见本头）
//   · PTDylibReadCfg —— PTEngineConfig.m；tests/ 构建时由测试文件提供假实现
// ============================================================
#import "PTCoreLogic.h"
#import <math.h>   // DBL_MAX / fabs（Foundation 不保证传递导入）

// PTTestMatchFeature 读实时配置的通道——实现在 PTEngineConfig.m（宿主）；
// tests/ 提供等价假实现（直接返回注入的配置字典），使匹配逻辑脱离文件系统单测。
extern NSMutableDictionary *PTDylibReadCfg(void);


// ============================================================
// 工具（UI 层复用）
// ============================================================

// v1.0.74：方案唯一身份 pid（头文件注释详述背景）。三端补发规则一致：
//   设置页 PTRead（v1.0.66-fix）/ 引擎 PTDylibLoadConfig / dylib UI（v1.0.75）
// 对同一份配置补出同一批 pid → 跨进程、跨版本不会漂移。
NSString *PTPlanPid(NSDictionary *p, NSInteger idx) {
    NSString *pid = p[@"pid"];
    if ([pid isKindOfClass:[NSString class]] && pid.length) return pid;
    NSString *nm = p[@"name"];
    if (![nm isKindOfClass:[NSString class]] || !nm.length) nm = @"plan";
    return [NSString stringWithFormat:@"%@#%ld", nm, (long)idx];
}

// v1.0.74：pid → 显示名（日志 / pill / 记录区）。gPlans 改 pid 索引后，原本直接
// 格式化 name 的位置全部经本函数取回；查不到返回 pid 本身（永不 nil，避免 %@ 崩）。
NSString *PTPlanNameForId(NSString *planId) {
    if (!planId) return @"（无方案）";
    NSDictionary *p = gPlans[planId];
    NSString *n = p[@"name"];
    return ([n isKindOfClass:[NSString class]] && n.length) ? n : planId;
}

NSArray *PTFeaturesOfPlan(NSDictionary *p) {
    if (p[@"features"]) return p[@"features"];
    if (p[@"feature"]) return @[p[@"feature"]];
    return @[];
}

NSString *PTDirName(double dir) {
    if (dir >= 45 && dir <= 135) return @"下";
    if (dir > 135 || dir < -135) return @"左";
    if (dir >= -135 && dir < -45) return @"上";
    return @"右";
}

NSString *PTActionText(NSDictionary *a) {
    NSString *t = a[@"type"];
    if ([t isEqualToString:@"tap"]) return [NSString stringWithFormat:@"点击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"doubleTap"]) return [NSString stringWithFormat:@"双击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%d,%d)→(%d,%d)", (int)[a[@"x1"] doubleValue], (int)[a[@"y1"] doubleValue], (int)[a[@"x2"] doubleValue], (int)[a[@"y2"] doubleValue]];
    if ([t isEqualToString:@"recSwipe"]) return [NSString stringWithFormat:@"滑动(手动) %lu点", (unsigned long)[a[@"pts"] count]];   // v1.0.8
    if ([t isEqualToString:@"delay"]) return [NSString stringWithFormat:@"延迟 %.0fms", [a[@"ms"] doubleValue]];
    if ([t isEqualToString:@"volumeUp"] || [t isEqualToString:@"volumeDown"] || [t isEqualToString:@"muteToggle"])
        return [NSString stringWithFormat:@"%@（已移除）", t];   // v1.0.5：音量动作已删除，旧配置显示提示
    return t;
}

NSString *PTDuplicate(NSDictionary *s, NSArray *plans) {
    NSString *snd = s[@"sender"];
    int phase = [s[@"phase"] intValue];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    int tapDx = [s[@"tapDx"] intValue];
    for (NSDictionary *p in plans) {
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (![ft[@"sender"] isEqualToString:snd]) continue;
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > kDirTolerance) continue;   // v1.0.71：kDirTol → kDirTolerance（统一常量名）
            if (phase == 1) {
                double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - kDistSlack || dist > hi + kDistSlack) continue;
            } else {
                if (ft[@"tapDx"] && tapDx != [ft[@"tapDx"] intValue]) continue;
                if (ft[@"distMin"]) {
                    double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            return p[@"name"];
        }
    }
    return nil;
}

BOOL PTStable(NSArray *mem, NSString *sender) {
    NSMutableArray *same = [NSMutableArray array];
    for (NSDictionary *s in mem) if ([s[@"sender"] isEqualToString:sender]) [same addObject:s];
    if (same.count < kLearnMin) return NO;
    NSInteger n = same.count;
    double dir = [same[n-1][@"direction"] doubleValue];
    for (NSInteger i = n - kLearnMin; i < n; i++) {
        double d = [same[i][@"direction"] doubleValue];
        double diff = fabs(fabs(dir - d)); if (diff > 180) diff = 360 - diff;
        if (diff > kDirTolerance) return NO;   // v1.0.71：kDirTol → kDirTolerance（统一常量名）
    }
    if ([same[n-1][@"phase"] intValue] == 1) {
        double lo = DBL_MAX, hi = 0;
        for (NSInteger i = n - kLearnMin; i < n; i++) {
            double v = [same[i][@"dist"] doubleValue];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (hi - lo > kConverge) return NO;
    }
    return YES;
}

// 匹配：sender + 相位 + 方向±15° + 位移区间 → 唯一方案（运行端；测试端用 PTTestMatchFeature）
// v1.0.74：返回值由 name 改为方案 pid——gPlans 按 pid 索引（重名方案是两条独立记录，
// 共用一个 name 键会互相覆盖），调用方（PTEngine.m）原样传给 PTChainHandleHit。
NSString *PTMatchPlan(PagerFeature f, uint64_t sender) {
    NSString *bestId = nil;
    double bestScore = DBL_MAX;
    for (NSString *pid in gPlans) {
        NSDictionary *p = gPlans[pid];
        NSArray *fts = p[@"features"] ?: (p[@"feature"] ? @[p[@"feature"]] : @[]);
        for (NSDictionary *ft in fts) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;
            }
            if ([ft[@"phase"] intValue] != f.phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(f.direction - pd)); if (d > 180) d = 360 - d;
            if (d > kDirTolerance) continue;
            double lo = 0, hi = 0;
            if (f.phase == 1) {
                lo = [ft[@"distMin"] doubleValue];
                hi = [ft[@"distMax"] doubleValue];
                if (f.dist < lo - kDistSlack || f.dist > hi + kDistSlack) continue;
            } else {
                if (ft[@"tapDx"]) {
                    if (f.tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (f.dist < lo - kTapDistSlack || f.dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (f.phase == 1 ? fabs(f.dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; bestId = pid; }
        }
    }
    return bestId;
}

BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

// v1.0.74：返回值由 name 改为方案 pid。本函数刻意读实时配置（不经 gPlans 缓存）——
// 录完特征立刻测试时 mtime 刷新可能还没发生；pid 用 PTPlanPid 惰性生成（与引擎
// 补发同规则），执行层 PTExecutePlanRun 对查不到的 pid 有强制刷新兜底（见其注释）。
NSString *PTTestMatchFeature(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *bestId = nil; double bestScore = DBL_MAX;
    NSArray *plans = PTDylibReadCfg()[@"plans"] ?: @[];
    for (NSUInteger i = 0; i < plans.count; i++) {
        NSDictionary *p = plans[i];
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;
            }
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > 15.0) continue;
            double lo = 0, hi = 0;
            if (phase == 1) {
                lo = [ft[@"distMin"] doubleValue];
                hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - 30.0 || dist > hi + 30.0) continue;
            } else {
                if (ft[@"tapDx"]) {
                    if (tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (phase == 1 ? fabs(dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; bestId = PTPlanPid(p, (NSInteger)i); }
        }
    }
    return bestId;
}

// ---------- 时间插值（原 PTEngineExec.m） ----------
// 按时间线性插值取坐标（二分定位区间）
CGPoint PTRecSwipeInterp(NSArray *xs, NSArray *ys, NSArray *ts, double targetT) {
    NSUInteger m = [ts count];
    if (m == 0) return CGPointZero;
    double t0 = [ts[0] doubleValue], tEnd = [ts[m-1] doubleValue];
    if (targetT <= t0)   return CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]);
    if (targetT >= tEnd) return CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
    NSUInteger lo = 0, hi = m - 1;
    while (hi - lo > 1) {
        NSUInteger mid = (lo + hi) / 2;
        if ([ts[mid] doubleValue] <= targetT) lo = mid; else hi = mid;
    }
    double ta = [ts[lo] doubleValue], tb = [ts[hi] doubleValue];
    double fa = [xs[lo] doubleValue], fb = [xs[hi] doubleValue];
    double ga = [ys[lo] doubleValue], gb = [ys[hi] doubleValue];
    double f = (tb - ta) > 1e-6 ? (targetT - ta) / (tb - ta) : 0.0;
    return CGPointMake(fa + (fb - fa) * f, ga + (gb - ga) * f);
}

// ---------- 原子写配置（原 PTEngineConfig.m） ----------
// v1.0.71：原子写指定路径（从 PTDylibWriteCfg 抽出）——设置页双写（jbroot 真实路径 +
// 普通路径兜底）直接用它，不必各写一份序列化逻辑。
void PTWriteCfgTo(NSString *path, NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:path error:nil];
}
