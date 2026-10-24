// ============================================================
// PTEngineLog.m —— 引擎核心·日志（v1.0.78 从 PTEngineCore.m 拆出）
//
// 内容：调试日志家族（PTDylibLog/PTDylibLogLines/PTDylibLogClearLines/
//       PTDylibLogSetEnabled/PTSetLogPath/PTSetFileLogEnabled）+ 单调时钟 PTNowC。
// 开关语义：debugLogEnabled（配置项；关 → PTDylibLog 直接返回，零 IO）；
//       文件落盘需 target 显式 PTSetFileLogEnabled(YES)（默认 NO——没读者的
//       App 写出来只会在 Documents 堆垃圾，详见原注释）。
// 循环上限：内存与文件均 PTLogMaxLines=500 行。
// 依赖：仅 PTDylibCfgPath（PTEngineConfig.m 的公共 API）——本文件不碰内部符号。
// ============================================================
#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <time.h>
#import <stdarg.h>
#import "PTEngineCore.h"
#import "PTEngineInternal.h"

static NSString *kDylibLogName = @"PageTurner.log";   // 兜底名：target 开了文件日志但未用 PTSetLogPath 注入路径时，写 App 容器 Documents
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
