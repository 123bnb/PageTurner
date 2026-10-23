// ============================================================
// PTUINavigator.h —— 共享 UI 层导航抽象（v1.0.77）
//
// 背景：8 个同名设置页 VC 抽到 common/PTUI* 后，两侧只剩「导航方式」一处真差异——
//   · deb：共享 VC 经 PTShimVC 桥接壳进系统设置的导航栈（PSViewController 要求
//     initWithSpecifier:，且设置页「返回即刷新」靠外观回调转发）
//   · dylib：共享 VC 进双指长按菜单窗口自己的 UINavigationController
// 共享 VC 内不判断 target、不直接碰 self.navigationController 的栈结构，全部
// 经本协议出口；各 target 启动时设一次 current。
//
// 栈手术（保存后回列表/回方案页）按 target 分叉：
//   · 回方案列表：deb 栈里是桥接壳 PTShimPlansVC，dylib 栈里是共享的 PTUIPlansVC
//   · 回方案页：两侧都是共享的 PTUIPlanVC（直接 push，无壳），走共享函数
//     PTUIPopToPlanPage（见 PTUICommon.h），不经本协议
// ============================================================
#ifndef PTUINavigator_h
#define PTUINavigator_h

#import <UIKit/UIKit.h>

@protocol PTUINavigator <NSObject>
- (void)ptPush:(UIViewController *)vc from:(UIViewController *)from animated:(BOOL)animated;   // 进入下级页
- (void)ptPopFrom:(UIViewController *)from animated:(BOOL)animated;                              // 关闭自己
- (void)ptPopToPlansListFrom:(UIViewController *)from animated:(BOOL)animated;                   // 新方案保存后回方案列表
@end

@interface PTUINavigator : NSObject
@property (class, nonatomic, strong) id<PTUINavigator> current;   // 各 target 启动时设一次
@end

#endif  // PTUINavigator_h
