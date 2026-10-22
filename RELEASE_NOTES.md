# PageTurner v1.0.71

> 引擎核心抽取 `PTEngineCore`（deb / dylib / Preferences 三目标链接）+ 版本横幅宏化 + 构建配置三目标化。1.0.70 → 1.0.71。设置页删除 **~490 行**重复实现（3028 → 2538 行），修复 4 处已漂移 bug；**用户可感知的变化集中在设置页「测试本方案」测试区**（与运行端行为对齐，详见文末「行为变化」）。

## ♻️ 改动

### 1. 版本号宏化：编译期横幅单一真源
- 新增 `common/PTVersion.h`（**`.gitignore` 生成物，勿手改/勿提交**）：`#define PT_VERSION_STRING @"1.0.71"`，由 `scripts/gen_ptversion.sh` 从 `Makefile` 的 `PACKAGE_VERSION` 自动生成。
- `Makefile` 新增 `before-all::` 钩子：任何 make 调用（含 `make package`）前幂等生成头文件；CI 在 Checkout 后直接调 `scripts/gen_ptversion.sh`——巨魔 dylib 走裸 clang、不过 make 钩子，编译前头文件必须已在。
- 三处源码硬编码横幅统一改为 `PT_VERSION_STRING`。**此前三处版本号互不相同且全部落后于实际版本**：`Tweak.m` 写死 v1.0.66、`PTDylibMain.m` 写死 v1.0.65、`PTDylibUI.m` 写死 v1.0.60。
- `scripts/check_version.sh` 升级为「**四处一致**」校验（control / Info.plist / Makefile / PTVersion.h），并新增**源码层硬编码横幅扫描**——任何 `.m` 里出现 `@"PageTurner...vX.Y.Z"` 字面量即 CI 失败，横幅漂移从此不可能再发生。
- `scripts/sync_version.sh` 将 PTVersion.h 的生成委托给 `gen_ptversion.sh`（单一实现，避免两处漂移）。

### 2. 构建配置三目标化：`build/sources.mk` 升级
- 从「两份共享列表」（v1.0.70 的 `SHARED_SOURCES`/`SHARED_CFLAGS`）升级为**按使用者分组的文件 → 目标组合**模型：
  `PTSRC_KIF` / `PTSRC_ENGINE` / `PTSRC_OVERLAY` / `PTSRC_DEB` / `PTSRC_DYLIB` / `PTSRC_PREFS` 六组，相组成 `PTSRC_ALL_DEB` / `PTSRC_ALL_DYLIB` / `PTSRC_ALL_PREFS` 三个目标组合。
- **`Preferences/Makefile` 首次纳入单一真源**（`PTROOT := ..` + `include`）：此前设置页是**第三处手抄**文件列表与 flags，且已漂移——缺 `-fobjc-abi-version=2`、缺仓库根 `-I`，与 deb / dylib 的 flags 不一致。
- CI 新增「**源码覆盖审计**」：`git ls-files '*.m'` 与 `print-all-sources` 严格对账，**漏登记一个 `.m` 即构建失败**——根治「新增文件只改一处、另一个 target 静默少编译」的隐患（最坏不是链接报错，而是丢功能）。
- dylib 构建改从 `print-dylib-sources` 读取（原来手拼「共享 + PTOverlayPage + dylib 薄壳」）。

### 3. 引擎核心抽取：`PTEngineCore`（设置页 −490 行重复实现）
- 新增 `common/PTEngineCore.{h,m}`（~1278 行）：**配置读写 / jbroot 探测 / IOKit 特征匹配 / 学习样本 / 测试回放 / 连滑状态机 / 动作执行 / 日志** + 会话/执行态全局。三个目标（deb / dylib / Preferences）**全部链接**。
- `common/PTEngine.{h,m}` 瘦身为**外壳薄壳**（hook 装配 / 运行拦截会话 / 调试可视化 / 录制 / 双指菜单，仅 deb + dylib 链），**1702 → 559 行**。
- `Preferences/RootListController.m` 删除 7 份常量副本、配置读写副本、IOKit 副本、测试全家、数学四件等**全部重复实现**，改调 Core  API：**3028 → 2538 行**。
- 跨层依赖三种解法：
  - **弱引用**：`PTDebugDestroyOverlay` 用 `__attribute__((weak_import))`——Preferences 只链 Core 时为 NULL，调用前判空；
  - **写入器钩子**：`PTSetCfgWriter(PTWrite)`——设置进程双写 jbroot + 普通路径，Core 不感知外壳差异；
  - **函数抽取**：`PTChainHandleHit` 从 `PTHandlePagerEvent` 抽出——测试页与运行端**共用同一套连滑状态机**。
- 双镜像隔离：Preferences 进程中「注入的 dylib（Tweak.m + Core）」与「PreferenceLoader bundle（RootListController + Core）」各持一份 Core 静态状态，只通过配置文件通信。

