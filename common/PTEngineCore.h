// ============================================================
// PTEngineCore.h —— PageTurner 引擎核心（三目标共享：deb / dylib / Preferences）
//
// v1.0.71 从 PTEngine.m 拆出。拆移动因（review 第三轮实锤）：
//   Preferences bundle 此前不链 PTEngine.m，把引擎约 1000 行逻辑（配置/匹配/
//   学习样本/测试回放/工具函数）在 RootListController.m 里又写了一遍，且已双向
//   漂移（3 个真实 bug：动作文案过期、测试区无连滑刹停、无倍速/无取消；
//   采集窗口 0.05s vs 引擎 0.30s 等）。本文件把「核心」独立成核，三个 target 全链接：
//     · deb（Tweak.m + 本 core + 外壳）
//     · dylib（targets/dylib/* + 本 core + 外壳）
//     · Preferences（RootListController + 本 core，不链外壳）
//   设置页的 ~950 行重复实现随之删除，行为以引擎侧为准（修复上述漂移）。
//
// 边界：
//   Core（本文件）= 配置读写/jbroot/特征匹配/学习样本/测试回放/连滑状态机/
//                   动作执行/日志/进程角色无关的纯逻辑 + 会话/执行态全局。
//   PTCoreLogic（v1.0.78）= Core 中「零 UI 依赖」的纯逻辑子层（数值常量/pid 身份/
//                   文案/特征工具/学习稳定性/匹配/插值/原子写），Foundation-only，
//                   tests/ 只链它即可在 macOS 原生单测；经本头 import 转曝。
//   外壳（PTEngine.h）= hook 装配、运行拦截会话、调试可视化、录制、双指菜单
//                   ——只被 deb 与 dylib 链接，Preferences 不链。
//   跨层依赖解法：
//     · Core 需要外壳能力时用弱引用（PTDebugDestroyOverlay，外壳未链时为 NULL）。
//     · 外壳/设置页写配置走 PTSetCfgWriter 注入的写入器（设置进程=双写）。
// ============================================================
#ifndef PTEngineCore_h
#define PTEngineCore_h

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ---------- 纯逻辑层（v1.0.78：常量与零 UI 依赖逻辑下沉 common/PTCoreLogic.h） ----------
// 为什么抽：要求「纯逻辑测试 + CI 接线」，而引擎六个实现文件都 import UIKit——
// macOS 上一个都编不了，CI（macos-latest）跑不了任何单测。PTCoreLogic 把纯逻辑
// + 数值常量收成 Foundation/CoreGraphics-only 层：三个 target 照常经本头转曝
// （公共 API 面不变），tests/ 只链 PTCoreLogic.m 即可原生跑（tests/run.sh）。
// 转曝内容：数值常量 / gPlans 等运行端缓存声明 / PTPlanPid / PTPlanNameForId /
//           PagerFeature / PTMatchPlan / PTTestMatchFeature / PTFeaturesOfPlan /
//           PTDirName / PTActionText / PTDuplicate / PTStable / PTIsLearnedSender /
//           PTRecSwipeInterp / PTWriteCfgTo。
#import "PTCoreLogic.h"

// ---------- 配置 ----------
extern NSString *PTDylibCfgPath(void);
extern NSString *PTJbrootRoot(void);       // 共享 jbroot 根路径（roothide），nil=未探测到
extern NSMutableDictionary *PTDylibReadCfg(void);
extern void PTDylibWriteCfg(NSDictionary *cfg);
// v1.0.77：UI 层统一配置读写（设置页 / dylib 浮窗 / common/PTUI* 共享 VC 三处合一）。
// 此前「读+pid 惰性补发」在设置页 PTRead 与 dylib PTUIRead 各存一份逐字复制的实现，
// 写路径也有两条（设置页双写 / dylib 容器单写）——UI 共享化后统一到此：
//   · 读 = PTDylibReadCfg + pid 补发（规则同引擎 PTDylibLoadConfig 的 gPlans 补发），
//     补发即经 PTUIWriteCfg 落盘；
//   · 写 = 经 PTSetCfgWriter 注入的写入器（设置进程=双写；未注入=dylib 容器单写）。
extern NSMutableDictionary *PTUIReadCfg(void);
extern void PTUIWriteCfg(NSDictionary *cfg);
extern void PTSetCfgPath(NSString *p);     // 配置路径由 target 注入（roothide 多候选 / dylib 容器 / 设置页 PT_PREFS）
extern NSDictionary *PTConfigDict(void);   // 暴露当前配置字典（roothide 读 masterEnabled/enabledApps）
extern void PTDylibLoadConfig(BOOL force); // 加载/刷新配置（mtime 懒加载）
extern void PTDylibSetLearningLocal(BOOL on);   // 写 learning.active + 清样本
extern void PTSetCfgWriter(void (*writer)(NSDictionary *cfg));   // v1.0.71：配置写入器注入（nil=PTDylibWriteCfg 单写）

