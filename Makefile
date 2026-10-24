# ============================================================
# PageTurner v1.0.78 —— 构建校验加固 + 引擎核心拆分（功能不变）
# ============================================================
# v1.0.78 变更概览（详见 RELEASE_NOTES.md）：
#   · scripts/check_syntax.sh + check_imports.sh：括号平衡 / import 链校验进仓库并挂 CI
#     （v1.0.77 的 5 轮 CI 编译修复根因 = 校验脚本用完即弃，本地发现不了 dylib 侧错误）
#   · scripts/build_dylib.sh：本地一键编 arm64+arm64e 双形态（dylib 构建不再只有 CI 一条路）
#   · dylib 构建加 strip + -Os + 分区/死代码消除（v1.0.77 产物 +18% 的体积回补）
#   · after-package 改快照式还原（不再冲掉用户本地未提交改动）
#   · PTEngineCore.m（84KB）拆为 7 个文件：纯逻辑层 PTCoreLogic（Foundation-only，
#     tests/ 可链、CI 原生跑单测）+ 六件套（日志/配置/匹配/动作执行/测试可视化/连滑）
#     + 内部共享头 PTEngineInternal.h
#   · tests/：纯逻辑测试 harness（Foundation-only，CI 原生可跑）
#   · docs/REGRESSION_CHECKLIST.md：双形态人工回归清单
# 更细的版本史（v1.0.57~v1.0.77）见 RELEASE_NOTES.md；下方 v1.0.24/23 注入考古保留作踩坑记录。
#
# 架构：引擎核心 common/PTEngine*(配置/匹配/样本/测试/连滑/动作/日志，v1.0.78 拆分) 三个 target 共用；
#       外壳 common/PTEngine.m（hook 装配/运行拦截/可视化/录制/菜单）只被 deb+dylib 链接：
#       · roothide deb（Tweak.m 薄壳，MSHookMessageEx 装 hook，设置页总开关+指定App生效）
#       · 巨魔 dylib（targets/dylib/，method_setImplementation 自 hook，应用内双指长按菜单）
#       · Preferences（RootListController + Core，不链外壳；进程内自 hook 采集）
# 事件/动作/匹配 全部共用，差异仅「配置路径 / 总开关门控 / hook 安装方式」，通过 PTSet* 注入。
# 事件：hook UIApplication -sendEvent:（UIEvent 层，UITouch 真实坐标）
#       + _UIUpdateHIDDigitizerInput -addEvent:（IOHIDEvent 层，sender 判来源/学习）
# 动作：PTFakeMetaTouch（点击/双击/滑动）+ AVSystemController（静音/音量±）
# UI：全部在系统设置 → PageTurner 设置页（Preferences bundle），App 内零 UI
# 日志：App 容器 Documents/PageTurner.log + /var/mobile/Documents/PageTurner.log
#
# v1.0.24 新增、v1.0.57 已删除（旧版无法注入时的兜底，早已失效）：
#   · 注入探针 ShowProbeAlert：第三方 App 启动 2.5s 弹窗（本App/注入✅/全局配置/总开关/
#     crashTest/勾选App数/本App被勾选）
#   · 提醒条 ShowToast（勾选生效 App）：黑底白字+黄边框、中上方、2 秒
#   → 删除后 App 内无任何弹窗/提醒条；确认是否注入成功改看「调试可视化」绿点轨迹
# v1.0.23 关键修复（三路实证锁定终极根因 = Filter，不是符号）：
#   · TrollCM deb 拆包：Filter={ Bundles=[com.apple.springboard] } + _MSHookMessageEx×4 → 注入 SB 成功
#   · volumekeytapper Makefile：Filter={ Bundles=[com.apple.UIKit] } + -Wl,-undefined,dynamic_lookup
#     → 注入所有 UIKit App 成功（用户实证点击成功）——它带 dynamic_lookup 也能注入！
#   · PageTurner 一直写 printf '{}'（空 Filter）→ ellekit 跳过，目标 App 从未被注入 → 16 版全无效
#   → 本版 Filter 改为 { Filter = { Bundles = ( "com.apple.UIKit"); }; }（照抄 volumekeytapper）
#   → 恢复 -Wl,-undefined,dynamic_lookup（volumekeytapper 同款，dynamic_lookup 本就不是问题）
#   → MSHookMessageEx 声明补 extern "C"（v1.0.22 链接失败：C++ 修饰符号找不到 _MSHookMessageEx）
#   → 新增调试可视化：TrollCM 触摸轨迹（绿点+轨迹线+翻页器 P 标记），设置页「调试可视化」开关
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME := roothide
PACKAGE_VERSION := 1.0.79

