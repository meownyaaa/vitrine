#!/usr/bin/env bash
# Mirage: builds Vitrine (tweak/) and Mirage (mirage/) from source and injects both into a decrypted
# Spotify IPA, unsigned/fakesigned, ready for Ksign (or SideStore). Works on Linux and macOS.
#
#   scripts/mirage-build.sh <decrypted Spotify.ipa> [-o out.ipa] [--no-vitrine] [--no-icons]
#
# Differences from scripts/pipeline.sh (Vitrine's macOS pipeline, still usable on a Mac):
#   - no FLEX, no install step;
#   - the Live Activity widget extension needs Xcode (swiftc for iOS + appintentsmetadataprocessor),
#     so it is only built when `xcrun --sdk iphoneos --find swiftc` works (macOS / the GitHub workflow);
#   - plist, zip and icon work is done in Python, so neither PlistBuddy, sips nor zip is needed.
#
# Needs: THEOS (default ~/theos) with an iPhoneOS 26+ SDK in $THEOS/sdks, gmake, ldid, dpkg-deb, python3
# (Pillow for the alternate icons) and cyan (uv tool install 'cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw').
# Linux setup: docs/mirage/BUILDING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export THEOS="${THEOS:-$HOME/theos}"
IN="" OUT="" WITH_VITRINE=1 WITH_ICONS=1
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    --no-vitrine) WITH_VITRINE=0; shift ;;
    --no-icons) WITH_ICONS=0; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) IN="$1"; shift ;;
  esac
done
[ -f "$IN" ] || { echo "usage: $0 <decrypted Spotify.ipa> [-o out.ipa]" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need gmake; need ldid; need dpkg-deb; need cyan; need python3

mkdir -p "$ROOT/out"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Version and decryption checks, from the IPA itself.
read -r APP_DIR SPOTIFY_VERSION <<<"$(python3 "$ROOT/scripts/mirage-ipa.py" info "$IN")"
MRG_VERSION="$(cat "$ROOT/mirage/VERSION")"
OUT="${OUT:-$ROOT/out/Mirage-$SPOTIFY_VERSION.ipa}"
echo "==> Mirage $MRG_VERSION + Vitrine $(cat "$ROOT/version.txt") on Spotify $SPOTIFY_VERSION -> $OUT"
grep -q "\"$SPOTIFY_VERSION\"" "$ROOT/tweak/Sources/App/Onboarding/Onboarding.h" \
  || echo "    warning: Vitrine does not list Spotify $SPOTIFY_VERSION as supported (tweak/Sources/App/Onboarding/Onboarding.h)"

FILES=()
if [ "$WITH_VITRINE" = 1 ]; then
  FLAG_LIST="$ROOT/tweak/Sources/Shared/Flags/SGFlagList.m"
  if ! head -1 "$FLAG_LIST" 2>/dev/null | grep -qF "from Spotify $SPOTIFY_VERSION."; then
    echo "==> extracting the flag table for Spotify $SPOTIFY_VERSION"
    "$ROOT/scripts/extract-flags.py" "$IN"
  fi
  echo "==> building Vitrine"
  # OS_LOG_FORMAT_WARNINGS: swift.org clang flags a format literal inside os_log() that Apple clang accepts,
  # and the SDK turns that warning into an error; this keeps it a (silenced) warning.
  env -u MAKELEVEL gmake -C "$ROOT/tweak" clean package SG_DRIVER=0 ADDITIONAL_CFLAGS="-DOS_LOG_FORMAT_WARNINGS=1 -Wno-format-security" >"$WORK/vitrine.log" 2>&1 \
    || { tail -40 "$WORK/vitrine.log"; exit 1; }
  FILES+=("$(ls -t "$ROOT"/tweak/packages/*.deb | head -1)")

  echo "==> building the App Group shim"
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -dynamiclib -fobjc-arc -Os -framework Foundation -framework Security \
    -install_name @rpath/SpotifyGlassAppGroups.dylib -o "$WORK/SpotifyGlassAppGroups.dylib" "$ROOT/extension/AppGroups/AppGroups.m"
  ldid -S "$WORK/SpotifyGlassAppGroups.dylib"
  FILES+=("$WORK/SpotifyGlassAppGroups.dylib")

  if xcrun --sdk iphoneos --find swiftc >/dev/null 2>&1; then
    python3 "$ROOT/scripts/mirage-ipa.py" extract-plist "$IN" "$WORK/host.plist"
    "$ROOT/scripts/build-extension.sh" "$WORK/host.plist" "$WORK/extension"
    FILES+=("$WORK/extension/SpotifyGlassLiveActivity.appex")
  else
    echo "==> no Xcode: building without Vitrine's Live Activity widget (the GitHub workflow builds it)"
  fi
fi

echo "==> building Mirage"
env -u MAKELEVEL gmake -C "$ROOT/mirage" clean package >"$WORK/mirage.log" 2>&1 || { tail -40 "$WORK/mirage.log"; exit 1; }
MIRAGE_DEB="$(ls -t "$ROOT"/mirage/packages/*.deb | head -1)"
FILES+=("$MIRAGE_DEB")
cp "$MIRAGE_DEB" "$ROOT/out/"
cp "$ROOT/mirage/.theos/obj/Mirage.dylib" "$ROOT/out/Mirage.dylib"

python3 "$ROOT/scripts/mirage-ipa.py" overlay "$IN" "$ROOT/plist/liquid-glass.plist" "$WORK/overlay.plist"

echo "==> injecting ${#FILES[@]} items with cyan"
cyan -i "$IN" -o "$OUT" -f "${FILES[@]}" -l "$WORK/overlay.plist" -w -s -u --overwrite

if [ "$WITH_VITRINE" = 1 ]; then
  echo "==> loading the App Group shim in the extensions, alternate icons"
  ICON_ARG=(); [ "$WITH_ICONS" = 1 ] && ICON_ARG=(--icons "$ROOT/icons")
  python3 "$ROOT/scripts/mirage-ipa.py" finish "$OUT" "$APP_DIR" "$ROOT/scripts/insert-dylib.py" "${ICON_ARG[@]}"
  if [ -d "$WORK/extension/app/Metadata.appintents" ]; then
    "$ROOT/scripts/merge-appintents.py" "$OUT" "$APP_DIR" "$WORK/extension/app/Metadata.appintents"
  fi
fi

python3 "$ROOT/scripts/mirage-ipa.py" verify "$OUT"
echo "==> done: $OUT"
