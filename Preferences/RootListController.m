// ============================================================
// RootListController.m —— PageTurner 设置页（v1.0.56）
//
// v1.0.56（废代码清理 + 滑动(手动)录制合并，与运行端同步）：
//   1. 删除 tapManual/doubleTapManual 废案全链路（测试分支/列表显示/类型转换）——实测仅
//      滑动(手动)有效；旧配置残留动作点击与长按均弹「该动作已删除」提醒，不进编辑页。
//   2. 滑动(手动)：新增 PTRecSwipeVC 灰色 pan 手势录制器（无穿透），新增入口与旧配置
//      重录都走它；落盘 @{x,y,t}，与运行端 PTFakeRecSwipeAsync（CADisplayLink 回放）一致。
//
// v1.0.43（9 项改进，与运行端同步）：
//   1. 增加特征：重复特征时右上角「保存」置灰禁止 + 已记录清空（防止把旧记录当新特征保存）
//   2. 调试可视化：测试页命中方案时不再画翻页器原始轨迹（只显示 App 实际收到的触摸）
//   3. 动作参数页「防惯性」开关：文字不再被遮挡（标签在左、开关在右）
//   4. 方案列表页：已录制方案不再误显示「未录制」（兼容新格式 features[] 数组）
//   5. 滑动速度默认 1000pt/s（上下限不变 100~2000）；参数页滑块新增预设值可点击；
//      行距缩短（118→104）
//   6. 动作设置页绿点：解除 22pt 最小坐标钳制，可拖到屏幕任意位置/边缘
//   7. 方案页映射区新增排序：右上角「排序」→ 按住行最右侧 ≡ 手柄拖动调整执行顺序
//   8. 设置页最底部居中显示版本号
//   9. 测试区防抖同步严谨化：序列执行中（gTestInjecting）一律忽略新按键
//
// v1.0.39（滑动参数上限 + 回滑防惯性，与运行端同步）：
//   1. 参数页滑动分支：弹起停留上限 500→2000ms、滑动分段上限 48→96
//   2. 参数页滑动 6 滑块：按下停留/弹起停留/滑动速度/滑动分段/回滑距离(0~10pt)/回滑停顿(0~500ms)
//   3. 测试区滑动执行：钳制 96；backPt>0 时回滑 backPt pt（30ms 后 Moved）停 backMs 再 Ended
//   4. 新建滑动动作默认存 backPt=0/backMs=80；编辑保留参数列表加 backPt/backMs
//
// v1.0.40（测试区同步运行端惯性修复）：时间插值（速度均匀）+ 静止衰减（终点每帧位置不变
// 的 Moved，持续 max(停顿,300)ms 再 Ended，velocity 归零防惯性）
//
// v1.0.41（测试区同步运行端 v1.0.41）：①Began 延迟 40ms（弃置复位不掐死新触摸）；
// ②固定 16ms 帧（60fps 采样，轨迹点间距均匀）；③防惯性开关 noInertia（默认开，
// 开=静止衰减无惯性，关=干净利落）；④删回滑距离/回滑停顿两参数
//
// v1.0.42（调试日志总开关 + 日志上限）：调试组「调试日志」条目上方新增开关（key=debugLogEnabled，默认开），
// 下方 staticText 写明位置与作用；开关控制所有日志（设置页内存+文件、运行端文件），关=完全无日志；
// 内存日志只存最近 200 条，文件日志循环保留 1000 行（超过删最旧）；运行端改动重启目标 App 后生效
// （注：这是 v1.0.42 当时的行为；v1.0.59 起内存与文件都已统一为 500，以下方实现为准）
//
// v1.0.37（滑动时序参数扩展，与运行端同步）：
//   1. 动作参数页滑动分支：按下停留 + 弹起停留(liftMs) + 滑动速度 + 滑动分段(steps 默认12)
//   2. 测试区滑动执行：读 holdMs/liftMs/steps，到终点停 liftMs 再 Ended（与运行端统一）
//   3. 新建滑动动作默认存 liftMs=0/steps=12；编辑模式保留参数列表加 liftMs/steps
//
// v1.0.36（点击特征位移矢量匹配）：
//   1. 点击样本新增 tapDx（位移方向符号 +1右/-1左/0原地）：会话起点 sSessStart 记录，
//      Ended 时按 x 分量方向计算；学习页显示「位移：向右 0.4 pt」不再笼统"无滑动"
//   2. 点击特征匹配/去重启用位移判定：tapDx 方向符号一致 + dist 区间（容差 kTapDistSlack=0.15pt）
//      ——解决同 sender 双点击键（如 0.4 右 / 0.7 左）被误判重复的问题
//   3. 录制保存：onStable/judgeOnce 点击存 tapDx + distMin/distMax（正常录与增加特征都支持）
//   4. 旧特征无 tapDx/distMin → 自动跳过新检查（兼容）
//
// v1.0.35（设置页风格统一）：
//   1. 各子页背景 systemBackgroundColor → systemGroupedBackgroundColor
//      （灰分组背景，与插件主设置页一致）：App列表/防抖/方案列表/方案页/特征列表/
//      动作设置/调试日志；列表页 Plain→Grouped（行变白底卡片）；参数页/测试页本就灰
//   2. 学习页/测试页保持大白屏（录特征/看轨迹需要干净背景）
//   3. 方案页方案名行：透明文字 → 白底圆角卡片样式（像系统输入框），点击仍弹框改名
//   4. 方案页两个大按钮（蓝/橙）保留彩色（醒目）
//
// v1.0.34（多特征方案）：
//   1. 方案数据结构 feature(单条) → features[] 数组（兼容旧数据自动迁移读取）
//   2. 方案页按键记录区：新增【增加特征】按钮（橙色，紧挨记录按钮）——
//      进单特征学习页（onceMode）：按 1 次记录、再按覆盖、以最后一下为准、
//      至少 1 次可保存，保存后加 1 条进当前方案已录入特征（不新建方案）
//   3. 新增已录入特征列表页 PTFeaturesVC（点【已录制完成】进入）：
//      行=特征详情；点击=详情弹窗+重新录制（替换该条）；左滑=删除；无新增入口
//   4. 匹配/去重遍历 features[]（PTTestMatchFeature / PTDuplicate）
//   5. 学习页保存分流：onceMode→saveOnce；replaceIndex≥0→saveReplace（重录替换）
//
// v1.0.33（实测反馈）：
//   1. 修测试区滑动速度 bug：旧代码把 speed 当毫秒时长（固定=速度值毫秒，与距离无关，
//      短距离滑动测试区比运行端慢数倍，体感"测试慢/应用快"）；改为与运行端统一
//      时长=距离/速度，距离 200pt @1000pt/s = 0.2s
//   2. 测试区命中日志加特征细节：✓ 命中「xx」→ 映射 N 条动作（sender=… phase=… dir=… dist=…），
//      与未命中格式一致
//
// v1.0.31（深色模式适配）：
//   1. 学习页大白屏 whiteColor → systemBackgroundColor（深色模式黑底白字，不再白底白字看不清）
//   2. 学习页/测试页实时记录区 colorWithWhite:0.95/0.9 → secondarySystemBackgroundColor
//      （深色模式下浅灰底+白字看不清）
//
// v1.0.30（实测反馈修正）：
//   1. 特征稳定后不再禁止继续录——背景绿提示 + 右上角保存自己点；
//      稳定后继续按同一个键 = 增强特征（样本继续累积、轨迹继续画、
//      位移区间实时刷新，保存时用最新样本）；误按别的键只提示不混入
//
// v1.0.29（用户定稿 + 实测反馈）：
//   1. 学习页：特征稳定后不再弹命名框——背景变绿色提示「特征已稳定」，
//      右上角「保存」自己点（稳定后才可点）；保存用默认名「新方案N」（跳过重名），
//      名字以后在方案页点「方案名： xxx」再改；保存后直接回记录与映射列表（自动刷新）
//   2. 方案页 viewWillAppear 重读动作 → 新增映射/修改后返回立即显示
//   3. 学习页/测试页轨迹可视化换成调试可视化同款：起点绿点 + 方向线 + P 标记
//   4. 首页「调试」组新增【注入探针】独立开关（key=probeEnabled）：
//      探针弹窗+提醒条归它管，与调试可视化互相独立、不跟总开关
//      （v1.0.57 已删除该开关：注入探针是旧版无法注入时的兜底弹窗，早已失效）
//   5. 动作设置页支持编辑：点击方案页动作行 → 进动作设置页（预填原坐标），
//      完成=覆盖更新该条（保留已调好的时序参数）；长按仍调参数
//
// v1.0.28（定稿版）：
//   1. BUG-1 波动太大弹窗：弹出时暂停收集；「继续录」= 不清空已录、解除 15 次上限
//      继续录到稳定（增强精准性）；「重录」= 清空已录+清样本重新录
//   2. 学习页下方新增实时记录区（每次按键实时显示 sender/相位/方向/位移）
//   3. BUG-2 命名保存后：空壳方案页+学习页一起移出导航栈，返回直接回记录与映射
//   4. BUG-3 记录与映射列表 viewWillAppear 重新读 plist 刷新，返回即见新方案
//   5. 动作设置页：标题实时显示动作（点击(200,600)/双击/滑动起点→终点）；
//      内容区统一灰色；绿点全屏可拖；滑动页两绿点间画连线；速度滑块移除
//   6. 方案页：方案名改「方案名： xxxxx」一行显示（点击弹框改名）；
//      「映射区…全部动作」水平居中+字号15；长按动作弹出参数调整框
//      （点击=按下时长；双击=按下时长+两次间隔；滑动=按下停留+真实速度pt/s；延迟=时长）
//   7. 测试页下方新增实时记录区（吞了什么/映射了什么，返回即消失不保留）
//
// v1.0.23：首页「调试」组新增【调试可视化】开关（key=debugDots）：
//   注入端 dylib（Tweak.xm）读取该键，开启后所有触摸显示绿点+轨迹
//   （TrollCM 触摸轨迹思路），翻页器圆点带 P 标记，映射执行的触摸也可见。
//   用于确认"注入成功→点触生效"，无需去目标 App 猜。
//
// v1.0.19：方案页新增【测试区】→ 大白屏测试页（PTTestVC）：
//   按翻页器按键 → 完整特征匹配（sender+phase+方向±15°+dist 区间）
//   → PTFakeMetaTouch 注入点触（ptftouch 编入 bundle）→ 大绿点可视化注入位置。
//   在设置 App 内闭环验证"录特征→匹配→执行→点触"，成功即执行链路 OK。
//   执行期间 gTestInjecting 放行（防注入触摸再被 hook 递归）；测试防抖 300ms。
//
// v1.0.17：整包回滚到用户实测唯一能录多个键的版本
//   = release v1.0.4（commit 0cd50018）—— 采集逻辑逐字未动：
//   SImpAddEvent（addEvent 层拿 sender + 开 50ms 窗口）
//   → SImpSendEvent（UIEvent 层 UITouch 屏幕坐标会话，位移/方向来自这里）
//   只加了：日志系统（内存+文件双写）、调试日志页（读内存 100% 可见）、
//   addEvent sender 变化 / sendEvent 窗口内事件 / 样本 / 判重 的观察日志。
//
// 页面结构（全部在系统设置 → PageTurner）：
//   RootListController  总开关 / 指定App生效 / 防抖 / 记录与映射 / 调试可视化 / 调试日志
//   PTPlansVC           方案列表（左滑删除 / 新增方案）
//   PTPlanVC            方案页（名称 / 记录状态 / 映射区 / 新增映射）
//   PTLearnVC           学习页（大白屏录特征，轮询 plist 判定）
//   PTActionVC          动作设置（绿点①点击/双击；①②起点终点+速度滑动）
//   PTDebugLogVC        调试日志（v1.0.17 加，读内存日志尾部 + 一键复制）
//
// 学习链路：
//   - 进入学习页：写 learning.active=true + 清 learningSamples
//   - bundle 内自 hook：addEvent 拿 sender → 50ms 窗口 → sendEvent UITouch 会话
//   - 本页 NSTimer 轮询 0.3s：读走样本（清空已读）→ 判定稳定/上限/去重 → 更新 UI
//   - 稳定 → 弹命名框 → feature（sender+相位+方向+位移区间）写入方案
//
// 注意：设置页 bundle 不调用注入 dylib 的符号（dyld two-level 会崩），
//       全部 plist 读写在本文件自实现（PTRead/PTWrite）
// ============================================================

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/time.h>
#include <math.h>
#include <float.h>
#include <stdarg.h>
#import "PTFakeMetaTouch.h"
#import "PTOverlayPage.h"   // v1.0.62：点击/双击/滑动/滑动(手动) 统一模板（与 dylib 共用）

@interface PSViewController (Private)
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier;
@end

// ---------- 全部子页接口（顶部集中声明，避免跨类前向引用问题） ----------
@interface RootListController : PSListController
@end

@interface PTAppListVC : PSViewController <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray *allApps;
@property (nonatomic, strong) NSMutableArray *shown;
@property (nonatomic, strong) NSMutableSet *selected;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UISearchBar *sb;
@end

@interface PTDebounceVC : PSViewController
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valLabel;
@end

@interface PTPlansVC : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray *plans;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, assign) NSInteger dragFrom;   // v1.0.66(#5)：长按拖拽起点行（-1=未拖）
@property (nonatomic, assign) NSInteger dragRow;     // v1.0.66(#5)：当前落点行
@property (nonatomic, strong) UIView *dragSnap;      // v1.0.66(#5)：拖拽浮层快照
- (void)reload;
@end

// v1.0.62：滑动(手动)录制器已并入 common/PTOverlayPage（与 dylib 共用的统一模板）

@interface PTPlanVC : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSString *planId;   // v1.0.66-fix：方案唯一身份（重名不串名）
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *recStatus;
@property (nonatomic, strong) UILabel *addFeatureBtn;   // v1.0.34：增加特征按钮（紧挨记录按钮）
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray *actions;
@property (nonatomic, assign) NSInteger dragFrom;   // v1.0.66(#5b)：长按拖拽起点行
@property (nonatomic, assign) NSInteger dragRow;     // v1.0.66(#5b)：当前落点行
@property (nonatomic, strong) UIView *dragSnap;      // v1.0.66(#5b)：拖拽浮层快照
@property (nonatomic, assign) CGPoint dragStartPt;   // v1.0.66(#5b)：长按起点
@property (nonatomic, assign) BOOL didDrag;          // v1.0.66(#5b)：是否已进入拖动
@property (nonatomic, assign) BOOL justDragged;      // v1.0.66(#5b)：刚拖完，忽略松手误触
- (void)reload;
@end

// v1.0.34：已录入特征列表页（点方案页【已录制完成】进入：点击=详情/重录，左滑=删除，无新增入口）
@interface PTFeaturesVC : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSString *planId;   // v1.0.66-fix：方案唯一身份
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) NSMutableArray *features;
@property (nonatomic, strong) UITableView *tv;
- (void)reload;
@end

@interface PTLearnVC : PSViewController
@property (nonatomic, strong) NSString *planId;   // v1.0.66-fix：方案唯一身份
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *dirLabel;
@property (nonatomic, strong) UILabel *distLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray *mem;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL limitExceeded;   // v1.0.28：继续录后跳过 15 次上限
@property (nonatomic, strong) NSDictionary *readyFt;      // v1.0.29：稳定后的特征，等右上角保存
@property (nonatomic, assign) BOOL onceMode;       // v1.0.34：增加特征模式（按 1 次记录，再按覆盖，以最后为准）
@property (nonatomic, assign) NSInteger replaceIndex;  // v1.0.34：>=0 = 替换方案第 N 条特征（特征列表重录）
@property (nonatomic, assign) int onceCount;       // v1.0.34：增加特征模式已记录次数
@property (nonatomic, strong) CAShapeLayer *trailLayer;   // v1.0.29：调试可视化同款轨迹
@property (nonatomic, strong) UIView *trailDot;
@property (nonatomic, strong) UILabel *trailLabel;
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

// v1.0.62：点击/双击/滑动 动作设置页已并入 common/PTOverlayPage（与 dylib 共用的统一模板）

