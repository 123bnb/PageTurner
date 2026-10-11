// ============================================================
// RootListController.m —— PageTurner 设置页（v1.0.1 全 UI 宿主）
//
// 页面结构（全部在系统设置 → PageTurner）：
//   RootListController  总开关 / 指定App生效 / 防抖 / 记录与映射 / 版本
//   PTPlansVC           方案列表（左滑删除 / 新增方案）
//   PTPlanVC            方案页（名称 / 记录状态 / 映射区 / 新增映射）
//   PTLearnVC           学习页（大白屏录特征，轮询 plist 判定）
//   PTActionVC          动作设置（绿点①点击/双击；①②起点终点+速度滑动）
//
// 学习链路：
//   - 进入学习页：写 learning.active=true + 清 learningSamples
//   - 注入 Preferences 进程的 tweak 收到翻页器按键 → append 样本到 learningSamples
//   - 本页 NSTimer 轮询 0.3s：读走样本（清空已读）→ 判定稳定/上限/去重 → 更新 UI
//   - 稳定 → 弹命名框 → feature（sender+相位+方向+位移区间）写入方案
//
// 注意：设置页 bundle 不调用注入 dylib 的符号（dyld two-level 会崩），
//       全部 plist 读写在本文件自实现（PTRead/PTWrite）
// ============================================================

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/time.h>
#include <math.h>
#include <float.h>

@interface PSViewController (Private)
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier;
@end

// ---------- 全部子页接口（顶部集中声明，避免跨类前向引用问题） ----------
@interface RootListController : PSListController
@end

@interface PTAppListVC : PSViewController <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray *allApps;
@property (nonatomic, strong) NSMutableArray *shown;
@property (nonatomic, strong) NSMutableSet *selected;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UISearchBar *sb;
@end

@interface PTDebounceVC : PSViewController
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valLabel;
@end

@interface PTPlansVC : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray *plans;
@property (nonatomic, strong) UITableView *tv;
- (void)reload;
@end

@interface PTPlanVC : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UILabel *recStatus;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray *actions;
- (void)reload;
@end

@interface PTLearnVC : PSViewController
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *dirLabel;
@property (nonatomic, strong) UILabel *distLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray *mem;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) UIView *traceView;   // 轨迹 overlay（全屏透明，不挡触摸）
@end

@interface PTActionVC : PSViewController
@property (nonatomic, strong) NSString *actionType;
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UIView *dot1, *dot2;
@property (nonatomic, strong) UILabel *posLabel;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, assign) BOOL isSwipe;
@end

@interface PTDebugLogVC : PSViewController
@end

// ---------- 工具 ----------
static NSString *PT_PREFS = @"/var/mobile/Library/Preferences/com.yourname.pageturner.plist";
static const double kDirTol = 15.0;     // 方向容差
static const double kDistSlack = 30.0;  // 位移匹配裕度
static const int kLearnMin = 5;         // 下限
static const int kLearnMax = 15;        // 上限
static const double kConverge = 60.0;   // 位移收敛

static NSMutableDictionary *PTRead(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:PT_PREFS];
    return d ? d : [NSMutableDictionary dictionary];
}

static void PTWrite(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *tmp = [PT_PREFS stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:PT_PREFS error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:PT_PREFS error:nil];
}

static void PTSetLearningLocal(BOOL on) {
    NSMutableDictionary *cfg = PTRead();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTWrite(cfg);
}

// ---------- 学习收集（bundle 内自 hook，不依赖 tweak 注入 Preferences 进程）----------
// 根因：roothide 空 Filter 不注入系统 App（Preferences），tweak 收集链路失效。
// bundle 必然被 PreferenceLoader 加载进 Preferences 进程，在这里自己 hook 事件收集样本。
static double PTNowC(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
typedef double (*IOHIDEventGetFloatValue_t)(void *, uint32_t);
static IOHIDEventGetType_t sGetType = NULL;
static IOHIDEventGetSenderID_t sGetSender = NULL;
static IOHIDEventGetFloatValue_t sGetFloat = NULL;
static uint64_t sCurSender = 0;
static BOOL sHooked = NO;
static BOOL sCollectArmed = NO;      // 学习页打开时置 YES（v1.0.4：进入即 armed，无延迟）
// 学习会话（v1.0.4 原版：addEvent 层读 IOHIDEvent 相对位移 0x23/0x24，无任何设备过滤）
static BOOL sSessActive = NO;
static uint64_t sSessSender = 0;
static double sSessLastAt = 0;
static double sSessDist = 0, sSessFirstDir = 0;
static BOOL sSessHasMove = NO;
static BOOL sSessSettled = NO;
static double sLastSampleAt = 0;     // 最近一次样本时间（学习页诊断用）
// 轨迹（学习页可视化）：最近一次按键的相对位移累积路径（起点=屏幕中心）
static NSMutableArray *sTracePoints = nil;   // NSValue(CGPoint) 相对坐标
static double sTraceX = 0, sTraceY = 0;      // 相对位移累计
static BOOL sTraceHas = NO;
static IMP gOrigAddEvent = NULL;

static void SAppendSample(int phase, double dir, double dist) {
    NSMutableDictionary *cfg = PTRead();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sCurSender],
        @"phase": @(phase), @"direction": @(dir), @"dist": @(dist),
    }];
    cfg[@"learningSamples"] = samples;
    PTWrite(cfg);
    sLastSampleAt = PTNowC();
}

