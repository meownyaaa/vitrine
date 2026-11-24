#!/bin/sh
# build.sh: builds check.m against this checkout's LocalFiles.m as a Mac Catalyst binary and runs it with
# a home of its own under build/, so its defaults and its covers never reach the Mac's.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$HERE/build/home"
xcrun -sdk macosx clang -target arm64-apple-ios17.0-macabi -isysroot "$SDK" -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -fobjc-arc -g -Wall -Werror -I"$SRC" "$HERE/check.m" "$SRC/Shared/LocalFiles/LocalFiles.m" \
    -framework UIKit -framework CoreGraphics -framework Foundation -o "$HERE/build/check"
CFFIXED_USER_HOME="$HERE/build/home" "$HERE/build/check"
# The imported LRC files, with the lyrics engine's line timing as the tweak has it.
xcrun -sdk macosx clang -target arm64-apple-ios17.0-macabi -isysroot "$SDK" -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -fobjc-arc -g -Wall -Werror -I"$SRC" "$HERE/lrc.m" "$SRC/Shared/LocalFiles/LocalLyrics.m" "$SRC/Shared/LocalFiles/LocalFiles.m" \
    "$SRC/Shared/Lyrics/KaraokeTiming.m" "$SRC/Shared/Lyrics/KaraokeBody.m" "$SRC/Shared/AdBlock/Protobuf.m" \
    -framework UIKit -framework CoreGraphics -framework Foundation -o "$HERE/build/lrc"
CFFIXED_USER_HOME="$HERE/build/home" "$HERE/build/lrc"