@interface PTActionParamVC : PSViewController   // v1.0.28：长按动作 → 参数调整页
@property (nonatomic, strong) NSString *planId;   // v1.0.66-fix：方案唯一身份
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, assign) NSInteger actionIndex;
@property (nonatomic, strong) NSDictionary *action;
@property (nonatomic, strong) NSArray *paramDefs;
@property (nonatomic, strong) NSMutableArray *sliders;
@property (nonatomic, strong) NSMutableArray *labels;
@property (nonatomic, strong) NSMutableArray *chips;   // v1.0.43：每行预设按钮数组（对应滑块行）
@end

@interface PTDebugLogVC : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *items;   // @[@{@"name":..., @"path":..., @"size":...}]
@end

// v1.0.59：单份日志的内容页（查看 + 一键复制）
@interface PTLogContentVC : PSViewController
@property (nonatomic, strong) NSString *logPath;
@end

@interface PTTestVC : PSViewController
@property (nonatomic, strong) NSString *planName;
@property (nonatomic, strong) UITextView *logView;   // v1.0.28：实时记录区
@property (nonatomic, strong) CAShapeLayer *trailLayer;   // v1.0.29：调试可视化同款轨迹
@property (nonatomic, strong) UIView *trailDot;
@property (nonatomic, strong) UILabel *trailLabel;
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

// ---------- 工具 ----------
static NSString *PT_PREFS = @"/var/mobile/Library/Preferences/com.yourname.pageturner.plist";
static const double kDirTol = 15.0;     // 方向容差
static const double kDistSlack = 30.0;  // 位移匹配裕度
// v1.0.36：点击位移区间容差 / 方向判定阈值（区分 0.4/0.7 这类微小位移点击键）
static const double kTapDistSlack = 0.15;
static const double kTapDxThresh = 0.05;
static const int kLearnMin = 5;         // 下限
static const int kLearnMax = 15;        // 上限
static const double kConverge = 60.0;   // 位移收敛

// v1.0.25 根因修复：设置页之前只写普通路径 /var/mobile/Library/Preferences/...，
// 第三方 App 沙盒读该路径会被系统重定向到 App 自己的容器 → 永远读不到
// （探针显示"文件不可读"）。现在照抄注入端 Tweak.xm 的 PTJbrootRoot 逻辑，
// 从本 dylib 镜像提取 .jbroot-XXX 根，把配置同时写入 jbroot 真实偏好路径 +
// 普通路径兜底，App 侧 PTGlobalPlistPath 多候选读取必有一处命中。
static NSString *PTJbrootRootC(void) {
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
            NSRange after = NSMakeRange(NSMaxRange(r), p.length - NSMaxRange(r));
            NSRange slash = [p rangeOfString:@"/" options:0 range:after];
            NSUInteger end = (slash.location != NSNotFound) ? slash.location : p.length;
            root = [p substringToIndex:end];
            break;
        }
    });
    return root;
}

// v1.0.66-fix：方案 pid 辅助（必须在 PTRead 之前定义，PTRead 会调用 PTPlanId 做惰性补发）
static NSString *PTPlanId(NSDictionary *p) {
    NSString *pid = p[@"pid"];
    return ([pid isKindOfClass:[NSString class]] && pid.length) ? pid : nil;
}
static NSDictionary *PTPlanById(NSArray *plans, NSString *pid) {
    if (!pid) return nil;
    for (NSDictionary *p in plans) if ([PTPlanId(p) isEqualToString:pid]) return p;
    return nil;
}
static NSInteger PTPlanIndexById(NSMutableArray *plans, NSString *pid) {
    if (!pid) return -1;
    for (NSUInteger i = 0; i < plans.count; i++)
        if ([PTPlanId(plans[i]) isEqualToString:pid]) return (NSInteger)i;
    return -1;
}

static void PTWrite(NSDictionary *cfg);   // 前向声明（PTRead 惰性补发 pid 落盘时要用）

static NSMutableDictionary *PTRead(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:PT_PREFS];
    if (!d) d = [NSMutableDictionary dictionary];
    // v1.0.66-fix：方案唯一身份 pid（防止重名时编辑/删除串名）。
    // 旧版方案无 pid → 首次读取时按"name#序号"惰性补发唯一 pid 并落盘；新方案创建时必带 pid。
    NSArray *plans = d[@"plans"];
    if ([plans isKindOfClass:[NSArray class]] && plans.count) {
        BOOL need = NO;
        for (NSDictionary *p in plans) { if (![PTPlanId(p) length]) { need = YES; break; } }
        if (need) {
            NSMutableSet *seen = [NSMutableSet set];
            NSMutableArray *out = [NSMutableArray array];
            int idx = 0;
            for (NSDictionary *p in plans) {
                NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
                NSString *pid = PTPlanId(np);
                if (!pid || [seen containsObject:pid]) pid = [NSString stringWithFormat:@"%@#%d", (np[@"name"] ?: @"plan"), idx];
                np[@"pid"] = pid;
                [seen addObject:pid];
                [out addObject:np];
                idx++;
            }
            d[@"plans"] = out;
            PTWrite(d);   // 落盘唯一 pid（下次读即带 pid）
        }
    }
    return d;
}

static void PTWrite(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    // 候选写入位置：jbroot 真实偏好路径（App 侧读得到）优先 + 普通路径兜底
    NSMutableArray *targets = [NSMutableArray array];
    NSString *jb = PTJbrootRootC();
    if (jb.length) {
        [targets addObject:[jb stringByAppendingPathComponent:
            [@"var/mobile/Library/Preferences" stringByAppendingPathComponent:@"com.yourname.pageturner.plist"]]];
    }
    [targets addObject:PT_PREFS];
    for (NSString *p in targets) {
        NSString *tmp = [p stringByAppendingString:@".tmp"];
        [data writeToFile:tmp atomically:YES];
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:p error:nil];
    }
}

static void PTSetLearningLocal(BOOL on) {
    NSMutableDictionary *cfg = PTRead();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTWrite(cfg);
}

// ---------- 学习收集（bundle 内自 hook，不依赖 tweak 注入 Preferences 进程）----------
// 根因：roothide 空 Filter 不注入系统 App（Preferences），tweak 收集链路失效。
// bundle 必然被 PreferenceLoader 加载进 Preferences 进程，在这里自己 hook 事件收集样本。
static double PTNowC(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// ---------- 日志系统（v1.0.17 加：内存+文件双写；v1.0.42：受调试日志开关控制）----------
static NSMutableArray *sLogLines = nil;      // 内存日志（日志页直接显示；v1.0.59 起循环保留最近 500 条）
static NSString *sLogPath = nil;             // 文件日志实际路径（nil=全部不可写）
static double sLogCfgMtime = -1;             // v1.0.42：配置 mtime 缓存（开关改动即时生效）
static BOOL sLogEnabled = YES;               // v1.0.42：受 debugLogEnabled 控制
static void SLogRefreshCfg(void) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:PT_PREFS error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (mtime == sLogCfgMtime) return;
    sLogCfgMtime = mtime;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:PT_PREFS];
    sLogEnabled = (cfg[@"debugLogEnabled"] == nil) ? YES : [cfg[@"debugLogEnabled"] boolValue];
}
// 设置页自己的日志写到「共享 jbroot 的 Documents」（PageTurner.log，不带 bundleID）。
// 注意：与 App 侧同目录只是为了清理时一处搞定，不代表设置页要读别人的文件——
// 各 App 的 PageTurner-<bid>.log 只有「勾选生效」的 App 才会写，且由 buildLogItems 按 enabledApps 枚举。
static NSString *SLogProbePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    NSString *jb = PTJbrootRootC();
    if (jb.length) [cands addObject:[jb stringByAppendingPathComponent:@"var/mobile/Documents"]];
    [cands addObject:@"/var/mobile/Documents"];
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (doc.length) [cands addObject:doc];
    [cands addObject:NSTemporaryDirectory()];
    for (NSString *d in cands) {
        if (!d.length) continue;
        if (![fm fileExistsAtPath:d]) [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm isWritableFileAtPath:d]) return [d stringByAppendingPathComponent:@"PageTurner.log"];
    }
    return nil;
}

// v1.0.59：清空全部日志（内存 + 所有 PageTurner*.log 文件）；调试日志开关关闭时调用
static void PTClearAllLogs(void) {
    @try {
        [sLogLines removeAllObjects];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray *dirs = [NSMutableArray array];
        NSString *jb = PTJbrootRootC();
        if (jb.length) [dirs addObject:[jb stringByAppendingPathComponent:@"var/mobile/Documents"]];
        [dirs addObject:@"/var/mobile/Documents"];
        for (NSString *dir in dirs) {
            NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
            for (NSString *it in items ?: @[]) {
                if ([it hasPrefix:@"PageTurner"] && [it hasSuffix:@".log"]) {
                    [fm removeItemAtPath:[dir stringByAppendingPathComponent:it] error:nil];
                }
            }
        }
        sLogPath = nil;   // 下次重新探测
    } @catch (NSException *e) {}
}
// 文件日志循环保留最近 500 行（删最旧，保留尾部 500 行；v1.0.42 时曾为 1000，v1.0.59 起与内存统一为 500）
static void SLogTrimFile(NSString *path) {
    @try {
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!content) return;
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        if (lines.count > 500) {
            NSArray *keep = [lines subarrayWithRange:NSMakeRange(lines.count - 500, 500)];
            [[keep componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {}
}
static void SLog(NSString *fmt, ...) {
    SLogRefreshCfg();
    if (!sLogEnabled) return;   // v1.0.42：日志开关关=内存/文件都不记
    if (!sLogLines) sLogLines = [NSMutableArray array];
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec; struct tm tmv; localtime_r(&sec, &tmv);
    char tbuf[64]; strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@", tbuf, (int)(tv.tv_usec/1000), msg];
    if (sLogLines.count >= 500) [sLogLines removeObjectsInRange:NSMakeRange(0, 250)];   // v1.0.59：500 条循环
    [sLogLines addObject:line];
    if (!sLogPath) sLogPath = SLogProbePath();
    if (sLogPath) {
        static int sFileLines = 0;   // 文件行数计数（>500 循环，与上方 SLogTrimFile 一致）
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
        if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; sFileLines++; } @catch (NSException *e) {} }
        if (sFileLines > 500) { SLogTrimFile(sLogPath); sFileLines = 500; }
    } else {
        static BOOL sWarned = NO;
        if (!sWarned) { sWarned = YES; [sLogLines addObject:@"[SLog] ⚠️ 所有候选路径都不可写（仅内存日志）"]; }
    }
}

typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
static IOHIDEventGetType_t sGetType = NULL;
static IOHIDEventGetSenderID_t sGetSender = NULL;
static uint64_t sCurSender = 0;
static double sWindowUntil = 0;
static BOOL sHooked = NO;
static BOOL sCollectArmed = NO;      // 学习页打开时置 YES
static BOOL sSessActive = NO;
static double sSessDist = 0, sSessFirstDir = 0;
static BOOL sSessHasMove = NO;
static CGPoint sSessLast = {0, 0};
static CGPoint sSessStart = {0, 0};   // v1.0.36：会话起点（算点击位移方向符号）
static double sLastSampleAt = 0;     // 最近一次样本时间（学习页诊断用）
static IMP gOrigAddEvent = NULL;
static IMP gOrigSendEvent = NULL;

static void SAppendSample(int phase, double dir, double dist, int tapDx) {
    NSMutableDictionary *cfg = PTRead();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sCurSender],
        @"phase": @(phase), @"direction": @(dir), @"dist": @(dist),
        @"tapDx": @(tapDx),   // v1.0.36：点击位移方向符号（+1/-1/0）
    }];
    cfg[@"learningSamples"] = samples;
    PTWrite(cfg);
    SLog(@"sample: sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d (总数%lu)", sCurSender, phase, dir, dist, tapDx, (unsigned long)samples.count);
    sLastSampleAt = PTNowC();
}

// ============================================================
// 测试模式（v1.0.19 加）：方案页 → 测试区 → 大白屏测试页
// 在设置 App 内闭环验证"录特征 → 匹配 → 执行动作 → 点触可视化"。
// 设置 App 里翻页器方向键走 UITouch 会话通道（与学习端同口径），
// 匹配用完整特征（sender+phase+方向±15°+dist 区间），
// 执行 = PTFakeMetaTouch 注入 + 大绿点显示注入位置（VolumeKeyTapper 式可视化）。
// 成功即证明执行链路 OK，无需去目标 App 实测。
// ============================================================
static BOOL sTestArmed = NO;          // 测试页打开时置 YES
static BOOL gTestInjecting = NO;      // 注入保护（防执行触摸再被本 hook 处理）
static UIView *sTestDot = nil;        // 测试页绿点视图（起点绿点）
static CAShapeLayer *sTestLine = nil; // v1.0.66(#3)：方向线
static UIView *sTestP = nil;          // v1.0.66(#3)：终点 P 标记
static NSMutableArray *sTestTrail = nil; // v1.0.66-fix：滑动(手动)回放尾巴轨迹点（起点→…→当前）
static int sTestTrailToken = 0;       // v1.0.66-fix：尾巴淡出令牌（防止上一段回放的余留淡出误清当前轨迹）
static double sLastTestExec = 0;      // 测试防抖
static __weak PTTestVC *sTestLogSink = nil;   // v1.0.28：测试页实时记录区（页面销毁即失效）

// v1.0.34：方案特征集合（新格式 features[] 数组；兼容旧格式单条 feature）
static NSArray *PTFeaturesOfPlan(NSDictionary *p) {
    if (p[@"features"]) return p[@"features"];
    if (p[@"feature"]) return @[p[@"feature"]];
    return @[];
}

