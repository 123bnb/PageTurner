// PTUIBaseListVC.m —— 共享列表页基类（v1.0.77）
#import "PTUIBaseListVC.h"

@implementation PTUIBaseListVC

- (NSMutableDictionary *)readCfg { return PTUIReadCfg(); }
- (void)writeCfg:(NSDictionary *)cfg { PTUIWriteCfg(cfg); }

- (void)setupGroupedTableWithTop:(CGFloat)top {
    // v1.0.35 起全插件统一的系统设置灰分组背景（与 deb 主设置页一致）
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width,
        self.view.bounds.size.height - top) style:UITableViewStyleGrouped];
    [self.view addSubview:self.tv];
}

// 「返回即刷新」公共语义：每次页面将出现都重读配置（原 deb/dylib 两个方案列表页
// 与特征列表页各写一份 viewWillAppear→reload，合一）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    [self.tv reloadData];
}

@end
