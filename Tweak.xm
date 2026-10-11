// ============================================================
// PageTurner v1.0.24 —— 翻页器按键拦截（学习模式 + 映射 + 动作执行）
//
// v1.0.24（注入可视化，照抄 volumekeytapper）：用户要求"打开 App 一眼看出注入成功没"
//   - 提醒条（勾选生效 App）：黑底白字+黄边框、屏幕中上方、2 秒——
//     「PageTurner 注入成功 · 翻页键映射生效中」，打勾的 App 打开就有，
//     有提醒条 = 注入成功
//   - 注入探针（照抄 VKT ShowProbeAlert）：第三方 App 启动 2.5s 弹窗显示
//     本App / 注入✅ / 全局配置(文件可读?) / 总开关 / crashTest / 勾选App数 /
//     本App被勾选 —— 打开番茄小说一眼看出注入和勾选状态
// v1.0.23（上一版核心修复，三路实证锁定终极根因）：
//   根因一【终极】：Filter 空 {} → ellekit 不注入任何进程。
//     TrollCM deb 拆包：Filter={ Bundles=[com.apple.springboard] } → 注入 SB 成功；
//     volumekeytapper Makefile：Filter={ Bundles=[com.apple.UIKit] } + dynamic_lookup
//     → 注入所有 UIKit App 成功（用户实证点击成功）；
//     PageTurner before-package 一直写 printf '{}' → ellekit 跳过 → 番茄小说
//     从未被注入 → 16 个版本全部无效。→ Filter 改为 Bundles=(com.apple.UIKit)。
//   根因二【链接】：v1.0.22 删 dynamic_lookup 后链接失败
//     "found '_MSHookMessageEx' in CydiaSubstrate.tbd, declaration possibly
//     missing 'extern \"C\"'" → extern 缺 extern "C" 被 C++ 修饰。
//     → extern "C" 声明 + 恢复 dynamic_lookup（volumekeytapper 同款，它带这个
//     且注入成功，证明 dynamic_lookup 本就不是问题）。
//   根因三【调试可视化】：按用户要求抄 TrollCM 触摸轨迹——本版加入
//     点触可视化（覆盖 UIWindow 绿点 + 轨迹线 + 翻页器 sender 标记），
//     设置页「调试可视化」开关控制，显示所有触摸（翻页器+手指+映射执行）。
// v1.0.21：注入标记 + 跨沙盒多路径读配置（PTGlobalPlistPath 照抄 volumekeytapper）。
// v1.0.20：运行端统一 sendEvent 会话通道（与测试区同款），命中才吞。
// v1.0.19：设置端方案页测试区（大白屏 + 绿点可视化），实证"匹配+执行+点触"OK。
// v1.0.18：运行端双通道（HID 位移通道 + 会话通道）——0x23/0x24 读不到，废弃。
// v1.0.17：整包回滚到真实 v1.0.4（release tag v1.0.4 = commit 0cd50018）。
//
// 注入范围：Filter = Bundles com.apple.UIKit（照抄 volumekeytapper，所有 UIKit App）
//   - Preferences 进程：旁路（学习收集由设置页 bundle 自 hook）
//   - 其它 App：运行时检查 masterEnabled + enabledApps[bundleID] 才执行映射
//
// 事件链路：
//   addEvent（IOHIDEvent 层）：已学 sender → 开窗口 + 放行（不吞）
//   sendEvent（UIEvent 层）会话：Began/Moved/Ended 结算 UITouch 位移特征
//     → 命中方案：吞事件 + 执行动作序列；未命中：放行 + 日志
//
// 动作：PTFakeMetaTouch（点击/双击/滑动）+ AVSystemController（静音/音量±）
// 防递归：gIsInjecting；防抖：gDebounceMs
// 日志：App 容器 Documents/PageTurner.log + /var/mobile/Documents/PageTurner.log
// 注入标记：/var/mobile/Documents/PageTurner-injected-<bid>.txt（Filza 一眼可查）
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <float.h>
#include <dlfcn.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach-o/dyld.h>
// MSHookMessageEx 由 -lsubstrate（ellekit substrate 兼容库）提供。
// 必须 extern "C"：Tweak.xm 由 clang++ 编译，缺 extern "C" 会被 C++ 名字修饰，
// 链接器找不到 _MSHookMessageEx（v1.0.22 链接失败实证）。
extern "C" void MSHookMessageEx(Class _cls, SEL _name, IMP _imp, IMP *_orig);
#import "ptftouch/PTFakeMetaTouch.h"

