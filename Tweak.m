// ============================================================
// Tweak.m —— PageTurner v1.0.57（roothide / deb 薄壳入口）
//
// 统一工程：运行端引擎在 common/PTEngine.m（roothide 与 dylib 共用同一份）。
// 本文件只负责 roothide 特有部分，绝不重复引擎逻辑：
//   · 配置路径（/var/mobile 多候选 + jbroot 探测）—— 通过 PTSetCfgPath 注入引擎
//   · 总开关 + 指定 App 生效门控（PTSetInterceptEnabled）—— 关掉 / 非指定 App 直接放行
//   · 用 MSHookMessageEx 装 hook（ellekit 要求含该符号才会注入第三方 App）
//   · 注入标记文件（Filza 一眼可查是否注入）
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

// 跨沙盒读全局 plist（照抄原 Tweak.xm）：roothide 下第三方 App 沙盒读 /var/mobile 会被重定向，
// 从 .jbroot-XXX 根拼真实偏好路径。
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
    return cands.firstObject;
}

// 注入标记文件（照抄原 Tweak.xm）：constructor 一被加载就写，Filza 看
// /var/mobile/Documents/PageTurner-injected-<bid>.txt 即知该进程有没有被注入。
static void PTWriteInjectMarker(NSString *bid) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ 注入标记 进程=%@ bundleID=%@\n",
                          [NSDate date], NSProcessInfo.processInfo.processName, bid];
        NSMutableArray *paths = [NSMutableArray arrayWithArray:@[
            [NSString stringWithFormat:@"/var/mobile/Documents/PageTurner-injected-%@.txt", bid],
            @"/var/mobile/Documents/PageTurner-injected.txt",
            [NSString stringWithFormat:@"/tmp/PageTurner-injected-%@.txt", bid]]];
        NSString *jb = PTJbrootRoot();
        if (jb.length) {
            [paths addObject:[jb stringByAppendingPathComponent:
                [NSString stringWithFormat:@"var/mobile/Documents/PageTurner-injected-%@.txt", bid]]];
        }
        for (NSString *p in paths) {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *dir = [p stringByDeletingLastPathComponent];
            if (dir.length && ![fm fileExistsAtPath:dir])
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:nil];
            FILE *f = fopen(p.UTF8String, "a");
            if (f) { fputs(line.UTF8String, f); fclose(f); }
        }
    } @catch (NSException *e) {}
}

static void PTHook(NSString *clsName, NSString *selName, IMP newImp, IMP *origSlot) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { PTDylibLog(@"[探测] 类不存在 %@ 跳过", clsName); return; }
    SEL sel = sel_registerName(selName.UTF8String);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PTDylibLog(@"[探测] %@ -%@ 不存在，跳过", clsName, selName); return; }
    MSHookMessageEx(cls, sel, newImp, origSlot);
}

__attribute__((constructor))
static void PTInit() {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID.length) return;
        gBundleID = bundleID;
        gIsPreferences = [bundleID isEqualToString:kPrefsBundleID];

        // 配置路径交给引擎（roothide 多候选 / jbroot）；日志路径指向 App 容器 Documents
        PTSetCfgPath(PTGlobalPlistPath());
        NSString *home = NSHomeDirectory();
        PTSetLogPath([[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"PageTurner.log"]);

        PTDylibInitIOKit();
        PTDylibLoadConfig(YES);

        NSDictionary *cfg = PTConfigDict();
        BOOL masterEnabled = [cfg[@"masterEnabled"] boolValue];
        NSArray *apps = cfg[@"enabledApps"];
        NSMutableSet *enabledApps = [NSMutableSet setWithArray:apps ? apps : @[]];

        PTDylibLog(@"==================================================");
        PTDylibLog(@"PageTurner v1.0.57 已注入 %@ (pid=%d) isPrefs=%d", bundleID, getpid(), gIsPreferences);
        PTDylibLog(@"配置路径=%@ 总开关=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu",
              PTGlobalPlistPath(), masterEnabled, (unsigned long)enabledApps.count,
              [cfg[@"debounceMs"] doubleValue] ?: 300.0,
              (unsigned long)(cfg[@"plans"] ? [cfg[@"plans"] count] : 0));

        PTWriteInjectMarker(bundleID);

        if (gIsPreferences) {
            // 学习收集由设置页 bundle 负责（roothide 空 Filter 不注入系统 App，tweak 在此进程收不到事件）
            PTDylibLog(@"Preferences 进程旁路：学习收集由设置页 bundle 负责");
        } else {
            BOOL intercept = masterEnabled && [enabledApps containsObject:bundleID];
            PTSetInterceptEnabled(intercept);
            if (intercept) {
                IMP origAdd = NULL, origSend = NULL;
                PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTDylibAddEvent, &origAdd);
                PTHook(@"UIApplication", @"sendEvent:", (IMP)PTDylibSendEvent, &origSend);
                PTSetOrigAddEvent(origAdd);
                PTSetOrigSendEvent(origSend);
                PTDylibLog(@"生效 App 就绪：学过的 sender 按键将被拦截");
            } else {
                PTDylibLog(@"旁路：未生效 App（bundleID=%@ 不在列表(%lu)或总开关=%d）",
                      bundleID, (unsigned long)enabledApps.count, masterEnabled);
            }
        }
        PTDylibLog(@"==================================================");
    }
}
