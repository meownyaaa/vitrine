#!/bin/sh
set -e
# The sources of the checkout this harness sits in, unless SRC names others.
SRC=${SRC:-$(cd "$(dirname "$0")/../../tweak/Sources" && pwd)}
OUT=$(dirname "$0")/build
rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/AddTabHarness.app"
"$THEOS/bin/logos.pl" -c generator=internal "$SRC/Shared/Navigation/Links.x" > "$OUT/gen/Links.m"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 \
    -I"$SRC" -I"$SRC/Shared/Navigation" -isysroot "$SDK" -Wno-deprecated-declarations \
    "$(dirname "$0")/main.m" "$(dirname "$0")/stubs.m" "$OUT/gen/Links.m" \
    "$SRC"/Shared/Navigation/AddTabSheet.m "$SRC"/Shared/Navigation/TabIcons.m \
    "$SRC"/Redesigned/Navbar/NavbarSettings.m "$SRC"/Redesigned/Navbar/NavbarLayout.m \
    "$SRC"/Settings/SGPage.m "$SRC"/Settings/SGPageStyle.m \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGViewTree.m "$SRC"/Core/SGGlass.m "$SRC"/Core/SGLegacyGlass.m "$SRC"/Core/SGGlassTouch.m \
    "$SRC"/Core/SGBackdrop.m "$SRC"/Core/SGFlagForce.m "$SRC"/Core/SGUIMode.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation \
    -o "$OUT/AddTabHarness.app/AddTabHarness"

# iOS 27 ends an app without a scene delegate at launch, so the scene is named here.
cat > "$OUT/AddTabHarness.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AddTabHarness</string>
<key>CFBundleIdentifier</key><string>com.vitrine.addtabharness</string>
<key>CFBundleName</key><string>AddTabHarness</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>UIUserInterfaceStyle</key><string>Dark</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><false/>
  <key>UISceneConfigurations</key><dict>
    <key>UIWindowSceneSessionRoleApplication</key><array><dict>
      <key>UISceneConfigurationName</key><string>Default</string>
      <key>UISceneDelegateClassName</key><string>SGHarnessScene</string>
    </dict></array>
  </dict>
</dict>
</dict></plist>
PLIST
codesign -f -s - "$OUT/AddTabHarness.app" >/dev/null 2>&1
echo "built $OUT/AddTabHarness.app"
