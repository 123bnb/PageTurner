// ============================================================
// PTDylibCore.m —— PageTurnerDylib 运行端核心（v1.0.20）
//
// 从 deb 版 PageTurner v1.0.43 移植：
//   · Tweak.xm 的运行拦截/匹配/执行/可视化（去掉 Preferences 进程分支、总开关、
//     指定 App 生效、探针、注入标记——dylib 注入即生效）
//   · RootListController.m 的学习/测试采集 + 测试执行（S 系列）
// 与 deb 版的关键差异：
//   · hook 用 method_getImplementation + method_setImplementation（无 ellekit，
//     参考 DirectVolumeTap 纯 clang + ldid 注入方案）
//   · 学习/测试采集与运行拦截合并为同一对 hook（PTDylibAddEvent/PTDylibSendEvent）：
//     学习/测试激活时只采集放行不拦截；否则正常运行拦截
//   · 配置：有 deb 版配置（com.yourname.pageturner.plist 5 候选路径）就复用；
//     没有则自建独立配置 com.yourname.pageturnerdylib.plist
//   · 日志：统一 PTDylibLog——debugLogEnabled 决定是否记录；是否落盘由 target 用
//     PTSetFileLogEnabled(YES) 显式开启（默认不落盘），内存与文件均按 PTLogMaxLines 循环
// v1.0.20（本次变更，与 deb 版 v1.0.55 同步）：
//   · 【滑动(手动)】录制改为覆盖层 UIPanGestureRecognizer 抓真实轨迹（照搬 DirectVolumeTap），
//     不再穿透到 App、不再用 sendEvent 全局采集；半透明黑 0.4 背景仍透出 App。
//   · 【滑动(手动)】回放改用 CADisplayLink + 二分时间插值（照搬 DVTFakeSwipe），更顺滑跟手、对齐 VSync。
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/time.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <unistd.h>
#import "ptftouch/PTFakeMetaTouch.h"
#import "PTEngine.h"

// 测试 sink 协议方法（sTestLogSink 为 id 类型，需编译器可见的声明才能调用）
@interface NSObject (PTTestSink)
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

// ============================================================
// 常量
// ============================================================
static NSString *kDylibPrefsName = @"com.yourname.pageturnerdylib.plist";
static NSString *kDylibLogName = @"PageTurner.log";   // 兜底名：target 开了文件日志但未用 PTSetLogPath 注入路径时，写 App 容器 Documents
static const double kPagerWindowSec = 0.4;       // 翻页器活跃窗口（已学 sender 开窗）
static const double kCollectWindowSec = 0.30;    // v1.0.19：学习/测试采集窗口放宽到 0.3s，减少系统繁忙时丢样本、便于"特征已稳定"达成（原 0.05s 过短）
static const double kTapDistThreshold = 30.0;    // 位移 <30pt 判定 tap
static const double kDirTolerance = 15.0;        // 方向容差 ±15°
static const double kDistSlack = 30.0;           // 位移区间匹配裕度
static const double kTapDistSlack = 0.15;        // 点击位移区间容差
static const double kTapDxThresh = 0.05;         // 点击位移方向判定阈值
static const int kLearnMin = 5;                  // 学习下限
static const int kLearnMax = 15;                 // 学习上限
static const double kConverge = 60.0;            // 位移收敛阈值
#define kMaxLearnedSenders 64                    // 已学 sender 上限（必须用宏：C 中 static const int 不是编译期常量，数组会退化为 VLA，theos 的 -Werror 会把它升级为错误）
#define PTLogMaxLines 500                        // v1.0.59：日志统一 500 条循环（内存与文件一致）

// ptftouch/Compat.h 声明了 extern gInjectSender（本库未使用，补实体防止动态查找落空）
uint64_t gInjectSender = 0;

// v1.0.57：下列符号由 dylib target（PTDylibMain/PTDylibUI）提供「真实现」，此处给弱桩，
// 保证 roothide（deb）构建也能链接通过；dylib 构建时其强定义覆盖这些桩。
// 双指菜单 / 录制覆盖层 UI 是 dylib 专属，roothide 用 PreferenceLoader 设置页，不会触发。
__attribute__((weak)) void PTDylibShowMenu(void) {}
__attribute__((weak)) void PTDylibCloseMenu(void) {}
__attribute__((weak)) BOOL PTDylibIsMenuWindow(UIWindow *w) { return NO; }
// roothide 不装双指长按菜单（用系统设置页），dylib 注入后开启
static BOOL gGestureMenuEnabled = NO;
void PTSetGestureMenuEnabled(BOOL b) { gGestureMenuEnabled = b; }

// ============================================================
// 日志
//   · 是否记录：配置项 debugLogEnabled（关 → PTDylibLog 直接返回，零 IO）
//   · 是否落盘：target 显式调用 PTSetFileLogEnabled(YES) 才写文件，默认 NO（不建任何日志文件）
//   · 循环上限：内存与文件均 PTLogMaxLines=500 行
// ============================================================
static NSMutableArray *sLogLines = nil;
static NSString *sLogFile = nil;
// v1.0.65：日志文件路径由 target 注入；未注入路径时兜底写 App 容器（文件名 kDylibLogName）
void PTSetLogPath(NSString *p) {
    if (p.length) sLogFile = [p copy];
}
static double sLogCfgMtime = -1;
static BOOL sLogEnabled = YES;
// v1.0.65：文件日志总开关，**默认 NO（不落盘）**，target 必须显式 PTSetFileLogEnabled(YES) 才写文件。
// 默认关的原因：PageTurner-<bid>.log 的唯一读者是 deb 设置页的日志列表，它只枚举 deb 配置里的
// enabledApps（见 Preferences/RootListController.m 的 buildLogItems）；没被勾选的 App 写出来也没有
// 任何代码会读，只会在 jbroot 的 Documents 里堆垃圾。落盘必须由 target 确认「本 App 有读者」后再开。
static BOOL sFileLogEnabled = NO;
void PTSetFileLogEnabled(BOOL b) { sFileLogEnabled = b; }

// v1.0.2：日志文件固定 App 容器 Documents（TrollStore 注入无沙盒外权限，/var/mobile/Documents
// 与 jbroot 变体均不可写，不再探测）
static NSString *PTDylibLogFilePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!dir.length) dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm isWritableFileAtPath:dir]) return [dir stringByAppendingPathComponent:kDylibLogName];
    return nil;
}

static void PTDylibEnsureLogFile(NSString *path) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (dir.length && ![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    } @catch (NSException *e) {}
}

static void PTDylibTrimLogFile(NSString *path) {
    @try {
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!content) return;
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        if (lines.count > PTLogMaxLines) {
            NSArray *keep = [lines subarrayWithRange:NSMakeRange(lines.count - PTLogMaxLines, PTLogMaxLines)];
            [[keep componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {}
}

// 开关改动即时生效（mtime 缓存）
static void PTDylibLogRefreshCfg(void) {
    NSString *p = PTDylibCfgPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (mtime == sLogCfgMtime) return;
    sLogCfgMtime = mtime;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:p];
    sLogEnabled = (cfg[@"debugLogEnabled"] == nil) ? YES : [cfg[@"debugLogEnabled"] boolValue];
}

void PTDylibLog(NSString *fmt, ...) {
    // v1.0.65：先把调试日志开关按 mtime 同步好，再决定是否返回——
    // 修复「首条日志用默认 YES、先于配置生效」，导致【关了调试日志仍建文件】的 bug。
    PTDylibLogRefreshCfg();
    // v1.0.19：关日志即零 IO——直接返回，不写文件。开启时才写。
    if (!sLogEnabled) return;
    if (!sLogLines) sLogLines = [NSMutableArray array];
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec; struct tm tmv; localtime_r(&sec, &tmv);
    char tbuf[64]; strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@", tbuf, (int)(tv.tv_usec / 1000), msg];
    if (sLogLines.count >= PTLogMaxLines) [sLogLines removeObjectsInRange:NSMakeRange(0, PTLogMaxLines / 2)];
    [sLogLines addObject:line];
    // v1.0.65：sFileLogEnabled=NO（默认；roothide 下未勾选生效的 App、以及巨魔 dylib）时不写任何文件，仅留内存日志。
    if (sFileLogEnabled) {
        if (!sLogFile) sLogFile = PTDylibLogFilePath();
        if (sLogFile) {
            static int sFileLines = 0;
            PTDylibEnsureLogFile(sLogFile);
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:sLogFile];
            if (fh) {
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                    sFileLines++;
                } @catch (NSException *e) {}
            }
            if (sFileLines > PTLogMaxLines) { PTDylibTrimLogFile(sLogFile); sFileLines = PTLogMaxLines; }
        }
    }
}

