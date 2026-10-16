// ============================================================
// PageTurner v1.0.55 —— 翻页器按键拦截（学习模式 + 映射 + 动作执行）
//
// v1.0.55（本次变更）：
//   1. 【滑动(手动)】回放照搬 DirectVolumeTap 的 DVTFakeSwipe：CADisplayLink + 二分时间插值，
//      顺滑跟手、对齐 VSync；删除旧跨进程手动录制链路（recRequest/recResult 覆盖层那一套），
//      录制改由设置页进程内灰色背景录制器完成。
//   2. 统一全部轨迹：以调试可视化轨迹为唯一基准（lineWidth 4 绿折线 + 绿点 + P 标记）。
//   3. 调试日志关闭时清空（由设置页 setPreferenceValue 处理）。
//
// v1.0.49（状态栏修复）：插件可视化窗口（windowLevel 高于状态栏且永驻）会接管 iOS 状态栏
//   样式，导致时间/信号电池颜色不再跟随 App → 覆盖窗口 VC 改为状态栏样式透传（跟随当前
//   keyWindow），可视化开关关掉时销毁窗口。
//
// v1.0.48（删除音量动作类型）：音量+/音量-/静音切换整体删除——第三方 App 进程无激活
//   音频会话时，系统音量读取接口（AVSystemController get / AVAudioSession.outputVolume /
//   MPVolumeView slider 同步读）全部返回假值（v1.0.44-47 四次实测），写也只能靠异步
//   slider 兜底 → 止损删除。旧配置兼容：已保存映射里的音量动作执行时被 PTRunAction
//   默认分支跳过（不崩溃）；设置页不再提供这三个动作类型。
//
// v1.0.43（防抖严谨化 + 可视化只画实际收到的触摸 + 滑动速度默认 1000）：
//   1. 防抖严谨化（根除狂按打断滑动）：新增 gExecRunning——序列执行中一律忽略新按键，
//      不再只看「距上次执行开始 < 防抖间隔」。旧版只在执行开始记 gLastExec，长滑动
//      （执行时长 > 防抖间隔）期间按新键会越过防抖去中断旧序列 → 滑动残缺/掐死的根因；
//      现在执行窗口也被防抖覆盖，序列不可能被新键掐断（v1.0.39 弃置中断、v1.0.40 静止
//      衰减、v1.0.41 Began 延迟 40ms 等修复保留作纵深防御，正常情况下不再被触发）
//   2. 调试可视化：只画「App 实际收到的触摸」——被整段吞掉的翻页器原始轨迹不再可见
//      （原代码在拦截判定前对所有触摸画点，命中执行时原始轨迹 + 注入轨迹同时可见，
//      误以为拦截没吞干净）；注入动作 / 未命中重放 / 手指触摸照常画点
//   3. 未命中重放补 gInFakeTouch：PTReplayTrailAsync 注入的合成触摸此前没置
//      gInFakeTouch，0.4s 窗口内会被 PTHandlePagerEvent 当成翻页器会话再次吞掉
//      → 重放被掐死 / 甚至反复重放；现与 PTFakeTap 一致，注入期间精确放行
//   4. 滑动速度默认 1000pt/s（新动作在设置页存 1000；旧动作缺 speed 字段兜底 1000）
//
// v1.0.39（滑动参数上限 + 回滑防惯性 + 弃置式中断修复）：
//   1. 弹起停留上限 500→2000ms；滑动分段上限 48→96（两处钳制同步）
//   2. 滑动动作新增回滑防惯性：backPt（0~10pt，0=不启用）+ backMs（0~500ms，默认80）
//      ——backPt>0 时到终点往回滑 backPt pt（30ms 后 Moved）再停 backMs 再 Ended，
//      Ended 时刻速度反向 → 防惯性比纯停顿更稳；backPt=0 走原地弹起停留 liftMs
//   3. 弃置式中断修复（根除"连按滑动越来越短"）：执行中按新键 → 旧滑动 token 失效时
//      立即在最后实际位置 Ended 复位（触摸不悬空）→ 新滑动干净开始；
//      runNext 被替代时不再误清新序列的 gIsInjecting
//
// v1.0.40（惯性修复：时间插值 + 静止衰减）：
//   1. 时间插值——滑动位置按真实经过时间算（帧间隔 max(16ms, 分段间隔)），主线程再忙速度也均匀
//   2. 静止衰减——到终点（或回滑终点）后每帧(~16ms)发位置不变的 Moved，持续 max(停顿,300)ms
//      再 Ended：模拟真实手指停住，手势速度采样窗口被"没动"填满 → velocity=0 → 弹起无惯性
//      （修"弹起停留 2000ms/回滑 10pt 都还惯性"的根因：我们停住期间不发事件，速度采样停在高速度上）
//
// v1.0.41（狂按根因修复 + 固定 60fps + 防惯性开关，删回滑）：
//   1. 狂按修复——滑动 Began 延迟 40ms：弃置式下旧滑动（同触摸 id=1）的复位 Ended 先发出（≤16ms），
//      新触摸才 Began；否则迟到的 Ended 会把刚 Began 的新触摸掐死 → 连按滑动残缺（日志实锤）
//   2. 固定 16ms 一帧（60fps 采样）——不再随"滑动分段"变大（12 段时 62ms/帧，主线程一抖
//      轨迹点间距忽大忽小→视觉速度不均）；位置仍按真实时间插值 → 点密且间距均匀
//   3. 【防惯性】显式开关 noInertia（默认开）：开=终点静止衰减 300ms+→弹起无惯性；
//      关=干净利落（停 liftMs 直接弹起，有轻微惯性用户自担）；回滑距离/回滑停顿参数已删除
//
// v1.0.42（调试日志总开关 + 日志上限）：debugLogEnabled（设置页「调试」组，调试日志上方开关）——
//   开（默认）= 记录日志；关 = 完全无日志（PTLog 直接返回，内存/文件都不记）。
//   日志上限：内存（设置页）只存最近 200 条；文件 PageTurner.log 循环保留 1000 行（超过删最旧）。
//   运行端 PTLoadConfig 缓存 gDebugLogEnabled，改开关后重启目标 App 生效。
//
// v1.0.38（设置页新增映射覆盖修复，Tweak.xm 无逻辑改动）：
//
// v1.0.37（滑动时序参数扩展）：
//   1. 滑动新增「弹起停留 liftMs」：到终点后停 liftMs 再 Ended（默认 0）
//   2. 滑动分段 steps 从写死 12 改为可调（默认 12，范围 6~48，超范围自动钳制）
//   3. PTFakeSwipeAsync 签名扩展（holdMs/liftMs/steps），PTRunAction 读取动作参数传入
//   测试区（设置页）同步；旧滑动动作无 liftMs/steps 字段 → 走默认（0/12）兼容
//
// v1.0.36（点击特征位移矢量匹配）：
//   点击样本/特征新增 tapDx（位移方向符号 +1右/-1左/0原地）：
//   会话 Ended 按起点→终点 x 分量方向计算；PTMatchPlan 点击分支检查
//   tapDx 一致 + dist 区间（kTapDistSlack=0.15pt）——区分同 sender 的双点击键
//   （设置页 0.4 右 / 0.7 左 实测）；旧特征无 tapDx 自动兼容。
//
// v1.0.34（多特征方案）：
//   方案特征集合 feature(单条) → features[] 数组（兼容旧格式自动迁移）：
//   PTLoadConfig 统计已学 sender 遍历 features；PTMatchPlan 遍历 features 匹配。
//   对应设置页：方案页【增加特征】单特征录制 + 已录入特征列表页（v1.0.34）
//
// v1.0.33（实测反馈）：
//   设置页测试区滑动速度换算与运行端统一 + 命中日志加特征细节（RootListController.m）
//
// v1.0.32（v1.0.31 实测：拦截已生效但仍见双动作）：
//   根因：v1.0.30 的「执行中放行（!gIsInjecting）」把执行期间按的翻页器键也放行了——
//   映射执行要数秒（滑动速度慢），期间再按键 → 原始滑动 + 映射同时出现 = 双动作。
//   修复：gInFakeTouch 标志精确区分注入触摸（fakeTouchId 同步调用，包住即可）。
//   翻页器按键无论是否执行中一律拦截（防抖内忽略/防抖外中断重启，绝不放行）；
//   注入触摸靠 gInFakeTouch 放行（否则映射触摸 Began 被吞 → 映射失效）
//
// v1.0.31（深色模式适配）：
//   设置页：学习页大白屏 whiteColor → systemBackgroundColor；记录区浅灰底 → 次级背景
//
// v1.0.30（v1.0.29 实测日志定位的双动作根因）：
//   1. 窗口 50ms → 0.4s：翻页器按键起始 HID 事件有空隙（实测 73ms），
//      旧窗口下 sendEvent 的 Began 到达时窗口已过期 → 整段会话放行 →
//      App 收到翻页器原始滑动 = 双动作。窗口只由已学 sender 的 addEvent 刷新。
//   2. PTHandlePagerEvent 加 sender 校验：窗口期内手指触摸会把 gCurSender
//      覆盖成手指 sender，必须放行（防误吞手指触摸导致手机无法操作）
//   3. 映射执行中（gIsInjecting）不走 PTHandlePagerEvent：注入触摸没有 addEvent、
//      gCurSender 残留翻页器 sender，若吞会丢映射触摸的 Began → 映射失效
//
// v1.0.29（用户定稿 + 实测反馈）：
//   1. 拦截修复（问题5/7）：窗口/会话判断优先于 gIsInjecting——
//      已学 sender 会话无视 gIsInjecting 继续吞+执行（修双动作+卡顿）；
//      注入触摸 sender 不是已学 sender（addEvent 不开窗），照旧放行防递归
//   2. 探针独立开关（probeEnabled）：探针弹窗+提醒条归它管，不跟总开关；
//      调试可视化归 debugDots，互相独立
//   3. 日志落盘修复：PTLog 自动创建文件（旧 fileHandleForWritingAtPath 不建文件，
//      运行端日志一直静默丢失）；候选 App容器+/var/mobile/Documents/+jbroot，
//      全失败 NSLog 兜底；注入标记加 jbroot 路径
//
// v1.0.28（定稿版）：
//   拦截方案 B（整段吞 + 未命中重放，用户定稿）：
//     · Began（已学 sender 会话）→ 吞 + 记录起点（App 收不到，不会先滚动）
//     · Moved → 吞 + 记录轨迹点
//     · Ended → 判定：命中已录特征 → 执行映射（App 全程未收到原始滑动）；
//                        未命中 → 用暂存轨迹重放给 App（放行，未录键保留原行为）
//     · 手指 / 非已学 sender → 不拦截，自然放行（用户录的是翻页器特征，碰不到手指）
//   动作时序参数化（长按方案页动作可调）：
//     · tap: pressMs 按下时长（默认30ms）  · doubleTap: pressMs + gapMs 两次间隔（默认120ms）
//     · swipe: holdMs 按下停留（默认20ms）+ speed 真实速度 pt/s（默认200，距离/速度换算时长）
//     · delay: ms
//
// v1.0.24（注入可视化，照抄 volumekeytapper）：用户要求"打开 App 一眼看出注入成功没"
//   - 提醒条（勾选生效 App）：黑底白字+黄边框、屏幕中上方、2 秒——
//     「PageTurner 注入成功 · 翻页键映射生效中」，打勾的 App 打开就有，
//     有提醒条 = 注入成功
//   - 注入探针（照抄 VKT ShowProbeAlert）：第三方 App 启动 2.5s 弹窗显示
//     本App / 注入✅ / 全局配置(文件可读?) / 总开关 / crashTest / 勾选App数 /
//     本App被勾选 —— 打开番茄小说一眼看出注入和勾选状态
// v1.0.23（上一版核心修复，三路实证锁定终极根因）：
//   根因一【终极】：Filter 空 {} → ellekit 不注入任何进程。
//     TrollCM deb 拆包：Filter={ Bundles=[com.apple.springboard] } → 注入 SB 成功；
//     volumekeytapper Makefile：Filter={ Bundles=[com.apple.UIKit] } + dynamic_lookup
//     → 注入所有 UIKit App 成功（用户实证点击成功）；
//     PageTurner before-package 一直写 printf '{}' → ellekit 跳过 → 番茄小说
//     从未被注入 → 16 个版本全部无效。→ Filter 改为 Bundles=(com.apple.UIKit)。
//   根因二【链接】：v1.0.22 删 dynamic_lookup 后链接失败
//     "found '_MSHookMessageEx' in CydiaSubstrate.tbd, declaration possibly
//     missing 'extern \"C\"'" → extern 缺 extern "C" 被 C++ 修饰。
//     → extern "C" 声明 + 恢复 dynamic_lookup（volumekeytapper 同款，它带这个
//     且注入成功，证明 dynamic_lookup 本就不是问题）。
//   根因三【调试可视化】：按用户要求抄 TrollCM 触摸轨迹——本版加入
//     点触可视化（覆盖 UIWindow 绿点 + 轨迹线 + 翻页器 sender 标记），
//     设置页「调试可视化」开关控制，显示所有触摸（翻页器+手指+映射执行）。
// v1.0.21：注入标记 + 跨沙盒多路径读配置（PTGlobalPlistPath 照抄 volumekeytapper）。
// v1.0.20：运行端统一 sendEvent 会话通道（与测试区同款），命中才吞。
// v1.0.19：设置端方案页测试区（大白屏 + 绿点可视化），实证"匹配+执行+点触"OK。
// v1.0.18：运行端双通道（HID 位移通道 + 会话通道）——0x23/0x24 读不到，废弃。
// v1.0.17：整包回滚到真实 v1.0.4（release tag v1.0.4 = commit 0cd50018）。
//
// 注入范围：Filter = Bundles com.apple.UIKit（照抄 volumekeytapper，所有 UIKit App）
//   - Preferences 进程：旁路（学习收集由设置页 bundle 自 hook）
//   - 其它 App：运行时检查 masterEnabled + enabledApps[bundleID] 才执行映射
//
// 事件链路：
//   addEvent（IOHIDEvent 层）：已学 sender → 开窗口 + 放行（不吞）
//   sendEvent（UIEvent 层）会话：Began/Moved/Ended 结算 UITouch 位移特征
//     → 命中方案：吞事件 + 执行动作序列；未命中：放行 + 日志
//
// 动作：PTFakeMetaTouch（点击/双击/滑动）＋延迟（v1.0.48 起音量动作已删除）
// 防递归：gIsInjecting；防抖：gDebounceMs
// 日志：App 容器 Documents/PageTurner.log + /var/mobile/Documents/PageTurner.log
// 注入标记：/var/mobile/Documents/PageTurner-injected-<bid>.txt（Filza 一眼可查）
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <float.h>
#include <dlfcn.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach-o/dyld.h>
// MSHookMessageEx 由 -lsubstrate（ellekit substrate 兼容库）提供。
// 必须 extern "C"：Tweak.xm 由 clang++ 编译，缺 extern "C" 会被 C++ 名字修饰，
// 链接器找不到 _MSHookMessageEx（v1.0.22 链接失败实证）。
extern "C" void MSHookMessageEx(Class _cls, SEL _name, IMP _imp, IMP *_orig);
#import "ptftouch/PTFakeMetaTouch.h"

