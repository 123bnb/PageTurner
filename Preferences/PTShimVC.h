// ============================================================
// PTShimVC.h —— deb 侧共享页桥接壳（v1.0.77）
//
// 背景：8 个同名设置页抽到 common/PTUI*（plain UIViewController）后，deb 侧
// 还有一处宿主差异——系统设置的 specifier detail 必须是 PSViewController 子类
// （要响应 initWithSpecifier:）。桥接壳本身是 PSViewController（满足框架），
// 真正的页面是壳 addChildViewController 进来的共享 VC：
//   · 子页所有[self.navigationController pushViewController:]经父链拿到真导航器
//   · 外观回调（viewWillAppear 等）由子 VC 自己响应，壳只转发状态栏样式
// 只有三个 specifier 入口需要壳：防抖 / 记录与映射 / 调试日志；其余共享页
// （方案页/特征/学习/测试/参数/日志内容）全部由代码 push，直接入栈无壳。
// ============================================================
#ifndef PTShimVC_h
#define PTShimVC_h

#import <Preferences/PSViewController.h>

@interface PTShimVC : PSViewController
- (UIViewController *)ptChildVC;   // 子类提供共享页实例
@end

/// 防抖间隔（specifier detail → common/PTUIDebounceVC）
@interface PTShimDebounceVC : PTShimVC
@end

/// 记录与映射列表（specifier detail → common/PTUIPlansVC）
@interface PTShimPlansVC : PTShimVC
@end

/// 调试日志列表（specifier detail → common/PTUIDebugLogVC）
@interface PTShimDebugLogVC : PTShimVC
@end

#endif  // PTShimVC_h
