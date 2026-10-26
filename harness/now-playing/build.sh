#!/bin/sh
# Builds the now playing check for the Mac, as a Mac Catalyst tool: the two hooks of the now playing setter
# through Logos as the tweak builds them, Karaoke's timing, and main.m. Runs it with lock screen lyrics off
# and on.
set -e
# SRC may point at another checkout of tweak/Sources (an older commit, to see a bug before its fix).
SRC=${SRC:-$(cd "$(dirname "$0")/../../tweak/Sources" && pwd)}
OUT=${OUT:-$(dirname "$0")/build}
rm -rf "$OUT"; mkdir -p "$OUT/gen"

# In the tweak's order (its Makefile sorts the files), so the setter's hooks nest the same way.
for f in Shared/LockScreenLyrics/LockScreenLyrics.x Shared/Player/NowPlayingExtras.x; do
    "$THEOS/bin/logos.pl" -c generator=internal "$SRC/$f" > "$OUT/gen/$(basename "$f" .x).m"
done

# main.m first, so its constructor replaces the system's setter before the hooks wrap it.
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -target arm64-apple-ios18.0-macabi -isysroot "$SDK" -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -fobjc-arc -g -O0 -Wall -I"$SRC" -I"$SRC/Shared/LockScreenLyrics" \
    "$(dirname "$0")/main.m" "$OUT/gen/LockScreenLyrics.m" "$OUT/gen/NowPlayingExtras.m" \
    "$SRC/Shared/Lyrics/KaraokeTiming.m" "$SRC/Shared/Lyrics/Romanise.m" "$SRC/Shared/AdBlock/Protobuf.m" \
    -framework UIKit -framework MediaPlayer -o "$OUT/now-playing"

"$OUT/now-playing"
LSL=1 "$OUT/now-playing"