// 匹配（复制 Tweak.xm PTMatchPlan：sender + phase + 方向±15° + dist 区间）
// v1.0.36：点击也启用位移匹配（tapDx 方向符号 + dist 区间小容差）
static NSString *PTTestMatchFeature(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *best = nil; double bestScore = DBL_MAX;
    for (NSDictionary *p in (PTRead()[@"plans"] ?: @[])) {
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;
            }
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > 15.0) continue;
            double lo = 0, hi = 0;
            if (phase == 1) {
                lo = [ft[@"distMin"] doubleValue];
                hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - 30.0 || dist > hi + 30.0) continue;
            } else {
                if (ft[@"tapDx"]) {
                    if (tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (phase == 1 ? fabs(dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; best = p[@"name"]; }
        }
    }
    return best;
}

// v1.0.66-fix：懒建 sTestLine / sTestP 覆盖层（供 PTTestShowDot 与滑动尾巴渲染共用）
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

// v1.0.66(#3)：轨迹可视化统一成「调试可视化同款」——起点绿点 + 方向线 + 终点 P 标记（真实坐标）。
// 此前只画一个移动绿点（无方向线/无 P），与引擎回放回调(drawTrailWithDirection)样式不一致；现统一。
// 注：本函数画「单段手势」（tap / 直线 swipe），from→to 是一条直线；滑动(手动)的连续尾巴见 PTTestDrawTrailHead。
static void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur) {
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

// v1.0.66-fix：滑动(手动)回放逐帧把当前点追加进「尾巴」折线（起点→…→当前）并渲染，绿点移到当前、P 隐藏。
// 此前每帧 PTTestShowDot(cur,cur) 把方向线画成零长（不可见）+ P 标记跟着跳动，看着像"点击连成"，没有连续尾巴。
static void PTTestDrawTrailHead(CGPoint cur) {
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

// v1.0.66-fix：滑动(手动)回放结束——终点显示 P，整条尾巴保留 hold 时长后淡出（用令牌防串场）
static void PTTestTrailFinish(CGPoint pN, double hold) {
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

// 点触注入（复制 Tweak.xm：PTFakeMetaTouch，KIF 合成触摸，与 volumekeytapper 同源）
static void PTTestTap(CGPoint p, BOOL doubleTap) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    PTTestShowDot(p, p, NO, 0);
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    usleep(30000);
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    if (doubleTap) {
        usleep(120000);
        PTTestShowDot(p, p, NO, 0);
        NSInteger pid2 = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
        usleep(30000);
        [PTFakeMetaTouch fakeTouchId:pid2 AtPoint:p withTouchPhase:UITouchPhaseEnded];
    }
}

// v1.0.52：滑动(手动)测试区回放——按录制轨迹逐点注入（保持时间间隔，最短 8ms 防风暴）
// v1.0.61：录制轨迹插值（与引擎 PTRecSwipeInterp 一致）——按目标时间在录制点之间线性插值。
// 此前设置页没有插值、直接把录制点当触摸事件发，点少时只有 Began+Ended，退化成「点击」。
static CGPoint PTTestRecSwipeInterp(NSArray *xs, NSArray *ys, NSArray *ts, double targetT) {
    NSUInteger m = [ts count];
    if (m == 0) return CGPointZero;
    double tA = [ts[0] doubleValue], tB = [ts[m - 1] doubleValue];
    if (targetT <= tA) return CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]);
    if (targetT >= tB) return CGPointMake([xs[m - 1] doubleValue], [ys[m - 1] doubleValue]);
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

static void PTTestRecSwipeAsync(NSArray *pts, void (^done)(void)) {
    if (pts.count < 2) {
        // 不足两点无法插值：退化为一次短按（避免什么都不做）
        if (pts.count == 1) {
            CGPoint p = CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]);
            NSInteger tid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
            PTTestShowDot(p, p, NO, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                [PTFakeMetaTouch fakeTouchId:tid AtPoint:p withTouchPhase:UITouchPhaseEnded];
                if (done) done();
            });
        } else if (done) done();
        return;
    }
    // 预解析 @{x,y,t}（避免每帧反复解包）
    NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array], *ts = [NSMutableArray array];
    for (NSDictionary *p in pts) {
        [xs addObject:@([p[@"x"] doubleValue])];
        [ys addObject:@([p[@"y"] doubleValue])];
        [ts addObject:@([p[@"t"] doubleValue])];
    }
    double t0 = [ts[0] doubleValue];
    double totalMs = [ts[ts.count - 1] doubleValue] - t0;
    if (totalMs <= 0) totalMs = 200;    // 录制时间异常 → 给默认时长，避免瞬间完成
    if (totalMs < 50) totalMs = 50;   // 下限与引擎画轨迹一致（录制时长异常短时的兜底，避免退化成点击）

    CGPoint p0 = CGPointMake([xs[0] doubleValue], [ys[0] doubleValue]);
    CGPoint pN = CGPointMake([xs[ts.count - 1] doubleValue], [ys[ts.count - 1] doubleValue]);
    sTestTrailToken++;   // v1.0.66-fix：新一段回放开始，作废上一段余留的淡出
    sTestTrail = [NSMutableArray array];
    PTTestDrawTrailHead(p0);   // 起点绿点 + 空尾巴（p0 自身即第一点）

    // v1.0.61：与引擎 PTFakeRecSwipeAsync 对齐——60fps 逐帧插值回放，位置连续 → 真正的拖动
    // v1.0.66-fix：逐帧把当前点追加进尾巴折线（PTTestDrawTrailHead），形成连续尾巴轨迹，而非零长方向线
    __block NSInteger pid = -1;
    __block BOOL ended = NO;
    __block CFAbsoluteTime startT = CFAbsoluteTimeGetCurrent();
    __block void (^tick)(void);
    tick = ^(void) {
        if (ended) return;
        double elapsedMs = (CFAbsoluteTimeGetCurrent() - startT) * 1000.0;
        CGPoint cur = PTTestRecSwipeInterp(xs, ys, ts, t0 + elapsedMs);
        if (pid < 0) pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:cur withTouchPhase:UITouchPhaseBegan];
        else         [PTFakeMetaTouch fakeTouchId:pid AtPoint:cur withTouchPhase:UITouchPhaseMoved];
        PTTestDrawTrailHead(cur);   // 逐帧追加尾巴（起点→…→当前）
        if (elapsedMs >= totalMs) {
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pN withTouchPhase:UITouchPhaseEnded];
            ended = YES;
            PTTestTrailFinish(pN, totalMs / 1000.0);   // 终点 P + 尾巴保留后淡出
            if (done) done();
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)),
                       dispatch_get_main_queue(), tick);
    };
    tick();
}

// v1.0.48：音量动作类型已整体删除（第三方 App 进程无激活音频会话，读真实音量全部
// 接口返回假值，v1.0.44-47 四次实测后止损）——测试区音量函数一并删除。

// 执行单条动作 → 完成后 next()（复制 Tweak.xm PTRunAction 逻辑）
static void PTTestRunAction(NSDictionary *a, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        // v1.0.33：修测试区速度 bug——旧代码把 speed 当毫秒时长（固定 1 秒，与距离无关，
        // 短距离比运行端慢数倍）；现在与运行端统一：时长 = 距离/速度
        // v1.0.43：默认 1000pt/s 与运行端一致（旧动作缺 speed 字段兜底 1000）
        double speed = [a[@"speed"] doubleValue] ?: 1000;
        double distT = hypot(to.x - from.x, to.y - from.y);
        double durMs = (distT / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        // v1.0.37：按下停留/弹起停留 与运行端统一（可调）
        // v1.0.40：时间插值（速度均匀）+ 静止衰减（每帧发位置不变 Moved，velocity 归零防惯性）
        // v1.0.41：固定 16ms 帧（60fps）+ Began 延迟 40ms + 防惯性开关（删回滑），与运行端一致
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;   // 缺省开
        PTTestShowDot(from, to, YES, durMs / 1000.0);
        double durSec = MAX(durMs / 1000.0, 0.001);
        __block NSInteger pid = -1;
        __block void (^stillAt)(CGPoint, int);
        stillAt = ^(CGPoint pos, int ms) {
            __block int n = MAX(ms, 0) / 16;
            __block void (^still)(void);
            still = ^(void) {
                if (n <= 0) {
                    [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseEnded];
                    if (next) next();
                    return;
                }
                n--;
                [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
            };
            still();
        };
        __block CFAbsoluteTime t0;
        __block void (^step)(void);
        step = ^(void) {
            double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
            if (t >= 1.0) {
                if (noInertia) {
                    // v1.0.40 防惯性：终点每帧不动（静止衰减），持续 max(liftMs,300) 再 Ended
                    stillAt(to, MAX(liftMs, 300));
                } else {
                    // v1.0.41 关防惯性：干净利落——停 liftMs（不发事件）→ 直接弹起
                    if (liftMs > 0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                            if (next) next();
                        });
                    } else {
                        [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                        if (next) next();
                    }
                }
                return;
            }
            CGPoint pp = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pp withTouchPhase:UITouchPhaseMoved];
            // v1.0.41：固定 16ms 一帧（60fps 采样）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
        };
        // v1.0.41：Began 延迟 40ms（与运行端一致，避免旧复位掐死新触摸）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                t0 = CFAbsoluteTimeGetCurrent();
                step();
            });
        });
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.52：测试区支持滑动(手动)回放——此前缺分支被 else 跳过，注入轨迹看不到
        PTTestRecSwipeAsync(a[@"pts"], next);
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        // v1.0.48：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// 顺序执行方案动作序列（测试防抖 300ms；v1.0.43：执行中同样忽略，与运行端防抖严谨化一致）
static void PTTestExecPlan(NSString *name) {
    double now = PTNowC();
    if (gTestInjecting || now - sLastTestExec < 0.3) { SLog(@"[测试] 防抖：忽略 %@", name); return; }
    sLastTestExec = now;
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTRead()[@"plans"] ?: @[]) if ([p[@"name"] isEqualToString:name]) { plan = p; break; }
    if (!plan) return;
    NSArray *actions = plan[@"actions"] ?: @[];
    if (!actions.count) { SLog(@"[测试] %@ 无动作，跳过", name); return; }
    SLog(@"[测试] 命中「%@」，执行 %lu 条动作", name, (unsigned long)actions.count);
    gTestInjecting = YES;
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (idx >= (int)actions.count) { gTestInjecting = NO; SLog(@"[测试] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTTestRunAction(a, runNext);
    };
    runNext();
}

// 测试模式：Ended 结算 → 匹配 → 执行
// v1.0.36：加 tapDx（点击位移方向符号）
static void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *plan = PTTestMatchFeature(phase, dir, dist, sender, tapDx);
    if (plan) {
        SLog(@"[测试] 特征匹配 → 方案「%@」", plan);
        PTTestExecPlan(plan);
        NSDictionary *pp = nil;
        for (NSDictionary *p in PTRead()[@"plans"] ?: @[]) if ([p[@"name"] isEqualToString:plan]) { pp = p; break; }
        // v1.0.33：命中日志加特征细节（sender/相位/方向/位移），与未命中格式一致
        [sTestLogSink appendLog:[NSString stringWithFormat:@"✓ 命中「%@」→ 映射 %lu 条动作（sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d）",
            plan, (unsigned long)(pp[@"actions"] ? [pp[@"actions"] count] : 0), sender, phase, dir, dist, tapDx]];
        // v1.0.43：命中 → 原始轨迹已被"吞掉"，不再画翻页器原始轨迹（只显示注入点触）
    } else {
        SLog(@"[测试] 未匹配：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d（特征需先录制）", sender, phase, dir, dist, tapDx);
        [sTestLogSink appendLog:[NSString stringWithFormat:@"✗ 未命中（放行）：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d",
            sender, phase, dir, dist, tapDx]];
        // v1.0.43：未命中/放行 → 画翻页器原始轨迹（App 实际会收到它，属于该显示的轨迹）
        [sTestLogSink drawTrailWithDirection:dir dist:dist phase:phase];
    }
}

static void SImpAddEvent(id self, SEL _cmd, void *event) {
    @try {
        if (sGetType && sGetSender && event) {
            uint32_t type = sGetType(event);
            if (type == 11) {
                uint64_t sender = sGetSender(event);
                // [日志观察] sender 变化才打（心跳同 sender 不打，防刷屏）
                static uint64_t sLastLoggedSender = 0;
                if (sender != sLastLoggedSender) {
                    sLastLoggedSender = sender;
                    SLog(@"addEvent: type=11 sender=0x%llx armed=%d", sender, sCollectArmed);
                }
                sCurSender = sender;
                if (sCollectArmed || sTestArmed) sWindowUntil = PTNowC() + 0.05;
            }
        }
    } @catch (NSException *e) {}
    if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

static void SImpSendEvent(id self, SEL _cmd, UIEvent *event) {
    @try {
        if (gTestInjecting) {
            ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
            return;
        }
        if ((sCollectArmed || sTestArmed) && event && PTNowC() < sWindowUntil) {
            NSSet *touches = [event respondsToSelector:@selector(allTouches)] ? event.allTouches : nil;
            UITouch *t = [touches anyObject];
            if (t && sGetSender) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                // [日志观察] 窗口内 UITouch 事件（量小，逐条打）
                SLog(@"sendEvent: phase=%ld pos=(%.1f,%.1f) sender=0x%llx sessActive=%d",
                     (long)t.phase, p.x, p.y, sCurSender, sSessActive);
                switch (t.phase) {
                    case UITouchPhaseBegan: {
                        sSessActive = YES; sSessDist = 0; sSessHasMove = NO; sSessFirstDir = 0;
                        sSessLast = p;
                        sSessStart = p;   // v1.0.36：记录会话起点
                        break;
                    }
                    case UITouchPhaseMoved: {
                        if (sSessActive) {
                            double dx = p.x - sSessLast.x, dy = p.y - sSessLast.y;
                            double seg = hypot(dx, dy);
                            if (seg > 0) {
                                sSessDist += seg;
                                if (!sSessHasMove && sSessDist > 5) {
                                    sSessHasMove = YES;
                                    sSessFirstDir = atan2(dy, dx) * 180.0 / M_PI;
                                }
                            }
                            sSessLast = p;
                        }
                        break;
                    }
                    case UITouchPhaseEnded: {
                        if (sSessActive) {
                            sSessActive = NO;
                            int phase = (sSessDist < 30.0) ? 0 : 1;
                            double dir = sSessHasMove ? sSessFirstDir : 0;
                            // v1.0.36：点击位移方向符号（x 分量，起点→终点）
                            int tapDx = 0;
                            {
                                double dxv = p.x - sSessStart.x;
                                tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
                            }
                            SLog(@"end: dist=%.1f dir=%.1f hasMove=%d → phase=%d tapDx=%d", sSessDist, sSessFirstDir, sSessHasMove, phase, tapDx);
                            if (sTestArmed) PTTestOnEnded(phase, dir, sSessDist, sCurSender, tapDx);
                            else SAppendSample(phase, dir, sSessDist, tapDx);
                        }
                        break;
                    }
                    case UITouchPhaseCancelled: sSessActive = NO; break;
                    default: break;
                }
            }
        }
    } @catch (NSException *e) {}
    if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

static void SCollectHook(void) {
    if (sHooked) return;
    @autoreleasepool {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            sGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
            sGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
        }
        Class addCls = NSClassFromString(@"_UIUpdateHIDDigitizerInput");
        SEL addSel = sel_registerName("addEvent:");
        Method am = addCls ? class_getInstanceMethod(addCls, addSel) : NULL;
        if (am) { gOrigAddEvent = method_getImplementation(am); method_setImplementation(am, (IMP)SImpAddEvent); }

        Class appCls = NSClassFromString(@"UIApplication");
        SEL sendSel = sel_registerName("sendEvent:");
        Method sm = appCls ? class_getInstanceMethod(appCls, sendSel) : NULL;
        if (sm) { gOrigSendEvent = method_getImplementation(sm); method_setImplementation(sm, (IMP)SImpSendEvent); }

        sHooked = (gOrigAddEvent != NULL && gOrigSendEvent != NULL && sGetType != NULL && sGetSender != NULL);
        SLog(@"collect: sHooked=%d addEvent=%d sendEvent=%d getType=%d getSender=%d", sHooked, gOrigAddEvent!=NULL, gOrigSendEvent!=NULL, sGetType!=NULL, sGetSender!=NULL);
    }
}

static NSString *PTDirName(double dir) {
    if (dir >= 45 && dir <= 135) return @"下";
    if (dir > 135 || dir < -135) return @"左";
    if (dir >= -135 && dir < -45) return @"上";
    return @"右";
}

static NSString *PTActionText(NSDictionary *a) {
    NSString *t = a[@"type"];
    if ([t isEqualToString:@"tap"]) return [NSString stringWithFormat:@"点击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"doubleTap"]) return [NSString stringWithFormat:@"双击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%d,%d)→(%d,%d)", (int)[a[@"x1"] doubleValue], (int)[a[@"y1"] doubleValue], (int)[a[@"x2"] doubleValue], (int)[a[@"y2"] doubleValue]];
    if ([t isEqualToString:@"delay"]) return [NSString stringWithFormat:@"延迟 %.0fms", [a[@"ms"] doubleValue]];
    if ([t isEqualToString:@"recSwipe"]) return [NSString stringWithFormat:@"滑动(手动) %lu点", (unsigned long)[a[@"pts"] count]];
    if ([t isEqualToString:@"tapManual"] || [t isEqualToString:@"doubleTapManual"])
        return @"已删除的手动动作";   // 点击(手动)/双击(手动) 废案已删，旧配置显示提示
    if ([t isEqualToString:@"volumeUp"] || [t isEqualToString:@"volumeDown"] || [t isEqualToString:@"muteToggle"])
        return [NSString stringWithFormat:@"%@（已移除）", t];   // v1.0.48：音量动作已删除，旧配置显示提示
    return t;
}

// 与已有特征去重（v1.0.34：遍历方案所有特征）：同 sender + 同相位 + 方向接近 + 位移接近 → 返回方案名
// v1.0.36：点击也检查 tapDx（位移方向符号）+ dist 区间（小容差）
static NSString *PTDuplicate(NSDictionary *s, NSArray *plans) {
    NSString *snd = s[@"sender"];
    int phase = [s[@"phase"] intValue];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    int tapDx = [s[@"tapDx"] intValue];
    for (NSDictionary *p in plans) {
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (![ft[@"sender"] isEqualToString:snd]) continue;
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > kDirTol) continue;
            if (phase == 1) {
                double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - kDistSlack || dist > hi + kDistSlack) continue;
            } else {
                // v1.0.36：点击去重——方向符号不同不算重复；位移区间小容差
                if (ft[@"tapDx"] && tapDx != [ft[@"tapDx"] intValue]) continue;
                if (ft[@"distMin"]) {
                    double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            return p[@"name"];
        }
    }
    return nil;
}

