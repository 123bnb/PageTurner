// ============================================================
// PTEngineChain.m —— 引擎核心·连滑（v1.0.78 从 PTEngineCore.m 拆出）
//
// 内容：连滑状态机（v1.0.67 起 1:1 移植自 DVT v1.0.22，"方向"概念映射为"方案"：
//       同方案=续滑/升档，异方案=刹停）——pill 提示 / 刹停清理 / 未命中 /
//       自动续滑 / 升档 / 蓄力时间窗；执行入口（PTExecutePlan 防抖 +
//       PTExecutePlanRun 起播，PTRunAction 在 PTEngineExec.m）；注入引用计数
//       （PTInjectBegin/PTInjectEnd，v1.0.76）；执行态全局 gIsInjecting。
// v1.0.74 起全程按方案 pid（planId）走，重名方案互不串链。
// ============================================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "PTEngineCore.h"
#import "PTEngineInternal.h"

// ============================================================
// 连滑状态 + 执行态全局（v1.0.78 拆文件落位）
//   连滑状态机全家留本文件；执行态全局按使用者分置——gExecRunning/gInFakeTouch/
//   gExecToken 随假触摸机制在 PTEngineExec.m，gIsInjecting 随注入引用计数留本文件。
//   跨文件读写的两个出口：PTEngineCore.h（公共 API，三目标可见）与
//   PTEngineInternal.h（六个实现文件内部）。
// ============================================================
// v1.0.67：连滑 1:1 移植自 DVT 1.0.22（DirectVolumeTap）——"方向"概念映射为"方案"：
//   同方案 = 同方向（续滑/升档），异方案 = 反方向（刹停）。状态机/刹停/变速/自动续滑/pill 与 DVT 完全一致。
BOOL gChainEnabled = YES;      // 连滑总开关（设置项 chainEnabled；默认开）——PTDylibLoadConfig 检测关开关时断链，extern 见 PTEngineInternal.h
static NSInteger gSwipeBurstCount  = 0;    // 当前窗口内同方案累计命中（含起滑那一次）
static BOOL      gSwipeBurstActive = NO;   // 是否连滑中
static NSString *gSwipeBurstPlan   = nil;  // 连滑归属方案（起滑时锁定，连滑只能是该方案；v1.0.74 起存 pid）
NSInteger gSwipeBurstRate   = 1;    // 连滑倍速档位 1/2/3（DVT v1.0.22：档位不记忆，进/退/刹停复位 1）——PTEngineExec.m 动作提速读，extern 见 PTEngineInternal.h
static double    gSwipeBurstLastAt = 0;    // v1.0.72：最近一次同方案命中时间（蓄力时间窗判定；刹停/生命周期复位清零）
static BOOL      gSwipeStopRequested = NO; // 刹停请求（异方案命中置位，中断在飞回放）
static long      gChainBurstRounds = 0;    // v1.0.73：连滑后自动续滑的轮数（记录区聚合显示用；进入连滑时归零）

// v1.0.67：执行态全局变量（供运行端/测试页/外壳 hook 共用，避免"使用先于定义"；连滑续播/刹停靠这些状态）
// v1.0.71：改非静态——外壳 PTHandlePagerEvent/PTDylibGestureTick/PTReplayTrailAsync 与
//          设置页 SImpSendEvent 跨文件读写（同进程内只有一个引擎镜像，见 PTEngineCore.h 注释）。
// v1.0.78：gIsInjecting 留本文件（与注入引用计数同进出）；gExecRunning/gInFakeTouch/gExecToken 移至 PTEngineExec.m。
BOOL gIsInjecting = NO;
static double gLastExec = 0;   // 普通防抖时间戳（PTExecutePlan 用；仅本文件读取）

// v1.0.76：注入态改引用计数。「方案回放」与「未命中轨迹重放」可并发——未识别按键
// 打断在飞快动作时，重放在旧链中止之前就起来了（PTChainMiss → PTReplayTrailAsync
// 与在飞链的令牌失差是两条时间线）。旧的双 BOOL 直接置位互相踩踏：
//   重放 save 的 prevInjecting=YES → 旧链中止时硬置 NO → 重放结束又 restore YES
//   → gIsInjecting 永久卡 YES（双指长按菜单检测死亡、hook 恒走注入分支）。
// 计数进出成对，归零才真正清零；读取方仍看 gIsInjecting 本身，接口不变。
static int gInjectDepth = 0;
void PTInjectBegin(void) { gInjectDepth++; gIsInjecting = YES; }
void PTInjectEnd(void)   { if (gInjectDepth > 0) gInjectDepth--; if (gInjectDepth == 0) gIsInjecting = NO; }

