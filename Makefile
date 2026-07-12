ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FrontCamAsBack

FrontCamAsBack_FILES = Tweak.xm
FrontCamAsBack_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