NSArray *PTDylibLogLines(void) {
    return sLogLines ? [sLogLines copy] : @[];
}

// v1.0.19：日志总开关运行时即时生效（菜单开关调用）；关日志后 PTDylibLog 直接返回，零 IO。
void PTDylibLogSetEnabled(BOOL on) {
    sLogEnabled = on;
}

double PTNowC(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// ============================================================
// 配置路径选择
// v1.0.2（用户定稿）：去掉 deb 版 5 候选路径探测 / jbroot 镜像推断 / 双写——
//   TrollStore 注入的 App 无沙盒外权限，那些路径全部访问不到（读重定向/写失败），
//   统一固定为 App 容器内自己的配置文件，读写自洽。
// ============================================================
static NSString *gCfgPath = nil;

// v1.0.59：共享 jbroot 根路径（roothide）——诊断证实所有进程共用同一个 .jbroot-XXX，
// 且「jbroot 的 var/mobile/Documents」是 App 侧与设置页唯一双向可通的目录。
// 探测方式：① 遍历已加载 dylib 镜像找 /.jbroot- ② 失败则扫描 App 安装目录找 .jbroot-*（供纯 dylib 注入的 App）
NSString *PTJbrootRoot(void) {
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
            NSRange after = NSMakeRange(NSMaxRange(r), p.length - NSMaxRange(r));
            NSRange slash = [p rangeOfString:@"/" options:0 range:after];
            NSUInteger end = (slash.location != NSNotFound) ? slash.location : p.length;
            root = [p substringToIndex:end];
            break;
        }
        if (!root.length) {
            @try {
                NSFileManager *fm = NSFileManager.defaultManager;
                NSString *base = @"/private/var/containers/Bundle/Application";
                NSArray *items = [fm contentsOfDirectoryAtPath:base error:nil];
                for (NSString *it in items ?: @[]) {
                    if ([it hasPrefix:@".jbroot-"]) { root = [base stringByAppendingPathComponent:it]; break; }
                }
            } @catch (NSException *e) {}
        }
    });
    return root;
}

static void PTDylibInitConfigPath(void) {
    if (gCfgPath) return;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    if (!dir.length) dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    gCfgPath = [dir stringByAppendingPathComponent:[@"Preferences" stringByAppendingPathComponent:kDylibPrefsName]];
    // 容器 Library/Preferences 目录可能不存在，确保可写
    [[NSFileManager defaultManager] createDirectoryAtPath:[gCfgPath stringByDeletingLastPathComponent]
                             withIntermediateDirectories:YES attributes:nil error:nil];
}

NSString *PTDylibCfgPath(void) {
    PTDylibInitConfigPath();
    return gCfgPath;
}

// v1.0.57：配置路径由各自 target 注入（roothide=/var/mobile/Library/Preferences，dylib=沙盒容器）。
// 若 target 未注入（dylib 默认路径），PTDylibInitConfigPath 已算好沙盒默认值。
void PTSetCfgPath(NSString *p) {
    if (p.length) gCfgPath = [p copy];
}

BOOL PTDylibUsingDebConfig(void) {
    return NO;   // v1.0.2：不再复用 deb 配置（沙盒读不到），恒为独立容器配置
}

// ============================================================
// 配置读写（v1.0.2：只写容器内单一路径，原子写）
// ============================================================
NSMutableDictionary *PTDylibReadCfg(void) {
    NSString *p = PTDylibCfgPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return d ? [NSMutableDictionary dictionaryWithDictionary:d] : [NSMutableDictionary dictionary];
}

void PTDylibWriteCfg(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *p = PTDylibCfgPath();
    NSString *tmp = [p stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:p error:nil];
}

void PTDylibSetLearningLocal(BOOL on) {
    NSMutableDictionary *cfg = PTDylibReadCfg();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTDylibWriteCfg(cfg);
}

// ============================================================
// 运行端配置缓存（mtime；无总开关/无指定 App——dylib 注入即生效）
// ============================================================
static NSDictionary *gConfig = nil;
static double gConfigMtime = 0;
static double gDebounceMs = 300;
static BOOL gDebugDots = NO;
static BOOL gDebugLogEnabled = YES;
static void PTDebugDestroyOverlay(void);    // v1.0.12：可视化覆盖层销毁（前向声明）
static void PTFakeRecSwipeAsync(NSArray *pts, int token, double rate, void (^done)(void));  // v1.0.13：测试区回放前向声明（v1.0.66(#6) 增 rate）
static int gExecToken;   // v1.0.13：前向声明（定义在运行拦截段，测试区 recSwipe 回放需要）
// v1.0.66(#6)：连滑状态机辅助（定义在 PTExecutePlan 之前，此处前向声明供 PTHandlePagerEvent 调用）
static void PTChainStartOrContinue(NSString *plan);
static void PTChainReset(void);
static void PTChainPillUpdate(void);
static NSMutableDictionary *gPlans = nil;      // name -> dict
static BOOL gLearnActive = NO;
static uint64_t gLearnedSenders[kMaxLearnedSenders];
static int gLearnedSenderCount = 0;

// v1.0.66(#6)：连滑（变速+刹停）状态机——同一方案连续命中累计提速，异方案/未命中/超时节拍停
#define kSwipeBurstThreshold 5        // 同一方案连续命中达到此值 → 进入连滑提速
#define kChainStaleSec 1.2            // 超过该间隔的再次命中视为新链（自动刹停旧链）
static BOOL gChainEnabled = YES;      // 连滑总开关（设置项；默认开）
static NSString *gChainPlan = nil;    // 当前连滑链归属方案
static int gChainCount = 0;           // 同方案连续命中计数
static BOOL gChainBurst = NO;         // 是否已进入连滑（提速）
static double gChainRate = 1.0;       // 注入提速倍率（>1 更快）
static CFAbsoluteTime gChainLastHitT = 0; // 上次命中时刻（用于自动刹停）

