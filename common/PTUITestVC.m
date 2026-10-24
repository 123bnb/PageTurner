// ============================================================
// PTUITestVC.m —— 测试页实现（v1.0.77 共享版）
// 按翻页器按键 → 匹配方案 → 执行动作 → 绿点显示注入位置
// 采集 hook 经每 target 的 PTUIEnsureCollectHook 确保装配
// ============================================================
#import "PTUITestVC.h"
#import "PTUICommon.h"
#import <QuartzCore/QuartzCore.h>

#define SLog(fmt, ...) PTDylibLog(fmt, ##__VA_ARGS__)

@implementation PTUITestVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"测试本方案";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 80, self.view.bounds.size.width - 32, 120)];
    tip.numberOfLines = 0;
    tip.textAlignment = NSTextAlignmentCenter;
    tip.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    // v1.0.80：音量键模式入口——文案扩为「按音量+ / 音量- 键测试」（音量键不经特征
    // 匹配，按下即按 volSource 直映射，故不用「匹配成功」口径）
    if (self.volumeMode) {
        tip.text = @"按音量+ / 音量- 键测试音量键模式\n\n音量键按下即执行对应映射区的动作序列，\n绿点 = 注入点触的位置\n（点击原地显示；滑动从起点到终点）";
    } else {
        tip.text = [NSString stringWithFormat:@"按翻页器按键测试方案「%@」\n\n匹配成功会执行动作序列，\n绿点 = 注入点触的位置\n（点击原地显示；滑动从起点到终点）", self.planName ?: @""];
    }
    [self.view addSubview:tip];

    // v1.0.28：测试页下方实时记录区（吞了什么/映射了什么；返回即消失不保留）
    CGFloat h = self.view.bounds.size.height, w = self.view.bounds.size.width;
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, h - 210, w - 24, 190)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    // v1.0.31：深色模式适配——浅灰底改系统次级背景
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 10;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:self.logView];
    [self appendLog:@"等待按键… 命中/未命中实时显示在这里"];

    // 绿点：全屏可移动的可视化圆点（不拦截触摸）
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 72, 72)];
    dot.layer.cornerRadius = 36;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.35];
    dot.layer.borderWidth = 3;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.hidden = YES;
    dot.userInteractionEnabled = NO;
    [self.view addSubview:dot];

    sTestDot = dot;
    sTestArmed = YES;
    sTestLogSink = self;
    PTUIEnsureCollectHook();
    SLog(@"test: viewDidLoad armed=YES（方案 %@）", self.planName ?: @"");
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // v1.0.71：改调 Core 的 PTTestReset（armed/绿点/方向线/P/尾巴/记录区/令牌 一站式复位；
    // 旧实现漏了 sTestTrailToken++，上一段回放余留的淡出会误清新轨迹）
    PTTestReset();
}

// v1.0.28：实时记录区追加一行并滚动到底部
- (void)appendLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", s] : s;
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}

// v1.0.73：原地改写最后一行——连滑续滑进度聚合显示用。
// 逐轮 append 会在数秒内刷爆记录区（点击类一轮约 80ms），故续滑进度复用同一行不断改写。
- (void)updateLastLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    if (!cur.length) { self.logView.text = s; return; }
    NSRange nl = [cur rangeOfString:@"\n" options:NSBackwardsSearch];
    NSString *head = (nl.location == NSNotFound) ? @"" : [cur substringToIndex:nl.location + 1];
    self.logView.text = [head stringByAppendingString:s];
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}

// v1.0.29：调试可视化同款轨迹——起点绿点 + 方向线 + 终点 P 标记（点击只有 P 标记）
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase {
    [self.trailLayer removeFromSuperlayer];
    [self.trailDot removeFromSuperview];
    [self.trailLabel removeFromSuperview];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGPoint start = CGPointMake(w * 0.5, h * 0.38);   // 避开上方提示/下方记录区
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    dot.layer.cornerRadius = 18;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.3];
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.center = start;
    [self.view addSubview:dot];
    self.trailDot = dot;
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    lb.text = @"P";
    lb.textAlignment = NSTextAlignmentCenter;
    lb.font = [UIFont boldSystemFontOfSize:18];
    lb.textColor = [UIColor whiteColor];
    lb.backgroundColor = [UIColor systemGreenColor];
    lb.layer.cornerRadius = 18;
    lb.clipsToBounds = YES;
    if (phase == 1) {
        double rad = dir * M_PI / 180.0;
        CGPoint end = CGPointMake(start.x + cos(rad) * dist, start.y + sin(rad) * dist);
        CAShapeLayer *l = [CAShapeLayer layer];
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, start.x, start.y);
        CGPathAddLineToPoint(path, NULL, end.x, end.y);
        l.path = path;
        CGPathRelease(path);
        l.strokeColor = [UIColor systemGreenColor].CGColor;
        l.fillColor = [UIColor clearColor].CGColor;
        l.lineWidth = 3;
        [self.view.layer addSublayer:l];
        self.trailLayer = l;
        lb.center = end;
    } else {
        lb.center = start;
    }
    [self.view addSubview:lb];
    self.trailLabel = lb;
}
@end
