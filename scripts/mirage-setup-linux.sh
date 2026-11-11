#!/usr/bin/env bash
# Sets up a Linux (x86_64, Debian/Ubuntu) box to build Mirage + Vitrine without macOS. Everything
# comes from GitHub releases / swift.org over HTTPS, so a broken apt mirror does not matter.
#
#   scripts/mirage-setup-linux.sh        then: source ~/mirage-env.sh
#
# What it installs (all under $HOME unless noted):
#   ~/theos                          Theos (git, with submodules)
#   ~/theos/toolchain/linux/iphone   L1ghtmann's iOS cctools toolchain (ld64, ldid, otool, lipo...)
#   ~/theos/sdks/iPhoneOS26.2.sdk    from github.com/xybp888/iOS-SDKs (sparse checkout), with 26.5's .tbd link stubs;
#                                    Vitrine needs a 26+ SDK
#   /opt/swift                       swift.org Swift 6.2.3 for Debian 12: its clang 17 reads the iOS 26 SDK, its swiftc the 26.2 Swift interfaces
#                                    (the cctools toolchain's clang 11 cannot), and its swiftc builds Vitrine's Swift
#   wrappers                         clang/clang++ (clang 17 + ld64 + a tiny availability shim instead of
#                                    libclang_rt.ios.a), swiftc (an iOS resource dir), xcrun (the few calls the
#                                    scripts make)
#   /usr/local/bin/make, gmake       GNU make 4.4.1 from source if missing
#   cyan                             uv tool install (pyzule-rw)
set -euo pipefail
THEOS="${THEOS:-$HOME/theos}"
SDK_VER=26.2
# 26.2's headers and Swift interfaces match Swift 6.2.3, but its .tbd stubs in that repo are incomplete
# (no Swift symbols for ActivityKit, FoundationModels...), so the link stubs come from 26.5, whose are complete.
TBD_VER=26.5
SWIFT_VER=6.2.3
TC="$THEOS/toolchain/linux/iphone"

command -v gmake >/dev/null || {
  echo "==> GNU make"
  tmp="$(mktemp -d)"; curl -fsSL https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz | tar xz -C "$tmp"
  (cd "$tmp/make-4.4.1" && ./configure --prefix=/usr/local --disable-dependency-tracking >/dev/null && sh build.sh >/dev/null)
  sudo install -m755 "$tmp/make-4.4.1/make" /usr/local/bin/make && sudo ln -sf /usr/local/bin/make /usr/local/bin/gmake
}

[ -d "$THEOS/.git" ] || { echo "==> Theos"; git clone --recursive --depth 1 https://github.com/theos/theos "$THEOS"; }

if [ ! -x "$TC/bin/ld" ]; then
  echo "==> iOS cctools toolchain"
  url="$(curl -fsSL https://api.github.com/repos/L1ghtmann/llvm-project/releases/latest | python3 -c 'import json,sys;print([a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if "x86_64" in a["name"]][0])')"
  mkdir -p "$TC"; curl -fsSL "$url" | tar xJ -C "$TC" --strip-components=2
  mv "$TC/bin/clang" "$TC/bin/clang-11-orig"; mv "$TC/bin/clang++" "$TC/bin/clang++-11-orig"
fi

if [ ! -d "$THEOS/sdks/iPhoneOS$SDK_VER.sdk" ]; then
  echo "==> iPhoneOS $SDK_VER SDK"
  tmp="$(mktemp -d)"
  git clone --filter=blob:none --no-checkout --depth 1 https://github.com/xybp888/iOS-SDKs "$tmp/sdks"
  (cd "$tmp/sdks" && git sparse-checkout set "iPhoneOS$SDK_VER.sdk" "iPhoneOS$TBD_VER.sdk" && git checkout -q)
  (cd "$tmp/sdks/iPhoneOS$TBD_VER.sdk" && find . -name '*.tbd' | while IFS= read -r f; do
     mkdir -p "../iPhoneOS$SDK_VER.sdk/$(dirname "$f")"; cp "$f" "../iPhoneOS$SDK_VER.sdk/$f"; done)
  mkdir -p "$THEOS/sdks"; mv "$tmp/sdks/iPhoneOS$SDK_VER.sdk" "$THEOS/sdks/"; rm -rf "$tmp"
fi

if [ ! -x /opt/swift/usr/bin/swiftc ]; then
  echo "==> Swift $SWIFT_VER"
  sudo mkdir -p /opt/swift && sudo chown "$USER" /opt/swift
  curl -fsSL "https://download.swift.org/swift-$SWIFT_VER-release/debian12/swift-$SWIFT_VER-RELEASE/swift-$SWIFT_VER-RELEASE-debian12.tar.gz" \
    | tar xz -C /opt/swift --strip-components=1
fi
/opt/swift/usr/bin/swift --version >/dev/null 2>&1 || echo "    swift needs libncurses6 (Debian: the libncurses6 .deb from deb.debian.org over https)"

echo "==> wrappers"
mkdir -p "$THEOS/toolchain/rtshim"
cat > "$THEOS/toolchain/rtshim/rt.c" <<'C'
// Stand-in for compiler-rt's Darwin availability builtins (os_version_check.c): the Linux clang ships no
// libclang_rt.ios.a. iOS 15+ libSystem has _availability_version_check, which compiler-rt calls too.
#include <stdint.h>
#include <stdbool.h>
typedef struct { uint32_t platform; uint32_t version; } dyld_build_version_t;
extern bool _availability_version_check(uint32_t count, dyld_build_version_t versions[]);
__attribute__((visibility("hidden"))) int32_t __isPlatformVersionAtLeast(uint32_t P, uint32_t Ma, uint32_t Mi, uint32_t S) {
  dyld_build_version_t v = { P, (Ma << 16) | ((Mi & 0xff) << 8) | (S & 0xff) };
  return _availability_version_check(1, &v);
}
__attribute__((visibility("hidden"))) int32_t __isOSVersionAtLeast(int32_t Ma, int32_t Mi, int32_t S) {
  return __isPlatformVersionAtLeast(2, Ma, Mi, S);
}
C
/opt/swift/usr/bin/clang -target arm64-apple-ios16.0 -isysroot "$THEOS/sdks/iPhoneOS$SDK_VER.sdk" -O2 -c "$THEOS/toolchain/rtshim/rt.c" -o "$THEOS/toolchain/rtshim/rt.o"
/opt/swift/usr/bin/llvm-ar rcs "$THEOS/toolchain/rtshim/libmirage_rt.a" "$THEOS/toolchain/rtshim/rt.o"
for t in clang clang++; do cat > "$TC/bin/$t" <<EOF2
#!/bin/bash
# Swift's clang 17 (reads the iOS 26 SDK) + cctools ld64 + the availability shim. Host builds pass through.
ios=0; link=1
for a in "\$@"; do case "\$a" in *apple-ios*|*iPhoneOS*|*apple-darwin*) ios=1;; -c|-E|-S|-M|-MM|-fsyntax-only|-dumpversion|--version|-v) link=0;; esac; done
if [ \$ios = 1 ] && [ \$link = 1 ]; then exec /opt/swift/usr/bin/$t --ld-path=$TC/bin/ld -Wno-unused-command-line-argument "\$@" $THEOS/toolchain/rtshim/libmirage_rt.a; fi
exec /opt/swift/usr/bin/$t "\$@"
EOF2
chmod +x "$TC/bin/$t"; done

