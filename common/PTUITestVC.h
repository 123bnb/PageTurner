// ============================================================
// PTUITestVC.h —— 测试页（大白屏 + 绿点点触可视化）（v1.0.77 共享版）
// ============================================================
#ifndef PTUITestVC_h
#define PTUITestVC_h

#import "PTUIBaseListVC.h"

@interface PTUITestVC : PTUIBaseListVC
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, assign) BOOL volumeMode;   // v1.0.80：音量键模式入口（文案改「按音量+ / 音量- 键测试」）
@property (nonatomic, strong) UITextView *logView;   // v1.0.28：实时记录区
@property (nonatomic, strong) CAShapeLayer *trailLayer;   // v1.0.29：调试可视化同款轨迹
@property (nonatomic, strong) UIView *trailDot;
@property (nonatomic, strong) UILabel *trailLabel;
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

#endif  // PTUITestVC_h
