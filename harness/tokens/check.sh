#!/bin/sh
# Builds and runs the SGRTokens check for the Mac (Mac Catalyst, for UIKit), the way harness/palette builds.
set -eu
cd "$(dirname "$0")"
SRC=../../tweak/Sources
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build
xcrun clang -fobjc-arc -O0 -g -Wall -Wextra -Werror -Wno-unused-parameter -target arm64-apple-ios17.0-macabi -isysroot "$SDK" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" -isystem "$SDK/System/iOSSupport/usr/include" \
    -I"$SRC" check.m "$SRC"/Redesigned/Kit/SGRTokens.m "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m \
    -framework UIKit -framework CoreGraphics -framework QuartzCore -o build/check
build/check
