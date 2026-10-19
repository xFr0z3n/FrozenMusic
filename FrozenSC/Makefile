ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(ROOTHIDE),1)
THEOS_PACKAGE_SCHEME = roothide
endif

ARCHS = arm64
INSTALL_TARGET_PROCESSES = SoundCloud
TARGET = iphone:clang:16.5:13.0
PACKAGE_VERSION = 1.0.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FrozenSCDiscord
$(TWEAK_NAME)_FILES = $(shell find Source \( -name '*.x' -o -name '*.xm' -o -name '*.m' \))
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DTWEAK_VERSION=$(PACKAGE_VERSION)
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation MediaPlayer Security

include $(THEOS_MAKE_PATH)/tweak.mk
