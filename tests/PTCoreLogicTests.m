// ============================================================
// tests/PTCoreLogicTests.m —— 引擎纯逻辑层测试（v1.0.78，评审 #6）
//
// 为什么是 CLI harness 而不是 XCTest bundle：仓库没有 .xcodeproj（theos
// Makefile 构建），XCTest bundle 无处挂载；且引擎六个实现文件都 import
// UIKit——macOS 上编不了，CI（macos-latest）跑不了。解法即被测对象本身：
// 只链 Foundation-only 的 common/PTCoreLogic.m，main() + CHECK 宏跑断言，
// clang 原生编译执行（tests/run.sh；CI 在 clone Theos 之前跑，秒级失败）。
//
// 测试替身（宿主持有、本文件提供定义，使逻辑层脱离宿主可测）：
//   · gPlans / gDebounceMs / gLearnedSenders / gLearnedSenderCount
//     ——PTCoreLogic.h 里是 extern 声明，定义在 PTEngineConfig.m；此处替身。
//   · PTDylibReadCfg —— PTTestMatchFeature 读实时配置的通道（实现在
//     PTEngineConfig.m）；假实现直接返回注入的字典，匹配逻辑脱离文件系统。
//
// 覆盖（12 组）：PTPlanPid / PTPlanNameForId / PTDirName / PTActionText /
//   PTFeaturesOfPlan / PTDuplicate / PTStable / PTMatchPlan /
//   PTTestMatchFeature / PTIsLearnedSender / PTWriteCfgTo / PTRecSwipeInterp。
// 原则：只测「输入 → 输出」的判定与计算，不测宿主状态与 UI。
// ============================================================
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "PTCoreLogic.h"

// ---------- 测试替身：宿主持有的运行端缓存（PTCoreLogic.h extern，此处给定义） ----------
NSMutableDictionary *gPlans = nil;
double gDebounceMs = 300;
uint64_t gLearnedSenders[kMaxLearnedSenders] = {0};
int gLearnedSenderCount = 0;

// ---------- 测试替身：PTDylibReadCfg（等价假实现：直接返回注入的配置） ----------
static NSMutableDictionary *sFakeCfg = nil;
NSMutableDictionary *PTDylibReadCfg(void) {
    return sFakeCfg ?: [NSMutableDictionary dictionary];
}
static void setFakePlans(NSArray *plans) {
    sFakeCfg = [NSMutableDictionary dictionaryWithObject:plans forKey:@"plans"];
}

