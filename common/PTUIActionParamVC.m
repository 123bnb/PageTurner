// ============================================================
// PTUIActionParamVC.m —— 动作参数调整页实现（v1.0.77 共享版）
//
// 统一口径：延迟时长上限 60000ms（deb 口径；dylib 旧版 5000ms——想录超过 5 秒的
// 延迟只能去设置页，统一后两边都能录到 60 秒）。
// 写回一律按 pid（PTPlanPid 遍历匹配）。
// ============================================================
#import "PTUIActionParamVC.h"
#import "PTUICommon.h"
#import <QuartzCore/QuartzCore.h>

// v1.0.43：各参数预设值（点一下直接跳到该值）
static NSDictionary *PTParamPresets(void) {
    return @{
        @"pressMs": @[ @10, @30, @50, @100, @200, @400 ],
        @"gapMs":   @[ @50, @120, @200, @300, @500 ],
        @"holdMs":  @[ @0, @20, @50, @100, @200 ],
        @"liftMs":  @[ @0, @100, @300, @500, @1000 ],
        @"speed":   @[ @100, @300, @500, @1000, @1500, @2000 ],
        @"steps":   @[ @6, @12, @24, @48, @96 ],
        @"ms":      @[ @50, @100, @300, @500, @1000, @3000 ],
    };
}
static void *PTParamSliderKey = &PTParamSliderKey;   // UIButton -> 所属 UISlider（弱引用，slider 由 self.sliders 持有）
static void *PTParamValueKey = &PTParamValueKey;     // UIButton -> 预设数值

@implementation PTUIActionParamVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"动作参数";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    NSString *type = self.action[@"type"];
    NSArray *defs = nil;
    if ([type isEqualToString:@"tap"]) {
        defs = @[ @{@"key": @"pressMs", @"name": @"按下时长", @"unit": @"ms", @"min": @10, @"max": @500, @"def": @30} ];
    } else if ([type isEqualToString:@"doubleTap"]) {
        defs = @[ @{@"key": @"pressMs", @"name": @"按下时长", @"unit": @"ms", @"min": @10, @"max": @500, @"def": @30},
                  @{@"key": @"gapMs", @"name": @"两次间隔", @"unit": @"ms", @"min": @50, @"max": @800, @"def": @120} ];
    } else if ([type isEqualToString:@"swipe"]) {
        // v1.0.37：弹起停留（liftMs）+ 滑动分段（steps）与按下停留放一起
        // v1.0.39：liftMs 上限 500→2000；steps 上限 48→96
        // v1.0.41：删回滑距离/回滑停顿（防惯性开关统一管理）；新增【防惯性】开关（默认开）
        // v1.0.43：滑动速度默认 1000pt/s（上下限仍 100~2000）
        defs = @[ @{@"key": @"holdMs", @"name": @"按下停留", @"unit": @"ms", @"min": @0, @"max": @500, @"def": @20},
                  @{@"key": @"liftMs", @"name": @"弹起停留", @"unit": @"ms", @"min": @0, @"max": @2000, @"def": @0},
                  @{@"key": @"speed", @"name": @"滑动速度", @"unit": @"pt/s", @"min": @100, @"max": @2000, @"def": @1000},
                  @{@"key": @"steps", @"name": @"滑动分段", @"unit": @"段", @"min": @6, @"max": @96, @"def": @12},
                  @{@"key": @"noInertia", @"name": @"防惯性", @"type": @"switch", @"def": @YES} ];
    } else if ([type isEqualToString:@"delay"]) {
        defs = @[ @{@"key": @"ms", @"name": @"延迟时长", @"unit": @"ms", @"min": @50, @"max": @60000, @"def": @100} ];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.paramDefs = defs;
    self.sliders = [NSMutableArray array];
    self.labels = [NSMutableArray array];
    self.chips = [NSMutableArray array];
    NSDictionary *presets = PTParamPresets();

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width;
    CGFloat rowH = 104;   // v1.0.43：行距缩短（原 118）
    for (int i = 0; i < (int)defs.count; i++) {
        NSDictionary *p = defs[i];
        CGFloat y = top + i * rowH;
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 26)];
        name.text = [NSString stringWithFormat:@"%@%@", p[@"name"],
            [p[@"type"] isEqualToString:@"switch"] ? @"" : [NSString stringWithFormat:@"（%@）", p[@"unit"]]];
        name.font = [UIFont systemFontOfSize:15];
        [self.view addSubview:name];
        if ([p[@"type"] isEqualToString:@"switch"]) {
            // v1.0.43：开关放右侧（标签在左、开关在右），文字不再被开关遮挡；
            // 默认值判定改为「有值取存的值，无值取默认」——旧代码 `|| 默认` 会让
            // 存了 NO 的防惯性开关显示/保存成 ON
            UISwitch *sw = [[UISwitch alloc] init];
            id v = self.action[p[@"key"]];
            sw.on = v ? [v boolValue] : [p[@"def"] boolValue];
            sw.frame = CGRectMake(w - 80, y - 2, 60, 34);
            [self.view addSubview:sw];
            [self.labels addObject:[NSNull null]];
            [self.sliders addObject:sw];
            [self.chips addObject:[NSMutableArray array]];
        } else {
            // 数值行：值在右侧同一行，中间是预设按钮，下面才是滑块
            UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(w - 120, y, 100, 26)];
            val.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
            val.textAlignment = NSTextAlignmentRight;
            [self.view addSubview:val];
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(20, y + 54, w - 40, 34)];
            sl.minimumValue = [p[@"min"] doubleValue];
            sl.maximumValue = [p[@"max"] doubleValue];
            // v1.0.43：有存储值取存储值（含 0），无值才取默认——旧代码 `cur>0?cur:默认`
            // 会把用户调成 0 的参数（如按下停留 0）在重进页面时覆盖回默认
            id vv0 = self.action[p[@"key"]];
            sl.value = vv0 ? [vv0 doubleValue] : [p[@"def"] doubleValue];
            [self.view addSubview:sl];
            [self.labels addObject:val];
            [self.sliders addObject:sl];
            NSArray *ps = presets[p[@"key"]];
            NSMutableArray *rowChips = [NSMutableArray array];
            if (ps.count) {
                CGFloat cw = (w - 40) / ps.count;
                for (int j = 0; j < (int)ps.count; j++) {
                    double vv = [ps[j] doubleValue];
                    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                    b.frame = CGRectMake(20 + j * cw, y + 28, cw - 4, 22);
                    [b setTitle:[NSString stringWithFormat:@"%.0f", vv] forState:UIControlStateNormal];
                    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
                    b.layer.cornerRadius = 6;
                    b.layer.borderWidth = 0.8;
                    b.layer.borderColor = [UIColor systemGray4Color].CGColor;
                    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
                    objc_setAssociatedObject(b, PTParamSliderKey, sl, OBJC_ASSOCIATION_ASSIGN);
                    objc_setAssociatedObject(b, PTParamValueKey, @(vv), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [b addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
                    [self.view addSubview:b];
                    [rowChips addObject:b];
                }
            }
            [self.chips addObject:rowChips];
            [sl addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
            [self changed:sl];
        }
    }
}

// v1.0.43：点预设值 → 滑块跳到该值并刷新（高亮由 changed: 统一处理）
- (void)presetTapped:(UIButton *)b {
    UISlider *sl = objc_getAssociatedObject(b, PTParamSliderKey);
    NSNumber *v = objc_getAssociatedObject(b, PTParamValueKey);
    if (!sl || !v) return;
    sl.value = v.doubleValue;
    [self changed:sl];
}

- (void)changed:(UISlider *)sl {
    NSUInteger i = [self.sliders indexOfObject:sl];
    if (i == NSNotFound || i >= self.labels.count) return;
    ((UILabel *)self.labels[i]).text = [NSString stringWithFormat:@"%.0f", sl.value];
    // v1.0.43：高亮当前值对应的预设按钮（蓝色边框+蓝字），非当前恢复灰
    NSArray *rowChips = (i < self.chips.count) ? self.chips[i] : @[];
    for (UIButton *b in rowChips) {
        double vv = [(NSNumber *)objc_getAssociatedObject(b, PTParamValueKey) doubleValue];
        BOOL near = fabs(sl.value - vv) < 1.0;
        [b setTitleColor:near ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor] forState:UIControlStateNormal];
        b.layer.borderColor = near ? [UIColor systemBlueColor].CGColor : [UIColor systemGray4Color].CGColor;
    }
}

- (void)done {
    NSMutableDictionary *cfg = self.readCfg;
    NSMutableArray *plans = [NSMutableArray array];
    NSArray *raw = cfg[@"plans"] ?: @[];
    for (NSUInteger i = 0; i < raw.count; i++) {
        NSDictionary *p = raw[i];
        if ([p isKindOfClass:[NSDictionary class]] && [PTPlanPid(p, (NSInteger)i) isEqualToString:self.planId]) {   // 按 pid 写回，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
            if (self.actionIndex >= 0 && self.actionIndex < (NSInteger)acts.count) {
                NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:acts[self.actionIndex]];
                for (int i = 0; i < (int)self.sliders.count && i < (int)self.paramDefs.count; i++) {
                    NSString *key = self.paramDefs[i][@"key"];
                    // 开关项写 BOOL，滑块项写数值（switch 支持备用）
                    if ([self.paramDefs[i][@"type"] isEqualToString:@"switch"]) {
                        a[key] = @(((UISwitch *)self.sliders[i]).on);
                    } else {
                        a[key] = @(roundf(((UISlider *)self.sliders[i]).value));
                    }
                }
                acts[self.actionIndex] = a;
            }
            np[@"actions"] = acts;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    [self writeCfg:cfg];
    [self.navigationController popViewControllerAnimated:YES];
}
@end
