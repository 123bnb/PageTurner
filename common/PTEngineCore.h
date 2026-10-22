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

// ---------- 常量（原 PTEngine.m / RootListController.m / PTDylibUI.m 三处各抄一份，统一为宏） ----------
// 注意 kMaxLearnedSenders 必须是宏：C 中 static const int 不是编译期常量，
// 用作数组尺寸会退化为 VLA（theos -Werror 会升级为错误）。
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

// ---------- 配置 ----------
extern NSString *PTDylibCfgPath(void);
extern NSString *PTJbrootRoot(void);       // 共享 jbroot 根路径（roothide），nil=未探测到
extern NSMutableDictionary *PTDylibReadCfg(void);
extern void PTDylibWriteCfg(NSDictionary *cfg);
extern void PTWriteCfgTo(NSString *path, NSDictionary *cfg);   // v1.0.71：原子写指定路径（设置页双写用）
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

// ---------- 工具 ----------
extern double PTNowC(void);
extern NSString *PTDirName(double dir);
extern NSString *PTActionText(NSDictionary *a);
extern NSArray *PTFeaturesOfPlan(NSDictionary *p);
extern NSString *PTDuplicate(NSDictionary *s, NSArray *plans);
extern BOOL PTStable(NSArray *mem, NSString *sender);
extern BOOL PTIsLearnedSender(uint64_t s);

// ---------- 特征结构 + 运行端匹配（外壳 PTHandlePagerEvent 用） ----------
typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
    int tapDx;
} PagerFeature;
extern NSString *PTMatchPlan(PagerFeature f, uint64_t sender);

// ---------- 测试（Core 实现；设置页/dylib 测试页共用） ----------
extern void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx);
extern void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur);
extern void PTSampleAppend(int phase, double dir, double dist, int tapDx);   // 学习样本落盘（原 SAppendSample）
extern void PTTestReset(void);      // v1.0.71：测试页退出一键复位（armed/绿点/方向线/P/尾巴/记录区）

// ---------- 连滑（Core 状态机；外壳命中判定后调用） ----------
extern void PTChainHandleHit(NSString *plan);   // v1.0.71：运行端命中方案——连滑判定 + 起执行/续档/刹停
extern void PTChainReset(void);                 // 刹停/未命中/关开关：清空连滑链

// 测试 sink 协议方法（sTestLogSink 为 id 类型，需编译器可见的声明才能调用）
@interface NSObject (PTTestSink)
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

#endif  // PTEngineCore_h
