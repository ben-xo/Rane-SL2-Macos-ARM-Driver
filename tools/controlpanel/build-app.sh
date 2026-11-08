#!/bin/bash
# build-app.sh [output-dir] — build "SL 2 Control Panel.app" (universal: arm64 + x86_64, macOS 13+)
# into output-dir (default: the repository root), ad-hoc signed. Run by `make controlpanel`.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$(cd "$HERE/../.." && pwd)}
APP="$OUT/SL 2 Control Panel.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Compile each architecture, then join them.
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos13.0" \
        -import-objc-header "$HERE/SL2Status.h" \
        "$HERE/SL2ControlPanel.swift" -o "$TMP/SL2ControlPanel-$arch"
done

# Lay out the bundle and sign it.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "$TMP/SL2ControlPanel-arm64" "$TMP/SL2ControlPanel-x86_64" -output "$APP/Contents/MacOS/SL2ControlPanel"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
