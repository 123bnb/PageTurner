// ============================================================
// PTCoreLogic.h —— 引擎纯逻辑层（v1.0.78 从 PTEngineCore 六件套抽出）
//
// 为什么抽（评审 #6）：要求「纯逻辑测试 + CI 接线」，而引擎六个实现文件
// （PTEngineLog/Config/Match/Exec/TestUI/Chain）都 import UIKit——macOS 上
// 一个都编不了，CI（macos-latest）跑不了任何单测。本文件把「零 UI 依赖的
// 纯逻辑 + 数值常量」下沉成 Foundation/CoreGraphics-only 层：
//   · 三个 target 照常链接（经 PTEngineCore.h 转曝，公共 API 面不变）；
//   · tests/ 只链本层（common/PTCoreLogic.m）即可在 CI 原生跑，见 tests/run.sh。
//
// 内容：数值常量（原 PTEngineCore.h 的宏）+ 方案身份 pid / 方向与动作文案 /
//       特征工具 / 学习稳定性 / 重复录入判定 / 匹配（运行端 PTMatchPlan +
//       测试端 PTTestMatchFeature）/ 时间插值 / 原子写配置 + 运行端缓存声明。
// 边界：本层不碰 UIKit / IOKit / hook / 线程 / 文件监听——只做「输入 → 输出」
//       的判定与计算；宿主持有的状态（gPlans 等）以 extern 声明进入。
// ============================================================
#ifndef PTCoreLogic_h
#define PTCoreLogic_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// ---------- 常量（原 PTEngineCore.h；数值型统一为宏——C 中 static const int
// 不是编译期常量，用作数组尺寸会退化为 VLA，theos -Werror 会升级为错误） ----------
#define kMaxLearnedSenders 64                    // 已学 sender 上限
#define PTLogMaxLines 500                        // 日志循环上限（内存与文件一致）
#define kPagerWindowSec 0.4                      // 翻页器活跃窗口（已学 sender 开窗）
#define kCollectWindowSec 0.30                   // v1.0.19：学习/测试采集窗口（原设置页 0.05s 过短，已对齐）
#define kTapDistThreshold 30.0                   // 位移 <30pt 判定 tap
#define kDirTolerance 15.0                       // 方向容差 ±15°
#define kDistSlack 30.0                          // 位移区间匹配裕度
#define kTapDistSlack 0.15                       // 点击位移区间容差
#define kTapDxThresh 0.05                        // 点击位移方向判定阈值
#define kLearnMin 5                              // 学习下限
#define kLearnMax 15                             // 学习上限
#define kConverge 60.0                           // 位移收敛阈值
#define kSwipeBurstThreshold 5                   // 同方案连续命中达此值 → 进入连滑
#define kSwipeBurstWindowSec 1.2                 // v1.0.72：蓄力时间窗——同方案 1.2s 内的命中都累计（旧版窗口="回放中"，点击等快动作 80~230ms 就播完，第二次按键到来时计数已复位，永远蓄不满）

// ---------- 运行端缓存（宿主 PTEngineConfig.m 持有定义；本层与 tests/ 只读/搭建用） ----------
extern NSMutableDictionary *gPlans;     // pid → 方案字典（匹配/执行/名称回显）
extern double gDebounceMs;              // 普通防抖周期 ms（连滑执行层读）
extern uint64_t gLearnedSenders[];      // 已学 sender 表（PTIsLearnedSender 读）
extern int gLearnedSenderCount;

// ---------- 方案唯一身份 pid（v1.0.74：重名方案不再互相覆盖/串台） ----------
// 背景：配置里两个方案可以同名（设置页/dylib UI 均允许），而引擎 gPlans 长期按
// name 索引——同名方案"后写覆盖前一个"（执行错方案）、改名即失联、删除/编辑按
// name 匹配会误伤同名者。设置页 UI 层 v1.0.66-fix 已 pid 化，本版把 pid 贯通到
// 引擎执行层：gPlans 改 pid 索引，匹配/连滑/执行全链路按 pid 走。
// 规则（三端一致，不会漂移）：有 p[@"pid"] 用字段；无则按「name#数组下标」惰性
// 补发——设置页 PTRead（v1.0.66-fix）、引擎 PTDylibLoadConfig、dylib UI（v1.0.75）
// 对同一份配置补出同一批 pid。补发即落盘，下次读取即带 pid。
extern NSString *PTPlanPid(NSDictionary *p, NSInteger idx);
// pid → 显示名（日志 / pill / 记录区格式化用）；查不到返回 pid 本身（永不返回
// nil——执行中配置被改的极端场景也要有可读标识，同时避免 %@ 格式化 nil）
extern NSString *PTPlanNameForId(NSString *planId);

// ---------- 特征结构 + 匹配 ----------
typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
    int tapDx;
} PagerFeature;
// 运行端匹配：sender + 相位 + 方向±kDirTolerance + 位移区间 → 唯一方案 pid。
// v1.0.74：返回值由 name 改为方案 pid（gPlans 按 pid 索引后，name 无法唯一定位
// 方案——重名时两条记录共用一个键）。调用方（PTEngine.m）原样传给 PTChainHandleHit。
extern NSString *PTMatchPlan(PagerFeature f, uint64_t sender);
// 测试端匹配：刻意读实时配置（不经 gPlans 缓存）——录完特征立刻测试时 mtime
// 刷新可能还没发生；pid 用 PTPlanPid 惰性生成（与引擎补发同规则），执行层
// PTExecutePlanRun 对查不到的 pid 有强制刷新兜底。返回 pid（v1.0.74 起）。
// 读配置走 PTDylibReadCfg（实现在 PTEngineConfig.m；tests/ 提供等价假实现）。
extern NSString *PTTestMatchFeature(int phase, double dir, double dist, uint64_t sender, int tapDx);

// ---------- 工具 ----------
extern NSArray *PTFeaturesOfPlan(NSDictionary *p);
extern NSString *PTDirName(double dir);
extern NSString *PTActionText(NSDictionary *a);
extern NSString *PTDuplicate(NSDictionary *s, NSArray *plans);
extern BOOL PTStable(NSArray *mem, NSString *sender);
extern BOOL PTIsLearnedSender(uint64_t s);

// ---------- 时间插值 / 配置原子写 ----------
// 滑动(手动)回放按时间线性插值取坐标（二分定位区间）；v1.0.78 随纯逻辑层下沉。
extern CGPoint PTRecSwipeInterp(NSArray *xs, NSArray *ys, NSArray *ts, double targetT);
// v1.0.71：原子写指定路径（从 PTDylibWriteCfg 抽出）——设置页双写（jbroot 真实路径 +
// 普通路径兜底）直接用它，不必各写一份序列化逻辑。
extern void PTWriteCfgTo(NSString *path, NSDictionary *cfg);

#endif  // PTCoreLogic_h