// ---------- 日志 ----------
extern void PTDylibLog(NSString *fmt, ...);
extern void PTDylibLogSetEnabled(BOOL on);
extern NSArray *PTDylibLogLines(void);
extern void PTDylibLogClearLines(void);    // v1.0.71：清空内存日志（设置页关调试开关时调）
extern void PTSetLogPath(NSString *p);     // 日志文件路径由 target 注入
extern void PTSetFileLogEnabled(BOOL b);   // 文件日志总开关（NO=不写文件，仅内存）

// ---------- hook 装配（外壳提供；此处仅弱引用声明，见 PTEngine.h） ----------
// IOKit sender 读取符号（PTDylibInitIOKit 解析；外壳与设置页 hook 共用）
typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
typedef double (*IOHIDEventGetFloatValue_t)(void *, uint32_t);
extern IOHIDEventGetType_t pGetType;
extern IOHIDEventGetSenderID_t pGetSender;
extern IOHIDEventGetFloatValue_t pGetFloat;
extern void PTDylibInitIOKit(void);

// 可视化覆盖层销毁（外壳实现；Preferences 只链 Core 时为 NULL，调用前判空）
extern void PTDebugDestroyOverlay(void) __attribute__((weak_import));

// ---------- 会话/执行态全局（Core 定义；外壳 hook 与设置页 hook 跨文件读写） ----------
extern BOOL sCollectArmed;     // 学习页打开 = YES
extern BOOL sTestArmed;        // 测试页打开 = YES
extern double sLastSampleAt;   // 最近样本时间（学习页诊断）
extern UIView *sTestDot;       // 测试页绿点视图
extern __weak id sTestLogSink; // 测试页实时记录区（弱引用）
extern uint64_t sCurSender;    // 当前 sender（采集端）
extern double sWindowUntil;    // 采集窗口截止（学习/测试）
extern BOOL sSessActive;
extern double sSessDist, sSessFirstDir;
extern BOOL sSessHasMove;
extern CGPoint sSessLast, sSessStart;

extern BOOL gIsInjecting;      // 注入态（映射动作执行中/轨迹重放中）
extern BOOL gExecRunning;      // 方案序列执行中（连滑检测窗口）
extern BOOL gInFakeTouch;      // 假触摸注入中（hook 放行判据）
extern int gExecToken;         // 执行令牌（失配=被打断，抬手收尾）
extern BOOL gDebugDots;        // 调试可视化开关（配置项）

// v1.0.76：注入态引用计数进出（方案回放与未命中重放可并发，成对调用）。
// gIsInjecting 仍是对外面孔——计数归零才清零，读取方无需改。
extern void PTInjectBegin(void);
extern void PTInjectEnd(void);

// ---------- 工具 ----------
extern double PTNowC(void);
// 其余工具（PTDirName/PTActionText/PTFeaturesOfPlan/PTDuplicate/PTStable/
// PTIsLearnedSender）v1.0.78 已随纯逻辑层下沉 PTCoreLogic.h（经本头转曝可见）。

// ---------- 方案唯一身份 pid / 特征结构 / 匹配（v1.0.78 起见 common/PTCoreLogic.h） ----------
// PTPlanPid / PTPlanNameForId / PagerFeature / PTMatchPlan 已随纯逻辑层下沉，
// 声明与「重名方案互不覆盖/串台」的背景注释见 PTCoreLogic.h（经本头 import
// 转曝，调用方无需改）。

// ---------- 测试（Core 实现；设置页/dylib 测试页共用） ----------
extern void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx);
extern void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur);
extern void PTSampleAppend(int phase, double dir, double dist, int tapDx);   // 学习样本落盘（原 SAppendSample）
extern void PTTestReset(void);      // v1.0.71：测试页退出一键复位（armed/绿点/方向线/P/尾巴/记录区）

// ---------- 连滑（Core 状态机；外壳命中判定后调用） ----------
// v1.0.74：入参为方案 pid（PTMatchPlan 的返回值），不再按 name 匹配——重名方案
// 在执行层曾互相覆盖/串台（UI 层 v1.0.66-fix 已修，本版修引擎执行层）。
extern void PTChainHandleHit(NSString *planId);   // v1.0.71：运行端命中方案——连滑判定 + 起执行/续档/刹停
extern void PTChainReset(void);                 // 刹停/未命中/关开关：清空连滑链
// v1.0.73：按键未命中（没录入的按键）——退出连滑 **且** 立刻停掉在飞动作。
// 与 PTChainReset 的区别：Reset 只清连滑状态、在飞动作照常播完；Miss 额外 gExecToken++
// 让在飞回放令牌失配→抬手收尾→立即停止（连滑中时补出 pill「已退出连滑」）。
// 运行端（PTHandlePagerEvent）与测试端（PTTestOnEnded）共用，杜绝两端漂移。
extern void PTChainMiss(void);

// 测试 sink 协议方法（sTestLogSink 为 id 类型，需编译器可见的声明才能调用）
@interface NSObject (PTTestSink)
- (void)appendLog:(NSString *)s;
// v1.0.73：原地改写最后一行（连滑续滑轮数聚合用）。逐轮 append 会在数秒内刷爆记录区，
// 故续滑进度走"同一行不断改写"，关键事件（进入连滑/升档/刹停）才另起一行。
- (void)updateLastLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

#endif  // PTEngineCore_h
