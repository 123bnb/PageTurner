// ============================================================
// PTUILogContentVC.m —— 单份日志内容页实现（v1.0.77 共享版）
// 内容经 PTUILogSource.current logContentAtIndex: 取（deb=读文件尾部 500 行；
// dylib=内存日志尾部 500 行——统一为 PTLogMaxLines，旧 dylib 200 行截断太早）
// ============================================================
#import "PTUILogContentVC.h"
#import "PTUICommon.h"

@implementation PTUILogContentVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.logTitle.length ? self.logTitle : @"日志";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:tv];

    NSString *s = nil;
    id<PTUILogSource> src = PTUILogSource.current;
    if ([src respondsToSelector:@selector(logContentAtIndex:)]) s = [src logContentAtIndex:self.logIndex];
    tv.text = s.length ? s : @"暂无日志内容。\n\n可能原因：该 App 还没产生日志，或调试日志开关被关闭（关闭会清空全部日志）。";

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制"
        style:UIBarButtonItemStyleDone target:self action:@selector(copyLog)];
}

- (void)copyLog {
    UITextView *tv = [self.view.subviews firstObject];
    if ([tv isKindOfClass:[UITextView class]]) UIPasteboard.generalPasteboard.string = tv.text;
}
@end
