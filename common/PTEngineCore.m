// ============================================================
// PTEngineCore.m —— PageTurner 引擎核心实现（v1.0.71 从 PTEngine.m 拆出）
//
// 本文件 = 「真正跨注入环境通用的逻辑」：配置读写/jbroot/特征匹配/学习样本/
// 测试回放/连滑状态机/动作执行/日志，外加会话/执行态全局（外壳与设置页 hook 跨文件读写）。
// hook 装配、运行拦截会话、调试可视化、录制、双指菜单在外壳 PTEngine.m。
//
// 组装来源（均逐字迁移，仅标注 [v1.0.71] 的为合并/胶水改动）：
//   · PTEngine.m 的配置/日志/工具/测试/动作/连滑（母版）
//   · RootListController.m 的测试可视化富版（v1.0.66(#3) 方向线+P 标记+尾巴，
//     比引擎侧更新，取设置页版；引擎侧 PTFakeRecSwipeAsync 补 trail 钩子）
//   · 修复设置页旧漂移：采集窗口 0.05→kCollectWindowSec(0.30)、动作文案以引擎为准
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
#import "PTEngineCore.h"

// 测试 sink 协议方法（sTestLogSink 为 id 类型，需编译器可见的声明才能调用）
@interface NSObject (PTTestSink)
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

// ============================================================
// 常量（数值型统一宏在 PTEngineCore.h；此处只留本文件私有字符串）
// ============================================================
static NSString *kDylibPrefsName = @"com.yourname.pageturnerdylib.plist";
static NSString *kDylibLogName = @"PageTurner.log";   // 兜底名：target 开了文件日志但未用 PTSetLogPath 注入路径时，写 App 容器 Documents

// ptftouch/Compat.h 声明了 extern gInjectSender（本库未使用，补实体防止动态查找落空）
uint64_t gInjectSender = 0;

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

// v1.0.71：清空内存日志（设置页关调试开关时与文件清理配套调）
void PTDylibLogClearLines(void) {
    [sLogLines removeAllObjects];
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

// ============================================================
// 配置读写（v1.0.2：只写容器内单一路径，原子写）
// ============================================================
NSMutableDictionary *PTDylibReadCfg(void) {
    NSString *p = PTDylibCfgPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return d ? [NSMutableDictionary dictionaryWithDictionary:d] : [NSMutableDictionary dictionary];
}

// v1.0.71：原子写指定路径（从 PTDylibWriteCfg 抽出）——设置页双写（jbroot 真实路径 +
// 普通路径兜底）直接用它，不必各写一份序列化逻辑。
void PTWriteCfgTo(NSString *path, NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:path error:nil];
}

void PTDylibWriteCfg(NSDictionary *cfg) {
    PTWriteCfgTo(PTDylibCfgPath(), cfg);
}

// v1.0.71：配置写入器注入——设置进程（Preferences）需要双写（jbroot 真实偏好路径 App 侧读得到
// + 普通路径兜底自己读），注入进程只写自己的路径。Core 内部所有配置写入
// （学习样本 / 学习开关）统一走 PTWriteCfg，行为随进程角色自动正确。
static void (*sCfgWriter)(NSDictionary *cfg) = NULL;
void PTSetCfgWriter(void (*writer)(NSDictionary *cfg)) { sCfgWriter = writer; }
static void PTWriteCfg(NSDictionary *cfg) {
    if (sCfgWriter) sCfgWriter(cfg);
    else PTDylibWriteCfg(cfg);
}

void PTDylibSetLearningLocal(BOOL on) {
    NSMutableDictionary *cfg = PTDylibReadCfg();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTWriteCfg(cfg);
}

