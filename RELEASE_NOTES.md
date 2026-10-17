# PageTurner v1.0.59

> 日志统一到「共享 jbroot 的 Documents」、调试日志改版；删除注入标记与全部诊断代码

依据 v1.0.58 诊断结论：**第三方沙盒 App 写不了普通 `/var/mobile/Documents`，但能写共享 jbroot 的 `var/mobile/Documents`，且设置页能读到**——故日志统一走 jbroot。

## 🗑 删除

- **注入标记功能**（`PTWriteInjectMarker`）：不再产生任何 `PageTurner-injected-*.txt`（含 `/var/mobile/Documents`、`/tmp`、jbroot 变体）。注入早已稳定，不再需要人工肉眼确认
- **v1.0.58 的全部诊断代码**：诊断 plist（`PageTurner-diag-*.plist`）、多路径探测函数、设置页诊断视图
- **`/var/mobile/Documents`（真实路径）不再存放任何日志文件**，日志只存在于 jbroot 的 Documents

## ✨ 新增

- **日志统一写入共享 jbroot 的 Documents**：
  - `PageTurner.log` —— 设置页进程日志
  - `PageTurner-<bundleID>.log` —— 各生效 App 的运行日志
- **「调试日志（详情）」改版为「选日志」列表**：第一项是设置页日志，其后是各生效 App 的运行日志；显示文件大小，点击进内容页查看并一键复制
- **长文件名一行显示不下可横向滑动**查看完整路径
- **【调试日志】开关联动**：关闭时隐藏下方详情入口，并**立即清空全部日志**（内存 + 所有 `PageTurner*.log` 文件）
- **巨魔 dylib 也写同一个 jbroot 目录**（此前写在自己容器，设置页读不到）
- **jbroot 探测提到引擎共用**（`PTJbrootRoot`），并加「扫描 App 安装目录找 `.jbroot-*`」兜底，供**纯 dylib 注入的 App**（如用 TrollFools 注入的番茄小说）也能定位 jbroot

## 🔄 改动

- **日志循环统一 500 条**（内存与文件一致；此前内存 200 条 / 文件 1000 行）
- 设置页自身日志路径改到 jbroot（与 App 侧同目录，才能读到各 App 日志）
- 兜底日志文件名 `PageTurnerDylib.log` → `PageTurner.log`

## 🔧 修复

- **版本号日志硬编码**：此前始终打印 "v1.0.57"（升版本时漏改字符串），现已修正为实际版本，并在日志里附带当前日志文件路径
- 修正「设置页读不到目标 App 运行日志」的老问题（根因：App 日志写在自己容器）

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.59-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.59.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

## 🔍 排查

- 日志目录：`<jbroot>/var/mobile/Documents/`（如 `/private/var/containers/Bundle/Application/.jbroot-XXXX/var/mobile/Documents/`）
- 设置页「调试日志」里直接选日志查看 / 复制，也可直接用 Filza 打开上述目录
- 注意：巨魔 dylib 注入的 App，需在设置页「指定 App 生效」里勾选，其日志才会出现在列表中
