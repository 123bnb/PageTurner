// PTUILogSource.m —— 日志数据源 current 存取（v1.0.77）
#import "PTUILogSource.h"

@implementation PTUILogSource

static id<PTUILogSource> sCurrent = nil;

+ (id<PTUILogSource>)current { return sCurrent; }
+ (void)setCurrent:(id<PTUILogSource>)cur { sCurrent = cur; }

@end
