#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -I ../../tweak/Sources -I ../../tweak/Sources/Core \
    -framework Foundation check.m ../../tweak/Sources/Core/SGPrefs.m -o build/check
build/check