// 稳定判定：最近 kLearnMin 个同 sender 样本方向一致 + 位移收敛
static BOOL PTStable(NSArray *mem, NSString *sender) {
    NSMutableArray *same = [NSMutableArray array];
    for (NSDictionary *s in mem) if ([s[@"sender"] isEqualToString:sender]) [same addObject:s];
    if (same.count < kLearnMin) return NO;
    NSInteger n = same.count;
    double dir = [same[n-1][@"direction"] doubleValue];
    for (NSInteger i = n - kLearnMin; i < n; i++) {
        double d = [same[i][@"direction"] doubleValue];
        double diff = fabs(fabs(dir - d)); if (diff > 180) diff = 360 - diff;
        if (diff > kDirTol) return NO;
    }
    if ([same[n-1][@"phase"] intValue] == 1) {
        double lo = DBL_MAX, hi = 0;
        for (NSInteger i = n - kLearnMin; i < n; i++) {
            double v = [same[i][@"dist"] doubleValue];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (hi - lo > kConverge) return NO;
    }
    return YES;
}

// ============================================================
// 主设置页
// ============================================================
@implementation RootListController

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"PageTurner";
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"总开关"]];
        PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用 PageTurner"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [master setProperty:@"masterEnabled" forKey:@"key"];
        [master setProperty:@YES forKey:@"default"];
        [master setProperty:@"关闭后全部按键恢复原样（不拦截）" forKey:@"staticText"];
        [specs addObject:master];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"生效范围"]];
        PSSpecifier *apps = [PSSpecifier preferenceSpecifierNamed:@"指定 App 生效"
            target:self set:nil get:nil detail:NSClassFromString(@"PTAppListVC")
            cell:PSLinkCell edit:nil];
        [apps setProperty:@"勾选后，只有这些 App 内会拦截翻页器按键；未勾选的 App 完全放行。改动即时生效。" forKey:@"staticText"];
        [specs addObject:apps];

        PSSpecifier *debounce = [PSSpecifier preferenceSpecifierNamed:@"防抖间隔"
            target:self set:nil get:nil detail:NSClassFromString(@"PTDebounceVC")
            cell:PSLinkCell edit:nil];
        [debounce setProperty:@"连续按键最小间隔，防止按住不放死循环（默认 300ms）" forKey:@"staticText"];
        [specs addObject:debounce];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"记录与映射"]];
        PSSpecifier *plans = [PSSpecifier preferenceSpecifierNamed:@"记录与映射"
            target:self set:nil get:nil detail:NSClassFromString(@"PTPlansVC")
            cell:PSLinkCell edit:nil];
        [plans setProperty:@"新增方案：录制翻页器一个按键的特征（来源+方向+位移），再映射为动作序列。左滑可删除方案。" forKey:@"staticText"];
        [specs addObject:plans];

        // v1.0.66(#6)：连滑（变速+刹停）总开关
        PSSpecifier *chain = [PSSpecifier preferenceSpecifierNamed:@"连滑提速"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [chain setProperty:@"chainEnabled" forKey:@"key"];
        [chain setProperty:@YES forKey:@"default"];
        [chain setProperty:@"同一方案连续翻页自动提速（满 5 次进入连滑，倍率最高 2x）；换成其他方案或没命中即刹停。顶部会显示连滑进度/倍率。注：连续按键间隔需小于 1.2s 才累计，超过即视为新链重新蓄力。" forKey:@"staticText"];
        [specs addObject:chain];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"调试"]];
        // v1.0.57：注入探针开关已删除（旧版无法注入时的兜底弹窗，早已失效，见 commit）
        PSSpecifier *dots = [PSSpecifier preferenceSpecifierNamed:@"调试可视化"
            target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [dots setProperty:@"debugDots" forKey:@"key"];
        [dots setProperty:@NO forKey:@"default"];
        [dots setProperty:@"开启后所有触摸显示绿点+轨迹（翻页器带P标记，映射执行也可见）。用于确认注入和点触生效。" forKey:@"staticText"];
        [specs addObject:dots];

        // v1.0.42：调试日志开关（放在日志页上方）；v1.0.59：关开关联动隐藏下方入口 + 清空日志
        NSDictionary *cfgNow = PTRead();
        BOOL logOn = (cfgNow[@"debugLogEnabled"] == nil) ? YES : [cfgNow[@"debugLogEnabled"] boolValue];
        PSSpecifier *logSw = [PSSpecifier preferenceSpecifierNamed:@"调试日志"
            target:self set:@selector(setLogEnabled:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [logSw setProperty:@"debugLogEnabled" forKey:@"key"];
        [logSw setProperty:@YES forKey:@"default"];
        [logSw setProperty:@"总日志开关：开启后记录注入/命中/执行全过程——每个日志文件循环保留最近 500 条；关闭则完全无日志，并立即清空已产生的全部日志（内存与文件）。设置页即时生效，目标 App 重启后生效。" forKey:@"staticText"];
        [specs addObject:logSw];

        // v1.0.59：仅在开关打开时显示「调试日志」详情入口（联动隐藏）
        if (logOn) {
            PSSpecifier *log = [PSSpecifier preferenceSpecifierNamed:@"调试日志"
                target:self set:nil get:nil detail:NSClassFromString(@"PTDebugLogVC")
                cell:PSLinkCell edit:nil];
            [log setProperty:@"选择要看哪份日志（设置页日志 / 各生效 App 的运行日志），查看并复制，发给开发者定位" forKey:@"staticText"];
            [specs addObject:log];
        }

        _specifiers = [specs copy];
    }
    return _specifiers;
}

// v1.0.60：版本号改为页面底部居中的 tableFooterView——没有灰框、字体固定（不再时大时小），
// 版本号动态读取 bundle 的 CFBundleShortVersionString（升版本只需改 Info.plist，代码不用动）
- (void)setupVersionFooter {
    if (self.table.tableFooterView) return;
    NSString *ver = [[NSBundle bundleForClass:self.class] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!ver.length) ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!ver.length) ver = @"?";
    CGFloat w = self.view.bounds.size.width ?: 320;
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
    foot.text = [NSString stringWithFormat:@"PageTurner v%@", ver];
    foot.textAlignment = NSTextAlignmentCenter;
    foot.font = [UIFont systemFontOfSize:13];
    foot.textColor = [UIColor secondaryLabelColor];
    foot.backgroundColor = [UIColor clearColor];
    self.table.tableFooterView = foot;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setupVersionFooter];
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    id val = PTRead()[key];
    if (!val) val = [spec propertyForKey:@"default"];
    return val ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSMutableDictionary *cfg = PTRead();
    cfg[[spec propertyForKey:@"key"]] = value;
    PTWrite(cfg);
    [self reloadSpecifiers];
}

// v1.0.59：调试日志开关——关闭时立即清空全部日志，并联动隐藏/显示「调试日志」详情入口
- (void)setLogEnabled:(id)value specifier:(PSSpecifier *)spec {
    NSMutableDictionary *cfg = PTRead();
    cfg[[spec propertyForKey:@"key"]] = value;
    PTWrite(cfg);
    if (![value boolValue]) PTClearAllLogs();
    [self reloadSpecifiers];
}

@end

// ============================================================
// App 列表子页（枚举 + 搜索 + 勾选）
// ============================================================
@implementation PTAppListVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"指定 App 生效";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.35：统一成系统设置灰分组背景（与主设置页一致）
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    NSMutableSet *sel = [NSMutableSet setWithArray:PTRead()[@"enabledApps"] ?: @[]];
    self.selected = sel;
    self.allApps = [self enumerateApps];
    self.shown = [NSMutableArray arrayWithArray:[self buildShownFrom:self.allApps]];   // v1.0.66：勾选优先置顶（进入时才重排，打勾当下列表不动）

    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 40;

    self.sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width, 44)];
    self.sb.placeholder = @"搜索 App";
    self.sb.delegate = self;
    [self.view addSubview:self.sb];

    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top + 44, self.view.bounds.size.width,
        self.view.bounds.size.height - top - 44) style:UITableViewStyleGrouped];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
}

- (NSArray *)enumerateApps {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        SEL selWs = NSSelectorFromString(@"defaultWorkspace");
        if (wsCls && [wsCls respondsToSelector:selWs]) {
            id ws = [wsCls performSelector:selWs];
            SEL selApps = NSSelectorFromString(@"allApplications");
            if (ws && [ws respondsToSelector:selApps]) {
                for (id app in [ws performSelector:selApps]) {
                    NSString *bid = nil, *name = nil;
                    SEL s1 = NSSelectorFromString(@"bundleIdentifier");
                    if (app && [app respondsToSelector:s1]) bid = [app performSelector:s1];
                    SEL s2 = NSSelectorFromString(@"localizedName");
                    if (app && [app respondsToSelector:s2]) name = [app performSelector:s2];
                    if (!bid.length || !name.length) continue;
                    UIImage *icon = nil;
                    SEL s3 = NSSelectorFromString(@"icon");
                    if (app && [app respondsToSelector:s3]) icon = [app performSelector:s3];
                    [out addObject:@{ @"name": name, @"bundle": bid, @"icon": icon ?: (id)[NSNull null] }];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return out;
}

- (NSArray *)buildShownFrom:(NSArray *)src {
    // v1.0.66：勾选优先置顶——selected 排前、其余排后；src 已按名称排好，分区后拼接即得「勾选优先 + 名称序」
    NSMutableArray *sel = [NSMutableArray array], *rest = [NSMutableArray array];
    for (NSDictionary *a in src) {
        if ([self.selected containsObject:a[@"bundle"]]) [sel addObject:a]; else [rest addObject:a];
    }
    [sel addObjectsFromArray:rest];
    return sel;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSArray *base = self.allApps;
    if (searchText.length) {
        NSMutableArray *f = [NSMutableArray array];
        for (NSDictionary *a in self.allApps) {
            if ([a[@"name"] localizedCaseInsensitiveContainsString:searchText] ||
                [a[@"bundle"] localizedCaseInsensitiveContainsString:searchText]) [f addObject:a];
        }
        base = f;
    }
    self.shown = [NSMutableArray arrayWithArray:[self buildShownFrom:base]];   // v1.0.66：搜索结果内勾选项也优先置顶
    [self.tv reloadData];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.shown.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"app";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *a = self.shown[ip.row];
    c.textLabel.text = a[@"name"];
    c.detailTextLabel.text = a[@"bundle"];
    c.imageView.image = [a[@"icon"] isKindOfClass:[UIImage class]] ? a[@"icon"] : nil;
    c.accessoryType = [self.selected containsObject:a[@"bundle"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *bid = self.shown[ip.row][@"bundle"];
    if ([self.selected containsObject:bid]) [self.selected removeObject:bid];
    else [self.selected addObject:bid];
    NSMutableDictionary *cfg = PTRead();
    cfg[@"enabledApps"] = [[self.selected allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    PTWrite(cfg);
    [tv reloadData];
}
@end

// ============================================================
// 防抖子页（滑块）
// ============================================================
@implementation PTDebounceVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"防抖间隔";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.35：统一成系统设置灰分组背景
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, top, self.view.bounds.size.width - 32, 40)];
    hint.text = @"连续按键的最小间隔（毫秒）。间隔太短时，按住翻页器不放会重复触发动作。";
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:hint];

    self.valLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 48, self.view.bounds.size.width - 32, 30)];
    self.valLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
    [self.view addSubview:self.valLabel];

    self.slider = [[UISlider alloc] initWithFrame:CGRectMake(16, top + 88, self.view.bounds.size.width - 32, 34)];
    self.slider.minimumValue = 100;
    self.slider.maximumValue = 1000;
    double cur = [PTRead()[@"debounceMs"] doubleValue];
    self.slider.value = (cur > 0) ? cur : 300;
    [self.slider addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.slider];
    [self changed];
}

- (void)changed {
    self.valLabel.text = [NSString stringWithFormat:@"%.0f ms", self.slider.value];
    NSMutableDictionary *cfg = PTRead();
    cfg[@"debounceMs"] = @(self.slider.value);
    PTWrite(cfg);
}
@end

// ============================================================
// 方案列表页（左滑删除 / 新增方案）
// ============================================================
@implementation PTPlansVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"记录与映射";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.35：统一成系统设置灰分组背景
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 40;
    self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width,
        self.view.bounds.size.height - top) style:UITableViewStyleGrouped];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
    self.dragFrom = -1; self.dragRow = -1;
    // v1.0.66(#5)：长按方案行拖拽排序（自定义浮层，零三横线）
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(planLongPress:)];
    lp.cancelsTouchesInView = YES;
    [self.tv addGestureRecognizer:lp];
    [self reload];
}

// v1.0.28 BUG-3：返回本页时重新读 plist（新方案/改名/删除即时可见，不用重进页面）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.plans = [NSMutableArray arrayWithArray:PTRead()[@"plans"] ?: @[]];
    [self.tv reloadData];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.plans.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"plan";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (ip.row < (NSInteger)self.plans.count) {
        NSDictionary *p = self.plans[ip.row];
        c.textLabel.text = p[@"name"] ?: @"（未命名）";
        // v1.0.43：用 PTFeaturesOfPlan 兼容新格式 features[]（旧代码只查 p[@"feature"]，
        // 多特征方案一律误显示「未录制」——方案列表页全未录制的 bug 根因）
        NSArray *fts = PTFeaturesOfPlan(p);
        NSArray *acts = p[@"actions"] ?: @[];
        if (fts.count) {
            NSDictionary *ft = fts.firstObject;
            NSString *d = PTDirName([ft[@"direction"] doubleValue]);
            NSString *ph = [ft[@"phase"] intValue] == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", d];
            c.detailTextLabel.text = [NSString stringWithFormat:@"来源%@ ｜ 特征 %lu 条（%@） ｜ 动作 %lu 条",
                ft[@"sender"], (unsigned long)fts.count, ph, (unsigned long)acts.count];
        } else {
            c.detailTextLabel.text = [NSString stringWithFormat:@"未录制 ｜ 动作 %lu 条", (unsigned long)acts.count];
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"新增方案";
        c.detailTextLabel.text = @"录制一个按键特征，映射为动作序列";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row < (NSInteger)self.plans.count) {
        PTPlanVC *vc = [PTPlanVC new];
        vc.planId = PTPlanId(self.plans[ip.row]);   // v1.0.66-fix：按唯一 pid 定位，重名不串
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        NSString *name = [NSString stringWithFormat:@"新方案%lu", (unsigned long)(plans.count + 1)];
        NSString *newPid = [[NSUUID UUID] UUIDString];   // v1.0.66-fix：新建即带唯一 pid
        [plans addObject:@{ @"name": name, @"pid": newPid, @"actions": @[] }];
        cfg[@"plans"] = plans;
        PTWrite(cfg);
        PTPlanVC *vc = [PTPlanVC new];
        vc.planId = newPid;
        [self.navigationController pushViewController:vc animated:YES];
        [self reload];
    }
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.plans.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        // v1.0.66-fix：按行索引删除该方案（仅删这一行对应的方案，不再按名删除全部同名）
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        if (ip.row >= 0 && ip.row < (NSInteger)plans.count) [plans removeObjectAtIndex:ip.row];
        cfg[@"plans"] = plans;
        PTWrite(cfg);
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

// v1.0.66(#5)：长按方案行拖拽排序——自定义浮层快照跟手移动，实时换序，落点钳制在方案范围内，
// 末行「新增方案」不参与拖拽（拖拽起点/落点都排除它）。
- (void)planLongPress:(UILongPressGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.tv];
    NSIndexPath *ip = [self.tv indexPathForRowAtPoint:p];
    if (g.state == UIGestureRecognizerStateBegan) {
        if (!ip || ip.row >= (NSInteger)self.plans.count) { self.dragFrom = -1; self.dragRow = -1; return; }
        self.dragFrom = ip.row; self.dragRow = ip.row;
        UITableViewCell *cell = [self.tv cellForRowAtIndexPath:ip];
        if (!cell) { self.dragFrom = -1; return; }
        self.dragSnap = [cell snapshotViewAfterScreenUpdates:NO];
        self.dragSnap.frame = cell.frame;
        [self.tv addSubview:self.dragSnap];
        cell.hidden = YES;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (self.dragFrom < 0) return;
        self.dragSnap.center = CGPointMake(self.tv.bounds.size.width / 2.0, p.y);
        NSIndexPath *target = [self.tv indexPathForRowAtPoint:p];
        NSInteger t = target ? target.row : (self.plans.count - 1);
        if (t < 0) t = 0;
        if (t >= (NSInteger)self.plans.count) t = self.plans.count - 1;   // 排除末行「新增方案」
        if (t != self.dragRow) {
            id obj = self.plans[self.dragRow];
            [self.plans removeObjectAtIndex:self.dragRow];
            [self.plans insertObject:obj atIndex:t];
            [self.tv moveRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]
                          toIndexPath:[NSIndexPath indexPathForRow:t inSection:0]];
            self.dragRow = t;
        }
        UITableViewCell *cur = [self.tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]];
        if (cur) cur.hidden = YES;   // 浮层替代当前行，隐藏真实 cell
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.dragFrom < 0) return;
        for (UITableViewCell *c in self.tv.visibleCells) c.hidden = NO;
        [self.dragSnap removeFromSuperview]; self.dragSnap = nil;
        self.dragFrom = -1; self.dragRow = -1;
        NSMutableDictionary *cfg = PTRead();
        cfg[@"plans"] = self.plans;
        PTWrite(cfg);
        [self.tv reloadData];
    }
}
@end

