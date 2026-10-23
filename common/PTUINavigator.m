// PTUINavigator.m —— 导航协议 + current 存取（v1.0.77）
#import "PTUINavigator.h"

@implementation PTUINavigator

static id<PTUINavigator> sCurrent = nil;

+ (id<PTUINavigator>)current { return sCurrent; }
+ (void)setCurrent:(id<PTUINavigator>)cur { sCurrent = cur; }

@end
