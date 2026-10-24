#!/bin/sh
set -eu
cd "$(dirname "$0")"
SRC=$(cd ../../tweak/Sources && pwd)
OUT=build/activation
mkdir -p "$OUT/AlbumActivation.app"
"${THEOS:-$HOME/theos}/bin/logos.pl" -c generator=internal "$SRC/Native/AlbumQueue/AlbumQueueMenu.x" > "$OUT/AlbumQueueMenu.m"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.4-simulator -fobjc-arc -O0 -g -I"$SRC" -isysroot "$SDK" \
    activation.m ../scene.m "$OUT/AlbumQueueMenu.m" -framework UIKit -framework Foundation -framework QuartzCore \
    -o "$OUT/AlbumActivation.app/AlbumActivation"
python3 - "$OUT/AlbumActivation.app/Info.plist" <<'PY'
import plistlib, sys
plistlib.dump(dict(CFBundleExecutable='AlbumActivation',CFBundleIdentifier='com.vitrine.albumactivation',CFBundleName='AlbumActivation',CFBundleVersion='1',CFBundleShortVersionString='1.0',UILaunchScreen={},UIApplicationSceneManifest={'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Default','UISceneDelegateClassName':'SGRHarnessScene'}]}}),open(sys.argv[1],'wb'))
PY
echo "built $OUT/AlbumActivation.app"
