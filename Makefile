# PageTurner v1.0.22 —— 翻页器按键拦截正式版（学习模式 + 映射 + 动作执行）
# 架构：注入所有进程（roothide 黑名单默认）→ Preferences 进程收集学习样本 → 生效 App 拦截执行
# 事件：hook UIApplication -sendEvent:（UIEvent 层，UITouch 真实坐标）
#       + _UIUpdateHIDDigitizerInput -addEvent:（IOHIDEvent 层，sender 判来源/学习）
# 动作：PTFakeMetaTouch（点击/双击/滑动）+ AVSystemController（静音/音量±）
# UI：全部在系统设置 → PageTurner 设置页（Preferences bundle），App 内零 UI
# 日志：App 容器 Documents/PageTurner.log + /var/mobile/Documents/PageTurner.log
#
# v1.0.22 关键修复：删除 -Wl,-undefined,dynamic_lookup！
#   该 flag 会把 MSHookMessageEx 变成"运行时动态查找"符号，不写入 dylib import 表，
#   ellekit/roothide 扫描不到 _MSHookMessageEx → 拒载 dylib → 目标 App 根本没被注入
#   （实测对比：TrollCM.dylib 含 _MSHookMessageEx×4，PageTurner×0）。
#   删除后 MSHookMessageEx 正常 import libsubstrate；ptftouch 的 IOHIDEvent* C 函数
#   补 -framework IOKit 链接。
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME := roothide
PACKAGE_VERSION := 1.0.22

DEBUG = 0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PageTurner

PageTurner_FILES = Tweak.xm \
	ptftouch/PTFakeMetaTouch.m ptftouch/UITouch-KIFAdditions.m \
	ptftouch/UIEvent+KIFAdditions.m ptftouch/IOHIDEvent+KIF.m
PageTurner_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-arc-performSelector-leaks -Wno-arc-retain-cycles -Iptftouch -include ptftouch/Compat.h
PageTurner_FRAMEWORKS = Foundation UIKit IOKit
PageTurner_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 设置页 ----------
SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/aggregate.mk

# ---------- 注入所有 App（无 Filter 限制，运行时检查 bundleID）----------
before-package::
	printf '{}' > "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/PageTurner.plist"
	mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	cp -f "layout/Library/PreferenceLoader/Preferences/PageTurner.plist" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"