void PTDylibLoadConfig(BOOL force) {
    NSString *p = PTDylibCfgPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (!force && gConfig && mtime == gConfigMtime) return;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:p];
    gConfig = cfg ? cfg : @{};
    gConfigMtime = mtime;
    double db = [gConfig[@"debounceMs"] doubleValue];
    gDebounceMs = (db > 0) ? db : 300;
    gDebugDots = [gConfig[@"debugDots"] boolValue];
    // v1.0.12：可视化开关关掉 → 销毁绿点覆盖层（覆盖层不碰状态栏，开关只控制显示）
    if (!gDebugDots) PTDebugDestroyOverlay();
    gDebugLogEnabled = (gConfig[@"debugLogEnabled"] == nil) ? YES : [gConfig[@"debugLogEnabled"] boolValue];
    gChainEnabled = (gConfig[@"chainEnabled"] == nil) ? YES : [gConfig[@"chainEnabled"] boolValue];   // v1.0.66(#6)
    gPlans = [NSMutableDictionary dictionary];
    gLearnedSenderCount = 0;
    for (NSDictionary *pl in gConfig[@"plans"] ?: @[]) {
        if (!pl[@"name"]) continue;
        gPlans[pl[@"name"]] = pl;
        NSArray *fts = pl[@"features"] ?: (pl[@"feature"] ? @[pl[@"feature"]] : @[]);
        for (NSDictionary *ft in fts) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if ([sc scanHexLongLong:&s] && gLearnedSenderCount < kMaxLearnedSenders) {
                    gLearnedSenders[gLearnedSenderCount++] = s;
                }
            }
        }
    }
    gLearnActive = [gConfig[@"learning"][@"active"] boolValue];
}

// v1.0.57：暴露当前配置字典，供 roothide target 读取 masterEnabled / enabledApps 计算拦截开关
// 注意：必须定义在 gConfig 声明之后（C 要求先声明后使用）
NSDictionary *PTConfigDict(void) {
    return gConfig ? gConfig : @{};
}

// ============================================================
// IOKit（sender 读取）
// ============================================================
typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
typedef double (*IOHIDEventGetFloatValue_t)(void *, uint32_t);
static IOHIDEventGetType_t pGetType = NULL;
static IOHIDEventGetSenderID_t pGetSender = NULL;
static IOHIDEventGetFloatValue_t pGetFloat = NULL;

// ============================================================
// 会话状态（学习/测试，UI 层读写 → extern）
// ============================================================
BOOL sCollectArmed = NO;
BOOL sTestArmed = NO;
double sLastSampleAt = 0;
UIView *sTestDot = nil;
__weak id sTestLogSink = nil;

static uint64_t sCurSender = 0;
static double sWindowUntil = 0;
static BOOL sSessActive = NO;
static double sSessDist = 0, sSessFirstDir = 0;
static BOOL sSessHasMove = NO;
static CGPoint sSessLast = {0, 0};
static CGPoint sSessStart = {0, 0};
static BOOL sTestInjecting = NO;      // 测试执行注入保护
static double sLastTestExec = 0;      // 测试防抖

// 学习样本写入 plist（learningSamples，学习页轮询读取）
static void SAppendSample(int phase, double dir, double dist, int tapDx) {
    NSMutableDictionary *cfg = PTDylibReadCfg();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sCurSender],
        @"phase": @(phase), @"direction": @(dir), @"dist": @(dist),
        @"tapDx": @(tapDx),
    }];
    cfg[@"learningSamples"] = samples;
    PTDylibWriteCfg(cfg);
    PTDylibLog(@"sample: sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d (总数%lu)",
        sCurSender, phase, dir, dist, tapDx, (unsigned long)samples.count);
    sLastSampleAt = PTNowC();
}

// ============================================================
// 工具（UI 层复用）
// ============================================================
NSArray *PTFeaturesOfPlan(NSDictionary *p) {
    if (p[@"features"]) return p[@"features"];
    if (p[@"feature"]) return @[p[@"feature"]];
    return @[];
}

NSString *PTDirName(double dir) {
    if (dir >= 45 && dir <= 135) return @"下";
    if (dir > 135 || dir < -135) return @"左";
    if (dir >= -135 && dir < -45) return @"上";
    return @"右";
}

NSString *PTActionText(NSDictionary *a) {
    NSString *t = a[@"type"];
    if ([t isEqualToString:@"tap"]) return [NSString stringWithFormat:@"点击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"doubleTap"]) return [NSString stringWithFormat:@"双击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%d,%d)→(%d,%d)", (int)[a[@"x1"] doubleValue], (int)[a[@"y1"] doubleValue], (int)[a[@"x2"] doubleValue], (int)[a[@"y2"] doubleValue]];
    if ([t isEqualToString:@"recSwipe"]) return [NSString stringWithFormat:@"滑动(手动) %lu点", (unsigned long)[a[@"pts"] count]];   // v1.0.8
    if ([t isEqualToString:@"delay"]) return [NSString stringWithFormat:@"延迟 %.0fms", [a[@"ms"] doubleValue]];
    if ([t isEqualToString:@"volumeUp"] || [t isEqualToString:@"volumeDown"] || [t isEqualToString:@"muteToggle"])
        return [NSString stringWithFormat:@"%@（已移除）", t];   // v1.0.5：音量动作已删除，旧配置显示提示
    return t;
}

NSString *PTDuplicate(NSDictionary *s, NSArray *plans) {
    NSString *snd = s[@"sender"];
    int phase = [s[@"phase"] intValue];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    int tapDx = [s[@"tapDx"] intValue];
    for (NSDictionary *p in plans) {
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (![ft[@"sender"] isEqualToString:snd]) continue;
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > kDirTolerance) continue;
            if (phase == 1) {
                double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - kDistSlack || dist > hi + kDistSlack) continue;
            } else {
                if (ft[@"tapDx"] && tapDx != [ft[@"tapDx"] intValue]) continue;
                if (ft[@"distMin"]) {
                    double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            return p[@"name"];
        }
    }
    return nil;
}

BOOL PTStable(NSArray *mem, NSString *sender) {
    NSMutableArray *same = [NSMutableArray array];
    for (NSDictionary *s in mem) if ([s[@"sender"] isEqualToString:sender]) [same addObject:s];
    if (same.count < kLearnMin) return NO;
    NSInteger n = same.count;
    double dir = [same[n-1][@"direction"] doubleValue];
    for (NSInteger i = n - kLearnMin; i < n; i++) {
        double d = [same[i][@"direction"] doubleValue];
        double diff = fabs(fabs(dir - d)); if (diff > 180) diff = 360 - diff;
        if (diff > kDirTolerance) return NO;
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
// 测试模式（大白屏 + 绿点可视化 + 执行链路验证）
// ============================================================
static NSString *PTTestMatchFeature(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *best = nil; double bestScore = DBL_MAX;
    for (NSDictionary *p in (PTDylibReadCfg()[@"plans"] ?: @[])) {
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;
            }
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > 15.0) continue;
            double lo = 0, hi = 0;
            if (phase == 1) {
                lo = [ft[@"distMin"] doubleValue];
                hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - 30.0 || dist > hi + 30.0) continue;
            } else {
                if (ft[@"tapDx"]) {
                    if (tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (phase == 1 ? fabs(dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; best = p[@"name"]; }
        }
    }
    return best;
}

void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur) {
    if (!sTestDot) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        sTestDot.hidden = NO;
        sTestDot.alpha = 0.9;
        sTestDot.center = from;
        if (animate) {
            [UIView animateWithDuration:dur animations:^{ sTestDot.center = to; }
                completion:^(BOOL f) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        sTestDot.alpha = 0; sTestDot.hidden = YES;
                    });
                }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sTestDot.alpha = 0; sTestDot.hidden = YES;
            });
        }
    });
}

static void PTTestTap(CGPoint p, BOOL doubleTap) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    PTTestShowDot(p, p, NO, 0);
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    usleep(30000);
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    if (doubleTap) {
        usleep(120000);
        PTTestShowDot(p, p, NO, 0);
        NSInteger pid2 = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
        usleep(30000);
        [PTFakeMetaTouch fakeTouchId:pid2 AtPoint:p withTouchPhase:UITouchPhaseEnded];
    }
}

