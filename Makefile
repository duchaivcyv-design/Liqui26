TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidMorph
LiquidMorph_FILES = Tweak.xm
LiquidMorph_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk
