TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = TikTokXPrefs

TikTokXPrefs_FILES = TTXRootListController.m
TikTokXPrefs_FRAMEWORKS = UIKit
TikTokXPrefs_PRIVATE_FRAMEWORKS = Preferences
TikTokXPrefs_INSTALL_PATH = /Library/PreferenceBundles
# Version shown in the footer card, read from ../control.
TikTokXPrefs_CFLAGS = -fobjc-arc -DTWEAK_VERSION=\"$(shell sed -n 's/^Version: *//p' ../control | tr -d '\r')\"

include $(THEOS_MAKE_PATH)/bundle.mk