// ============================================================
// 常量
// ============================================================
static NSString *kPrefPath = @"/var/mobile/Library/Preferences/com.yourname.pageturner.plist";
static NSString *kPrefsBundleID = @"com.apple.Preferences";
static const double kPagerWindowSec = 0.4;       // v1.0.30：窗口 0.4s——翻页器按键起始 HID 事件有空隙（实测 73ms）
                                                 // 旧 0.05s 窗口：Began 到达时窗口已过期 → 整段放行 → 双动作。
                                                 // 窗口只由「已学 sender 的 addEvent」刷新，加长不误吞（PTHandlePagerEvent 有 sender 校验）
static const double kTapDistThreshold = 30.0;    // 位移 <30pt 判定 tap
static const double kDirTolerance = 15.0;        // 方向容差 ±15°
static const double kDistSlack = 30.0;           // 位移区间匹配裕度
static const double kTapDistSlack = 0.15;        // v1.0.36：点击位移区间容差（pt，用于区分 0.4/0.7 这类微小位移点击键）
static const double kTapDxThresh = 0.05;         // v1.0.36：点击位移方向判定阈值（|dx|>0.05 才算有方向）

// ============================================================
// 日志
// ============================================================
static const char *gLogPath = NULL;
static BOOL gDebugLogEnabled = YES;   // v1.0.42：调试日志总开关（PTLog 使用，须在 PTLog 前声明）
static NSString *PTJbrootRoot(void);   // 前向声明（139 行定义）

