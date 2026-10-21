# PageTurner

iOS 越狱插件（Dopamine roothide）：把 **BLE 翻页器**（看小说用的翻页遥控器，上下左右 / 确定键）的按键动作**录成特征**，拦截下来**替换成你想要的动作**——点击、双击、滑动、延迟、静音、音量 ±，只在**指定 App** 里生效，其他 App 完全放行。

> 适用场景：番茄小说等阅读 App 里，翻页器方向键默认是"滑动翻页"；装了这个插件后，你可以把方向键录成特征，映射成"点击屏幕中央"、"双击点赞"、"滑动指定路径"等任意动作，并且不会残留翻页器自带的原始滑动（双动作问题已在 v1.0.32 根除）。

---

## 特性

- **按键特征学习录制**：大白屏里反复按同一个键，插件自动归纳特征（来源设备 + 方向 + 位移区间），支持同一翻页器多个键分别录制
- **一键多动作**：一个按键特征可以挂任意多条动作，按一次键按顺序全部执行；映射区支持**拖动排序**（v1.0.43+）
- **动作类型**：点击、双击、滑动（速度可调，默认 1000pt/s）、滑动(手动)（直接填参数）、延迟
  - v1.0.48 起已**移除**音量 +/音量 -/静音切换（跨进程音量控制在第三方 App 不可靠）；旧配置里残留的会显示「（已移除）」
- **指定 App 生效**：勾选目标 App（如 com.dragon.read），只有它里面拦截替换；未勾选 App 完全不受影响
- **调试可视化**：独立开关，显示绿点轨迹——只画 App **实际收到**的触摸（被拦截吞掉的翻页器原始轨迹不显示，命中执行/未命中重放一目了然）
- **测试区**：方案页内置大白屏测试页，在设置里就能验证"录特征 → 匹配 → 执行映射"整条链路
- **深色模式适配**（v1.0.31+）
- **版本号展示**：设置页最底部居中显示版本号（v1.0.43+）

---

## 安装

- 环境要求：Dopamine / RootHide（roothide）越狱，iOS 15 / 16（iPhoneOS 16 SDK 编译）
- 下载最新 `.deb`（Release 页），用 Sileo / Zebra / dpkg 安装，**装完注销**

```bash
dpkg -i PageTurner-1.0.57-roothide.deb
```

装完在 **系统设置 App** 里会出现 `PageTurner` 分组（所有 UI 都在系统设置里，目标 App 内没有页面、没有双指手势）。

> **两种形态，同一份代码**：本仓库一次构建同时产出
> · `PageTurner-<ver>-roothide.deb` —— 越狱(roothide) 直装，设置页总开关 + 指定 App 生效；
> · `PageTurnerDylib_<ver>.dylib` —— 巨魔(TrollStore / TrollFools) 注入任意 App，App 内**双指长按**（两指同时按住 0.5 秒）弹出设置菜单。
> 两者的运行端引擎（`common/PTEngine.m`）完全相同，仅「配置路径 / 总开关门控 / hook 安装方式」因注入环境不同由各自 target 注入。
> 注：v1.0.57 已删除失效的「注入探针」开关（旧版无法注入时的兜底弹窗）。

---

## 快速开始（4 步）

1. 安装 deb → 注销
2. 设置 → `PageTurner` → 打开 **总开关**
3. **记录与映射** → **新增方案** → **新增记录** → 大白屏里反复按同一个键 → 出现绿色「特征已稳定」提示 → 点右上角 **保存**（默认名「新方案N」，名字以后可改）
4. 回到方案页 → **新增映射** → 选动作类型 → 设坐标 → 完成；再到首页 **指定 App 生效** 勾选目标 App → 打开目标 App 按那个键

---

## 详细使用

### 首页

| 项目 | 说明 |
| --- | --- |
| 总开关 | 插件总闸，关闭则全部功能（含探针 / 可视化）不工作 |
| 指定 App 生效 | 勾选列表：哪些 App 里拦截替换翻页器按键 |
| 防抖 | 两次按键最小间隔（默认 300ms，100~1000 可调） |
| 记录与映射 | 方案管理入口 |
| 调试可视化 | 独立开关：所有触摸显示绿点轨迹 |
| 调试日志 | 总开关（关闭=停止记录+清空日志+隐藏下方入口；每个文件循环 500 条） |
| 调试日志（详情） | 选择查看哪份日志：设置页日志 / 各生效 App 的运行日志（开关关闭时隐藏） |

