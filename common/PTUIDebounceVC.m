// ============================================================
// PTUIDebounceVC.m —— 防抖间隔页实现（v1.0.77 共享版）
// 文案取 deb 版（更完整），top 取值取deb（safeArea 适配）
// ============================================================
#import "PTUIDebounceVC.h"

@implementation PTUIDebounceVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"防抖间隔";
    // v1.0.35：统一成系统设置灰分组背景
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, top, self.view.bounds.size.width - 32, 40)];
    hint.text = @"连续按键的最小间隔（毫秒）。间隔太短时，按住翻页器不放会重复触发动作。";
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:hint];

    self.valLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 48, self.view.bounds.size.width - 32, 30)];
    self.valLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
    [self.view addSubview:self.valLabel];

    self.slider = [[UISlider alloc] initWithFrame:CGRectMake(16, top + 88, self.view.bounds.size.width - 32, 34)];
    self.slider.minimumValue = 100;
    self.slider.maximumValue = 1000;
    double cur = [self.readCfg[@"debounceMs"] doubleValue];
    self.slider.value = (cur > 0) ? cur : 300;
    [self.slider addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.slider];
    [self changed];
}

- (void)changed {
    self.valLabel.text = [NSString stringWithFormat:@"%.0f ms", self.slider.value];
    NSMutableDictionary *cfg = self.readCfg;
    cfg[@"debounceMs"] = @(self.slider.value);
    [self writeCfg:cfg];
}
@end