static void SFinishSession(void);   // 前向声明

// v1.0.4 原版录制：hook _UIUpdateHIDDigitizerInput -addEvent:，type=11 全收
// （无设备过滤、无锚定 —— 这是 1.0.4 能正常录翻页器的原因），读相对位移 0x23/0x24
static void SImpAddEvent(id self, SEL _cmd, void *event) {
    @try {
        if (sGetType && sGetSender && event) {
            uint32_t type = sGetType(event);
            if (type == 11 && sCollectArmed) {
                // 翻页器 digitizer：读相对位移（0x23=dx 0x24=dy）
                uint64_t sender = sGetSender(event);
                double dx = sGetFloat ? sGetFloat(event, 0x23) : 0;
                double dy = sGetFloat ? sGetFloat(event, 0x24) : 0;
                double now = PTNowC();
                if (sSessActive && now - sSessLastAt > 0.15) SFinishSession();
                if (!sSessActive) {
                    sSessActive = YES;
                    sSessSender = sender;
                    sSessDist = 0; sSessFirstDir = 0;
                    sSessHasMove = NO; sSessSettled = NO;
                    // 新会话：轨迹重置到中心
                    sTracePoints = [NSMutableArray array];
                    sTraceX = 0; sTraceY = 0;
                    sTraceHas = YES;
                    [sTracePoints addObject:[NSValue valueWithCGPoint:CGPointMake(0, 0)]];
                }
                sSessLastAt = now;
                double seg = hypot(dx, dy);
                if (seg > 0) {
                    sSessDist += seg;
                    if (!sSessHasMove && sSessDist > 5) {
                        sSessHasMove = YES;
                        sSessFirstDir = atan2(dy, dx) * 180.0 / M_PI;
                    }
                    // 轨迹累积（相对路径）
                    sTraceX += dx; sTraceY += dy;
                    [sTracePoints addObject:[NSValue valueWithCGPoint:CGPointMake(sTraceX, sTraceY)]];
                }
                // 事件流停止 250ms 后结算样本
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    SFinishSession();
                });
            }
        }
    } @catch (NSException *e) {}
    if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

// 结算按键会话 → append 样本（v1.0.4 原版，含停止校验）
static void SFinishSession(void) {
    if (!sSessActive || sSessSettled) return;
    if (PTNowC() - sSessLastAt < 0.25) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SFinishSession();
        });
        return;
    }
    sSessSettled = YES;
    int phase = (sSessDist < 30.0) ? 0 : 1;
    double dir = sSessHasMove ? sSessFirstDir : 0;
    sCurSender = sSessSender;
    sSessActive = NO;
    SAppendSample(phase, dir, sSessDist);
}

static void SCollectHook(void) {
    if (sHooked) return;
    @autoreleasepool {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            sGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
            sGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
            sGetFloat = (IOHIDEventGetFloatValue_t)dlsym(iokit, "IOHIDEventGetFloatValue");
        }
        // v1.0.4 原版：hook _UIUpdateHIDDigitizerInput -addEvent:
        Class addCls = NSClassFromString(@"_UIUpdateHIDDigitizerInput");
        SEL addSel = sel_registerName("addEvent:");
        Method am = addCls ? class_getInstanceMethod(addCls, addSel) : NULL;
        if (am) { gOrigAddEvent = method_getImplementation(am); method_setImplementation(am, (IMP)SImpAddEvent); }

        sHooked = (gOrigAddEvent != NULL && sGetType != NULL && sGetSender != NULL);
    }
}

static NSString *PTDirName(double dir) {
    if (dir >= 45 && dir <= 135) return @"下";
    if (dir > 135 || dir < -135) return @"左";
    if (dir >= -135 && dir < -45) return @"上";
    return @"右";
}

static NSString *PTActionText(NSDictionary *a) {
    NSString *t = a[@"type"];
    if ([t isEqualToString:@"tap"]) return [NSString stringWithFormat:@"点击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"doubleTap"]) return [NSString stringWithFormat:@"双击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%d,%d)→(%d,%d)", (int)[a[@"x1"] doubleValue], (int)[a[@"y1"] doubleValue], (int)[a[@"x2"] doubleValue], (int)[a[@"y2"] doubleValue]];
    if ([t isEqualToString:@"delay"]) return [NSString stringWithFormat:@"延迟 %.0fms", [a[@"ms"] doubleValue]];
    if ([t isEqualToString:@"volumeUp"]) return @"音量+";
    if ([t isEqualToString:@"volumeDown"]) return @"音量-";
    if ([t isEqualToString:@"muteToggle"]) return @"静音切换";
    return t;
}