// v1.0.29：日志文件自动创建（fileHandleForWritingAtPath 不会建文件，旧版静默丢日志）
static void PTEnsureLogFile(NSString *path) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (dir.length && ![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    } @catch (NSException *e) {}
}

// v1.0.42：日志文件只保留最近 1000 行，超过循环（删最旧，保留尾部 1000 行）
static void PTTrimLogFile(NSString *path) {
    @try {
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!content) return;
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        if (lines.count > 1000) {
            NSArray *keep = [lines subarrayWithRange:NSMakeRange(lines.count - 1000, 1000)];
            [[keep componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {}
}

// 运行端日志：App 容器 + /var/mobile/Documents + jbroot 三候选，自动创建，全失败 NSLog 兜底
// v1.0.42：受【调试日志】开关（debugLogEnabled）控制，关=完全不写（省电省空间）；
// 文件只保留最近 1000 行，超过循环（trim 保留尾部 1000 行）
static void PTLog(NSString *fmt, ...) {
    if (!gDebugLogEnabled) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec; struct tm tmv; localtime_r(&sec, &tmv);
    char tbuf[64]; strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@\n", tbuf, (int)(tv.tv_usec/1000), msg];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    BOOL wrote = NO;
    static int gPTFileLines = 0;   // v1.0.42：行数计数（多候选路径共享，触发时逐路径 trim）
    NSMutableArray *paths = [NSMutableArray array];
    if (gLogPath) [paths addObject:[NSString stringWithUTF8String:gLogPath]];
    [paths addObject:@"/var/mobile/Documents/PageTurner.log"];
    NSString *jb = PTJbrootRoot();
    if (jb.length) [paths addObject:[jb stringByAppendingPathComponent:@"var/mobile/Documents/PageTurner.log"]];
    for (NSString *p in paths) {
        PTEnsureLogFile(p);
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; wrote = YES; gPTFileLines++; } @catch (NSException *e) {} }
    }
    if (gPTFileLines > 1000) {
        for (NSString *p in paths) PTTrimLogFile(p);   // 每个路径保留尾部 1000 行
        gPTFileLines = 1000;
    }
    if (!wrote) NSLog(@"[PageTurner] %@", line);   // 全失败：系统日志兜底（Console/Filza 可查）
}

static double PTNow(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// ============================================================
// 配置（plist：masterEnabled / enabledApps[] / debounceMs / plans[] / learning / learningSamples）
// ============================================================
static NSString *gBundleID = nil;
static BOOL gIsPreferences = NO;
static NSDictionary *gConfig = nil;
static double gConfigMtime = 0;
static BOOL gMasterEnabled = NO;
static NSMutableSet *gEnabledApps = nil;
static double gDebounceMs = 300;
static BOOL gDebugDots = NO;                // v1.0.23：调试可视化（TrollCM 触摸轨迹）
static BOOL gProbeEnabled = NO;             // v1.0.29：探针独立开关（探针弹窗+提醒条）
static BOOL gCrashTest = NO;                // v1.0.24：注入测试（探针字段，照抄 VKT）
static void PTDebugDestroyOverlay(void);    // v1.0.51：可视化覆盖层销毁（前向声明）
static NSMutableDictionary *gPlans = nil;   // name -> dict
static BOOL gLearnActive = NO;              // plist learning.active（Preferences 进程学习开关）
static NSString *gCfgPath = nil;            // 实际读到的 plist 路径（诊断）

static uint64_t gLearnedSenders[32];        // 已学 sender 集合（运行时识别）
static int gLearnedSenderCount = 0;

// 跨沙盒读全局 plist（v1.0.21 加，照抄 volumekeytapper）：
// roothide 下第三方 App 沙盒读 /var/mobile/Library/Preferences 会被重定向到
// App 沙盒，读不到 Preferences 进程写的全局配置 → 从本 dylib 镜像提取
// .jbroot-XXX 根，拼接 jbroot 下的真实偏好路径。
static NSString *PTJbrootRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t on;
    dispatch_once(&on, ^{
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *img = _dyld_get_image_name(i);
            if (!img) continue;
            NSString *p = [NSString stringWithUTF8String:img];
            NSRange r = [p rangeOfString:@"/.jbroot-"];
            if (r.location == NSNotFound) continue;
            NSRange startSeg = r;
            NSRange after = NSMakeRange(NSMaxRange(startSeg), p.length - NSMaxRange(startSeg));
            NSRange slash = [p rangeOfString:@"/" options:0 range:after];
            NSUInteger end = (slash.location != NSNotFound) ? slash.location : p.length;
            root = [p substringToIndex:end];
            break;
        }
    });
    return root;
}

static NSString *PTGlobalPlistPath(void) {
    NSString *name = @"com.yourname.pageturner.plist";
    NSMutableArray *cands = [NSMutableArray array];
    [cands addObject:[@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:name]];
    NSString *jb = PTJbrootRoot();
    if (jb.length) {
        [cands addObject:[jb stringByAppendingPathComponent:[@"var/mobile/Library/Preferences" stringByAppendingPathComponent:name]]];
        [cands addObject:[jb stringByAppendingPathComponent:[@"Library/Preferences" stringByAppendingPathComponent:name]]];
    }
    [cands addObject:[@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:name]];
    [cands addObject:[@"/var/jb/Library/Preferences" stringByAppendingPathComponent:name]];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return cands.firstObject; // 不存在也返回首选路径（供日志）
}

// 原始读文件（不碰 mtime 缓存；多路径取第一个存在的）
static NSMutableDictionary *PTReadFileRaw(void) {
    NSString *p = PTGlobalPlistPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return d ? [NSMutableDictionary dictionaryWithDictionary:d] : [NSMutableDictionary dictionary];
}

// 原子写（tmp + rename；只 Preferences 进程使用，写系统根路径）
static void PTWriteFileRaw(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *tmp = [kPrefPath stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:kPrefPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kPrefPath error:nil];
}

static void PTLoadConfig(BOOL force) {
    // v1.0.54：配置路径缓存优先——gCfgPath 已确定且文件仍在,直接复用,
    // 跳过 PTGlobalPlistPath 的 5 路径 fileExists 探测。AddEvent/SendEvent 每事件各调一次
    // PTLoadConfig,原每次探测 5 次系统调用 + 5 个字符串分配(每事件约 10 次),现降为仅
    // 1 次 fileExists;文件路径失效(如 JB 环境切换)时自动回退全探测重新定位。
    NSString *p = (gCfgPath && [NSFileManager.defaultManager fileExistsAtPath:gCfgPath])
        ? gCfgPath : PTGlobalPlistPath();
    if (!gCfgPath || ![gCfgPath isEqualToString:p]) {
        gCfgPath = p;
        PTLog(@"[配置] 实际读取路径=%@", p);
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (!force && gConfig && mtime == gConfigMtime) return;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:p];
    gConfig = cfg ? cfg : @{};
    gConfigMtime = mtime;
    gMasterEnabled = [gConfig[@"masterEnabled"] boolValue];
    NSArray *apps = gConfig[@"enabledApps"];
    gEnabledApps = [NSMutableSet setWithArray:apps ? apps : @[]];
    double db = [gConfig[@"debounceMs"] doubleValue];
    gDebounceMs = (db > 0) ? db : 300;
    gDebugDots = [gConfig[@"debugDots"] boolValue];
    // v1.0.49：可视化开关关掉 → 销毁绿点窗口（此前永驻，windowLevel 高于状态栏会接管
    // 状态栏样式导致时间/信号电池颜色不再跟随 App）
    if (!gDebugDots) PTDebugDestroyOverlay();
    gProbeEnabled = (gConfig[@"probeEnabled"] == nil) ? NO : [gConfig[@"probeEnabled"] boolValue];
    gDebugLogEnabled = (gConfig[@"debugLogEnabled"] == nil) ? YES : [gConfig[@"debugLogEnabled"] boolValue];   // v1.0.42：缺省开
    gCrashTest = (gConfig[@"crashTest"] == nil) ? NO : [gConfig[@"crashTest"] boolValue];
    gPlans = [NSMutableDictionary dictionary];
    gLearnedSenderCount = 0;
    for (NSDictionary *p in gConfig[@"plans"] ?: @[]) {
        if (!p[@"name"]) continue;
        gPlans[p[@"name"]] = p;
        // v1.0.34：特征集合 features[]（兼容旧格式单条 feature）
        NSArray *fts = p[@"features"] ?: (p[@"feature"] ? @[p[@"feature"]] : @[]);
        for (NSDictionary *ft in fts) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if ([sc scanHexLongLong:&s] && gLearnedSenderCount < 32) {
                    gLearnedSenders[gLearnedSenderCount++] = s;
                }
            }
        }
    }
    gLearnActive = [gConfig[@"learning"][@"active"] boolValue];
}

