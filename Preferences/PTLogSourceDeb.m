// ============================================================
// PTLogSourceDeb.m —— deb 侧调试日志数据源实现（v1.0.77）
// ============================================================
#import "PTLogSourceDeb.h"
#import "PTEngineCore.h"
#import "PTUICommon.h"

@implementation PTLogSourceDeb

// 构建日志列表——① 设置页日志 ② 各「勾选生效」App 的运行日志
// 全部位于共享 jbroot 的 Documents（诊断证实这是 App 侧与设置页唯一双向可通的路径）。
// ②只枚举 enabledApps：App 侧也只为勾选生效的 App 写文件（见 Tweak.m 的 PTInit），两侧规则一致；
// 未勾选的 App 不会生成 PageTurner-<bid>.log，列表里自然也不该出现它。
- (NSArray<NSDictionary *> *)logItems {
    NSMutableArray *arr = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *jb = PTJbrootRoot();
    NSMutableArray *dirs = [NSMutableArray array];
    if (jb.length) [dirs addObject:[jb stringByAppendingPathComponent:@"var/mobile/Documents"]];
    [dirs addObject:@"/var/mobile/Documents"];
    if (!dirs.count) return arr;

    // ① 设置页日志（PageTurner.log，不带 bundleID）
    NSString *mainPath = [dirs[0] stringByAppendingPathComponent:@"PageTurner.log"];
    for (NSString *dir in dirs) {
        NSString *p = [dir stringByAppendingPathComponent:@"PageTurner.log"];
        NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
        if (at) { mainPath = p; break; }
    }
    NSDictionary *mainAt = [fm attributesOfItemAtPath:mainPath error:nil];
    [arr addObject:@{@"name": @"设置页日志（PageTurner.log）", @"path": mainPath,
                     @"size": @(mainAt ? [mainAt fileSize] : 0)}];

    // ② 各生效 App 的运行日志 PageTurner-<bundleID>.log（只列已勾选生效的 App）
    NSDictionary *cfg = PTUIReadCfg();
    NSArray *apps = cfg[@"enabledApps"] ?: @[];
    for (NSString *bid in apps) {
        NSString *fname = [NSString stringWithFormat:@"PageTurner-%@.log", bid];
        NSString *found = [dirs[0] stringByAppendingPathComponent:fname];
        for (NSString *dir in dirs) {
            NSString *p = [dir stringByAppendingPathComponent:fname];
            if ([fm attributesOfItemAtPath:p error:nil]) { found = p; break; }
        }
        NSDictionary *at = [fm attributesOfItemAtPath:found error:nil];
        [arr addObject:@{@"name": fname, @"path": found, @"size": @(at ? [at fileSize] : 0), @"bid": bid}];
    }
    return arr;
}

// 第 i 份内容（文件尾部最多 PTLogMaxLines 行——与文件循环保留行数一致）
- (NSString *)logContentAtIndex:(NSInteger)i {
    NSArray *items = [self logItems];
    if (i < 0 || i >= (NSInteger)items.count) return nil;
    NSString *path = items[i][@"path"];
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return nil;
    NSArray *ls = [s componentsSeparatedByString:@"\n"];
    NSUInteger n = ls.count;
    NSUInteger from = n > PTLogMaxLines ? n - PTLogMaxLines : 0;   // v1.0.59：最多显示 500 行
    return [[ls subarrayWithRange:NSMakeRange(from, n - from)] componentsJoinedByString:@"\n"];
}

- (BOOL)canClearLogs { return YES; }

// v1.0.59：清空全部日志（内存 + 所有 PageTurner*.log 文件）；调试日志开关关闭时调用
- (void)clearAllLogs { PTClearAllLogs(); }

@end

void PTClearAllLogs(void) {
    @try {
        PTDylibLogClearLines();   // v1.0.71：内存日志归 Core 管（旧实现 [sLogLines removeAllObjects]）
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray *dirs = [NSMutableArray array];
        NSString *jb = PTJbrootRoot();
        if (jb.length) [dirs addObject:[jb stringByAppendingPathComponent:@"var/mobile/Documents"]];
        [dirs addObject:@"/var/mobile/Documents"];
        for (NSString *dir in dirs) {
            NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
            for (NSString *it in items ?: @[]) {
                if ([it hasPrefix:@"PageTurner"] && [it hasSuffix:@".log"]) {
                    [fm removeItemAtPath:[dir stringByAppendingPathComponent:it] error:nil];
                }
            }
        }
        // sLogPath = nil（下次重新探测）已删：Core 的 sLogFile 由 PTSetLogPath 注入后不再变
    } @catch (NSException *e) {}
}

// 设置页自己的日志写到「共享 jbroot 的 Documents」（PageTurner.log，不带 bundleID）。
// 注意：与 App 侧同目录只是为了清理时一处搞定，不代表设置页要读别人的文件——
// 各 App 的 PageTurner-<bid>.log 只有「勾选生效」的 App 才会写，且由 buildLogItems 按 enabledApps 枚举。
NSString *PTSettingsLogProbePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    NSString *jb = PTJbrootRoot();
    if (jb.length) [cands addObject:[jb stringByAppendingPathComponent:@"var/mobile/Documents"]];
    [cands addObject:@"/var/mobile/Documents"];
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (doc.length) [cands addObject:doc];
    [cands addObject:NSTemporaryDirectory()];
    for (NSString *d in cands) {
        if (!d.length) continue;
        if (![fm fileExistsAtPath:d]) [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm isWritableFileAtPath:d]) return [d stringByAppendingPathComponent:@"PageTurner.log"];
    }
    return nil;
}