// ============================================================
// 方案页（名称 / 记录状态 / 映射区）
// ============================================================
@implementation PTPlanVC

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.35：统一成系统设置灰分组背景
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    // v1.0.66(#5b)：移除「排序」按钮——排序改由动作行长按拖拽完成（见 longPressAction:）
    [self reload];
}

// v1.0.29（问题2）：从动作设置页/参数页返回时重读动作，映射区立即显示新增/修改
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSDictionary *plan = PTPlanById(PTRead()[@"plans"] ?: @[], self.planId);   // v1.0.66-fix：按 pid 定位，重名不串
    if (!plan) { [self.navigationController popViewControllerAnimated:YES]; return; }
    self.planName = plan[@"name"] ?: @"";   // 仅作显示用
    self.actions = [NSMutableArray arrayWithArray:plan[@"actions"] ?: @[]];

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width;

    if (!self.nameLabel) {
        // v1.0.28：方案名一行显示「方案名： xxxxx」，点击弹框改名
        // v1.0.35：改白底圆角卡片样式（像系统设置输入框），文字居中，点击弹框改名
        self.nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top, w - 32, 40)];
        self.nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        self.nameLabel.backgroundColor = [UIColor systemBackgroundColor];
        self.nameLabel.layer.cornerRadius = 10;
        self.nameLabel.clipsToBounds = YES;
        self.nameLabel.textAlignment = NSTextAlignmentCenter;
        self.nameLabel.userInteractionEnabled = YES;
        [self.nameLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(renameTapped)]];
        [self.view addSubview:self.nameLabel];

        // 记录按钮：大按钮样式（蓝底白字），与下方「新增映射」视觉统一、紧凑
        self.recStatus = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 44, w - 32, 44)];
        self.recStatus.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.recStatus.textColor = [UIColor whiteColor];
        self.recStatus.backgroundColor = [UIColor systemBlueColor];
        self.recStatus.textAlignment = NSTextAlignmentCenter;
        self.recStatus.layer.cornerRadius = 10;
        self.recStatus.clipsToBounds = YES;
        self.recStatus.userInteractionEnabled = YES;
        [self.recStatus addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recordTapped)]];
        [self.view addSubview:self.recStatus];

        // v1.0.34：增加特征按钮（紧挨记录按钮下方）——录单个特征，以最后一次为准
        self.addFeatureBtn = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 96, w - 32, 44)];
        self.addFeatureBtn.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.addFeatureBtn.textColor = [UIColor whiteColor];
        self.addFeatureBtn.backgroundColor = [UIColor systemOrangeColor];
        self.addFeatureBtn.textAlignment = NSTextAlignmentCenter;
        self.addFeatureBtn.layer.cornerRadius = 10;
        self.addFeatureBtn.clipsToBounds = YES;
        self.addFeatureBtn.userInteractionEnabled = YES;
        [self.addFeatureBtn addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(addFeatureTapped)]];
        [self.view addSubview:self.addFeatureBtn];

        self.tv = [[UITableView alloc] initWithFrame:CGRectMake(0, top + 148, w, self.view.bounds.size.height - top - 148)
            style:UITableViewStyleGrouped];
        self.tv.dataSource = self;
        self.tv.delegate = self;
        [self.view addSubview:self.tv];

        // v1.0.28：映射区说明水平居中 + 字号 15
        // v1.0.43：补充排序入口提示
        UILabel *hv = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 32, 34)];
        hv.text = @"映射区：按一次该键 → 从上到下依次执行全部动作（点按=编辑，长按=参数，长按拖动=排序）";
        hv.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        hv.textColor = [UIColor labelColor];
        hv.textAlignment = NSTextAlignmentCenter;
        self.tv.tableHeaderView = hv;
    }
    self.nameLabel.text = [NSString stringWithFormat:@"方案名： %@", self.planName];
    // v1.0.34：已录制显示特征条数，点击进特征列表页；未录显示新增记录
    NSArray *fts = PTFeaturesOfPlan(plan);
    if (fts.count) {
        self.recStatus.text = [NSString stringWithFormat:@"✅ 已录制 %ld 条特征 · 点我查看", (long)fts.count];
        self.recStatus.backgroundColor = [UIColor systemGreenColor];
    } else {
        self.recStatus.text = @"＋ 新增记录（按翻页器同一键录特征）";
        self.recStatus.backgroundColor = [UIColor systemBlueColor];
    }
    self.addFeatureBtn.text = @"＋ 增加特征（录单个特征，以最后一次为准）";
    [self.tv reloadData];
}

// v1.0.28：点「方案名： xxxxx」弹框改名（保留改名功能）
- (void)renameTapped {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"修改方案名"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.planName;
        tf.placeholder = @"方案名";
    }];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *newName = [al.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!newName.length || [newName isEqualToString:self.planName]) return;
        NSMutableDictionary *cfg = PTRead();
        NSMutableArray *plans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
        // v1.0.66-fix：按 pid 定位要改名的方案，只改这一个（重名时不会把所有同名都改掉）
        NSInteger idx = PTPlanIndexById(plans, self.planId);
        if (idx >= 0) {
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:plans[idx]];
            np[@"name"] = newName;
            plans[idx] = np;
            cfg[@"plans"] = plans;
            PTWrite(cfg);
        }
        self.planName = newName;
        self.nameLabel.text = [NSString stringWithFormat:@"方案名： %@", newName];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)recordTapped {
    NSDictionary *plan = PTPlanById(PTRead()[@"plans"] ?: @[], self.planId);   // v1.0.66-fix：按 pid 定位
    // v1.0.34：已录制 → 进特征列表页（查看/重录/左滑删）；未录制 → 正常学习页
    if (PTFeaturesOfPlan(plan).count) {
        PTFeaturesVC *vc = [PTFeaturesVC new];
        vc.planId = self.planId;
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        PTLearnVC *vc = [PTLearnVC new];
        vc.planId = self.planId;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

// v1.0.34：增加特征——单特征学习页（按 1 次记录，再按覆盖，以最后一下为准），保存后加入已录入特征
- (void)addFeatureTapped {
    PTLearnVC *vc = [PTLearnVC new];
    vc.planId = self.planId;
    vc.onceMode = YES;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark UITableView
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.actions.count + 2; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"act";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    if (ip.row < (NSInteger)self.actions.count) {
        c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(ip.row + 1), PTActionText(self.actions[ip.row])];
        c.textLabel.textColor = [UIColor labelColor];   // v1.0.66：动作行显式设色，避免复用「新增映射/测试本方案」cell 时串色（黑→绿/蓝）
        c.accessoryType = UITableViewCellAccessoryNone;
        // v1.0.28：长按动作 → 参数调整框（左滑删除并存）
        for (UIGestureRecognizer *g in c.gestureRecognizers)
            if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) [c removeGestureRecognizer:g];
        UILongPressGestureRecognizer *lg = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressAction:)];
        [c addGestureRecognizer:lg];
    } else if (ip.row == (NSInteger)self.actions.count) {
        c.textLabel.text = @"＋ 新增映射";
        c.textLabel.textColor = [UIColor systemBlueColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"▶ 测试本方案（大白屏 + 绿点点触验证）";
        c.textLabel.textColor = [UIColor systemGreenColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.justDragged) { self.justDragged = NO; return; }   // v1.0.66(#5b)：刚拖完排序，忽略松手带来的误触
    if (ip.row < (NSInteger)self.actions.count) {
        // v1.0.29（问题6）：点击动作行 → 进动作设置页编辑（预填坐标，完成覆盖更新）
        NSDictionary *act = self.actions[ip.row];
        NSString *type = act[@"type"];
        // v1.0.48：已删除的音量动作（旧配置残留）→ 提示，不进编辑页
        if ([type isEqualToString:@"volumeUp"] || [type isEqualToString:@"volumeDown"] || [type isEqualToString:@"muteToggle"]) {
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"该动作已移除"
                message:@"音量+/音量-/静音切换已在 v1.0.48 删除（注入环境音量读取不可靠）。请在编辑中删除这个动作，换成其它动作。" 
                preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
            return;
        }
        // 点击(手动)/双击(手动) 废案已删除（旧配置残留）→ 提示，不进编辑页
        if ([type isEqualToString:@"tapManual"] || [type isEqualToString:@"doubleTapManual"]) {
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"该动作已删除"
                message:@"点击(手动)/双击(手动)已删除（废案）。请在编辑中删除这个动作，换成其它动作。"
                preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
            return;
        }
        // v1.0.62：滑动(手动)再次点击 → 统一模板重录（预载已有轨迹）
        if ([type isEqualToString:@"recSwipe"]) {
            [self presentOverlayPageWithMode:PTOverlayModeRecSwipe editIndex:ip.row editAction:act];
            return;
        }
        if (![type isEqualToString:@"delay"]) {
            PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                            : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
            [self presentOverlayPageWithMode:mode editIndex:ip.row editAction:act];
        } else {
            PTActionParamVC *vc = [PTActionParamVC new];
            vc.planId = self.planId;
            vc.actionIndex = ip.row;
            vc.action = act;
            [self.navigationController pushViewController:vc animated:YES];
        }
        return;
    }
    if (ip.row == (NSInteger)self.actions.count) { [self addActionMenu]; return; }
    // 最后一行：测试本方案（大白屏 + 绿点点触验证）
    PTTestVC *vc = [PTTestVC new];
    vc.planName = self.planName;   // 仅显示用（测试页按特征匹配执行，不按 pid 写方案）
    [self.navigationController pushViewController:vc animated:YES];
}
// v1.0.66(#5b)：动作行手势分工（Z 方案）——点按=编辑(didSelect)、长按不动=参数页、长按并拖动=排序。
// 旧「排序」按钮 + 系统编辑态手柄已删除，排序改由本长按手势的状态机完成（零三横线、无后遗症）。
- (void)longPressAction:(UILongPressGestureRecognizer *)g {
    UITableViewCell *cell = (UITableViewCell *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.didDrag = NO; self.justDragged = NO;
        self.dragFrom = -1; self.dragRow = -1;
        NSIndexPath *ip = [self.tv indexPathForCell:cell];
        if (!ip || ip.row >= (NSInteger)self.actions.count) return;
        // 点击(手动)/双击(手动) 废案已删除（旧配置残留）→ 提示，不进参数页
        NSString *ltype = self.actions[ip.row][@"type"];
        if ([ltype isEqualToString:@"tapManual"] || [ltype isEqualToString:@"doubleTapManual"]) {
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"该动作已删除"
                message:@"点击(手动)/双击(手动)已删除（废案）。请在编辑中删除这个动作，换成其它动作。"
                preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
            return;
        }
        self.dragFrom = ip.row; self.dragRow = ip.row;
        self.dragStartPt = [g locationInView:self.tv];
        // 不立即进参数页：先等 Changed 判断是否拖动；未拖动(长按不动)才在 Ended 进参数页
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (self.dragFrom < 0) return;
        CGPoint now = [g locationInView:self.tv];
        if (!self.didDrag) {
            CGFloat dx = now.x - self.dragStartPt.x, dy = now.y - self.dragStartPt.y;
            if (hypot(dx, dy) < 10.0) return;   // 未超阈值：仍算"长按不动"，不进入拖拽
            // 进入拖拽：建浮层快照替代原 cell
            self.didDrag = YES;
            UITableViewCell *c = [self.tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]];
            if (c) { self.dragSnap = [c snapshotViewAfterScreenUpdates:NO]; self.dragSnap.frame = c.frame; [self.tv addSubview:self.dragSnap]; c.hidden = YES; }
        }
        self.dragSnap.center = CGPointMake(self.tv.bounds.size.width / 2.0, now.y);
        NSIndexPath *target = [self.tv indexPathForRowAtPoint:now];
        NSInteger t = target ? target.row : (self.actions.count - 1);
        if (t < 0) t = 0;
        if (t >= (NSInteger)self.actions.count) t = self.actions.count - 1;   // 落点钳制在动作行内（不拖到「新增映射/测试」）
        if (t != self.dragRow) {
            id obj = self.actions[self.dragRow];
            [self.actions removeObjectAtIndex:self.dragRow];
            [self.actions insertObject:obj atIndex:t];
            [self.tv moveRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]
                          toIndexPath:[NSIndexPath indexPathForRow:t inSection:0]];
            self.dragRow = t;
        }
        for (UITableViewCell *c in self.tv.visibleCells) c.hidden = NO;   // 先全显，再隐藏当前行，避免 cell 复用残留隐藏
        UITableViewCell *cur = [self.tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]];
        if (cur) cur.hidden = YES;
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.dragFrom < 0) return;
        if (self.didDrag) {
            for (UITableViewCell *c in self.tv.visibleCells) c.hidden = NO;
            [self.dragSnap removeFromSuperview]; self.dragSnap = nil;
            [self saveActions];
            [self.tv reloadData];
            self.justDragged = YES;   // 防止松手瞬间被误判为点按进编辑页
        } else {
            // 长按不动 → 进参数页（原 longPressAction 行为）
            NSInteger r = self.dragFrom;
            if (r >= (NSInteger)self.actions.count) { self.dragFrom = -1; return; }
            PTActionParamVC *vc = [PTActionParamVC new];
            vc.planId = self.planId;
            vc.actionIndex = r;
            vc.action = self.actions[r];
            [self.navigationController pushViewController:vc animated:YES];
        }
        self.dragFrom = -1; self.dragRow = -1; self.didDrag = NO;
    }
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.actions.count) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *v, void (^done)(BOOL)) {
        [self.actions removeObjectAtIndex:ip.row];
        [self saveActions];
        [tv reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

// v1.0.66(#5b)：映射区排序改由 longPressAction 长按拖拽完成（见上），以下系统编辑态排序方法已删除：
// toggleEdit / canEditRowAtIndexPath / canMoveRowAtIndexPath / editingStyleForRowAtIndexPath / shouldIndentWhileEditingRowAtIndexPath
- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.row >= (NSInteger)self.actions.count) return;
    // 目标钳制在动作行范围内（系统不允许拖到非动作行，这里双保险）
    NSUInteger dest = MIN((NSUInteger)to.row, (NSUInteger)(self.actions.count - 1));
    id a = self.actions[from.row];
    [self.actions removeObjectAtIndex:from.row];
    [self.actions insertObject:a atIndex:dest];
    [self saveActions];
}