// v1.0.5（与 deb v1.0.48 同步）：音量动作类型（音量+/音量-/静音切换）整体删除——
// 第三方 App 进程无激活音频会话时，系统音量读取接口（AVSystemController get /
// AVAudioSession.outputVolume / MPVolumeView slider 同步读）全部返回假值（四版实测），
// 写也只能靠异步 slider 兜底 → 止损删除。旧配置兼容：已保存映射里的音量动作执行时
// 被 PTRunAction/PTTestRunAction 默认分支跳过（不崩溃）。

// 执行单条动作 → 完成后 next()
static void PTTestRunAction(NSDictionary *a, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double speed = [a[@"speed"] doubleValue] ?: 1000;
        double distT = hypot(to.x - from.x, to.y - from.y);
        double durMs = (distT / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        PTTestShowDot(from, to, YES, durMs / 1000.0);
        double durSec = MAX(durMs / 1000.0, 0.001);
        __block NSInteger pid = -1;
        __block void (^stillAt)(CGPoint, int);
        stillAt = ^(CGPoint pos, int ms) {
            __block int n = MAX(ms, 0) / 16;
            __block void (^still)(void);
            still = ^(void) {
                if (n <= 0) {
                    [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseEnded];
                    if (next) next();
                    return;
                }
                n--;
                [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
            };
            still();
        };
        __block CFAbsoluteTime t0;
        __block void (^step)(void);
        step = ^(void) {
            double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
            if (t >= 1.0) {
                if (noInertia) {
                    stillAt(to, MAX(liftMs, 300));
                } else {
                    if (liftMs > 0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                            if (next) next();
                        });
                    } else {
                        [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                        if (next) next();
                    }
                }
                return;
            }
            CGPoint pp = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pp withTouchPhase:UITouchPhaseMoved];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                t0 = CFAbsoluteTimeGetCurrent();
                step();
            });
        });
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.13：测试区支持滑动(手动)回放——此前缺分支被 else 跳过，注入轨迹看不到
        // v1.0.20：补上测试页轨迹可视化——绿点沿录制起点→终点移动，时长对齐录制耗时，
        // 否则测试本方案里滑动(手动)虽正常注入、却看不到轨迹（与「滑动」类型表现一致）。
        NSArray *pts = a[@"pts"];
        if (pts.count) {
            CGPoint from = CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]);
            CGPoint to = CGPointMake([pts[pts.count - 1][@"x"] doubleValue], [pts[pts.count - 1][@"y"] doubleValue]);
            double t0 = [pts[0][@"t"] doubleValue];
            double t1 = [pts[pts.count - 1][@"t"] doubleValue];
            PTTestShowDot(from, to, YES, MAX(t1 - t0, 50) / 1000.0);
        }
        PTFakeRecSwipeAsync(pts, gExecToken, gChainRate, next);   // v1.0.66(#6)：测试页同样支持连滑提速
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// 顺序执行方案动作序列（测试防抖 300ms；执行中同样忽略）
static void PTTestExecPlan(NSString *name) {
    double now = PTNowC();
    PTChainReset();   // v1.0.66(#6)：测试执行前复位连滑链，避免继承真实翻页残留的提速倍率
    if (sTestInjecting || now - sLastTestExec < 0.3) { PTDylibLog(@"[测试] 防抖：忽略 %@", name); return; }
    sLastTestExec = now;
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTDylibReadCfg()[@"plans"] ?: @[]) if ([p[@"name"] isEqualToString:name]) { plan = p; break; }
    if (!plan) return;
    NSArray *actions = plan[@"actions"] ?: @[];
    if (!actions.count) { PTDylibLog(@"[测试] %@ 无动作，跳过", name); return; }
    PTDylibLog(@"[测试] 命中「%@」，执行 %lu 条动作", name, (unsigned long)actions.count);
    sTestInjecting = YES;
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (idx >= (int)actions.count) { sTestInjecting = NO; PTDylibLog(@"[测试] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTTestRunAction(a, runNext);
    };
    runNext();
}

// 测试模式：Ended 结算 → 匹配 → 执行
void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *plan = PTTestMatchFeature(phase, dir, dist, sender, tapDx);
    if (plan) {
        PTDylibLog(@"[测试] 特征匹配 → 方案「%@」", plan);
        PTTestExecPlan(plan);
        NSDictionary *pp = nil;
        for (NSDictionary *p in PTDylibReadCfg()[@"plans"] ?: @[]) if ([p[@"name"] isEqualToString:plan]) { pp = p; break; }
        if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) {
            [sTestLogSink appendLog:[NSString stringWithFormat:@"✓ 命中「%@」→ 映射 %lu 条动作（sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d）",
                plan, (unsigned long)(pp[@"actions"] ? [pp[@"actions"] count] : 0), sender, phase, dir, dist, tapDx]];
        }
    } else {
        PTDylibLog(@"[测试] 未匹配：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d", sender, phase, dir, dist, tapDx);
        if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) {
            [sTestLogSink appendLog:[NSString stringWithFormat:@"✗ 未命中（放行）：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d",
                sender, phase, dir, dist, tapDx]];
        }
        if ([sTestLogSink respondsToSelector:@selector(drawTrailWithDirection:dist:phase:)]) {
            [sTestLogSink drawTrailWithDirection:dir dist:dist phase:phase];
        }
    }
}

// ============================================================
// 特征结构 + 触摸会话（运行拦截）
// ============================================================
typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
    int tapDx;
} PagerFeature;

static void PTExecutePlan(NSString *name);
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender);

typedef struct {
    BOOL active;
    int nEvents;
    CGPoint start, last;
    double totalDist;
    double firstMoveDir;
    BOOL hasMove;
} PagerSession;
static PagerSession gSession;
static NSMutableArray *gSessTrail = nil;

static uint64_t gCurSender = 0;
static double gPagerWindowUntil = 0;

static BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

static void PTReplayTrailAsync(void);

// 匹配：sender + 相位 + 方向±15° + 位移区间 → 唯一方案
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender) {
    NSString *best = nil;
    double bestScore = DBL_MAX;
    for (NSString *name in gPlans) {
        NSDictionary *p = gPlans[name];
        NSArray *fts = p[@"features"] ?: (p[@"feature"] ? @[p[@"feature"]] : @[]);
        for (NSDictionary *ft in fts) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;
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
            } else {
                if (ft[@"tapDx"]) {
                    if (f.tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (f.dist < lo - kTapDistSlack || f.dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (f.phase == 1 ? fabs(f.dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; best = name; }
        }
    }
    return best;
}

// 返回 YES = 吞（命中：防 App 同时收到翻页器滚动）；NO = 放行
static BOOL PTHandlePagerEvent(UIEvent *event) {
    if (![event respondsToSelector:@selector(allTouches)]) return NO;
    if (!PTIsLearnedSender(gCurSender)) return NO;
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
            gSessTrail = [NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:p]];
            return YES;
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
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            return YES;
        }
        case UITouchPhaseEnded: {
            if (!gSession.active) return NO;
            gSession.active = NO;
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            PagerFeature f;
            f.phase = (gSession.totalDist < kTapDistThreshold) ? 0 : 1;
            f.direction = gSession.hasMove ? gSession.firstMoveDir : 0;
            f.dist = gSession.totalDist;
            {
                double sx = gSession.start.x, ex = p.x;
                double dxv = ex - sx;
                f.tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
            }
            NSString *plan = PTMatchPlan(f, gCurSender);
            if (plan) {
                gSessTrail = nil;
                PTChainStartOrContinue(plan);   // v1.0.66(#6)：连滑记账（同方案提速/异方案刹停重开）
                PTDylibLog(@"[会话] 命中「%@」→ 执行映射（原始滑动已整段吞掉）链:%@ 计数%d 倍率%.2f",
                    plan, gChainBurst ? @"BURST" : @"-", gChainCount, gChainRate);
                PTExecutePlan(plan);
                return YES;
            }
            PTChainReset();   // v1.0.66(#6)：未命中 → 刹停连滑
            PTDylibLog(@"[会话] 未命中：sender=0x%llx phase=%d dir=%.1f dist=%.1f → 重放轨迹放行",
                gCurSender, f.phase, f.direction, f.dist);
            PTReplayTrailAsync();
            return YES;
        }
        case UITouchPhaseCancelled:
            gSession.active = NO;
            gSessTrail = nil;
            return NO;
        default:
            return NO;
    }
}

