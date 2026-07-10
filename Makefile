ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = FrontCamAsBack

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FrontCamAsBack

FrontCamAsBack_FILES = Tweak.xm
FrontCamAsBack_CFLAGS = -fobjc-arc -std=c++17
FrontCamAsBack_FRAMEWORKS = AVFoundation CoreMedia CoreVideo UIKit Accelerate
FrontCamAsBack_PRIVATE_FRAMEWORKS = MediaToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
