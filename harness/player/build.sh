#!/bin/sh
set -e
# SRC may point at another checkout of tweak/Sources (an older commit, to see a bug before its fix).
SRC=${SRC:-$(cd "$(dirname "$0")/../../tweak/Sources" && pwd)}
OUT=${OUT:-$(dirname "$0")/build}
rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/PlayerHarness.app"

for f in Redesigned/Player/PlayerLyrics.x Redesigned/Player/PlayerArtwork.x Redesigned/Player/PlayerFooter.x \
         Redesigned/Player/PlayerScroll.x Redesigned/Player/PlayerField.x Redesigned/Player/PlayerMotion.x Redesigned/Player/PlayerLandscape.x Redesigned/Player/PlayerControls.x Redesigned/Player/PlayerHeader.x Redesigned/Player/PlayerCoverAccent.x Redesigned/Kit/SGRBridges.x; do
    name=$(basename "$f" .x)
    "$THEOS/bin/logos.pl" -c generator=internal "$SRC/$f" > "$OUT/gen/$name.m"
done

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 \
    -I"$SRC" -I"$SRC/Redesigned/Player" -I"$SRC/Redesigned/Kit" -I"$OUT/gen" -I"$(dirname "$0")" -isysroot "$SDK" \
    -Wno-deprecated-declarations \
    "$(dirname "$0")/main.m" "$(dirname "$0")/../scene.m" "$(dirname "$0")/stubs.m" "$(dirname "$0")/../tabbar/touch.m" \
    "$OUT"/gen/*.m \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGViewTree.m "$SRC"/Core/SGGlass.m \
    "$SRC"/Core/SGBackdrop.m "$SRC"/Core/SGFlagForce.m "$SRC"/Core/SGUIMode.m \
    "$SRC"/Redesigned/Kit/SGRTokens.m "$SRC"/Redesigned/Kit/SGRPalette.m "$SRC"/Redesigned/Kit/SGRField.m "$SRC"/Redesigned/Kit/SGRFlow.m "$SRC"/Redesigned/Kit/SGRFluid.m "$SRC"/Shared/AnimatedArtwork/SGMotionCatalog.m "$SRC"/Shared/AnimatedArtwork/SGMotionStore.m \
    "$SRC"/Shared/AnimatedArtwork/SGMotionFollower.m "$SRC"/Shared/AnimatedArtwork/SGMotionClip.m "$SRC"/Shared/Player/SGLastTrack.m \
    "$SRC"/Redesigned/Kit/SGRGlass.m "$SRC"/Settings/SGMarquee.m "$SRC"/Redesigned/Kit/SGRGlyph.m "$SRC"/Redesigned/Kit/SGRRestyle.m \
    "$SRC"/Redesigned/Kit/SGRedesign.m \
    "$SRC"/Redesigned/Player/PlayerSettings.m "$SRC"/Redesigned/Player/PlayerVisualiser.m "$SRC"/Redesigned/Player/SGRSpectrum.m "$SRC"/Redesigned/Player/PlayerVolume.m "$SRC"/Redesigned/NowPlayingBar/NowPlayingBarSettings.m \
    "$SRC"/Settings/SGPage.m "$SRC"/Settings/SGPageStyle.m "$SRC"/Settings/SGModPage.m "$SRC"/Settings/SGGlowSwitch.m \
    "$SRC"/Redesigned/Lyrics/SGRKaraokeView.m "$SRC"/Redesigned/Lyrics/LyricsLook.m "$SRC"/Redesigned/Lyrics/SGRSingButton.m "$SRC"/Redesigned/Lyrics/MeaningSheet.m "$SRC"/Redesigned/Lyrics/LyricsText.m "$SRC"/Shared/Lyrics/KaraokeTiming.m "$SRC"/Shared/Lyrics/Romanise.m "$SRC"/Shared/AdBlock/Protobuf.m \
    "$SRC"/Shared/LyricsSources/SGTTML.m \
    -framework UIKit -framework IOKit -framework QuartzCore -framework CoreGraphics -framework CoreImage -framework Foundation -framework Symbols -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Accelerate -framework MediaPlayer -framework NaturalLanguage \
    -o "$OUT/PlayerHarness.app/PlayerHarness"

cat > "$OUT/PlayerHarness.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PlayerHarness</string>
<key>CFBundleIdentifier</key><string>com.vojta.playerharness</string>
<key>CFBundleName</key><string>PlayerHarness</string>
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
echo "built $OUT/PlayerHarness.app"