// ============================================================
// 调试可视化（绿点 + 轨迹；只画 App 实际收到的触摸）
// ============================================================
@interface PTDebugDot : NSObject
@property (nonatomic) CGPoint pos;
@property (nonatomic) BOOL pager;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) NSMutableArray *trail;
@end
@implementation PTDebugDot
- (instancetype)initWithPoint:(CGPoint)p pager:(BOOL)pg parentView:(UIView *)pv {
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
        [pv.layer addSublayer:_trailLayer];
        [pv addSubview:_dotView];
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

static UIView *gDotOverlay = nil;   // v1.0.12：可视化改为 keyWindow 上的覆盖层 view（不建独立窗口）
static NSMutableDictionary *gDotViews = nil;

// v1.0.12：可视化不再用独立 UIWindow——独立窗口存在就会参与系统状态栏样式计算
// （时间/信号电量变白根因）。改为直接叠加在当前 keyWindow 上的透明 view，
// 零窗口参与状态栏判定，状态栏彻底归系统/App 管。keyWindow 变化时由通知迁移。
static void PTDebugEnsureOverlay(void) {
    if (gDotOverlay) return;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    UIView *ov = [[UIView alloc] initWithFrame:kw.bounds];
    ov.userInteractionEnabled = NO;
    ov.backgroundColor = [UIColor clearColor];
    [kw addSubview:ov];
    gDotOverlay = ov;
    gDotViews = [NSMutableDictionary dictionary];
}

// v1.0.7：可视化开关关掉时销毁（不再永驻影响状态栏）
static void PTDebugDestroyOverlay(void) {
    [gDotOverlay removeFromSuperview];
    gDotOverlay = nil;
    gDotViews = nil;
}

// v1.0.12：keyWindow 变化时把覆盖层迁到新窗口（旧覆盖层移除重建）
void PTDebugMigrateOverlay(void) {
    if (!gDotOverlay) return;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    if (gDotOverlay.superview == kw) return;
    PTDebugDestroyOverlay();
    PTDebugEnsureOverlay();
}

static void PTDebugUpdate(void *touchPtr, CGPoint p, UITouchPhase phase, BOOL pager) {
    if (!gDebugDots) return;
    if (![NSThread isMainThread]) return;
    PTDebugEnsureOverlay();
    if (!gDotOverlay) return;
    NSString *key = [NSString stringWithFormat:@"%p", touchPtr];
    PTDebugDot *dot = gDotViews[key];
    if (phase == UITouchPhaseBegan) {
        if (dot) return;
        dot = [[PTDebugDot alloc] initWithPoint:p pager:pager parentView:gDotOverlay];
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
// 动作执行（PTFakeMetaTouch ＋ 延迟；v1.0.5 音量动作已删除）
// ============================================================
static BOOL gIsInjecting = NO;
static BOOL gExecRunning = NO;
static BOOL gInFakeTouch = NO;
static int gExecToken = 0;
static double gLastExec = 0;

// v1.0.8：手动滑动录制（滑动(手动)动作）——v1.0.20 起录制改为覆盖层 UIPanGestureRecognizer 抓取
// （见 PTDylibUI.m 的 PTRecOnPan），不再用 sendEvent 钩子全局采集（旧版穿透到 App 抓真实触摸）。
// 此处仅保留 PTRecStart/PTRecStop 开关 + gRecArmed 守卫（供双指检测等处排除录制态）。
static BOOL gRecArmed = NO;                 // 录制覆盖层打开（v1.0.62 起由 common/PTOverlayPage 经 PTRecStart/PTRecStop 控制）
static void (^gRecDone)(NSArray *) = nil;    // 录制完成回调（UI 传入；UI 端用同块 gRecDoneUI）

void PTRecStart(NSString *mode, double topY, void (^done)(NSArray *pts)) {
    gRecArmed = YES;
    gRecDone = done;
}

void PTRecStop(void) {
    gRecArmed = NO;
    gRecDone = nil;
}

// 未命中：暂存轨迹重放给 App
static void PTReplayTrailAsync(void) {
    if (!gSessTrail || gSessTrail.count < 2) { gSessTrail = nil; return; }
    NSArray *pts = [gSessTrail copy];
    gSessTrail = nil;
    NSUInteger n = pts.count;
    // v1.0.18：回放「未命中」的原始轨迹时必须保持足够点密度，否则 UIScrollView 在
    // 两点之间收不到 Moved 事件而阶梯跳变（卡顿）。原先 k = MIN(n - 2, 10) 把轨迹
    // 砍到最多 10 个中间点 —— 这里改为全量回放原始采样点，密度跟随录制轨迹。
    CGPoint from = [pts.firstObject CGPointValue];
    CGPoint to = [pts.lastObject CGPointValue];
    NSMutableArray *mids = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 1; i < n - 1; i++) [mids addObject:pts[i]];

    gIsInjecting = YES;
    gInFakeTouch = YES;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    // v1.0.18：按屏幕刷新节奏（~60Hz，16.6ms/点）逐点推进，密度接近真实手指，
    // 不再把整段滑动压缩进 ~120ms。宗旨不变：未命中时仍把原始轨迹还原给 App。
    static const double kReplayStepSec = 1.0 / 60.0;
    __block NSUInteger i = 0;
    __block void (^step)(void);
    step = ^(void) {
        if (i >= mids.count) {
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            gIsInjecting = NO;
            PTDylibLog(@"[重放] 未命中：原始轨迹已重放给 App（%lu 点）", (unsigned long)mids.count);
            return;
        }
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:[mids[i] CGPointValue] withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        i++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReplayStepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReplayStepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

// 点击（同步短阻塞）
static void PTFakeTap(CGPoint p, int pressMs) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    gInFakeTouch = YES;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    usleep(pressMs * 1000);
    gInFakeTouch = YES;
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    gInFakeTouch = NO;
}

// 滑动（异步分步；holdMs 按下停留，liftMs 弹起停留，noInertia 防惯性）
static void PTFakeSwipeAsync(CGPoint from, CGPoint to, double durationMs, int holdMs, int liftMs, BOOL noInertia, int token, void (^done)(void)) {
    double durSec = MAX(durationMs / 1000.0, 0.001);
    __block NSInteger pid = -1;
    __block BOOL began = NO;
    __block BOOL ended = NO;
    __block CGPoint lastP = from;
    __block void (^abortEnd)(void);
    __block void (^doEnd)(void);
    abortEnd = ^{
        if (ended) return;
        ended = YES;
        if (!began) { if (done) done(); return; }
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
    };
    doEnd = ^{
        if (ended) { if (done) done(); return; }
        ended = YES;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
        if (done) done();
    };
    __block void (^stillAt)(CGPoint, int);
    stillAt = ^(CGPoint pos, int ms) {
        __block int n = MAX(ms, 0) / 16;
        __block void (^still)(void);
        still = ^(void) {
            if (token != gExecToken) { abortEnd(); if (done) done(); return; }
            if (n <= 0) { doEnd(); return; }
            n--;
            lastP = pos;
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
            gInFakeTouch = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
        };
        still();
    };
    __block CFAbsoluteTime t0;
    __block void (^step)(void);
    step = ^(void) {
        if (token != gExecToken) { abortEnd(); if (done) done(); return; }
        double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
        if (t >= 1.0) {
            if (noInertia) {
                stillAt(to, MAX(liftMs, 300));
            } else {
                if (liftMs > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                        if (token != gExecToken) { abortEnd(); if (done) done(); return; }
                        doEnd();
                    });
                } else {
                    doEnd();
                }
            }
            return;
        }
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        lastP = p;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
        if (token != gExecToken) { if (done) done(); return; }
        began = YES;
        gInFakeTouch = YES;
        pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
        gInFakeTouch = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            t0 = CFAbsoluteTimeGetCurrent();
            step();
        });
    });
}