R="$HOME/swift-ios-res"; mkdir -p "$R/iphoneos"
ln -sfn /opt/swift/usr/lib/swift/shims "$R/shims"; ln -sfn /opt/swift/usr/lib/swift/clang "$R/clang"
S="$THEOS/toolchain/swift/bin"; rm -rf "$S"; mkdir -p "$S"
for f in /opt/swift/usr/bin/*; do ln -sf "$f" "$S/"; done; rm "$S/swiftc"
cat > "$S/swiftc" <<'EOF2'
#!/bin/bash
# The Linux resource dir's Dispatch/Glibc modules clash with the iOS SDK's: iOS targets get one with
# only the shims and clang's headers; the Swift stdlib comes from the SDK.
for a in "$@"; do case "$a" in *apple-ios*) exec /opt/swift/usr/bin/swiftc -resource-dir "$HOME/swift-ios-res" -Xfrontend -enable-cross-import-overlays "$@";; esac; done
exec /opt/swift/usr/bin/swiftc "$@"
EOF2
chmod +x "$S/swiftc"

cat > "$TC/bin/xcrun" <<EOF2
#!/bin/bash
# The few xcrun calls the build scripts make. No iOS swiftc/Xcode here, so the Live Activity is skipped.
SDK="$THEOS/sdks/iPhoneOS$SDK_VER.sdk"; BIN="$TC/bin"; find=0
while [ \$# -gt 0 ]; do case "\$1" in -sdk|--sdk) shift 2;; --show-sdk-path) echo "\$SDK"; exit 0;; -f|--find) find=1; shift;; *) break;; esac; done
tool="\$1"; shift || true
case "\$tool" in swiftc|swift|xcodebuild|appintentsmetadataprocessor|"") exit 1;; esac
path="\$BIN/\$tool"; [ -x "\$path" ] || path="\$(command -v "\$tool")" || exit 1
[ \$find = 1 ] && { echo "\$path"; exit 0; }
case "\$tool" in clang|clang++) exec "\$path" -isysroot "\$SDK" "\$@";; esac
exec "\$path" "\$@"
EOF2
chmod +x "$TC/bin/xcrun"

# The iOS tools go on PATH through a directory of their own: putting $TC/bin itself first would hand
# its cctools `ld` to host (Linux) links, like the one building Theos' Swift support tools.
mkdir -p "$HOME/mirage-bin"
for t in xcrun ldid otool lipo install_name_tool strings; do ln -sf "$TC/bin/$t" "$HOME/mirage-bin/$t"; done
command -v cyan >/dev/null || uv tool install 'cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw'

cat > "$HOME/mirage-env.sh" <<EOF2
export THEOS=$THEOS
export PATH=\$HOME/mirage-bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/swift/usr/bin
EOF2
echo "==> done: source ~/mirage-env.sh, then scripts/mirage-build.sh <decrypted Spotify.ipa>"
