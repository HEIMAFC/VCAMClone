ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAMClone VCAMCloneSB
VCAMClone_FILES = Tweak.xm
VCAMClone_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new
VCAMClone_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo CoreImage ImageIO VideoToolbox
VCAMClone_LIBRARIES = substrate
VCAMClone_PLIST = VCAMClone.plist

VCAMCloneSB_FILES = TweakSB.xm
VCAMCloneSB_CFLAGS = -fobjc-arc
VCAMCloneSB_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage
VCAMCloneSB_LIBRARIES = substrate
VCAMCloneSB_PLIST = VCAMCloneSB.plist

TOOL_NAME = vcamctl
vcamctl_FILES = vcamctl.m
vcamctl_CFLAGS = -fobjc-arc
vcamctl_FRAMEWORKS = Foundation
vcamctl_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "launchctl kickstart -k system/com.apple.mediaserverd || killall -9 mediaserverd; sbreload || killall -9 SpringBoard"
