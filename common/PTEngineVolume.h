// ============================================================
// PTEngineVolume.h —— 音量键机制（v1.0.80 新增）
//
// 整套移植 DirectVolumeTap v1.0.18~v1.0.22 音量基线，实现细节与 DVT 源码
// 逐条对照见 PTEngineVolume.m 头注释。对外只暴露「启停 + HUD 热应用」——
// 触发链路（KVO → 去抖 → 估算 → PTChainHandleHitVolume → PTChainOnHit）
// 全部内封闭，调用方零感知。
// ============================================================
#ifndef PTEngineVolume_h
#define PTEngineVolume_h

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// 运行端配置缓存（PTDylibLoadConfig 读写；UI 侧不直接读这两个，走 PTUIReadCfg）
extern BOOL gVolEnabled;      // 音量键模式总开关（volEnabled，默认关）
extern BOOL gVolHudHidden;    // 隐藏系统音量条（volHudHidden，默认开）

extern void PTVolumeStart(void);            // 注册 KVO/音频会话/前后台通知（幂等；内部判 gVolEnabled；主队列执行）
extern void PTVolumeStop(void);             // 反注册（总闸关闭时 PTDylibLoadConfig 调）
extern void PTVolumeApplyHud(BOOL hidden);  // UI 改「隐藏音量条」时热应用（挂/摘离屏 MPVolumeView）

#endif  // PTEngineVolume_h
