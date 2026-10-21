// ============================================================
// PTDylibMain.m —— PageTurnerDylib 入口（v1.0.20）
//
// 注入即生效：constructor → 主队列安装 hook。
// v1.0.12：不再用手势识别器（会被 App 手势仲裁抢）——双指长按改由
// PTDylibSendEvent（sendEvent 层）检测：两指同时按下 0.5s 不动 → 弹出菜单，
// App 任何页面任何角落都能触发。
// 菜单 = 独立覆盖窗口（UINavigationController 包主菜单）。
// 可视化/录制 = keyWindow 上的覆盖层（不建窗口，不碰状态栏）。
// ============================================================

#import <UIKit/UIKit.h>
#import "PTEngine.h"

// 主菜单类在 PTDylibUI.m 实现
@interface PTDylibMenuVC : UITableViewController
@end

static UIWindow *gMenuWindow = nil;
static dispatch_once_t gInitOnce;

// 找当前 keyWindow（多 scene 兼容）
static UIWindow *PTDylibKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.connectedScenes) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            return [ws.windows firstObject];
        }
    }
    return app.keyWindow ?: app.windows.firstObject;
}

// 关闭菜单（UI 层关闭按钮调用）
void PTDylibCloseMenu(void) {
    if (!gMenuWindow) return;
    UIWindow *w = gMenuWindow;
    gMenuWindow = nil;
    w.hidden = YES;
    w.rootViewController = nil;
    [w removeFromSuperview];
}

// v1.0.12：判断是否菜单窗口（Core 双指检测排除菜单上的触摸）
BOOL PTDylibIsMenuWindow(UIWindow *w) {
    return w == gMenuWindow;
}

// 弹出主菜单（v1.0.12 起由 sendEvent 双指检测调用）
void PTDylibShowMenu(void) {
    if (gMenuWindow) {
        gMenuWindow.hidden = NO;
        return;
    }
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // v1.0.19：iOS13+ 窗口必须绑定 windowScene 才能渲染，否则菜单可能完全不显示
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
            w.windowScene = (UIWindowScene *)scene;
            break;
        }
    }
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = [UIColor systemBackgroundColor];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[PTDylibMenuVC new]];
    w.rootViewController = nav;
    w.hidden = NO;
    gMenuWindow = w;
    PTDylibLog(@"双指长按 → 弹出主菜单");
}

// v1.0.62：关菜单但保留窗口与导航栈（不销毁）。供录制/编辑覆盖层使用：
// 结束后 PTDylibShowMenu() 会重显该窗口，导航栈停留在方案页，而非退回首页。
// 正常的「关闭菜单」(closeTapped) 仍走 PTDylibCloseMenu（销毁），全局行为不变。
void PTDylibHideMenuPreserving(void) {
    if (!gMenuWindow) return;
    gMenuWindow.hidden = YES;   // 仅隐藏，保留 gMenuWindow 与导航栈
}

UIWindow *PTDylibMenuWindow(void) {
    return gMenuWindow;
}

// 注入入口：TrollStore/巨魔注入 dylib 后立即执行
__attribute__((constructor))
static void PTDylibInit(void) {
    dispatch_once(&gInitOnce, ^{
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
                // v1.0.65：巨魔(dylib)形态【不落盘任何日志文件】——不调 PTSetLogPath，也不调
                // PTSetFileLogEnabled(YES)（引擎默认 NO），日志只留在内存（PTDylibLogLines()）。
                // 依据：日志文件 PageTurner-<bid>.log 的唯一读者是 deb 设置页的日志列表，它只枚举 deb
                // 配置里的 enabledApps；而 dylib 用的是自己的容器配置（v1.0.70 起已无该开关、恒为独立容器配置，
                // 无「指定 App 生效」机制、注入即生效），不会有 App 被那个列表枚举到——以前无条件往共享
                // jbroot 写，等于给每个被注入的 App 留一份没有任何代码会读的垃圾文件。
                PTDylibInstallHooks();
                PTDylibLog(@"==================================================");
                PTDylibLog(@"PageTurnerDylib v1.0.65 已注入 %@ (pid=%d) 配置来源=%@ 文件日志=(关闭·仅内存)",
                    bid, getpid(), @"独立配置");
                PTDylibLog(@"配置路径=%@ 防抖=%.0fms 方案数=%lu",
                    PTDylibCfgPath(),
                    [PTDylibReadCfg()[@"debounceMs"] doubleValue] ?: 300,
                    (unsigned long)([PTDylibReadCfg()[@"plans"] count] ?: 0));
                PTDylibLog(@"==================================================");
                    // v1.0.7→v1.0.12：keyWindow 变化（App 切阅读页全屏窗口等）时——
                    // 迁移可视化覆盖层（录制覆盖层已并入统一模板的覆盖窗口，无需迁移）
                    [[NSNotificationCenter defaultCenter]
                        addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                            PTDebugMigrateOverlay();
                        }];
            });
        }
    });
}
