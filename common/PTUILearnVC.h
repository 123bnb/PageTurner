// ============================================================
// PTUILearnVC.h —— 学习页（大白屏录特征）（v1.0.77 共享版）
// ============================================================
#ifndef PTUILearnVC_h
#define PTUILearnVC_h

#import "PTUIBaseListVC.h"

@interface PTUILearnVC : PTUIBaseListVC
@property (nonatomic, strong) NSString *planId;   // 方案唯一身份
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *dirLabel;
@property (nonatomic, strong) UILabel *distLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray *mem;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL limitExceeded;   // v1.0.28：继续录后跳过 15 次上限
@property (nonatomic, strong) NSDictionary *readyFt;      // v1.0.29：稳定后的特征，等右上角保存
@property (nonatomic, assign) BOOL onceMode;       // v1.0.34：增加特征模式（按 1 次记录，再按覆盖，以最后为准）
@property (nonatomic, assign) NSInteger replaceIndex;  // v1.0.34：>=0 = 替换方案第 N 条特征（特征列表重录）
@property (nonatomic, assign) int onceCount;       // v1.0.34：增加特征模式已记录次数
@property (nonatomic, strong) CAShapeLayer *trailLayer;   // v1.0.29：调试可视化同款轨迹
@property (nonatomic, strong) UIView *trailDot;
@property (nonatomic, strong) UILabel *trailLabel;
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

#endif  // PTUILearnVC_h
