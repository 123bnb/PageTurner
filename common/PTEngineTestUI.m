// ============================================================
// PTEngineTestUI.m —— 引擎核心·测试可视化（v1.0.78 从 PTEngineCore.m 拆出）
//
// 内容（v1.0.66(#3) 富版；v1.0.71 从 RootListController.m 迁入 Core，
//       该版比引擎侧旧版新，取设置页版）：起点绿点 + 方向线 + 终点 P 标记 +
//       滑动(手动)回放连续尾巴（令牌防串场）+ 实时记录区（PTTestLog：续滑进度
//       聚合行 / 关键事件独占行）+ 测试页退出一键复位（PTTestReset）。
// 可视化对象（sTestLine/sTestP/sTestTrail/sTestTrailToken/sTestAggActive）
// 归本文件所有——设置页/dylib 测试页不得直接摸，经 PTTestShowDot/PTTestReset 出入。
// ============================================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "PTEngineCore.h"
#import "PTEngineInternal.h"

// ============================================================
// 测试可视化（v1.0.66(#3) 富版：起点绿点 + 方向线 + 终点 P 标记 + 滑动(手动)连续尾巴）
// v1.0.71：从 RootListController.m 迁入 Core（该版比引擎侧旧版更新，取设置页版；
//          原引擎 PTTestShowDot 只有移动绿点，已删除）。dylib 测试页随之获得同款可视化。
// ============================================================
static CAShapeLayer *sTestLine = nil;   // 方向线
static UIView *sTestP = nil;            // 终点 P 标记
// v1.0.78 拆文件：sTestTrail/sTestTrailToken 原为 static，但 PTEngineExec.m 的
// PTFakeRecSwipeAsync 要直接追加/作废（逐帧画尾巴 + 中断收尾）→ 升为 extern，
// 声明见 PTEngineInternal.h；定义仍只此一处。
NSMutableArray *sTestTrail = nil;   // 滑动(手动)回放尾巴轨迹点（起点→…→当前）
int sTestTrailToken = 0;         // 尾巴淡出令牌（防止上一段回放的余留淡出误清当前轨迹）
// v1.0.73：记录区最后一行是否为"聚合行"（连滑续滑进度行）——v1.0.78 拆文件时从
// PTEngineMatch.m 的会话状态块移居本文件（只被 PTTestLog/PTTestReset 使用）。
static BOOL sTestAggActive = NO;

// v1.0.34：方案特征集合（新格式 features[] 数组；兼容旧格式单条 feature）→ 已上移 PTFeaturesOfPlan

// 懒建 sTestLine / sTestP 覆盖层（供 PTTestShowDot 与滑动尾巴渲染共用）
static void PTTestEnsureOverlay(void) {
    if (!sTestDot || !sTestDot.superview) return;
    UIView *parent = sTestDot.superview;
    if (!sTestLine) {
        sTestLine = [CAShapeLayer layer];
        sTestLine.strokeColor = [UIColor systemGreenColor].CGColor;
        sTestLine.fillColor = [UIColor clearColor].CGColor;
        sTestLine.lineWidth = 3; sTestLine.lineCap = kCALineCapRound;
        sTestLine.lineJoin = kCALineJoinRound;
        [parent.layer addSublayer:sTestLine];
    }
    if (!sTestP) {
        sTestP = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        sTestP.layer.cornerRadius = 18;
        sTestP.backgroundColor = [UIColor systemGreenColor];
        sTestP.userInteractionEnabled = NO; sTestP.hidden = YES;
        UILabel *pl = [[UILabel alloc] initWithFrame:sTestP.bounds];
        pl.text = @"P"; pl.textAlignment = NSTextAlignmentCenter;
        pl.font = [UIFont boldSystemFontOfSize:18]; pl.textColor = [UIColor whiteColor];
        [sTestP addSubview:pl];
        [parent addSubview:sTestP];
    }
}

// 轨迹可视化统一成「调试可视化同款」——起点绿点 + 方向线 + 终点 P 标记（真实坐标）。
// 本函数画「单段手势」（tap / 直线 swipe），from→to 是一条直线；滑动(手动)的连续尾巴见 PTTestDrawTrailHead。
void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur) {
    if (!sTestDot) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTTestEnsureOverlay();
        if (!sTestDot.superview) return;
        // 起点绿点
        sTestDot.hidden = NO; sTestDot.alpha = 0.9; sTestDot.center = from;
        // 终点 P + 方向线（from→to）
        sTestP.hidden = NO; sTestP.alpha = 0.95; sTestP.center = to;
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, from.x, from.y);
        CGPathAddLineToPoint(path, NULL, to.x, to.y);
        sTestLine.path = path; CGPathRelease(path);
        // 渐隐收尾：swipe 按其时长保留，tap 短暂保留
        double hold = animate ? MAX(dur, 0.3) : 0.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((hold + 0.4) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sTestDot.alpha = 0; sTestDot.hidden = YES;
            sTestP.alpha = 0; sTestP.hidden = YES; sTestLine.path = nil;
        });
    });
}