// ============================================================
// 常量
// ============================================================
static NSString *kPrefPath = @"/var/mobile/Library/Preferences/com.yourname.pageturner.plist";
static NSString *kPrefsBundleID = @"com.apple.Preferences";
static const double kPagerWindowSec = 0.05;      // HID 事件 → UIEvent 分发窗口
static const double kTapDistThreshold = 30.0;    // 位移 <30pt 判定 tap
static const double kDirTolerance = 15.0;        // 方向容差 ±15°
static const double kDistSlack = 30.0;           // 位移区间匹配裕度

// ============================================================
// 日志
// ============================================================
static const char *gLogPath = NULL;
static void PTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec; struct tm tmv; localtime_r(&sec, &tmv);
    char tbuf[64]; strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@\n", tbuf, (int)(tv.tv_usec/1000), msg];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (gLogPath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:[NSString stringWithUTF8String:gLogPath]];
        if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; } @catch (NSException *e) {} }
    }
    NSFileHandle *fh2 = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Documents/PageTurner.log"];
    if (fh2) { @try { [fh2 seekToEndOfFile]; [fh2 writeData:d]; [fh2 closeFile]; } @catch (NSException *e) {} }
}

static double PTNow(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// ============================================================
// 配置（plist：masterEnabled / enabledApps[] / debounceMs / plans[] / learning / learningSamples）
// ============================================================
static NSString *gBundleID = nil;
static BOOL gIsPreferences = NO;
static NSDictionary *gConfig = nil;
static double gConfigMtime = 0;
static BOOL gMasterEnabled = NO;
static NSMutableSet *gEnabledApps = nil;
static double gDebounceMs = 300;
static BOOL gDebugDots = NO;                // v1.0.23：调试可视化（TrollCM 触摸轨迹）
static BOOL gCrashTest = NO;                // v1.0.24：注入测试（探针字段，照抄 VKT）
static NSMutableDictionary *gPlans = nil;   // name -> dict
static BOOL gLearnActive = NO;              // plist learning.active（Preferences 进程学习开关）
static NSString *gCfgPath = nil;            // 实际读到的 plist 路径（诊断）

static uint64_t gLearnedSenders[32];        // 已学 sender 集合（运行时识别）
static int gLearnedSenderCount = 0;

// 跨沙盒读全局 plist（v1.0.21 加，照抄 volumekeytapper）：
// roothide 下第三方 App 沙盒读 /var/mobile/Library/Preferences 会被重定向到
// App 沙盒，读不到 Preferences 进程写的全局配置 → 从本 dylib 镜像提取
// .jbroot-XXX 根，拼接 jbroot 下的真实偏好路径。
static NSString *PTJbrootRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t on;
    dispatch_once(&on, ^{
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *img = _dyld_get_image_name(i);
            if (!img) continue;
            NSString *p = [NSString stringWithUTF8String:img];
            NSRange r = [p rangeOfString:@"/.jbroot-"];
            if (r.location == NSNotFound) continue;
            NSRange startSeg = r;
            NSRange after = NSMakeRange(NSMaxRange(startSeg), p.length - NSMaxRange(startSeg));
            NSRange slash = [p rangeOfString:@"/" options:0 range:after];
            NSUInteger end = (slash.location != NSNotFound) ? slash.location : p.length;
            root = [p substringToIndex:end];
            break;
        }
    });
    return root;
}

static NSString *PTGlobalPlistPath(void) {
    NSString *name = @"com.yourname.pageturner.plist";
    NSMutableArray *cands = [NSMutableArray array];
    [cands addObject:[@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:name]];
    NSString *jb = PTJbrootRoot();
    if (jb.length) {
        [cands addObject:[jb stringByAppendingPathComponent:[@"var/mobile/Library/Preferences" stringByAppendingPathComponent:name]]];
        [cands addObject:[jb stringByAppendingPathComponent:[@"Library/Preferences" stringByAppendingPathComponent:name]]];
    }
    [cands addObject:[@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:name]];
    [cands addObject:[@"/var/jb/Library/Preferences" stringByAppendingPathComponent:name]];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return cands.firstObject; // 不存在也返回首选路径（供日志）
}