- (void)addActionMenu {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"新增映射"
        message:@"选择要添加的动作" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *items = @[
        @[@"点击", @"tap"], @[@"双击", @"doubleTap"], @[@"滑动", @"swipe"],
        @[@"滑动(手动)", @"recSwipe"],   // v1.0.55：滑动(手动)改为灰色 PTRecSwipeVC 录制（照搬 DVT pan 手势，无穿透）；点击(手动)/双击(手动)已删
        @[@"延迟", @"delay"]];   // v1.0.48：音量+/音量-/静音切换动作类型已删除
    for (NSArray *it in items) {
        [al addAction:[UIAlertAction actionWithTitle:it[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self configAction:it[1]];
        }]];
    }
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)configAction:(NSString *)type {
    if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.62：滑动(手动)——统一模板（不透明灰屏录制，落盘 @{x,y,t} 与运行端回放一致）
        [self presentOverlayPageWithMode:PTOverlayModeRecSwipe editIndex:-1 editAction:nil];
    } else if ([type isEqualToString:@"delay"]) {
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"延迟"
            message:@"输入延迟毫秒数（如 500 = 0.5 秒）" preferredStyle:UIAlertControllerStyleAlert];
        [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.keyboardType = UIKeyboardTypeNumberPad; tf.text = @"500"; }];   // v1.0.66：真实预填 500（非 placeholder），空按【添加】即添加 500
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            double ms = [al.textFields.firstObject.text doubleValue];
            if (ms > 0) { [self.actions addObject:@{@"type": @"delay", @"ms": @(ms)}]; [self saveActions]; }
        }]];
        [self presentViewController:al animated:YES completion:nil];
    } else {
        PTOverlayMode mode = [type isEqualToString:@"doubleTap"] ? PTOverlayModeDoubleTap
                        : ([type isEqualToString:@"swipe"] ? PTOverlayModeSwipe : PTOverlayModeTap);
        // v1.0.38：editIndex=-1 表示新增，避免 done 里误覆盖第 1 条映射
        [self presentOverlayPageWithMode:mode editIndex:-1 editAction:nil];
    }
}

// v1.0.62：统一模板呈现（deb：全屏 modal + 不透明灰；recStart/recStop 不需要）
- (void)presentOverlayPageWithMode:(PTOverlayMode)mode editIndex:(NSInteger)ei editAction:(NSDictionary *)ea {
    PTOverlayPage *page = [PTOverlayPage new];
    page.mode = mode;
    page.planName = self.planName;
    page.editIndex = ei;
    page.editAction = ea;
    page.translucent = NO;   // deb 不透明灰
    __weak typeof(self) wself = self;
    page.onSave = ^(NSDictionary *a, NSInteger ei2, NSDictionary *ea2) {
        [wself saveAction:a editIndex:ei2 editAction:ea2];
    };
    page.onDismiss = ^(BOOL saved) {
        [page dismissViewControllerAnimated:NO completion:nil];
    };
    page.recStart = nil;
    page.recStop = nil;
    page.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:page animated:NO completion:nil];
}

// v1.0.62：保存单条动作到方案（新增或覆盖），与引擎回放字段一致
- (void)saveAction:(NSDictionary *)a editIndex:(NSInteger)ei editAction:(NSDictionary *)ea {
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([PTPlanId(p) isEqualToString:self.planId]) {   // v1.0.66-fix：按 pid 写回，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
            // v1.0.38：editIndex>=0 且带原动作才覆盖，新增一律追加
            if (ei >= 0 && ea && ei < (NSInteger)acts.count) acts[ei] = a;
            else [acts addObject:a];
            np[@"actions"] = acts;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self.tv reloadData];
}

- (void)saveActions {
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([PTPlanId(p) isEqualToString:self.planId]) {   // v1.0.66-fix：按 pid 写回，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            np[@"actions"] = self.actions;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self.tv reloadData];
}

// v1.0.53：跨进程手动录制（v1.0.51 引入的 startManualRec/pollRecResult/applyRecResult）已整体删除——
// deb 版背景是设置页，半透明实地录制无意义；滑动(手动)改回普通【滑动】配置页直接填参数。
@end

// ============================================================
// 已录入特征列表页（v1.0.34：点方案页【已录制完成】进入）
// 行 = 特征详情；点击 = 详情/重新录制；左滑 = 删除；无新增入口
// ============================================================
@implementation PTFeaturesVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"已录入特征";
    // v1.0.35：统一成系统设置灰分组背景
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tv.dataSource = self;
    self.tv.delegate = self;
    [self.view addSubview:self.tv];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSDictionary *plan = PTPlanById(PTRead()[@"plans"] ?: @[], self.planId);   // v1.0.66-fix：按 pid 定位
    if (!plan) { [self.navigationController popViewControllerAnimated:YES]; return; }
    self.features = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(plan)];
    [self.tv reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return MAX((NSInteger)self.features.count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"ft";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (ip.row >= (NSInteger)self.features.count) {
        c.textLabel.text = @"还没有特征";
        c.detailTextLabel.text = @"点方案页【＋ 新增记录】正常录，或【＋ 增加特征】录单个";
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    NSDictionary *ft = self.features[ip.row];
    NSString *snd = ft[@"sender"] ?: @"—";
    int phase = [ft[@"phase"] intValue];
    NSString *ph = phase == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", PTDirName([ft[@"direction"] doubleValue])];
    c.textLabel.text = [NSString stringWithFormat:@"特征%ld  %@  sender=%@", (long)(ip.row + 1), ph, snd];
    if (phase == 0) {
        // v1.0.36：点击显示位移方向 + 大小
        int dx = [ft[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ %@ %.1f pt · 录 %d 次", dxs,
            PTDirName([ft[@"direction"] doubleValue]), [ft[@"distMin"] doubleValue], [ft[@"recordCount"] intValue]];
    } else {
        c.detailTextLabel.text = [NSString stringWithFormat:@"方向 %.0f° · 位移 %.0f~%.0f pt · 录 %d 次",
            [ft[@"direction"] doubleValue], [ft[@"distMin"] doubleValue], [ft[@"distMax"] doubleValue],
            [ft[@"recordCount"] intValue]];
    }
    c.textLabel.textColor = [UIColor labelColor];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= (NSInteger)self.features.count) return;
    NSDictionary *ft = self.features[ip.row];
    NSString *snd = ft[@"sender"] ?: @"—";
    int phase = [ft[@"phase"] intValue];
    NSString *ph = phase == 0 ? @"点击" : [NSString stringWithFormat:@"滑动%@", PTDirName([ft[@"direction"] doubleValue])];
    NSString *detail;
    if (phase == 0) {
        // v1.0.36：点击详情显示位移方向 + 大小
        int dx = [ft[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        detail = [NSString stringWithFormat:@"类型：%@\n来源：%@\n位移：%@ %.1f pt\n录制样本：%d 次",
            ph, snd, dxs, [ft[@"distMin"] doubleValue], [ft[@"recordCount"] intValue]];
    } else {
        detail = [NSString stringWithFormat:@"类型：%@\n来源：%@\n方向：%.0f°\n位移：%.0f ~ %.0f pt\n录制样本：%d 次",
            ph, snd, [ft[@"direction"] doubleValue], [ft[@"distMin"] doubleValue], [ft[@"distMax"] doubleValue],
            [ft[@"recordCount"] intValue]];
    }
    UIAlertController *al = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"特征%ld 详情", (long)(ip.row + 1)]
        message:detail preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"重新录制" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        // 重录 = 进学习页（正常收敛模式），保存时替换这一条；返回不保存则原特征保留
        PTLearnVC *vc = [PTLearnVC new];
        vc.planId = self.planId;
        vc.replaceIndex = ip.row;
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

// 左滑删除（v1.0.34）
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.row < (NSInteger)self.features.count;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.row >= (NSInteger)self.features.count) return;
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([PTPlanId(p) isEqualToString:self.planId]) {   // v1.0.66-fix：按 pid 删特征，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *fts = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(np)];
            [fts removeObjectAtIndex:ip.row];
            np[@"features"] = fts;
            [np removeObjectForKey:@"feature"];
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self reload];
}

@end

// ============================================================
// 学习页（大白屏录特征）
// ============================================================
@implementation PTLearnVC

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.0.34：增加特征模式（onceMode）——标题/提示不同，正常模式不变
    self.title = self.onceMode ? @"增加特征" : @"录制特征";
    // v1.0.31：深色模式适配——大白屏改系统自适应背景（浅色=白底黑字，深色=黑底白字）
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    // v1.0.29：右上角「保存」（录稳后变可点），名字用默认名以后再改
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.finished = NO;
    self.mem = [NSMutableArray array];

    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.22, w - 48, 60)];
    // v1.0.34：once 模式提示单次覆盖逻辑
    self.status.text = self.onceMode ? @"按 1 次即可记录\n再按会覆盖上一条（以最后一下为准）"
                                     : @"请一直重复按同一个键\n直到提示特征已稳定";
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [self.view addSubview:self.status];

    self.countLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4, w - 48, 30)];
    self.countLabel.text = @"已录：0 次";
    self.countLabel.textAlignment = NSTextAlignmentCenter;
    self.countLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.countLabel];

    self.dirLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 34, w - 48, 30)];
    self.dirLabel.text = @"方向：—";
    self.dirLabel.textAlignment = NSTextAlignmentCenter;
    self.dirLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.dirLabel];

    self.distLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, h * 0.4 + 68, w - 48, 30)];
    self.distLabel.text = @"位移：—";
    self.distLabel.textAlignment = NSTextAlignmentCenter;
    self.distLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.distLabel];

    // v1.0.28：实时记录区（每次按键实时显示 sender/相位/方向/位移，眼见为实）
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(16, h * 0.4 + 106, w - 32, h - (h * 0.4 + 106) - 30)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 10;
    self.logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.view addSubview:self.logView];
    [self appendLog:@"等待按键… 识别结果实时显示在这里"];

    PTSetLearningLocal(YES);
    sCollectArmed = YES;
    sLastSampleAt = PTNowC();
    SCollectHook();
    SLog(@"learn: viewDidLoad 会话已复位，armed=YES");
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
    sCollectArmed = NO;
    PTSetLearningLocal(NO);
}

- (void)back {
    [self.navigationController popViewControllerAnimated:YES];
}

// 轮询 plist：读走新样本 → 判定
- (void)poll {
    // v1.0.28 BUG-1：波动太大弹窗期间暂停收集（sCollectArmed=NO），不读样本不误报
    // v1.0.30（用户问题1）：稳定后不暂停——继续录增强特征，直到自己点保存
    if (!sCollectArmed) return;
    NSMutableDictionary *cfg = PTRead();
    NSArray *samples = cfg[@"learningSamples"] ?: @[];
    cfg[@"learningSamples"] = @[];   // 清空已读
    PTWrite(cfg);
    if (!samples.count) {
        // 诊断：一直没收到翻页器事件
        if (!self.finished && self.mem.count == 0 && PTNowC() - sLastSampleAt > 1.5) {
            self.status.text = @"⚠️ 未收到翻页器按键事件\n确认翻页器已连接、保持在前台按它";
            self.status.textColor = [UIColor systemOrangeColor];
        }
        return;
    }
    sLastSampleAt = PTNowC();
    for (NSDictionary *s in samples) [self judge:s];
}

- (void)judge:(NSDictionary *)s {
    // v1.0.34：增加特征模式——单次覆盖逻辑（不走收敛判定）
    if (self.onceMode) { [self judgeOnce:s]; return; }
    // v1.0.30（用户问题1）：稳定后仍可继续录（增强精准性）——不再 return；
    // 只接受同一个 sender 继续累积，误按别的键给提示不混入
    if (self.finished) {
        if (![s[@"sender"] isEqualToString:self.readyFt[@"sender"]]) {
            [self appendLog:[NSString stringWithFormat:@"⚠ 正在增强当前特征，请继续按同一个键（当前来源 %@）",
                self.readyFt[@"sender"]]];
            return;
        }
        [self.mem addObject:s];
        NSString *sender = s[@"sender"];
        double dir = [s[@"direction"] doubleValue];
        double dist = [s[@"dist"] doubleValue];
        int count = 0;
        for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) count++;
        self.countLabel.text = [NSString stringWithFormat:@"已录：%d 次（来源 %@）", count, sender];
        self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
        if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", dist];
        else {
            // v1.0.36：点击显示位移方向 + 大小（不再笼统显示"无滑动"）
            int dx = [s[@"tapDx"] intValue];
            NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
            self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, dist];
        }
        [self appendLog:[NSString stringWithFormat:@"✓ 增强 %d 次  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            count, sender, [s[@"phase"] intValue], dir, dist]];
        [self drawTrailWithDirection:dir dist:dist phase:[s[@"phase"] intValue]];
        // 实时刷新特征区间（保存时用最新样本，录得越多越准）
        double lo = DBL_MAX, hi = 0;
        for (NSDictionary *m in self.mem) {
            if (![m[@"sender"] isEqualToString:sender]) continue;
            double v = [m[@"dist"] doubleValue];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        NSMutableDictionary *ft = [NSMutableDictionary dictionaryWithDictionary:self.readyFt];
        ft[@"distMin"] = @(lo);
        ft[@"distMax"] = @(hi);
        self.readyFt = ft;
        return;
    }
    NSArray *plans = PTRead()[@"plans"] ?: @[];
    // 去重：与已有方案高度相似 → 拒绝
    NSString *dup = PTDuplicate(s, plans);
    if (dup) {
        SLog(@"judge: REJECT duplicate with '%@' — new{sender=%@ phase=%d dir=%.1f dist=%.1f}",
             dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]);
        self.status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", dup];
        self.status.textColor = [UIColor systemRedColor];
        [self.mem removeAllObjects];
        // v1.0.43：重复特征 → 清空已记录 + 禁止保存（双保险，与增加特征模式一致）
        self.readyFt = nil;
        self.finished = NO;
        self.navigationItem.rightBarButtonItem.enabled = NO;
        self.countLabel.text = @"已录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        [self appendLog:[NSString stringWithFormat:@"✗ 拒绝（与『%@』重复）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]]];
        return;
    }
    self.status.textColor = [UIColor labelColor];
    [self.mem addObject:s];
    NSString *sender = s[@"sender"];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    // 同 sender 计数
    int count = 0;
    for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) count++;
    SLog(@"judge: ACCEPT sender=%@ phase=%d dir=%.1f dist=%.1f count=%d", sender, [s[@"phase"] intValue], dir, dist, count);
    self.countLabel.text = [NSString stringWithFormat:@"已录：%d 次（来源 %@）", count, sender];
    self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
    if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", dist];
    else {
        // v1.0.36：点击显示位移方向 + 大小
        int dx = [s[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, dist];
    }
    [self appendLog:[NSString stringWithFormat:@"✓ 已录 %d 次  sender=%@ phase=%d dir=%.1f° dist=%.1f",
        count, sender, [s[@"phase"] intValue], dir, dist]];
    // v1.0.29：每次按键画调试可视化同款轨迹（方向线 + 绿点 + P 标记）
    [self drawTrailWithDirection:dir dist:dist phase:[s[@"phase"] intValue]];

    if (PTStable(self.mem, sender)) {
        self.status.text = @"✅ 特征已稳定，可以停止";
        self.status.textColor = [UIColor systemGreenColor];
        [self onStable:sender phase:[s[@"phase"] intValue] dir:dir];
    } else if (count >= kLearnMax && !self.limitExceeded) {
        [self onTooMany];
    } else {
        self.status.text = count < kLearnMin ? @"请继续按同一个键…" : @"特征收敛中，请继续…";
    }
}