// 供设置页读取当前配置快照（Preferences 进程内）
NSDictionary *PTGetConfig(void) { PTLoadConfig(NO); return gConfig; }

// 供设置页写回完整配置
void PTSaveConfig(NSDictionary *cfg) { PTWriteFileRaw(cfg); }

// 学习模式开关（设置页学习页进入/退出时写 learning.active）
void PTSetLearning(BOOL on) {
    NSMutableDictionary *cfg = PTReadFileRaw();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTWriteFileRaw(cfg);
    PTLoadConfig(YES);
}

// ============================================================
// IOKit（sender 读取 + HID 相对位移）
// ============================================================
typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
typedef double (*IOHIDEventGetFloatValue_t)(void *, uint32_t);
static IOHIDEventGetType_t pGetType = NULL;
static IOHIDEventGetSenderID_t pGetSender = NULL;
static IOHIDEventGetFloatValue_t pGetFloat = NULL;

// ============================================================
// HID 通道（v1.0.20 起废弃匹配，仅保留观察日志）
// 0x23/0x24 相对位移在 Preferences 进程实测恒 0（iOS 16 HID 结构），
// v1.0.18 双通道目标 App 实测无效。方向键改走 sendEvent 会话通道
// （与设置 App 测试区同款，v1.0.19 已实证成功）。
// 这里保留读取仅用于日志观察：判断目标 App 里 0x23/0x24 到底有没有值。
// ============================================================
static uint64_t gCurSender = 0;              // 最近 digitizer 事件 sender
static double gPagerWindowUntil = 0;         // 翻页器活跃窗口（已学 sender 开窗）

static BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

// ============================================================
// 特征结构（触摸会话共用）
// ============================================================
typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
    int tapDx;        // v1.0.36：点击位移方向符号（+1 右 / -1 左 / 0 不动）——区分同 sender 的多个点击键
} PagerFeature;

static void PTExecutePlan(NSString *name);                    // 前向声明（动作执行段定义）
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender); // 前向声明（匹配段定义）

// ============================================================
// 触摸会话 + 特征
// ============================================================
typedef struct {
    BOOL active;
    int nEvents;
    CGPoint start, last;
    double totalDist;
    double firstMoveDir;
    BOOL hasMove;
} PagerSession;
static PagerSession gSession;

// v1.0.28：前向声明（实现放在动作执行段，gIsInjecting/PTFakeMetaTouch 定义之后）
static void PTReplayTrailAsync(void);

// ============================================================
// 事件处理（学习收集 / 运行匹配+吞）
// ============================================================
static void PTExecutePlan(NSString *name);   // 前向声明（定义在动作执行段）
// 学习模式（Preferences 进程）：append 样本到 plist，不吞
static void PTAppendLearnSample(PagerFeature f, uint64_t sender) {
    NSMutableDictionary *cfg = PTReadFileRaw();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sender],
        @"phase": @(f.phase),
        @"direction": @(f.direction),
        @"dist": @(f.dist),
        @"tapDx": @(f.tapDx),   // v1.0.36：点击位移方向符号
    }];
    cfg[@"learningSamples"] = samples;
    PTWriteFileRaw(cfg);
    PTLog(@"[学习] 样本 sender=0x%llx phase=%d dir=%.1f dist=%.1f", sender, f.phase, f.direction, f.dist);
}

// 运行模式：匹配（sender + 相位 + 方向±15° + 位移区间）→ 唯一方案
// v1.0.34：遍历方案 features[]（兼容旧 feature 单条）
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender) {
    NSString *best = nil;
    double bestScore = DBL_MAX;
    for (NSString *name in gPlans) {
        NSDictionary *p = gPlans[name];
        NSArray *fts = p[@"features"] ?: (p[@"feature"] ? @[p[@"feature"]] : @[]);
        for (NSDictionary *ft in fts) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;   // sender 必须一致
            }
            if ([ft[@"phase"] intValue] != f.phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(f.direction - pd)); if (d > 180) d = 360 - d;
            if (d > kDirTolerance) continue;
            double lo = 0, hi = 0;
            if (f.phase == 1) {
                lo = [ft[@"distMin"] doubleValue];
                hi = [ft[@"distMax"] doubleValue];
                if (f.dist < lo - kDistSlack || f.dist > hi + kDistSlack) continue;
            } else {
                // v1.0.36：点击也启用位移匹配——方向符号 + 位移区间（微小容差）
                if (ft[@"tapDx"]) {
                    if (f.tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (f.dist < lo - kTapDistSlack || f.dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (f.phase == 1 ? fabs(f.dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; best = name; }
        }
    }
    return best;
}

// 返回 YES = 吞（命中：防 App 同时收到翻页器滚动）；NO = 放行（未命中：App 保留原行为）
// v1.0.28 方案 B：已学 sender 会话 Began/Moved 即吞 + 记录轨迹；Ended 判定——
//   命中 → 执行映射（整个会话 App 未收到）；未命中 → 暂存轨迹重放给 App（放行）
static NSMutableArray *gSessTrail = nil;   // 当前会话轨迹点（NSValue<CGPoint>）

static BOOL PTHandlePagerEvent(UIEvent *event) {    if (![event respondsToSelector:@selector(allTouches)]) return NO;
    // v1.0.30：窗口开着也不能吞手指——窗口由「已学 sender 的 addEvent」打开，
    // 但窗口期内手指触摸的 addEvent 会把 gCurSender 覆盖成手指 sender（type=11 全记），
    // 此时必须放行（return NO），否则手指触摸的 Began 会被吞导致手机无法操作
    if (!PTIsLearnedSender(gCurSender)) return NO;
    NSSet *touches = event.allTouches;
    if (!touches.count) return NO;
    UITouch *t = [touches anyObject];
    CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
    switch (t.phase) {
        case UITouchPhaseBegan: {
            gSession.active = YES;
            gSession.nEvents = 0;
            gSession.start = p;
            gSession.last = p;
            gSession.totalDist = 0;
            gSession.hasMove = NO;
            gSession.firstMoveDir = 0;
            gSessTrail = [NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:p]];
            return YES;   // 方案 B：Began 即吞（App 收不到，由 Ended 决定放行/替换）
        }
        case UITouchPhaseMoved: {
            if (!gSession.active) return NO;
            gSession.nEvents++;
            double dx = p.x - gSession.last.x, dy = p.y - gSession.last.y;
            double seg = hypot(dx, dy);
            if (seg > 0) {
                gSession.totalDist += seg;
                if (!gSession.hasMove && gSession.totalDist > 5) {
                    gSession.hasMove = YES;
                    gSession.firstMoveDir = atan2(dy, dx) * 180.0 / M_PI;
                }
            }
            gSession.last = p;
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            return YES;   // 吞 Moved（轨迹已记录，未命中时重放）
        }
        case UITouchPhaseEnded: {
            if (!gSession.active) return NO;
            gSession.active = NO;
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            PagerFeature f;
            f.phase = (gSession.totalDist < kTapDistThreshold) ? 0 : 1;
            f.direction = gSession.hasMove ? gSession.firstMoveDir : 0;
            f.dist = gSession.totalDist;
            // v1.0.36：点击位移方向符号（用整段位移的 x 分量方向；start=Began 起点）
            {
                double sx = gSession.start.x, ex = p.x;
                double dxv = ex - sx;
                f.tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
            }
            if (gIsPreferences && gLearnActive) {
                PTAppendLearnSample(f, gCurSender);
                gSessTrail = nil;
                return NO;   // 学习端由设置页 bundle 收集，tweak 旁路不吞
            }
            NSString *plan = PTMatchPlan(f, gCurSender);
            if (plan) {
                gSessTrail = nil;
                PTLog(@"[会话] 命中「%@」→ 执行映射（原始滑动已整段吞掉）", plan);
                PTExecutePlan(plan);
                return YES;   // 吞 Ended（整个会话 App 未收到）
            }
            PTLog(@"[会话] 未命中：sender=0x%llx phase=%d dir=%.1f dist=%.1f → 重放轨迹放行",
                  gCurSender, f.phase, f.direction, f.dist);
            PTReplayTrailAsync();
            return YES;   // 吞原 Ended，重放合成版给 App
        }
        case UITouchPhaseCancelled:
            gSession.active = NO;
            gSessTrail = nil;
            return NO;
        default:
            return NO;
    }
}

// v1.0.28 方案 B：PTReplayTrailAsync 实现见动作执行段（gIsInjecting 定义之后）

// ============================================================
// 调试可视化（v1.0.23 加，按用户要求抄 TrollCM 触摸轨迹思路）
// 覆盖 UIWindow（level=StatusBar+1）+ 绿点 + 轨迹线；
// 翻页器 sender 的圆点带 "P" 标记（黑描边绿点）；
// 显示所有触摸：翻页器、手指、映射执行（gIsInjecting 内的触摸）。
// ============================================================
@interface PTDebugDot : NSObject
@property (nonatomic) CGPoint pos;
@property (nonatomic) BOOL pager;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) NSMutableArray *trail;   // NSValue<CGPoint>
@end
@implementation PTDebugDot
- (instancetype)initWithPoint:(CGPoint)p pager:(BOOL)pg parentView:(UIView *)pv {
    self = [super init];
    if (self) {
        _pos = p; _pager = pg;
        _trail = [NSMutableArray array];
        [_trail addObject:[NSValue valueWithCGPoint:p]];
        _dotView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        _dotView.center = p;
        _dotView.layer.cornerRadius = 22;
        _dotView.layer.borderWidth = 2;
        _dotView.layer.borderColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.8].CGColor;
        _dotView.backgroundColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.85];
        if (pg) {
            UILabel *lb = [[UILabel alloc] initWithFrame:_dotView.bounds];
            lb.text = @"P";
            lb.font = [UIFont boldSystemFontOfSize:20];
            lb.textColor = [UIColor blackColor];
            lb.textAlignment = NSTextAlignmentCenter;
            [_dotView addSubview:lb];
        }
        _trailLayer = [CAShapeLayer layer];
        _trailLayer.strokeColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.7].CGColor;
        _trailLayer.fillColor = [UIColor clearColor].CGColor;
        _trailLayer.lineWidth = 4;
        _trailLayer.lineCap = kCALineCapRound;
        [pv.layer addSublayer:_trailLayer];
        [pv addSubview:_dotView];
    }
    return self;
}
- (void)moveTo:(CGPoint)p {
    _pos = p;
    _dotView.center = p;
    [_trail addObject:[NSValue valueWithCGPoint:p]];
    if (_trail.count > 80) [_trail removeObjectAtIndex:0];
    CGMutablePathRef path = CGPathCreateMutable();
    BOOL first = YES;
    for (NSValue *v in _trail) {
        CGPoint q = v.CGPointValue;
        if (first) { CGPathMoveToPoint(path, NULL, q.x, q.y); first = NO; }
        else CGPathAddLineToPoint(path, NULL, q.x, q.y);
    }
    _trailLayer.path = path;
    CGPathRelease(path);
}
- (void)fadeOut {
    [_dotView.layer removeAllAnimations];
    [UIView animateWithDuration:0.5 animations:^{
        _dotView.alpha = 0.15;
    } completion:^(BOOL f) {
        [_dotView removeFromSuperview];
    }];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.toValue = @(0.0);
    fade.duration = 0.5;
    fade.removedOnCompletion = NO;
    fade.fillMode = kCAFillModeForwards;
    [_trailLayer addAnimation:fade forKey:@"fade"];
}
@end

