// ============================================================
// PTUIDebounceVC.h —— 防抖间隔页（v1.0.77 共享版）
//
// 统一前：deb PTDebounceVC（PSViewController + initWithSpecifier）与
// dylib PTDebounceVC（UIViewController + init）两份近乎逐行复制，仅提示文案
// 与 top 微差。本版收成一份 plain UIViewController，deb 侧经 PTShimDebounceVC
// 桥接进 specifier detail。
// ============================================================
#ifndef PTUIDebounceVC_h
#define PTUIDebounceVC_h

#import "PTUIBaseListVC.h"

@interface PTUIDebounceVC : PTUIBaseListVC
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valLabel;
@end

#endif  // PTUIDebounceVC_h