// ============================================================
// 运行端配置缓存（mtime；无总开关/无指定 App——dylib 注入即生效）
// ============================================================
static NSDictionary *gConfig = nil;
static double gConfigMtime = 0;
static double gDebounceMs = 300;
BOOL gDebugDots = NO;   // v1.0.71：改非静态（外壳调试可视化读取；原 static 仅引擎内部用）
// v1.0.67：连滑辅助（1:1 移植自 DVT 1.0.22）——前向声明，供 PTDylibLoadConfig / PTTestExecPlan / PTChainHandleHit 调用
static void PTChainReset(void);
static void PTChainPill(NSString *msg);
static void PTChainStopAll(void);
static void PTExecutePlan(NSString *name);
static void PTExecutePlanRun(NSString *name);
// v1.0.71：测试区 PTTestRunAction 的 recSwipe 分支调用（定义在后方「动作执行」区）
static void PTFakeRecSwipeAsync(NSArray *pts, int token, double rate, void (^done)(void));
static NSMutableDictionary *gPlans = nil;      // name -> dict
static BOOL gLearnActive = NO;
static uint64_t gLearnedSenders[kMaxLearnedSenders];
static int gLearnedSenderCount = 0;

// v1.0.67：连滑 1:1 移植自 DVT 1.0.22（DirectVolumeTap）——"方向"概念映射为"方案"：
//   同方案 = 同方向（续滑/升档），异方案 = 反方向（刹停）。状态机/刹停/变速/自动续滑/pill 与 DVT 完全一致。
static BOOL gChainEnabled = YES;      // 连滑总开关（设置项 chainEnabled；默认开）
static NSInteger gSwipeBurstCount  = 0;    // 当前窗口内同方案累计命中（含起滑那一次）
static BOOL      gSwipeBurstActive = NO;   // 是否连滑中
static NSString *gSwipeBurstPlan   = nil;  // 连滑归属方案（起滑时锁定，连滑只能是该方案）
static NSInteger gSwipeBurstRate   = 1;    // 连滑倍速档位 1/2/3（DVT v1.0.22：档位不记忆，进/退/刹停复位 1）
static BOOL      gSwipeStopRequested = NO; // 刹停请求（异方案命中置位，中断在飞回放）
// v1.0.67：执行态全局变量（供运行端/测试页/外壳 hook 共用，避免"使用先于定义"；连滑续播/刹停靠这些状态）
// v1.0.71：改非静态——外壳 PTHandlePagerEvent/PTDylibGestureTick/PTReplayTrailAsync 与
//          设置页 SImpSendEvent 跨文件读写（同进程内只有一个引擎镜像，见 PTEngineCore.h 注释）。
BOOL gIsInjecting = NO;
BOOL gExecRunning = NO;
BOOL gInFakeTouch = NO;
int gExecToken = 0;
static double gLastExec = 0;

void PTDylibLoadConfig(BOOL force) {
    // v1.0.67：连滑生命周期——进程内注册一次退后台通知，断连滑+中断在飞回放（DVT v1.0.22 对应行为）
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                     usingBlock:^(NSNotification *n){ PTChainStopAll(); }];
    });
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
    // v1.0.12：可视化开关关掉 → 销毁绿点覆盖层（覆盖层不碰状态栏，开关只控制显示）。
    // v1.0.71：PTDebugDestroyOverlay 是外壳实现的弱引用——Preferences 只链 Core 时为 NULL，判空跳过。
    if (!gDebugDots && PTDebugDestroyOverlay) PTDebugDestroyOverlay();
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
// IOKit（sender 读取）——roothide / dylib / 设置页 bundle 三方共用
// v1.0.71：从外壳移入 Core（设置页的采集 hook 也要读 sender，此前自己 dlsym 一份）
// ============================================================
IOHIDEventGetType_t pGetType = NULL;
IOHIDEventGetSenderID_t pGetSender = NULL;
IOHIDEventGetFloatValue_t pGetFloat = NULL;

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

// ============================================================
// 会话状态（学习/测试，UI 层读写 → extern；外壳 hook 与设置页 hook 跨文件共用）
// v1.0.71：改非静态——设置页 SImpSendEvent 直接驱动同一组状态（每个 Mach-O 镜像各持一份，
//          注入 dylib 与设置 bundle 互不干扰，只通过配置文件通信）。
// ============================================================
BOOL sCollectArmed = NO;
BOOL sTestArmed = NO;
double sLastSampleAt = 0;
UIView *sTestDot = nil;
__weak id sTestLogSink = nil;
uint64_t sCurSender = 0;
double sWindowUntil = 0;
BOOL sSessActive = NO;
double sSessDist = 0, sSessFirstDir = 0;
BOOL sSessHasMove = NO;
CGPoint sSessLast = {0, 0};
CGPoint sSessStart = {0, 0};
static double sLastTestExec = 0;      // 测试防抖