static UIView *gDotOverlay = nil;   // v1.0.51：可视化改为 keyWindow 上的覆盖层 view（不建独立窗口，不碰状态栏）
static NSMutableDictionary *gDotViews = nil;   // key=UITouch 指针字符串

// v1.0.51：可视化不再用独立 UIWindow——独立窗口存在就会参与系统状态栏样式计算
// （时间/信号电量变白根因）。改为直接叠加在当前 keyWindow 上的透明 view，
// 零窗口参与状态栏判定，状态栏彻底归系统/App 管。
static void PTDebugEnsureOverlay(void) {
    if (gDotOverlay) return;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    UIView *ov = [[UIView alloc] initWithFrame:kw.bounds];
    ov.userInteractionEnabled = NO;                // 纯显示，不拦截触摸
    ov.backgroundColor = [UIColor clearColor];
    [kw addSubview:ov];
    gDotOverlay = ov;
    gDotViews = [NSMutableDictionary dictionary];
}

// v1.0.51：可视化开关关掉时销毁覆盖层
static void PTDebugDestroyOverlay(void) {
    [gDotOverlay removeFromSuperview];
    gDotOverlay = nil;
    gDotViews = nil;
}

static void PTDebugUpdate(void *touchPtr, CGPoint p, UITouchPhase phase, BOOL pager) {
    if (!gMasterEnabled || !gDebugDots) return;   // v1.0.26：调试可视化纳入总开关
    if (![NSThread isMainThread]) return;
    PTDebugEnsureOverlay();
    if (!gDotOverlay) return;
    NSString *key = [NSString stringWithFormat:@"%p", touchPtr];
    PTDebugDot *dot = gDotViews[key];
    if (phase == UITouchPhaseBegan) {
        if (dot) return;
        dot = [[PTDebugDot alloc] initWithPoint:p pager:pager parentView:gDotOverlay];
        gDotViews[key] = dot;
    } else if (phase == UITouchPhaseMoved) {
        if (dot) [dot moveTo:p];
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        if (dot) {
            [dot moveTo:p];
            [dot fadeOut];
            [gDotViews removeObjectForKey:key];
        }
    }
}

// ============================================================
// 注入可视化（v1.0.24，照抄 volumekeytapper）：
//   PTShowToast —— 黑底白字+黄边框提醒条（勾选生效 App 启动显示，2 秒）
//   PTShowProbeAlert —— 注入探针弹窗（第三方 App 启动 2.5s 后弹）
// ============================================================
static UIWindow *PTFindKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.connectedScenes) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
                return [ws.windows firstObject];
            }
        }
    }
    return app.keyWindow ?: app.windows.firstObject;
}

static void PTShowToast(NSString *msg) {
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *w = PTFindKeyWindow();
            if (!w) return;
            // 大而醒目的黑底白字圆角条，屏幕中上方，停留 2 秒（照抄 VKT ShowToast）
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(w.bounds.size.width/2 - 160, 200, 320, 64)];
            l.text = msg;
            l.textColor = [UIColor whiteColor];
            l.textAlignment = NSTextAlignmentCenter;
            l.font = [UIFont boldSystemFontOfSize:18];
            l.numberOfLines = 2;
            l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
            l.layer.cornerRadius = 12;
            l.layer.masksToBounds = YES;
            l.layer.borderWidth = 2;
            l.layer.borderColor = [UIColor systemYellowColor].CGColor;
            [w addSubview:l];
            [w bringSubviewToFront:l];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
        });
    } @catch (NSException *e) {}
}

static void PTShowProbeAlert(void) {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        if ([bid hasPrefix:@"com.apple."]) return;   // 只对第三方 App 弹，避免骚扰系统进程
        BOOL selected = [gEnabledApps containsObject:bid];
        BOOL cfgReadable = [NSFileManager.defaultManager fileExistsAtPath:gCfgPath ?: @""];
        NSString *msg = [NSString stringWithFormat:
            @"本App: %@\n注入: ✅ 成功\n全局配置: %@\n总开关enabled: %@\n注入测试crashTest: %@\n勾选App数: %lu  本App被勾选: %@",
            bid,
            cfgReadable ? [NSString stringWithFormat:@"文件可读 %@", gCfgPath] : [NSString stringWithFormat:@"文件不可读 %@", gCfgPath],
            gMasterEnabled ? @"开" : @"关",
            gCrashTest ? @"开" : @"关",
            (unsigned long)gEnabledApps.count,
            selected ? @"是✅" : @"否❌"];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *w = PTFindKeyWindow();
            UIViewController *vc = w.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if (!vc) return;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PageTurner 注入探针"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
        });
    } @catch (NSException *e) {}
}

