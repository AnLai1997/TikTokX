TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = TikTokXPrefs
TikTokXPrefs_FILES = TTXRootListController.m
TikTokXPrefs_FRAMEWORKS = UIKit
TikTokXPrefs_PRIVATE_FRAMEWORKS = Preferences
TikTokXPrefs_INSTALL_PATH = /Library/PreferenceBundles
TikTokXPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
