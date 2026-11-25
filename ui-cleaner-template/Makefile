THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.5:15.0
# Use pure arm64 so the exact same binary runs on BOTH:
# - iPhone 13 Pro (iOS 16.5 Rootless .deb)
# - iPhone 15 Pro Max (iOS 17.4.1 non-JIT user-signed .dylib)
ARCHS = arm64

# Use Logos 'internal' Objective-C runtime generator (zero CydiaSubstrate / zero JIT dependency!)
LOGOS_DEFAULT_GENERATOR = internal

THEOS_DEVICE_IP = 192.168.1.xxx
THEOS_DEVICE_PORT = 22

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UICleaner

UICleaner_FILES = Tweak.x
UICleaner_CFLAGS = -fobjc-arc
UICleaner_FRAMEWORKS = UIKit Foundation QuartzCore
UICleaner_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@mkdir -p ./dist
	@cp -f $(THEOS_OBJ_DIR)/UICleaner.dylib ./dist/UICleaner.dylib
	@$(THEOS)/toolchain/linux/iphone/bin/install_name_tool \
		-delete_rpath /var/jb/Library/Frameworks \
		-delete_rpath /var/jb/usr/lib \
		-delete_rpath @loader_path/.jbroot/Library/Frameworks \
		-delete_rpath @loader_path/.jbroot/usr/lib \
		./dist/UICleaner.dylib 2>/dev/null || true
	@$(THEOS)/toolchain/linux/iphone/bin/ldid -S ./dist/UICleaner.dylib
	@cp -f ./packages/*.deb ./dist/
	@echo "==> Dual-device artifacts exported to ./dist/ (clean jailed UICleaner.dylib for 15PM 17.4.1 + Rootless .deb for 13 Pro 16.5)"