// ============================================================
// 动作执行（PTFakeMetaTouch ＋ 延迟；v1.0.48 音量动作已删除）
// ============================================================
static BOOL gIsInjecting = NO;
static BOOL gExecRunning = NO;   // v1.0.43：序列执行中（防抖覆盖执行窗口，根除狂按打断滑动）
static BOOL gInFakeTouch = NO;   // v1.0.32：PTFakeMetaTouch 注入触摸期间置 YES（同步调用，包住即可）
                                  // 用于精确区分「注入触摸（放行）」vs「翻页器按键（拦截）」——
                                  // 注入触摸没有 addEvent、sender 残留翻页器，必须靠这个标志识别
static int gExecToken = 0;
static double gLastExec = 0;

// v1.0.28 方案 B：未命中时把暂存轨迹重放给 App（恢复原行为 = 放行）
// 中间点均匀抽样最多 10 个，异步分步，gIsInjecting 防递归
// v1.0.43：重放注入期间补 gInFakeTouch（与 PTFakeTap 一致）——此前没置，0.4s 窗口内
// 重放合成触摸会被 PTHandlePagerEvent 当成翻页器会话再次吞掉 → 重放被掐死/反复重放
static void PTReplayTrailAsync(void) {
    if (!gSessTrail || gSessTrail.count < 2) { gSessTrail = nil; return; }
    NSArray *pts = [gSessTrail copy];
    gSessTrail = nil;
    CGPoint from = [pts.firstObject CGPointValue];
    CGPoint to = [pts.lastObject CGPointValue];
    NSMutableArray *mids = [NSMutableArray array];
    NSUInteger n = pts.count;
    NSUInteger k = MIN(n - 2, 10u);
    for (NSUInteger i = 0; i < k; i++) {
        NSUInteger idx = 1 + (i * (n - 2)) / k;
        if (idx >= n - 1) idx = n - 2;
        [mids addObject:pts[idx]];
    }
    gIsInjecting = YES;
    gInFakeTouch = YES;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    __block NSUInteger i = 0;
    __block void (^step)(void);
    step = ^(void) {
        if (i >= mids.count) {
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            gIsInjecting = NO;
            PTLog(@"[重放] 未命中：原始轨迹已重放给 App（%lu 中间点）", (unsigned long)mids.count);
            return;
        }
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:[mids[i] CGPointValue] withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        i++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.012 * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

// v1.0.48：音量动作类型（音量+/音量-/静音切换）已整体删除——第三方 App 进程无激活音频
// 会话时系统音量读取接口（AVSystemController get / AVAudioSession.outputVolume / MPVolumeView
// slider 同步读）全部返回假值，写也依赖异步 slider 兜底，修 4 版无法稳定 → 止损删除。
// 旧配置兼容：已保存映射里的音量动作执行时被 PTRunAction 默认分支跳过（不崩溃）。

// 点击（同步短阻塞，DVT 验证过的方案；pressMs = 按下时长）
static void PTFakeTap(CGPoint p, int pressMs) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    // v1.0.32：注入触摸期间置 gInFakeTouch=YES → sendEvent 层放行（不走拦截，映射触摸不丢 Began）
    gInFakeTouch = YES;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    usleep(pressMs * 1000);
    gInFakeTouch = YES;
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    gInFakeTouch = NO;
}

// 滑动（异步分步，不阻塞主线程；holdMs = 按下停留，liftMs = 弹起停留，完成后调 completion）
// v1.0.37：steps 从写死 12 改为可调（默认 12）；到终点后先停 liftMs 再 Ended
// v1.0.39：弃置式中断修复——token 失效（新按键打断旧滑动）时立即在当前实际位置 Ended 复位，
//          触摸不再悬空，新滑动干净开始（根除"连按滑动越来越短"）
// v1.0.40：①时间插值——位置按真实经过时间算（主线程再忙，速度也恒定均匀）；
//          ②静止衰减——到终点后每帧(~16ms)发位置不变的 Moved，持续 max(停顿,300)ms，
//            模拟真实手指停住：速度采样窗口被"没动"填满 → velocity=0 → 弹起无惯性
// v1.0.41：①狂按修复——Began 延迟 40ms：弃置式下旧滑动（同触摸 id=1）的复位 Ended 先发出，
//            新触摸才 Began（否则迟到的 Ended 会把刚 Began 的新触摸掐死 → 滑动残缺）；
//            延迟期间 token 已失效则直接放弃本次（不发触摸）
//          ②固定 60fps 采样——帧间隔固定 16ms（不再随"分段"变大），轨迹点密且间距均匀；
//          ③【防惯性】显式开关（noInertia）：开=终点静止衰减（每帧不动 300ms+）→ 弹起无惯性；
//            关=干净利落（停 liftMs 直接弹起，可能有惯性，用户自担）；回滑参数已删除
static void PTFakeSwipeAsync(CGPoint from, CGPoint to, double durationMs, int holdMs, int liftMs, BOOL noInertia, int token, void (^done)(void)) {
    double durSec = MAX(durationMs / 1000.0, 0.001);
    __block NSInteger pid = -1;
    __block BOOL began = NO;
    __block BOOL ended = NO;
    __block CGPoint lastP = from;              // 记录最后实际位置（弃置时原地 Ended，无瞬移）
    __block void (^abortEnd)(void);
    __block void (^doEnd)(void);
    abortEnd = ^{
        if (ended) return;
        ended = YES;
        if (!began) { if (done) done(); return; }   // 尚未 Began 已被弃置：不发任何触摸
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
    };
    doEnd = ^{
        if (ended) { if (done) done(); return; }
        ended = YES;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
        if (done) done();
    };
    // v1.0.40：静止衰减——在 pos 原地每帧发位置不变的 Moved，持续 ms 毫秒（模拟手指停住，速度衰减到 0）
    __block void (^stillAt)(CGPoint, int);
    stillAt = ^(CGPoint pos, int ms) {
        __block int n = MAX(ms, 0) / 16;
        __block void (^still)(void);
        still = ^(void) {
            if (token != gExecToken) { abortEnd(); if (done) done(); return; }
            if (n <= 0) { doEnd(); return; }
            n--;
            lastP = pos;
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
            gInFakeTouch = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
        };
        still();
    };
    __block CFAbsoluteTime t0;
    __block void (^step)(void);
    step = ^(void) {
        if (token != gExecToken) { abortEnd(); if (done) done(); return; }
        // v1.0.40：位置按真实经过时间插值 → 速度恒定均匀
        double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
        if (t >= 1.0) {
            if (noInertia) {
                // v1.0.40 防惯性：终点每帧不动（静止衰减），持续 max(liftMs,300) 再 Ended
                stillAt(to, MAX(liftMs, 300));
            } else {
                // v1.0.41 关防惯性：干净利落——停 liftMs（不发事件）→ 直接弹起（可能有轻微惯性）
                if (liftMs > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                        if (token != gExecToken) { abortEnd(); if (done) done(); return; }
                        doEnd();
                    });
                } else {
                    doEnd();
                }
            }
            return;
        }
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        lastP = p;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        // v1.0.41：固定 16ms 一帧（60fps 采样），轨迹点密且间距均匀
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
    };
    // v1.0.41：Began 延迟 40ms——让被弃置的旧滑动先补发 Ended（≤16ms），同 id 触摸不复位打死新触摸
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
        if (token != gExecToken) { if (done) done(); return; }   // 未 Began 已被弃置：放弃本次
        began = YES;
        gInFakeTouch = YES;
        pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
        gInFakeTouch = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            t0 = CFAbsoluteTimeGetCurrent();   // v1.0.40：按下停留结束后开始计时
            step();
        });
    });
}

// ============================================================
// v1.0.55：滑动(手动)回放（CADisplayLink 驱动，照搬 DirectVolumeTap 的 DVTFakeSwipe）
// 每帧对齐 VSync，按真实经过时间插值出坐标注入一次 Moved，1:1 还原真实手指流畅感。
// 录制在设置页进程（灰色 PTRecView）完成，pts 为 @{x,y,t} 字典（与设置页/测试一致）。
// ============================================================
@interface PTRecSwipeTickProxy : NSObject
@property (nonatomic, copy) void (^tick)(void);
- (void)onTick:(CADisplayLink *)link;
@end
@implementation PTRecSwipeTickProxy
- (void)onTick:(CADisplayLink *)link { if (_tick) _tick(); }
@end