// ============================================================
// v1.0.67：连滑（1:1 移植自 DVT 1.0.22）——顶部 pill + 刹停/清理 + 生命周期
// ============================================================
// 顶部小胶囊提示（DVT v1.0.17：文案参数化，2 秒自动消失）
// v1.0.67：绿底白字。底色用动态Provider——深色模式下自动换更深的绿，
//   白字在两种模式下都清晰可读（杜绝"背景字体糊成一片"；alpha 保证pill感又不挡内容）。
static UILabel *gChainHint = nil;
static UIColor *PTChainPillBG(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.10 green:0.50 blue:0.23 alpha:0.95];   // 深色模式：深绿，白字对比度高
        }
        return [UIColor colorWithRed:0.18 green:0.73 blue:0.31 alpha:0.90];       // 浅色模式：鲜绿
    }];
}
static void PTChainPill(NSString *msg) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ PTChainPill(msg); }); return; }
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    if (gChainHint) { [gChainHint removeFromSuperview]; gChainHint = nil; }
    CGFloat topInset = (w.safeAreaInsets.top > 0) ? w.safeAreaInsets.top : 20;
    // v1.0.72：绿底按文字测宽收拢（旧版硬编码 240pt 通栏，实测「【　　　　连滑　　　　】」）——
    // 左右各 16pt 内边距，高度 30 / 圆角 15 不变；超长文案封顶屏宽-32。
    UIFont *pillFont = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    NSString *pillText = msg.length ? msg : @"请等待滑动完成";
    CGFloat tw = [pillText boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, 30)
                                        options:NSStringDrawingUsesLineFragmentOrigin
                                     attributes:@{NSFontAttributeName: pillFont} context:nil].size.width;
    CGFloat bw = MIN(ceil(tw) + 32.0, w.bounds.size.width - 32.0);
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake((w.bounds.size.width - bw) / 2.0, topInset + 44, bw, 30)];
    h.text = pillText;
    h.textColor = [UIColor whiteColor];   // v1.0.67：绿底白字（底色随深色模式自适应，见 PTChainPillBG）
    h.textAlignment = NSTextAlignmentCenter;
    h.font = pillFont;   // v1.0.67：半粗体，绿底上更清晰
    h.backgroundColor = PTChainPillBG();
    h.layer.cornerRadius = 15;
    h.layer.masksToBounds = YES;
    [w addSubview:h];
    [w bringSubviewToFront:h];
    gChainHint = h;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gChainHint == h) { [h removeFromSuperview]; gChainHint = nil; }
    });
}

// 刹停/未命中/关开关：清空连滑链（DVT：异方案/退后台/无轨迹时调用；PageTurner 未命中也兜底清理）
void PTChainReset(void) {
    // v1.0.74：gSwipeBurstPlan 存的是 pid，日志显示名经 PTPlanNameForId 取回
    if (gSwipeBurstPlan) PTDylibLog(@"[连滑] 刹停：链「%@」结束（计数 %ld 档位%ld）", PTPlanNameForId(gSwipeBurstPlan), (long)gSwipeBurstCount, (long)gSwipeBurstRate);
    gSwipeBurstActive = NO;
    gSwipeBurstCount = 0;
    gSwipeBurstRate  = 1;
    gSwipeBurstLastAt = 0;   // v1.0.72：时间窗一并清零
    gSwipeStopRequested = NO;
    gSwipeBurstPlan = nil;
}

// 退后台/生命周期：断连滑 + 中断在飞回放（抬手收尾），回前台状态干净（DVT v1.0.22 dvtAppDidEnterBackground）
void PTChainStopAll(void) {
    gSwipeBurstActive = NO;
    gSwipeBurstCount = 0;
    gSwipeBurstRate  = 1;
    gSwipeBurstLastAt = 0;   // v1.0.72：时间窗一并清零
    gSwipeStopRequested = NO;
    gSwipeBurstPlan = nil;
    if (gExecRunning) gExecToken++;   // 中断在飞回放（PTFakeSwipeAsync/... 令牌失配 → 抬手收尾）
}