// 原始读文件（不碰 mtime 缓存；多路径取第一个存在的）
static NSMutableDictionary *PTReadFileRaw(void) {
    NSString *p = PTGlobalPlistPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return d ? [NSMutableDictionary dictionaryWithDictionary:d] : [NSMutableDictionary dictionary];
}

// 原子写（tmp + rename；只 Preferences 进程使用，写系统根路径）
static void PTWriteFileRaw(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *tmp = [kPrefPath stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:kPrefPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kPrefPath error:nil];
}

static void PTLoadConfig(BOOL force) {
    NSString *p = PTGlobalPlistPath();
    if (!gCfgPath || ![gCfgPath isEqualToString:p]) {
        gCfgPath = p;
        PTLog(@"[配置] 实际读取路径=%@", p);
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (!force && gConfig && mtime == gConfigMtime) return;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:p];
    gConfig = cfg ? cfg : @{};
    gConfigMtime = mtime;
    gMasterEnabled = [gConfig[@"masterEnabled"] boolValue];
    NSArray *apps = gConfig[@"enabledApps"];
    gEnabledApps = [NSMutableSet setWithArray:apps ? apps : @[]];
    double db = [gConfig[@"debounceMs"] doubleValue];
    gDebounceMs = (db > 0) ? db : 300;
    gDebugDots = [gConfig[@"debugDots"] boolValue];
    gCrashTest = (gConfig[@"crashTest"] == nil) ? NO : [gConfig[@"crashTest"] boolValue];
    gPlans = [NSMutableDictionary dictionary];
    gLearnedSenderCount = 0;
    for (NSDictionary *p in gConfig[@"plans"] ?: @[]) {
        if (!p[@"name"]) continue;
        gPlans[p[@"name"]] = p;
        NSDictionary *ft = p[@"feature"];
        if (ft[@"sender"]) {
            unsigned long long s = 0;
            NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
            if ([sc scanHexLongLong:&s] && gLearnedSenderCount < 32) {
                gLearnedSenders[gLearnedSenderCount++] = s;
            }
        }
    }
    gLearnActive = [gConfig[@"learning"][@"active"] boolValue];
}

// 供设置页读取当前配置快照（Preferences 进程内）
NSDictionary *PTGetConfig(void) { PTLoadConfig(NO); return gConfig; }

// 供设置页写回完整配置
void PTSaveConfig(NSDictionary *cfg) { PTWriteFileRaw(cfg); }

// 学习模式开关（设置页学习页进入/退出时写 learning.active）
void PTSetLearning(BOOL on) {
    NSMutableDictionary *cfg = PTReadFileRaw();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTWriteFileRaw(cfg);
    PTLoadConfig(YES);
}

// ============================================================
// IOKit（sender 读取 + HID 相对位移）
// ============================================================
typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
typedef double (*IOHIDEventGetFloatValue_t)(void *, uint32_t);
static IOHIDEventGetType_t pGetType = NULL;
static IOHIDEventGetSenderID_t pGetSender = NULL;
static IOHIDEventGetFloatValue_t pGetFloat = NULL;

// ============================================================
// HID 通道（v1.0.20 起废弃匹配，仅保留观察日志）
// 0x23/0x24 相对位移在 Preferences 进程实测恒 0（iOS 16 HID 结构），
// v1.0.18 双通道目标 App 实测无效。方向键改走 sendEvent 会话通道
// （与设置 App 测试区同款，v1.0.19 已实证成功）。
// 这里保留读取仅用于日志观察：判断目标 App 里 0x23/0x24 到底有没有值。
// ============================================================
static uint64_t gCurSender = 0;              // 最近 digitizer 事件 sender
static double gPagerWindowUntil = 0;         // 翻页器活跃窗口（已学 sender 开窗）

static BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

// ============================================================
// 特征结构（触摸会话共用）
// ============================================================
typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
} PagerFeature;

static void PTExecutePlan(NSString *name);                    // 前向声明（动作执行段定义）
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender); // 前向声明（匹配段定义）

// ============================================================
// 触摸会话 + 特征
// ============================================================
typedef struct {
    BOOL active;
    int nEvents;
    CGPoint start, last;
    double totalDist;
    double firstMoveDir;
    BOOL hasMove;
} PagerSession;
static PagerSession gSession;