// 与已有方案去重：同 sender + 同相位 + 方向接近 + 位移接近 → 返回方案名
static NSString *PTDuplicate(NSDictionary *s, NSArray *plans) {
    NSString *snd = s[@"sender"];
    int phase = [s[@"phase"] intValue];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    for (NSDictionary *p in plans) {
        NSDictionary *ft = p[@"feature"];
        if (!ft) continue;
        if (![ft[@"sender"] isEqualToString:snd]) continue;
        if ([ft[@"phase"] intValue] != phase) continue;
        double pd = [ft[@"direction"] doubleValue];
        double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
        if (d > kDirTol) continue;
        if (phase == 1) {
            double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
            if (dist < lo - kDistSlack || dist > hi + kDistSlack) continue;
        }
        return p[@"name"];
    }
    return nil;
}

// 稳定判定：最近 kLearnMin 个同 sender 样本方向一致 + 位移收敛
static BOOL PTStable(NSArray *mem, NSString *sender) {
    NSMutableArray *same = [NSMutableArray array];
    for (NSDictionary *s in mem) if ([s[@"sender"] isEqualToString:sender]) [same addObject:s];
    if (same.count < kLearnMin) return NO;
    NSInteger n = same.count;
    double dir = [same[n-1][@"direction"] doubleValue];
    for (NSInteger i = n - kLearnMin; i < n; i++) {
        double d = [same[i][@"direction"] doubleValue];
        double diff = fabs(fabs(dir - d)); if (diff > 180) diff = 360 - diff;
        if (diff > kDirTol) return NO;
    }
    if ([same[n-1][@"phase"] intValue] == 1) {
        double lo = DBL_MAX, hi = 0;
        for (NSInteger i = n - kLearnMin; i < n; i++) {
            double v = [same[i][@"dist"] doubleValue];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (hi - lo > kConverge) return NO;
    }
    return YES;
}

// ============================================================
// 主设置页
// ============================================================
@implementation RootListController

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"PageTurner";
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"总开关"]];
        PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用 PageTurner"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [master setProperty:@"masterEnabled" forKey:@"key"];
        [master setProperty:@YES forKey:@"default"];
        [master setProperty:@"关闭后全部按键恢复原样（不拦截）" forKey:@"staticText"];
        [specs addObject:master];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"生效范围"]];
        PSSpecifier *apps = [PSSpecifier preferenceSpecifierNamed:@"指定 App 生效"
            target:self set:nil get:nil detail:NSClassFromString(@"PTAppListVC")
            cell:PSLinkCell edit:nil];
        [apps setProperty:@"勾选后，只有这些 App 内会拦截翻页器按键；未勾选的 App 完全放行。改动即时生效。" forKey:@"staticText"];
        [specs addObject:apps];

        PSSpecifier *debounce = [PSSpecifier preferenceSpecifierNamed:@"防抖间隔"
            target:self set:nil get:nil detail:NSClassFromString(@"PTDebounceVC")
            cell:PSLinkCell edit:nil];
        [debounce setProperty:@"连续按键最小间隔，防止按住不放死循环（默认 300ms）" forKey:@"staticText"];
        [specs addObject:debounce];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"记录与映射"]];
        PSSpecifier *plans = [PSSpecifier preferenceSpecifierNamed:@"记录与映射"
            target:self set:nil get:nil detail:NSClassFromString(@"PTPlansVC")
            cell:PSLinkCell edit:nil];
        [plans setProperty:@"新增方案：录制翻页器一个按键的特征（来源+方向+位移），再映射为动作序列。左滑可删除方案。" forKey:@"staticText"];
        [specs addObject:plans];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"调试"]];
        PSSpecifier *dbg = [PSSpecifier preferenceSpecifierNamed:@"调试模式"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [dbg setProperty:@"debugMode" forKey:@"key"];
        [dbg setProperty:@NO forKey:@"default"];
        [dbg setProperty:@"开启后记录详细运行日志（拦截/特征/匹配/执行），排查映射不生效等问题" forKey:@"staticText"];
        [specs addObject:dbg];

        PSSpecifier *log = [PSSpecifier preferenceSpecifierNamed:@"调试日志"
            target:self set:nil get:nil detail:NSClassFromString(@"PTDebugLogVC")
            cell:PSLinkCell edit:nil];
        [log setProperty:@"查看并复制 /var/mobile/Documents/PageTurner.log 的最近记录" forKey:@"staticText"];
        [specs addObject:log];

        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    id val = PTRead()[key];
    if (!val) val = [spec propertyForKey:@"default"];
    return val ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSMutableDictionary *cfg = PTRead();
    cfg[[spec propertyForKey:@"key"]] = value;
    PTWrite(cfg);
    [self reloadSpecifiers];
}

@end

// ============================================================
// App 列表子页（枚举 + 搜索 + 勾选）
// ============================================================
@implementation PTAppListVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"指定 App 生效";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    NSMutableSet *sel = [NSMutableSet setWithArray:PTRead()[@"enabledApps"] ?: @[]];
    self.selected = sel;
    self.allApps = [self enumerateApps];
    self.shown = [NSMutableArray arrayWithArray:self.allApps];

    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 40;

    self.sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width, 44)];
    self.sb.placeholder = @"搜索 App";
    self.sb.delegate = self;
    [self.view addSubview:self.sb];

    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top + 44, self.view.bounds.size.width,
        self.view.bounds.size.height - top - 44) style:UITableViewStylePlain];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
}