### 4. 修复 4 处已漂移 bug / 隐患
- **设置页日志文件静默失效（真 bug）**：`Tweak.m` 的 `PTInit` 构造函数在 Preferences 进程也会跑，且**晚于** bundle 的 `PTPrefsEngineInit`——原来它在构造函数里无条件 `PTSetFileLogEnabled(fileLog)`，会把设置页注入的共享日志配置覆盖成 NO。修复：fileLog 设置移入「非 Preferences」分支，Preferences 进程只打旁路日志、不碰共享日志配置。
- **采集窗口不一致**：设置页 SImpAddEvent 硬编码 `0.05`，运行端为 `kCollectWindowSec = 0.30`——同一按键在两侧采样窗口差 6 倍。统一为 Core 宏。
- **常量两份命名漂移**：设置页旧名 `kDirTol` vs 引擎 `kDirTolerance`（及 kLearnMin/kLearnMax/kConverge 等 7 份副本）——统一为 Core 宏；`kMaxLearnedSenders` 必须为宏（C 中 `static const int` 做数组尺寸会退化成 VLA）。
- **dylib 测试页退场漏清**：旧实现只清 3 个状态，漏清方向线 / P 标记 / 尾巴淡出令牌——改调 Core 的 `PTTestReset()`（多清 `sTestLine`/`sTestP`/`sTestTrail` 并作废尾巴令牌）。
- 另补齐一处「调用早于定义」缺前向声明（`PTTestRunAction` → `PTFakeRecSwipeAsync`）。

## ⚠️ 行为变化（设置页测试区，属预期修复）

> 以下变化**只影响设置页「测试本方案」与调试日志的呈现**，运行端（deb 注入 / 巨魔 dylib）行为不变。原因是设置页此前的测试/日志是**另一套简化实现**，与运行端早已漂移；本次统一到 Core 后两者严格一致——「测试即所见」正是本项目的设计约定。

1. **测试区与运行端完全同行为**：连滑蓄力实时倒数（`连滑 N/5`）、升档（`⚡连滑 ×N`）、刹停、防抖、执行中放行——此前设置页测试区不走连滑状态机，这些一律不生效。
2. **采集窗口 0.05s → 0.30s**：设置页学习采集的采样窗口与运行端对齐（`kCollectWindowSec`）。
3. **设置页日志行首时间格式**：由「年月日 时分秒」统一为引擎侧「时分秒.毫秒」——设置页日志查看器与 App 运行日志现在同格式。
4. **dylib 测试页退场更干净**：退场新增清理方向线 / P 标记 / 尾巴（旧实现漏清，会留下残影）。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `common/PTEngineCore.h` / `common/PTEngineCore.m`（新增） | 引擎核心：配置/jbroot/IOKit/匹配/样本/测试回放/连滑/动作执行/日志 + 会话执行态全局；三目标全链 |
| `common/PTEngine.h` / `common/PTEngine.m` | 删全部 Core 内容，瘦身为外壳薄壳（1702 → 559 行）；保留 hook 装配/会话/可视化/录制/菜单 |
| `Preferences/RootListController.m` | 删 ~490 行重复实现（3028 → 2538 行）改调 Core；新增 `PTPrefsEngineInit` 构造函数（cfg 路径/写入器/日志/Core 就绪） |
| `Tweak.m` | 横幅改 `PT_VERSION_STRING`；fileLog 设置移入非 Preferences 分支（修设置页日志静默失效） |
| `targets/dylib/PTDylibUI.m` | 删 7 份常量副本；横幅改宏；测试页退场改调 `PTTestReset()` |
| `targets/dylib/PTDylibMain.m` | 横幅改 `PT_VERSION_STRING`；删入口注释里写死的版本号 |
| `build/sources.mk` | 三目标分组模型 + PTROOT + print-* 目标；新增 `PTSRC_CORE` 并纳入三个目标组合 |
| `Makefile` | `before-all::` 生成 PTVersion.h；`PageTurner_FILES` 改 `$(PTSRC_ALL_DEB)`；架构注释三目标化；版本 1.0.70 → 1.0.71 |
| `Preferences/Makefile` | 源文件/flags 改从仓库根 `build/sources.mk` 读取（纳入单一真源） |
| `.github/workflows/build.yml` | Checkout 后生成 PTVersion.h；新增「源码覆盖审计」步；dylib 构建读 `print-dylib-sources` |
| `scripts/gen_ptversion.sh`（新增） | 从 PACKAGE_VERSION 生成 PTVersion.h（CI / before-all 共用） |
| `scripts/check_version.sh` | 四处一致 + 源码层硬编码横幅扫描 |
| `scripts/sync_version.sh` | PTVersion.h 生成委托 `gen_ptversion.sh` |
| `.gitignore`（新增） | 收录生成物 `common/PTVersion.h` 等 |
| `control` / `Preferences/Resources/Info.plist` | 版本号 1.0.70 → 1.0.71 |
| `README.md` | 版本历史补 v1.0.71 |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.71-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.71.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

---

# PageTurner v1.0.70

> 双形态治理（构建配置单一真源 + 两道 CI 安全网 + 删掉恒 NO 的死开关）。1.0.69 → 1.0.70，**零功能改动、零引擎行为改动**，用户无感知。

## ♻️ 改动

### 1. 共享源文件 + 共享编译 flags 抽成单一真源
- 新增 `build/sources.mk`：`SHARED_SOURCES`（共享源文件）与 `SHARED_CFLAGS`（共享 flags）的唯一出处。
- `Makefile`（deb / Theos）改为 `include build/sources.mk` 后派生 `PageTurner_FILES` / `PageTurner_CFLAGS`；
  `.github/workflows/build.yml`（dylib / 裸 clang）改为用 `make -s -f build/sources.mk PRINT_CONFIG=1 print-sources|print-cflags` 读取。