// 滑动(手动)回放逐帧把当前点追加进「尾巴」折线（起点→…→当前）并渲染，绿点移到当前、P 隐藏。
void PTTestDrawTrailHead(CGPoint cur) {
    if (!sTestDot) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTTestEnsureOverlay();
        if (!sTestDot.superview) return;
        if (!sTestTrail) sTestTrail = [NSMutableArray array];
        [sTestTrail addObject:[NSValue valueWithCGPoint:cur]];
        CGMutablePathRef path = CGPathCreateMutable();
        BOOL first = YES;
        for (NSValue *v in sTestTrail) {
            CGPoint pt = [v CGPointValue];
            if (first) { CGPathMoveToPoint(path, NULL, pt.x, pt.y); first = NO; }
            else CGPathAddLineToPoint(path, NULL, pt.x, pt.y);
        }
        sTestLine.path = path; CGPathRelease(path);
        sTestDot.hidden = NO; sTestDot.alpha = 0.9; sTestDot.center = cur;
        if (sTestP) sTestP.hidden = YES;
    });
}

// 滑动(手动)回放结束——终点显示 P，整条尾巴保留 hold 时长后淡出（用令牌防串场）
void PTTestTrailFinish(CGPoint pN, double hold) {
    if (!sTestDot) return;
    int myToken = sTestTrailToken;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTTestEnsureOverlay();
        if (!sTestDot.superview) return;
        if (sTestP) { sTestP.hidden = NO; sTestP.alpha = 0.95; sTestP.center = pN; }
        double h = MAX(hold, 0.3);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((h + 0.4) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (myToken != sTestTrailToken) return;   // 已有新回放开始，不要误清当前轨迹
            sTestDot.alpha = 0; sTestDot.hidden = YES;
            if (sTestP) { sTestP.alpha = 0; sTestP.hidden = YES; }
            sTestLine.path = nil;
            sTestTrail = nil;
        });
    });
}

// v1.0.73：测试页实时记录区写入。
//   agg=YES → 原地改写最后一行（连滑续滑进度，同一行数字不断跳动）
//   agg=NO  → 另起一行（关键事件：进入连滑 / 升档 / 刹停 / 命中 / 未命中）
// 逐轮 append 会在数秒内刷爆记录区（点击类一轮约 80ms，5 秒就有 60+ 行），
// 故续滑进度必须聚合到同一行；关键事件才配独占一行。
void PTTestLog(BOOL agg, NSString *s) {
    if (!sTestLogSink) { sTestAggActive = NO; return; }   // 运行端无测试页 → 静默跳过
    if (agg && sTestAggActive && [sTestLogSink respondsToSelector:@selector(updateLastLog:)]) {
        [sTestLogSink updateLastLog:s];
        return;
    }
    if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) [sTestLogSink appendLog:s];
    sTestAggActive = agg;   // agg=NO 表示聚合被关键事件打断，下次续滑要另起一行
}

// v1.0.71：测试页退出一键复位——armed/绿点/方向线/P 标记/尾巴/实时记录区一并清理，
// 并作废在飞的尾巴淡出回调（令牌）。替代设置页/dylib 各自 viewDidDisappear 里
// 直接摸 Core 静态可视化对象的旧写法（那些静态现已归 Core 所有）。
void PTTestReset(void) {
    sTestArmed = NO;
    sTestDot = nil;
    if (sTestLine) { [sTestLine removeFromSuperlayer]; sTestLine = nil; }
    if (sTestP) { [sTestP removeFromSuperview]; sTestP = nil; }
    sTestTrail = nil;
    sTestLogSink = nil;
    sTestAggActive = NO;   // v1.0.73：记录区聚合行状态一并复位
    sTestTrailToken++;   // 作废上一段回放余留的淡出
    // v1.0.72：测试页退场 = 连滑链终结。连滑激活后是"自动无限续滑"，不会因为离开
    // 测试页而停——不清理的话 fake 触摸会继续打进设置界面。时间窗蓄力修复后快动作
    // （点击/双击）也能进连滑，此清理从"可选"变为"必须"。
    PTChainStopAll();
}
