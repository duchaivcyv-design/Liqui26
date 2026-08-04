FINALPACKAGE = 1
export TARGET = iphone:clang
export ARCHS = arm64
export ADDITIONAL_CFLAGS = -DTHEOS_LEAN_AND_MEAN -fobjc-arc

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidMorph

LiquidMorph_FILES = Tweak.xm
LiquidMorph_FRAMEWORKS = UIKit Foundation CoreMotion QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