- (NSArray *)enumerateApps {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        SEL selWs = NSSelectorFromString(@"defaultWorkspace");
        if (wsCls && [wsCls respondsToSelector:selWs]) {
            id ws = [wsCls performSelector:selWs];
            SEL selApps = NSSelectorFromString(@"allApplications");
            if (ws && [ws respondsToSelector:selApps]) {
                for (id app in [ws performSelector:selApps]) {
                    NSString *bid = nil, *name = nil;
                    SEL s1 = NSSelectorFromString(@"bundleIdentifier");
                    if (app && [app respondsToSelector:s1]) bid = [app performSelector:s1];
                    SEL s2 = NSSelectorFromString(@"localizedName");
                    if (app && [app respondsToSelector:s2]) name = [app performSelector:s2];
                    if (!bid.length || !name.length) continue;
                    UIImage *icon = nil;
                    SEL s3 = NSSelectorFromString(@"icon");
                    if (app && [app respondsToSelector:s3]) icon = [app performSelector:s3];
                    [out addObject:@{ @"name": name, @"bundle": bid, @"icon": icon ?: (id)[NSNull null] }];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return out;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (!searchText.length) {
        self.shown = [NSMutableArray arrayWithArray:self.allApps];
    } else {
        NSMutableArray *f = [NSMutableArray array];
        for (NSDictionary *a in self.allApps) {
            if ([a[@"name"] localizedCaseInsensitiveContainsString:searchText] ||
                [a[@"bundle"] localizedCaseInsensitiveContainsString:searchText]) [f addObject:a];
        }
        self.shown = f;
    }
    [self.tv reloadData];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.shown.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"app";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *a = self.shown[ip.row];
    c.textLabel.text = a[@"name"];
    c.detailTextLabel.text = a[@"bundle"];
    c.imageView.image = [a[@"icon"] isKindOfClass:[UIImage class]] ? a[@"icon"] : nil;
    c.accessoryType = [self.selected containsObject:a[@"bundle"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *bid = self.shown[ip.row][@"bundle"];
    if ([self.selected containsObject:bid]) [self.selected removeObject:bid];
    else [self.selected addObject:bid];
    NSMutableDictionary *cfg = PTRead();
    cfg[@"enabledApps"] = [[self.selected allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    PTWrite(cfg);
    [tv reloadData];
}
@end

// ============================================================
// 防抖子页（滑块）
// ============================================================
@implementation PTDebounceVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"防抖间隔";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

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
    double cur = [PTRead()[@"debounceMs"] doubleValue];
    self.slider.value = (cur > 0) ? cur : 300;
    [self.slider addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.slider];
    [self changed];
}

- (void)changed {
    self.valLabel.text = [NSString stringWithFormat:@"%.0f ms", self.slider.value];
    NSMutableDictionary *cfg = PTRead();
    cfg[@"debounceMs"] = @(self.slider.value);
    PTWrite(cfg);
}
@end

// ============================================================
// 方案列表页（左滑删除 / 新增方案）
// ============================================================
@implementation PTPlansVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"记录与映射";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 40;
    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width,
        self.view.bounds.size.height - top) style:UITableViewStylePlain];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
    [self reload];
}

- (void)reload {
    self.plans = [NSMutableArray arrayWithArray:PTRead()[@"plans"] ?: @[]];
    [self.tv reloadData];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.plans.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"plan";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (ip.row < (NSInteger)self.plans.count) {
        NSDictionary *p = self.plans[ip.row];
        c.textLabel.text = p[@"name"] ?: @"（未命名）";
        NSDictionary *ft = p[@"feature"];
        NSArray *acts = p[@"actions"] ?: @[];
        if (ft) {
            NSString *d = PTDirName([ft[@"direction"] doubleValue]);
            NSString *ph = [ft[@"phase"] intValue] == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", d];
            c.detailTextLabel.text = [NSString stringWithFormat:@"来源%@ ｜ 特征：%@ ｜ 动作 %lu 条", ft[@"sender"], ph, (unsigned long)acts.count];
        } else {
            c.detailTextLabel.text = [NSString stringWithFormat:@"未录制 ｜ 动作 %lu 条", (unsigned long)acts.count];
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"新增方案";
        c.detailTextLabel.text = @"录制一个按键特征，映射为动作序列";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row < (NSInteger)self.plans.count) {
        PTPlanVC *vc = [PTPlanVC new];
        vc.planName = self.plans[ip.row][@"name"];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        NSString *name = [NSString stringWithFormat:@"新方案%lu", (unsigned long)(plans.count + 1)];
        [plans addObject:@{ @"name": name, @"actions": @[] }];
        cfg[@"plans"] = plans;
        PTWrite(cfg);
        PTPlanVC *vc = [PTPlanVC new];
        vc.planName = name;
        [self.navigationController pushViewController:vc animated:YES];
        [self reload];
    }
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.plans.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        NSDictionary *p = self.plans[ip.row];
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray array];
        for (NSDictionary *x in cfg[@"plans"] ?: @[]) {
            if (![x[@"name"] isEqualToString:p[@"name"]]) [plans addObject:x];
        }
        cfg[@"plans"] = plans;
        PTWrite(cfg);
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
@end

// ============================================================
// 方案页（名称 / 记录状态 / 映射区）
// ============================================================
@implementation PTPlanVC

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从动作设置页/学习页返回时自动刷新（新映射、新特征立即显示）
    if (self.nameField) [self reload];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self reload];
}

- (void)reload {
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTRead()[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) { plan = p; break; }
    }
    if (!plan) { [self.navigationController popViewControllerAnimated:YES]; return; }
    self.actions = [NSMutableArray arrayWithArray:plan[@"actions"] ?: @[]];

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width;

    if (!self.nameField) {
        self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(16, top, w - 32, 36)];
        self.nameField.borderStyle = UITextBorderStyleRoundedRect;
        self.nameField.font = [UIFont systemFontOfSize:16];
        self.nameField.placeholder = @"方案名称（如：左键）";
        [self.nameField addTarget:self action:@selector(nameChanged) forControlEvents:UIControlEventEditingChanged];
        [self.view addSubview:self.nameField];

        // 记录按钮：大按钮样式（蓝底白字），与下方「新增映射」视觉统一、紧凑
        self.recStatus = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 44, w - 32, 44)];
        self.recStatus.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.recStatus.textColor = [UIColor whiteColor];
        self.recStatus.backgroundColor = [UIColor systemBlueColor];
        self.recStatus.textAlignment = NSTextAlignmentCenter;
        self.recStatus.layer.cornerRadius = 10;
        self.recStatus.clipsToBounds = YES;
        self.recStatus.userInteractionEnabled = YES;
        [self.recStatus addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recordTapped)]];
        [self.view addSubview:self.recStatus];

        self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top + 96, w, self.view.bounds.size.height - top - 96)
            style:UITableViewStylePlain];
        self.tv.dataSource = self;
        self.tv.delegate = self;
        [self.view addSubview:self.tv];

        UILabel *hv = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 32, 34)];
        hv.text = @"映射区：按一次该键 → 从上到下依次执行全部动作";
        hv.font = [UIFont systemFontOfSize:12];
        hv.textColor = [UIColor secondaryLabelColor];
        self.tv.tableHeaderView = hv;
    }
    self.nameField.text = self.planName;
    if (plan[@"feature"]) {
        NSDictionary *ft = plan[@"feature"];
        NSString *d = PTDirName([ft[@"direction"] doubleValue]);
        NSString *ph = [ft[@"phase"] intValue] == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", d];
        self.recStatus.text = [NSString stringWithFormat:@"✅ 已录制：%@（%d次）· 点我清空重录",
            ph, [ft[@"recordCount"] intValue]];
        self.recStatus.backgroundColor = [UIColor systemGreenColor];
    } else {
        self.recStatus.text = @"＋ 新增记录（按翻页器同一键录特征）";
        self.recStatus.backgroundColor = [UIColor systemBlueColor];
    }
    [self.tv reloadData];
}

