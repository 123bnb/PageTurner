// ============================================================
// PTUILogSource.h —— 调试日志数据源协议（v1.0.77）
//
// 共享的 PTUIDebugLogVC / PTUILogContentVC 不区分日志从哪来：
//   · deb（roothide）：枚举共享 jbroot 的 Documents——设置页日志 PageTurner.log
//     + 各「勾选生效」App 的运行日志 PageTurner-<bid>.log（文件）
//   · dylib（巨魔）：v1.0.65 起不落盘任何文件，只有内存日志 PTDylibLogLines()
// 两侧各自实现本协议，共享页零 #ifdef。
// ============================================================
#ifndef PTUILogSource_h
#define PTUILogSource_h

#import <Foundation/Foundation.h>

@protocol PTUILogSource <NSObject>
- (NSArray<NSDictionary *> *)logItems;             // @[@{@"name":显示名, @"size":@(字节)}]
- (NSString *)logContentAtIndex:(NSInteger)i;      // 第 i 份内容（尾部最多 PTLogMaxLines 行）
- (BOOL)canClearLogs;                              // 是否可清空（两侧均为 YES）
- (void)clearAllLogs;                              // 清空（deb=删文件+清内存；dylib=清内存）
@end

@interface PTUILogSource : NSObject
@property (class, nonatomic, strong) id<PTUILogSource> current;   // 各 target 启动时设一次
@end

#endif  // PTUILogSource_h
