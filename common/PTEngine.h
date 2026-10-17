// ============================================================
// PTEngine.h —— PageTurner 统一引擎（roothide / dylib 双 target 共享）
//
// 历史：由 dylib 版 PTDylibCore（v1.0.20，纯 ObjC）抽离为共享引擎母版，
//       与 deb 版运行端（v1.0.56）对齐：删除 tapManual/doubleTapManual 废案、
//       配置路径/拦截开关/原始 IMP 改为由各自 target 注入（见下方 PTSet*）。
//
// 设计：引擎只含「真正跨注入环境通用的逻辑」——配置读写、日志、特征匹配、
//       动作执行、手动录制回放、调试可视化、两条 hook 处理器（addEvent/sendEvent）。
//       roothide 与 dylib 的差异只在「配置路径」「总开关+指定 App 门控」
//       「hook 安装方式（MSHookMessageEx vs method_setImplementation）」，
//       全部通过 PTSet* 接口注入，不写死在引擎里。
// ============================================================
#ifndef PTEngine_h
#define PTEngine_h

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ---------- 配置（路径由 target 注入） ----------
extern NSString *PTDylibCfgPath(void);
extern NSString *PTJbrootRoot(void);       // v1.0.59：共享 jbroot 根路径（roothide），nil=未探测到
extern BOOL PTDylibUsingDebConfig(void);   // YES=复用 deb 版配置；NO=独立配置
extern NSMutableDictionary *PTDylibReadCfg(void);
extern void PTDylibWriteCfg(NSDictionary *cfg);
extern void PTSetCfgPath(NSString *p);       // v1.0.57：配置路径由 target 注入（roothide=/var/mobile，dylib=沙盒容器）
extern NSDictionary *PTConfigDict(void);     // v1.0.57：暴露当前配置字典（roothide 读 masterEnabled/enabledApps）
extern void PTDylibLoadConfig(BOOL force);    // v1.0.57：加载/刷新配置（roothide 构造函数注入路径后主动调一次；hook 处理器内按 mtime 懒加载）

// ---------- 日志 ----------
extern void PTDylibLog(NSString *fmt, ...);
extern void PTDylibLogSetEnabled(BOOL on);
extern NSArray *PTDylibLogLines(void);
extern void PTSetLogPath(NSString *p);       // v1.0.57：日志文件路径由 target 注入

// ---------- hook 装配 ----------
extern void PTDylibInstallHooks(void);        // dylib 用：method_setImplementation + IOKit dlsym
extern void PTDylibInitIOKit(void);           // 公用：dlopen IOKit 解析 sender 读取符号
extern void PTDylibAddEvent(id self, SEL _cmd, void *event);   // 公用 hook 处理器（target 用 MSHookMessageEx 安装）
extern void PTDylibSendEvent(id self, SEL _cmd, UIEvent *event);
extern void PTSetOrigAddEvent(IMP o);         // v1.0.57：roothide 用 MSHookMessageEx 装 hook 后回填原始 IMP
extern void PTSetOrigSendEvent(IMP o);
extern void PTSetInterceptEnabled(BOOL b);    // v1.0.57：roothide 按总开关+指定App 决定；dylib 恒 YES

// ---------- 学习/测试会话状态（core 定义，UI 读写） ----------
extern BOOL sCollectArmed;     // 学习页打开 = YES
extern BOOL sTestArmed;        // 测试页打开 = YES
extern double sLastSampleAt;   // 最近样本时间（学习页诊断）
extern UIView *sTestDot;       // 测试页绿点视图
extern __weak id sTestLogSink;   // 测试页实时记录区（弱引用）
extern void PTDylibSetLearningLocal(BOOL on);   // 写 learning.active + 清样本

// ---------- 工具（core 定义，UI 复用） ----------
extern double PTNowC(void);
extern NSString *PTDirName(double dir);
extern NSString *PTActionText(NSDictionary *a);
extern NSArray *PTFeaturesOfPlan(NSDictionary *p);
extern NSString *PTDuplicate(NSDictionary *s, NSArray *plans);
extern BOOL PTStable(NSArray *mem, NSString *sender);
extern void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx);
extern void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur);

// ---------- 手动录制（覆盖层 UIPanGestureRecognizer 抓取） ----------
extern void PTRecStart(NSString *mode, double topY, void (^done)(NSArray *pts));
extern void PTRecStop(void);
extern void PTRecShowOverlay(NSString *mode, NSString *planName, NSInteger editIndex, NSDictionary *editAction);
extern void PTDebugMigrateOverlay(void);
extern void PTRecMigrateOverlay(void);

// ---------- 主菜单窗口（main 实现，UI 关闭按钮调用） ----------
extern void PTDylibCloseMenu(void);
extern void PTDylibShowMenu(void);
extern BOOL PTDylibIsMenuWindow(UIWindow *w);

#endif
