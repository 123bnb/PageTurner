// ============================================================
// PTUIActionParamVC.h —— 动作参数调整页（v1.0.77 共享版）
// ============================================================
#ifndef PTUIActionParamVC_h
#define PTUIActionParamVC_h

#import "PTUIBaseListVC.h"

@interface PTUIActionParamVC : PTUIBaseListVC
@property (nonatomic, strong) NSString *planId;
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, assign) NSInteger actionIndex;
@property (nonatomic, strong) NSDictionary *action;
@property (nonatomic, strong) NSArray *paramDefs;
@property (nonatomic, strong) NSMutableArray *sliders;
@property (nonatomic, strong) NSMutableArray *labels;
@property (nonatomic, strong) NSMutableArray *chips;   // v1.0.43：每行预设按钮数组（对应滑块行）
@end

#endif  // PTUIActionParamVC_h