// ============================================================
// 事件处理（学习收集 / 运行匹配+吞）
// ============================================================
static void PTExecutePlan(NSString *name);   // 前向声明（定义在动作执行段）
// 学习模式（Preferences 进程）：append 样本到 plist，不吞
static void PTAppendLearnSample(PagerFeature f, uint64_t sender) {
    NSMutableDictionary *cfg = PTReadFileRaw();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sender],
        @"phase": @(f.phase),
        @"direction": @(f.direction),
        @"dist": @(f.dist),
    }];
    cfg[@"learningSamples"] = samples;
    PTWriteFileRaw(cfg);
    PTLog(@"[学习] 样本 sender=0x%llx phase=%d dir=%.1f dist=%.1f", sender, f.phase, f.direction, f.dist);
}

// 运行模式：匹配（sender + 相位 + 方向±15° + 位移区间）→ 唯一方案
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender) {
    NSString *best = nil;
    double bestScore = DBL_MAX;
    for (NSString *name in gPlans) {
        NSDictionary *ft = gPlans[name][@"feature"];
        if (!ft) continue;
        if (ft[@"sender"]) {
            unsigned long long s = 0;
            NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
            if (![sc scanHexLongLong:&s] || s != sender) continue;   // sender 必须一致
        }
        if ([ft[@"phase"] intValue] != f.phase) continue;
        double pd = [ft[@"direction"] doubleValue];
        double d = fabs(fabs(f.direction - pd)); if (d > 180) d = 360 - d;
        if (d > kDirTolerance) continue;
        double lo = 0, hi = 0;
        if (f.phase == 1) {
            lo = [ft[@"distMin"] doubleValue];
            hi = [ft[@"distMax"] doubleValue];
            if (f.dist < lo - kDistSlack || f.dist > hi + kDistSlack) continue;
        }
        double score = d + (f.phase == 1 ? fabs(f.dist - (lo + hi) / 2.0) / 100.0 : 0);
        if (score < bestScore) { bestScore = score; best = name; }
    }
    return best;
}

// 返回 YES = 吞（命中：防 App 同时收到翻页器滚动）；NO = 放行（未命中：App 保留原行为）
static BOOL PTHandlePagerEvent(UIEvent *event) {
    if (![event respondsToSelector:@selector(allTouches)]) return NO;
    NSSet *touches = event.allTouches;
    if (!touches.count) return NO;
    UITouch *t = [touches anyObject];
    CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
    switch (t.phase) {
        case UITouchPhaseBegan: {
            gSession.active = YES;
            gSession.nEvents = 0;
            gSession.start = p;
            gSession.last = p;
            gSession.totalDist = 0;
            gSession.hasMove = NO;
            gSession.firstMoveDir = 0;
            return gIsPreferences ? NO : NO;   // 不吞 Began（放行，会话由 Ended 决定）
        }
        case UITouchPhaseMoved: {
            if (!gSession.active) return NO;
            gSession.nEvents++;
            double dx = p.x - gSession.last.x, dy = p.y - gSession.last.y;
            double seg = hypot(dx, dy);
            if (seg > 0) {
                gSession.totalDist += seg;
                if (!gSession.hasMove && gSession.totalDist > 5) {
                    gSession.hasMove = YES;
                    gSession.firstMoveDir = atan2(dy, dx) * 180.0 / M_PI;
                }
            }
            gSession.last = p;
            return NO;   // 放行 Moved
        }
        case UITouchPhaseEnded: {
            if (!gSession.active) return NO;
            gSession.active = NO;
            PagerFeature f;
            f.phase = (gSession.totalDist < kTapDistThreshold) ? 0 : 1;
            f.direction = gSession.hasMove ? gSession.firstMoveDir : 0;
            f.dist = gSession.totalDist;
            if (gIsPreferences && gLearnActive) {
                PTAppendLearnSample(f, gCurSender);
                return NO;
            }
            NSString *plan = PTMatchPlan(f, gCurSender);
            if (plan) {
                PTLog(@"[会话] 命中「%@」→ 执行 + 吞事件", plan);
                PTExecutePlan(plan);
                return YES;   // 命中：吞 Ended，App 收不到这次滑动
            }
            PTLog(@"[会话] 未命中：sender=0x%llx phase=%d dir=%.1f dist=%.1f（放行，App 保留原行为）",
                  gCurSender, f.phase, f.direction, f.dist);
            return NO;   // 未命中：放行
        }
        case UITouchPhaseCancelled:
            gSession.active = NO;
            return NO;
        default:
            return NO;
    }
}

