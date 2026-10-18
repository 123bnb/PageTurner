//
//  PTOverlayPage.m
//  统一"新增映射"四页面模板（v1.0.62）
//
//  内容两种：绿点拖拽(tap/doubleTap/swipe) 与 轨迹录制(recSwipe)。
//  绿点逻辑逐字移植自原 deb/dylib 的 PTActionVC；录制逻辑逐字移植自原 dylib 的 PTRecShowOverlay。
//
#import "PTOverlayPage.h"

@interface PTOverlayPage () <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL isSwipe;
@property (nonatomic, strong) UIView *dot1, *dot2;
@property (nonatomic, strong) UIView *selectedDot;      // 当前选中的圆点（默认 dot1）
@property (nonatomic, strong) CAShapeLayer *lineLayer;
@property (nonatomic, strong) UILabel *feedbackLabel;   // 绿点页：实时坐标；录制页：提示
@property (nonatomic, strong) UIView *topBar;           // 顶部 取消/完成 条
@property (nonatomic, strong) UIButton *cancelBtn;      // 取消按钮（手势需避让）
@property (nonatomic, strong) UIButton *doneBtn;        // 完成按钮（手势需避让）
// 录制态
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) NSMutableArray *currentPts;
@property (nonatomic, assign) CFAbsoluteTime recT0;
@property (nonatomic, copy) void (^recDoneUI)(NSArray *pts);
@end

@implementation PTOverlayPage

- (void)viewDidLoad {
    [super viewDidLoad];
    self.isSwipe = (self.mode == PTOverlayModeSwipe);

    // 背景：dylib 半透明黑（透出 App）；deb 不透明灰
    self.view.backgroundColor = self.translucent
        ? [UIColor colorWithWhite:0 alpha:0.4]
        : [UIColor systemGroupedBackgroundColor];

    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;

    // 安全区顶（多机型兜底：灵动岛≈54 / 刘海≈47 / 无刘海≈20）
    CGFloat topInset = self.view.safeAreaInsets.top;
    CGFloat statusH = [UIApplication sharedApplication].statusBarFrame.size.height;
    if (topInset < statusH) topInset = statusH;
    if (topInset < 20) topInset = 20;

    // 顶部按钮条（56pt）：取消 / 完成
    self.topBar = [[UIView alloc] initWithFrame:CGRectMake(0, topInset, w, 56)];
    self.topBar.userInteractionEnabled = YES;
    self.topBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.78];
    [self.view addSubview:self.topBar];

    self.cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.cancelBtn.frame = CGRectMake(8, 10, 60, 36);
    [self.cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    self.cancelBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [self.cancelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.cancelBtn addTarget:self action:@selector(onCancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.cancelBtn];

    self.doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.doneBtn.frame = CGRectMake(w - 68, 10, 60, 36);
    self.doneBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.doneBtn setTitle:@"完成" forState:UIControlStateNormal];
    [self.doneBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.doneBtn addTarget:self action:@selector(onDoneTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.doneBtn];

    if (self.mode == PTOverlayModeRecSwipe) {
        [self setupRecSwipeWithTopInset:topInset width:w height:h];
    } else {
        [self setupGreenDotsWithWidth:w height:h];
    }
}

// ---------- 绿点内容（点击 / 双击 / 滑动）----------
- (void)setupGreenDotsWithWidth:(CGFloat)w height:(CGFloat)h {
    if (self.isSwipe) {
        self.lineLayer = [CAShapeLayer layer];
        self.lineLayer.strokeColor = [UIColor systemGrayColor].CGColor;
        self.lineLayer.fillColor = [UIColor clearColor].CGColor;
        self.lineLayer.lineWidth = 2.5;
        self.lineLayer.lineDashPattern = @[@6, @4];
        [self.view.layer addSublayer:self.lineLayer];
        self.dot1 = [self makeDot:self.view label:@"1" color:[UIColor systemGreenColor]];
        self.dot2 = [self makeDot:self.view label:@"2" color:[UIColor systemOrangeColor]];
        if (self.editIndex >= 0 && self.editAction) {
            self.dot1.center = CGPointMake([self.editAction[@"x1"] doubleValue], [self.editAction[@"y1"] doubleValue]);
            self.dot2.center = CGPointMake([self.editAction[@"x2"] doubleValue], [self.editAction[@"y2"] doubleValue]);
        } else {
            self.dot1.center = CGPointMake(w * 0.3, h * 0.45);
            self.dot2.center = CGPointMake(w * 0.7, h * 0.55);
        }
    } else {
        self.dot1 = [self makeDot:self.view label:@"1" color:[UIColor systemGreenColor]];
        if (self.editIndex >= 0 && self.editAction) {
            self.dot1.center = CGPointMake([self.editAction[@"x"] doubleValue], [self.editAction[@"y"] doubleValue]);
        } else {
            self.dot1.center = CGPointMake(w * 0.5, h * 0.5);
        }
    }
    self.selectedDot = self.dot1;   // 默认选中 1
    [self clampAllDots];            // 预载/默认坐标钳制到屏幕内（防负数/出屏）
    [self applySelection];          // 高亮当前选中圆点（1）
    [self updatePos];
    // 全屏拖动：按住屏幕任意处拖动选中的圆点（点圆点选中；默认 dot1）
    UIPanGestureRecognizer *gpan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onGreenPan:)];
    gpan.delegate = self;
    [self.view addGestureRecognizer:gpan];
}