- (void)nameChanged {
    NSString *newName = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!newName.length || [newName isEqualToString:self.planName]) return;
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"name"] = newName;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    self.planName = newName;
    PTWrite(cfg);
}

- (void)recordTapped {
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTRead()[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) { plan = p; break; }
    }
    if (plan[@"feature"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"重新录制？"
            message:@"将清空已录制的特征，重新进入录制页" preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"清空重录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSMutableDictionary *cfg = PTRead();
            NSMutableArray *plans = [NSMutableArray array];
            for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
                if ([p[@"name"] isEqualToString:self.planName]) {
                    NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
                    [np removeObjectForKey:@"feature"];
                    [plans addObject:np];
                } else [plans addObject:p];
            }
            cfg[@"plans"] = plans;
            PTWrite(cfg);
            PTLearnVC *vc = [PTLearnVC new];
            vc.planName = self.planName;
            [self.navigationController pushViewController:vc animated:YES];
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else {
        PTLearnVC *vc = [PTLearnVC new];
        vc.planName = self.planName;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.actions.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"act";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    if (ip.row < (NSInteger)self.actions.count) {
        c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(ip.row + 1), PTActionText(self.actions[ip.row])];
        c.accessoryType = UITableViewCellAccessoryNone;
    } else {
        c.textLabel.text = @"＋ 新增映射";
        c.textLabel.textColor = [UIColor systemBlueColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.actions.count) [self addActionMenu];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.actions.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        [self.actions removeObjectAtIndex:ip.row];
        [self saveActions];
        [tv reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (void)addActionMenu {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"新增映射"
        message:@"选择要添加的动作" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *items = @[
        @[@"点击", @"tap"], @[@"双击", @"doubleTap"], @[@"滑动", @"swipe"],
        @[@"延迟", @"delay"], @[@"静音", @"muteToggle"], @[@"音量+", @"volumeUp"], @[@"音量-", @"volumeDown"]];
    for (NSArray *it in items) {
        [al addAction:[UIAlertAction actionWithTitle:it[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self configAction:it[1]];
        }]];
    }
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)configAction:(NSString *)type {
    if ([type isEqualToString:@"delay"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"延迟"
            message:@"输入延迟毫秒数（如 500 = 0.5 秒）" preferredStyle:UIAlertControllerStyleAlert];
        [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.keyboardType = UIKeyboardTypeNumberPad; tf.placeholder = @"500"; }];
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            double ms = [al.textFields.firstObject.text doubleValue];
            if (ms > 0) { [self.actions addObject:@{@"type": @"delay", @"ms": @(ms)}]; [self saveActions]; }
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else if ([type isEqualToString:@"volumeUp"] || [type isEqualToString:@"volumeDown"] || [type isEqualToString:@"muteToggle"]) {
        [self.actions addObject:@{@"type": type}];
        [self saveActions];
    } else {
        PTActionVC *vc = [PTActionVC new];
        vc.actionType = type;
        vc.planName = self.planName;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)saveActions {
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"actions"] = self.actions;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self.tv reloadData];
}
@end

// ============================================================
// 学习页（大白屏录特征）
// ============================================================
@implementation PTLearnVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"录制特征";
    self.view.backgroundColor = [UIColor whiteColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    self.finished = NO;
    self.mem = [NSMutableArray array];

    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.22, w - 48, 60)];
    self.status.text = @"请一直重复按同一个键\n直到提示特征已稳定";
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [self.view addSubview:self.status];

    self.countLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4, w - 48, 30)];
    self.countLabel.text = @"已录：0 次";
    self.countLabel.textAlignment = NSTextAlignmentCenter;
    self.countLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.countLabel];

    self.dirLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 34, w - 48, 30)];
    self.dirLabel.text = @"方向：—";
    self.dirLabel.textAlignment = NSTextAlignmentCenter;
    self.dirLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.dirLabel];

    self.distLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 68, w - 48, 30)];
    self.distLabel.text = @"位移：—";
    self.distLabel.textAlignment = NSTextAlignmentCenter;
    self.distLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.distLabel];

    PTSetLearningLocal(YES);
    sCollectArmed = YES;   // v1.0.4 原版：进入即 armed（无武装延迟）
    sLastSampleAt = PTNowC();
    SCollectHook();
    // 轨迹 overlay（全屏透明，显示最近一次按键的相对位移路径）
    self.traceView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.traceView.userInteractionEnabled = NO;
    self.traceView.backgroundColor = [UIColor clearColor];
    self.traceView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.traceView];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
    sCollectArmed = NO;
    PTSetLearningLocal(NO);
}