// v1.0.55：滑动(手动)回放（CADisplayLink 驱动，照搬 DirectVolumeTap 的 DVTFakeSwipe）
// 每帧对齐 VSync，按真实经过时间插值出坐标注入一次 Moved，1:1 还原真实手指流畅感。
// pts 为 @{x,y,t} 字典（与录制/设置页/测试一致）。
@interface PTRecSwipeTickProxy : NSObject
@property (nonatomic, copy) void (^tick)(void);
- (void)onTick:(CADisplayLink *)link;
@end
@implementation PTRecSwipeTickProxy
- (void)onTick:(CADisplayLink *)link { if (_tick) _tick(); }
@end

// 按时间线性插值取坐标（二分定位区间）
static CGPoint PTRecSwipeInterp(NSArray *xs, NSArray *ys, NSArray *ts, double targetT) {
    NSUInteger m = [ts count];
    if (m == 0) return CGPointZero;
    double t0 = [ts[0] doubleValue], tEnd = [ts[m-1] doubleValue];
    if (targetT <= t0)   return CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]);
    if (targetT >= tEnd) return CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
    NSUInteger lo = 0, hi = m - 1;
    while (hi - lo > 1) {
        NSUInteger mid = (lo + hi) / 2;
        if ([ts[mid] doubleValue] <= targetT) lo = mid; else hi = mid;
    }
    double ta = [ts[lo] doubleValue], tb = [ts[hi] doubleValue];
    double fa = [xs[lo] doubleValue], fb = [xs[hi] doubleValue];
    double ga = [ys[lo] doubleValue], gb = [ys[hi] doubleValue];
    double f = (tb - ta) > 1e-6 ? (targetT - ta) / (tb - ta) : 0.0;
    return CGPointMake(fa + (fb - fa) * f, ga + (gb - ga) * f);
}

static void PTFakeRecSwipeAsync(NSArray *pts, int token, double rate, void (^done)(void)) {
    if (!pts.count) { if (done) done(); return; }
    // 预解析 @{x,y,t} → 分离数组（避免每帧反复解包）
    NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array], *ts = [NSMutableArray array];
    for (NSDictionary *p in pts) {
        [xs addObject:@([p[@"x"] doubleValue])];
        [ys addObject:@([p[@"y"] doubleValue])];
        [ts addObject:@([p[@"t"] doubleValue])];
    }
    NSUInteger m = ts.count;
    if (m < 2) { if (done) done(); return; }
    double t0 = [ts[0] doubleValue];
    double totalMs = [ts[m-1] doubleValue] - t0;
    if (totalMs <= 0) totalMs = 1.0;
    double ratev = (rate > 0) ? rate : 1.0;   // v1.0.66(#6)：提速倍率（连滑时 >1）

    __block NSInteger pid = -1;
    __block BOOL ended = NO;
    __block CFAbsoluteTime startT = CFAbsoluteTimeGetCurrent();
    __block CFAbsoluteTime lastTick = startT;
    __block double playMs = 0;   // v1.0.66(#6)：已播放毫秒（受 rate 与单帧封顶约束，单调推进）
    PTRecSwipeTickProxy *proxy = [PTRecSwipeTickProxy new];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(onTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    proxy.tick = ^{
        if (token != gExecToken) { [link invalidate]; if (done) done(); return; }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        double realMs = (now - startT) * 1000.0;
        double frameMs = (now - lastTick) * 1000.0;   // 距上次 tick 的真实间隔
        lastTick = now;
        // v1.0.66(#6)：看门狗——真实时间远超播放总时长（封顶 6x）仍没走完 → 强制结束，避免卡死
        if (realMs > totalMs * 6.0) frameMs = totalMs;
        double target = playMs + frameMs * ratev;      // 按 rate 推进目标
        if (target > totalMs) target = totalMs;
        // v1.0.66(#6)：单帧封顶——每帧最多推进 100ms，避免高 rate / 卡顿后瞬移
        double cap = playMs + 100.0;
        if (target > cap) target = cap;
        playMs = target;
        CGPoint cur = PTRecSwipeInterp(xs, ys, ts, t0 + playMs);   // 按推进量插值还原
        gInFakeTouch = YES;
        if (pid < 0) pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:cur withTouchPhase:UITouchPhaseBegan];
        else         [PTFakeMetaTouch fakeTouchId:pid AtPoint:cur withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        if (playMs >= totalMs && !ended) {
            CGPoint end = CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:end withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            ended = YES;
            [link invalidate];
            if (done) done();
        }
    };
}

// 执行单条动作 → 完成后 next()
static void PTRunAction(NSDictionary *a, int token, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        PTFakeTap(CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]), pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        int gapMs = [a[@"gapMs"] intValue] ?: 120;
        PTFakeTap(p, pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gapMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p, pressMs);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double speed = ([a[@"speed"] doubleValue] ?: 1000) * gChainRate;   // v1.0.66(#6)：连滑提速（倍率>1 更快）
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        double dist = hypot(to.x - from.x, to.y - from.y);
        double durMs = (dist / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        PTFakeSwipeAsync(from, to, durMs, holdMs, liftMs, noInertia, token, next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.8：滑动(手动)——按录制轨迹回放；v1.0.66(#6)：带连滑提速倍率
        PTFakeRecSwipeAsync(a[@"pts"], token, gChainRate, next);
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// ============================================================
// v1.0.66(#6)：连滑（变速+刹停）状态机辅助 + 顶部 pill
// ============================================================
static UIView *gChainPill = nil;
static void PTChainPillUpdate(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ PTChainPillUpdate(); }); return; }
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    // 链激活即提示：未进连滑显示蓄力进度，进连滑显示倍率
    BOOL show = gChainEnabled && gChainPlan != nil && gChainCount >= 2;
    if (!show) { [gChainPill removeFromSuperview]; gChainPill = nil; return; }
    if (!gChainPill) {
        gChainPill = [[UIView alloc] init];
        gChainPill.layer.cornerRadius = 12;
        gChainPill.userInteractionEnabled = NO;
        UILabel *lb = [[UILabel alloc] init];
        lb.tag = 101; lb.font = [UIFont boldSystemFontOfSize:13];
        lb.textColor = [UIColor whiteColor]; lb.textAlignment = NSTextAlignmentCenter;
        [gChainPill addSubview:lb];
        [kw addSubview:gChainPill];
    }
    gChainPill.backgroundColor = gChainBurst
        ? [UIColor colorWithRed:0.1 green:0.7 blue:0.2 alpha:0.92]
        : [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:0.85];
    UILabel *lb = [gChainPill viewWithTag:101];
    lb.text = gChainBurst
        ? [NSString stringWithFormat:@"⚡连滑 ×%.1f", gChainRate]
        : [NSString stringWithFormat:@"连滑 %d/%d", gChainCount, kSwipeBurstThreshold];
    [lb sizeToFit];
    CGFloat w = lb.bounds.size.width + 20, h = 24;
    CGFloat topInset = (kw.safeAreaInsets.top > 0) ? kw.safeAreaInsets.top : 20;
    gChainPill.frame = CGRectMake((kw.bounds.size.width - w) / 2, topInset + 6, w, h);
    lb.frame = CGRectMake(10, 0, w - 20, h);
}

