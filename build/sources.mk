# ============================================================
# 共享构建配置 —— 单一真源（v1.0.70 建立；v1.0.71 起三目标化）
# ============================================================
# 背景：此前「共享源文件列表」在多处手填 ——
#   · Makefile 的 PageTurner_FILES（deb / Theos）
#   · .github/workflows/build.yml 里的 SRCS（dylib / 裸 clang）
#   · Preferences/Makefile 的 PageTurner_FILES + 第三份手抄 CFLAGS
#     （已漂移：缺 -fobjc-abi-version=2、缺仓库根 -I；review 第三轮的实锤）
#   于是加一个 .m 只改一处，另外两个 target 会**静默少编译一个文件**
#   （最坏不是链接报错，而是丢功能）；CFLAGS 漂移同理。
#
# 解法：本文件按「文件 → 被哪些目标使用」建模，三个消费者都从这里读：
#   · 根 Makefile : include build/sources.mk                  （deb）
#   · Preferences : PTROOT := .. ; include $(PTROOT)/build/sources.mk
#   · build.yml   : make -s -f build/sources.mk PRINT_CONFIG=1 print-*
#   （PRINT_CONFIG=1 守卫保证 print-* 目标不污染主 Makefile 的 default goal）
#
# 路径一律「仓库根相对」书写。PTROOT 处理跨目录 include 的前缀与 -I：
#   · 仓库根消费者（根 Makefile / build.yml）  PTROOT = .  （默认值）
#   · Preferences/Makefile（在子目录里）       PTROOT = ..
# 列表本身不带前缀，print-* 输出与 git ls-files 严格对齐（供 CI 源码覆盖审计）。
#
# 文件分组（按使用者）：
#   PTSRC_KIF     ptftouch 四件（fake touch / KIF 事件注入）       三目标全要
#   PTSRC_CORE    引擎核心 7 文件（v1.0.78 起 PTEngineCore.m 拆为：纯逻辑层 PTCoreLogic +
#                  日志/配置/匹配/动作执行/测试可视化/连滑 6 件套 + 内部共享头 PTEngineInternal.h）  三目标全要
#   PTSRC_ENGINE  common/PTEngine.m（引擎外壳：hook 装配/运行拦截/调试可视化）  deb + dylib
#   PTSRC_OVERLAY common/PTOverlayPage.m（点击/双击/滑动统一模板页）   dylib + Preferences
#   PTSRC_UISHARED common/PTUI*.m + PTDragSortHelper.m（共享设置页：基础设施 + 9 个 VC + 桥接工具） dylib + Preferences
#   PTSRC_DEB     Tweak.m（deb 私有：MSHookMessageEx/ellekit 装配）   deb
#   PTSRC_DYLIB   targets/dylib/*.m（dylib 私有：入口/菜单/日志源/导航器）  dylib
#   PTSRC_PREFS   Preferences/RootListController.m + PTShimVC.m + PTLogSourceDeb.m（设置页）  Preferences
# 目标组合 = 组相并。v1.0.71 起 Preferences 也链 PTSRC_CORE（消除设置页 ~950 行重复实现），
# 但不链 PTSRC_ENGINE（外壳的 hook 装配是 deb/dylib 专属；设置页进程有自己的 hook）。
# v1.0.77 起设置页 UI 全量统一：8 个同名 VC 曾 deb/dylib 各存一份（约 1,900 行×2，重复度 95–98%，
# 且 8 项行为漂移），现全部收敛到 common/PTUI*，两侧只留各实现一次的
# PTUIEnsureCollectHook / PTUIPresentEditor / 日志源 / 导航器（见各文件头注释）。
# deb 不链 PTSRC_UISHARED（注入镜像不带设置页）。
PTROOT ?= .

PTSRC_KIF := \
	ptftouch/PTFakeMetaTouch.m \
	ptftouch/UITouch-KIFAdditions.m \
	ptftouch/UIEvent+KIFAdditions.m \
	ptftouch/IOHIDEvent+KIF.m

# v1.0.78：PTEngineCore.m（1,525 行 / 84KB）按职责拆为 6 个实现文件 + 1 个内部共享头。
# 拆前它是全仓最大文件、单文件改一行就要全量重编；且 static 跨段可见性靠文件中部
# 前向声明维持（v1.0.66~77 因此炸过 3 轮「调用早于定义」）。拆后：
#   PTEngineLog.m     日志（PTDylibLog 家族 + PTNowC）
#   PTEngineConfig.m  配置路径/读写/UI 入口/运行端缓存/IOKit dlsym
#   PTEngineMatch.m   会话状态/学习样本/方案 pid/工具/匹配（运行端 + 测试端）
#   PTEngineExec.m    动作执行全家（fake touch）+ 测试回放执行链
#   PTEngineTestUI.m  测试可视化（绿点/方向线/P 标记/尾巴）+ 实时记录区
#   PTEngineChain.m   连滑状态机 + pill + 执行入口 + 注入引用计数
#   PTEngineVolume.m  音量键机制（KVO/Ambient 会话/去抖/徘徊/HUD 抑制/前台闸；v1.0.80）
#   PTEngineInternal.h（非 .m）跨文件内部 extern——仅上列 6 个 .m import，
#                       公共 API 仍走 PTEngineCore.h（三目标共享）。
# v1.0.78(2)：PTCoreLogic.m = 纯逻辑层（零 UI 依赖，Foundation-only）——从六件套抽出，
#   使 tests/ 能在 macOS 原生编译运行（CI 可跑单测）；三个 target 照常链接。
PTSRC_CORE := \
	common/PTCoreLogic.m \
	common/PTEngineLog.m \
	common/PTEngineConfig.m \
	common/PTEngineMatch.m \
	common/PTEngineExec.m \
	common/PTEngineTestUI.m \
	common/PTEngineChain.m \
	common/PTEngineVolume.m
