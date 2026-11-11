# Mirage: a second tweak injected next to Vitrine (../tweak). It owns its own classes (MRG prefix),
# its own preference keys (mirage.) and its own row in the side drawer, so Vitrine's sources stay
# untouched and upstream merges stay clean. It also runs without Vitrine.
TARGET := iphone:clang:latest:16.0
ARCHS := arm64
FINALPACKAGE ?= 1

MRG_VERSION := $(or $(shell cat VERSION 2>/dev/null),0.1.0)
PACKAGE_VERSION := $(MRG_VERSION)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := Mirage
Mirage_FILES := $(shell find Sources -name '*.m' -o -name '*.x' | sort)
Mirage_CFLAGS := -fobjc-arc -ISources -DMRG_VERSION=\"$(MRG_VERSION)\" -Wno-deprecated-declarations
Mirage_FRAMEWORKS := UIKit QuartzCore AVFoundation CoreMedia CoreVideo CoreImage ImageIO PhotosUI UniformTypeIdentifiers MobileCoreServices
# Runtime swizzling (Logos' internal generator), like Vitrine: no Substrate/ElleKit dependency in the IPA.
Mirage_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