- (void)back {
    [self.navigationController popViewControllerAnimated:YES];
}

// 轮询 plist：读走新样本 → 判定；刷新轨迹 overlay
- (void)poll {
    [self drawTrace];
    NSMutableDictionary *cfg = PTRead();
    NSArray *samples = cfg[@"learningSamples"] ?: @[];
    cfg[@"learningSamples"] = @[];   // 清空已读
    PTWrite(cfg);
    if (!samples.count) {
        // 诊断：一直没收到翻页器事件
        if (!self.finished && self.mem.count == 0 && PTNowC() - sLastSampleAt > 1.5) {
            self.status.text = @"⚠️ 未收到翻页器按键事件\n确认翻页器已连接、保持在前台按它";
            self.status.textColor = [UIColor systemOrangeColor];
        }
        return;
    }
    sLastSampleAt = PTNowC();
    for (NSDictionary *s in samples) [self judge:s];
}

// 画最近一次按键的轨迹（相对位移路径）：起点=屏幕中心绿圈 → 沿线绿点 → 终点红点 + 蓝位移线
- (void)drawTrace {
    for (UIView *v in self.traceView.subviews) [v removeFromSuperview];
    for (CALayer *l in [self.traceView.layer.sublayers copy]) [l removeFromSuperlayer];
    if (!sTraceHas || !sTracePoints.count) return;
    CGFloat w = self.traceView.bounds.size.width, h = self.traceView.bounds.size.height;
    CGPoint c = CGPointMake(w / 2, h / 2);
    CGPoint end = CGPointMake(c.x + sTraceX, c.y + sTraceY);
    // 位移线：中心 → 终点
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:c];
    [path addLineToPoint:end];
    CAShapeLayer *line = [CAShapeLayer layer];
    line.path = path.CGPath;
    line.strokeColor = [UIColor systemBlueColor].CGColor;
    line.lineWidth = 3;
    line.fillColor = [UIColor clearColor].CGColor;
    line.lineCap = kCALineCapRound;
    [self.traceView.layer addSublayer:line];
    // 沿线触摸点（绿小点，相对坐标偏移）
    for (NSValue *v in sTracePoints) {
        CGPoint rel = v.CGPointValue;
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
        dot.center = CGPointMake(c.x + rel.x, c.y + rel.y);
        dot.layer.cornerRadius = 4;
        dot.backgroundColor = [UIColor systemGreenColor];
        [self.traceView addSubview:dot];
    }
    // 起点（绿空心圈，屏幕中心） + 终点（红实心）
    UIView *s0 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    s0.center = c;
    s0.layer.cornerRadius = 9;
    s0.layer.borderWidth = 3;
    s0.layer.borderColor = [UIColor systemGreenColor].CGColor;
    s0.backgroundColor = [UIColor clearColor];
    [self.traceView addSubview:s0];
    UIView *e0 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    e0.center = end;
    e0.layer.cornerRadius = 9;
    e0.backgroundColor = [UIColor systemRedColor];
    [self.traceView addSubview:e0];
    // 位移标注（底部）
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(12, h - 44, w - 24, 30)];
    lb.text = [NSString stringWithFormat:@"位移 Δ(%.0f, %.0f) pt", sTraceX, sTraceY];
    lb.font = [UIFont systemFontOfSize:13];
    lb.textColor = [UIColor secondaryLabelColor];
    lb.textAlignment = NSTextAlignmentCenter;
    [self.traceView addSubview:lb];
}

