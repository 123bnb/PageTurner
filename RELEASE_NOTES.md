# PageTurner v1.0.57

> 统一代码：单仓库双 target，一次构建同时产出越狱 .deb 与巨魔 .dylib；删除失效的注入探针

## ✨ 新增
- 巨魔（TrollStore / TrollFools）dylib 形态：targets/dylib/（入口/菜单窗口 + 浮窗菜单/录制覆盖层，用 method_setImplementation 自 hook），注入即生效，App 内双指长按弹菜单
- 共用运行端引擎 common/PTEngine.{h,m}：配置读写、日志、特征匹配、动作执行、可视化、两条 hook 处理器，两个形态共用同一份
- 形态差异通过 PTSet* 接口注入（配置路径 / 日志路径 / 拦截开关 / 原始 IMP），引擎不再写死任何形态特有逻辑
- 一次 GitHub Actions 同时产出 .deb 与 .dylib 两个包
- RELEASE_NOTES.md（发布说明文件，Release 用 gh release create --notes-file 读取）

## 🔧 修复
- 手势说明文案错误：代码判定一直是「双指长按」（两指同时按住 0.5 秒），但 Release/README/注释共 6 处误写为「三指」→ 全部统一为双指并补明触发条件
- deb 编译失败（5 errors）：Tweak.m 里 extern "C" 是 C++ 语法（原 Tweak.xm 经 Logos 转 .mm 才需要），改为 .m 后非法并连带 MSHookMessageEx 声明失效 → 改为直接 extern；补 <mach-o/dyld.h>（_dyld_image_count 未声明）、<stdio.h>
- 引擎编译失败（3 errors）：PTConfigDict 定义在 gConfig 声明之前（C 要求先声明后使用）→ 移到 PTDylibLoadConfig 之后；kMaxLearnedSenders 为 static const int，C 中不是编译期常量 → 数组退化为 VLA，被 theos 的 -Werror 升级为错误 → 改为 #define
- dylib 编译失败：引擎从仓库根移到 common/ 后，#import "ptftouch/..." 按文件所在目录解析 → 找不到；clang 补 -I.（仓库根）进入搜索路径
- CI：Release 说明改为读取 RELEASE_NOTES.md（此前为单行硬编码，无法承载完整改动说明）

## 🗑 删除
- 注入探针（v1.0.24 引入的兜底弹窗 PTShowProbeAlert 与提醒条 PTShowToast）及设置页「注入探针」开关——旧版无法注入时的排查手段，早已失效；删除后 App 内不再有任何弹窗/提醒条，确认注入改看「调试可视化」绿点轨迹或「调试日志」

## 🔄 改动
- 代码统一：roothide deb 与巨魔 dylib 合并为同一套源码（原两套代码库合并）
- 越狱 deb 改为薄壳 Tweak.m（jbroot 配置路径探测 + 总开关/指定 App 门控 + MSHookMessageEx 装 hook），取代原 Tweak.xm
- ptftouch/（12 个文件）两形态逐字节一致，留在仓库根共享
- 设置页（Preferences）不引入共用引擎（RootListController 自带 static 副本，避免重复符号）

**说明**：功能与 v1.0.56 完全一致：学习模式、记录与映射、动作执行、防抖、调试可视化/调试日志全部不变。本次只是代码统一 + 删除废功能 + 文档修正，没有新增或改动任何运行时行为。

---

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.57-roothide.deb` | 安装后**注销**，系统设置 → PageTurner：开总开关 + 勾选生效 App |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.57.dylib` | 用注入器注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |

## 🔍 排查

- 越狱版日志：`/var/mobile/Documents/PageTurner.log`；巨魔版在 App 容器 `Documents/PageTurner.log`
- 确认是否注入生效：设置页开「调试可视化」（绿点轨迹）或看「调试日志」