// v1.0.34：增加特征模式——每次按键直接覆盖 readyFt（以最后一下为准），至少 1 次可保存
- (void)judgeOnce:(NSDictionary *)s {
    // 去重：与已有特征（跨方案全部特征）高度相似 → 拒绝（沿用防重复规矩）
    NSArray *plans = PTRead()[@"plans"] ?: @[];
    NSString *dup = PTDuplicate(s, plans);
    if (dup) {
        SLog(@"judgeOnce: REJECT duplicate with '%@' — new{sender=%@ phase=%d dir=%.1f dist=%.1f}",
             dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]);
        self.status.text = [NSString stringWithFormat:@"⚠️ 与已有方案『%@』高度相似\n可能按错了键，请换一个键", dup];
        self.status.textColor = [UIColor systemRedColor];
        [self appendLog:[NSString stringWithFormat:@"✗ 拒绝（与『%@』重复）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
            dup, s[@"sender"], [s[@"phase"] intValue], [s[@"direction"] doubleValue], [s[@"dist"] doubleValue]]];
        // v1.0.43：重复特征 → 右上角禁止保存 + 已记录清空（防止把之前录的旧记录
        // 当新特征保存——旧版只提示，右上角仍可点，会把旧 readyFt 存进去）
        self.readyFt = nil;
        self.finished = NO;
        self.onceCount = 0;
        self.navigationItem.rightBarButtonItem.enabled = NO;
        self.countLabel.text = @"已记录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        return;
    }
    self.status.textColor = [UIColor labelColor];
    self.onceCount++;
    NSMutableDictionary *ft = [NSMutableDictionary dictionary];
    ft[@"sender"] = s[@"sender"];
    ft[@"phase"] = s[@"phase"];
    ft[@"direction"] = s[@"direction"];
    double d = [s[@"dist"] doubleValue];
    if ([s[@"phase"] intValue] == 1) { ft[@"distMin"] = @(d); ft[@"distMax"] = @(d); }
    else {
        // v1.0.36：点击也存位移区间 + 方向符号（区分同 sender 的多个点击键）
        ft[@"distMin"] = @(d); ft[@"distMax"] = @(d);
        ft[@"tapDx"] = s[@"tapDx"] ?: @0;
    }
    ft[@"recordCount"] = @(1);
    self.readyFt = ft;
    self.finished = YES;
    NSString *sender = s[@"sender"];
    double dir = [s[@"direction"] doubleValue];
    self.countLabel.text = [NSString stringWithFormat:@"已记录：第 %d 次（来源 %@，以最后为准）", self.onceCount, sender];
    self.dirLabel.text = [NSString stringWithFormat:@"方向：%@（%.0f°）", PTDirName(dir), dir];
    if ([s[@"phase"] intValue] == 1) self.distLabel.text = [NSString stringWithFormat:@"位移：%.0f pt", d];
    else {
        // v1.0.36：点击显示位移方向 + 大小
        int dx = [s[@"tapDx"] intValue];
        NSString *dxs = dx > 0 ? @"向右" : (dx < 0 ? @"向左" : @"原地");
        self.distLabel.text = [NSString stringWithFormat:@"位移：%@ %.1f pt", dxs, d];
    }
    [self appendLog:[NSString stringWithFormat:@"✓ 记录 %d 次（覆盖上一条）  sender=%@ phase=%d dir=%.1f° dist=%.1f",
        self.onceCount, sender, [s[@"phase"] intValue], dir, d]];
    [self drawTrailWithDirection:dir dist:d phase:[s[@"phase"] intValue]];
    self.status.text = [NSString stringWithFormat:@"✅ 已记录：来源 %@｜方向 %@｜位移 %.0f pt\n\n再按会覆盖，点右上角「保存」完成",
        sender, PTDirName(dir), d];
    self.status.textColor = [UIColor systemGreenColor];
    self.navigationItem.rightBarButtonItem.enabled = YES;
    SLog(@"learn(once): 已记录 %d 次 sender=%@ phase=%d dir=%.1f dist=%.1f（等右上角保存）",
        self.onceCount, sender, [s[@"phase"] intValue], dir, d);
}

- (void)onStable:(NSString *)sender phase:(int)phase dir:(double)dir {
    if (self.finished) return;
    self.finished = YES;
    // 计算位移区间（同 sender 样本）
    double lo = DBL_MAX, hi = 0;
    for (NSDictionary *m in self.mem) {
        if (![m[@"sender"] isEqualToString:sender]) continue;
        double v = [m[@"dist"] doubleValue];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    NSMutableDictionary *ft = [NSMutableDictionary dictionary];
    ft[@"sender"] = sender;
    ft[@"phase"] = @(phase);
    ft[@"direction"] = @(dir);
    ft[@"distMin"] = @(lo);
    ft[@"distMax"] = @(hi);
    // v1.0.36：点击特征记录位移方向符号（用最后一次样本；点击方向稳定）
    if (phase == 0) {
        int lastDx = 0;
        for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) lastDx = [m[@"tapDx"] intValue];
        ft[@"tapDx"] = @(lastDx);
    }
    ft[@"recordCount"] = @([self countForSender:sender]);
    self.readyFt = ft;
    // v1.0.29：稳定后不弹框——背景绿色提示，你自己按够了点右上角「保存」；名字以后再改
    if (phase == 0) {
        NSString *dxs = ([ft[@"tapDx"] intValue] > 0) ? @"向右" : (([ft[@"tapDx"] intValue] < 0) ? @"向左" : @"原地");
        self.status.text = [NSString stringWithFormat:@"✅ 特征已稳定\n来源 %@｜%@ %@｜位移 %.1f~%.1f pt\n\n点右上角「保存」完成录制", sender, dxs, PTDirName(dir), lo, hi];
    } else {
        self.status.text = [NSString stringWithFormat:@"✅ 特征已稳定\n来源 %@｜方向 %@｜位移 %.0f~%.0f pt\n\n点右上角「保存」完成录制", sender, PTDirName(dir), lo, hi];
    }
    self.status.textColor = [UIColor whiteColor];
    self.view.backgroundColor = [UIColor systemGreenColor];
    // v1.0.31：深色模式适配——日志底改系统次级背景（绿底上白字保持）
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.navigationItem.rightBarButtonItem.enabled = YES;
    // v1.0.30（用户问题1）：稳定后不暂停收集——你还能继续按同一个键增强特征，
    // 按够了再点右上角「保存」；保存时用最新样本重算位移区间
    SLog(@"learn: 特征已稳定（不弹框），可继续录或点右上角保存 sender=%@ phase=%d dir=%.1f dist=%.0f~%.0f tapDx=%d", sender, phase, dir, lo, hi, [ft[@"tapDx"] intValue]);
}

// v1.0.29：右上角保存——默认名「新方案N」（N 跳过重名），保存后回记录与映射列表
- (void)saveTapped {
    // v1.0.34：增加特征模式——加 1 条进当前方案已录入特征，回方案页
    if (self.onceMode) { [self saveOnce]; return; }
    // v1.0.34：特征列表页重录——替换当前方案第 replaceIndex 条特征，回方案页
    if (self.replaceIndex >= 0) { [self saveReplace]; return; }
    if (!self.finished || !self.readyFt) return;
    NSDictionary *ft = self.readyFt;
    NSArray *plans = PTRead()[@"plans"] ?: @[];
    NSString *name = nil;
    for (int i = 1; i < 1000; i++) {
        NSString *cand = [NSString stringWithFormat:@"新方案%d", i];
        BOOL dupName = NO;
        for (NSDictionary *p in plans) if ([p[@"name"] isEqualToString:cand]) { dupName = YES; break; }
        if (!dupName) { name = cand; break; }
    }
    if (!name) name = @"新按键";
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *nplans = [NSMutableArray arrayWithArray:cfg[@"plans"] ?: @[]];
    // v1.0.34：新方案统一 features[] 数组存储（兼容旧 feature 单条读取）
    [nplans addObject:@{@"name": name, @"features": @[ft], @"actions": @[]}];
    cfg[@"plans"] = nplans;
    PTWrite(cfg);
    PTSetLearningLocal(NO);
    [self appendLog:[NSString stringWithFormat:@"已保存「%@」（名字可在方案页点方案名修改）", name]];
    // 回记录与映射列表（清掉学习页；列表 viewWillAppear 自动刷新，立刻看到新方案）
    NSMutableArray *stack = [NSMutableArray arrayWithArray:self.navigationController.viewControllers];
    NSUInteger base = NSNotFound;
    for (NSUInteger i = 0; i < stack.count; i++) {
        if ([stack[i] isKindOfClass:[PTPlansVC class]]) { base = i; break; }
    }
    if (base != NSNotFound) {
        [stack removeObjectsInRange:NSMakeRange(base + 1, stack.count - base - 1)];
        [self.navigationController setViewControllers:stack animated:YES];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

// v1.0.34：增加特征保存——加 1 条进当前方案 features（不新建方案），回方案页
- (void)saveOnce {
    if (!self.readyFt) return;
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    BOOL done = NO;
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([PTPlanId(p) isEqualToString:self.planId]) {   // v1.0.66-fix：按 pid 写回，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *fts = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(np)];
            [fts addObject:self.readyFt];
            np[@"features"] = fts;
            [np removeObjectForKey:@"feature"];
            [plans addObject:np];
            done = YES;
        } else [plans addObject:p];
    }
    if (!done) { [self.navigationController popViewControllerAnimated:YES]; return; }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    PTSetLearningLocal(NO);
    // 数一下该方案现在的特征数（写日志用，按 pid 取该方案）
    NSDictionary *saved = PTPlanById(plans, self.planId);
    NSUInteger total = PTFeaturesOfPlan(saved).count;
    [self appendLog:[NSString stringWithFormat:@"已增加 1 条特征（共 %lu 条），回方案页", (unsigned long)total]];
    // 回方案页（清掉学习页；方案页 viewWillAppear 自动刷新）
    NSMutableArray *stack = [NSMutableArray arrayWithArray:self.navigationController.viewControllers];
    NSUInteger base = NSNotFound;
    for (NSUInteger i = 0; i < stack.count; i++) {
        if ([stack[i] isKindOfClass:[PTPlanVC class]]) { base = i; break; }
    }
    if (base != NSNotFound) {
        [stack removeObjectsInRange:NSMakeRange(base + 1, stack.count - base - 1)];
        [self.navigationController setViewControllers:stack animated:YES];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

// v1.0.34：特征列表重录保存——替换当前方案第 replaceIndex 条特征，回方案页
- (void)saveReplace {
    if (!self.finished || !self.readyFt) return;
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    BOOL done = NO;
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([PTPlanId(p) isEqualToString:self.planId]) {   // v1.0.66-fix：按 pid 写回，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *fts = [NSMutableArray arrayWithArray:PTFeaturesOfPlan(np)];
            if (self.replaceIndex >= 0 && self.replaceIndex < (NSInteger)fts.count) {
                fts[self.replaceIndex] = self.readyFt;
            } else {
                [fts addObject:self.readyFt];
            }
            np[@"features"] = fts;
            [np removeObjectForKey:@"feature"];
            [plans addObject:np];
            done = YES;
        } else [plans addObject:p];
    }
    if (!done) { [self.navigationController popViewControllerAnimated:YES]; return; }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    PTSetLearningLocal(NO);
    [self appendLog:@"已替换特征，回方案页"];
    // 回方案页
    NSMutableArray *stack = [NSMutableArray arrayWithArray:self.navigationController.viewControllers];
    NSUInteger base = NSNotFound;
    for (NSUInteger i = 0; i < stack.count; i++) {
        if ([stack[i] isKindOfClass:[PTPlanVC class]]) { base = i; break; }
    }
    if (base != NSNotFound) {
        [stack removeObjectsInRange:NSMakeRange(base + 1, stack.count - base - 1)];
        [self.navigationController setViewControllers:stack animated:YES];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

// v1.0.29：调试可视化同款轨迹——起点绿点 + 方向线 + 终点 P 标记（点击只有 P 标记）
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase {
    [self.trailLayer removeFromSuperlayer];
    [self.trailDot removeFromSuperview];
    [self.trailLabel removeFromSuperview];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGPoint start = CGPointMake(w * 0.5, h * 0.38);   // 避开上方状态/标签区
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    dot.layer.cornerRadius = 18;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.3];
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.center = start;
    [self.view addSubview:dot];
    self.trailDot = dot;
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    lb.text = @"P";
    lb.textAlignment = NSTextAlignmentCenter;
    lb.font = [UIFont boldSystemFontOfSize:18];
    lb.textColor = [UIColor whiteColor];
    lb.backgroundColor = [UIColor systemGreenColor];
    lb.layer.cornerRadius = 18;
    lb.clipsToBounds = YES;
    if (phase == 1) {
        double rad = dir * M_PI / 180.0;
        CGPoint end = CGPointMake(start.x + cos(rad) * dist, start.y + sin(rad) * dist);
        CAShapeLayer *l = [CAShapeLayer layer];
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, start.x, start.y);
        CGPathAddLineToPoint(path, NULL, end.x, end.y);
        l.path = path;
        CGPathRelease(path);
        l.strokeColor = [UIColor systemGreenColor].CGColor;
        l.fillColor = [UIColor clearColor].CGColor;
        l.lineWidth = 3;
        [self.view.layer addSublayer:l];
        self.trailLayer = l;
        lb.center = end;
    } else {
        lb.center = start;
    }
    [self.view addSubview:lb];
    self.trailLabel = lb;
}

- (int)countForSender:(NSString *)sender {
    int c = 0;
    for (NSDictionary *m in self.mem) if ([m[@"sender"] isEqualToString:sender]) c++;
    return c;
}

// v1.0.28 BUG-1：弹窗出现 → 先暂停收集；继续录 = 不清空已录解除上限继续录（增强精准性）；
// 重录 = 清空已录 + 清样本重新录
- (void)onTooMany {
    sCollectArmed = NO;   // 弹窗期间暂停收集（poll 直接 return，不误报不误录）
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"特征波动太大"
        message:@"已录 15 次仍未稳定，建议检查按键或重录" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"继续录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.limitExceeded = YES;          // 解除 15 次上限，继续按同一键直到稳定
        sCollectArmed = YES;
        sLastSampleAt = PTNowC();
        self.status.textColor = [UIColor labelColor];
        self.status.text = @"已解除上限，继续按同一个键直到稳定…";
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"重录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        self.limitExceeded = NO;
        [self.mem removeAllObjects];
        self.countLabel.text = @"已录：0 次";
        self.dirLabel.text = @"方向：—";
        self.distLabel.text = @"位移：—";
        self.status.textColor = [UIColor labelColor];
        self.status.text = @"请一直重复按同一个键\n直到提示特征已稳定";
        NSMutableDictionary *cfg = PTRead();
        cfg[@"learningSamples"] = @[];
        PTWrite(cfg);
        sCollectArmed = YES;
        sLastSampleAt = PTNowC();
        [self appendLog:@"已重录：样本已清空"];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

// v1.0.28：实时记录区追加一行并滚动到底部
- (void)appendLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", s] : s;
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}
@end


// ============================================================
// 动作参数调整页（v1.0.28 加）：方案页长按动作进入
// 点击=按下时长；双击=按下时长+两次间隔；滑动=按下停留+真实速度(pt/s)；延迟=时长
// v1.0.43：滑块加预设值可点击 + 行距缩短（118→104）+ 防惯性开关文字不再被遮挡
// ============================================================
// v1.0.43：各参数预设值（点一下直接跳到该值）
static NSDictionary *PTParamPresets(void) {
    return @{
        @"pressMs": @[ @10, @30, @50, @100, @200, @400 ],
        @"gapMs":   @[ @50, @120, @200, @300, @500 ],
        @"holdMs":  @[ @0, @20, @50, @100, @200 ],
        @"liftMs":  @[ @0, @100, @300, @500, @1000 ],
        @"speed":   @[ @100, @300, @500, @1000, @1500, @2000 ],
        @"steps":   @[ @6, @12, @24, @48, @96 ],
        @"ms":      @[ @50, @100, @300, @500, @1000, @3000 ],
    };
}
static void *PTParamSliderKey = &PTParamSliderKey;   // UIButton -> 所属 UISlider（弱引用，slider 由 self.sliders 持有）
static void *PTParamValueKey = &PTParamValueKey;     // UIButton -> 预设数值

@implementation PTActionParamVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"动作参数";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    NSString *type = self.action[@"type"];
    NSArray *defs = nil;
    if ([type isEqualToString:@"tap"]) {
        defs = @[ @{@"key": @"pressMs", @"name": @"按下时长", @"unit": @"ms", @"min": @10, @"max": @500, @"def": @30} ];
    } else if ([type isEqualToString:@"doubleTap"]) {
        defs = @[ @{@"key": @"pressMs", @"name": @"按下时长", @"unit": @"ms", @"min": @10, @"max": @500, @"def": @30},
                  @{@"key": @"gapMs", @"name": @"两次间隔", @"unit": @"ms", @"min": @50, @"max": @800, @"def": @120} ];
    } else if ([type isEqualToString:@"swipe"]) {
        // v1.0.37：弹起停留（liftMs）+ 滑动分段（steps）与按下停留放一起
        // v1.0.39：liftMs 上限 500→2000；steps 上限 48→96
        // v1.0.41：删回滑距离/回滑停顿（防惯性开关统一管理）；新增【防惯性】开关（默认开）
        // v1.0.43：滑动速度默认 1000pt/s（上下限仍 100~2000）
        defs = @[ @{@"key": @"holdMs", @"name": @"按下停留", @"unit": @"ms", @"min": @0, @"max": @500, @"def": @20},
                  @{@"key": @"liftMs", @"name": @"弹起停留", @"unit": @"ms", @"min": @0, @"max": @2000, @"def": @0},
                  @{@"key": @"speed", @"name": @"滑动速度", @"unit": @"pt/s", @"min": @100, @"max": @2000, @"def": @1000},
                  @{@"key": @"steps", @"name": @"滑动分段", @"unit": @"段", @"min": @6, @"max": @96, @"def": @12},
                  @{@"key": @"noInertia", @"name": @"防惯性", @"type": @"switch", @"def": @YES} ];
    } else if ([type isEqualToString:@"delay"]) {
        defs = @[ @{@"key": @"ms", @"name": @"延迟时长", @"unit": @"ms", @"min": @50, @"max": @60000, @"def": @100} ];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.paramDefs = defs;
    self.sliders = [NSMutableArray array];
    self.labels = [NSMutableArray array];
    self.chips = [NSMutableArray array];
    NSDictionary *presets = PTParamPresets();

    CGFloat top = 110;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;
    CGFloat w = self.view.bounds.size.width;
    CGFloat rowH = 104;   // v1.0.43：行距缩短（原 118）
    for (int i = 0; i < (int)defs.count; i++) {
        NSDictionary *p = defs[i];
        CGFloat y = top + i * rowH;
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 26)];
        name.text = [NSString stringWithFormat:@"%@%@", p[@"name"],
            [p[@"type"] isEqualToString:@"switch"] ? @"" : [NSString stringWithFormat:@"（%@）", p[@"unit"]]];
        name.font = [UIFont systemFontOfSize:15];
        [self.view addSubview:name];
        if ([p[@"type"] isEqualToString:@"switch"]) {
            // v1.0.43：开关放右侧（标签在左、开关在右），文字不再被开关遮挡；
            // 默认值判定改为「有值取存的值，无值取默认」——旧代码 `|| 默认` 会让
            // 存了 NO 的防惯性开关显示/保存成 ON
            UISwitch *sw = [[UISwitch alloc] init];
            id v = self.action[p[@"key"]];
            sw.on = v ? [v boolValue] : [p[@"def"] boolValue];
            sw.frame = CGRectMake(w - 80, y - 2, 60, 34);
            [self.view addSubview:sw];
            [self.labels addObject:[NSNull null]];
            [self.sliders addObject:sw];
            [self.chips addObject:[NSMutableArray array]];
        } else {
            // 数值行：值在右侧同一行，中间是预设按钮，下面才是滑块
            UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(w - 120, y, 100, 26)];
            val.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightMedium];
            val.textAlignment = NSTextAlignmentRight;
            [self.view addSubview:val];
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(20, y + 54, w - 40, 34)];
            sl.minimumValue = [p[@"min"] doubleValue];
            sl.maximumValue = [p[@"max"] doubleValue];
            // v1.0.43：有存储值取存储值（含 0），无值才取默认——旧代码 `cur>0?cur:默认`
            // 会把用户调成 0 的参数（如按下停留 0）在重进页面时覆盖回默认
            id vv0 = self.action[p[@"key"]];
            sl.value = vv0 ? [vv0 doubleValue] : [p[@"def"] doubleValue];
            [self.view addSubview:sl];
            [self.labels addObject:val];
            [self.sliders addObject:sl];
            NSArray *ps = presets[p[@"key"]];
            NSMutableArray *rowChips = [NSMutableArray array];
            if (ps.count) {
                CGFloat cw = (w - 40) / ps.count;
                for (int j = 0; j < (int)ps.count; j++) {
                    double vv = [ps[j] doubleValue];
                    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                    b.frame = CGRectMake(20 + j * cw, y + 28, cw - 4, 22);
                    [b setTitle:[NSString stringWithFormat:@"%.0f", vv] forState:UIControlStateNormal];
                    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
                    b.layer.cornerRadius = 6;
                    b.layer.borderWidth = 0.8;
                    b.layer.borderColor = [UIColor systemGray4Color].CGColor;
                    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
                    objc_setAssociatedObject(b, PTParamSliderKey, sl, OBJC_ASSOCIATION_ASSIGN);
                    objc_setAssociatedObject(b, PTParamValueKey, @(vv), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [b addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
                    [self.view addSubview:b];
                    [rowChips addObject:b];
                }
            }
            [self.chips addObject:rowChips];
            [sl addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
            [self changed:sl];
        }
    }
}

