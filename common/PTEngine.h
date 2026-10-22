// ============================================================
// PTEngine.h —— PageTurner 引擎外壳（hook 装配 / 运行拦截 / 调试可视化 / 录制 / 双指菜单）
//
// v1.0.71 拆分说明：引擎母版 PTEngine.m 一分为二——
//   · 核心（PTEngineCore.h/.m）：配置读写、jbroot、特征匹配、学习样本、测试回放、
//     连滑状态机、动作执行、日志、进程角色无关的纯逻辑 + 会话/执行态全局。
//     三个编译目标（deb / dylib / Preferences）全部链接。
//   · 外壳（本文件 + PTEngine.m）：hook 装配、运行拦截会话、调试可视化、手动录制、
//     双指菜单——只被 deb 与 dylib 链接，Preferences 不链（其进程内另有一套 hook，
//     见 Preferences/RootListController.m 的 SImpAddEvent/SImpSendEvent）。
//   老消费者只需 import "PTEngine.h"——本文件 re-export PTEngineCore.h，API 不丢。
//
// 跨层依赖解法：
//   · Core 需要外壳能力时用弱引用（PTDebugDestroyOverlay，Preferences 只链 Core 时为 NULL）。
//   · 外壳/设置页写配置走 PTSetCfgWriter 注入的写入器（设置进程 = 双写 jbroot + 普通路径）。
// ============================================================
#ifndef PTEngine_h
#define PTEngine_h

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "PTEngineCore.h"

// ---------- hook 装配 ----------
extern void PTDylibInstallHooks(void);        // dylib 用：method_setImplementation + IOKit dlsym
extern void PTDylibAddEvent(id self, SEL _cmd, void *event);   // 公用 hook 处理器（target 用 MSHookMessageEx 安装）
extern void PTDylibSendEvent(id self, SEL _cmd, UIEvent *event);
extern void PTSetOrigAddEvent(IMP o);         // roothide 用 MSHookMessageEx 装 hook 后回填原始 IMP
extern void PTSetOrigSendEvent(IMP o);
extern void PTSetInterceptEnabled(BOOL b);    // roothide 按总开关+指定App 决定；dylib 恒 YES

// ---------- 调试可视化 ----------
extern void PTDebugMigrateOverlay(void);      // keyWindow 变化时把绿点覆盖层迁到新窗口

// ---------- 手动录制（覆盖层 UIPanGestureRecognizer 抓取，经 PTRecStart/PTRecStop 控制） ----------
extern void PTRecStart(NSString *mode, double topY, void (^done)(NSArray *pts));
extern void PTRecStop(void);

// ---------- 主菜单窗口（PTDylibUI.m 实现，UI 关闭按钮与双指检测调用） ----------
extern void PTDylibCloseMenu(void);
extern void PTDylibShowMenu(void);
extern void PTDylibHideMenuPreserving(void);   // 关菜单但保留导航栈（录制/编辑后回方案页，不改全局关菜单行为）
extern UIWindow *PTDylibMenuWindow(void);        // 暴露菜单窗口（导航栈含方案页）
extern BOOL PTDylibIsMenuWindow(UIWindow *w);

#endif
