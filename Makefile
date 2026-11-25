ARCHS = armv7 armv7s arm64
TARGET = iphone:clang:latest:8.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = CatInvoice
CatInvoice_FILES = main.m
CatInvoice_FRAMEWORKS = UIKit Foundation CoreBluetooth
CatInvoice_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