// v1.0.73：按键「未命中」（按的是没录入的按键）——退出连滑 **且** 立刻停掉在飞动作。
// 语义分两层，缺一不可：
//   ① 清连滑链（PTChainStopAll）→ 自动续滑不再继续；
//   ② gExecToken++ → 在飞回放令牌失配，下一次回调即在最后位置抬手收尾并放弃，
//      当前这一轮动作**立刻停**，而不是播完为止。
// 连滑中触发时补 pill「已退出连滑」，与异方案刹停（PTChainOnHit）表现一致。
// 运行端（PTEngine.m PTHandlePagerEvent）与测试端（PTTestOnEnded）共用本函数 → 两端不可能再漂移。
void PTChainMiss(void) {
    BOOL wasActive = gSwipeBurstActive;
    PTChainStopAll();
    if (!wasActive) return;                     // 非连滑：只停动作，无需提示
    PTChainPill(@"已退出连滑");
    if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) {
        [sTestLogSink appendLog:@"✗ 未命中按键 → 已退出连滑（动作已停）"];
    }
}

// 实际执行方案动作序列（无防抖）。v1.0.67：DVT 式连滑——进连滑后收尾处自动调用本函数实现无缝续滑。
// v1.0.74：入参 name → planId（pid）。gPlans 按 pid 索引；测试链路读实时配置生成的 pid
// 可能还没进缓存（UI 刚改完配置、mtime 未刷新）→ 查不到时强制刷新一次再查，仍查不到
// 才放弃（配置被删/被改坏），不留半启动的脏状态。
static void PTExecutePlanRun(NSString *planId) {
    NSDictionary *p = gPlans[planId];
    if (!p) {
        PTDylibLoadConfig(YES);   // 强制重读（跳过 mtime 判断）+ 补发 pid
        p = gPlans[planId];
        if (!p) { PTDylibLog(@"[执行] 方案 %@ 不存在（配置已变更？），放弃本次执行", planId); return; }
    }
    NSArray *actions = p[@"actions"] ?: @[];
    NSString *pname = PTPlanNameForId(planId);
    if (!actions.count) { PTDylibLog(@"[执行] %@ 无动作，跳过", pname); return; }
    gExecToken++;   // 全新启动递增令牌（刹停/异常中止时令在飞手势令牌失配 → 抬手收尾）
    int token = gExecToken;
    PTInjectBegin();   // v1.0.76：引用计数进入（旧为 gIsInjecting = YES）
    gExecRunning = YES;
    PTDylibLog(@"[执行] 命中 %@，开始动作序列（%lu 条，档位 %ld）", pname, (unsigned long)actions.count, (long)gSwipeBurstRate);
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (token != gExecToken) {   // 令牌失配（刹停/异常中止）→ 不再续播，复位在飞标记
            PTInjectEnd();   // v1.0.76：引用计数退出（旧为 gIsInjecting = NO）
            gExecRunning = NO;
            return;
        }
        if (idx >= (int)actions.count) {
            PTInjectEnd();   // v1.0.76：引用计数退出（旧为 gIsInjecting = NO）
            gExecRunning = NO;
            PTDylibLog(@"[执行] %@ 序列完成", pname);
            // v1.0.67：DVT 式自动续滑——连滑中且未刹停 → 立即重开同方案（无缝重复，无需再按键）
            if (gSwipeBurstActive && gChainEnabled && !gSwipeStopRequested) {
                PTDylibLog(@"[连滑] 自动续滑「%@」（档位 %ld）", pname, (long)gSwipeBurstRate);
                // v1.0.73：自动续滑此前绕过"按键→匹配→记录"整条 UI 链路，达成连滑后记录区完全
                // 静默——用户无从确认连滑是否真在跑、跑了几轮、当前几档。逐轮 append 会刷屏
                // （点击类一轮约 80ms），故聚合为同一行原地改写。
                gChainBurstRounds++;
                PTTestLog(YES, [NSString stringWithFormat:@"⟳ 续滑中… 第 %ld 轮  档位 ×%ld",
                    (long)gChainBurstRounds, (long)gSwipeBurstRate]);
                PTExecutePlanRun(planId);
            }
            return;
        }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// 执行方案动作序列（对外入口，含普通防抖）。自动续滑由 PTExecutePlanRun 收尾处直接触发，不经过此处防抖。
// v1.0.72：force=YES 跳过防抖——仅用于"刚刚进入连滑的那一次按键"：时间窗蓄力修好后，
// 激活连滑的那一击距上次起播往往不足一个防抖周期，被挡下就会出现「已进入连滑」却没有
// 回放在跑的假连滑。
// v1.0.74：name → planId（pid）。
static void PTExecutePlan(NSString *planId, BOOL force) {
    double now = PTNowC();
    if (!force && now - gLastExec < gDebounceMs / 1000.0) {
        PTDylibLog(@"[执行] 防抖：忽略 %@（%.0fms 内已执行）", PTPlanNameForId(planId), gDebounceMs);
        return;
    }
    gLastExec = now;
    PTExecutePlanRun(planId);
}

// v1.0.72：蓄力提示——只在最后两档出现（4/5 与 已进入连滑）。实测反馈：前 3 下也提示
// 会把"按得快"误报成"要连滑"，且从 1/5 起步的倒数没有信息量（真连滑用户自己会按满 5 下）。
// 返回 YES = 本次刚刚进入连滑（调用方在空闲路径上必须放行防抖强行起播，否则链激活了
// 却没有回放在跑 = 假连滑）。
static BOOL PTChainChargePill(void) {
    if (!gChainEnabled) return NO;
    if (gSwipeBurstCount >= kSwipeBurstThreshold) {
        if (!gSwipeBurstActive) {
            gSwipeBurstActive = YES;
            gSwipeBurstRate   = 1;
            gChainBurstRounds = 0;   // v1.0.73：续滑轮数从头计（用户按的那 5 次不算续滑轮）
            PTChainPill(@"已进入连滑");
            // v1.0.73：记录区留痕——此前「已进入连滑」只在顶部 pill 一闪而过，
            // 返回即消失，事后在记录区查不到任何连滑痕迹。
            PTTestLog(NO, @"★ 已进入连滑 —— 自动续滑接管，档位 ×1");
            return YES;
        }
        return NO;
    }
    if (gSwipeBurstCount == kSwipeBurstThreshold - 1) {
        PTChainPill([NSString stringWithFormat:@"连滑 %ld/%d", (long)gSwipeBurstCount, kSwipeBurstThreshold]);
    }
    return NO;
}

// v1.0.72：连滑命中判定统一入口——测试页（PTTestExecPlan）与运行端（PTChainHandleHit）
// 共用。此前两处各写一份，已两次漂移（v1.0.71：设置页侧旧版无连滑逻辑；v1.0.72：测试区
// 执行期被 hook 吞按键 + 蓄力窗口只认"回放中"）。残留差异仅：测试页多一道 0.3s 防抖与日志前缀。
//
// v1.0.72 蓄力窗口改时间窗（kSwipeBurstWindowSec = 1.2s，兑现设置页文案承诺）：
//   旧版窗口 = "回放中"（gExecRunning）。点击/双击等快动作 80~230ms 就播完，用户第二次
//   按键到来时早已回落空闲路径 → 计数重置为 1 → 永远蓄不满 5 次（实测：连滑只对
//   滑动(手动)类慢动作生效）。现在同方案 1.2s 内的命中都累计，快动作同样能进连滑
//   （自动续滑对点击即高频连击）。
//
// v1.0.74：plan → planId（方案 pid）。gSwipeBurstPlan 同步改存 pid——同方案判定
// （samePlan）按 pid 比较，重名的两个方案不会再被误判为"同一个"而续滑/升档。
void PTChainOnHit(NSString *planId, BOOL viaTest) {
    double now = PTNowC();
    BOOL samePlan = [gSwipeBurstPlan isEqualToString:planId];

    if (gExecRunning) {   // 回放中 = 连按累计窗口（只累计/升档/刹停，不起新动作）
        if (!samePlan) {
            // 异方案 = 刹停：立即中断当前滑剩余帧 + 退连滑 + 档位复位（DVT v1.0.22）
            BOOL wasActive = gSwipeBurstActive;
            NSString *oldName = PTPlanNameForId(gSwipeBurstPlan);   // v1.0.74：被刹停的旧链（pid→name）
            NSString *newName = PTPlanNameForId(planId);            // v1.0.74：新按的方案（pid→name）
            gSwipeBurstActive = NO; gSwipeBurstCount = 0; gSwipeBurstRate = 1;
            gSwipeBurstLastAt = 0;                    // v1.0.72：时间窗清零，旧链不能跨刹停续接
            gSwipeStopRequested = YES; gExecToken++;  // 中断在飞回放（令牌失配 → 抬手收尾）
            PTDylibLog(viaTest ? @"[测试] 异方案「%@」→ 刹停「%@」" : @"[连滑] 异方案「%@」→ 刹停「%@」", newName, oldName);
            if (wasActive) {
                PTChainPill(@"已退出连滑");
                // v1.0.73：记录区关键事件独占一行（并打断续滑聚合行）
                PTTestLog(NO, [NSString stringWithFormat:@"✗ 刹停（异方案「%@」）→ 已退出连滑", newName]);
            }
            return;
        }
        if (gSwipeBurstActive) {
            // 连滑中按同方案 = 升档 1→2→3→1 循环，对下一段滑生效（DVT v1.0.22）
            gSwipeBurstRate = (gSwipeBurstRate >= 3) ? 1 : gSwipeBurstRate + 1;
            // v1.0.67：与运行端一致——⚡雷电样式「⚡连滑 ×1/×2/×3」（选项 i：仍走 DVT 1/2/3 档）
            PTChainPill([NSString stringWithFormat:@"⚡连滑 ×%ld", (long)gSwipeBurstRate]);
            // v1.0.73：升档是档位变化的时刻，独占一行（升档后的续滑另起一行重新开始聚合）
            PTTestLog(NO, [NSString stringWithFormat:@"⚡ 升档 → ×%ld", (long)gSwipeBurstRate]);
            return;
        }
        if (!gChainEnabled) return;   // 总开关关闭：窗口期按压静默忽略
        // 普通窗口期：同方案累计，达阈值即进入连滑（v1.0.72：时间窗内快动作也能走到这）
        gSwipeBurstCount++;
        gSwipeBurstLastAt = now;
        PTChainChargePill();
        return;
    }

    // 空闲：本次命中要起一个新动作。v1.0.72：时间窗内同方案续接计数（不再因"回放已结束"复位）
    BOOL windowAlive = gChainEnabled && samePlan && (now - gSwipeBurstLastAt) < kSwipeBurstWindowSec;
    if (windowAlive) {
        gSwipeBurstCount++;
    } else {
        gSwipeBurstCount = gChainEnabled ? 1 : 0;
        gSwipeBurstPlan  = planId;   // v1.0.74：锁定 pid（重名方案互不串链）
        gSwipeBurstRate  = 1;
    }
    gSwipeStopRequested = NO;   // 已无在飞回放，旧刹停请求作废
    gSwipeBurstLastAt = now;
    BOOL justActivated = PTChainChargePill();
    if (!viaTest) PTDylibLog(@"[会话] 命中「%@」→ 起映射（原始滑动已整段吞掉）", PTPlanNameForId(planId));
    if (justActivated) {
        // 刚进连滑：两道防抖都放行，强行起播（激活那一击被防抖挡下 = 假连滑）
        if (viaTest) sLastTestExec = now;
        PTExecutePlan(planId, YES);
        return;
    }
    if (viaTest) {
        // 测试页防抖只挡"重复起播"，不挡连滑计数（计数在上面已累计）
        if (now - sLastTestExec < 0.3) { PTDylibLog(@"[测试] 防抖：忽略本次起播（连滑计数已累计）"); return; }
        sLastTestExec = now;
    }
    PTExecutePlan(planId, NO);   // 测试页走与运行端完全相同的回放路径，验证即所见
}

// v1.0.72：运行端命中方案后的连滑判定 + 起执行（外壳 PTHandlePagerEvent 调用）。
// 逻辑与测试页共用 PTChainOnHit，差异仅 viaTest=NO（无测试页 0.3s 防抖）。
// v1.0.74：入参为方案 pid（PTMatchPlan 返回值），不再按 name 匹配。
// 调用方（外壳 PTHandlePagerEvent）负责：gSessTrail 清理 / 未命中时 PTReplayTrailAsync 重放。
void PTChainHandleHit(NSString *planId) {
    PTChainOnHit(planId, NO);
}

