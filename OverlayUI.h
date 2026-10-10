// ============================================================
// OverlayUI.h —— PageTurner 注入 App 内的录制/映射面板接口
// ============================================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ---------- 引擎函数（Tweak.xm 实现，UI 调用） ----------
NSDictionary *PTGetConfig(void);                  // 读当前配置
void PTSaveConfig(NSDictionary *cfg);             // 保存并刷新 + 通知 UI
void PTSetLearning(BOOL on);                      // 开/关学习模式
void PTFinishLearning(NSString *planName);        // 学习完成：写入方案
void PTClearLearning(void);                       // 清空学习样本

// ---------- Overlay 面板 ----------
@interface PTOverlay : NSObject
+ (void)install;                       // constructor 调用，预创建隐藏窗口
+ (void)show;
+ (void)hide;
+ (void)toggle;
+ (BOOL)isVisible;
+ (void)refreshPlans;                  // 配置变化后刷新列表
+ (void)learnFeedback:(int)count dir:(double)dir stable:(BOOL)stable rejected:(NSString *)rejected;
+ (void)learnStable;                   // 稳定：弹命名框
+ (void)learnTooMany;                  // 上限：提示重录
@end
