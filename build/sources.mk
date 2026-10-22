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
#   PTSRC_CORE    common/PTEngineCore.m（引擎核心：配置/匹配/学习样本/测试回放/连滑/动作执行/日志） 三目标全要
#   PTSRC_ENGINE  common/PTEngine.m（引擎外壳：hook 装配/运行拦截/调试可视化）  deb + dylib
#   PTSRC_OVERLAY common/PTOverlayPage.m（点击/双击/滑动统一模板页）   dylib + Preferences
#   PTSRC_DEB     Tweak.m（deb 私有：MSHookMessageEx/ellekit 装配）   deb
#   PTSRC_DYLIB   targets/dylib/*.m（dylib 私有：入口/菜单/关于页）   dylib
#   PTSRC_PREFS   Preferences/RootListController.m（设置页）          Preferences
# 目标组合 = 组相并。v1.0.71 起 Preferences 也链 PTSRC_CORE（消除设置页 ~950 行重复实现），
# 但不链 PTSRC_ENGINE（外壳的 hook 装配是 deb/dylib 专属；设置页进程有自己的 hook）。
PTROOT ?= .

PTSRC_KIF := \
	ptftouch/PTFakeMetaTouch.m \
	ptftouch/UITouch-KIFAdditions.m \
	ptftouch/UIEvent+KIFAdditions.m \
	ptftouch/IOHIDEvent+KIF.m

PTSRC_CORE := common/PTEngineCore.m
PTSRC_ENGINE := common/PTEngine.m
PTSRC_OVERLAY := common/PTOverlayPage.m

PTSRC_DEB := Tweak.m
PTSRC_DYLIB := \
	targets/dylib/PTDylibMain.m \
	targets/dylib/PTDylibUI.m
PTSRC_PREFS := Preferences/RootListController.m

PTSRC_ALL_DEB := $(PTSRC_KIF) $(PTSRC_CORE) $(PTSRC_ENGINE) $(PTSRC_DEB)
PTSRC_ALL_DYLIB := $(PTSRC_KIF) $(PTSRC_CORE) $(PTSRC_ENGINE) $(PTSRC_OVERLAY) $(PTSRC_DYLIB)
PTSRC_ALL_PREFS := $(PTSRC_KIF) $(PTSRC_CORE) $(PTSRC_OVERLAY) $(PTSRC_PREFS)

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

ifeq ($(PRINT_CONFIG),1)
.PHONY: print-cflags print-deb-sources print-dylib-sources print-prefs-sources print-all-sources
print-cflags:
	@echo $(SHARED_CFLAGS)
print-deb-sources:
	@echo $(PTSRC_ALL_DEB)
print-dylib-sources:
	@echo $(PTSRC_ALL_DYLIB)
print-prefs-sources:
	@echo $(PTSRC_ALL_PREFS)
print-all-sources:
	@echo $(sort $(PTSRC_ALL_DEB) $(PTSRC_ALL_DYLIB) $(PTSRC_ALL_PREFS))
endif
