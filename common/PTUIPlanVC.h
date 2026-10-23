// ============================================================
// PTUIPlanVC.h —— 方案页（名称 / 记录状态 / 映射区）（v1.0.77 共享版）
// ============================================================
#ifndef PTUIPlanVC_h
#define PTUIPlanVC_h

#import "PTUIBaseListVC.h"

@class PTDragSortHelper;   // 属性仅需前向声明（.m 内 import PTDragSortHelper.h）

@interface PTUIPlanVC : PTUIBaseListVC <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSString *planId;   // 方案唯一身份（重名不串名）
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *recStatus;
@property (nonatomic, strong) UILabel *addFeatureBtn;   // v1.0.34：增加特征按钮（紧挨记录按钮）
@property (nonatomic, strong) NSMutableArray *actions;
@property (nonatomic, strong) PTDragSortHelper *dragHelper;
@end

#endif  // PTUIPlanVC_h
