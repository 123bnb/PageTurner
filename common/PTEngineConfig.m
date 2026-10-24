// ============================================================
// PTEngineConfig.m —— 引擎核心·配置（v1.0.78 从 PTEngineCore.m 拆出）
//
// 内容：配置路径（App 沙盒容器 / PTSetCfgPath 注入 / PTJbrootRoot 共享 jbroot
//       探测）、配置读写（PTDylibReadCfg/PTDylibWriteCfg/PTWriteCfgTo + 写入器
//       注入 PTSetCfgWriter→PTWriteCfg）、v1.0.77 UI 统一入口（PTUIReadCfg/
//       PTUIWriteCfg，含 pid 惰性补发）、学习开关（PTDylibSetLearningLocal）、
//       运行端配置缓存（gConfig/gPlans/gDebounceMs/gDebugDots，
//       PTDylibLoadConfig/PTConfigDict）、IOKit sender 读取 dlsym。
// 跨文件依赖（PTEngineInternal.h）：PTChainStopAll/PTChainReset（退后台/关开关断链）。
// ============================================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import "PTEngineCore.h"
#import "PTEngineInternal.h"
#import "PTEngineVolume.h"   // v1.0.80：音量配置缓存 + 热启停（gVolEnabled/gVolHudHidden）

// ============================================================
// 常量（数值型统一宏在 PTEngineCore.h；此处只留本文件私有字符串）
// ============================================================
static NSString *kDylibPrefsName = @"com.yourname.pageturnerdylib.plist";
// ptftouch/Compat.h 声明了 extern gInjectSender（本库未使用，补实体防止动态查找落空）
uint64_t gInjectSender = 0;
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

// v1.0.78：PTWriteCfgTo（原子写指定路径）已下沉 PTCoreLogic.m（纯逻辑层，
// tests/ 可链）——本文件 PTDylibWriteCfg 经 PTCoreLogic.h 调用，行为不变。

void PTDylibWriteCfg(NSDictionary *cfg) {
    PTWriteCfgTo(PTDylibCfgPath(), cfg);
}

// v1.0.71：配置写入器注入——设置进程（Preferences）需要双写（jbroot 真实偏好路径 App 侧读得到
// + 普通路径兜底自己读），注入进程只写自己的路径。Core 内部所有配置写入
// （学习样本 / 学习开关）统一走 PTWriteCfg，行为随进程角色自动正确。
static void (*sCfgWriter)(NSDictionary *cfg) = NULL;
void PTSetCfgWriter(void (*writer)(NSDictionary *cfg)) { sCfgWriter = writer; }
void PTWriteCfg(NSDictionary *cfg) {
    if (sCfgWriter) sCfgWriter(cfg);
    else PTDylibWriteCfg(cfg);
}

// ============================================================
// v1.0.77：UI 层统一配置读写入口（设置页 / dylib 浮窗 / 共享 VC 合一）
// ============================================================
// 背景：v1.0.77 前「读配置 + pid 惰性补发」有两份逐字复制的实现——
//   · Preferences/RootListController.m 的 PTRead（v1.0.66-fix，含重名去重）
//   · targets/dylib/PTDylibUI.m 的 PTUIRead（v1.0.75，同规则）
// 写路径同样两条（设置页 PTWrite 双写 / dylib PTDylibWriteCfg 单写）。8 个同名 VC
// 抽到 common/PTUI* 后，读写入口必须合一，否则「设置各管各的」又复辟。
// 补发规则与引擎 PTDylibLoadConfig 的 gPlans 补发完全一致（PTPlanPid：有 pid 用
// 字段、无则 name#数组下标），补发即经 PTUIWriteCfg 落盘（设置页=双写，dylib=单写）。
void PTUIWriteCfg(NSDictionary *cfg) {
    PTWriteCfg(cfg);
}

