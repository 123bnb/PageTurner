// ============================================================
// PTUIPlansVC.h —— 方案列表页（v1.0.77 共享版）
// ============================================================
#ifndef PTUIPlansVC_h
#define PTUIPlansVC_h

#import "PTUIBaseListVC.h"

@class PTDragSortHelper;   // 属性仅需前向声明（.m 内 import PTDragSortHelper.h）

@interface PTUIPlansVC : PTUIBaseListVC <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray *plans;
@property (nonatomic, strong) PTDragSortHelper *dragHelper;
@end

#endif  // PTUIPlansVC_h