// 学习样本写入 plist（learningSamples，学习页轮询读取）。
// v1.0.71：原 SAppendSample（设置页/引擎各一份）合并为公开 PTSampleAppend；
//          写入走 PTWriteCfg（设置进程经 PTSetCfgWriter 注入双写）。
void PTSampleAppend(int phase, double dir, double dist, int tapDx) {
    NSMutableDictionary *cfg = PTDylibReadCfg();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sCurSender],
        @"phase": @(phase), @"direction": @(dir), @"dist": @(dist),
        @"tapDx": @(tapDx),
    }];
    cfg[@"learningSamples"] = samples;
    PTWriteCfg(cfg);
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
            if (d > kDirTolerance) continue;   // v1.0.71：kDirTol → kDirTolerance（统一常量名）
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
        if (diff > kDirTolerance) return NO;   // v1.0.71：kDirTol → kDirTolerance（统一常量名）
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

// 匹配：sender + 相位 + 方向±15° + 位移区间 → 唯一方案（运行端；测试端用 PTTestMatchFeature）
NSString *PTMatchPlan(PagerFeature f, uint64_t sender) {
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

BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

// ============================================================
// 测试可视化（v1.0.66(#3) 富版：起点绿点 + 方向线 + 终点 P 标记 + 滑动(手动)连续尾巴）
// v1.0.71：从 RootListController.m 迁入 Core（该版比引擎侧旧版更新，取设置页版；
//          原引擎 PTTestShowDot 只有移动绿点，已删除）。dylib 测试页随之获得同款可视化。
// ============================================================
static CAShapeLayer *sTestLine = nil;   // 方向线
static UIView *sTestP = nil;            // 终点 P 标记
static NSMutableArray *sTestTrail = nil;   // 滑动(手动)回放尾巴轨迹点（起点→…→当前）
static int sTestTrailToken = 0;         // 尾巴淡出令牌（防止上一段回放的余留淡出误清当前轨迹）

// v1.0.34：方案特征集合（新格式 features[] 数组；兼容旧格式单条 feature）→ 已上移 PTFeaturesOfPlan

// 懒建 sTestLine / sTestP 覆盖层（供 PTTestShowDot 与滑动尾巴渲染共用）
static void PTTestEnsureOverlay(void) {
    if (!sTestDot || !sTestDot.superview) return;
    UIView *parent = sTestDot.superview;
    if (!sTestLine) {
        sTestLine = [CAShapeLayer layer];
        sTestLine.strokeColor = [UIColor systemGreenColor].CGColor;
        sTestLine.fillColor = [UIColor clearColor].CGColor;
        sTestLine.lineWidth = 3; sTestLine.lineCap = kCALineCapRound;
        sTestLine.lineJoin = kCALineJoinRound;
        [parent.layer addSublayer:sTestLine];
    }
    if (!sTestP) {
        sTestP = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        sTestP.layer.cornerRadius = 18;
        sTestP.backgroundColor = [UIColor systemGreenColor];
        sTestP.userInteractionEnabled = NO; sTestP.hidden = YES;
        UILabel *pl = [[UILabel alloc] initWithFrame:sTestP.bounds];
        pl.text = @"P"; pl.textAlignment = NSTextAlignmentCenter;
        pl.font = [UIFont boldSystemFontOfSize:18]; pl.textColor = [UIColor whiteColor];
        [sTestP addSubview:pl];
        [parent addSubview:sTestP];
    }
}

// 轨迹可视化统一成「调试可视化同款」——起点绿点 + 方向线 + 终点 P 标记（真实坐标）。
// 本函数画「单段手势」（tap / 直线 swipe），from→to 是一条直线；滑动(手动)的连续尾巴见 PTTestDrawTrailHead。
void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur) {
    if (!sTestDot) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTTestEnsureOverlay();
        if (!sTestDot.superview) return;
        // 起点绿点
        sTestDot.hidden = NO; sTestDot.alpha = 0.9; sTestDot.center = from;
        // 终点 P + 方向线（from→to）
        sTestP.hidden = NO; sTestP.alpha = 0.95; sTestP.center = to;
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, from.x, from.y);
        CGPathAddLineToPoint(path, NULL, to.x, to.y);
        sTestLine.path = path; CGPathRelease(path);
        // 渐隐收尾：swipe 按其时长保留，tap 短暂保留
        double hold = animate ? MAX(dur, 0.3) : 0.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((hold + 0.4) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sTestDot.alpha = 0; sTestDot.hidden = YES;
            sTestP.alpha = 0; sTestP.hidden = YES; sTestLine.path = nil;
        });
    });
}

