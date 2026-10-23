// ============================================================
// PTUIDebugLogVC.h —— 调试日志列表页（v1.0.77 共享版）
// 列表内容来自 PTUILogSource.current（deb=文件枚举 / dylib=内存日志单条）
// ============================================================
#ifndef PTUIDebugLogVC_h
#define PTUIDebugLogVC_h

#import "PTUIBaseListVC.h"

@interface PTUIDebugLogVC : PTUIBaseListVC <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *items;   // @[@{@"name":..., @"size":...}]
@end

#endif  // PTUIDebugLogVC_h
