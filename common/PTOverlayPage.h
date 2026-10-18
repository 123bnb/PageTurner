//
//  PTOverlayPage.h
//  统一"新增映射"四页面模板（v1.0.62）
//
//  把 点击 / 双击 / 滑动 / 滑动(手动) 四个页面统一到同一套模板：
//  · 顶部 取消/完成 按钮条（56pt + 安全区兜底）
//  · 背景：dylib=半透明黑 0.4（透出 App）；deb=不透明灰
//  · 内容由 mode 决定：绿点拖拽(tap/doubleTap/swipe) 或 轨迹录制(recSwipe)
//
//  host（deb 设置页 / dylib 浮窗）负责：呈现与移除页面、保存、录制守卫。
//  本类只做 UI 与交互，不碰配置读写、不直连引擎（守卫经回调），便于 deb/dylib 共用。
//
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PTOverlayMode) {
    PTOverlayModeTap = 0,
    PTOverlayModeDoubleTap,
    PTOverlayModeSwipe,
    PTOverlayModeRecSwipe,
};

@interface PTOverlayPage : UIViewController

@property (nonatomic, assign) PTOverlayMode mode;
@property (nonatomic, copy) NSString *planName;
@property (nonatomic, assign) NSInteger editIndex;     // -1=新增；>=0=编辑已有动作
@property (nonatomic, copy) NSDictionary *editAction;
@property (nonatomic, assign) BOOL translucent;         // dylib=YES(半透明，透出 App)；deb=NO(不透明灰)

// host 提供的回调（本类不直连配置/引擎，全部经回调，保证 deb/dylib 共用）
@property (nonatomic, copy) void (^onSave)(NSDictionary *action, NSInteger editIndex, NSDictionary *editAction);
@property (nonatomic, copy) void (^onDismiss)(BOOL saved);   // 由 host 真正移除页面（modal dismiss / 关覆盖层）
@property (nonatomic, copy) void (^recStart)(NSString *mode, double topY, void (^doneUI)(NSArray *pts)); // dylib 必填，deb 传 nil
@property (nonatomic, copy) void (^recStop)(void);            // dylib 必填，deb 传 nil

@end
