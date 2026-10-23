// ============================================================
// PTUIFeaturesVC.h —— 已录入特征列表页（v1.0.77 共享版）
// ============================================================
#ifndef PTUIFeaturesVC_h
#define PTUIFeaturesVC_h

#import "PTUIBaseListVC.h"

@interface PTUIFeaturesVC : PTUIBaseListVC <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSString *planId;
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) NSMutableArray *features;
@end

#endif  // PTUIFeaturesVC_h
