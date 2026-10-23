// ============================================================
// PTUICommon.h —— 共享 UI 伞标题 + 公共助手（v1.0.77）
//
// 统一前 deb（Preferences/RootListController.m）与 dylib（PTDylibUI.m）
// 各自维护一份静态助手（PTPlanById/PTPlanIndexById/saveAction 写回/覆盖页
// 呈现），行为已漂移（重名串台、落盘口径不一）。本文件把「与宿主无关」的
// 部分收成一份；「与宿主有关」的部分（覆盖页窗口形态、采集 hook 装配）
// 声明成每 target 实现一次的 extern 函数，签名一致、内部各按宿主实现。
// ============================================================
#ifndef PTUICommon_h
#define PTUICommon_h

#import <UIKit/UIKit.h>
#import "PTEngineCore.h"      // 配置读写 PTUIReadCfg/PTUIWriteCfg + PTPlanPid 等
#import "PTUINavigator.h"     // 导航协议（from:-式）
#import "PTUILogSource.h"     // 日志数据源协议
#import "PTOverlayPage.h"     // 点击/双击/滑动统一模板（与 deb 共用）

#pragma mark - 方案定位（按 pid，重名不串）

/// 按 pid 找方案（deb 静态 PTPlanById 与 dylib 内联查找合一）
NSDictionary *PTUIPlanById(NSArray *plans, NSString *pid);
/// 按 pid 找下标，找不到返回 -1
NSInteger PTUIPlanIndexById(NSArray *plans, NSString *pid);

#pragma mark - 动作写回（与引擎回放字段一致）

/// 保存单条动作到方案：editIndex>=0 覆盖、否则追加（deb saveAction 与 dylib onSave 合一）
void PTUISaveActionToPlan(NSString *planId, NSDictionary *action, NSInteger editIndex);

#pragma mark - 导航便捷

/// 回退到方案列表页（经 PTUINavigator.current；deb 找栈内 PTShimPlansVC，dylib 找 PTUIPlansVC）
void PTUIPopToPlansList(UIViewController *from);
/// 回退到方案页（两侧栈里都是共享的 PTUIPlanVC，扫栈回退）
void PTUIPopToPlanPage(UIViewController *from);

#pragma mark - 每 target 实现一次（deb: RootListController.m / dylib: PTDylibUI.m）

/// 确保采集 hook 已装配（deb: 注入环境 PTEngine 自带；dylib: 双指菜单形态由
/// PTDylibCore 装配——两边实现不同，签名一致，共享 VC 只认这个签名）
extern void PTUIEnsureCollectHook(void);

typedef void (^PTUIEditorSavedBlock)(void);

/// 弹出统一模板覆盖页。presentation 形态每 target 不同（deb=全屏 modal 不透明；
/// dylib=独立 UIWindow 半透明 + 关/显菜单），保存逻辑统一走 PTUISaveActionToPlan，
/// onSave 供宿主在落盘后刷新自己的页面。
extern void PTUIPresentEditor(UIViewController *presenter,
                              PTOverlayMode mode,
                              NSString *planId,
                              NSInteger editIndex,
                              NSDictionary *editAction,
                              PTUIEditorSavedBlock onSave);

#endif  // PTUICommon_h
