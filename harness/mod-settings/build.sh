#!/bin/sh
# Builds the Mod Settings harness for the simulator: App/ModSettings.x run through Logos, App/Pages.m and the
# Settings/ framework as they are in the tweak, stubs.m for every page a row opens.
set -e
SRC=$(cd "$(dirname "$0")/../../tweak/Sources" && pwd)
OUT=$(dirname "$0")/build
rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/ModSettingsHarness.app"
"$THEOS/bin/logos.pl" -c generator=internal "$SRC/App/ModSettings.x" > "$OUT/gen/ModSettings.m"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 \
    -I"$SRC" -I"$SRC/App" -isysroot "$SDK" -Wall -Werror -Wno-deprecated-declarations -DSG_VERSION=\"1.0.0-harness\" \
    "$(dirname "$0")/main.m" "$(dirname "$0")/../scene.m" "$(dirname "$0")/stubs.m" \
    "$OUT"/gen/ModSettings.m "$SRC"/App/Pages.m "$SRC"/App/About/Signing.m "$SRC"/Shared/AnimatedArtwork/AnimatedArtworkSettings.m \
    "$SRC"/Settings/SGPage.m "$SRC"/Settings/SGPageStyle.m "$SRC"/Settings/SGModPage.m "$SRC"/Settings/SGGlowSwitch.m \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGViewTree.m "$SRC"/Core/SGGlass.m "$SRC"/Core/SGFlagForce.m "$SRC"/Core/SGUIMode.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation \
    -o "$OUT/ModSettingsHarness.app/ModSettingsHarness"

cat > "$OUT/ModSettingsHarness.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ModSettingsHarness</string>
<key>CFBundleIdentifier</key><string>com.vitrine.modsettingsharness</string>
<key>CFBundleName</key><string>ModSettingsHarness</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>UIUserInterfaceStyle</key><string>Dark</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><false/>
  <key>UISceneConfigurations</key><dict>
    <key>UIWindowSceneSessionRoleApplication</key><array><dict>
      <key>UISceneConfigurationName</key><string>Default</string>
      <key>UISceneDelegateClassName</key><string>SGRHarnessScene</string>
    </dict></array>
  </dict>
</dict>
</dict></plist>
PLIST
echo "built $OUT/ModSettingsHarness.app"
