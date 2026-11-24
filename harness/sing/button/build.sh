#!/bin/sh
# Builds the mic button harness for the simulator: SGRSingButton.m with the Kit's glass, and Sing's calls stood in
# for by sing-stubs.m.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../../tweak/Sources
APP=$HERE/build/SingButtonHarness.app
rm -rf "$APP"; mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 -isysroot "$SDK" -Wall -Wno-deprecated-declarations \
    -Wno-undeclared-selector -I"$SRC" "$HERE/main.m" "$HERE/sing-stubs.m" "$HERE/../../scene.m" \
    "$SRC"/Redesigned/Lyrics/SGRSingButton.m "$SRC"/Redesigned/Kit/SGRGlass.m "$SRC"/Redesigned/Kit/SGRTokens.m \
    "$SRC"/Core/SGGlass.m "$SRC"/Core/SGLegacyGlass.m "$SRC"/Core/SGGlassTouch.m "$SRC"/Core/SGUIMode.m "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation -framework Symbols -o "$APP/SingButtonHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SingButtonHarness</string>
<key>CFBundleIdentifier</key><string>com.vojta.singbuttonharness</string>
<key>CFBundleName</key><string>Sing button</string>
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
codesign -f -s - "$APP" >/dev/null 2>&1
echo "built $APP"
