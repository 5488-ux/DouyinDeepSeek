ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DouyinDeepSeek

DouyinDeepSeek_FILES = Tweak.xm \
	Sources/DSConfig.m \
	Sources/DSDeepSeekClient.m \
	Sources/DSRuntimeBridge.m \
	Sources/DSConversationPickerViewController.m \
	Sources/DSSettingsViewController.m
DouyinDeepSeek_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
DouyinDeepSeek_CCFLAGS = -std=c++17
DouyinDeepSeek_FRAMEWORKS = UIKit Foundation Security
DouyinDeepSeek_LIBRARIES = substrate

INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS_MAKE_PATH)/tweak.mk

