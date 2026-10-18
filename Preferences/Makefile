# PageTurner 设置页子工程（生成 PageTurner.bundle）
# v1.0.19：测试页需要 PTFakeMetaTouch（KIF 合成触摸注入），ptftouch 编入 bundle
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME := roothide
ARCHS = arm64 arm64e

include $(THEOS_MAKE_PATH)/common.mk

BUNDLE_NAME = PageTurner

PageTurner_FILES = RootListController.m \
	../common/PTOverlayPage.m \
	../ptftouch/PTFakeMetaTouch.m ../ptftouch/UITouch-KIFAdditions.m \
	../ptftouch/UIEvent+KIFAdditions.m ../ptftouch/IOHIDEvent+KIF.m
PageTurner_FRAMEWORKS = UIKit
PageTurner_PRIVATE_FRAMEWORKS = Preferences
PageTurner_INSTALL_PATH = /Library/PreferenceBundles
PageTurner_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-arc-retain-cycles -I../common -I../ptftouch -include ../ptftouch/Compat.h
PageTurner_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