- **根治的隐患**：此前共享列表在两处手填，且**已经不一致**——deb 少了 `common/PTOverlayPage.m`，dylib 少了 `-Wno-arc-retain-cycles`，
  两边 `-I` 也不一致。将来新增一个 `.m` 只改一处的话，另一个 target 会**静默少编译该文件**（最坏情况不是链接报错，而是丢功能）。

### 2. CI 新增两道 dylib 安全网
- **未定义符号审计**：dylib 用 `-Wl,-undefined,dynamic_lookup` 构建，链接期**不报**「找不到符号」，只有首次调用才崩。
  新增步骤用 `nm -u` 审计，**一旦出现 substrate 类符号（`_MSHook*` 等）即 CI 失败**——TrollStore 环境没有 substrate 可提供这些符号。
  （本次审计结果：**0 个** substrate 符号。共享引擎 `PTEngine.m` 本就没有 substrate 引用，`MSHookMessageEx` 只存在于 deb 私有的 `Tweak.m`。）
- **arm64e 不再静默降级**：此前 `arm64+arm64e` 编译失败会静默退回仅 arm64，而 iOS 15/16 上大量 App 是 arm64e，
  注入会失败却 CI 仍是绿的。新增步骤用 `lipo -info` 校验，**缺 arm64e 即 CI 失败**。

### 3. 删除恒为 NO 的死开关 `PTDylibUsingDebConfig()`
- 该函数恒 `return NO`，唯一调用点在 dylib 初始化的一行日志字符串里。它留成可翻转的布尔就是地雷：
  哪天被改成 YES，dylib 会去读写 jbroot 全局配置——既写不进第三方沙盒（v1.0.58 已实证），又会污染 deb 用户的配置。
- 处理：删除该函数及其 `extern` 声明，日志直接输出「独立配置」字面量。**行为完全一致**（原本恒输出该值）。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `build/sources.mk`（新增） | 共享源文件列表 + 共享 CFLAGS 的单一真源 |
| `Makefile` | include 单一真源；`PageTurner_FILES` / `PageTurner_CFLAGS` 改为从中派生；版本号 1.0.69 → 1.0.70 |
| `.github/workflows/build.yml` | dylib 构建改从单一真源读取；新增「未定义符号审计」「arm64e 存在性校验」两步 |
| `common/PTEngine.h` / `common/PTEngine.m` | 删除死开关 `PTDylibUsingDebConfig()` 的声明与定义 |
| `targets/dylib/PTDylibMain.m` | 日志去掉死开关调用，改为「独立配置」字面量（输出不变） |
| `control` / `Preferences/Resources/Info.plist` | 版本号 1.0.69 → 1.0.70 |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.70-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.70.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

---

# PageTurner v1.0.69

> 版本号机制打磨（1.0.68 → 1.0.69）。在「版本单一真源」基础上修正三处细节；纯工程卫生、零功能改动、用户无感知。

## ♻️ 改动

| 文件 | 改动 |
|------|------|
| `scripts/sync_version.sh` | 版本号同步改为**按 `Info.plist` 的 `<key>` 锚定**，只改 `CFBundleShortVersionString` / `CFBundleVersion` 两处；避免将来新增任何 `X.Y.Z` 形式的 `<string>` 被误改；三处已一致则早退跳过写入 |
| `Makefile` | 新增 `after-package::`：打包完成后 `git checkout -- control Preferences/Resources/Info.plist` 还原工作树，避免本地 `make package` 后 `git status` 出现脏文件、误提交 |
| `control` / `Preferences/Resources/Info.plist` | 版本号 **1.0.68 → 1.0.69** |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.69-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.69.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

---

# PageTurner v1.0.68

> 版本号单一真源 + CI 构建前一致性校验（1.0.67 → 1.0.68）。根治「control / Makefile / Info.plist 三处手填」漂移；纯工程卫生、零功能改动、用户无感知。

## ✨ 新功能（无） / ♻️ 改动

### 版本号单一真源
- 发版只改 `Makefile` 的 `PACKAGE_VERSION` 一处；打包前 `before-package::` 钩子自动把另两处（`control` / `Info.plist`）同步成同一版本，彻底避免手滑导致三处不一致。
- 新增 `scripts/sync_version.sh`（派生）与 `scripts/check_version.sh`（校验）。

### CI 构建前版本一致性校验
- `.github/workflows/build.yml` 在 Checkout 后、构建前新增一步「Verify version consistency」；三处版本号不一致则构建直接失败，把「版本漂移」挡在打包之前。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `Makefile` | 新增 `PACKAGE_VERSION` 单一真源 + `before-package::` 自动同步钩子；版本号 **1.0.67 → 1.0.68** |
| `control` / `Preferences/Resources/Info.plist` | 版本号 **1.0.67 → 1.0.68**（由 `PACKAGE_VERSION` 派生，提交态即一致） |
| `.github/workflows/build.yml` | 新增构建前「Verify version consistency」步骤 |
| `scripts/sync_version.sh`（新增） | 从 `PACKAGE_VERSION` 派生 `control` / `Info.plist` 版本号 |
| `scripts/check_version.sh`（新增） | 校验三处版本号一致，否则 `exit 1` |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.68-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.68.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