// ============================================================
// 调试可视化（v1.0.23 加，按用户要求抄 TrollCM 触摸轨迹思路）
// 覆盖 UIWindow（level=StatusBar+1）+ 绿点 + 轨迹线；
// 翻页器 sender 的圆点带 "P" 标记（黑描边绿点）；
// 显示所有触摸：翻页器、手指、映射执行（gIsInjecting 内的触摸）。
// ============================================================
@interface PTDebugDot : NSObject
@property (nonatomic) CGPoint pos;
@property (nonatomic) BOOL pager;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) NSMutableArray *trail;   // NSValue<CGPoint>
@end
@implementation PTDebugDot
- (instancetype)initWithPoint:(CGPoint)p pager:(BOOL)pg window:(UIWindow *)w {
    self = [super init];
    if (self) {
        _pos = p; _pager = pg;
        _trail = [NSMutableArray array];
        [_trail addObject:[NSValue valueWithCGPoint:p]];
        _dotView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        _dotView.center = p;
        _dotView.layer.cornerRadius = 22;
        _dotView.layer.borderWidth = 2;
        _dotView.layer.borderColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.8].CGColor;
        _dotView.backgroundColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.85];
        if (pg) {
            UILabel *lb = [[UILabel alloc] initWithFrame:_dotView.bounds];
            lb.text = @"P";
            lb.font = [UIFont boldSystemFontOfSize:20];
            lb.textColor = [UIColor blackColor];
            lb.textAlignment = NSTextAlignmentCenter;
            [_dotView addSubview:lb];
        }
        _trailLayer = [CAShapeLayer layer];
        _trailLayer.strokeColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.7].CGColor;
        _trailLayer.fillColor = [UIColor clearColor].CGColor;
        _trailLayer.lineWidth = 4;
        _trailLayer.lineCap = kCALineCapRound;
        [w.layer addSublayer:_trailLayer];
        [w addSubview:_dotView];
    }
    return self;
}
- (void)moveTo:(CGPoint)p {
    _pos = p;
    _dotView.center = p;
    [_trail addObject:[NSValue valueWithCGPoint:p]];
    if (_trail.count > 80) [_trail removeObjectAtIndex:0];
    CGMutablePathRef path = CGPathCreateMutable();
    BOOL first = YES;
    for (NSValue *v in _trail) {
        CGPoint q = v.CGPointValue;
        if (first) { CGPathMoveToPoint(path, NULL, q.x, q.y); first = NO; }
        else CGPathAddLineToPoint(path, NULL, q.x, q.y);
    }
    _trailLayer.path = path;
    CGPathRelease(path);
}
- (void)fadeOut {
    [_dotView.layer removeAllAnimations];
    [UIView animateWithDuration:0.5 animations:^{
        _dotView.alpha = 0.15;
    } completion:^(BOOL f) {
        [_dotView removeFromSuperview];
    }];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.toValue = @(0.0);
    fade.duration = 0.5;
    fade.removedOnCompletion = NO;
    fade.fillMode = kCAFillModeForwards;
    [_trailLayer addAnimation:fade forKey:@"fade"];
}
@end

static UIWindow *gDotWindow = nil;
static NSMutableDictionary *gDotViews = nil;   // key=UITouch 指针字符串

static void PTDebugEnsureWindow(void) {
    if (gDotWindow) return;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelStatusBar + 1;   // 置顶覆盖一切
    w.userInteractionEnabled = NO;                // 纯显示，不拦截触摸
    w.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = vc;
    w.hidden = NO;                                // 非 key 窗口直接显示
    gDotWindow = w;
    gDotViews = [NSMutableDictionary dictionary];
}

static void PTDebugUpdate(void *touchPtr, CGPoint p, UITouchPhase phase, BOOL pager) {
    if (!gDebugDots) return;
    if (![NSThread isMainThread]) return;
    PTDebugEnsureWindow();
    NSString *key = [NSString stringWithFormat:@"%p", touchPtr];
    PTDebugDot *dot = gDotViews[key];
    if (phase == UITouchPhaseBegan) {
        if (dot) return;
        dot = [[PTDebugDot alloc] initWithPoint:p pager:pager window:gDotWindow];
        gDotViews[key] = dot;
    } else if (phase == UITouchPhaseMoved) {
        if (dot) [dot moveTo:p];
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        if (dot) {
            [dot moveTo:p];
            [dot fadeOut];
            [gDotViews removeObjectForKey:key];
        }
    }
}

