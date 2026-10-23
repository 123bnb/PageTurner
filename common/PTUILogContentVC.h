// ============================================================
// PTUILogContentVC.h —— 单份日志内容页（v1.0.77 共享版）
// ============================================================
#ifndef PTUILogContentVC_h
#define PTUILogContentVC_h

#import "PTUIBaseListVC.h"

@interface PTUILogContentVC : PTUIBaseListVC
@property (nonatomic, assign) NSInteger logIndex;   // 对应 PTUILogSource logItems 的下标
@property (nonatomic, strong) NSString *logTitle;   // 标题（= 该项 name）
@end

#endif  // PTUILogContentVC_h
