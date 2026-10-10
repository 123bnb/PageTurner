# PageTurner 设置页子工程（生成 PageTurner.bundle）
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME := roothide
ARCHS = arm64 arm64e

include $(THEOS_MAKE_PATH)/common.mk

BUNDLE_NAME = PageTurner

PageTurner_FILES = RootListController.m
PageTurner_FRAMEWORKS = UIKit
PageTurner_PRIVATE_FRAMEWORKS = Preferences
PageTurner_INSTALL_PATH = /Library/PreferenceBundles
PageTurner_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks
PageTurner_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
