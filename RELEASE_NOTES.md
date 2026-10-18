# PageTurner v1.0.61

> 修复 deb 测试区「滑动(手动)」像点击：补上插值 + 60fps 帧驱动，与 dylib / 运行端一致

## 🔧 修复

**【测试本方案】里「滑动(手动)」没有拖动连贯性、表现像一次点击**

- **根因**：设置页测试区（`RootListController`）与引擎（dylib / 运行端）**各写了一套回放代码**。
  引擎侧用 `PTFakeRecSwipeAsync`（CADisplayLink 60fps + 按时间插值 `PTRecSwipeInterp`）；
  设置页侧则**直接把录制点当触摸事件发**，中间**没有任何插值**——
  录制点少时（甚至只有起点+终点）就变成 `Began` 后立刻 `Ended`，也就是一次点击
- **修复**：设置页补上插值函数 `PTTestRecSwipeInterp`，改为 **60fps 逐帧插值回放**
  （每 16ms 按时间插值出一个位置发 `Moved`，累计到录制时长后 `Ended`），并**逐帧画轨迹点**
  （此前是逐点画，点少时只画两个点，所以视觉上也像点击）
- 录制时长异常短时兜底 50ms（与引擎一致），避免再退化成点击

> 说明：**运行端（真机按键）本来就有插值**，是连贯的；只有「测试本方案」这个预览页有问题。

## 🔍 顺带做的全仓排查（找同类问题）

对比了设置页与引擎的 **13 个同名函数 + 判定常量 + 匹配逻辑**：

- 判定常量**全部一致**：方向容差 15°、位移裕度 30、点击位移容差 0.15、学习下限 5 / 上限 15 / 收敛 60
  （设置页叫 `kDirTol`、引擎叫 `kDirTolerance`，名字不同但值都是 15.0）
- 匹配逻辑一致：测试区 `PTTestMatchFeature` 与运行端匹配同源，都用 `kTapDistSlack` / `kDistSlack`
- 学习采样（`SAppendSample`）、判重（`PTDuplicate`）、稳定性判定（`PTStable`）、
  动作执行（点击 / 双击 / 滑动 / 延迟）两边一致
- **唯一的真实差异就是上面这个 recSwipe 回放**（已修）
- 无害差异：设置页 `PTActionText` 对已删除的「点击(手动)/双击(手动)」多一句提示文案（更好）

## 📦 下载与安装

| 形态 | 文件 | 用法 |
|------|------|------|
| 越狱（Dopamine / roothide） | `PageTurner-1.0.61-roothide.deb` | 安装后**注销**，系统设置 → PageTurner |
| 巨魔（TrollStore / TrollFools） | `PageTurnerDylib_v1.0.61.dylib` | 注入目标 App，**注入即生效**，App 内**双指长按**（两指同时按住 0.5 秒）弹菜单 |
