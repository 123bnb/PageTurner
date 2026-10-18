# PageTurner v1.0.57 —— 统一代码（roothide / deb + 巨魔 dylib 双形态，功能不变，删除注入探针）
# 架构：单一运行端引擎 common/PTEngine.m 被两个 target 共用：
#       · roothide deb（Tweak.m 薄壳，MSHookMessageEx 装 hook，设置页总开关+指定App生效）
#       · 巨魔 dylib（targets/dylib/，method_setImplementation 自 hook，应用内双指长按菜单）
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
PACKAGE_VERSION := 1.0.61

DEBUG = 0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PageTurner

PageTurner_FILES = Tweak.m \
	common/PTEngine.m \
	ptftouch/PTFakeMetaTouch.m ptftouch/UITouch-KIFAdditions.m \
	ptftouch/UIEvent+KIFAdditions.m ptftouch/IOHIDEvent+KIF.m
PageTurner_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-arc-performSelector-leaks -Wno-arc-retain-cycles -Icommon -Iptftouch -include ptftouch/Compat.h
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