---

# PageTurner v1.0.67

> 连滑 pill 视觉重做 + 版本号正式升级（1.0.66 → 1.0.67）。绿底白字且深色模式自适应、蓄力期实时倒数、升档改 ⚡ 雷电样式；**提速模型仍保持 DVT 1:1 的 1/2/3 离散档，只换皮不改手感**。

## ✨ 新功能

### 连滑 pill：绿底白字 + 深色模式自适应
- pill 底色改为**绿色**、字体**白色半粗体**；底色用动态颜色（`colorWithDynamicProvider`）——**深色模式下自动换更深的绿**，白字在两种模式下都清晰可读，不会出现背景/字体糊成一片看不清的情况。
- 浅色模式：鲜绿 `RGB(0.18, 0.73, 0.31)` alpha 0.9；深色模式：深绿 `RGB(0.10, 0.50, 0.23)` alpha 0.95（白字对比度更高）。
- 文案、位置、2 秒自动消失等行为与之前一致。

### 蓄力期实时倒数（选项 A）
- 连按同一个翻页键的蓄力期，pill 逐级实时显示 `连滑 1/5` → `2/5` → `3/5` → `4/5`，**第 1 次命中即开始显示**；进入连滑门槛保持 **5** 次不变。
- 运行端与「测试本方案」测试页行为完全一致。

### 升档提示改 ⚡ 雷电样式
- 连滑中再按同键升档，pill 改为 `⚡连滑 ×1 / ×2 / ×3`（1→2→3→1 循环）。
- 注意：这是**选项 i**——提速模型仍是 DVT 1:1 的 1/2/3 离散档（封顶 3 倍、循环回 1、档位不记忆），本次只改提示样式，**实际手感不变**。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `common/PTEngine.m` | `PTChainPill` 绿底白字 + 动态底色（深色模式自适应）+ 半粗体；蓄力期 `连滑 N/5` 实时倒数（运行端 + 测试页，第 1 次即显示）；升档文案 `⚡连滑 ×N`；测试页防抖忽略时不出 pill |
| `control` / `Makefile` / `Preferences/Resources/Info.plist` | 版本号 **1.0.66 → 1.0.67** |
| `README.md` | 版本历史补全 v1.0.58 ~ v1.0.67 共 10 行 |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.67-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.67.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

---

# PageTurner v1.0.66

> 一批攒下来的体验修复 + 一个新手感功能「连滑」。涵盖：App 列表勾选置顶、动作页配色不再串色、延迟上限放开且新增默认值生效、滑动(手动) 录制/回放坐标对齐、测试页轨迹统一、命中时不再画出翻页器原始轨迹，以及方案/动作排序改成长按拖拽。

## ✨ 新功能

### 连滑（变速 + 刹停，1:1 复刻 DVT 1.0.22）
- 快速连按同一个已映射翻页键满 5 次进入连滑；**进连滑后自动连续翻页**（每段滑收尾无缝续下一段，无需再按键），直到刹停 / 退后台 / 关开关。
- 变速：连滑中再按同键 = 升档 **1→2→3→1 循环**，只对下一段滑生效，档位不记忆；pill 提示「连滑一/二/三倍速」。
- 刹停：翻页进行中按**别的方案键** = 立即中断当前滑并抬手、退出连滑（连滑中额外弹「已退出连滑」）。
- 顶部 pill 全程胶囊提示；设置页「连滑提速」总开关默认开；「测试本方案」走同一套逻辑，验证即所见。

## 🐛 修复 / ♻️ 改动

### 1. 「指定 App 生效」列表：勾选的 App 置顶（#1）
- **改动**：`PTAppListVC` 进入页面（及搜索重建）时，把已勾选的 App 排到最顶部、其余按名称排在后面；打勾当下列表**不即时重排**，返回再进入才看到置顶（符合需求）。

### 2. 调试可视化：命中时不再画出翻页器原始轨迹（#2）
- **现象**：开启【调试可视化】后触发已映射按键，翻页器原始轨迹仍可见，与「命中即吞掉、只显示映射轨迹」的设计矛盾。
- **修复**：把调试绿点绘制移到「交付 App 之前」——命中（被吞）的翻页器原始触摸不再画点，只显示映射注入轨迹；未命中放行 / 注入态的触摸在各自交付处补画。

### 3. 测试本方案：轨迹统一成「起点绿点 + 方向线 + P 标记」（#3）
- **改动**：测试页本地执行的「点触 / 滑动(手动) 回放」改用真实坐标的「起点绿点 + 方向线 + 终点 P 标记」样式，与调试可视化、引擎命中回放三处视觉统一（点触短暂、滑动按录制时长移动）。

### 4. 滑动(手动)：录制与回放坐标对齐（#4，真 bug）
- **现象**：录制的滑动在「测试本方案」回放时起点落到屏幕外（从屏外滑进来）。
- **根因**：录制端 `onRecPan` 存的是覆盖层**视图坐标**，回放端 `PTFakeMetaTouch` 用的是**窗口坐标**，两套基准差固定偏移。
- **修复**：录制端改用 `fixedCoordinateSpace` 转成屏幕固定坐标存储；绿点（点击 / 滑动）编辑载入与保存同样做视图↔屏幕坐标互转，落点回到真实位置。

