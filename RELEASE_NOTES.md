# PageTurner v1.0.58（日志通路诊断版）

> **仅用于诊断「App 侧与设置页如何共通日志」，不含任何功能改动。**

## ✨ 新增（诊断能力）

- App 侧（被注入的进程）启动时，探测 **4 类候选日志路径**是否可写，日志会**同时写入所有可写路径**
  1. `/var/mobile/Documents/PageTurner-<bundleID>.log`
  2. `<jbroot>/var/mobile/Documents/PageTurner-<bundleID>.log`（roothide 真实路径）
  3. `/tmp/PageTurner-<bundleID>.log`
  4. App 自身容器 `Documents/PageTurner.log`（原行为，作对照）
- 探测结果写入**独立诊断文件** `PageTurner-diag-<bundleID>.plist`（写到上述多个目录），**不碰主配置**，不会影响你的方案/勾选数据
- 设置页「调试日志」页改为**诊断视图**，显示三部分：
  1. 设置页进程能列出哪些目录、里面有哪些 `PageTurner*` 文件（大小 / 是否可读）
  2. 能读到的 App 侧诊断 plist（App 自己探测出的可写 / 不可写路径、jbroot、容器路径）
  3. 各候选日志文件能不能读到内容（尾部 30 行预览）

## 🔄 改动

- 引擎 `common/PTEngine.m`：日志写入支持**多路径同时写**（新增 `PTSetLogPaths` / `PTLogActivePaths`）

## 🚫 本次**没有**改的东西（等诊断完再动）

- 注入标记：保留未动
- 调试日志开关与「调试日志(详情)」的联动：未做
- 日志条数 500 条循环：未做
- 日志文件名滚动显示：未做
- 关闭调试日志时清空日志：未做

## 🔍 怎么配合诊断（3 步）

1. 安装本版 → **注销**
2. 打开目标 App（例如番茄小说，让它被注入一次）→ 随便按几下翻页器
3. 回到 **系统设置 → PageTurner → 调试日志**，把整页内容**全选复制**发给开发者

**重点看两处**：

- 【2】里有没有读到 App 上报的诊断 plist —— 有，说明「App 侧写的文件」设置页能读到
- 【1】【3】里 `/var/mobile/Documents` 下的 `PageTurner-*.log` 是否存在且可读 —— 决定日志最终该落在哪条路径

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.58-roothide.deb` | 安装后**注销**，系统设置 → PageTurner → 调试日志 |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.58.dylib` | 注入目标 App（本次诊断主要针对越狱 deb 形态） |

## 🔍 排查

- 越狱版日志候选：`/var/mobile/Documents/PageTurner.log`、`PageTurner-<bundleID>.log`、`<jbroot>/var/mobile/Documents/...`、`/tmp/...`
- 诊断文件：`PageTurner-diag-<bundleID>.plist`（可直接用 Filza 打开看）