// ============================================================
// 注入可视化（v1.0.24，照抄 volumekeytapper）：
//   PTShowToast —— 黑底白字+黄边框提醒条（勾选生效 App 启动显示，2 秒）
//   PTShowProbeAlert —— 注入探针弹窗（第三方 App 启动 2.5s 后弹）
// ============================================================
static UIWindow *PTFindKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.connectedScenes) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
                return [ws.windows firstObject];
            }
        }
    }
    return app.keyWindow ?: app.windows.firstObject;
}

static void PTShowToast(NSString *msg) {
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *w = PTFindKeyWindow();
            if (!w) return;
            // 大而醒目的黑底白字圆角条，屏幕中上方，停留 2 秒（照抄 VKT ShowToast）
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(w.bounds.size.width/2 - 160, 200, 320, 64)];
            l.text = msg;
            l.textColor = [UIColor whiteColor];
            l.textAlignment = NSTextAlignmentCenter;
            l.font = [UIFont boldSystemFontOfSize:18];
            l.numberOfLines = 2;
            l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
            l.layer.cornerRadius = 12;
            l.layer.masksToBounds = YES;
            l.layer.borderWidth = 2;
            l.layer.borderColor = [UIColor systemYellowColor].CGColor;
            [w addSubview:l];
            [w bringSubviewToFront:l];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
        });
    } @catch (NSException *e) {}
}

static void PTShowProbeAlert(void) {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        if ([bid hasPrefix:@"com.apple."]) return;   // 只对第三方 App 弹，避免骚扰系统进程
        BOOL selected = [gEnabledApps containsObject:bid];
        BOOL cfgReadable = [NSFileManager.defaultManager fileExistsAtPath:gCfgPath ?: @""];
        NSString *msg = [NSString stringWithFormat:
            @"本App: %@\n注入: ✅ 成功\n全局配置: %@\n总开关enabled: %@\n注入测试crashTest: %@\n勾选App数: %lu  本App被勾选: %@",
            bid,
            cfgReadable ? [NSString stringWithFormat:@"文件可读 %@", gCfgPath] : [NSString stringWithFormat:@"文件不可读 %@", gCfgPath],
            gMasterEnabled ? @"开" : @"关",
            gCrashTest ? @"开" : @"关",
            (unsigned long)gEnabledApps.count,
            selected ? @"是✅" : @"否❌"];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *w = PTFindKeyWindow();
            UIViewController *vc = w.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if (!vc) return;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PageTurner 注入探针"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
        });
    } @catch (NSException *e) {}
}

// ============================================================
// 动作执行（PTFakeMetaTouch + AVSystemController）
// ============================================================
static BOOL gIsInjecting = NO;
static int gExecToken = 0;
static double gLastExec = 0;
static float gMutedVolume = -1;   // 静音前音量（-1=未静音）

static float PTGetVolume(void) {
    @try {
        id c = [NSClassFromString(@"AVSystemController") performSelector:NSSelectorFromString(@"sharedAVSystemController")];
        id v = [c performSelector:NSSelectorFromString(@"getVolumeForCategory:") withObject:@"AVAudioSessionCategoryAmbient"];
        return v ? [v floatValue] : 0.5f;
    } @catch (NSException *e) { return 0.5f; }
}

static void PTSetVolume(float v) {
    @try {
        id c = [NSClassFromString(@"AVSystemController") performSelector:NSSelectorFromString(@"sharedAVSystemController")];
        [c performSelector:NSSelectorFromString(@"setVolumeTo:forCategory:") withObject:@(v) withObject:@"AVAudioSessionCategoryAmbient"];
        [c performSelector:NSSelectorFromString(@"setVolumeTo:") withObject:@(v)];
    } @catch (NSException *e) {}
}

// 点击（同步短阻塞，DVT 验证过的方案）
static void PTFakeTap(CGPoint p) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    usleep(30000);
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
}