### 5 / 5b. 排序改为长按拖拽（方案页 + 动作页，零三横线）（#5, #5b）
- **方案选择页（#5）**：新增长按手势——长按方案行浮层跟手拖动实时换序，松手写回配置；末行「新增方案」不拖、落点钳制在方案范围内。
- **方案内部动作页（#5b）**：三种手势分工明确——**点按**进编辑、**长按不动**进参数页、**长按拖动**换序；删除原「排序」按钮与系统编辑态 / 三横线。

### 6. 动作页文字颜色不再串色（#7）
- **现象**：进入动作页动作行是黑色；点编辑返回 / 直接新增后部分行变绿或变蓝，唯独「新增映射 / 测试本方案」两行不变。
- **根因**：tableView cell 复用，动作行分支从不重置 `textColor`，继承了绿 / 蓝行的颜色。
- **修复**：动作行分支显式设 `textColor = labelColor`，与系统两行对齐，始终黑色。

### 7. 延迟参数页上限放开（#8）
- **现象**：新增延迟可填任意 >0 值（如 10000），但编辑参数页滑块 / 输入框最高锁死 5000，超过的值改不回来只能删了重加。
- **修复**：编辑端 `max` 由 `@5000` 提到 `@60000`（与新增端一致），新增能填多大、编辑就能改多大。

### 8. 新增延迟默认值生效（#9）
- **现象**：新增延迟弹窗的灰色「500」只是 placeholder 提示，空按【添加】不会当成 500，等于空输入无效。
- **修复**：把 `tf.placeholder = @"500"` 改为 `tf.text = @"500"`（真实预填值），不输入直接按【添加】＝新增 500ms，与「示范值即默认值」直觉一致。

### 10. 测试本方案：滑动(手动) 回放显示连续尾巴轨迹（修复 #3 遗留）
- **现象**：测试本方案播放「滑动(手动)」录制轨迹时，看不到尾巴（连续轨迹线），看起来像一串点击连成的滑动。
- **根因**：回放每帧调用 `PTTestShowDot(cur, cur, …)`，方向线 `from=to` 长度为零（不可见），还每帧把带「P」标记的终点挪到当前点，于是只剩「绿点 + 跳动的 P」在移动，没有连续尾巴。
- **修复**：新增「尾巴」折线渲染——逐帧把当前点追加进 `sTestTrail`，重绘 `起点→…→当前` 的连续轨迹线，绿点跟随当前位置；回放结束在终点显示 P，保留片刻后淡出；用令牌防止上一段回放的余留淡出误清当前轨迹。直线 `swipe` 与点击样式不变。

### 11. 重名方案：编辑 / 删除不再串名（真 bug）
- **现象**：两个方案名称相同时，编辑其中一个会改掉所有同名的、删除一个会把所有同名的都删掉。
- **根因**：方案以 `name` 为唯一键在 `plans` 数组里增 / 删 / 改 / 查，重名时检索命中全部同名方案。
- **修复**：给每个方案引入唯一身份 `pid`——首次读取时为旧方案惰性补发唯一 `pid` 并落盘、新建方案即带 `pid`；列表页导航 / 方案页改名 / 编辑动作 / 编辑特征 / 增减特征 / 删除全部改为按 `pid` 定位，重名时只作用于「那一个」方案（改名、长按排序后也不串）。

### 12. 连滑安全化：翻页不再被提速搞失效（修复「滑动没反应」）
- **现象**：开启连滑后，连续翻几页进入提速，之后「划了没反应」——页面不再翻。
- **根因**：连滑提速倍率是**全局变量**，且只在「再次命中翻页手势」时才复位；进入提速后若停顿不再划屏，倍率就**卡在高位残留**，把后续每次翻页回放都加速到 App 识别不了（尤其合成 `swipe` 动作的时长被压到 50ms 以下，直接被当成点按而非滑动）。
- **修复**：① 提速更温和（封顶 2x、每档 +0.2）；② 翻页 `swipe` 动作保底时长 90ms，连滑提速也不低于此，确保 App 识别为滑动；③ **停顿即自动刹停复位**——停止翻页后由「连滑链超时窗口（1.2s）」判停（详见 #13），立即把连滑链倍率归 1，不再残留。

### 13. 连滑触发不了修复（版本不变，仍属 v1.0.66）
- **现象**：开启连滑后，无论如何连按同一个按键，插件都只识别前一次未完成的滑动、然后放弃，等于没有反应，连滑永远触发不了；「测试本方案」里同样不行。
- **根因**：连滑"刹停"被错误绑在 **0.4s 翻页器窗口**（`gPagerWindowUntil`）上——一次按键触摸一结束、窗口 0.4s 过期后，下一次任意 `sendEvent` 就 `PTChainReset()` 把整条链（计数 + 方案 + 倍率）清零。而单次滑动回放本身就 ~400ms+，两次按键间隔只要 ≥0.4s，计数就永远到不了 5。
  另：测试页 `PTTestExecPlan` 每次执行都无条件 `PTChainReset()` 且从不累计，所以测试页也永远触发不了连滑。
