# PageTurner v1.0.0 —— 翻页器按键拦截正式版（学习模式 + 映射 + 动作执行）
# 架构：注入所有 App（roothide 黑名单默认）→ 运行时检查 bundleID+总开关 → 旁路
# 事件：hook UIApplication -sendEvent:（UIEvent 层，UITouch 真实坐标）
#       + _UIUpdateHIDDigitizerInput -addEvent:（IOHIDEvent 层，sender 判来源）
# 动作：PTFakeMetaTouch（点击/双击/滑动）+ AVSystemController（静音/音量±）
# 日志：App 容器 Documents/PageTurner.log + /var/mobile/Documents/PageTurner.log
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME := roothide
PACKAGE_VERSION := 1.0.0

DEBUG = 0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PageTurner

PageTurner_FILES = Tweak.xm OverlayUI.m \
	ptftouch/PTFakeMetaTouch.m ptftouch/UITouch-KIFAdditions.m \
	ptftouch/UIEvent+KIFAdditions.m ptftouch/IOHIDEvent+KIF.m
PageTurner_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-arc-performSelector-leaks -Iptftouch -include ptftouch/Compat.h
PageTurner_LDFLAGS = -Wl,-undefined,dynamic_lookup
PageTurner_FRAMEWORKS = Foundation UIKit
PageTurner_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 设置页 ----------
SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/aggregate.mk

# ---------- 注入所有 App（无 Filter 限制，运行时检查 bundleID）----------
before-package::
	printf '{}' > "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/PageTurner.plist"
