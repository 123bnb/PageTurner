# PageTurner v1.0.57

同一套源码、一次构建，同时产出**越狱版 `.deb`** 与**巨魔版 `.dylib`**。

## 本次做了什么

### 1. 代码统一：roothide 版与巨魔版合并为同一套源码

- 抽出共用运行端引擎 `common/PTEngine.{h,m}`（配置读写、日志、特征匹配、动作执行、可视化、两条 hook 处理器），**两个形态共用同一份**
- 越狱 `.deb`：薄壳 `Tweak.m`（jbroot 配置路径探测 + 总开关/指定 App 门控 + `MSHookMessageEx` 装 hook）
- 巨魔 `.dylib`：`targets/dylib/`（入口/菜单窗口 + 浮窗菜单/录制覆盖层，用 `method_setImplementation` 自 hook）
- 形态差异全部通过 `PTSet*` 接口注入（配置路径、日志路径、拦截开关、原始 IMP），引擎不再写死任何形态特有逻辑
- `ptftouch/`（12 个文件）两形态逐字节一致，留在仓库根共享
- 一次 GitHub Actions 同时产出 `.deb` 与 `.dylib` 两个包

### 2. 删除已失效的注入探针

- 移除旧版"无法注入时的兜底"弹窗（`PTShowProbeAlert`）与提醒条（`PTShowToast`），以及设置页「注入探针」开关
- 该功能早已失效，删除后 **App 内不再有任何弹窗/提醒条**
- 需要确认是否注入成功，请用设置页「调试可视化」（绿点轨迹）或「调试日志」

### 3. 修正手势说明：三指 → 双指

- 巨魔版菜单触发方式代码一直判定为**双指长按**（两指同时按住 0.5 秒），此前 Release/说明文案误写为「三指」，已全部统一为「双指」并补明触发条件

### 功能与 v1.0.56 完全一致

学习模式、记录与映射、动作执行、防抖、调试可视化/调试日志等**全部功能不变**。本次只是代码统一 + 删除废功能 + 文档修正，没有新增或改动任何运行时行为。

## 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.57-roothide.deb` | 安装后**注销**，系统设置 → PageTurner：开总开关 + 勾选生效 App |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.57.dylib` | 用注入器注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

## 使用提示

- **越狱版**：UI 全在系统设置页，目标 App 内没有页面、没有手势
- **巨魔版**：App 内双指长按弹菜单；可视化/录制覆盖层挂在 keyWindow 上，不建独立窗口
- **看日志排查**：越狱版 `/var/mobile/Documents/PageTurner.log`；巨魔版在 App 容器 `Documents/PageTurner.log`
- iOS 15 / 16，iPhoneOS 16.5 SDK 编译，架构 arm64 + arm64e