### 记录与映射（方案列表）

- 每个方案 = 「一个按键特征」+「一组映射动作」
- **新增方案** → 进入方案页；已有方案 **左滑删除**
- 方案列表每次返回自动刷新（v1.0.29+）

### 方案页

- **方案名： xxx**：点击弹框改名（录制时保存的是默认名，在这里改）
- **新增记录 / 已录制完成**：录完一次后变「已录制完成」，再点 = 清空特征重新录制
- **映射区**：动作列表，从上到下按一次键全执行
  - **＋ 新增映射**：选动作（点击 / 双击 / 滑动 / 延迟 / 静音 / 音量+ / 音量-）
  - 点击动作行：进入动作设置页改坐标（预填原值）
  - 长按动作行：调整时序参数（按下时长、双击间隔、滑动速度、延迟毫秒）
  - 左滑动作行：删除
  - **右上角「排序」**：进入编辑态，按住行最右侧 ≡ 手柄拖动调整执行顺序（v1.0.43+）
- **▶ 测试本方案**：大白屏测试页，按翻页器键验证匹配和执行，实时记录区显示命中/未命中

### 学习页（录特征）

- 大白屏（深色模式自动黑底白字），下方实时记录区显示每次按键的 sender / 相位 / 方向 / 位移
- **要点：学习页必须在系统设置 App 前台时按翻页器**（iOS 事件只路由给前台 App，这是系统机制）
- 录稳后：背景变绿提示「特征已稳定」，可以**继续按同一个键增强特征**（位移区间实时刷新，保存时用最新样本）；按够了点右上角「保存」
- 误按别的键只提示不混入；与已有方案高度相似的按键会被拒绝（避免重复录入）

### 动作设置页

| 动作 | 设置 |
| --- | --- |
| 点击 | 绿点拖到目标位置，标题实时显示坐标 `点击(x, y)` |
| 双击 | 同上（一个绿点） |
| 滑动 | 绿点 1 = 起点、绿点 2 = 终点，两点之间画连线，标题显示 `滑动起点→终点`；速度在方案页长按该动作调（默认 1000pt/s，可调 100~2000，参数页有预设值一键点击） |
| 延迟 / 静音 / 音量± | 长按动作行调参数，无坐标 |

---

## 调试

1. **调试可视化**：显示绿点轨迹——只画 App **实际收到**的触摸（被拦截吞掉的翻页器原始轨迹不显示；命中执行、未命中重放、手指触摸都可见）。
2. **调试日志**：设置页进「调试日志」→ 选择要看哪份日志（设置页日志 / 各生效 App 的运行日志）→ 查看并一键复制。每个日志文件循环保留最近 **500 条**；关闭「调试日志」开关会立即清空全部日志，并隐藏详情入口。

### 日志文件（排障必备）

- 日志统一写在**共享 jbroot 的 Documents**（`<jbroot>/var/mobile/Documents/`）——这是 App 侧与设置页唯一双向可通的路径：
  - `PageTurner.log` —— 设置页进程日志
  - `PageTurner-<bundleID>.log` —— 各生效 App 的运行日志（越狱 deb 与巨魔 dylib 都写这里）
  - 设置页「调试日志」里可直接选择要看哪份日志，查看并一键复制（v1.0.59 起）
- 实测后把日志发给开发者即可定位问题。

---

## 工作原理（写给开发者）

```
翻页器按键（BLE → HID digitizer, type=11）
        │
        ▼
_UIUpdateHIDDigitizerInput -addEvent:   ← hook：读 sender（来源设备），已学 sender → 开 0.4s 窗口
        │
        ▼
UIApplication -sendEvent:               ← hook：
        │  ├─ 窗口内且 sender=已学 → 整段吞掉 Began/Moved/Ended，记录轨迹
        │  │     Ended 结算：命中特征 → 执行映射动作序列（PTFakeMetaTouch 注入触摸）
        │  │                 未命中    → 重放轨迹给 App（保留原行为）
        │  ├─ 窗口内但 sender=手指 → 放行（绝不吞手指）
        │  └─ 映射执行中的注入触摸 → gInFakeTouch 标志放行（不丢 Began）
```