// 滑动（异步分步，不阻塞主线程；完成后调 completion）
static void PTFakeSwipeAsync(CGPoint from, CGPoint to, double durationMs, int token, void (^done)(void)) {
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
    int steps = 12;
    double per = durationMs / steps / 1000.0;
    __block int i = 1;
    __block void (^step)(void);
    step = ^(void) {
        if (token != gExecToken) { if (done) done(); return; }
        if (i > steps) {
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
            if (done) done();
            return;
        }
        double t = (double)i / steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseMoved];
        i++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(per * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

// 执行单条动作 → 完成后 next()
static void PTRunAction(NSDictionary *a, int token, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        PTFakeTap(CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTFakeTap(p);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double dur = [a[@"speed"] doubleValue] ?: 200;
        PTFakeSwipeAsync(from, to, dur, token, next);
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"volumeUp"]) {
        PTSetVolume(MIN(1.0, PTGetVolume() + 0.0625));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"volumeDown"]) {
        PTSetVolume(MAX(0.0, PTGetVolume() - 0.0625));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"muteToggle"]) {
        if (gMutedVolume < 0) { gMutedVolume = PTGetVolume(); PTSetVolume(0); }
        else { PTSetVolume(gMutedVolume); gMutedVolume = -1; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        if (next) next();
    }
}

// 执行方案动作序列（顺序全执行；防抖；中断旧序列）
static void PTExecutePlan(NSString *name) {
    double now = PTNow();
    if (now - gLastExec < gDebounceMs / 1000.0) {
        PTLog(@"[执行] 防抖：忽略 %@（%.0fms 内已执行）", name, gDebounceMs);
        return;
    }
    gLastExec = now;
    NSDictionary *p = gPlans[name];
    NSArray *actions = p[@"actions"] ?: @[];
    if (!actions.count) { PTLog(@"[执行] %@ 无动作，跳过", name); return; }
    gExecToken++;
    int token = gExecToken;
    gIsInjecting = YES;
    PTLog(@"[执行] 命中 %@，开始动作序列（%lu 条）", name, (unsigned long)actions.count);
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (token != gExecToken) { gIsInjecting = NO; return; }
        if (idx >= (int)actions.count) { gIsInjecting = NO; PTLog(@"[执行] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// ============================================================
// hook
// ============================================================
static IMP gOrigAddEvent = NULL;
static void PTImpAddEvent(id self, SEL _cmd, void *event) {
    PTLoadConfig(NO);   // 每次事件刷新配置（设置页改动即时生效）
    if (event && pGetSender && pGetType) {
        uint32_t type = pGetType(event);
        uint64_t sender = pGetSender(event);
        if (type == 11) {
            gCurSender = sender;
            if (gIsPreferences && gLearnActive) {
                // 学习（Preferences 进程，设置页 bundle 自 hook 已处理，tweak 在此旁路不 hook）
                gPagerWindowUntil = PTNow() + kPagerWindowSec;
            } else if (PTIsLearnedSender(sender)) {
                // 运行（生效 App）：已学 sender → 开窗口 + 放行原文
                // 方向键/点击键统一走 sendEvent 会话通道（v1.0.20，与测试区同款链路）
                double dx = pGetFloat ? pGetFloat(event, 0x23) : 0;
                double dy = pGetFloat ? pGetFloat(event, 0x24) : 0;
                PTLog(@"[addEvent] 已学 sender=0x%llx → 会话通道（HID 位移观察 dx=%.2f dy=%.2f）", sender, dx, dy);
                gPagerWindowUntil = PTNow() + kPagerWindowSec;
            }
        }
    }
    ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

static IMP gOrigSendEvent = NULL;
static void PTImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    PTLoadConfig(NO);   // 每次事件刷新配置（设置页改动即时生效）
    // 调试可视化（v1.0.23）：所有触摸——翻页器（gCurSender≠0）、手指、映射执行
    if (gDebugDots && event) {
        for (UITouch *t in event.allTouches) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            PTDebugUpdate((__bridge void *)t, p, t.phase, (gCurSender != 0));
        }
    }
    if (gIsInjecting) {
        ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    if (event && PTNow() < gPagerWindowUntil) {
        if (PTHandlePagerEvent(event)) return;
    }
    ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

// ---------- swizzle（v1.0.21 改用 MSHookMessageEx） ----------
// 关键：ellekit/roothide 只注入含 _MSHookMessageEx / _MSHookFunction 符号的 dylib
// （volumekeytapper Tweak.x 注释原文："无任何 %hook 的 dylib 会被 ellekit 拒载第三方 App"）。
// 此前 method_setImplementation 不产生该符号 → 目标 App 根本没被注入。
// MSHookMessageEx 由 -lsubstrate（ellekit substrate 兼容库）提供。
static void PTHook(NSString *clsName, NSString *selName, IMP newImp, IMP *origSlot) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { PTLog(@"[探测] 类不存在 %@ 跳过", clsName); return; }
    SEL sel = sel_registerName(selName.UTF8String);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PTLog(@"[探测] %@ -%@ 不存在，跳过", clsName, selName); return; }
    MSHookMessageEx(cls, sel, newImp, origSlot);
    PTLog(@"[探测] %@ -%@ 已hook ✓（MSHookMessageEx）", clsName, selName);
}

// 注入标记文件（v1.0.21 加，照抄 volumekeytapper WriteInjectMarker）：
// constructor 一被加载就写（无论是否勾选），Filza 看 /var/mobile/Documents/
// PageTurner-injected-<bid>.txt 即知该进程有没有被 dylib 注入
static void PTWriteInjectMarker(NSString *bid) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ 注入标记 进程=%@ bundleID=%@\n",
                          [NSDate date], NSProcessInfo.processInfo.processName, bid];
        for (NSString *p in @[
            [NSString stringWithFormat:@"/var/mobile/Documents/PageTurner-injected-%@.txt", bid],
            @"/var/mobile/Documents/PageTurner-injected.txt",
            [NSString stringWithFormat:@"/tmp/PageTurner-injected-%@.txt", bid]]) {
            FILE *f = fopen(p.UTF8String, "a");
            if (f) { fputs(line.UTF8String, f); fclose(f); }
        }
    } @catch (NSException *e) {}
}