// ---------- harness ----------
static int gPass = 0, gFail = 0;
#define CHECK(cond) do { \
    if (cond) { gPass++; } \
    else { gFail++; NSLog(@"  FAIL %s:%d  %s", __func__, __LINE__, #cond); } \
} while (0)

static void section(const char *name) { NSLog(@"—— %s ——", name); }
static BOOL ptEq(double a, double b) { return fabs(a - b) < 1e-9; }

// ============================================================
// 1. PTPlanPid：显式 pid 原样；缺则「name#下标」惰性补发；脏数据不崩
// ============================================================
static void test_plan_pid(void) {
    section(__func__);
    CHECK([PTPlanPid(@{@"pid": @"p1", @"name": @"方案"}, 3) isEqualToString:@"p1"]);
    CHECK([PTPlanPid(@{@"name": @"方案"}, 3) isEqualToString:@"方案#3"]);
    CHECK([PTPlanPid(@{@"name": @"方案"}, 0) isEqualToString:@"方案#0"]);
    // pid 非字符串 → 走 name 补发（配置可能是外部手改的）
    CHECK([PTPlanPid(@{@"pid": @123, @"name": @"方案"}, 1) isEqualToString:@"方案#1"]);
    CHECK([PTPlanPid(@{@"pid": @"", @"name": @"方案"}, 1) isEqualToString:@"方案#1"]);
    // name 缺失/非字符串/空 → "plan#下标"（永不 nil，避免执行中 %@ 崩）
    CHECK([PTPlanPid(@{}, 7) isEqualToString:@"plan#7"]);
    CHECK([PTPlanPid(@{@"name": @""}, 2) isEqualToString:@"plan#2"]);
    CHECK([PTPlanPid(@{@"name": @42}, 2) isEqualToString:@"plan#2"]);
}

// ============================================================
// 2. PTPlanNameForId：命中回显 name；未命中回 pid 本身；nil 有兜底
// ============================================================
static void test_plan_name_for_id(void) {
    section(__func__);
    gPlans = [NSMutableDictionary dictionary];
    gPlans[@"p1"] = [@{@"name": @"方案一"} mutableCopy];
    gPlans[@"p2"] = [@{@"name": @42} mutableCopy];      // 脏 name
    gPlans[@"p3"] = [@{@"name": @""} mutableCopy];      // 空 name
    CHECK([PTPlanNameForId(@"p1") isEqualToString:@"方案一"]);
    CHECK([PTPlanNameForId(@"nope") isEqualToString:@"nope"]);   // 查不到 → pid 本身
    CHECK([PTPlanNameForId(@"p2") isEqualToString:@"p2"]);
    CHECK([PTPlanNameForId(@"p3") isEqualToString:@"p3"]);
    CHECK([PTPlanNameForId(nil) isEqualToString:@"（无方案）"]);
}

// ============================================================
// 3. PTDirName：方向 → 文案（边界值全走一遍：±45/±135/180 交界）
// ============================================================
static void test_dir_name(void) {
    section(__func__);
    CHECK([PTDirName(90) isEqualToString:@"下"]);
    CHECK([PTDirName(45) isEqualToString:@"下"]);     // 闭区间下界
    CHECK([PTDirName(135) isEqualToString:@"下"]);    // 闭区间上界
    CHECK([PTDirName(136) isEqualToString:@"左"]);    // 出上界即左
    CHECK([PTDirName(180) isEqualToString:@"左"]);
    CHECK([PTDirName(-180) isEqualToString:@"左"]);
    CHECK([PTDirName(-136) isEqualToString:@"左"]);   // < -135 → 左
    CHECK([PTDirName(-135) isEqualToString:@"上"]);   // [-135,-45) → 上
    CHECK([PTDirName(-90) isEqualToString:@"上"]);
    CHECK([PTDirName(-45) isEqualToString:@"右"]);    // 区间不含 -45；与 +45 归「下」的约定对称（-45 归右）
    CHECK([PTDirName(-44.9) isEqualToString:@"右"]);
    CHECK([PTDirName(0) isEqualToString:@"右"]);
    CHECK([PTDirName(44.9) isEqualToString:@"右"]);
}

// ============================================================
// 4. PTActionText：七种动作的文案（含已移除音量的提示与未知类型回退）
// ============================================================
static void test_action_text(void) {
    section(__func__);
    CHECK([PTActionText(@{@"type": @"tap", @"x": @12.7, @"y": @34.2}) isEqualToString:@"点击(12, 34)"]);
    CHECK([PTActionText(@{@"type": @"doubleTap", @"x": @1, @"y": @2}) isEqualToString:@"双击(1, 2)"]);
    CHECK([PTActionText(@{@"type": @"swipe", @"x1": @1, @"y1": @2, @"x2": @3, @"y2": @4})
           isEqualToString:@"滑动 (1,2)→(3,4)"]);
    CHECK([PTActionText(@{@"type": @"recSwipe", @"pts": @[@1, @2, @3]}) isEqualToString:@"滑动(手动) 3点"]);
    CHECK([PTActionText(@{@"type": @"delay", @"ms": @250}) isEqualToString:@"延迟 250ms"]);
    CHECK([PTActionText(@{@"type": @"volumeUp"}) isEqualToString:@"volumeUp（已移除）"]);
    CHECK([PTActionText(@{@"type": @"muteToggle"}) isEqualToString:@"muteToggle（已移除）"]);
    CHECK([PTActionText(@{@"type": @"unknownXYZ"}) isEqualToString:@"unknownXYZ"]);
}

// ============================================================
// 5. PTFeaturesOfPlan：features 数组 / 单 feature 兜底 / 都没有 → 空
// ============================================================
static void test_features_of_plan(void) {
    section(__func__);
    NSDictionary *ft1 = @{@"phase": @0}, *ft2 = @{@"phase": @1};
    NSArray *fts = @[ft1, ft2];
    CHECK(PTFeaturesOfPlan(@{@"features": fts}) == fts);            // 原样透传
    CHECK(PTFeaturesOfPlan(@{@"feature": ft1}).count == 1);
    CHECK([PTFeaturesOfPlan(@{@"feature": ft1})[0] isEqualToDictionary:ft1]);
    CHECK(PTFeaturesOfPlan(@{}).count == 0);
}

// ============================================================
// 6. PTDuplicate：重复录入判定（sender/相位/方向容差/位移裕度/tapDx 全维度）
// ============================================================
static void test_duplicate(void) {
    section(__func__);
    NSArray *plans = @[
        @{@"name": @"swipe甲",
          @"features": @[@{@"sender": @"0x10", @"phase": @1, @"direction": @90,
                           @"distMin": @100, @"distMax": @200}]},
        @{@"name": @"tap乙",
          @"features": @[@{@"sender": @"0x10", @"phase": @0, @"direction": @0,
                           @"tapDx": @1}]},
    ];
    NSDictionary *hit = @{@"sender": @"0x10", @"phase": @1, @"direction": @90, @"dist": @150};
    CHECK([PTDuplicate(hit, plans) isEqualToString:@"swipe甲"]);
    // sender 不同 → 不重复
    CHECK(PTDuplicate(@{@"sender": @"0x11", @"phase": @1, @"direction": @90, @"dist": @150}, plans) == nil);
    // 相位不同 → 不重复
    CHECK(PTDuplicate(@{@"sender": @"0x10", @"phase": @0, @"direction": @90, @"dist": @150}, plans) == nil);
    // 方向超出 ±15° → 不重复；±14° 在容差内 → 重复
    CHECK(PTDuplicate(@{@"sender": @"0x10", @"phase": @1, @"direction": @110, @"dist": @150}, plans) == nil);
    CHECK([PTDuplicate(@{@"sender": @"0x10", @"phase": @1, @"direction": @104, @"dist": @150}, plans)
           isEqualToString:@"swipe甲"]);
    // 位移超出 ±30 裕度 → 不重复；边界内 → 重复
    CHECK(PTDuplicate(@{@"sender": @"0x10", @"phase": @1, @"direction": @90, @"dist": @60}, plans) == nil);
    CHECK(PTDuplicate(@{@"sender": @"0x10", @"phase": @1, @"direction": @90, @"dist": @240}, plans) == nil);
    CHECK([PTDuplicate(@{@"sender": @"0x10", @"phase": @1, @"direction": @90, @"dist": @70}, plans)
           isEqualToString:@"swipe甲"]);
    CHECK([PTDuplicate(@{@"sender": @"0x10", @"phase": @1, @"direction": @90, @"dist": @230}, plans)
           isEqualToString:@"swipe甲"]);
    // tapDx 必须相等
    CHECK([PTDuplicate(@{@"sender": @"0x10", @"phase": @0, @"direction": @0, @"tapDx": @1}, plans)
           isEqualToString:@"tap乙"]);
    CHECK(PTDuplicate(@{@"sender": @"0x10", @"phase": @0, @"direction": @0, @"tapDx": @2}, plans) == nil);
}

// ============================================================
// 7. PTStable：学习稳定性（样本下限 / 方向收敛 / 位移收敛 / 只数自己的 sender）
// ============================================================
static void test_stable(void) {
    section(__func__);
    NSMutableArray *mem = [NSMutableArray array];
    for (int i = 0; i < kLearnMin; i++)
        [mem addObject:@{@"sender": @"0x10", @"phase": @0, @"direction": @90, @"dist": @5}];
    CHECK(PTStable(mem, @"0x10") == YES);

    // 少于 kLearnMin → 不稳定（再补 3 个别的 sender 的样本也不计数）
    NSMutableArray *few = [NSMutableArray array];
    for (int i = 0; i < kLearnMin - 1; i++)
        [few addObject:@{@"sender": @"0x10", @"phase": @0, @"direction": @90, @"dist": @5}];
    for (int i = 0; i < 3; i++)
        [few addObject:@{@"sender": @"0x99", @"phase": @0, @"direction": @90, @"dist": @5}];
    CHECK(PTStable(few, @"0x10") == NO);

    // 末样本为基准，早前样本方向差 >15° → 不稳定
    NSMutableArray *spread = [NSMutableArray array];
    for (int i = 0; i < kLearnMin - 1; i++)
        [spread addObject:@{@"sender": @"0x10", @"phase": @0, @"direction": @60, @"dist": @5}];
    [spread addObject:@{@"sender": @"0x10", @"phase": @0, @"direction": @90, @"dist": @5}];
    CHECK(PTStable(spread, @"0x10") == NO);

    // swipe 位移收敛：极差 > kConverge(60) → 不稳定；≤60 → 稳定
    NSMutableArray *wide = [NSMutableArray array];
    double distsWide[] = {100, 100, 100, 100, 175};   // 极差 75
    for (int i = 0; i < kLearnMin; i++)
        [wide addObject:@{@"sender": @"0x10", @"phase": @1, @"direction": @90,
                          @"dist": @(distsWide[i])}];
    CHECK(PTStable(wide, @"0x10") == NO);
    NSMutableArray *tight = [NSMutableArray array];
    double distsTight[] = {100, 120, 140, 150, 155};  // 极差 55
    for (int i = 0; i < kLearnMin; i++)
        [tight addObject:@{@"sender": @"0x10", @"phase": @1, @"direction": @90,
                           @"dist": @(distsTight[i])}];
    CHECK(PTStable(tight, @"0x10") == YES);
}

// ============================================================
// 8. PTMatchPlan：运行端匹配（gPlans 按 pid 索引；sender/相位/方向/位移 +
//    方向环绕 350°↔5°；返回 pid 而非 name）
// ============================================================
static void test_match_plan(void) {
    section(__func__);
    gPlans = [NSMutableDictionary dictionary];
    gPlans[@"甲#0"] = [@{@"name": @"甲", @"features": @[
        @{@"sender": @"0x10", @"phase": @1, @"direction": @90, @"distMin": @100, @"distMax": @200}]} mutableCopy];
    gPlans[@"乙#1"] = [@{@"name": @"乙", @"features": @[
        @{@"sender": @"0x10", @"phase": @1, @"direction": @270, @"distMin": @100, @"distMax": @200}]} mutableCopy];
    gPlans[@"丙#2"] = [@{@"name": @"丙", @"features": @[
        @{@"sender": @"0x10", @"phase": @1, @"direction": @350, @"distMin": @100, @"distMax": @200}]} mutableCopy];

    PagerFeature f;
    f.phase = 1; f.direction = 90;  f.dist = 150; f.tapDx = 0;
    CHECK([PTMatchPlan(f, 0x10) isEqualToString:@"甲#0"]);      // 返回 pid
    f.direction = 270;
    CHECK([PTMatchPlan(f, 0x10) isEqualToString:@"乙#1"]);
    // 方向环绕：|5-350|=345 → 360-345=15 ≤ 容差 → 命中丙
    f.direction = 5;
    CHECK([PTMatchPlan(f, 0x10) isEqualToString:@"丙#2"]);
    // 180° 谁都不挨 → nil
    f.direction = 180;
    CHECK(PTMatchPlan(f, 0x10) == nil);
    // sender / 相位 / 位移越界 → nil
    f.direction = 90;
    CHECK(PTMatchPlan(f, 0x11) == nil);
    f.phase = 0;
    CHECK(PTMatchPlan(f, 0x10) == nil);
    f.phase = 1; f.dist = 60;
    CHECK(PTMatchPlan(f, 0x10) == nil);
    f.dist = 240;
    CHECK(PTMatchPlan(f, 0x10) == nil);
}

// ============================================================
// 9. PTTestMatchFeature：测试端匹配（刻意读实时配置而非 gPlans 缓存——
//    录完立刻测试时 mtime 可能没刷新；pid 惰性补发；显式 pid 优先）
// ============================================================
static void test_test_match_feature(void) {
    section(__func__);
    setFakePlans(@[@{@"name": @"测试方案",
                     @"features": @[@{@"sender": @"0xAB", @"phase": @0, @"direction": @0}]}]);
    // 惰性 pid = name#数组下标
    CHECK([PTTestMatchFeature(0, 0, 5, 0xAB, 0) isEqualToString:@"测试方案#0"]);
    // 方向差 90° → 不命中
    CHECK(PTTestMatchFeature(0, 90, 5, 0xAB, 0) == nil);
    // sender 不符 → 不命中
    CHECK(PTTestMatchFeature(0, 0, 5, 0xCD, 0) == nil);
    // 显式 pid 优先于惰性补发
    setFakePlans(@[@{@"pid": @"fixed1", @"name": @"X",
                     @"features": @[@{@"sender": @"0xAB", @"phase": @0, @"direction": @0}]}]);
    CHECK([PTTestMatchFeature(0, 0, 5, 0xAB, 0) isEqualToString:@"fixed1"]);
    // 实时性：换一份配置立刻反映（若走 gPlans 缓存，这里还是旧结果）
    setFakePlans(@[@{@"name": @"新方案",
                     @"features": @[@{@"sender": @"0xAB", @"phase": @0, @"direction": @0}]}]);
    CHECK([PTTestMatchFeature(0, 0, 5, 0xAB, 0) isEqualToString:@"新方案#0"]);
    // 空配置不崩
    setFakePlans(@[]);
    CHECK(PTTestMatchFeature(0, 0, 5, 0xAB, 0) == nil);
}

// ============================================================
// 10. PTIsLearnedSender：已学 sender 表查找
// ============================================================
static void test_is_learned_sender(void) {
    section(__func__);
    gLearnedSenders[0] = 0x10; gLearnedSenders[1] = 0x20;
    gLearnedSenderCount = 2;
    CHECK(PTIsLearnedSender(0x10) == YES);
    CHECK(PTIsLearnedSender(0x20) == YES);
    CHECK(PTIsLearnedSender(0x30) == NO);
    gLearnedSenderCount = 0;
    CHECK(PTIsLearnedSender(0x10) == NO);   // 表清空后谁都算没学过
}

// ============================================================
// 11. PTWriteCfgTo：原子写指定路径（落盘可读回、覆盖写、无 .tmp 残留）
// ============================================================
static void test_write_cfg_to(void) {
    section(__func__);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"PTCoreLogicTests.plist"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    NSDictionary *cfg = @{@"plans": @[@{@"name": @"甲", @"pid": @"甲#0"}],
                          @"learning": @{@"active": @YES},
                          @"debounceMs": @300};
    PTWriteCfgTo(path, cfg);
    NSDictionary *back = [NSDictionary dictionaryWithContentsOfFile:path];
    CHECK([back isEqualToDictionary:cfg]);
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingString:@".tmp"]]);

    // 覆盖写：第二次写不同内容，读回是新的（原子替换生效）
    NSDictionary *cfg2 = @{@"plans": @[], @"learning": @{@"active": @NO}};
    PTWriteCfgTo(path, cfg2);
    NSDictionary *back2 = [NSDictionary dictionaryWithContentsOfFile:path];
    CHECK([back2 isEqualToDictionary:cfg2]);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

