// ============================================================
// PTUICommon.m —— 共享 UI 公共助手实现（v1.0.77）
// ============================================================
#import "PTUICommon.h"
#import "PTUIPlanVC.h"   // PTUIPopToPlanPage 扫栈回退用

NSDictionary *PTUIPlanById(NSArray *plans, NSString *pid) {
    if (!pid) return nil;
    for (NSUInteger i = 0; i < plans.count; i++) {
        id p = plans[i];
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        // 已带 pid 的按字段匹配；旧配置残留（PTUIReadCfg 读时已惰性补发，双保险）
        if ([PTPlanPid(p, (NSInteger)i) isEqualToString:pid]) return p;
    }
    return nil;
}

NSInteger PTUIPlanIndexById(NSArray *plans, NSString *pid) {
    if (!pid) return -1;
    for (NSUInteger i = 0; i < plans.count; i++) {
        id p = plans[i];
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        if ([PTPlanPid(p, (NSInteger)i) isEqualToString:pid]) return (NSInteger)i;
    }
    return -1;
}

void PTUISaveActionToPlan(NSString *planId, NSDictionary *action, NSInteger editIndex) {
    if (!planId || !action) return;
    NSMutableDictionary *cfg = PTUIReadCfg();
    NSMutableArray *plans = [NSMutableArray array];
    NSArray *raw = cfg[@"plans"] ?: @[];
    for (NSUInteger i = 0; i < raw.count; i++) {
        NSDictionary *p = raw[i];
        if ([p isKindOfClass:[NSDictionary class]] && [PTPlanPid(p, (NSInteger)i) isEqualToString:planId]) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
            if (editIndex >= 0 && editIndex < (NSInteger)acts.count) acts[editIndex] = action;
            else [acts addObject:action];
            np[@"actions"] = acts;
            [plans addObject:np];
        } else {
            [plans addObject:p];
        }
    }
    cfg[@"plans"] = plans;
    PTUIWriteCfg(cfg);
}

void PTUIPopToPlansList(UIViewController *from) {
    if (!from) return;
    id<PTUINavigator> nav = PTUINavigator.current;
    if ([nav respondsToSelector:@selector(ptPopToPlansListFrom:animated:)]) {
        [nav ptPopToPlansListFrom:from animated:YES];
    } else {
        [from.navigationController popViewControllerAnimated:YES];
    }
}

// 回方案页：两侧栈里都是共享的 PTUIPlanVC（直接 push，无桥接壳）——扫栈回退即可，
// 不需要 navigator 分叉（deb 的方案页不在壳里：壳只包列表/防抖/日志三个 specifier 入口）
void PTUIPopToPlanPage(UIViewController *from) {
    if (!from) return;
    UINavigationController *nav = from.navigationController;
    if (nav) {
        for (UIViewController *vc in nav.viewControllers) {
            if ([vc isKindOfClass:[PTUIPlanVC class]]) {
                [nav popToViewController:vc animated:YES];
                return;
            }
        }
    }
    [from.navigationController popViewControllerAnimated:YES];
}