// 滑动(手动)回放逐帧把当前点追加进「尾巴」折线（起点→…→当前）并渲染，绿点移到当前、P 隐藏。
static void PTTestDrawTrailHead(CGPoint cur) {
    if (!sTestDot) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTTestEnsureOverlay();
        if (!sTestDot.superview) return;
        if (!sTestTrail) sTestTrail = [NSMutableArray array];
        [sTestTrail addObject:[NSValue valueWithCGPoint:cur]];
        CGMutablePathRef path = CGPathCreateMutable();
        BOOL first = YES;
        for (NSValue *v in sTestTrail) {
            CGPoint pt = [v CGPointValue];
            if (first) { CGPathMoveToPoint(path, NULL, pt.x, pt.y); first = NO; }
            else CGPathAddLineToPoint(path, NULL, pt.x, pt.y);
        }
        sTestLine.path = path; CGPathRelease(path);
        sTestDot.hidden = NO; sTestDot.alpha = 0.9; sTestDot.center = cur;
        if (sTestP) sTestP.hidden = YES;
    });
}

// 滑动(手动)回放结束——终点显示 P，整条尾巴保留 hold 时长后淡出（用令牌防串场）
static void PTTestTrailFinish(CGPoint pN, double hold) {
    if (!sTestDot) return;
    int myToken = sTestTrailToken;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTTestEnsureOverlay();
        if (!sTestDot.superview) return;
        if (sTestP) { sTestP.hidden = NO; sTestP.alpha = 0.95; sTestP.center = pN; }
        double h = MAX(hold, 0.3);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((h + 0.4) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (myToken != sTestTrailToken) return;   // 已有新回放开始，不要误清当前轨迹
            sTestDot.alpha = 0; sTestDot.hidden = YES;
            if (sTestP) { sTestP.alpha = 0; sTestP.hidden = YES; }
            sTestLine.path = nil;
            sTestTrail = nil;
        });
    });
}