// v1.0.43：点预设值 → 滑块跳到该值并刷新（高亮由 changed: 统一处理）
- (void)presetTapped:(UIButton *)b {
    UISlider *sl = objc_getAssociatedObject(b, PTParamSliderKey);
    NSNumber *v = objc_getAssociatedObject(b, PTParamValueKey);
    if (!sl || !v) return;
    sl.value = v.doubleValue;
    [self changed:sl];
}

- (void)changed:(UISlider *)sl {
    NSUInteger i = [self.sliders indexOfObject:sl];
    if (i == NSNotFound || i >= self.labels.count) return;
    ((UILabel *)self.labels[i]).text = [NSString stringWithFormat:@"%.0f", sl.value];
    // v1.0.43：高亮当前值对应的预设按钮（蓝色边框+蓝字），非当前恢复灰
    NSArray *rowChips = (i < self.chips.count) ? self.chips[i] : @[];
    for (UIButton *b in rowChips) {
        double vv = [(NSNumber *)objc_getAssociatedObject(b, PTParamValueKey) doubleValue];
        BOOL near = fabs(sl.value - vv) < 1.0;
        [b setTitleColor:near ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor] forState:UIControlStateNormal];
        b.layer.borderColor = near ? [UIColor systemBlueColor].CGColor : [UIColor systemGray4Color].CGColor;
    }
}

- (void)done {
    NSMutableDictionary *cfg = PTRead();
    NSMutableArray *plans = [NSMutableArray array];
    for (NSDictionary *p in cfg[@"plans"] ?: @[]) {
        if ([PTPlanId(p) isEqualToString:self.planId]) {   // v1.0.66-fix：按 pid 写回，重名不串
            NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:p];
            NSMutableArray *acts = [NSMutableArray arrayWithArray:np[@"actions"] ?: @[]];
            if (self.actionIndex >= 0 && self.actionIndex < (NSInteger)acts.count) {
                NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:acts[self.actionIndex]];
                for (int i = 0; i < (int)self.sliders.count && i < (int)self.paramDefs.count; i++) {
                    NSString *key = self.paramDefs[i][@"key"];
                    // 开关项写 BOOL，滑块项写数值（switch 支持备用）
                    if ([self.paramDefs[i][@"type"] isEqualToString:@"switch"]) {
                        a[key] = @(((UISwitch *)self.sliders[i]).on);
                    } else {
                        a[key] = @(roundf(((UISlider *)self.sliders[i]).value));
                    }
                }
                acts[self.actionIndex] = a;
            }
            np[@"actions"] = acts;
            [plans addObject:np];
        } else [plans addObject:p];
    }
    cfg[@"plans"] = plans;
    PTWrite(cfg);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

// ============================================================
// 调试日志页（v1.0.17 加：读内存日志尾部 + 复制）
// ============================================================
@implementation PTDebugLogVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"调试日志";
    return self;
}

// 构建日志列表——① 设置页日志 ② 各「勾选生效」App 的运行日志
// 全部位于共享 jbroot 的 Documents（诊断证实这是 App 侧与设置页唯一双向可通的路径）。
// ②只枚举 enabledApps：App 侧也只为勾选生效的 App 写文件（见 Tweak.m 的 PTInit），两侧规则一致；
// 未勾选的 App 不会生成 PageTurner-<bid>.log，列表里自然也不该出现它。
- (NSArray *)buildLogItems {
    NSMutableArray *arr = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *jb = PTJbrootRootC();
    NSMutableArray *dirs = [NSMutableArray array];
    if (jb.length) [dirs addObject:[jb stringByAppendingPathComponent:@"var/mobile/Documents"]];
    [dirs addObject:@"/var/mobile/Documents"];
    if (!dirs.count) return arr;

    // ① 设置页日志（PageTurner.log，不带 bundleID）
    NSString *mainPath = [dirs[0] stringByAppendingPathComponent:@"PageTurner.log"];
    for (NSString *dir in dirs) {
        NSString *p = [dir stringByAppendingPathComponent:@"PageTurner.log"];
        NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
        if (at) { mainPath = p; break; }
    }
    NSDictionary *mainAt = [fm attributesOfItemAtPath:mainPath error:nil];
    [arr addObject:@{@"name": @"设置页日志（PageTurner.log）", @"path": mainPath,
                     @"size": @(mainAt ? [mainAt fileSize] : 0)}];

    // ② 各生效 App 的运行日志 PageTurner-<bundleID>.log（只列已勾选生效的 App）
    NSDictionary *cfg = PTRead();
    NSArray *apps = cfg[@"enabledApps"] ?: @[];
    for (NSString *bid in apps) {
        NSString *fname = [NSString stringWithFormat:@"PageTurner-%@.log", bid];
        NSString *found = [dirs[0] stringByAppendingPathComponent:fname];
        for (NSString *dir in dirs) {
            NSString *p = [dir stringByAppendingPathComponent:fname];
            if ([fm attributesOfItemAtPath:p error:nil]) { found = p; break; }
        }
        NSDictionary *at = [fm attributesOfItemAtPath:found error:nil];
        [arr addObject:@{@"name": fname, @"path": found, @"size": @(at ? [at fileSize] : 0), @"bid": bid}];
    }
    return arr;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.items = [self buildLogItems];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"PTLogCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:ID];
    if (!c) {
        // v1.0.60：不用系统 textLabel/detailTextLabel（会与自定义布局重叠），改为自己放两层
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ID];
        c.textLabel.text = nil;
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectZero];
        sv.tag = 900; sv.showsHorizontalScrollIndicator = NO;
        UILabel *lb = [[UILabel alloc] init];
        lb.tag = 901; lb.font = [UIFont systemFontOfSize:15]; lb.textColor = [UIColor labelColor];
        [sv addSubview:lb];
        [c.contentView addSubview:sv];
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectZero];
        sub.tag = 902; sub.font = [UIFont systemFontOfSize:12]; sub.textColor = [UIColor secondaryLabelColor];
        [c.contentView addSubview:sub];
    }
    NSDictionary *it = self.items[ip.row];
    unsigned long long sz = [it[@"size"] unsignedLongLongValue];
    NSString *szTxt = sz >= 1024 ? [NSString stringWithFormat:@"%.1f KB", sz / 1024.0]
                                 : [NSString stringWithFormat:@"%llu B", sz];
    c.detailTextLabel.text = sz > 0 ? [NSString stringWithFormat:@"%@ · 点击查看", szTxt]
                                    : @"暂无内容（还没产生日志）";
    CGFloat w = self.view.bounds.size.width - 56;
    UIScrollView *sv = [c.contentView viewWithTag:900];
    UILabel *lb = [sv viewWithTag:901];
    lb.text = it[@"name"];
    [lb sizeToFit];
    sv.frame = CGRectMake(16, 9, w, lb.bounds.size.height);
    sv.contentSize = CGSizeMake(MAX(lb.bounds.size.width, w), lb.bounds.size.height);
    UILabel *sub = [c.contentView viewWithTag:902];
    sub.text = sz > 0 ? [NSString stringWithFormat:@"%@ · 点击查看", szTxt] : @"暂无内容（还没产生日志）";
    sub.frame = CGRectMake(16, 31, w, 15);
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 56; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    PTLogContentVC *vc = [PTLogContentVC new];
    vc.logPath = self.items[ip.row][@"path"];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

// ============================================================
// 日志内容页（v1.0.59：查看单份日志 + 一键复制）
// ============================================================
@implementation PTLogContentVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self.logPath lastPathComponent];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    NSString *s = [NSString stringWithContentsOfFile:self.logPath encoding:NSUTF8StringEncoding error:nil];
    NSArray *ls = s.length ? [s componentsSeparatedByString:@"\n"] : @[];
    NSUInteger n = ls.count;
    NSUInteger from = n > 500 ? n - 500 : 0;   // v1.0.59：与 500 条循环一致，最多显示 500 行
    tv.text = s.length
        ? [[ls subarrayWithRange:NSMakeRange(from, n - from)] componentsJoinedByString:@"\n"]
        : [NSString stringWithFormat:@"暂无日志内容。\n\n路径：%@\n\n可能原因：该 App 还没产生日志，或调试日志开关被关闭（关闭会清空全部日志）。", self.logPath];
    [self.view addSubview:tv];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制"
        style:UIBarButtonItemStyleDone target:self action:@selector(copyLog)];
}

- (void)copyLog {
    UITextView *tv = [self.view.subviews firstObject];
    if ([tv isKindOfClass:[UITextView class]]) UIPasteboard.generalPasteboard.string = tv.text;
}
@end

// ============================================================
// 测试页（v1.0.19 加）：大白屏 + 绿点点触可视化
// 按翻页器按键 → 匹配方案 → 执行动作 → 绿点显示注入位置
// ============================================================
@implementation PTTestVC

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"测试本方案";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 80, self.view.bounds.size.width - 32, 120)];
    tip.numberOfLines = 0;
    tip.textAlignment = NSTextAlignmentCenter;
    tip.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    tip.text = [NSString stringWithFormat:@"按翻页器按键测试方案「%@」\n\n匹配成功会执行动作序列，\n绿点 = 注入点触的位置\n（点击原地显示；滑动从起点到终点）", self.planName ?: @""];
    [self.view addSubview:tip];

    // v1.0.28：测试页下方实时记录区（吞了什么/映射了什么；返回即消失不保留）
    CGFloat h = self.view.bounds.size.height, w = self.view.bounds.size.width;
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, h - 210, w - 24, 190)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    // v1.0.31：深色模式适配——浅灰底改系统次级背景
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 10;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:self.logView];
    [self appendLog:@"等待按键… 命中/未命中实时显示在这里"];

    // 绿点：全屏可移动的可视化圆点（不拦截触摸）
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 72, 72)];
    dot.layer.cornerRadius = 36;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.35];
    dot.layer.borderWidth = 3;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.hidden = YES;
    dot.userInteractionEnabled = NO;
    [self.view addSubview:dot];

    sTestDot = dot;
    sTestArmed = YES;
    sTestLogSink = self;
    SCollectHook();
    SLog(@"test: viewDidLoad armed=YES（方案 %@）", self.planName ?: @"");
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    sTestArmed = NO;
    sTestDot = nil;
    if (sTestLine) { [sTestLine removeFromSuperlayer]; sTestLine = nil; }
    if (sTestP) { [sTestP removeFromSuperview]; sTestP = nil; }
    sTestTrail = nil;
    sTestLogSink = nil;   // 返回即消失，测试记录不保留
}

// v1.0.28：实时记录区追加一行并滚动到底部
- (void)appendLog:(NSString *)s {
    if (!self.logView) return;
    NSString *cur = self.logView.text;
    self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", s] : s;
    NSRange r = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:r];
}

// v1.0.29：调试可视化同款轨迹——起点绿点 + 方向线 + 终点 P 标记（点击只有 P 标记）
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase {
    [self.trailLayer removeFromSuperlayer];
    [self.trailDot removeFromSuperview];
    [self.trailLabel removeFromSuperview];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGPoint start = CGPointMake(w * 0.5, h * 0.38);   // 避开上方提示/下方记录区
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    dot.layer.cornerRadius = 18;
    dot.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.3];
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = [UIColor systemGreenColor].CGColor;
    dot.center = start;
    [self.view addSubview:dot];
    self.trailDot = dot;
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    lb.text = @"P";
    lb.textAlignment = NSTextAlignmentCenter;
    lb.font = [UIFont boldSystemFontOfSize:18];
    lb.textColor = [UIColor whiteColor];
    lb.backgroundColor = [UIColor systemGreenColor];
    lb.layer.cornerRadius = 18;
    lb.clipsToBounds = YES;
    if (phase == 1) {
        double rad = dir * M_PI / 180.0;
        CGPoint end = CGPointMake(start.x + cos(rad) * dist, start.y + sin(rad) * dist);
        CAShapeLayer *l = [CAShapeLayer layer];
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, start.x, start.y);
        CGPathAddLineToPoint(path, NULL, end.x, end.y);
        l.path = path;
        CGPathRelease(path);
        l.strokeColor = [UIColor systemGreenColor].CGColor;
        l.fillColor = [UIColor clearColor].CGColor;
        l.lineWidth = 3;
        [self.view.layer addSublayer:l];
        self.trailLayer = l;
        lb.center = end;
    } else {
        lb.center = start;
    }
    [self.view addSubview:lb];
    self.trailLabel = lb;
}
@end

