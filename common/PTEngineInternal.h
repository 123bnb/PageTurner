// ============================================================
// PTEngineInternal.h —— 引擎核心 6 个实现文件之间的内部共享声明（v1.0.78）
//
// v1.0.78：PTEngineCore.m（1,525 行 / 84KB）按职责拆为 6 个实现文件——
//   PTEngineLog.m     日志（PTDylibLog 家族 + PTNowC）
//   PTEngineConfig.m  配置路径/读写/UI 入口/运行端缓存/IOKit dlsym
//   PTEngineMatch.m   会话状态/学习样本/方案身份 pid/工具/匹配（运行端+测试端）
//   PTEngineExec.m    动作执行全家（fake touch）+ 测试回放执行链
//   PTEngineTestUI.m  测试可视化（绿点/方向线/P 标记/尾巴）+ 实时记录区
//   PTEngineChain.m   连滑状态机 + pill + 执行入口 + 注入引用计数
// 本文件只放「跨这 6 个文件、但不属于 PTEngineCore.h 公共 API」的 extern——
// 公共 API 仍走 PTEngineCore.h（三目标共享），内部共享走本文件（仅 6 个 .m import）。
//
// 旧单文件时代这些符号靠文件中部的前向声明 + static 可见性搞定；拆文件后
// static 不再是文件内私有那么简单——跨文件即必须 extern，且定义只能有一处
// （同进程内只有一个引擎镜像，多目标各自静态链接一份，见 PTEngineCore.h 注释）。
//
// 注：测试 sink 的 NSObject(PTTestSink) category 声明在 PTEngineCore.h
// （import 即可见），任何文件不得重复定义——同一 TU 内重复定义 category
// 是编译错误（-Werror,-Wobjc-duplicate-category-definition，v1.0.71 CI 实锤）。
//
// v1.0.78(2)：PTCoreLogic.m（纯逻辑层）不 import 本文件——它 Foundation-only、
// 无跨文件内部共享需求（对外只经 PTEngineCore.h → PTCoreLogic.h）；它曾持有的
// gDebounceMs/gPlans/gLearnedSenders/gLearnedSenderCount/PTTestMatchFeature 声明
// 已随定义迁至 PTCoreLogic.h，下面 6 个 .m 经 PTEngineCore.h 照常可见。
// ============================================================
#ifndef PTEngineInternal_h
#define PTEngineInternal_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>   // CGPoint（尾巴绘制签名）

// ---------- Core 内部统一写配置（定义：PTEngineConfig.m） ----------
extern void PTWriteCfg(NSDictionary *cfg);   // Core 内部统一写配置（经注入写入器）

// ---------- 连滑状态（定义：PTEngineChain.m） ----------
extern BOOL gChainEnabled;              // 连滑总开关（PTDylibLoadConfig 读写）
extern NSInteger gSwipeBurstRate;       // 连滑倍速档位 1/2/3（PTEngineExec.m 动作提速读）
extern void PTChainStopAll(void);       // 退后台/测试退场：断链 + 中断在飞回放
extern void PTChainOnHit(NSString *planId, BOOL viaTest);   // 连滑命中判定统一入口（测试端 PTTestExecPlan 调）

// ---------- 会话状态（定义：PTEngineMatch.m） ----------
extern double sLastTestExec;            // 测试起播防抖时间戳（PTChainOnHit 读写）

// ---------- 匹配（定义：PTCoreLogic.m，v1.0.78 随纯逻辑层迁出；声明见 PTCoreLogic.h） ----------
// PTTestMatchFeature 曾在本文件 extern——它读实时配置（PTDylibReadCfg），与
// gPlans 缓存类符号同属纯逻辑层，一并下沉后 tests/ 才能链到它。

// ---------- 测试可视化 / 记录区（定义：PTEngineTestUI.m） ----------
extern void PTTestDrawTrailHead(CGPoint cur);
extern void PTTestTrailFinish(CGPoint p, double hold);
extern void PTTestLog(BOOL agg, NSString *s);
extern NSMutableArray *sTestTrail;     // 滑动(手动)回放尾巴（PTEngineExec.m 的 PTFakeRecSwipeAsync 逐帧追加）
extern int sTestTrailToken;            // 尾巴淡出令牌（PTFakeRecSwipeAsync 新段回放时作废上一段）

// ---------- 动作执行（定义：PTEngineExec.m） ----------
extern void PTRunAction(NSDictionary *a, int token, void (^next)(void));

#endif  // PTEngineInternal_h