// 命中方案时记账：同方案累计提速，异方案/过时刹停重开
static void PTChainStartOrContinue(NSString *plan) {
    if (!gChainEnabled || !plan) { PTChainReset(); return; }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gChainPlan && ![gChainPlan isEqualToString:plan]) {
        PTDylibLog(@"[连滑] 异方案「%@」→ 刹停旧链「%@」", plan, gChainPlan);
        PTChainReset();
    } else if (gChainPlan && (now - gChainLastHitT) > kChainStaleSec) {
        PTDylibLog(@"[连滑] 间隔超时 → 刹停旧链「%@」", gChainPlan);
        PTChainReset();
    }
    if (!gChainPlan) { gChainPlan = plan; gChainCount = 0; gChainBurst = NO; gChainRate = 1.0; }
    gChainCount++;
    gChainLastHitT = now;
    if (gChainCount >= kSwipeBurstThreshold) {
        gChainBurst = YES;
        gChainRate = MIN(1.0 + (gChainCount - kSwipeBurstThreshold + 1) * 0.25, 4.0);   // 每多一次 +0.25，封顶 4x
    }
    PTChainPillUpdate();
}

// 刹停：清空连滑链（未命中/异方案/超时/功能关闭）——gExecToken 不变，留给在飞动作自然走完
static void PTChainReset(void) {
    if (gChainPlan) PTDylibLog(@"[连滑] 刹停：链「%@」结束（计数 %d 倍率%.2f）", gChainPlan, gChainCount, gChainRate);
    gChainPlan = nil; gChainCount = 0; gChainBurst = NO; gChainRate = 1.0; gChainLastHitT = 0;
    PTChainPillUpdate();
}

// 执行方案动作序列（防抖：序列执行中或距上次执行 < 防抖间隔都忽略）
static void PTExecutePlan(NSString *name) {
    double now = PTNowC();
    if (gExecRunning || (now - gLastExec < gDebounceMs / 1000.0)) {
        PTDylibLog(@"[执行] 防抖：忽略 %@（执行中=%d，%.0fms 内已执行）", name, gExecRunning, gDebounceMs);
        return;
    }
    gLastExec = now;
    NSDictionary *p = gPlans[name];
    NSArray *actions = p[@"actions"] ?: @[];
    if (!actions.count) { PTDylibLog(@"[执行] %@ 无动作，跳过", name); return; }
    gExecToken++;
    int token = gExecToken;
    gIsInjecting = YES;
    gExecRunning = YES;
    PTDylibLog(@"[执行] 命中 %@，开始动作序列（%lu 条）", name, (unsigned long)actions.count);
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (token != gExecToken) return;
        if (idx >= (int)actions.count) { gIsInjecting = NO; gExecRunning = NO; PTDylibLog(@"[执行] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// ============================================================
// 合并 hook（学习/测试采集 + 运行拦截，同一对方法）
// ============================================================
static IMP gOrigAddEvent = NULL;
static IMP gOrigSendEvent = NULL;
// v1.0.57：拦截开关由 target 注入——roothide 按总开关+指定App 决定；dylib 注入即生效恒 YES
static BOOL gInterceptEnabled = NO;
void PTSetInterceptEnabled(BOOL b) { gInterceptEnabled = b; }
void PTSetOrigAddEvent(IMP o) { gOrigAddEvent = o; }
void PTSetOrigSendEvent(IMP o) { gOrigSendEvent = o; }

void PTDylibAddEvent(id self, SEL _cmd, void *event) {
    // v1.0.57：未启用拦截（roothide：总开关关 / 非指定App）→ 直接放行原始事件
    if (!gInterceptEnabled) {
        if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
        return;
    }
    PTDylibLoadConfig(NO);
    if (event && pGetSender && pGetType) {
        uint32_t type = pGetType(event);
        uint64_t sender = pGetSender(event);
        if (type == 11) {
            gCurSender = sender;      // 运行端
            sCurSender = sender;      // 采集端
            if (sCollectArmed || sTestArmed) sWindowUntil = PTNowC() + kCollectWindowSec;
            if (PTIsLearnedSender(sender)) {
                double dx = pGetFloat ? pGetFloat(event, 0x23) : 0;
                double dy = pGetFloat ? pGetFloat(event, 0x24) : 0;
                PTDylibLog(@"[addEvent] 已学 sender=0x%llx → 会话通道（HID 位移观察 dx=%.2f dy=%.2f）", sender, dx, dy);
                gPagerWindowUntil = PTNowC() + kPagerWindowSec;
            }
        }
    }
    if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

// v1.0.12：sendEvent 层双指长按检测——两指同时按下 0.5s 不动 → 弹菜单。
// sendEvent 是 App 所有触摸必经之路，任何页面/角落都能触发，不被 App 手势仲裁抢。
// 菜单窗口上的触摸不算；手指位移 >25pt 视为移动取消该指。
static NSMutableDictionary *gFingers = nil;
static BOOL gGestureFired = NO;

static void PTDylibGestureTick(UIEvent *event) {
    if (!event) return;
    if (gRecArmed || gInFakeTouch || gIsInjecting) return;   // v1.0.12：录制/注入中不触发双指
    if (!gFingers) gFingers = [NSMutableDictionary dictionary];
    for (UITouch *t in event.allTouches) {
        if (!t.window) continue;
        if (PTDylibIsMenuWindow(t.window)) continue;   // 菜单窗口上的触摸不参与
        NSString *key = [NSString stringWithFormat:@"%p", t];
        if (t.phase == UITouchPhaseBegan) {
            CGPoint p = [t locationInView:t.window];
            gFingers[key] = @{@"t": @(CACurrentMediaTime()), @"x": @(p.x), @"y": @(p.y)};
        } else if (t.phase == UITouchPhaseMoved) {
            NSDictionary *f = gFingers[key];
            if (f) {
                CGPoint p = [t locationInView:t.window];
                CGFloat dx = p.x - [f[@"x"] doubleValue], dy = p.y - [f[@"y"] doubleValue];
                if (dx * dx + dy * dy > 25.0 * 25.0) [gFingers removeObjectForKey:key];
            }
        } else if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) {
            [gFingers removeObjectForKey:key];
        }
    }
    if (gFingers.count >= 2 && !gGestureFired) {
        double now = CACurrentMediaTime();
        BOOL allHold = YES;
        for (NSDictionary *f in gFingers.allValues) {
            if (now - [f[@"t"] doubleValue] < 0.5) { allHold = NO; break; }
        }
        if (allHold) {
            gGestureFired = YES;
            PTDylibShowMenu();
        }
    } else if (gFingers.count == 0) {
        gGestureFired = NO;
    }
}

void PTDylibSendEvent(id self, SEL _cmd, UIEvent *event) {
    // v1.0.57：未启用拦截 → 直接放行原始事件
    if (!gInterceptEnabled) {
        if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    PTDylibLoadConfig(NO);
    // v1.0.12：双指长按检测（最前面，任何触摸都能触发）——仅 dylib 开启（roothide 用设置页）
    if (gGestureMenuEnabled) PTDylibGestureTick(event);
    // v1.0.66(#2)：调试绿点绘制移到「交付 App 之前」（见下方各交付分支），命中被吞的翻页器原始轨迹不再画点，
    // 只显示映射注入轨迹；未命中放行/注入态的触摸在各自交付处补画。
    // v1.0.20：已删除「sendEvent 钩子全局采集录制」——旧版录制覆盖层穿透到 App、靠全局 sendEvent 抓真实触摸。
    // 现改为覆盖层 UIPanGestureRecognizer 直接抓轨迹（见 PTDylibUI.m PTRecOnPan），不再在此处采集。
    // gRecArmed 仍保留（上方双指检测等处用其排除录制态）。
    // 注入触摸/执行中：放行（注入触摸没有 addEvent、sender 残留翻页器，走拦截会把映射触摸 Began 吞掉）
    if (gInFakeTouch || gIsInjecting || sTestInjecting) {
        if (gDebugDots && event) {   // v1.0.66(#2)：映射注入触摸照常画点（pager=NO），保证命中时可见的是映射轨迹而非翻页器原始轨迹
            for (UITouch *t in event.allTouches) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
            }
        }
        if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    // 学习/测试激活：只采集放行，不拦截（即使按的是已学 sender 也不吞）
    if ((sCollectArmed || sTestArmed) && event && PTNowC() < sWindowUntil) {
        NSSet *touches = [event respondsToSelector:@selector(allTouches)] ? event.allTouches : nil;
        UITouch *t = [touches anyObject];
        if (t && pGetSender) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            switch (t.phase) {
                case UITouchPhaseBegan: {
                    sSessActive = YES; sSessDist = 0; sSessHasMove = NO; sSessFirstDir = 0;
                    sSessLast = p;
                    sSessStart = p;
                    break;
                }
                case UITouchPhaseMoved: {
                    if (sSessActive) {
                        double dx = p.x - sSessLast.x, dy = p.y - sSessLast.y;
                        double seg = hypot(dx, dy);
                        if (seg > 0) {
                            sSessDist += seg;
                            if (!sSessHasMove && sSessDist > 5) {
                                sSessHasMove = YES;
                                sSessFirstDir = atan2(dy, dx) * 180.0 / M_PI;
                            }
                        }
                        sSessLast = p;
                    }
                    break;
                }
                case UITouchPhaseEnded: {
                    if (sSessActive) {
                        sSessActive = NO;
                        int phase = (sSessDist < kTapDistThreshold) ? 0 : 1;
                        double dir = sSessHasMove ? sSessFirstDir : 0;
                        int tapDx = 0;
                        {
                            double dxv = p.x - sSessStart.x;
                            tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
                        }
                        if (sTestArmed) PTTestOnEnded(phase, dir, sSessDist, sCurSender, tapDx);
                        else SAppendSample(phase, dir, sSessDist, tapDx);
                    }
                    break;
                }
                case UITouchPhaseCancelled: sSessActive = NO; break;
                default: break;
            }
        }
        if (gDebugDots && event) {   // v1.0.66(#2)：学习/测试期 App 真实收到的触摸照常画点
            for (UITouch *t in event.allTouches) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
            }
        }
        if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    // 运行拦截：已学 sender 会话/窗口内 → 整段吞（命中执行/未命中重放），App 不收到原始触摸
    if (event && (PTNowC() < gPagerWindowUntil || gSession.active)) {
        if (PTHandlePagerEvent(event)) return;
    }
    // 诊断：非注入触摸会话 Began 打一行 sender
    if (event) {
        for (UITouch *t in event.allTouches) {
            if (t.phase == UITouchPhaseBegan) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                PTDylibLog(@"[touch] sender=0x%llx phase=Began pos=(%.1f,%.1f)", gCurSender, p.x, p.y);
            }
        }
    }
    if (gDebugDots && event) {   // v1.0.66(#2)：最终交付 App 的触摸画点（含未命中放行的翻页器原始触摸）
        for (UITouch *t in event.allTouches) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
        }
    }
    if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

// v1.0.57：IOKit 符号解析（sender 读取）——roothide / dylib 共用，各自安装 hook 前调用
void PTDylibInitIOKit(void) {
    static dispatch_once_t on;
    dispatch_once(&on, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            pGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
            pGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
            pGetFloat = (IOHIDEventGetFloatValue_t)dlsym(iokit, "IOHIDEventGetFloatValue");
        }
    });
}