// 按时间线性插值取坐标（二分定位区间）
static CGPoint PTRecSwipeInterp(NSArray *xs, NSArray *ys, NSArray *ts, double targetT) {
    NSUInteger m = [ts count];
    if (m == 0) return CGPointZero;
    double t0 = [ts[0] doubleValue], tEnd = [ts[m-1] doubleValue];
    if (targetT <= t0)   return CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]);
    if (targetT >= tEnd) return CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
    NSUInteger lo = 0, hi = m - 1;
    while (hi - lo > 1) {
        NSUInteger mid = (lo + hi) / 2;
        if ([ts[mid] doubleValue] <= targetT) lo = mid; else hi = mid;
    }
    double ta = [ts[lo] doubleValue], tb = [ts[hi] doubleValue];
    double fa = [xs[lo] doubleValue], fb = [xs[hi] doubleValue];
    double ga = [ys[lo] doubleValue], gb = [ys[hi] doubleValue];
    double f = (tb - ta) > 1e-6 ? (targetT - ta) / (tb - ta) : 0.0;
    return CGPointMake(fa + (fb - fa) * f, ga + (gb - ga) * f);
}

static void PTFakeRecSwipeAsync(NSArray *pts, int token, void (^done)(void)) {
    if (!pts.count) { if (done) done(); return; }
    // 预解析 @{x,y,t} → 分离数组（避免每帧反复解包）
    NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array], *ts = [NSMutableArray array];
    for (NSDictionary *p in pts) {
        [xs addObject:@([p[@"x"] doubleValue])];
        [ys addObject:@([p[@"y"] doubleValue])];
        [ts addObject:@([p[@"t"] doubleValue])];
    }
    NSUInteger m = ts.count;
    if (m < 2) { if (done) done(); return; }
    double t0 = [ts[0] doubleValue];
    double totalMs = [ts[m-1] doubleValue] - t0;
    if (totalMs <= 0) totalMs = 1.0;

    __block NSInteger pid = -1;
    __block BOOL ended = NO;
    __block CFAbsoluteTime startT = CFAbsoluteTimeGetCurrent();
    PTRecSwipeTickProxy *proxy = [PTRecSwipeTickProxy new];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(onTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    proxy.tick = ^{
        if (token != gExecToken) { [link invalidate]; if (done) done(); return; }
        double elapsedMs = (CFAbsoluteTimeGetCurrent() - startT) * 1000.0;
        CGPoint cur = PTRecSwipeInterp(xs, ys, ts, t0 + elapsedMs);   // 1:1 还原（无速率调节）
        gInFakeTouch = YES;
        if (pid < 0) pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:cur withTouchPhase:UITouchPhaseBegan];
        else         [PTFakeMetaTouch fakeTouchId:pid AtPoint:cur withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        if (elapsedMs >= totalMs && !ended) {
            CGPoint end = CGPointMake([xs[m-1] doubleValue], [ys[m-1] doubleValue]);
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:end withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            ended = YES;
            [link invalidate];
            if (done) done();
        }
    };
}

// v1.0.55：已删除「跨进程手动录制」（设置页写 recRequest → 注入 App 弹覆盖层那一套）。
// 录制改在设置页进程内用灰色 PTRecView 完成（见 Preferences/RootListController.m），
// 运行时真实轨迹回放见上方 PTFakeRecSwipeAsync。

// 执行单条动作 → 完成后 next()
static void PTRunAction(NSDictionary *a, int token, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        PTFakeTap(CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]), pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        int gapMs = [a[@"gapMs"] intValue] ?: 120;
        PTFakeTap(p, pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gapMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p, pressMs);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        // v1.0.28：speed = 真实速度 pt/s；时长 = 距离/速度
        // v1.0.43：默认 1000pt/s（设置页新动作默认 1000；旧动作缺 speed 字段兜底 1000）
        double speed = [a[@"speed"] doubleValue] ?: 1000;
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        // v1.0.37：弹起停留（默认 0）
        // v1.0.41：防惯性开关（默认开）——开=静止衰减无惯性；关=干净利落；回滑参数已删除
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;   // 缺省开（兼容旧配置）
        double dist = hypot(to.x - from.x, to.y - from.y);
        double durMs = (dist / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        PTFakeSwipeAsync(from, to, durMs, holdMs, liftMs, noInertia, token, next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.51：滑动(手动)——按录制轨迹回放
        PTFakeRecSwipeAsync(a[@"pts"], token, next);
    } else if ([type isEqualToString:@"tapManual"]) {
        // v1.0.51：点击(手动)——按录制的真实点击点注入
        NSArray *pts = a[@"pts"];
        CGPoint p = pts.count ? CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]) : CGPointMake(200, 400);
        PTFakeTap(p, 30);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTapManual"]) {
        // v1.0.51：双击(手动)——两次点击，间隔按录制时间戳
        NSArray *pts = a[@"pts"];
        CGPoint p0 = pts.count >= 1 ? CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]) : CGPointMake(200, 400);
        CGPoint p1 = pts.count >= 2 ? CGPointMake([pts[1][@"x"] doubleValue], [pts[1][@"y"] doubleValue]) : p0;
        double gapMs = (pts.count >= 2) ? ([pts[1][@"t"] doubleValue] - [pts[0][@"t"] doubleValue]) : 120.0;
        if (gapMs < 40) gapMs = 40;
        PTFakeTap(p0, 30);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gapMs / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p1, 30);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        // v1.0.48：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// 执行方案动作序列（顺序全执行；防抖；执行中不再被新键中断）