__attribute__((constructor))
static void PTInit() {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID.length) return;
        gBundleID = bundleID;
        gIsPreferences = [bundleID isEqualToString:kPrefsBundleID];
        PTLoadConfig(YES);

        NSString *home = NSHomeDirectory();
        NSString *logPath = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"PageTurner.log"];
        gLogPath = strdup([logPath UTF8String]);

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            pGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
            pGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
            pGetFloat = (IOHIDEventGetFloatValue_t)dlsym(iokit, "IOHIDEventGetFloatValue");
        }
        PTLog(@"==================================================");
        PTLog(@"PageTurner v1.0.24 已注入 %@ (pid=%d) isPrefs=%d", bundleID, getpid(), gIsPreferences);
        PTLog(@"配置路径=%@ 总开关=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu 已学sender=%d",
              gCfgPath, gMasterEnabled, (unsigned long)gEnabledApps.count, gDebounceMs,
              (unsigned long)gPlans.count, gLearnedSenderCount);
        // 注入标记（无条件写）：Filza 看 /var/mobile/Documents/PageTurner-injected-<bid>.txt
        PTWriteInjectMarker(bundleID);
        if (gIsPreferences) {
            // 学习收集由设置页 bundle 内自 hook 负责（roothide 空 Filter 不注入系统 App，
            // tweak 在此进程收不到事件；bundle 必然被 PreferenceLoader 加载）。
            // tweak 不 hook，避免双收集。
            PTLog(@"Preferences 进程旁路：学习收集由设置页 bundle 负责");
        } else if (gMasterEnabled && [gEnabledApps containsObject:bundleID]) {
            // 生效 App：hook 拦截
            PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTImpAddEvent, &gOrigAddEvent);
            PTHook(@"UIApplication", @"sendEvent:", (IMP)PTImpSendEvent, &gOrigSendEvent);
            PTLog(@"生效 App 就绪：学过的 sender 按键将被拦截");
        } else {
            PTLog(@"旁路：未生效 App（bundleID=%@ 不在列表(%lu)或总开关=%d）",
                  bundleID, (unsigned long)gEnabledApps.count, gMasterEnabled);
        }
        // v1.0.24 注入探针（照抄 VKT ShowProbeAlert）：第三方 App 启动 2.5s 弹，
        // 显示 本App/注入✅/全局配置/总开关/crashTest/勾选App数/本App被勾选 ——
        // 打开番茄小说一眼看出注入成功没、有没有勾选
        if (!gIsPreferences && ![bundleID hasPrefix:@"com.apple."]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PTShowProbeAlert(); });
        }
        // v1.0.24 提醒条（勾选生效 App）：黑底白字+黄边框、中上方、2 秒。
        // 有提醒条 = 注入成功（用户要求：打勾了那这个提醒条就有）
        if (!gIsPreferences && gMasterEnabled && [gEnabledApps containsObject:bundleID]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PTShowToast(@"PageTurner 注入成功 · 翻页键映射生效中"); });
        }
        PTLog(@"==================================================");
    }
}
