#!/bin/sh
# build.sh: builds check.m against this checkout's SpicyLyrics.m as a Mac Catalyst binary and runs it,
# so no simulator is needed.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
mkdir -p "$HERE/build"
xcrun -sdk macosx clang -target arm64-apple-ios17.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -iframework "$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks" -fobjc-arc -g -Wall -I"$SRC" \
    "$HERE/check.m" "$SRC/Shared/LyricsSources/SpicyLyrics.m" "$SRC/Shared/LyricsSources/SGTTML.m" "$SRC/Shared/Lyrics/KaraokeTiming.m" "$SRC/Shared/Lyrics/KaraokeBody.m" "$SRC/Shared/AdBlock/Protobuf.m" \
    -framework UIKit -framework Security -framework Foundation -o "$HERE/build/check"
"$HERE/build/check"