DEBUG = 0
ARCHS = arm64 arm64e

# v1.0.70：共享源文件列表 + 共享编译 flags 的单一真源（Makefile 与 CI 的 dylib 构建共用）
include build/sources.mk

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PageTurner

# v1.0.71：deb 目标文件列表 = build/sources.mk 的 PTSRC_ALL_DEB
#          （KIF + 引擎核心 PTEngineCore + 引擎外壳 PTEngine + Tweak.m）。
# 此前这里手写 `Tweak.m $(SHARED_SOURCES)`，与 build.yml / Preferences/Makefile 三处各自维护。
PageTurner_FILES = $(PTSRC_ALL_DEB)
PageTurner_CFLAGS = $(SHARED_CFLAGS)
PageTurner_FRAMEWORKS = Foundation UIKit IOKit
PageTurner_LIBRARIES = substrate
# 照抄 volumekeytapper：-Wl,-undefined,dynamic_lookup 允许 IOHIDEvent*/MSHookMessageEx
# 未定义符号运行时动态解析；它带此 flag 注入成功，证明该 flag 不影响 ellekit 注入判定
PageTurner_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 设置页 ----------
SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/aggregate.mk

# ---------- Filter：注入所有 UIKit App（照抄 volumekeytapper 的 OpenStep 写法）----------
# 空 Filter {} 会被 ellekit 跳过 → 目标 App 从未被注入（v1.0.1~v1.0.22 全部无效的终极根因）
before-package::
	printf '{ Filter = { Bundles = ( "com.apple.UIKit"); }; }\n' > "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/PageTurner.plist"
	mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	cp -f "layout/Library/PreferenceLoader/Preferences/PageTurner.plist" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"

# ---------- 版本号单一真源：从 PACKAGE_VERSION 自动派生 control / Info.plist ----------
# 根治「三处手填」漂移：发版只改上面一行的 PACKAGE_VERSION，打包前自动同步其余两处。
#
# v1.0.78（评审 #3）：跑 sync_version 之前先快照原内容（.pt-version-snapshot/），
# 供 after-package 精确回退——旧实现 `git checkout --` 无条件还原到提交态，会把用户
# 对这两个文件的本地未提交改动一并冲掉且无提示。语义 = 「打包前是什么样，打包后还是什么样」。
PT_VERSION_FILES := control Preferences/Resources/Info.plist
PT_SNAP_DIR := .pt-version-snapshot

before-package::
	@mkdir -p $(PT_SNAP_DIR)/Preferences/Resources
	@cp -f control $(PT_SNAP_DIR)/control
	@cp -f Preferences/Resources/Info.plist $(PT_SNAP_DIR)/Preferences/Resources/Info.plist
	bash ./scripts/sync_version.sh

# ---------- 编译期横幅头：任何 make 调用前幂等生成 ----------
# PTVersion.h 是 .gitignore 生成物，全新 checkout 里不存在；Tweak.m 等源码 import 它，
# 必须早于编译。挂 before-all（plain make / make package 都会先跑）；只生成头文件、
# 不碰 tracked 的 control/Info.plist（那是 before-package 的职责）。
# CI 另外在 checkout 后直接调 scripts/gen_ptversion.sh——巨魔 dylib 走裸 clang 构建，
# 不过 make 钩子，编译前头文件必须已在。
before-all::
	bash ./scripts/gen_ptversion.sh

# ---------- 还原工作树：打包产生的 control/Info.plist 改写不应留在 git 里 ----------
# sync_version.sh 在 before-package 阶段会把仓库根 control / Info.plist 同步成
# PACKAGE_VERSION（仅 deb 打包需要）。打包完成后按 before-package 的快照原样写回，
# 避免本地 `make package` 后 git status 出现脏文件、误提交；sync_version 的改写被
# 精确回退，用户自己的未提交改动不受影响。CI 中 check_version.sh 已保证提交态
# 三处一致，此处还原不影响产物（deb 已在打包阶段生成完毕）。
# 无快照（非常规调用，如只跑 make 不打包）时跳过，绝不碰 git。
after-package::
	@if [ -f "$(PT_SNAP_DIR)/control" ] && [ -f "$(PT_SNAP_DIR)/Preferences/Resources/Info.plist" ]; then \
	  cp -f $(PT_SNAP_DIR)/control control; \
	  cp -f $(PT_SNAP_DIR)/Preferences/Resources/Info.plist Preferences/Resources/Info.plist; \
	  rm -rf $(PT_SNAP_DIR); \
	  echo "after-package: 已按快照还原 control / Info.plist（用户本地未提交改动不受影响）"; \
	else \
	  echo "after-package: 无版本快照，跳过还原"; \
	fi
