// ============================================================
// PTShimVC.m —— deb 侧共享页桥接壳实现（v1.0.77）
//
// 背景：v1.0.77 起 8 个设置页收敛到 common/PTUI*（PTUIBaseListVC 子类，
// 非 PSViewController 体系），而 Preferences 的 specifier detail 入口要求
// 类能响应 initWithSpecifier:。于是加一层壳：
//   · 壳 = PSViewController 子类（满足 specifier 入口 + 状态栏/导航集成）
//   · 壳 viewDidLoad 里把共享子页 addChildViewController 铺满
// 壳只承担「入口适配」，不承载任何 UI 逻辑。
// 注：父类 PSViewController 未公开 initWithSpecifier:（roothide SDK 头文件
// 无此声明），故壳内走 [super init]；specifier detail 实例化时运行期仍会
// 发 initWithSpecifier: 消息，由本类自己的实现接收（标题在此固定设置）。
// ============================================================
#import "PTShimVC.h"
#import "PTUICommon.h"
#import "PTUIDebounceVC.h"
#import "PTUIPlansVC.h"
#import "PTUIDebugLogVC.h"
#import <UIKit/UIKit.h>

@implementation PTShimVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super init];
    return self;
}

// 壳不画任何自己的内容——共享子页铺满
- (void)viewDidLoad {
    [super viewDidLoad];
    UIViewController *child = [self ptChildVC];
    if (!child) return;
    [self addChildViewController:child];
    child.view.frame = self.view.bounds;
    child.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:child.view];
    [child didMoveToParentViewController:self];
}

// 状态栏样式跟随子页（壳自己不呈现内容）
- (UIViewController *)childViewControllerForStatusBarStyle {
    return self.childViewControllers.firstObject ?: [super childViewControllerForStatusBarStyle];
}

- (UIViewController *)ptChildVC { return nil; }
@end

@implementation PTShimDebounceVC
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super init];
    if (self) self.title = @"防抖间隔";
    return self;
}
- (UIViewController *)ptChildVC { return [PTUIDebounceVC new]; }
@end

@implementation PTShimPlansVC
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super init];
    if (self) self.title = @"记录与映射";
    return self;
}
- (UIViewController *)ptChildVC { return [PTUIPlansVC new]; }
@end

@implementation PTShimDebugLogVC
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super init];
    if (self) self.title = @"调试日志";
    return self;
}
- (UIViewController *)ptChildVC { return [PTUIDebugLogVC new]; }
@end