// hook 装配（dylib 用：method_getImplementation + method_setImplementation，无 ellekit）
void PTDylibInstallHooks(void) {
    static dispatch_once_t on;
    dispatch_once(&on, ^{
        @autoreleasepool {
            PTDylibLogRefreshCfg();   // v1.0.19：启动时从配置种子 sLogEnabled（关日志后 PTDylibLog 不再每次读 plist）
            PTDylibInitIOKit();
            gInterceptEnabled = YES;  // dylib 注入即生效（roothide 由 target 按总开关+指定App 决定）
            gGestureMenuEnabled = YES;  // dylib：开启双指长按菜单
            Class addCls = NSClassFromString(@"_UIUpdateHIDDigitizerInput");
            if (!addCls) {
                // v1.0.19：私有类不存在（当前 iOS 版本可能已改名）→ 拦截完全失效，必须醒目提示
                NSLog(@"[PageTurnerDylib][严重] 核心钩子失败：私有类 _UIUpdateHIDDigitizerInput 不存在，翻页器输入拦截将完全失效（当前 iOS 可能已改名该私有类）。");
                PTDylibLog(@"[严重][核心钩子] 私有类 _UIUpdateHIDDigitizerInput 不存在 → 拦截失效");
            }
            SEL addSel = sel_registerName("addEvent:");
            Method am = addCls ? class_getInstanceMethod(addCls, addSel) : NULL;
            if (addCls && !am) {
                NSLog(@"[PageTurnerDylib][严重] 核心钩子失败：_UIUpdateHIDDigitizerInput 缺少 addEvent: 方法，翻页器输入拦截将完全失效。");
                PTDylibLog(@"[严重][核心钩子] _UIUpdateHIDDigitizerInput 缺少 addEvent: 方法 → 拦截失效");
            }
            if (am) { gOrigAddEvent = method_getImplementation(am); method_setImplementation(am, (IMP)PTDylibAddEvent); }

            Class appCls = NSClassFromString(@"UIApplication");
            SEL sendSel = sel_registerName("sendEvent:");
            Method sm = appCls ? class_getInstanceMethod(appCls, sendSel) : NULL;
            if (sm) { gOrigSendEvent = method_getImplementation(sm); method_setImplementation(sm, (IMP)PTDylibSendEvent); }

            BOOL ok = (gOrigAddEvent != NULL && gOrigSendEvent != NULL && pGetType != NULL && pGetSender != NULL);
            PTDylibLog(@"PTDylibInstallHooks: ok=%d addEvent=%d sendEvent=%d getType=%d getSender=%d",
                ok, gOrigAddEvent != NULL, gOrigSendEvent != NULL, pGetType != NULL, pGetSender != NULL);
            if (!ok) {
                // v1.0.19：单点失败兜底——任一核心符号缺失都导致功能静默失效，强制进 syslog 让用户可见
                NSLog(@"[PageTurnerDylib][严重] PTDylibInstallHooks 部分失败 ok=%d（addEvent=%d sendEvent=%d getType=%d getSender=%d）。翻页器拦截可能不工作，请核对当前 iOS 版本与私有 API 兼容性！",
                    ok, gOrigAddEvent != NULL, gOrigSendEvent != NULL, pGetType != NULL, pGetSender != NULL);
                PTDylibLog(@"[严重][核心钩子] 安装部分失败 ok=%d → 拦截可能不工作，核对 iOS 私有 API 兼容性", ok);
            }
        }
    });
}