NSMutableDictionary *PTUIReadCfg(void) {
    NSMutableDictionary *d = PTDylibReadCfg();
    NSArray *plans = d[@"plans"];
    if ([plans isKindOfClass:[NSArray class]] && plans.count) {
        BOOL need = NO;
        for (id p in plans) {
            if (![p isKindOfClass:[NSDictionary class]] || !p[@"name"]) continue;
            // 取字符串字段先过 isKindOfClass 再转型——id 上直接点 .length 编译不过
            NSString *pf = [p[@"pid"] isKindOfClass:[NSString class]] ? p[@"pid"] : nil;
            if (!pf.length) { need = YES; break; }
        }
        if (need) {
            NSMutableArray *out = [NSMutableArray array];
            for (NSUInteger i = 0; i < plans.count; i++) {
                id p = plans[i];
                if ([p isKindOfClass:[NSDictionary class]] && p[@"name"]) {
                    NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
                    NSString *pf = [np[@"pid"] isKindOfClass:[NSString class]] ? np[@"pid"] : nil;
                    if (!pf.length) np[@"pid"] = PTPlanPid(np, (NSInteger)i);
                    p = np;
                }
                [out addObject:p];
            }
            d[@"plans"] = out;
            PTUIWriteCfg(d);   // 补发即落盘（经注入写入器：设置页双写 / dylib 容器单写）
            PTDylibLog(@"[配置] UI 侧方案 pid 惰性补发完成（%lu 条）", (unsigned long)out.count);
        }
    }
    return d;
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
double gDebounceMs = 300;
BOOL gDebugDots = NO;   // v1.0.71：改非静态（外壳调试可视化读取；原 static 仅引擎内部用）
// v1.0.78：PTEngineCore.m 拆为 7 个实现文件（纯逻辑层 PTCoreLogic + 六件套，各文件头
// 有清单）。旧单文件时代此处有一批「调用早于定义」的前向声明（PTChainReset/PTChainMiss/
// PTChainPill/PTChainStopAll/PTChainOnHit/PTExecutePlan/PTExecutePlanRun/PTFakeRecSwipeAsync）——
// 跨文件的那些现已由 PTEngineInternal.h 统一声明，本文件不再需要。仍留在位的历史语义：
//   · PTChainReset/PTChainMiss 是 PTEngineCore.h 的 extern 公开 API（设置页/外壳都要调）；
//   · PTExecutePlan 的 force 参数 = 刚进连滑的那一击放行防抖，防「假连滑」（v1.0.72）；
//   · PTFakeRecSwipeAsync 的调用方（测试回放/动作分发）已同住 PTEngineExec.m，无需声明。

NSMutableDictionary *gPlans = nil;
static BOOL gLearnActive = NO;
uint64_t gLearnedSenders[kMaxLearnedSenders];
int gLearnedSenderCount = 0;
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
    // v1.0.72：连滑开关被关 → 断链。否则 gSwipeBurstActive 残留：开关再开时第一击的
    // 回放一结束就满足自动续滑条件 → 一击进连滑（假连滑）。
    BOOL prevChainEnabled = gChainEnabled;
    gChainEnabled = (gConfig[@"chainEnabled"] == nil) ? YES : [gConfig[@"chainEnabled"] boolValue];   // v1.0.66(#6)
    if (prevChainEnabled && !gChainEnabled) PTChainReset();
    // v1.0.80：音量键配置缓存 + 热启停（对称 chainEnabled：开关翻转时机制起停干净，
    // 不在「关了闸」的状态下残留 KVO/会话）。首次加载 prevVol=NO，配置开即热启动。
    BOOL prevVol = gVolEnabled;
    BOOL prevVolHud = gVolHudHidden;
    gVolEnabled   = [gConfig[@"volEnabled"] boolValue];                                    // 默认关
    gVolHudHidden = (gConfig[@"volHudHidden"] == nil) ? YES : [gConfig[@"volHudHidden"] boolValue];   // 默认开
    if (prevVol && !gVolEnabled) { PTChainReset(); PTVolumeStop(); }                        // 关闸：断链 + 停机制
    if (!prevVol && gVolEnabled) { PTVolumeStart(); PTVolumeApplyHud(gVolHudHidden); }      // 开闸：热启动 + HUD 应用
    if (prevVol && prevVolHud != gVolHudHidden) PTVolumeApplyHud(gVolHudHidden);            // 闸已开时单改「隐藏音量条」：热应用（挂/摘 MPVolumeView）
    gPlans = [NSMutableDictionary dictionary];
    gLearnedSenderCount = 0;
    // v1.0.74：pid 贯通——gPlans 由 name 索引改 pid 索引。旧配置无 pid → 惰性补发
    // 「name#下标」并落盘（规则与设置页 v1.0.66-fix / dylib UI v1.0.75 完全一致，
    // 三端对同一份配置补出同一批 pid）。写盘只发生一次：落盘后下次读取即带 pid，
    // needPid=NO 不再写，mtime 不会因此反复变化。
    NSArray *plansArr = gConfig[@"plans"] ?: @[];
    BOOL needPid = NO;
    for (NSUInteger i = 0; i < plansArr.count; i++) {
        NSDictionary *pl = plansArr[i];
        if (![pl isKindOfClass:[NSDictionary class]] || !pl[@"name"]) continue;
        // v1.0.74(3/3)：取字符串字段要先过 isKindOfClass 再转型——id 上直接点 .length 编译不过
        NSString *pidField = [pl[@"pid"] isKindOfClass:[NSString class]] ? pl[@"pid"] : nil;
        if (!pidField.length) { needPid = YES; break; }
    }
    if (needPid) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSUInteger i = 0; i < plansArr.count; i++) {
            id pl = plansArr[i];
            if ([pl isKindOfClass:[NSDictionary class]] && pl[@"name"]) {
                NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:pl];
                NSString *pf = [np[@"pid"] isKindOfClass:[NSString class]] ? np[@"pid"] : nil;
                if (!pf.length) np[@"pid"] = PTPlanPid(np, (NSInteger)i);
                pl = np;
            }
            [out addObject:pl];
        }
        plansArr = out;
        // v1.0.74(3/3)：gConfig 声明为不可变 NSDictionary*，下标赋值要先转可变副本
        NSMutableDictionary *mCfg = [NSMutableDictionary dictionaryWithDictionary:gConfig];
        mCfg[@"plans"] = out;
        gConfig = mCfg;
        PTWriteCfg(mCfg);   // 落盘唯一 pid（三端下次读即带 pid）
        PTDylibLog(@"[配置] 方案 pid 惰性补发完成（%lu 条）", (unsigned long)out.count);
    }
    for (NSUInteger i = 0; i < plansArr.count; i++) {
        NSDictionary *pl = plansArr[i];
        if (![pl isKindOfClass:[NSDictionary class]] || !pl[@"name"]) continue;
        gPlans[PTPlanPid(pl, (NSInteger)i)] = pl;
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
