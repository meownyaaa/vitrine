#!/bin/sh
# Builds the onboarding harness for the simulator: the welcome tour (Tour.m) and the What's new sheet
# (WhatsNew.m, with App/About/Update.m's parser). The sheet needs notes, so this writes CHANGELOG.md's
# section for VERSION into the generated header first, upstream's sections included; the tweak's next
# make writes its own version's back.
set -e
cd "$(dirname "$0")"
SRC=$(cd ../../tweak/Sources && pwd)
OUT=build
VERSION=${1:-0.20.0}
rm -rf "$OUT"; mkdir -p "$OUT/OnboardingHarness.app"
ALLOW_UPSTREAM=1 ../../scripts/whats-new.sh "$VERSION" ../../CHANGELOG.md "$SRC/App/Onboarding/SGWhatsNewNotes.h"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 \
    -I"$SRC" -isysroot "$SDK" -Wno-deprecated-declarations -DSG_VERSION="\"$VERSION\"" \
    main.m "$SRC"/App/Onboarding/Tour.m "$SRC"/App/Onboarding/WhatsNew.m "$SRC"/App/Onboarding/Environment.m \
    "$SRC"/App/About/Update.m \
    "$SRC"/Settings/SGPage.m "$SRC"/Settings/SGPageStyle.m \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGViewTree.m "$SRC"/Core/SGGlass.m "$SRC"/Core/SGLegacyGlass.m "$SRC"/Core/SGGlassTouch.m \
    "$SRC"/Core/SGBackdrop.m "$SRC"/Core/SGFlagForce.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework CoreImage -framework Foundation \
    -o "$OUT/OnboardingHarness.app/OnboardingHarness"

# A stand-in for EeveeSpotify's dylib, which the install check finds by its name alone.
echo 'void sg_stand_in(void) {}' | xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" \
    -x c - -dynamiclib -o "$OUT/OnboardingHarness.app/EeveeSpotify.dylib"

cat > "$OUT/OnboardingHarness.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OnboardingHarness</string>
<key>CFBundleIdentifier</key><string>com.vitrine.onboardingharness</string>
<key>CFBundleName</key><string>OnboardingHarness</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>UIUserInterfaceStyle</key><string>Dark</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><false/>
  <key>UISceneConfigurations</key><dict>
    <key>UIWindowSceneSessionRoleApplication</key><array><dict>
      <key>UISceneConfigurationName</key><string>Default</string>
      <key>UISceneDelegateClassName</key><string>Scene</string>
    </dict></array>
  </dict>
</dict>
</dict></plist>
PLIST
codesign -f -s - "$OUT/OnboardingHarness.app" >/dev/null 2>&1
echo "built $OUT/OnboardingHarness.app"
