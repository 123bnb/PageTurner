# PageTurner 设置页子工程（生成 PageTurner.bundle）
# v1.0.19：测试页需要 PTFakeMetaTouch（KIF 合成触摸注入），ptftouch 编入 bundle
# v1.0.71：源文件列表与编译 flags 统一改从仓库根的 build/sources.mk 读取
#          （三目标单一真源）——此前这里是第三处手抄，且已漂移：
#          缺 -fobjc-abi-version=2、缺仓库根 -I，与 deb / dylib 的 flags 不一致。
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME := roothide
ARCHS = arm64 arm64e

# 本 Makefile 由 Theos 在 Preferences/ 子目录里执行（make -C 进来），
# PTROOT=.. 让 sources.mk 的根相对路径与 -I 前缀正确指向仓库根。
PTROOT := ..
include $(PTROOT)/build/sources.mk

include $(THEOS_MAKE_PATH)/common.mk

BUNDLE_NAME = PageTurner

# v1.0.71：列表来自 sources.mk 的 PTSRC_ALL_PREFS（KIF + 引擎核心 PTEngineCore +
#          统一模板 PTOverlayPage + 设置页本体 RootListController）。
#          deb 私有的 Tweak.m / 引擎外壳 PTEngine.m 均不进这里（外壳的 hook 装配是
#          deb/dylib 专属；设置页进程用自己的 SImpAddEvent/SImpSendEvent）。
# v1.0.77：设置页 UI 全量统一，列表再并上 PTSRC_UISHARED（共享设置页 9 个 VC + 基础设施）
#          与本目录私有 PTShimVC.m（PSViewController 桥接壳）/ PTLogSourceDeb.m（日志源）。
PageTurner_FILES = $(addprefix $(PTROOT)/,$(PTSRC_ALL_PREFS))
PageTurner_FRAMEWORKS = UIKit
PageTurner_PRIVATE_FRAMEWORKS = Preferences
PageTurner_INSTALL_PATH = /Library/PreferenceBundles
PageTurner_CFLAGS = $(SHARED_CFLAGS)
PageTurner_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
