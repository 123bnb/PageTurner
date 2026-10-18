# PageTurner v1.0.62

> 修复 dylib「新增滑动(手动)」点取消退回首页的问题；并把四个「新增映射」页面统一成一套共享模板

## 🐛 修复 — dylib 新增映射点「取消」应回方案页，而非插件首页

**【方案页 → 新增映射 → 滑动(手动)】，点左上角「取消」，直接退回 dylib 插件首页，应该返回「方案页」**

- **根因**：原来的实现在弹出录制覆盖层时，走的是「全局关闭菜单再重建」的逻辑——`PTDylibCloseMenu` 会销毁菜单 `UIWindow` 连同里面的 `UINavigationController` 导航栈，
  等取消 / 完成后再 `PTDylibShowMenu` 从首页（`PTDylibMenuVC`）重新搭起，自然就回不到原来的「方案页」了。
- **修复（采用方案 B — 仅录制场景重建回方案页，不动全局菜单关闭逻辑）**：
  - 新增 `PTDylibHideMenuPreserving()` —— 录制覆盖层弹出时**只隐藏菜单窗口、保留导航栈**，不再销毁；
  - 录制结束（取消 / 完成）后 `PTDylibShowMenu()` 重新显示，保留的导航栈自动回到进入前的「方案页」，
    并对对应的 `PTPlanVC` 调 `reload` 刷新列表；
  - 全局 `PTDylibCloseMenu`（用户点「关闭」菜单）保持原样——彻底销毁，行为不变。

## ♻️ 改动（重构）— 四个「新增映射」页面统一成一套模板 `common/PTOverlayPage`

之前 deb 与 dylib 各自写了一份「点击 / 双击 / 滑动」的 `PTActionVC`，以及各写了一份「滑动(手动)」的录制页
（deb 是 `PTRecSwipeVC` 不透明灰全屏页，dylib 是 `PTRecShowOverlay` 半透明黑覆盖层），**逻辑重复、表现还不一致**。

现在抽出**一份共享模板 `common/PTOverlayPage.{h,m}`**，deb 与 dylib 共用：

- 统一了四个页面的**模板外壳 + 顶部 56pt「取消 / 完成」操作条 + 安全区回退**；
- **半透明背景（按版本区分）**：
  - `dylib`：`translucent = YES` → 四个页面均改为**半透明黑（alpha 0.4）覆盖层**，和原来的「滑动(手动)」观感一致；
  - `deb`：`translucent = NO` → 仍是**不透明灰全屏页**（和系统设置页风格统一）。
- **交互表现不变（按你的要求保留原样）**：
  - 「点击 / 双击 / 滑动」继续用原来的**绿点拖动**录交互（绿点、拖动、坐标反馈 label 原样保留）；
  - 「滑动(手动)」继续用原来的**手势轨迹录制**（3px 阈值降采样、蓝色 6pt 轨迹、录制点回调）；
- 通过 **host 回调（`onSave` / `onDismiss` / `recStart` / `recStop`）** 把「保存配置、关闭、录制起止」交给宿主实现，
  从而**避免把共享引擎链接进 deb 设置页**（deb 不链 `PTEngine`，用 `PTRead()/PTWrite()` 自己的本地实现），
  实现真正的单份代码、双端复用。

## 🔧 对应文件改动

| 文件 | 改动 |
|------|------|
| `common/PTOverlayPage.{h,m}` | **新增** 四个新增映射页的共享模板 |
| `Preferences/RootListController.m` | 接入 `PTOverlayPage`，删除旧的 `PTActionVC` / `PTRecSwipeVC` |
| `Preferences/Makefile` | `PageTurner_FILES` 加入 `../common/PTOverlayPage.m`，`CFLAGS` 加 `-I../common` |
| `targets/dylib/PTDylibUI.m` | 接入 `PTOverlayPage`，删除旧的 `PTActionVC` / `PTRecShowOverlay` 等录制代码 |
| `targets/dylib/PTDylibMain.m` | 新增 `PTDylibHideMenuPreserving()` / `PTDylibMenuWindow()`，去掉 `PTRecMigrateOverlay()` 调用 |
| `common/PTEngine.h` | 声明导出 `PTDylibHideMenuPreserving()` / `PTDylibMenuWindow()` |
| `.github/workflows/build.yml` | dylib 编译 `SRCS` 加入 `common/PTOverlayPage.m` |
| `control` / `Makefile` / `Preferences/Resources/Info.plist` | 版本号 **1.0.61 → 1.0.62** |

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.62-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.62.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |
