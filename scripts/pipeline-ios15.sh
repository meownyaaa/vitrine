#!/usr/bin/env bash
# iOS 15 variant of pipeline.sh. A duplicate, the way pipeline-cyan.sh is, so edits for iOS 15 never
# touch the main pipeline. Four things differ, all of them about what iOS 15 does not have:
#
#   1. The tweak is built at deployment target 15.0 instead of 16.0. This is the one that matters.
#      AppIntents, ActivityKit, FoundationModels and Translation are autolinked by the Swift sources
#      that import them, and Swift decides weak-vs-hard per symbol from the deployment target: a
#      declaration available no earlier than the target is a HARD import. At 16.0, AppIntents (iOS 16.0)
#      came out hard while ActivityKit (16.1) came out weak, so dyld on iOS 15 halted the whole app
#      before a single instruction ran:
#        Library not loaded: '/System/Library/Frameworks/AppIntents.framework/AppIntents'
#        Referenced from: '.../Spotify.app/Frameworks/spotifyglass.dylib'
#      At 15.0 every one of those frameworks is newer than the target, so all four autolink weakly and
#      dyld skips the missing ones. Nothing in the sources needs changing: the AppIntents and
#      ActivityKit code is already behind @available(iOS 17.0, *) / iOS 26 gates.
#   2. ObjC unguarded-availability warnings are not errors here. The native look's floor is 16.1 and the
#      tweak builds with -Werror, so lowering the target without this fails the build on code that is
#      correct for the OS it runs the redesign on.
#   3. No Live Activity extension, and no Spotify PlugIns at all. SpotifyGlassLiveActivity.appex
#      hard-links ActivityKit and Live Activities do not exist below iOS 16.1 in any form, so the appex
#      crash-loops at launch; Spotify's own WidgetExtension wants WidgetKit and AppIntents. Both are
#      dropped rather than patched.
#   4. The App Group shim and the vendored audio library are built for iOS 15.0.
#
# This does NOT make Spotify itself run on iOS 15 - that is a separate patcher (the spotify-ios15
# project), which rewrites Spotify's own imports and ships its shim dylib, and is not vendored here.
# Run this first and that over the result; it patches every mach-o in the bundle, this tweak's included.
#
#   scripts/pipeline-ios15.sh <decrypted.ipa> [-o out.ipa] [--no-flex] [--install] [--name N] [--icon P.png] [--keep-watch]
#
# --keep-watch keeps Spotify's Apple Watch app, untested. Only its arm64 build is decrypted in an IPA dumped on an
# iPhone (the arm64_32 one older Watches run stays encrypted and is taken out), so it can only run on a Watch from
# Series 9 and Ultra 2 on. Its companion key names com.spotify.client until it is signed: the signer has to rename
# it and the Watch app's ids to the signing App ID, and sign the Watch app with a profile of its own that covers
# the Watch.
#
# Every icons/NAME.png becomes an alternate icon (icons/README.md).
#
# --install hands the result to install.sh (sign with your certificate, push to the plugged-in iPhone).
#
# The IPA is yours to supply: drop a decrypted Spotify .ipa in ipa/ and the Makefile finds it.
#
# Needs: Theos in $THEOS (default ~/theos), an iPhoneOS 26+ SDK from the selected Xcode or in $THEOS/sdks,
# gmake, ldid, dpkg-deb (brew) and cyan (uv tool install "cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
FLEX_DEB="$ROOT/vendor/com.hopeless.autoflex_0.0.1_iphoneos-arm.deb"
# The bundle id is left alone by default, the way EeveeSpotify and the YouTube mods leave it. Rewriting
# it only works when it ends up equal to the App ID of the profile that signs the IPA, and this build
# has no idea what that profile will be -- it is picked later, in Feather or whatever else the person
# signing uses. A mismatched pair still installs, but MediaRemote launches the now playing app by its
# application-identifier entitlement, so tapping the lock screen card asks for a bundle that does not
# exist and nothing opens. Set BUNDLE_ID only if you know it matches your App ID; scripts/install.sh
# reads that App ID out of the profile and can do it safely.
BUNDLE_ID="${BUNDLE_ID:-}"
# Overridable so a build can be pushed back up to 16.0 to compare against the main pipeline without
# editing this script.
SG_DEPLOYMENT="${SG_DEPLOYMENT:-15.0}"
mkdir -p "$ROOT/out"

IN="" OUT="" WITH_FLEX=1 INSTALL=0 NAME="" ICON="" KEEP_WATCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --no-flex) WITH_FLEX=0; shift ;;
    --install) INSTALL=1; shift ;;
    --keep-watch) KEEP_WATCH=1; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) IN="$1"; shift ;;
  esac
done
[ -n "$IN" ] || { echo "no IPA: put a decrypted Spotify .ipa in ipa/, or pass one (make build IPA=path.ipa)" >&2; exit 1; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1 -> $2" >&2; exit 1; }; }
need gmake "brew install make"
need ldid "brew install ldid"
need dpkg-deb "brew install dpkg"
need cyan "uv tool install 'cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw'"
{ ls -d "$THEOS"/sdks/iPhoneOS*.sdk "$(xcode-select -p 2>/dev/null)"/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null || true; } \
  | grep -qE 'iPhoneOS(2[6-9]|[3-9][0-9])\.' \
  || { echo "no iPhoneOS 26+ SDK: xcode-select an Xcode 26 or newer, or put the SDK in $THEOS/sdks" >&2; exit 1; }
# cyan skips -k with only a warning when its environment has no Pillow.
if [ -n "$ICON" ]; then
  [ -f "$ICON" ] || { echo "no such icon: $ICON" >&2; exit 1; }
  "$(dirname "$(readlink -f "$(command -v cyan)")")/python" -c 'import PIL' 2>/dev/null \
    || { echo "cyan has no Pillow for --icon -> uv tool install --force --with pillow 'cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw'" >&2; exit 1; }
fi

APP_DIR="$(unzip -Z1 "$IN" | grep -oE '^Payload/[^/]+\.app/' | sort -u | head -1)"
[ -n "$APP_DIR" ] || { echo "no Payload/*.app in $IN" >&2; exit 1; }
SPOTIFY_VERSION="$(unzip -p "$IN" "${APP_DIR}Info.plist" > "$ROOT/out/.info.plist" && plutil -extract CFBundleShortVersionString raw -o - "$ROOT/out/.info.plist")"
rm -f "$ROOT/out/.info.plist"
# The name carries the mod's version, not Spotify's: it is the one the About page shows and the one
# worth telling builds apart by. version.txt is read the way tweak/Makefile reads it, so a build from
# a fork left behind by a release is named for the version it really is.
MOD_VERSION="$(cat "$ROOT/version.txt" 2>/dev/null || true)"
: "${MOD_VERSION:=0.0.0}"
OUT="${OUT:-$ROOT/out/vitrine-ios15-$MOD_VERSION.ipa}"
echo "==> Vitrine $MOD_VERSION on Spotify $SPOTIFY_VERSION, for iOS $SG_DEPLOYMENT -> $OUT"

# The flag table is generated rather than committed, so it always matches the IPA being built: again whenever
# the Spotify it was read from (its first line) is not this one.
FLAG_LIST="$ROOT/tweak/Sources/Shared/Flags/SGFlagList.m"
if ! head -1 "$FLAG_LIST" 2>/dev/null | grep -qF "from Spotify $SPOTIFY_VERSION."; then
  echo "==> extracting the flag table for Spotify $SPOTIFY_VERSION (about 40 s)"
  "$ROOT/scripts/extract-flags.py" "$IN"
fi

echo "==> building tweak"
export THEOS
# Theos resolves its toolchain through `xcrun -sdk iphoneos`, which needs full Xcode. With only the
# Command Line Tools installed, name the tools directly instead.
if ! xcrun -sdk iphoneos --find clang >/dev/null 2>&1; then
  export TARGET_CC=clang TARGET_CXX=clang++ TARGET_LD=clang++ \
         TARGET_STRIP=strip TARGET_LIPO=lipo TARGET_CODESIGN_ALLOCATE=codesign_allocate TARGET_LIBTOOL=libtool
fi
# Theos builds its Swift support tools only at MAKELEVEL 0, and `make release` hands this script MAKELEVEL 1.
# A build with FLEX carries the phone driver too (tweak/Makefile, SG_DRIVER); --no-flex leaves it out.
# The audio library first, on its own, because TARGET means two different things in the two makefiles
# and a command-line assignment reaches both: Theos wants iphone:clang:latest:<version>, while
# vendor/audio/Makefile wants a clang triple, and handing it Theos's spelling fails with
# "unknown target triple 'iphone:clang:latest:15.0'". Building it here leaves the nested sg-audio
# sub-make with nothing to compile, so the value it gets is never used. The ios objects are removed
# first so they are not reused from a 16.0 build; the main pipeline rebuilds them the same way.
rm -rf "$ROOT/vendor/audio/build/ios"
env -u MAKELEVEL gmake -C "$ROOT/vendor/audio" PLATFORM=ios TARGET="arm64-apple-ios$SG_DEPLOYMENT" >/dev/null

# TARGET is a plain := in tweak/Makefile, so a command-line assignment wins over it; CFLAGS must go
# through Theos's ADDITIONAL_CFLAGS, because overriding spotifyglass_CFLAGS would drop -fobjc-arc.
env -u MAKELEVEL gmake -C "$ROOT/tweak" clean package SG_DRIVER="$WITH_FLEX" \
  TARGET="iphone:clang:latest:$SG_DEPLOYMENT" \
  ADDITIONAL_CFLAGS="-Wno-unguarded-availability -Wno-unguarded-availability-new" >/dev/null
TWEAK_DEB="$(ls -t "$ROOT"/tweak/packages/*.deb | head -1)"
echo "    $TWEAK_DEB"

FILES=("$TWEAK_DEB")
[ "$WITH_FLEX" = 1 ] && FILES+=("$FLEX_DEB")

# No Live Activity extension: it hard-links ActivityKit, which iOS 15 does not have, so the appex is
# killed by dyld at launch and relaunched for as long as the app asks for it. Leaving EXT_DIR unset also
# skips the App Intents metadata merge at the end.
echo "==> iOS 15: building without the Live Activity extension (ActivityKit does not exist)"

# Spotify's widget reads what the app writes through App Group suites the re-signed IPA is not entitled
# to; this dylib, loaded by the app and by the widget, puts both on a group the signature does have.
echo "==> building the App Group shim"
GROUPS_DYLIB="$ROOT/out/SpotifyGlassAppGroups.dylib"
xcrun --sdk iphoneos clang -target arm64-apple-ios$SG_DEPLOYMENT -dynamiclib -fobjc-arc -Os -framework Foundation -framework Security \
  -install_name @rpath/SpotifyGlassAppGroups.dylib -o "$GROUPS_DYLIB" "$ROOT/extension/AppGroups/AppGroups.m"
FILES+=("$GROUPS_DYLIB")

# A key in plist/ replaces Spotify's own of that name, so the Bonjour services Connect discovery
# (Shared/Connect) browses go in after the ones Spotify lists, and Spotify's own local network wording
# is kept where it has one.
OVERLAY="$ROOT/out/.overlay.plist"
unzip -p "$IN" "${APP_DIR}Info.plist" > "$ROOT/out/.info.plist"
python3 - "$ROOT/plist/liquid-glass.plist" "$ROOT/out/.info.plist" "$OVERLAY" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: overlay = plistlib.load(f)
with open(sys.argv[2], 'rb') as f: app = plistlib.load(f)
services = list(app.get('NSBonjourServices', []))
services += [s for s in overlay.get('NSBonjourServices', []) if s not in services]
overlay['NSBonjourServices'] = services
if app.get('NSLocalNetworkUsageDescription'): overlay.pop('NSLocalNetworkUsageDescription', None)
with open(sys.argv[3], 'wb') as f: plistlib.dump(overlay, f)
PY
rm -f "$ROOT/out/.info.plist"

echo "==> injecting"
# -w drops the Watch app: its companion-app key would still name com.spotify.client and block the install.
WATCH=(-w)
[ -n "$KEEP_WATCH" ] && WATCH=()
cyan -i "$IN" -o "$OUT" -f "${FILES[@]}" -l "$OVERLAY" ${BUNDLE_ID:+-b "$BUNDLE_ID"} ${NAME:+-n "$NAME"} ${ICON:+-k "$ICON"} ${WATCH[@]+"${WATCH[@]}"} -s -u --overwrite
rm -f "$OVERLAY"

if [ -n "$KEEP_WATCH" ]; then
  echo "==> keeping the Watch app, its arm64 build only (untested)"
  PATCH="$(mktemp -d)"
  OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
  (cd "$PATCH" && unzip -q "$OUT_ABS" "${APP_DIR}Watch/*")
  # The arm64_32 build is still encrypted with the App Store's DRM and could never run; the DRM records go too.
  find "$PATCH/${APP_DIR}Watch" -type f -perm -u+x | while read -r bin; do
    if lipo -archs "$bin" 2>/dev/null | grep -qw arm64_32; then lipo -remove arm64_32 "$bin" -output "$bin"; fi
  done
  find "$PATCH/${APP_DIR}Watch" -type d -name SC_Info -prune -exec rm -rf {} +
  zip -q -d "$OUT_ABS" "${APP_DIR}Watch/*" >/dev/null
  (cd "$PATCH" && zip -q -r "$OUT_ABS" "${APP_DIR}Watch")
  rm -rf "$PATCH"
fi
# Every app extension goes, rather than the App Group shim going into Spotify's widget. The widget
# wants WidgetKit and AppIntents, which iOS 15 has neither of, and an extension dyld refuses is
# relaunched on a loop. The spotify-ios15 patcher drops PlugIns/ for the same reason.
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
if unzip -Z1 "$OUT_ABS" | grep -q "^${APP_DIR}PlugIns/"; then
  echo "==> iOS 15: dropping app extensions (no WidgetKit, no AppIntents, no ActivityKit)"
  unzip -Z1 "$OUT_ABS" | grep "^${APP_DIR}PlugIns/" | sed 's|^|   |'
  zip -q -d "$OUT_ABS" "${APP_DIR}PlugIns/*" >/dev/null
else
  echo "    no PlugIns in this IPA"
fi

shopt -s nullglob
ICONS=("$ROOT"/icons/*.png)
shopt -u nullglob
if [ ${#ICONS[@]} -gt 0 ]; then
  echo "==> adding ${#ICONS[@]} alternate icons from icons/"
  PATCH="$(mktemp -d)"
  unzip -q "$OUT" "${APP_DIR}Info.plist" -d "$PATCH"
  PLIST="$PATCH/${APP_DIR}Info.plist"
  for png in "${ICONS[@]}"; do
    name="$(basename "$png" .png)"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "icon names are letters, digits, _ and - only: $png" >&2; exit 1; }
    sips -s format png -z 120 120 "$png" --out "$PATCH/$APP_DIR$name@2x.png" >/dev/null
    sips -s format png -z 180 180 "$png" --out "$PATCH/$APP_DIR$name@3x.png" >/dev/null
    sips -s format png -z 152 152 "$png" --out "$PATCH/$APP_DIR$name@2x~ipad.png" >/dev/null
    for key in CFBundleIcons 'CFBundleIcons~ipad'; do
      /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 || continue
      /usr/libexec/PlistBuddy -c "Add :$key:CFBundleAlternateIcons dict" "$PLIST" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Delete :$key:CFBundleAlternateIcons:$name" "$PLIST" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :$key:CFBundleAlternateIcons:$name:CFBundleIconFiles array" \
        -c "Add :$key:CFBundleAlternateIcons:$name:CFBundleIconFiles:0 string $name" "$PLIST"
    done
  done
  OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
  (cd "$PATCH" && zip -q -r "$OUT_ABS" "$APP_DIR")
  rm -rf "$PATCH"
fi

if [ -n "${EXT_DIR:-}" ]; then
  echo "==> adding the Live Activity intents to Spotify's App Intents metadata"
  "$ROOT/scripts/merge-appintents.py" "$OUT" "$APP_DIR" "$EXT_DIR/app/Metadata.appintents"
fi

echo "==> done: $OUT"
[ "$INSTALL" = 1 ] && exec "$ROOT/scripts/install.sh" "$OUT"
exit 0