static void PTExecutePlan(NSString *name) {
    double now = PTNow();
    // v1.0.43：防抖 = 「序列执行中」或「距上次执行开始 < 防抖间隔」都忽略。
    // 旧版只在执行开始时记 gLastExec：长滑动（执行时长 > 防抖间隔）期间按新键会越过
    // 防抖去中断旧序列 → 滑动残缺/掐死（狂按 bug 的根源）。现在执行窗口也被防抖覆盖，
    // 序列跑完前不可能被新键掐断；v1.0.39 弃置中断 / v1.0.40 静止衰减 / v1.0.41
    // Began 延迟 40ms 等修复保留作纵深防御，正常路径不再触发。
    if (gExecRunning || (now - gLastExec < gDebounceMs / 1000.0)) {
        PTLog(@"[执行] 防抖：忽略 %@（执行中=%d，%.0fms 内已执行）", name, gExecRunning, gDebounceMs);
        return;
    }
    gLastExec = now;
    NSDictionary *p = gPlans[name];
    NSArray *actions = p[@"actions"] ?: @[];
    if (!actions.count) { PTLog(@"[执行] %@ 无动作，跳过", name); return; }
    gExecToken++;
    int token = gExecToken;
    gIsInjecting = YES;
    gExecRunning = YES;
    PTLog(@"[执行] 命中 %@，开始动作序列（%lu 条）", name, (unsigned long)actions.count);
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        // v1.0.39：被新序列替代（token 换代）时直接退出，不再动 gIsInjecting——
        // 新序列已同步置 YES，旧 runNext 若清 NO 会误清新序列的执行态
        // v1.0.43：gExecRunning 防抖下序列不会被替代，token 换代仅作纵深防御
        if (token != gExecToken) return;
        if (idx >= (int)actions.count) { gIsInjecting = NO; gExecRunning = NO; PTLog(@"[执行] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// ============================================================
// hook
// ============================================================
static IMP gOrigAddEvent = NULL;
static void PTImpAddEvent(id self, SEL _cmd, void *event) {
    PTLoadConfig(NO);   // 每次事件刷新配置（设置页改动即时生效）
    if (event && pGetSender && pGetType) {
        uint32_t type = pGetType(event);
        uint64_t sender = pGetSender(event);
        if (type == 11) {
            gCurSender = sender;
            if (gIsPreferences && gLearnActive) {
                // 学习（Preferences 进程，设置页 bundle 自 hook 已处理，tweak 在此旁路不 hook）
                gPagerWindowUntil = PTNow() + kPagerWindowSec;
            } else if (PTIsLearnedSender(sender)) {
                // 运行（生效 App）：已学 sender → 开窗口 + 放行原文
                // 方向键/点击键统一走 sendEvent 会话通道（v1.0.20，与测试区同款链路）
                double dx = pGetFloat ? pGetFloat(event, 0x23) : 0;
                double dy = pGetFloat ? pGetFloat(event, 0x24) : 0;
                PTLog(@"[addEvent] 已学 sender=0x%llx → 会话通道（HID 位移观察 dx=%.2f dy=%.2f）", sender, dx, dy);
                gPagerWindowUntil = PTNow() + kPagerWindowSec;
            }
        }
    }
    ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

static IMP gOrigSendEvent = NULL;
static void PTImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    PTLoadConfig(NO);   // 每次事件刷新配置（设置页改动即时生效）
    // v1.0.55：跨进程手动录制采集块已删除（录制改在设置页进程内 PTRecView 完成，
    // 不再在 sendEvent 抓真实触摸；运行时回放见 PTFakeRecSwipeAsync）。
    // v1.0.32：窗口/会话判断始终优先（含映射执行中）——
    // 翻页器按键（已学 sender）无论是否执行中，一律拦截整段吞：执行中按键会命中→
    // 防抖内忽略 / 防抖外中断旧序列重启新序列，绝不放行原始滑动（根除双动作）；
    // 注入触摸靠 gInFakeTouch 精确放行（注入触摸没有 addEvent、sender 残留翻页器，
    // 若走 PTHandlePagerEvent 会把映射触摸的 Began 吞掉 → 映射失效）
    // v1.0.43：拦截判定移到可视化之前——被整段吞掉（命中执行/未命中重放）的触摸
    // 直接 return，不再画绿点轨迹；只有 App 实际收到的触摸才画
    if (event && !gInFakeTouch && (PTNow() < gPagerWindowUntil || gSession.active)) {
        if (PTHandlePagerEvent(event)) return;
    }
    // v1.0.43：调试可视化只画「App 实际收到的触摸」——注入动作 / 未命中重放的合成
    // 轨迹 / 手指触摸 / 未学 sender 都走到这里正常画点；被拦截吞掉的翻页器原始轨迹
    // 不再可见（此前在拦截判定前画点，命中时原始轨迹+注入轨迹同时显示，误以为没吞干净）
    if (gMasterEnabled && gDebugDots && event) {
        for (UITouch *t in event.allTouches) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
        }
    }
    if (gIsInjecting) {
        ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    // v1.0.27 诊断：所有触摸会话 Began 打一行 sender（手指/翻页器都记），
    // 用于实测证明手指 sender ≠ 翻页器 sender（方案 A 安全前置验证）
    // v1.0.54：守卫到 gDebugLogEnabled——默认日志开时仍记录(诊断用),关闭则连
    // allTouches 都不 materialize,避免把同步文件 IO 无条件挂到每次手指落下的热路径上
    if (gDebugLogEnabled && event) {
        for (UITouch *t in event.allTouches) {
            if (t.phase == UITouchPhaseBegan) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                PTLog(@"[touch] sender=0x%llx phase=Began pos=(%.1f,%.1f)", gCurSender, p.x, p.y);
            }
        }
    }
    ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

// ---------- swizzle（v1.0.21 改用 MSHookMessageEx） ----------
// 关键：ellekit/roothide 只注入含 _MSHookMessageEx / _MSHookFunction 符号的 dylib
// （volumekeytapper Tweak.x 注释原文："无任何 %hook 的 dylib 会被 ellekit 拒载第三方 App"）。
// 此前 method_setImplementation 不产生该符号 → 目标 App 根本没被注入。
// MSHookMessageEx 由 -lsubstrate（ellekit substrate 兼容库）提供。
static void PTHook(NSString *clsName, NSString *selName, IMP newImp, IMP *origSlot) {
    Class cls = NSClassFromString(clsName);
    if (!cls) { PTLog(@"[探测] 类不存在 %@ 跳过", clsName); return; }
    SEL sel = sel_registerName(selName.UTF8String);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PTLog(@"[探测] %@ -%@ 不存在，跳过", clsName, selName); return; }
    MSHookMessageEx(cls, sel, newImp, origSlot);
    PTLog(@"[探测] %@ -%@ 已hook ✓（MSHookMessageEx）", clsName, selName);
}

// 注入标记文件（v1.0.21 加，照抄 volumekeytapper WriteInjectMarker）：
// constructor 一被加载就写（无论是否勾选），Filza 看 /var/mobile/Documents/
// PageTurner-injected-<bid>.txt 即知该进程有没有被 dylib 注入
static void PTWriteInjectMarker(NSString *bid) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ 注入标记 进程=%@ bundleID=%@\n",
                          [NSDate date], NSProcessInfo.processInfo.processName, bid];
        NSMutableArray *paths = [NSMutableArray arrayWithArray:@[
            [NSString stringWithFormat:@"/var/mobile/Documents/PageTurner-injected-%@.txt", bid],
            @"/var/mobile/Documents/PageTurner-injected.txt",
            [NSString stringWithFormat:@"/tmp/PageTurner-injected-%@.txt", bid]]];
        // v1.0.29：jbroot 真实路径兜底（roothide 下 /var/mobile/Documents 可能被沙盒重定向）
        NSString *jb = PTJbrootRoot();
        if (jb.length) {
            [paths addObject:[jb stringByAppendingPathComponent:
                [NSString stringWithFormat:@"var/mobile/Documents/PageTurner-injected-%@.txt", bid]]];
        }
        for (NSString *p in paths) {
            PTEnsureLogFile(p);
            FILE *f = fopen(p.UTF8String, "a");
            if (f) { fputs(line.UTF8String, f); fclose(f); }
        }
    } @catch (NSException *e) {}
}

__attribute__((constructor))
static void PTInit() {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID.length) return;
        gBundleID = bundleID;
        gIsPreferences = [bundleID isEqualToString:kPrefsBundleID];
        PTLoadConfig(YES);

        NSString *home = NSHomeDirectory();
        NSString *logPath = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"PageTurner.log"];
        gLogPath = strdup([logPath UTF8String]);

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            pGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
            pGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
            pGetFloat = (IOHIDEventGetFloatValue_t)dlsym(iokit, "IOHIDEventGetFloatValue");
        }
        PTLog(@"==================================================");
        PTLog(@"PageTurner v1.0.55 已注入 %@ (pid=%d) isPrefs=%d", bundleID, getpid(), gIsPreferences);
        PTLog(@"配置路径=%@ 总开关=%d 探针=%d 可视化=%d 生效App数=%lu 防抖=%.0fms 方案数=%lu 已学sender=%d",
              gCfgPath, gMasterEnabled, gProbeEnabled, gDebugDots,
              (unsigned long)gEnabledApps.count, gDebounceMs,
              (unsigned long)gPlans.count, gLearnedSenderCount);
        // 注入标记（无条件写）：Filza 看 /var/mobile/Documents/PageTurner-injected-<bid>.txt
        PTWriteInjectMarker(bundleID);
        if (gIsPreferences) {
            // 学习收集由设置页 bundle 内自 hook 负责（roothide 空 Filter 不注入系统 App，
            // tweak 在此进程收不到事件；bundle 必然被 PreferenceLoader 加载）。
            // tweak 不 hook，避免双收集。
            PTLog(@"Preferences 进程旁路：学习收集由设置页 bundle 负责");
        } else if (gMasterEnabled && [gEnabledApps containsObject:bundleID]) {
            // 生效 App：hook 拦截
            PTHook(@"_UIUpdateHIDDigitizerInput", @"addEvent:", (IMP)PTImpAddEvent, &gOrigAddEvent);
            PTHook(@"UIApplication", @"sendEvent:", (IMP)PTImpSendEvent, &gOrigSendEvent);
            PTLog(@"生效 App 就绪：学过的 sender 按键将被拦截");
        } else {
            PTLog(@"旁路：未生效 App（bundleID=%@ 不在列表(%lu)或总开关=%d）",
                  bundleID, (unsigned long)gEnabledApps.count, gMasterEnabled);
        }
        // v1.0.24 注入探针（照抄 VKT ShowProbeAlert）：第三方 App 启动 2.5s 弹，
        // 显示 本App/注入✅/全局配置/总开关/crashTest/勾选App数/本App被勾选 ——
        // 打开番茄小说一眼看出注入成功没、有没有勾选
        // v1.0.29：探针独立开关（不跟总开关），调试可视化归 debugDots
        if (!gIsPreferences && gProbeEnabled && ![bundleID hasPrefix:@"com.apple."]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PTShowProbeAlert(); });
        }
        // v1.0.24 提醒条（勾选生效 App）：黑底白字+黄边框、中上方、2 秒。
        // 有提醒条 = 注入成功（用户要求：打勾了那这个提醒条就有）；v1.0.29 归探针开关
        if (!gIsPreferences && gProbeEnabled && [gEnabledApps containsObject:bundleID]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PTShowToast(@"PageTurner 注入成功 · 翻页键映射生效中"); });
        }
        PTLog(@"==================================================");
    }
}