- (void)judge:(NSDictionary *)s {
    if (self.finished) return;
    NSArray *plans = PTRead()[@"plans"] ?: @[];
    // 去重：与已有方案高度相似 → 拒绝
    NSString *dup = PTDuplicate(s, plans);
    if (dup) {
        self.status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", dup];
        self.status.textColor = [UIColor systemRedColor];
        [self.mem removeAllObjects];
        self.countLabel.text = @"已录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        return;
    }
    self.status.textColor = [UIColor labelColor];
    [self.mem addObject:s];
    NSString *sender = s[@"sender"];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    // 同 sender 计数
    int count = 0;
    for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) count++;
    self.countLabel.text = [NSString stringWithFormat:@"已录：%d 次（来源 %@）", count, sender];
    self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
    if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", dist];
    else self.distLabel.text = @"位移：点击（无滑动）";

    if (PTStable(self.mem, sender)) {
        self.status.text = @"✅ 特征已稳定，可以停止";
        self.status.textColor = [UIColor systemGreenColor];
        [self onStable:sender phase:[s[@"phase"] intValue] dir:dir];
    } else if (count >= kLearnMax) {
        [self onTooMany];
    } else {
        self.status.text = count < kLearnMin ? @"请继续按同一个键…" : @"特征收敛中，请继续…";
    }
}

- (void)onStable:(NSString *)sender phase:(int)phase dir:(double)dir {
    if (self.finished) return;
    self.finished = YES;
    // 计算位移区间（同 sender 样本）
    double lo = DBL_MAX, hi = 0;
    for (NSDictionary *m in self.mem) {
        if (![m[@"sender"] isEqualToString:sender]) continue;
        double v = [m[@"dist"] doubleValue];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"特征已稳定"
        message:[NSString stringWithFormat:@"来源 %@｜方向 %@｜位移 %.0f~%.0f pt\n给这个按键命名：", sender, PTDirName(dir), lo, hi]
        preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"如：左键";
        tf.text = self.planName.length ? self.planName : @"";
    }];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { self.finished = NO; }]];
    [al addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [al.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!name.length) name = @"新按键";
        NSMutableDictionary *ft = [NSMutableDictionary dictionary];
        ft[@"sender"] = sender;
        ft[@"phase"] = @(phase);
        ft[@"direction"] = @(dir);
        ft[@"distMin"] = @(lo);
        ft[@"distMax"] = @(hi);
        ft[@"recordCount"] = @([self countForSender:sender]);
        // 写入方案（同名更新 feature / 否则新增）
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray array];
        BOOL updated = NO;
        for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
            if ([p[@"name"] isEqualToString:name]) {
                NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
                np[@"feature"] = ft;
                [plans addObject:np];
                updated = YES;
            } else [plans addObject:p];
        }
        if (!updated) [plans addObject:@{@"name": name, @"feature": ft, @"actions": @[]}];
        cfg[@"plans"] = plans;
        PTWrite(cfg);
        PTSetLearningLocal(NO);
        // 原地更新栈内的方案页（不 push 新页）：返回一次直接回方案列表，看到的就是改好名的新方案
        NSMutableArray *stack = [NSMutableArray arrayWithArray:self.navigationController.viewControllers];
        [stack removeLastObject];   // 移除学习页
        PTPlanVC *planVC = nil;
        for (UIViewController *vc in stack) {
            if ([vc isKindOfClass:[PTPlanVC class]]) { planVC = (PTPlanVC *)vc; break; }
        }
        if (planVC) {
            planVC.planName = name;
            [planVC reload];
        } else {
            PTPlanVC *vc = [PTPlanVC new];
            vc.planName = name;
            [stack addObject:vc];
        }
        [self.navigationController setViewControllers:stack animated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (int)countForSender:(NSString *)sender {
    int c = 0;
    for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) c++;
    return c;
}

- (void)onTooMany {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"特征波动太大"
        message:@"已录 15 次仍未稳定，建议检查按键或重录" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"继续录" style:UIAlertActionStyleDefault handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"重录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.mem removeAllObjects];
        self.countLabel.text = @"已录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        self.status.textColor = [UIColor labelColor];
        self.status.text = @"请一直重复按同一个键\n直到提示特征已稳定";
        NSMutableDictionary *cfg = PTRead();
        cfg[@"learningSamples"] = @[];
        PTWrite(cfg);
    }]];
    [self presentViewController:al animated:YES completion:nil];
}
@end