// v1.0.71：测试页退出一键复位——armed/绿点/方向线/P 标记/尾巴/实时记录区一并清理，
// 并作废在飞的尾巴淡出回调（令牌）。替代设置页/dylib 各自 viewDidDisappear 里
// 直接摸 Core 静态可视化对象的旧写法（那些静态现已归 Core 所有）。
void PTTestReset(void) {
    sTestArmed = NO;
    sTestDot = nil;
    if (sTestLine) { [sTestLine removeFromSuperlayer]; sTestLine = nil; }
    if (sTestP) { [sTestP removeFromSuperview]; sTestP = nil; }
    sTestTrail = nil;
    sTestLogSink = nil;
    sTestTrailToken++;   // 作废上一段回放余留的淡出
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
        double speed = ([a[@"speed"] doubleValue] ?: 1000) * gSwipeBurstRate;   // v1.0.67：测试页同样吃连滑档位(1/2/3)
        double distT = hypot(to.x - from.x, to.y - from.y);
        double durMs = (distT / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        PTTestShowDot(from, to, YES, durMs / 1000.0);
        double durSec = MAX(durMs / 1000.0, 0.001);
        int token = gExecToken;   // v1.0.66-fix：捕获本次令牌，中断上一段测试手势用
        __block NSInteger pid = -1;
        __block CGPoint lastP = from;   // 中止时在最后已知位置抬手，避免粘手
        __block void (^stillAt)(CGPoint, int);
        stillAt = ^(CGPoint pos, int ms) {
            __block int n = MAX(ms, 0) / 16;
            __block void (^still)(void);
        still = ^(void) {
            if (token != gExecToken) {   // v1.0.66-fix：被新手势中断 → 抬手收尾
                if (pid >= 0) [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseEnded];
                if (next) next();
                return;
            }
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
            if (token != gExecToken) {   // v1.0.66-fix：被新手势中断 → 在最后位置抬手收尾
                if (pid >= 0) [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
                if (next) next();
                return;
            }
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
            lastP = pp;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pp withTouchPhase:UITouchPhaseMoved];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }   // v1.0.66-fix：已中断则不落新手势
            pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                if (token != gExecToken) { if (pid >= 0) [PTFakeMetaTouch fakeTouchId:pid AtPoint:from withTouchPhase:UITouchPhaseEnded]; if (next) next(); return; }
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
        PTFakeRecSwipeAsync(pts, gExecToken, (double)gSwipeBurstRate, next);   // v1.0.67：测试页同样支持连滑档位(1/2/3)
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// 测试页：1:1 移植 DVT 连滑（与运行端一致：同方案=续滑/升档，异方案=刹停）
static void PTTestExecPlan(NSString *name) {
    // 测试按钮即"一次按键"：复用与运行端相同的连滑判定
    if (gExecRunning) {
        if (![gSwipeBurstPlan isEqualToString:name]) {
            BOOL wasActive = gSwipeBurstActive;
            gSwipeBurstActive = NO; gSwipeBurstCount = 0; gSwipeBurstRate = 1;
            gSwipeStopRequested = YES; gExecToken++;   // 中断在飞回放（抬手收尾）
            PTDylibLog(@"[测试] 异方案「%@」→ 刹停「%@」", name, gSwipeBurstPlan);
            if (wasActive) PTChainPill(@"已退出连滑");
            return;
        }
        if (gSwipeBurstActive) {
            gSwipeBurstRate = (gSwipeBurstRate >= 3) ? 1 : gSwipeBurstRate + 1;
            // v1.0.67：与运行端一致——⚡雷电样式「⚡连滑 ×1/×2/×3」（选项 i：仍走 DVT 1/2/3 档）
            PTChainPill([NSString stringWithFormat:@"⚡连滑 ×%ld", (long)gSwipeBurstRate]);
            return;
        }
        if (!gChainEnabled) return;
        gSwipeBurstCount++;
        if (gSwipeBurstCount < kSwipeBurstThreshold) {
            // v1.0.67：蓄力期实时倒数「连滑 1/5 … 4/5」（选项 A，门槛保持 5）
            PTChainPill([NSString stringWithFormat:@"连滑 %ld/%d", (long)gSwipeBurstCount, kSwipeBurstThreshold]);
        } else {
            gSwipeBurstActive = YES; gSwipeBurstRate = 1; PTChainPill(@"已进入连滑");
        }
        return;
    }
    gSwipeBurstCount = gChainEnabled ? 1 : 0;
    gSwipeBurstPlan  = name;
    gSwipeBurstRate  = 1;
    gSwipeStopRequested = NO;
    double now = PTNowC();
    if (now - sLastTestExec < 0.3) { PTDylibLog(@"[测试] 防抖：忽略 %@", name); return; }
    sLastTestExec = now;
    // v1.0.67：蓄力倒数从第 1 次命中即开始显示（连滑 1/5）；防抖忽略的不出 pill
    if (gChainEnabled) PTChainPill([NSString stringWithFormat:@"连滑 1/%d", kSwipeBurstThreshold]);
    PTExecutePlan(name);   // 测试页走与运行端完全相同的回放路径，验证即所见
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
        PTDylibLog(@"[测试] 未匹配：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d（特征需先录制）", sender, phase, dir, dist, tapDx);
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
// 动作执行（PTFakeMetaTouch ＋ 延迟；v1.0.5 音量动作已删除）
// ============================================================
// v1.0.66-fix4：gIsInjecting/gExecRunning/gInFakeTouch/gExecToken/gLastExec 已上移至顶部全局区（供测试页共用）

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
        if (done) done();   // v1.0.66-fix3：旧代码此路径不回调 done，动作序列链悬挂
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

    // v1.0.71：测试区轨迹可视化（设置页富版并入 Core）——新段回放开始：作废上一段余留的
    // 淡出令牌、重建尾巴、先画起点。sTestDot 为 nil（App 进程无测试页）时各钩子直接返回，零成本。
    sTestTrailToken++;
    sTestTrail = [NSMutableArray array];
    PTTestDrawTrailHead(CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]));

    __block NSInteger pid = -1;
    __block BOOL ended = NO;
    __block CGPoint lastCur = CGPointZero;   // v1.0.66-fix3：最后注入坐标，中断时在此抬手
    __block CFAbsoluteTime startT = CFAbsoluteTimeGetCurrent();
    __block CFAbsoluteTime lastTick = startT;
    __block double playMs = 0;   // v1.0.66(#6)：已播放毫秒（受 rate 与单帧封顶约束，单调推进）
    PTRecSwipeTickProxy *proxy = [PTRecSwipeTickProxy new];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(onTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    proxy.tick = ^{
        // v1.0.66-fix3：被新手势砍断（token 失配）→ 先在最后位置发 Ended 抬手，再 invalidate。
        // 旧代码只 invalidate 不发 Ended → 假手指粘半空、调试圆点永不消散、App 端叠成双指混乱。
        if (token != gExecToken) {
            if (pid >= 0 && !ended) {
                ended = YES;
                gInFakeTouch = YES;
                [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastCur withTouchPhase:UITouchPhaseEnded];
                gInFakeTouch = NO;
            }
            PTTestTrailFinish(lastCur, 0.3);   // v1.0.71：中断也要收尾（终点 P + 尾巴淡出），否则可视化残影
            [link invalidate]; if (done) done(); return;
        }
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
        lastCur = cur;   // v1.0.66-fix3：记录最后坐标供中断抬手
        gInFakeTouch = YES;
        if (pid < 0) pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:cur withTouchPhase:UITouchPhaseBegan];
        else         [PTFakeMetaTouch fakeTouchId:pid AtPoint:cur withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        PTTestDrawTrailHead(cur);   // v1.0.71：逐帧追加尾巴（起点→…→当前）
        if (playMs >= totalMs && !ended) {
            CGPoint end = CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:end withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            ended = YES;
            [link invalidate];
            PTTestTrailFinish(end, totalMs / 1000.0);   // v1.0.71：终点 P + 尾巴保留后淡出
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
        double speed = ([a[@"speed"] doubleValue] ?: 1000) * gSwipeBurstRate;   // v1.0.67：连滑档位(1/2/3) → 越快；单滑固定 1.0
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        double dist = hypot(to.x - from.x, to.y - from.y);
        double durMs = (dist / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 90) durMs = 90;   // v1.0.66-fix：保底时长，连滑提速也不低于此，确保 App 识别为滑动而非点按
        PTFakeSwipeAsync(from, to, durMs, holdMs, liftMs, noInertia, token, next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.8：滑动(手动)——按录制轨迹回放；v1.0.66(#6)：带连滑提速倍率
        PTFakeRecSwipeAsync(a[@"pts"], token, (double)gSwipeBurstRate, next);   // v1.0.67：连滑档位(1/2/3) → 越快
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// ============================================================
// v1.0.67：连滑（1:1 移植自 DVT 1.0.22）——顶部 pill + 刹停/清理 + 生命周期
// ============================================================
// 顶部小胶囊提示（DVT v1.0.17：文案参数化，2 秒自动消失）
// v1.0.67：绿底白字。底色用动态Provider——深色模式下自动换更深的绿，
//   白字在两种模式下都清晰可读（杜绝"背景字体糊成一片"；alpha 保证pill感又不挡内容）。
static UILabel *gChainHint = nil;
static UIColor *PTChainPillBG(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.10 green:0.50 blue:0.23 alpha:0.95];   // 深色模式：深绿，白字对比度高
        }
        return [UIColor colorWithRed:0.18 green:0.73 blue:0.31 alpha:0.90];       // 浅色模式：鲜绿
    }];
}
static void PTChainPill(NSString *msg) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ PTChainPill(msg); }); return; }
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    if (gChainHint) { [gChainHint removeFromSuperview]; gChainHint = nil; }
    CGFloat topInset = (w.safeAreaInsets.top > 0) ? w.safeAreaInsets.top : 20;
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(w.bounds.size.width/2 - 120, topInset + 44, 240, 30)];
    h.text = msg.length ? msg : @"请等待滑动完成";
    h.textColor = [UIColor whiteColor];   // v1.0.67：绿底白字（底色随深色模式自适应，见 PTChainPillBG）
    h.textAlignment = NSTextAlignmentCenter;
    h.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];   // v1.0.67：半粗体，绿底上更清晰
    h.backgroundColor = PTChainPillBG();
    h.layer.cornerRadius = 15;
    h.layer.masksToBounds = YES;
    [w addSubview:h];
    [w bringSubviewToFront:h];
    gChainHint = h;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gChainHint == h) { [h removeFromSuperview]; gChainHint = nil; }
    });
}

