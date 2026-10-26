#!/bin/sh
# Builds the AirPods gestures simulator harness: HeadGestures.x through Logos, its page, the detector and
# the Settings/ framework as they are in the tweak, main.m standing in for Spotify and the headphones.
set -e
SRC=$(cd "$(dirname "$0")/../../../tweak/Sources" && pwd)
OUT=$(dirname "$0")/../build/sim   # under the gitignored build/ beside the Mac harness
rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/HeadGesturesSim.app"
"$THEOS/bin/logos.pl" -c generator=internal "$SRC/Shared/HeadGestures/HeadGestures.x" > "$OUT/gen/HeadGestures.m"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 \
    -I"$SRC" -I"$SRC/Shared/HeadGestures" -isysroot "$SDK" -Wall -Werror -Wno-deprecated-declarations \
    "$(dirname "$0")/main.m" "$(dirname "$0")/../../scene.m" "$OUT/gen/HeadGestures.m" \
    "$SRC"/Shared/HeadGestures/HeadGesturesSettings.m "$SRC"/Shared/HeadGestures/HeadGesturesTeach.m \
    "$SRC"/Shared/HeadGestures/SGHeadDetector.m \
    "$SRC"/Settings/SGPage.m "$SRC"/Settings/SGPageStyle.m "$SRC"/Settings/SGModPage.m "$SRC"/Settings/SGGlowSwitch.m \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGViewTree.m "$SRC"/Core/SGGlass.m "$SRC"/Core/SGFlagForce.m "$SRC"/Core/SGUIMode.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation -framework CoreMotion -framework AudioToolbox -framework AVFoundation \
    -o "$OUT/HeadGesturesSim.app/HeadGesturesSim"

cat > "$OUT/HeadGesturesSim.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HeadGesturesSim</string>
<key>CFBundleIdentifier</key><string>com.vitrine.headgesturessim</string>
<key>CFBundleName</key><string>HeadGesturesSim</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>UIUserInterfaceStyle</key><string>Dark</string>
<key>UILaunchScreen</key><dict/>
<key>NSMotionUsageDescription</key><string>The harness reads made-up head motion.</string>
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
echo "built $OUT/HeadGesturesSim.app"