- **特征** = 来源 sender（精确）+ 相位（位移 <30pt = 点击 / 否则滑动）+ 方向（±15°）+ 位移区间（±30pt 裕度）
- **注入**：ellekit / roothide，`Filter: Bundles = (com.apple.UIKit)`；hook 用 `MSHookMessageEx`（ellekit 只注入含该符号的 dylib，`method_setImplementation` 不生效）
- **配置**：跨沙盒直接读全局 plist（自动定位 `.jbroot-XXX` 动态根路径），不依赖 `NSUserDefaults suiteName`（第三方沙盒内读不到）
- **动作执行**：`ptftouch/` 目录是 KIF FakeTouch 移植（`PTFakeMetaTouch`），同步注入 UITouch；音量走 `AVSystemController`

---

## 仓库结构

```
PageTurner/
├── common/PTEngine.{h,m}             # 统一运行端引擎（roothide / dylib 共用）：配置/日志/匹配/执行/可视化/hook 处理器
├── Tweak.m                           # roothide deb 薄壳：配置路径注入 + 总开关+指定App门控 + MSHookMessageEx 装 hook
├── targets/dylib/                    # 巨魔 dylib 薄壳：PTDylibMain（入口/菜单窗口）+ PTDylibUI（浮窗菜单/录制覆盖层）
├── Preferences/
│   ├── RootListController.m          # 设置页全部 UI（方案 / 学习 / 映射 / 测试 / 调试）
│   └── Resources/Info.plist
├── ptftouch/                         # PTFakeMetaTouch（KIF FakeTouch 触摸注入库）
├── Makefile / control                # Theos roothide 打包
└── .github/workflows/build.yml       # push 自动编译 roothide deb + 巨魔 dylib 并发布 Release
```

## 版本里程碑（关键节点）