// 刹停/未命中/关开关：清空连滑链（DVT：异方案/退后台/无轨迹时调用；PageTurner 未命中也兜底清理）
void PTChainReset(void) {
    if (gSwipeBurstPlan) PTDylibLog(@"[连滑] 刹停：链「%@」结束（计数 %ld 档位%ld）", gSwipeBurstPlan, (long)gSwipeBurstCount, (long)gSwipeBurstRate);
    gSwipeBurstActive = NO;
    gSwipeBurstCount = 0;
    gSwipeBurstRate  = 1;
    gSwipeStopRequested = NO;
    gSwipeBurstPlan = nil;
}

// 退后台/生命周期：断连滑 + 中断在飞回放（抬手收尾），回前台状态干净（DVT v1.0.22 dvtAppDidEnterBackground）
static void PTChainStopAll(void) {
    gSwipeBurstActive = NO;
    gSwipeBurstCount = 0;
    gSwipeBurstRate  = 1;
    gSwipeStopRequested = NO;
    gSwipeBurstPlan = nil;
    if (gExecRunning) gExecToken++;   // 中断在飞回放（PTFakeSwipeAsync/... 令牌失配 → 抬手收尾）
}

// 实际执行方案动作序列（无防抖）。v1.0.67：DVT 式连滑——进连滑后收尾处自动调用本函数实现无缝续滑。
static void PTExecutePlanRun(NSString *name) {
    NSDictionary *p = gPlans[name];
    NSArray *actions = p[@"actions"] ?: @[];
    if (!actions.count) { PTDylibLog(@"[执行] %@ 无动作，跳过", name); return; }
    gExecToken++;   // 全新启动递增令牌（刹停/异常中止时令在飞手势令牌失配 → 抬手收尾）
    int token = gExecToken;
    gIsInjecting = YES;
    gExecRunning = YES;
    PTDylibLog(@"[执行] 命中 %@，开始动作序列（%lu 条，档位 %ld）", name, (unsigned long)actions.count, (long)gSwipeBurstRate);
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (token != gExecToken) {   // 令牌失配（刹停/异常中止）→ 不再续播，复位在飞标记
            gIsInjecting = NO;
            gExecRunning = NO;
            return;
        }
        if (idx >= (int)actions.count) {
            gIsInjecting = NO;
            gExecRunning = NO;
            PTDylibLog(@"[执行] %@ 序列完成", name);
            // v1.0.67：DVT 式自动续滑——连滑中且未刹停 → 立即重开同方案（无缝重复，无需再按键）
            if (gSwipeBurstActive && gChainEnabled && !gSwipeStopRequested) {
                PTDylibLog(@"[连滑] 自动续滑「%@」（档位 %ld）", name, (long)gSwipeBurstRate);
                PTExecutePlanRun(name);
            }
            return;
        }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// 执行方案动作序列（对外入口，含普通防抖）。自动续滑由 PTExecutePlanRun 收尾处直接触发，不经过此处防抖。
static void PTExecutePlan(NSString *name) {
    double now = PTNowC();
    if (now - gLastExec < gDebounceMs / 1000.0) {
        PTDylibLog(@"[执行] 防抖：忽略 %@（%.0fms 内已执行）", name, gDebounceMs);
        return;
    }
    gLastExec = now;
    PTExecutePlanRun(name);
}

// v1.0.71：运行端命中方案后的连滑判定 + 起执行（从外壳 PTHandlePagerEvent 抽出，与测试页
// PTTestExecPlan 共用同一套连滑状态机——此前两处各写一份，设置页侧已漂移成旧版无连滑逻辑）。
// 调用方（外壳 PTHandlePagerEvent）负责：gSessTrail 清理 / 未命中时 PTReplayTrailAsync 重放。
void PTChainHandleHit(NSString *plan) {
    if (gExecRunning) {   // 回放中（= 连按检测窗口）
        if (![gSwipeBurstPlan isEqualToString:plan]) {
            // 异方案 = 反方向刹停：立即中断当前滑剩余帧 + 退连滑 + 档位复位（DVT v1.0.22）
            BOOL wasActive = gSwipeBurstActive;
            gSwipeBurstActive     = NO;
            gSwipeBurstCount      = 0;
            gSwipeBurstRate       = 1;
            gSwipeStopRequested   = YES;
            gExecToken++;   // 中断在飞回放（令牌失配 → PTFakeSwipeAsync/RecSwipe 抬手收尾）
            PTDylibLog(@"[连滑] 异方案「%@」→ 刹停「%@」", plan, gSwipeBurstPlan);
            if (wasActive) PTChainPill(@"已退出连滑");
            return;
        }
        if (gSwipeBurstActive) {
            // 连滑中按同方案 = 升档 1→2→3→1 循环，对下一段滑生效（DVT v1.0.22）
            gSwipeBurstRate = (gSwipeBurstRate >= 3) ? 1 : gSwipeBurstRate + 1;
            // v1.0.67：⚡雷电样式「⚡连滑 ×1/×2/×3」（选项 i：提速模型仍走 DVT 1/2/3 离散档，只换皮）
            PTChainPill([NSString stringWithFormat:@"⚡连滑 ×%ld", (long)gSwipeBurstRate]);
            return;
        }
        if (!gChainEnabled) return;   // 总开关关闭：窗口期按压静默忽略
        // 普通窗口期：同方案累计，达阈值即进入连滑
        gSwipeBurstCount++;
        if (gSwipeBurstCount < kSwipeBurstThreshold) {
            // v1.0.67：蓄力期实时倒数「连滑 1/5 … 4/5」（选项 A，门槛保持 5）
            PTChainPill([NSString stringWithFormat:@"连滑 %ld/%d", (long)gSwipeBurstCount, kSwipeBurstThreshold]);
        } else {
            gSwipeBurstActive = YES;
            gSwipeBurstRate   = 1;
            PTChainPill(@"已进入连滑");
        }
        return;
    }
    // 不在回放中：起新滑，开启新检测窗口（本次命中计为第 1 次，并锁定方案）
    gSwipeBurstCount     = gChainEnabled ? 1 : 0;
    gSwipeBurstPlan      = plan;
    gSwipeBurstRate      = 1;
    gSwipeStopRequested  = NO;
    // v1.0.67：蓄力倒数从第 1 次命中即开始显示（连滑 1/5）
    if (gChainEnabled) PTChainPill([NSString stringWithFormat:@"连滑 1/%d", kSwipeBurstThreshold]);
    PTDylibLog(@"[会话] 命中「%@」→ 起映射（原始滑动已整段吞掉）", plan);
    PTExecutePlan(plan);
}