// ============================================================
// 动作设置页（绿点坐标）
// ============================================================
@implementation PTActionVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.isSwipe = [self.actionType isEqualToString:@"swipe"];
    self.title = self.isSwipe ? @"滑动设置" : ([self.actionType isEqualToString:@"doubleTap"] ? @"双击设置" : @"点击设置");
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat areaH = h - top - 190;

    self.posLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top + areaH + 8, w - 32, 30)];
    self.posLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    [self.view addSubview:self.posLabel];

    UIView *area = [[UIView alloc] initWithFrame:CGRectMake(0, top, w, areaH)];
    area.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.view addSubview:area];

    // 绿点直接挂全屏 view，可在屏幕任意位置拖动（点击/双击/滑动起点终点）
    self.dot1 = [self makeDotOnView:self.view label:@"1" color:[UIColor systemGreenColor]];
    self.dot1.center = CGPointMake(w * 0.3, h * 0.4);

    if (self.isSwipe) {
        self.dot2 = [self makeDotOnView:self.view label:@"2" color:[UIColor systemOrangeColor]];
        self.dot2.center = CGPointMake(w * 0.7, h * 0.6);
        UILabel *speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top + areaH + 44, 80, 30)];
        speedLabel.text = @"速度";
        speedLabel.font = [UIFont systemFontOfSize:14];
        [self.view addSubview:speedLabel];
        self.speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(100, top + areaH + 44, w - 116, 30)];
        self.speedSlider.minimumValue = 100; self.speedSlider.maximumValue = 600; self.speedSlider.value = 200;
        [self.speedSlider addTarget:self action:@selector(updatePos) forControlEvents:UIControlEventValueChanged];
        [self.view addSubview:self.speedSlider];
    }
    [self updatePos];
}

- (UIView *)makeDotOnView:(UIView *)root label:(NSString *)label color:(UIColor *)color {
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
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [dot addGestureRecognizer:pan];
    [root addSubview:dot];
    return dot;
}

- (void)drag:(UIPanGestureRecognizer *)g {
    UIView *dot = g.view;
    UIView *root = dot.superview;
    CGPoint t = [g translationInView:root];
    dot.center = CGPointMake(dot.center.x + t.x, dot.center.y + t.y);
    CGFloat w = root.bounds.size.width, h = root.bounds.size.height;
    dot.center = CGPointMake(MAX(22, MIN(w - 22, dot.center.x)), MAX(22, MIN(h - 22, dot.center.y)));
    [g setTranslation:CGPointZero inView:root];
    [self updatePos];
}

- (void)updatePos {
    if (self.isSwipe) {
        self.posLabel.text = [NSString stringWithFormat:@"滑动 起点(%d,%d) → 终点(%d,%d)  速度%.0fms",
            (int)self.dot1.center.x, (int)self.dot1.center.y, (int)self.dot2.center.x, (int)self.dot2.center.y,
            self.speedSlider.value];
    } else {
        self.posLabel.text = [NSString stringWithFormat:@"%@(%d, %d)",
            [self.actionType isEqualToString:@"doubleTap"] ? @"双击" : @"点击",
            (int)self.dot1.center.x, (int)self.dot1.center.y];
    }
}

- (void)done {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    if (self.isSwipe) {
        a[@"type"] = @"swipe";
        a[@"x1"] = @(self.dot1.center.x); a[@"y1"] = @(self.dot1.center.y);
        a[@"x2"] = @(self.dot2.center.x); a[@"y2"] = @(self.dot2.center.y);
        a[@"speed"] = @(self.speedSlider.value);
    } else {
        a[@"type"] = self.actionType;
        a[@"x"] = @(self.dot1.center.x); a[@"y"] = @(self.dot1.center.y);
    }
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([p[@"name"] isEqualToString:self.planName]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
            [acts addObject:a];
            np[@"actions"] = acts;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

// ============================================================
// 调试日志页（读 PageTurner.log 尾部 + 复制）
// ============================================================
@implementation PTDebugLogVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"调试日志";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:tv];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制"
        style:UIBarButtonItemStyleDone target:self action:@selector(copyLog)];

    NSString *path = @"/var/mobile/Documents/PageTurner.log";
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (content.length) {
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        NSUInteger n = lines.count;
        NSUInteger from = n > 200 ? n - 200 : 0;
        NSArray *tail = [lines subarrayWithRange:NSMakeRange(from, n - from)];
        tv.text = [tail componentsJoinedByString:@"\n"];
    } else {
        tv.text = @"日志为空。\n\n开启首页「调试模式」后重开 App，翻页器相关拦截/特征/匹配/执行日志会写入此文件。";
    }
}

- (void)copyLog {
    UITextView *tv = [self.view.subviews firstObject];
    if (![tv isKindOfClass:[UITextView class]]) return;
    UIPasteboard.generalPasteboard.string = tv.text;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"已复制"
        message:@"日志已复制到剪贴板，可直接粘贴发送" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}
@end