// ============================================================
// 12. PTRecSwipeInterp：按时间线性插值（空/越界钳制/节点/中点/退化区间）
// ============================================================
static void test_rec_swipe_interp(void) {
    section(__func__);
    NSArray *xs = @[@0, @100], *ys = @[@0, @50], *ts = @[@0, @1];
    // 空输入 → 零点
    CGPoint z = PTRecSwipeInterp(@[], @[], @[], 0.5);
    CHECK(z.x == 0 && z.y == 0);
    // 早于首节点 → 首点；晚于末节点 → 末点（钳制）
    CGPoint p0 = PTRecSwipeInterp(xs, ys, ts, -1);
    CHECK(ptEq(p0.x, 0) && ptEq(p0.y, 0));
    CGPoint p1 = PTRecSwipeInterp(xs, ys, ts, 2);
    CHECK(ptEq(p1.x, 100) && ptEq(p1.y, 50));
    // 正好落在节点 → 节点值
    CGPoint pn = PTRecSwipeInterp(xs, ys, ts, 1);
    CHECK(ptEq(pn.x, 100) && ptEq(pn.y, 50));
    // 中点线性插值
    CGPoint pm = PTRecSwipeInterp(xs, ys, ts, 0.5);
    CHECK(ptEq(pm.x, 50) && ptEq(pm.y, 25));
    CGPoint pq = PTRecSwipeInterp(xs, ys, ts, 0.25);
    CHECK(ptEq(pq.x, 25) && ptEq(pq.y, 12.5));
    // 三点序列：跨区间定位正确（0.3s 落在 [0,1] 段）
    CGPoint p3 = PTRecSwipeInterp(@[@0, @100, @200], @[@0, @50, @100], @[@0, @1, @2], 0.3);
    CHECK(ptEq(p3.x, 30) && ptEq(p3.y, 15));
    // 退化区间（ta==tb）→ 取区间左端
    CGPoint pd = PTRecSwipeInterp(@[@10, @20], @[@1, @2], @[@0, @0], 0);
    CHECK(ptEq(pd.x, 10) && ptEq(pd.y, 1));
    // 单节点
    CGPoint ps = PTRecSwipeInterp(@[@7], @[@9], @[@1], 0.5);
    CHECK(ptEq(ps.x, 7) && ptEq(ps.y, 9));
}

// ============================================================
int main(void) {
    @autoreleasepool {
        test_plan_pid();
        test_plan_name_for_id();
        test_dir_name();
        test_action_text();
        test_features_of_plan();
        test_duplicate();
        test_stable();
        test_match_plan();
        test_test_match_feature();
        test_is_learned_sender();
        test_write_cfg_to();
        test_rec_swipe_interp();
        NSLog(@"----------------------------------------");
        NSLog(@"PTCoreLogic: %d 通过 / %d 失败", gPass, gFail);
    }
    return gFail ? 1 : 0;
}