- **修复**：① 连滑刹停改用「同方案连续命中**间隔**」（`kChainStaleSec=1.2s`）判停，与 `PTChainStartOrContinue` 内部 stale 判停同纪元（`CFAbsoluteTimeGetCurrent()`），翻页器窗口过期不再清链；② 测试页去掉每次执行清零，命中后正常 `PTChainStartOrContinue` 累计，「滑动 / 滑动(手动)」均吃 `gChainRate` 提速，便于验证。

### 14. 连滑改成「排队续播」——在飞动作不打断、同方案连击排队续播、异方案无视（修复"滑动途中无反应 / 越按越卡 / 连滑不连"）
- **现象（用户实测）**：
  - Bug1：连滑提示出现两种颜色——蓄力时是灰色「连滑 2/5」、提速后变绿色。
  - Bug2：滑动进行期（飞快势）中按相同键，动作被直接打断、新动作覆盖在旧轨迹上（调试可见一大堆圆点），越按越多反而越来越慢、越来越卡；按 5/10 次虽出连滑提示，但根本不会连滑。
  - Bug3：当前动作进行中遇到其他方案键，会被直接打断去执行别的动作。
- **根因**：
  - Bug1：pill 用 `gChainBurst ? 绿 : 灰` 区分蓄力 / 提速两态。
  - Bug2/Bug3：旧「连滑」被实现成「打断重开」——`PTExecutePlan` 用 `gExecToken++` 令在飞手势下一帧失配被砍断、再从方案起点重开；而判定「是否连滑中」用的是「两次抬手间隔 ≤1.2s」，与 3.5s 的动作时长根本不匹配，于是每次新滑动寿命只有两次按键间隔、永远没一次是完整的，pill 却记着 5/5 →「出提示但不连滑」；被砍断的旧手势若没正确抬手（旧 recSwipe 只 `invalidate` 不 `Ended`），假手指粘半空、圆点不消散、App 端叠成双指混乱 → 越来越卡。
- **修复（v1.0.66-fix4，仍为同一版本号）**：
  - ① pill 统一绿色（Bug1），不再分灰 / 绿两态。
  - ② 连滑语义改为**真·排队续播**：在飞动作期间按**同方案**键 → 入队（`gExecPending++`）**绝不打断**，当前动作播完后自动续播下一轮，每一轮都是完整滑动、速度吃连滑倍率（≥5 次 1.2x→2x 封顶）；按**异方案**键 → 直接无视（Bug3，正常应让本动作完成）。
  - ③ 不再用 `gExecToken++` 砍在飞手势；令牌只在「全新启动」时递增作异常兜底。新增 `gExecPlan`（在飞方案）+ `gExecPending`（排队数）两个状态，`PTHandlePagerEvent` 在链记账**之前**判定「异方案在飞 → 直接吞掉」，避免改写连滑链。
  - ④ 修掉「砍断不抬手」：`PTFakeRecSwipeAsync` 被令牌失配时先在最后坐标发 `Ended` 抬手再停，假手指不粘半空、圆点正常消散。
  - 测试页「测试本方案」同步为排队续播语义，便于验证。
- **连滑现在怎么触发**：连按同一个已映射翻页键（动作播完前连按也算），同方案累计满 5 次进入提速；**每一按都是一次完整播放、首尾相接排队续播**，不再互相打断、不再卡顿。

### 15. 连滑 1:1 复刻 DVT 1.0.22（#14 的"排队续播"作废，仍为同一版本号）
> #14 那套「排队续播 + 异方案无视」是自行设计的模型，与参考实现 DirectVolumeTap 1.0.22 的连滑相差甚远。按"要 DVT 效果"的要求，删掉自研连滑，从 DVT 1.0.22 原样移植，仅把"方向"映射为"方案"（同方案=同方向，异方案=反方向）。

- **移植前（#14，作废）**：同方案连击入队排队播、异方案无视、倍率线性 +0.2 封顶 2x、用 1.2s 抬手间隔判链。
- **移植后（DVT 1:1）**：
  - **检测窗口**=回放进行中（`gExecRunning`）；起滑即锁方案（`gSwipeBurstPlan`），连滑只能是该方案。
  - **触发**：窗口期内同方案连续命中满 **5** 次 → 进入连滑（`gSwipeBurstActive`）；第 4 次弹「再按一次进入连滑」，进连滑弹「已进入连滑」。
  - **自动续滑**：进连滑后每段回放收尾**自动无缝重开同方案**（`PTExecutePlanRun` 收尾处回调），**无需再按键**，直到刹停/退后台/关开关。
  - **变速**：连滑中再按同方案 = 升档 **1→2→3→1 循环**（`gSwipeBurstRate`），只对下一段滑生效；档位**不记忆**，进连滑/刹停/退后台均复位 1 档；pill 分别提示「连滑一/二/三倍速」。
  - **刹停（关键差异）**：回放中按**异方案** = 立即中断当前滑剩余帧并抬手（`gExecToken++` 令在飞手势失配收尾）+ 退连滑 + 档位复位，连滑中额外弹「已退出连滑」；总开关关闭时窗口期按压静默忽略。
  - **pill**：改用 DVT 式顶部小胶囊（黑底白字、2 秒自动消失），文案与 DVT 一致。
  - **生命周期**：进程内注册一次退后台通知 → 断连滑 + 中断在飞回放（抬手收尾），回前台状态干净（对齐 DVT `dvtAppDidEnterBackground`）。
  - **测试页**「测试本方案」与运行端走同一 `PTExecutePlan` 判定，验证即所见。