| 版本 | 意义 |
| --- | --- |
| [v1.0.0](https://github.com/123bnb/PageTurner/releases/tag/v1.0.0) | 首个正式版：拦截翻页器 + 学习录特征 + 映射动作 |
| [v1.0.4](https://github.com/123bnb/PageTurner/releases/tag/v1.0.4) | 采集基线：唯一能正常录多个键且带位移数据的版本（后续多次回滚到它） |
| [v1.0.5](https://github.com/123bnb/PageTurner/releases/tag/v1.0.5) | 映射动作不生效的核心修复：特征提取搬到 IOHIDEvent 层 |
| [v1.0.8](https://github.com/123bnb/PageTurner/releases/tag/v1.0.8) | 拦截架构定调：回滚到 sendEvent 层读真实 UITouch 坐标 |
| [v1.0.17](https://github.com/123bnb/PageTurner/releases/tag/v1.0.17) | 整包回滚到真实 v1.0.4 采集逻辑 + 日志系统 |
| [v1.0.23](https://github.com/123bnb/PageTurner/releases/tag/v1.0.23) | 【最重要】注入终极根因修复：Filter 空 {} → com.apple.UIKit，此前 22 版全部从未被注入 |
| [v1.0.25](https://github.com/123bnb/PageTurner/releases/tag/v1.0.25) | 跨沙盒配置读写双通（设置页写 jbroot 路径，App 侧读得到） |
| [v1.0.28](https://github.com/123bnb/PageTurner/releases/tag/v1.0.28) | 拦截方案 B 定稿：整段吞 + 未命中重放；动作时序参数全可调 |
| [v1.0.32](https://github.com/123bnb/PageTurner/releases/tag/v1.0.32) | 双动作根除：gInFakeTouch 精确区分注入触摸，执行中按键也拦截 |
| [v1.0.41](https://github.com/123bnb/PageTurner/releases/tag/v1.0.41) | 狂按根因修复（Began 延迟 40ms）+ 固定 60fps + 防惯性开关 |
| [v1.0.43](https://github.com/123bnb/PageTurner/releases/tag/v1.0.43) | 9 项改进：防抖严谨化、映射排序、速度默认 1000、底部版本号 |
| [v1.0.48](https://github.com/123bnb/PageTurner/releases/tag/v1.0.48) | 删除音量/静音动作类型（跨进程音量控制不可靠） |
| [v1.0.50](https://github.com/123bnb/PageTurner/releases/tag/v1.0.50) | 可视化窗口不再接管状态栏（windowLevel 降 Normal+1） |
| [v1.0.53](https://github.com/123bnb/PageTurner/releases/tag/v1.0.53) | 手动动作回归：仅留滑动(手动)，改为设置页直接填参数 |
| [v1.0.57](https://github.com/123bnb/PageTurner/releases/tag/v1.0.57) | 统一代码：单仓库双 target，一次构建同时产出越狱 .deb 与巨魔 .dylib；删除失效的注入探针 |
| [v1.0.66](https://github.com/123bnb/PageTurner/releases/tag/v1.0.66) | 连滑 1:1 复刻 DVT 1.0.22：满 5 次进连滑、自动续滑、1→2→3 档变速、异方案刹停；v1.0.67 起 pill 绿底白字（深色模式自适应）|

## 版本历史（全部 71 个版本）

> 每个版本点版本号可看该版完整的「新增 / 修复 / 删除 / 改动」说明。

| 版本 | 这一版做了什么 |
| --- | --- |
| [v1.0.70](https://github.com/123bnb/PageTurner/releases/tag/v1.0.70) | 双形态构建治理：共享源文件+flags 抽单一真源、CI 新增 dylib 未定义符号审计与 arm64e 响亮校验、删除恒 NO 死开关；零功能改动 |
| [v1.0.69](https://github.com/123bnb/PageTurner/releases/tag/v1.0.69) | 版本号机制打磨：Info.plist 按 key 锚定同步 + 早退守卫 + 打包后还原工作树；根治三处手填漂移，零功能改动 |
| [v1.0.68](https://github.com/123bnb/PageTurner/releases/tag/v1.0.68) | 版本号单一真源（Makefile PACKAGE_VERSION 派生 control/Info.plist）+ CI 构建前一致性校验，根治版本漂移；零功能改动 |
| [v1.0.67](https://github.com/123bnb/PageTurner/releases/tag/v1.0.67) | 连滑 pill 绿底白字（深色模式自适应）+ 蓄力实时倒数「连滑 N/5」+ 升档⚡样式「⚡连滑 ×N」；提速模型仍 DVT 1/2/3 档只换皮 |
| [v1.0.66](https://github.com/123bnb/PageTurner/releases/tag/v1.0.66) | 连滑 1:1 复刻 DVT 1.0.22（变速+刹停+自动续滑）+ 一批体验修复（App 置顶/串色/延迟上限/坐标对齐/拖拽排序/重名 pid） |
| [v1.0.65](https://github.com/123bnb/PageTurner/releases/tag/v1.0.65) | 巨魔 dylib 同样彻底不落盘日志 + 修复未勾选/关调试日志的 App 仍被建 jbroot 注入日志 |
| [v1.0.64](https://github.com/123bnb/PageTurner/releases/tag/v1.0.64) | 修正绿点拖动坐标范围（可半出屏/不为负）+ 滑动选中 1/2 高亮提醒 |
| [v1.0.63](https://github.com/123bnb/PageTurner/releases/tag/v1.0.63) | 修复新增映射三处体验——坐标居中标题栏/滑动全屏可做起点/任意处拖动圆点 |
| [v1.0.62](https://github.com/123bnb/PageTurner/releases/tag/v1.0.62) | 统一四个新增映射页到 common/PTOverlayPage，修复 dylib 取消退回首页 |
| [v1.0.61](https://github.com/123bnb/PageTurner/releases/tag/v1.0.61) | 修复 deb 测试区滑动(手动)像点击——补插值 + 60fps 帧驱动 |
| [v1.0.60](https://github.com/123bnb/PageTurner/releases/tag/v1.0.60) | 修复日志重叠/手动滑动无轨迹/版本号样式，删除 dylib 配置来源 |
| [v1.0.59](https://github.com/123bnb/PageTurner/releases/tag/v1.0.59) | 日志统一到共享 jbroot、调试日志改版，删除注入标记与诊断代码 |
| [v1.0.58](https://github.com/123bnb/PageTurner/releases/tag/v1.0.58) | 日志通路诊断版：只诊断 App 与设置页如何共通日志 |
| [v1.0.57](https://github.com/123bnb/PageTurner/releases/tag/v1.0.57) | 统一代码：单仓库双 target，一次构建同时产出越狱 .deb 与巨魔 .dylib；删除失效的注入探针 |
| [v1.0.56](https://github.com/123bnb/PageTurner/releases/tag/v1.0.56) | 废代码清理 + 滑动(手动)合并为 1.0.55 的 DVT 式录制 |
| [v1.0.55](https://github.com/123bnb/PageTurner/releases/tag/v1.0.55) | 滑动(手动)改 DVT 式（灰底无穿透）+ 统一轨迹基准 + 调试日志开关关即清空 |
| [v1.0.54](https://github.com/123bnb/PageTurner/releases/tag/v1.0.54) | 优化事件热路径：配置路径缓存 + 诊断日志收敛 |
| [v1.0.53](https://github.com/123bnb/PageTurner/releases/tag/v1.0.53) | 手动动作回归：删除点击(手动)/双击(手动)，滑动(手动)改为填参数 |
| [v1.0.52](https://github.com/123bnb/PageTurner/releases/tag/v1.0.52) | 修复测试本方案看不到滑动(手动)轨迹（回放分支此前被 else 跳过） |
| [v1.0.51](https://github.com/123bnb/PageTurner/releases/tag/v1.0.51) | 同步 dylib v1.0.12 四件套：keyWindow 覆盖层 + 手动录制 + 轨迹可见 + 重录覆盖 |
| [v1.0.50](https://github.com/123bnb/PageTurner/releases/tag/v1.0.50) | 可视化绿点窗口 windowLevel 降为 Normal+1（彻底不碰状态栏） |
| [v1.0.49](https://github.com/123bnb/PageTurner/releases/tag/v1.0.49) | 状态栏修复：可视化窗口不再接管状态栏，开关关掉时销毁窗口 |
| [v1.0.48](https://github.com/123bnb/PageTurner/releases/tag/v1.0.48) | 删除音量动作类型（音量+/音量-/静音切换）+ 日志页改读运行端日志文件 |
| [v1.0.47](https://github.com/123bnb/PageTurner/releases/tag/v1.0.47) | 音量读取改 MPVolumeView slider（绕开「无音频会话进程恒假 0.5」） |
| [v1.0.46](https://github.com/123bnb/PageTurner/releases/tag/v1.0.46) | 音量±基础值修复：改走 AVAudioSession.outputVolume 现读现算 |
| [v1.0.45](https://github.com/123bnb/PageTurner/releases/tag/v1.0.45) | 修复音量±只能首次触发（目标值不再依赖 get 回读） |
| [v1.0.44](https://github.com/123bnb/PageTurner/releases/tag/v1.0.44) | 修复音量动作全部无效（AVSystemController category 字符串用错）+ CI 版本号修复 |
| [v1.0.43](https://github.com/123bnb/PageTurner/releases/tag/v1.0.43) | 9 项改进：防抖严谨化 + 可视化修正 + 速度默认 1000 + 映射排序 |
| [v1.0.42](https://github.com/123bnb/PageTurner/releases/tag/v1.0.42) | 调试日志总开关 + 日志上限（内存 200 条 / 文件 1000 行） |
| [v1.0.41](https://github.com/123bnb/PageTurner/releases/tag/v1.0.41) | 狂按根因修复（Began 延迟 40ms）+ 固定 60fps + 防惯性显式开关 |
| [v1.0.40](https://github.com/123bnb/PageTurner/releases/tag/v1.0.40) | 惯性修复：时间插值 + 静止衰减（模拟真实手指停住） |
| [v1.0.39](https://github.com/123bnb/PageTurner/releases/tag/v1.0.39) | 滑动 6 参数 + 回滑防惯性 + 修复连按滑动越滑越短 |
| [v1.0.38](https://github.com/123bnb/PageTurner/releases/tag/v1.0.38) | 修复严重 bug：新增映射会覆盖已有第 1 条映射 |
| [v1.0.37](https://github.com/123bnb/PageTurner/releases/tag/v1.0.37) | 滑动时序参数扩展：新增弹起停留 liftMs + 滑动分段可调 |
| [v1.0.36](https://github.com/123bnb/PageTurner/releases/tag/v1.0.36) | 点击特征启用位移矢量匹配（区分同 sender 的双点击键） |
| [v1.0.35](https://github.com/123bnb/PageTurner/releases/tag/v1.0.35) | 设置页风格统一：灰分组背景 + 方案名白卡片 |
| [v1.0.34](https://github.com/123bnb/PageTurner/releases/tag/v1.0.34) | 多特征方案：一个方案可有多条特征（解决「启动后首次按键位移特殊」录不进） |
| [v1.0.33](https://github.com/123bnb/PageTurner/releases/tag/v1.0.33) | 测试区滑动速度修复（与运行端统一为 时长=距离/速度）+ 命中日志加特征 |
| [v1.0.32](https://github.com/123bnb/PageTurner/releases/tag/v1.0.32) | 双动作彻底根除：gInFakeTouch 精确识别注入触摸，翻页器按键执行中一律拦截 |
| [v1.0.31](https://github.com/123bnb/PageTurner/releases/tag/v1.0.31) | 深色模式适配（学习页大白屏改系统自适应背景） |
| [v1.0.30](https://github.com/123bnb/PageTurner/releases/tag/v1.0.30) | 双动作根因修复：拦截窗口 50ms→400ms + sender 校验防误吞手指 |
| [v1.0.29](https://github.com/123bnb/PageTurner/releases/tag/v1.0.29) | 8 项：学习页保存改手动 + 注入探针独立开关 + 拦截与日志落盘修复 |
| [v1.0.28](https://github.com/123bnb/PageTurner/releases/tag/v1.0.28) | 定稿版：拦截方案 B（整段吞 + 未命中重放）+ 动作时序参数全可调 |
| [v1.0.27](https://github.com/123bnb/PageTurner/releases/tag/v1.0.27) | 新增触摸 sender 诊断日志（实测证明手指 ≠ 翻页器） |
| [v1.0.26](https://github.com/123bnb/PageTurner/releases/tag/v1.0.26) | 总开关 = 总闸：探针 / 提醒条 / 调试可视化全部纳入 |
| [v1.0.25](https://github.com/123bnb/PageTurner/releases/tag/v1.0.25) | 跨沙盒配置读写双通：设置页同时写 jbroot 路径，App 侧读得到 |
| [v1.0.24](https://github.com/123bnb/PageTurner/releases/tag/v1.0.24) | 注入可视化：打开 App 一眼看出注入成功没（探针弹窗 + 提醒条） |
| [v1.0.23](https://github.com/123bnb/PageTurner/releases/tag/v1.0.23) | 【终极根因】Filter 空 {} → ellekit 从不注入任何进程；改为 com.apple.UIKit |
| [v1.0.22](https://github.com/123bnb/PageTurner/releases/tag/v1.0.22) | 修复 ellekit 拒载：删除 dynamic_lookup，让 _MSHookMessageEx 正常 import |
| [v1.0.21](https://github.com/123bnb/PageTurner/releases/tag/v1.0.21) | 修复目标 App 不生效的三个根因（对照 volumekeytapper） |
| [v1.0.20](https://github.com/123bnb/PageTurner/releases/tag/v1.0.20) | 运行端改测试区同款会话链路：命中才吞、未命中放行 |
| [v1.0.19](https://github.com/123bnb/PageTurner/releases/tag/v1.0.19) | 方案页新增「▶ 测试本方案」：大白屏测试页 + 绿点点触可视化 |
| [v1.0.18](https://github.com/123bnb/PageTurner/releases/tag/v1.0.18) | 运行端双通道：方向键走 HID 位移、点击键走 UITouch 会话 |
| [v1.0.17](https://github.com/123bnb/PageTurner/releases/tag/v1.0.17) | 以真实 v1.0.4（commit 0cd50018）为基底 + 日志系统 |
| [v1.0.16](https://github.com/123bnb/PageTurner/releases/tag/v1.0.16) | 整包回滚 v1.0.4（用户实测唯一能正常录多键的版本）+ 只新增日志系统 |
| [v1.0.15](https://github.com/123bnb/PageTurner/releases/tag/v1.0.15) | 录制采集修复：方向键=hover 事件（此前被过滤）+ Tweak 全 App 学习采集 |
| [v1.0.14](https://github.com/123bnb/PageTurner/releases/tag/v1.0.14) | 录制端双通道采集，根治「位移丢失 + 心跳污染」 |
| [v1.0.13](https://github.com/123bnb/PageTurner/releases/tag/v1.0.13) | 日志改内存+文件双写（日志页 100% 可见）+ 冲突提示自动换行 |
| [v1.0.12](https://github.com/123bnb/PageTurner/releases/tag/v1.0.12) | 录制日志路径修复（改写到 Preferences 沙盒容器，日志这次真的能写出来） |
| [v1.0.11](https://github.com/123bnb/PageTurner/releases/tag/v1.0.11) | 录制端全链路日志 + 会话彻底复位 + 判重提示显示特征对比 |
| [v1.0.10](https://github.com/123bnb/PageTurner/releases/tag/v1.0.10) | 录制端真正回滚 v1.0.4 原版（整段还原采集代码） |
| [v1.0.9](https://github.com/123bnb/PageTurner/releases/tag/v1.0.9) | 录制回滚 v1.0.4 行为（去掉锚定锁定）+ 学习轨迹可视化 + 日志目录修复 |
| [v1.0.8](https://github.com/123bnb/PageTurner/releases/tag/v1.0.8) | 拦截架构回滚到 sendEvent 层，修复方向键完全没拦 |
| [v1.0.7](https://github.com/123bnb/PageTurner/releases/tag/v1.0.7) | 修复录制回归（进入学习页延迟 1 秒再接收）+ 设置图标改标准 29×29 |
| [v1.0.6](https://github.com/123bnb/PageTurner/releases/tag/v1.0.6) | 【核心】修复模拟触摸注入：注入事件补 senderID；调试模式改为点触可视化 |
| [v1.0.5](https://github.com/123bnb/PageTurner/releases/tag/v1.0.5) | 【核心】修复映射动作不生效：特征提取搬到 IOHIDEvent 层；新增调试模式与日志页 |
| [v1.0.4](https://github.com/123bnb/PageTurner/releases/tag/v1.0.4) | 设置 App 里 PageTurner 条目加图标 |
| [v1.0.3](https://github.com/123bnb/PageTurner/releases/tag/v1.0.3) | 修复学习收集失效（搬进设置页 bundle 自 hook）+ 首页空条目与方案页布局 |
| [v1.0.2](https://github.com/123bnb/PageTurner/releases/tag/v1.0.2) | 修复设置里看不到 PageTurner 条目（PreferenceLoader 入口 plist 缺字段） |
| [v1.0.1](https://github.com/123bnb/PageTurner/releases/tag/v1.0.1) | 架构修正：UI 全部移入系统设置页，App 内零 UI；sender 录进特征不再写死设备 |
| [v1.0.0](https://github.com/123bnb/PageTurner/releases/tag/v1.0.0) | 首个正式版：注入所有 App，拦截翻页器触摸键并映射为动作序列 |

## 常见问题

- **按一次键两个动作（原始滑动 + 映射）**：v1.0.30 / v1.0.32 已根除（窗口加长 + 执行中按键也拦截）。若仍复现，发 `PageTurner.log`
- **录不了 / 只录一个键说重复**：特征按 sender + 方向 + 位移区分；不同键位移方向不同即可分别录入。确认用的是最新版本（老版本采集逻辑有回归）
- **狂按 / 连按滑动残缺**：v1.0.41 + v1.0.43 双重修复——Began 延迟 40ms 让旧滑动复位先发出；防抖严谨化后序列执行中一律忽略新键，滑动再不会被新键掐断
- **映射动作很慢**：滑动动作默认速度 1000pt/s，长按该动作可调（参数页还有预设值一键点击）
- **手指触摸会被吞吗**：不会。拦截有 sender 校验，手指（0x1000008ef 等）永远放行
- **找不到日志文件**：用 v1.0.29+，`/var/mobile/Documents/PageTurner.log` 会自动创建
- **学习页录不到翻页器**：确认学习页在系统设置前台（事件只路由给前台 App），翻页器已连接
- **设置页在哪**：系统设置 → PageTurner 分组（v1.0.1+ 全部 UI 在系统设置里）

## 说明

- 本插件仅用于个人自动化 / 辅助使用，请勿用于绕过付费、批量操作等违规场景
- 不同品牌翻页器的事件特征可能不同，换设备后重新录一次即可
- 仅供研究学习，使用风险自行承担
