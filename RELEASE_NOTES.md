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
