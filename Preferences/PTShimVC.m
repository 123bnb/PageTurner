// ============================================================
// PTShimVC.m —— deb 侧共享页桥接壳实现（v1.0.77）
// ============================================================
#import "PTShimVC.h"
#import "PTUICommon.h"
#import <UIKit/UIKit.h>

@implementation PTShimVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
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
- (UIViewController *)childForStatusBarStyle {
    return self.childViewControllers.firstObject ?: [super childForStatusBarStyle];
}

- (UIViewController *)ptChildVC { return nil; }
@end

@implementation PTShimDebounceVC
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"防抖间隔";
    return self;
}
- (UIViewController *)ptChildVC { return [PTUIDebounceVC new]; }
@end

@implementation PTShimPlansVC
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"记录与映射";
    return self;
}
- (UIViewController *)ptChildVC { return [PTUIPlansVC new]; }
@end

@implementation PTShimDebugLogVC
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"调试日志";
    return self;
}
- (UIViewController *)ptChildVC { return [PTUIDebugLogVC new]; }
@end