- (UIView *)makeDot:(UIView *)superview label:(NSString *)label color:(UIColor *)color {
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    dot.layer.cornerRadius = 22;
    dot.backgroundColor = [color colorWithAlphaComponent:0.35];
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = color.CGColor;
    UILabel *l = [[UILabel alloc] initWithFrame:dot.bounds];
    l.text = label;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor labelColor];
    l.font = [UIFont boldSystemFontOfSize:16];
    [dot addSubview:l];
    // 点圆点即选中（无需按住圆点本身才能拖）：点哪个选中哪个
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dotTapped:)];
    [dot addGestureRecognizer:tap];
    [superview addSubview:dot];   // 绿点加到全屏视图，可拖区域 = 全屏幕
    return dot;
}

- (void)dotTapped:(UITapGestureRecognizer *)g {
    self.selectedDot = g.view;   // 点哪个圆点选中哪个（滑动时 1/2 可切换）；setter 自动高亮
    [self updatePos];            // 刷新标题栏"选中点N"标记
}

- (void)onGreenPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        CGPoint loc = [g locationInView:self.view];
        // 按下时若落在某个圆点上，则选中它（按下即拖也生效）
        if (self.isSwipe) {
            if (CGRectContainsPoint(self.dot1.frame, loc)) self.selectedDot = self.dot1;
            else if (CGRectContainsPoint(self.dot2.frame, loc)) self.selectedDot = self.dot2;
        }
    }
    if (!self.selectedDot) self.selectedDot = self.dot1;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.view];
        self.selectedDot.center = CGPointMake(self.selectedDot.center.x + t.x, self.selectedDot.center.y + t.y);
        [self clampDot:self.selectedDot];   // 圆心钳到屏幕内：可半出屏，坐标不为负/不越界
        [g setTranslation:CGPointZero inView:self.view];
        [self updatePos];
    }
}

- (void)updatePos {
    if (!self.feedbackLabel) {
        CGFloat w = self.view.bounds.size.width;
        // v1.0.63：坐标提示作为标题栏居中的「标题」，垂直居中在 56pt 半黑条内
        CGFloat barY = self.topBar.frame.origin.y;
        self.feedbackLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, barY + 13, w, 30)];
        self.feedbackLabel.textAlignment = NSTextAlignmentCenter;
        self.feedbackLabel.textColor = [UIColor whiteColor];   // 半黑标题栏上用白字
        self.feedbackLabel.font = [UIFont boldSystemFontOfSize:16];
        [self.view addSubview:self.feedbackLabel];
    }
    if (self.isSwipe) {
        if (self.lineLayer) {
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathMoveToPoint(path, NULL, self.dot1.center.x, self.dot1.center.y);
            CGPathAddLineToPoint(path, NULL, self.dot2.center.x, self.dot2.center.y);
            self.lineLayer.path = path;
            CGPathRelease(path);
        }
        self.feedbackLabel.text = [NSString stringWithFormat:@"滑动起点(%d,%d)→终点(%d,%d)",
            (int)self.dot1.center.x, (int)self.dot1.center.y,
            (int)self.dot2.center.x, (int)self.dot2.center.y];
    } else {
        self.feedbackLabel.text = [NSString stringWithFormat:@"%@(%d, %d)",
            (self.mode == PTOverlayModeDoubleTap) ? @"双击" : @"点击",
            (int)self.dot1.center.x, (int)self.dot1.center.y];
    }
}

// ---------- 选中高亮 / 坐标钳制 ----------
- (void)setSelectedDot:(UIView *)selectedDot {
    _selectedDot = selectedDot;
    [self applySelection];   // 选中变化即刷新高亮（无需手动调用）
}

// 选中态可视化：选中放大+不透明+底色加亮+数字白字；未选中缩小半透明
- (void)applySelection {
    NSArray *dots = self.isSwipe ? @[self.dot1, self.dot2] : @[self.dot1];
    for (UIView *d in dots) {
        BOOL sel = (d == self.selectedDot);
        d.transform = sel ? CGAffineTransformMakeScale(1.3, 1.3) : CGAffineTransformMakeScale(0.85, 0.85);
        d.alpha = sel ? 1.0 : 0.4;
        UIColor *base = [UIColor colorWithCGColor:d.layer.borderColor];   // 原色（绿/橙），边框不变
        d.backgroundColor = [base colorWithAlphaComponent: sel ? 0.65 : 0.3];
        UILabel *lbl = (UILabel *)d.subviews.firstObject;
        if ([lbl isKindOfClass:[UILabel class]]) lbl.textColor = sel ? [UIColor whiteColor] : [UIColor labelColor];
    }
}

// 把圆点圆心(坐标)钳制到屏幕内：允许圆点半出屏（如坐标0时出一半），但坐标不为负、不越界
- (void)clampDot:(UIView *)dot {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGPoint c = dot.center;
    c.x = MIN(MAX(c.x, 0), w);
    c.y = MIN(MAX(c.y, 0), h);
    dot.center = c;
}

- (void)clampAllDots {
    if (self.dot1) [self clampDot:self.dot1];
    if (self.dot2) [self clampDot:self.dot2];
}

// ---------- 轨迹录制内容（滑动手动）----------
- (void)setupRecSwipeWithTopInset:(CGFloat)topInset width:(CGFloat)w height:(CGFloat)h {
    // v1.0.63：去掉「标题栏内不录」限制，全屏幕任意处（含标题栏背景）均可作为滑动起点；
    // 仅【取消】【完成】按钮通过手势代理避让，保证按钮可点。

    // 提示字（背景，居中）
    CGFloat tw = w - 56, th = 150;
    self.feedbackLabel = [[UILabel alloc] initWithFrame:CGRectMake((w - tw) / 2.0, (h - th) / 2.0, tw, th)];
    self.feedbackLabel.numberOfLines = 0;
    self.feedbackLabel.textAlignment = NSTextAlignmentCenter;
    self.feedbackLabel.font = [UIFont systemFontOfSize:16];
    self.feedbackLabel.textColor = [UIColor whiteColor];
    self.feedbackLabel.userInteractionEnabled = NO;
    self.feedbackLabel.layer.cornerRadius = 12;
    self.feedbackLabel.layer.masksToBounds = YES;
    self.feedbackLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.feedbackLabel.text = @"滑动(手动)\n在区域内用手指滑一道，松手即录完\n顶部「取消/完成」可点击";
    [self.view addSubview:self.feedbackLabel];

    // 轨迹线（蓝，lineWidth 6，与圆角端点）
    self.trailLayer = [CAShapeLayer layer];
    self.trailLayer.strokeColor = [UIColor systemBlueColor].CGColor;
    self.trailLayer.fillColor = [UIColor clearColor].CGColor;
    self.trailLayer.lineWidth = 6;
    self.trailLayer.lineJoin = kCALineJoinRound;
    [self.view.layer addSublayer:self.trailLayer];

    // 预载已有轨迹（编辑重录）
    NSArray *lastPts = (self.editIndex >= 0 && self.editAction) ? self.editAction[@"pts"] : nil;
    if (lastPts.count >= 2) {
        self.currentPts = [NSMutableArray arrayWithArray:lastPts];
        [self drawTrail];
        self.feedbackLabel.text = [NSString stringWithFormat:@"滑动(手动)\n已录 %lu 点，可重录\n完成按钮保存覆盖",
            (unsigned long)lastPts.count];
    }

    // 录制完成回调——更新提示（松手后调用）
    __weak typeof(self) wself = self;
    self.recDoneUI = ^(NSArray *pts) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!wself) return;
            wself.feedbackLabel.text = [NSString stringWithFormat:@"滑动(手动)\n已录 %lu 点 ✓\n可重录，完成后点「完成」",
                (unsigned long)pts.count];
        });
    };

    // 录制守卫（dylib 提供；deb 传 nil）：仅置 gRecArmed 供引擎排除录制态，真实抓取由下方 pan 完成
    // topY 传 0：v1.0.63 起全屏幕（含标题栏背景）均可作为起点，标题栏「按钮」由手势代理避让
    if (self.recStart) self.recStart(@"recSwipe", 0, self.recDoneUI);

    // 整个页面接收 pan（含标题栏背景）；【取消】【完成】按钮由手势代理避让，不影响功能
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onRecPan:)];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];
}

- (void)onRecPan:(UIPanGestureRecognizer *)pan {
    CGPoint loc = [pan locationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.currentPts = [NSMutableArray array];
        self.recT0 = CFAbsoluteTimeGetCurrent();
        [self.currentPts addObject:@{@"x": @(loc.x), @"y": @(loc.y), @"t": @0}];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (!self.currentPts) return;
        NSDictionary *last = self.currentPts.lastObject;
        CGPoint lp = CGPointMake([last[@"x"] doubleValue], [last[@"y"] doubleValue]);
        if (hypot(loc.x - lp.x, loc.y - lp.y) >= 3.0f) {   // 3px 阈值降采样（照搬 DVT）
            double tms = (CFAbsoluteTimeGetCurrent() - self.recT0) * 1000.0;
            [self.currentPts addObject:@{@"x": @(loc.x), @"y": @(loc.y), @"t": @(tms)}];
            [self drawTrail];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        if (self.currentPts.count >= 2) {
            [self drawTrail];
            if (self.recDoneUI) self.recDoneUI([self.currentPts copy]);   // 更新提示（暂存）
        }
    }
}

- (void)drawTrail {
    if (!self.trailLayer) return;
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < self.currentPts.count; i++) {
        NSDictionary *pt = self.currentPts[i];
        CGPoint p = CGPointMake([pt[@"x"] doubleValue], [pt[@"y"] doubleValue]);
        if (i == 0) CGPathMoveToPoint(path, NULL, p.x, p.y);
        else CGPathAddLineToPoint(path, NULL, p.x, p.y);
    }
    self.trailLayer.path = path;
    CGPathRelease(path);
}

// ---------- 取消 / 完成 ----------
- (void)onCancelTapped {
    if (self.mode == PTOverlayModeRecSwipe && self.recStop) self.recStop();
    if (self.onDismiss) self.onDismiss(NO);
}

- (void)onDoneTapped {
    if (self.mode == PTOverlayModeRecSwipe) { [self recSwipeDone]; return; }
    [self greenDotDone];
}

- (void)greenDotDone {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    if (self.isSwipe) {
        a[@"type"] = @"swipe";
        a[@"x1"] = @(self.dot1.center.x); a[@"y1"] = @(self.dot1.center.y);
        a[@"x2"] = @(self.dot2.center.x); a[@"y2"] = @(self.dot2.center.y);
        a[@"speed"] = @(1000); a[@"holdMs"] = @(20); a[@"liftMs"] = @(0);
        a[@"steps"] = @(12); a[@"noInertia"] = @(YES);
    } else if (self.mode == PTOverlayModeDoubleTap) {
        a[@"type"] = @"doubleTap";
        a[@"x"] = @(self.dot1.center.x); a[@"y"] = @(self.dot1.center.y);
        a[@"pressMs"] = @(30); a[@"gapMs"] = @(120);
    } else {
        a[@"type"] = @"tap";
        a[@"x"] = @(self.dot1.center.x); a[@"y"] = @(self.dot1.center.y);
        a[@"pressMs"] = @(30);
    }
    // 编辑模式：保留原时序参数，只更新坐标
    if (self.editIndex >= 0 && self.editAction) {
        for (NSString *k in @[@"pressMs", @"gapMs", @"speed", @"holdMs", @"liftMs", @"steps", @"noInertia", @"ms"]) {
            if (self.editAction[k]) a[k] = self.editAction[k];
        }
    }
    if (self.onSave) self.onSave(a, self.editIndex, self.editAction);
    if (self.onDismiss) self.onDismiss(YES);
}

- (void)recSwipeDone {
    if (self.currentPts.count < 2) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"还没录到"
            message:@"请在屏幕任意处（含标题栏背景）实地滑动一次" preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
        return;
    }
    if (self.recStop) self.recStop();
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[@"type"] = @"recSwipe";
    a[@"pts"] = [self.currentPts copy];
    if (self.onSave) self.onSave(a, self.editIndex, self.editAction);
    if (self.onDismiss) self.onDismiss(YES);
}

// ---------- 手势代理：避让【取消】【完成】按钮，保证按钮可点 ----------
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self.view];
    CGRect cb = [self.cancelBtn convertRect:self.cancelBtn.bounds toView:self.view];
    CGRect db = [self.doneBtn convertRect:self.doneBtn.bounds toView:self.view];
    if (CGRectContainsPoint(cb, p) || CGRectContainsPoint(db, p)) return NO;
    return YES;
}

@end