PTSRC_ENGINE := common/PTEngine.m
PTSRC_OVERLAY := common/PTOverlayPage.m

PTSRC_DEB := Tweak.m
PTSRC_DYLIB := \
	targets/dylib/PTDylibMain.m \
	targets/dylib/PTDylibUI.m
PTSRC_PREFS := \
	Preferences/RootListController.m \
	Preferences/PTShimVC.m \
	Preferences/PTLogSourceDeb.m

# 共享设置页（v1.0.77 全量统一）：基础设施 + 9 个共享 VC + 拖拽助手
# v1.0.80：+PTUIVolumeVC（音量键模式页：总开关 + 音量+ 绿区 / 音量- 红区 + 测试行）
PTSRC_UISHARED := \
	common/PTUINavigator.m \
	common/PTUILogSource.m \
	common/PTUIBaseListVC.m \
	common/PTDragSortHelper.m \
	common/PTUICommon.m \
	common/PTUIDebounceVC.m \
	common/PTUIPlansVC.m \
	common/PTUIPlanVC.m \
	common/PTUIFeaturesVC.m \
	common/PTUILearnVC.m \
	common/PTUIActionParamVC.m \
	common/PTUITestVC.m \
	common/PTUIDebugLogVC.m \
	common/PTUILogContentVC.m \
	common/PTUIVolumeVC.m

PTSRC_ALL_DEB := $(PTSRC_KIF) $(PTSRC_CORE) $(PTSRC_ENGINE) $(PTSRC_DEB)
PTSRC_ALL_DYLIB := $(PTSRC_KIF) $(PTSRC_CORE) $(PTSRC_ENGINE) $(PTSRC_OVERLAY) $(PTSRC_UISHARED) $(PTSRC_DYLIB)
PTSRC_ALL_PREFS := $(PTSRC_KIF) $(PTSRC_CORE) $(PTSRC_OVERLAY) $(PTSRC_UISHARED) $(PTSRC_PREFS)

SHARED_CFLAGS := \
	-fobjc-arc \
	-fobjc-abi-version=2 \
	-Wno-deprecated-declarations \
	-Wno-unused-variable \
	-Wno-unused-function \
	-Wno-arc-performSelector-leaks \
	-Wno-arc-retain-cycles \
	-I$(PTROOT) \
	-I$(PTROOT)/common \
	-I$(PTROOT)/ptftouch \
	-include $(PTROOT)/ptftouch/Compat.h

# dylib 专属编译/链接 flags（v1.0.78，评审 #4）：
#   v1.0.77 起 dylib 从「自建精简副本」切换为链接 deb 派生的完整共享层（14 个 .m），
#   产物 +148KB（+18%）。这里做体积回补，**只作用于裸 clang 的 dylib 构建**：
#     · -Os                      体积优先的优化等级
#     · -ffunction-sections -fdata-sections  按函数/数据分区，供死代码消除生效
#     · -Wl,-dead_strip          链接期剔除未被引用的分区（macOS ld64 的 --gc-sections）
#   deb（theos + substrate）不感知这两个变量——注入镜像不冒险改能跑的形态。
DYLIB_CFLAGS := -Os -ffunction-sections -fdata-sections
DYLIB_LDFLAGS := -Wl,-dead_strip

ifeq ($(PRINT_CONFIG),1)
.PHONY: print-cflags print-deb-sources print-dylib-sources print-prefs-sources print-uihared-sources print-all-sources print-dylib-cflags print-dylib-ldflags
print-cflags:
	@echo $(SHARED_CFLAGS)
print-deb-sources:
	@echo $(PTSRC_ALL_DEB)
print-dylib-sources:
	@echo $(PTSRC_ALL_DYLIB)
print-prefs-sources:
	@echo $(PTSRC_ALL_PREFS)
print-uihared-sources:
	@echo $(PTSRC_UISHARED)
print-all-sources:
	@echo $(sort $(PTSRC_ALL_DEB) $(PTSRC_ALL_DYLIB) $(PTSRC_ALL_PREFS))
print-dylib-cflags:
	@echo $(DYLIB_CFLAGS)
print-dylib-ldflags:
	@echo $(DYLIB_LDFLAGS)
endif
