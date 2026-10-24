// ============================================================
// PTEngineMatch.m —— 引擎核心·匹配（v1.0.78 从 PTEngineCore.m 拆出）
//
// 内容：会话状态全局（sCollectArmed/sTestArmed/sLastSampleAt/sCurSender/
//       sWindowUntil/sSess* 全家/sTestDot/sTestLogSink——UI 层与 hook 跨文件
//       读写，均 PTEngineCore.h extern）、学习样本落盘（PTSampleAppend）、
//       方案唯一身份 pid（PTPlanPid/PTPlanNameForId）、工具（PTDirName/
//       PTActionText/PTFeaturesOfPlan/PTDuplicate/PTStable/PTIsLearnedSender）、
//       运行端匹配（PTMatchPlan，读 gPlans 缓存）与测试端匹配
//       （PTTestMatchFeature，刻意读实时配置）。
// v1.0.74 起匹配/执行全链路按 pid 走（重名方案互不覆盖/串台）。
// ============================================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "PTEngineCore.h"
#import "PTEngineInternal.h"

// ============================================================
// 会话状态（学习/测试，UI 层读写 → extern；外壳 hook 与设置页 hook 跨文件共用）
// v1.0.71：改非静态——设置页 SImpSendEvent 直接驱动同一组状态（每个 Mach-O 镜像各持一份，
//          注入 dylib 与设置 bundle 互不干扰，只通过配置文件通信）。
// ============================================================
BOOL sCollectArmed = NO;
BOOL sTestArmed = NO;
double sLastSampleAt = 0;
UIView *sTestDot = nil;
__weak id sTestLogSink = nil;
// 注：sTestAggActive（记录区聚合行状态）v1.0.78 拆文件时移居 PTEngineTestUI.m——
// 它只被 PTTestLog/PTTestReset 使用，与可视化静态对象同住（原随会话状态块落在此处，
// 跨文件即编译错，见 PTEngineInternal.h 旁的教训）。
uint64_t sCurSender = 0;
double sWindowUntil = 0;
BOOL sSessActive = NO;
double sSessDist = 0, sSessFirstDir = 0;
BOOL sSessHasMove = NO;
CGPoint sSessLast = {0, 0};
CGPoint sSessStart = {0, 0};
double sLastTestExec = 0;      // 测试防抖（v1.0.78 拆文件：PTEngineChain.m 的 PTChainOnHit 读写，声明见 PTEngineInternal.h）

// 学习样本写入 plist（learningSamples，学习页轮询读取）。
// v1.0.71：原 SAppendSample（设置页/引擎各一份）合并为公开 PTSampleAppend；
//          写入走 PTWriteCfg（设置进程经 PTSetCfgWriter 注入双写）。
void PTSampleAppend(int phase, double dir, double dist, int tapDx) {
    NSMutableDictionary *cfg = PTDylibReadCfg();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sCurSender],
        @"phase": @(phase), @"direction": @(dir), @"dist": @(dist),
        @"tapDx": @(tapDx),
    }];
    cfg[@"learningSamples"] = samples;
    PTWriteCfg(cfg);
    PTDylibLog(@"sample: sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d (总数%lu)",
        sCurSender, phase, dir, dist, tapDx, (unsigned long)samples.count);
    sLastSampleAt = PTNowC();
}

// ------------------------------------------------------------
// v1.0.78：工具/匹配区（PTPlanPid…PTIsLearnedSender、PTTestMatchFeature）已下沉
// common/PTCoreLogic.{h,m}（纯逻辑层，Foundation-only，tests/ 在 macOS 原生单测）。
// 本文件只留会话状态全局与学习样本落盘；那些函数经 PTEngineCore.h → PTCoreLogic.h
// 转曝可见，调用方无需改。
// ------------------------------------------------------------
