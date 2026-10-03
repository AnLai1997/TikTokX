TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = TikTok

# Bo comment dong duoi neu build cho jailbreak rootless (Dopamine, palera1n rootless...)
# THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TikTokX
TikTokX_FILES = Tweak.x
TikTokX_CFLAGS = -fobjc-arc
TikTokX_FRAMEWORKS = UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
