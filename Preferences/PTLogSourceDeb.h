// ============================================================
// PTLogSourceDeb.h —— deb 侧调试日志数据源（v1.0.77）
//
// 从 RootListController.m 迁出（原 PTDebugLogVC.buildLogItems / PTClearAllLogs /
// SLogProbePath），实现共享的 PTUILogSource 协议：
//   · logItems：设置页日志 PageTurner.log + 各「勾选生效」App 的运行日志
//     PageTurner-<bid>.log（全部位于共享 jbroot 的 Documents——诊断证实这是
//     App 侧与设置页唯一双向可通的路径）
//   · logContentAtIndex:：读文件尾部 PTLogMaxLines 行
//   · clearAllLogs：删全部 PageTurner*.log + 清内存日志
// 主设置页的日志开关（关=立即清空）与构造函数（PTSetLogPath）复用本文件的
// 两个 extern 函数，行为与旧址逐字一致。
// ============================================================
#ifndef PTLogSourceDeb_h
#define PTLogSourceDeb_h

#import <Foundation/Foundation.h>
#import "PTUILogSource.h"

@interface PTLogSourceDeb : NSObject <PTUILogSource>
@end

/// 关调试日志开关时立即清空全部日志（内存 + 所有 PageTurner*.log 文件）
extern void PTClearAllLogs(void);

/// 设置页日志落盘路径探测（构造函数 PTSetLogPath 用；候选路径全部不可写返回 nil）
extern NSString *PTSettingsLogProbePath(void);

#endif  // PTLogSourceDeb_h
