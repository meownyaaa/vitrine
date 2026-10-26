#!/bin/sh
# Builds the listening stats page harness for the simulator: Shared/ListeningStats as it is in the tweak (its .x
# through Logos), the Settings/ framework, stubs.m for the player.
set -e
SRC=$(cd "$(dirname "$0")/../../tweak/Sources" && pwd)
OUT=$(dirname "$0")/build/sim
rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/ListeningStatsHarness.app"
"$THEOS/bin/logos.pl" -c generator=internal "$SRC/Shared/ListeningStats/ListeningStats.x" > "$OUT/gen/ListeningStats.m"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 \
    -I"$SRC" -I"$SRC/Shared/ListeningStats" -isysroot "$SDK" -Wall -Werror -Wno-deprecated-declarations \
    "$(dirname "$0")/sim/main.m" "$(dirname "$0")/sim/stubs.m" "$(dirname "$0")/../scene.m" "$OUT/gen/ListeningStats.m" \
    "$SRC"/Shared/ListeningStats/ListeningStatsPage.m "$SRC"/Shared/ListeningStats/SGPlayLog.m \
    "$SRC"/Settings/SGPage.m "$SRC"/Settings/SGPageStyle.m "$SRC"/Settings/SGModPage.m "$SRC"/Settings/SGGlowSwitch.m \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGViewTree.m "$SRC"/Core/SGGlass.m "$SRC"/Core/SGFlagForce.m "$SRC"/Core/SGUIMode.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation -framework UniformTypeIdentifiers \
    -o "$OUT/ListeningStatsHarness.app/ListeningStatsHarness"

cat > "$OUT/ListeningStatsHarness.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ListeningStatsHarness</string>
<key>CFBundleIdentifier</key><string>com.vitrine.listeningstatsharness</string>
<key>CFBundleName</key><string>ListeningStatsHarness</string>
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
echo "built $OUT/ListeningStatsHarness.app"