- **速率应用**：滑动 / 滑动(手动) 回放速度吃档位 `gSwipeBurstRate`（1/2/3），单滑固定原速。
- **连滑现在怎么触发**：快速连按同一个翻页键满 5 次（都在回放窗口内）即进入连滑，之后**自动连续翻页**；连按同键继续升档提速，按别的键立即刹停，退后台/关开关结束。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `common/PTEngine.m` | 连滑状态机 + 顶部 pill + `PTFakeRecSwipeAsync` 提速/单帧封顶/看门狗；命中吞原始轨迹（#2）；`chainEnabled` 配置读取；测试回放提速；连滑刹停改用 1.2s 同方案命中间隔、测试页累计连滑（#13） |
| `common/PTOverlayPage.m` | 录制 / 绿点坐标改用屏幕固定坐标，修复回放偏移（#4） |
| `Preferences/RootListController.m` | App 列表勾选置顶（#1）；测试页真实坐标轨迹（#3）及滑动尾巴修复（#10）；方案页 / 动作页长按拖拽排序（#5/#5b）；动作行配色（#7）；延迟上限放开（#8）+ 默认预填（#9）；新增「连滑提速」开关；方案唯一 `pid` 身份，重名不再串名（#11） |
| `Makefile` / `Preferences/Resources/Info.plist` | 版本号 **1.0.65 → 1.0.66** |

> 说明：连滑改变了一条既有行为——**连滑会话期间**，没匹配到方案的手势会被当作「刹停」信号（不再穿透当成普通翻页）；非连滑会话时穿透翻页保持原样。这是「除开头手势外都刹停」的必然代价。

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.66-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.66.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

---

# PageTurner v1.0.65

> 修复「打开任意被注入的 App 都会往 jbroot 的 Documents 生成 `PageTurner-<bid>.log`」的 bug——之前即使是关掉调试日志、且未勾选生效的 App 也会建文件，导致 jbroot Documents 被一堆无用日志占满。

## 🐛 修复

### 1. 关掉调试日志仍建文件（根因）
- **现象**：总开关开、调试日志关、App 未勾选生效，打开该 App（如 Filza）仍会在 jbroot Documents 生成 `PageTurner-com.tigisoftware.Filza.log`，且每次打开都重建。
- **根因**：`PTDylibLog`（common/PTEngine.m）里「关日志即返回」的检查排在「从 plist 读 `debugLogEnabled`」之前，而 `sLogEnabled` 默认 `YES`；于是**首条日志用默认的 YES 放行、创建了文件之后**才读到你已关闭的配置。
- **修复**：把 `PTDylibLogRefreshCfg()` 移到提前返回之前，首条日志就先按配置判定——调试日志关时**完全不建文件**。

### 2. 未勾选生效的 App 也被建日志（根因）
- **现象**：几乎所有被注入的 App 都会在 jbroot Documents 留下一份 `PageTurner-<bid>.log`，纯浪费空间，且无实际作用。
- **根因**：`Tweak.m` 的 `PTInit` 无条件把日志路径钉到共享 jbroot Documents，且「旁路（未勾选）」App 也会跑启动日志。
- **修复**：新增文件日志总开关 `PTSetFileLogEnabled(BOOL)`（引擎），`PTInit` 仅在 App **勾选生效**时才打开文件日志并钉 jbroot 路径；未勾选/旁路 App 只走内存日志、**不写任何文件**。「设置」进程自身同样不再落盘（它的日志由 `RootListController` 单独写成 `PageTurner.log`，与本项无关）。

### 3. 巨魔(dylib) 构建同样不再建任何日志文件
- **现象**：TrollStore 注入的 dylib 会给**每个**被注入的 App 在 jbroot Documents 建一份 `PageTurner-<bid>.log`。
- **判定依据**：设置页的 `buildLogItems` **只枚举 `enabledApps`**；而 dylib 用的是自己的容器配置（`PTDylibUsingDebConfig()` 恒为 `NO`，没有「指定 App 生效」机制、注入即生效）——这些文件**没有任何代码会读**，100% 是垃圾。
- **修复**：移除 `PTDylibMain.m` 里无条件的 `PTSetLogPath`（不再钉 jbroot 路径）；引擎 `sFileLogEnabled` 默认改为 **NO**，dylib 因此完全不落盘，日志只留在内存（`PTDylibLogLines()`）。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `common/PTEngine.m` | `PTDylibLog` 先同步配置再判定返回（修关日志仍建文件）；新增 `sFileLogEnabled` 关卡文件写入，**默认 NO** |
| `common/PTEngine.h` | 暴露 `PTSetFileLogEnabled(BOOL)` |
| `Tweak.m` | `PTInit` 仅对「勾选生效」App 开文件日志；其余 App（含「设置」进程自身）不写文件 |
| `targets/dylib/PTDylibMain.m` | 移除无条件的 `PTSetLogPath`，巨魔形态不再落盘任何日志文件（仅内存日志） |
| `Preferences/RootListController.m` | 修正与实际不符的注释（日志条数 `200`/`1000` → 实际 `500`），并写明读写两侧都以 `enabledApps` 为准 |

