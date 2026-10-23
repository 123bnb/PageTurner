// ============================================================
// PTUIDebugLogVC.m —— 调试日志列表页实现（v1.0.77 共享版）
//
// 统一前：deb 是「文件列表 → 内容页」（设置页日志 + 各生效 App 运行日志），
// dylib 是「直接显示内存日志 200 行」。统一后列表经 PTUILogSource 抽象：
// deb 源=枚举文件（buildLogItems），dylib 源=内存日志单条；行数统一 500
// （PTLogMaxLines，dylib 旧版 200——大诊断场景截断太早）。
// ============================================================
#import "PTUIDebugLogVC.h"
#import "PTUILogContentVC.h"   // didSelect → 日志内容页
#import "PTUICommon.h"

@implementation PTUIDebugLogVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"调试日志";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    id<PTUILogSource> src = PTUILogSource.current;
    self.items = [src respondsToSelector:@selector(logItems)] ? [src logItems] : @[];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"PTLogCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:ID];
    if (!c) {
        // v1.0.60：不用系统 textLabel/detailTextLabel（会与自定义布局重叠），改为自己放两层
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
        c.textLabel.text = nil;
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectZero];
        sv.tag = 900; sv.showsHorizontalScrollIndicator = NO;
        UILabel *lb = [[UILabel alloc] init];
        lb.tag = 901; lb.font = [UIFont systemFontOfSize:15]; lb.textColor = [UIColor labelColor];
        [sv addSubview:lb];
        [c.contentView addSubview:sv];
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectZero];
        sub.tag = 902; sub.font = [UIFont systemFontOfSize:12]; sub.textColor = [UIColor secondaryLabelColor];
        [c.contentView addSubview:sub];
    }
    NSDictionary *it = self.items[ip.row];
    unsigned long long sz = [it[@"size"] unsignedLongLongValue];
    NSString *szTxt = sz >= 1024 ? [NSString stringWithFormat:@"%.1f KB", sz / 1024.0]
                                 : [NSString stringWithFormat:@"%llu B", sz];
    CGFloat w = self.view.bounds.size.width - 56;
    UIScrollView *sv = [c.contentView viewWithTag:900];
    UILabel *lb = [sv viewWithTag:901];
    lb.text = it[@"name"];
    [lb sizeToFit];
    sv.frame = CGRectMake(16, 9, w, lb.bounds.size.height);
    sv.contentSize = CGSizeMake(MAX(lb.bounds.size.width, w), lb.bounds.size.height);
    UILabel *sub = [c.contentView viewWithTag:902];
    sub.text = sz > 0 ? [NSString stringWithFormat:@"%@ · 点击查看", szTxt] : @"暂无内容（还没产生日志）";
    sub.frame = CGRectMake(16, 31, w, 15);
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 56; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    PTUILogContentVC *vc = [PTUILogContentVC new];
    vc.logIndex = ip.row;
    vc.logTitle = self.items[ip.row][@"name"];
    [self.navigationController pushViewController:vc animated:YES];
}
@end
