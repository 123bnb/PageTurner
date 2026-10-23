// ============================================================
// PTUIBaseListVC.h —— 共享列表页基类（v1.0.77）
//
// 8 个共享 VC 的共同底座：
//   · readCfg / writeCfg：统一走 Core 的 PTUIReadCfg / PTUIWriteCfg
//     （读含 pid 惰性补发；写经注入写入器——deb 双写 / dylib 容器单写）
//   · setupGroupedTableWithTop:：系统设置同款灰分组背景 + 分组表格
//   · viewWillAppear 自动 [self reload]（设置页「返回即刷新」的公共语义；
//     子类覆写 reload，默认实现只刷新表格——无表格的页（学习/测试/参数/防抖）
//     覆写为空操作或沿用均无害）
// ============================================================
#ifndef PTUIBaseListVC_h
#define PTUIBaseListVC_h

#import <UIKit/UIKit.h>
#import "PTEngineCore.h"

@interface PTUIBaseListVC : UIViewController

@property (nonatomic, strong) UITableView *tv;

// 配置读写（子类/外部均可用；内部即 Core 入口）
- (NSMutableDictionary *)readCfg;
- (void)writeCfg:(NSDictionary *)cfg;

// 视图搭建：灰分组背景 + 从 top 起的全宽分组表格（dataSource/delegate 由子类自设）
- (void)setupGroupedTableWithTop:(CGFloat)top;

// 子类覆写：读数据 + [super reload]（基类实现 = tv reloadData，tv 为 nil 时安全）
- (void)reload;

@end

#endif  // PTUIBaseListVC_h
