#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
SRC=../../tweak/Sources
xcrun clang -fobjc-arc -Wall -Werror -target arm64-apple-macos13.0 -I"$SRC" \
    check.m "$SRC/Shared/AlbumQueue/AlbumQueueContext.m" -framework Foundation -o build/context-check
cat "$SRC/Shared/AlbumQueue/AlbumPage.swift" page.swift > build/page-check.swift
xcrun swiftc -module-cache-path build/module-cache build/page-check.swift -o build/page-check
build/context-check
build/page-check
