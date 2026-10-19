// ============================================================
// Tweak.m —— PageTurner v1.0.57（roothide / deb 薄壳入口）
//
// 统一工程：运行端引擎在 common/PTEngine.m（roothide 与 dylib 共用同一份）。
// 本文件只负责 roothide 特有部分，绝不重复引擎逻辑：
//   · 配置路径（/var/mobile 多候选 + jbroot 探测）—— 通过 PTSetCfgPath 注入引擎
//   · 总开关 + 指定 App 生效门控（PTSetInterceptEnabled）—— 关掉 / 非指定 App 直接放行
//   · 用 MSHookMessageEx 装 hook（ellekit 要求含该符号才会注入第三方 App）
//   · 日志：仅「勾选生效」的 App 写共享 jbroot 的 Documents（设置页可读）；未勾选 App 不写文件（v1.0.65 修正滥建）
//
// 已删除：注入探针（旧版无法注入时的兜底弹窗 PTShowProbeAlert / 提醒条 PTShowToast，
//         早该删）；多候选路径日志冗余收敛为单路径。
// ============================================================
#import "PTEngine.h"
#import <dlfcn.h>
#import <stdio.h>
#import <mach-o/dyld.h>   // _dyld_image_count / _dyld_get_image_name（jbroot 探测）

// MSHookMessageEx 由 -lsubstrate（ellekit substrate 兼容库）提供。
// 注意：本文件是 Tweak.m（Objective-C，按 C 编译），不能用 C++ 的 extern "C" 写法——
// 原 Tweak.xm 经 Logos 转成 .mm（C++）才需要 extern "C"；这里直接 extern 即为 C 链接。
extern void MSHookMessageEx(Class _cls, SEL _name, IMP _imp, IMP *_orig);

static NSString *kPrefsBundleID = @"com.apple.Preferences";
static NSString *gBundleID = nil;
static BOOL gIsPreferences = NO;

// 跨沙盒读全局 plist：roothide 下第三方 App 沙盒读 /var/mobile 会被重定向，
// 从 .jbroot-XXX 根拼真实偏好路径。jbroot 探测统一用引擎的 PTJbrootRoot()（含目录扫描兜底）。

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
    return cands.firstObject;
}

// v1.0.59：注入标记功能已删除（注入早已稳定可靠，不再产生 PageTurner-injected-*.txt）

static void PTHook(NSString *clsName, NSString *selName, IMP newImp, IMP *origSlot) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { PTDylibLog(@"[探测] 类不存在 %@ 跳过", clsName); return; }
    SEL sel = sel_registerName(selName.UTF8String);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PTDylibLog(@"[探测] %@ -%@ 不存在，跳过", clsName, selName); return; }
    MSHookMessageEx(cls, sel, newImp, origSlot);
}

// v1.0.65：仅「勾选生效」的 App 才调用本函数拿共享 jbroot 的 Documents 路径（设置页可读）；
// 未勾选的 App 不调用，由 PTSetFileLogEnabled(NO) 关掉文件日志。v1.0.59 曾对所有注入 App 都钉此路径，
// 导致 jbroot Documents 被一堆未启用的 PageTurner-<bid>.log 占满——现已修正。
static NSString *PTLogPathFor(NSString *bid) {
    NSString *jb = PTJbrootRoot();
    NSString *name = [NSString stringWithFormat:@"PageTurner-%@.log", bid];
    if (jb.length) return [jb stringByAppendingPathComponent:[@"var/mobile/Documents" stringByAppendingPathComponent:name]];
    // jbroot 探测不到时兜底写自己容器（至少日志不丢）
    NSString *home = NSHomeDirectory();
    return [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"PageTurner.log"];
}

__attribute__((constructor))
static void PTInit() {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID.length) return;
        gBundleID = bundleID;
        gIsPreferences = [bundleID isEqualToString:kPrefsBundleID];

        // 配置路径交给引擎（roothide 多候选 / jbroot）
        PTSetCfgPath(PTGlobalPlistPath());

        PTDylibInitIOKit();
        PTDylibLoadConfig(YES);

        NSDictionary *cfg = PTConfigDict();
        BOOL masterEnabled = [cfg[@"masterEnabled"] boolValue];
        NSArray *apps = cfg[@"enabledApps"];
        NSMutableSet *enabledApps = [NSMutableSet setWithArray:apps ? apps : @[]];
        // 是否真正生效（勾选拦截）：设置页进程恒为 YES（它要写自己的诊断日志）
        BOOL intercept = gIsPreferences ? YES : (masterEnabled && [enabledApps containsObject:bundleID]);

        // v1.0.65：文件日志只给「勾选生效」的 App（写共享 jbroot，供设置页读取）；
        // 未勾选/旁路的 App 关闭文件日志，不再在 jbroot Documents 留一堆无用 PageTurner-<bid>.log。
        // 调试日志总开关关闭时，PTDylibLog 内部直接返回，也不会产生文件。
        PTSetFileLogEnabled(intercept);
        if (intercept) PTSetLogPath(PTLogPathFor(bundleID));

        PTDylibLog(@"==================================================");
        PTDylibLog(@"PageTurner v1.0.65 已注入 %@ (pid=%d) isPrefs=%d 写文件=%@",
              bundleID, getpid(), gIsPreferences, intercept ? PTLogPathFor(bundleID) : @"(关闭·不写文件)");
        PTDylibLog(@"配置路径=%@ 总开关=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu",
              PTGlobalPlistPath(), masterEnabled, (unsigned long)enabledApps.count,
              [cfg[@"debounceMs"] doubleValue] ?: 300.0,
              (unsigned long)(cfg[@"plans"] ? [cfg[@"plans"] count] : 0));

        if (gIsPreferences) {
            // 学习收集由设置页 bundle 负责（roothide 空 Filter 不注入系统 App，tweak 在此进程收不到事件）
            PTDylibLog(@"Preferences 进程旁路：学习收集由设置页 bundle 负责");
        } else {
            PTSetInterceptEnabled(intercept);
            if (intercept) {
                IMP origAdd = NULL, origSend = NULL;
                PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTDylibAddEvent, &origAdd);
                PTHook(@"UIApplication", @"sendEvent:", (IMP)PTDylibSendEvent, &origSend);
                PTSetOrigAddEvent(origAdd);
                PTSetOrigSendEvent(origSend);
                PTDylibLog(@"生效 App 就绪：学过的 sender 按键将被拦截");
            } else {
                PTDylibLog(@"旁路：未生效 App（bundleID=%@ 不在列表(%lu)或总开关=%d）——不写日志文件",
                      bundleID, (unsigned long)enabledApps.count, masterEnabled);
            }
        }
        PTDylibLog(@"==================================================");
    }
}