> 说明：共享 jbroot Documents 的日志是为「设置页调试日志查看器」跨进程读 App 运行日志而设。**落盘规则与读取规则现已严格一致**：写入侧只为 `enabledApps` 里的 App 建文件，读取侧也只枚举 `enabledApps`，其余 App 一律不产生文件。
>
> 顺带清理：本次修正了多处与代码实际行为不符的注释（如日志上限注释写 `200`/`1000`，实际均为 `500`；以及「统一写到共享 jbroot」等过期描述），避免后续被这些注释误导。

# PageTurner v1.0.64

> 修复「新增映射」绿点拖动的坐标范围问题，并给滑动(手动) 的 1/2 选中加上可视化高亮提醒。（均在 `common/PTOverlayPage`）

## 🐛 修复 / ♻️ 改动

### 1. 绿点拖动坐标范围修正（bug1）
- **现象**：上一版（v1.0.63）把圆点圆心钳到 `[半径, 屏宽-半径]`，等于禁止坐标进入屏幕边缘 22px 内，导致设不到 22 以下的坐标；且不钳制时又会拖到屏幕外、坐标变负数。
- **修复**：`clampDot:` 现在只把**圆心(坐标)**钳到 `[0, 屏宽] × [0, 屏高]`：
  - 允许圆点**半出屏**——坐标 0 / 屏宽 / 屏高 时圆点自然出一半（直径 22，边缘点击点本就该如此）；
  - 坐标**永不为负、也不越界**，保存的是有效屏幕点。
- 顺手移除了上一版临时加的 `contentTop` 属性（已无用途）。

### 2. 滑动(手动) 选中 1 / 2 增加高亮提醒（bug2）
- **现象**：滑动的两个圆点（1 绿 / 2 橙）选中了没有任何视觉反馈，不知道当前在拖谁。
- **修复**：保留**选中态可视化**作为提醒（标题栏文字维持原样「滑动起点(x,y)→终点(x,y)」未改）：
  - 选中圆点：放大 1.3×、不透明、底色加亮、数字转白字；
  - 未选中：缩小 0.85×、半透明；
  - 重写 `setSelectedDot:` 让选中切换自动刷新——点圆点 / 按下落在圆点上都会即时高亮，一眼看清在拖 1 还是 2。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `common/PTOverlayPage.m` | `clampDot:` 改为圆心钳到 `[0,屏]×[0,屏]`（可半出屏、不为负）；`applySelection` 选中高亮；移除 `contentTop` |
| `control` / `Makefile` / `Preferences/Resources/Info.plist` | 版本号 **1.0.63 → 1.0.64** |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.64-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.64.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

---

# PageTurner v1.0.63

> 修复「新增映射」三处体验问题：坐标提示垂直居中到标题栏；滑动(手动) 全屏任意处可做起点；点击/双击/滑动 改为按住屏幕任意处即可拖动圆点

## 🐛 修复 / ♻️ 改动（均在 `common/PTOverlayPage`）

### 1. 坐标提示「点击(坐标,坐标)」垂直居中到半黑标题栏（bug1）
- **现象**：绿点页（点击 / 双击 / 滑动）的实时坐标提示被放在标题栏**下方**，没有在半黑标题栏里居中。
- **修复**：坐标提示现在作为标题栏居中的「标题」——垂直居中在 56pt 半黑条内（`barY + 13`，文字白色），和「取消 / 完成」按钮并排，像导航栏标题一样。
- 仅绿点页生效；滑动(手动) 仍用屏幕中央的提示框，未改动。

### 2. 滑动(手动) 全屏任意处均可作为滑动起点（bug2）
- **现象**：只能从标题栏**下方**开始滑，标题栏区域（含背景）按下去不录。
- **修复**：去掉「标题栏内不录」的限制（`onRecPan` 的 `loc.y < recTopY` 排除 + `recTopY` 传参一并移除），现在**全屏幕任意处**（含标题栏背景）都能做起始点。
- **关键**：通过新增的手势代理 `gestureRecognizer:shouldReceiveTouch:` **只避让【取消】【完成】两个按钮**，所以全屏可滑的同时，按钮的点击功能完全不受影响（按钮区域不交给 pan，按钮照常响应）。

### 3. 点击 / 双击 / 滑动：不用按住圆点本身，按住屏幕任意处即可拖动（改动1）
- **现象**：必须精确按住绿点才能拖动，体验别扭。
- **修复**：
  - 圆点改为「点一下即选中」（新增 `dotTapped` 轻点手势）：点 1 选中 1、点 2 选中 2（滑动时可在 1/2 间切换；点击/双击只有 1，恒选中）。
  - 拖动改为**全屏 pan**（`onGreenPan`）：按住屏幕任意处拖动，移动的是「当前选中的圆点」。
  - **默认选中 1**：没点过任何圆点就直接拖，移动的就是 1；先点某个圆点再拖，移动的才是那个。
  - 同样通过手势代理避让【取消】【完成】按钮，拖动时按钮仍可点。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `common/PTOverlayPage.m` | 上述 3 处修复/改动；新增 `selectedDot` 选中态、手势代理避让按钮；移除废弃的 `recTopY` 与逐点 `drag:` |
| `control` / `Makefile` / `Preferences/Resources/Info.plist` | 版本号 **1.0.62 → 1.0.63** |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.63-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.63.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |
