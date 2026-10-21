# ============================================================
# 共享构建配置 —— 单一真源（v1.0.70）
# ============================================================
# 背景：此前「共享源文件列表」在两处手填 ——
#   · Makefile 的 PageTurner_FILES（deb / Theos）
#   · .github/workflows/build.yml 里的 SRCS（dylib / 裸 clang）
#   于是未来加一个 .m，只改一处的话，另一个 target 会**静默少编译一个文件**
#   （最坏情况不是链接报错，而是丢功能）。共享 CFLAGS 同理：此前两边已不一致
#   （dylib 少 -Wno-arc-retain-cycles，deb 缺 -I. 等）。
#
# 解法：抽到本文件，两个消费者都从这里读：
#   · Makefile : include build/sources.mk
#   · build.yml: make -s -f build/sources.mk PRINT_CONFIG=1 print-sources
#                make -s -f build/sources.mk PRINT_CONFIG=1 print-cflags
#   （PRINT_CONFIG=1 守卫保证 print-* 目标不污染主 Makefile 的 default goal）
#
# 原则：这里**只放两个 target 真正共用**的部分；各 target 私有文件仍在各自位置声明
#   · deb 私有  : Tweak.m（内含 MSHookMessageEx；dylib 侧无 substrate，不可共用）
#   · dylib 私有: common/PTOverlayPage.m + targets/dylib/{PTDylibMain,PTDylibUI}.m

SHARED_SOURCES := \
	common/PTEngine.m \
	ptftouch/PTFakeMetaTouch.m \
	ptftouch/UITouch-KIFAdditions.m \
	ptftouch/UIEvent+KIFAdditions.m \
	ptftouch/IOHIDEvent+KIF.m

SHARED_CFLAGS := \
	-fobjc-arc \
	-fobjc-abi-version=2 \
	-Wno-deprecated-declarations \
	-Wno-unused-variable \
	-Wno-unused-function \
	-Wno-arc-performSelector-leaks \
	-Wno-arc-retain-cycles \
	-I. \
	-Icommon \
	-Iptftouch \
	-include ptftouch/Compat.h

ifeq ($(PRINT_CONFIG),1)
.PHONY: print-sources print-cflags
print-sources:
	@echo $(SHARED_SOURCES)
print-cflags:
	@echo $(SHARED_CFLAGS)
endif
