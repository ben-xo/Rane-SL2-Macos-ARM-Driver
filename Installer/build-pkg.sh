#!/bin/bash
# build-pkg.sh [version] — build the installer package and the download zip from this checkout:
#   build/RaneSL2-macOS-Universal.pkg            what Instalar-Rane-SL2.command installs
#   build/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip  the Installer folder and tools/firmware, as published
# Nothing committed is touched: copy the results over Installer/RaneSL2-macOS-Universal.pkg and
# Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip to publish them. Run by `make package` (VERSION=x.y.z).
#
# The package installs, all ad-hoc signed:
#   /Library/Audio/Plug-Ins/HAL/SL2Device.driver   the CoreAudio driver (plugin/)
#   /Library/Frameworks/SL2Api.framework           the SL2Api replacement for Serato DJ Pro 2.5.5
#   /Library/Extensions/SL2.10.9.kext              Info.plist only: no code, nothing loads
#   /Applications/SL 2 Control Panel.app           tools/controlpanel/
#   /usr/local/bin/sl2panel, sl2dump, sl2flash
# with Installer/package/scripts as its pre- and post-install scripts.
set -euo pipefail
VERSION=${1:-1.3.0}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKGSRC="$ROOT/Installer/package"
OUT="$ROOT/build"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/root"

# Build everything from source (release driver, no debug code).
cd "$ROOT"
make plugin api panel dump flash
tools/controlpanel/build-app.sh "$WORK"

# The driver bundle.
DRV="$STAGE/Library/Audio/Plug-Ins/HAL/SL2Device.driver"
mkdir -p "$DRV/Contents/MacOS"
cp -X plugin/Device-Info.plist "$DRV/Contents/Info.plist"
cp -X SL2Device "$DRV/Contents/MacOS/SL2Device"
codesign --force --sign - "$DRV"

# SL2Api.framework, laid out as Rane's (Serato loads .../SL2Api.framework/SL2Api).
FW="$STAGE/Library/Frameworks/SL2Api.framework"
mkdir -p "$FW/Versions/A/Resources"
cp -X SL2Api "$FW/Versions/A/SL2Api"
cp -X "$PKGSRC/metadata/SL2Api-Info.plist" "$FW/Versions/A/Resources/Info.plist"
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/SL2Api "$FW/SL2Api"
ln -s Versions/Current/Resources "$FW/Resources"
codesign --force --sign - "$FW"

# The kext's Info.plist (clients look for an installed SL 2 kext; there is no code in it).
mkdir -p "$STAGE/Library/Extensions/SL2.10.9.kext/Contents"
cp -X "$PKGSRC/metadata/SL2-kext-Info.plist" "$STAGE/Library/Extensions/SL2.10.9.kext/Contents/Info.plist"

# The control panel app and the command-line tools.
mkdir -p "$STAGE/Applications" "$STAGE/usr/local/bin"
ditto --noextattr --noqtn "$WORK/SL 2 Control Panel.app" "$STAGE/Applications/SL 2 Control Panel.app"
cp -X sl2panel sl2dump sl2flash "$STAGE/usr/local/bin/"

# The component package. Bundles install where listed: not relocated to a copy found elsewhere.
pkgbuild --analyze --root "$STAGE" "$WORK/components.plist" >/dev/null
i=0
while plutil -replace "$i.BundleIsRelocatable" -bool NO "$WORK/components.plist" 2>/dev/null; do
    i=$((i + 1))
done
mkdir -p "$WORK/pkgs"
pkgbuild --root "$STAGE" --component-plist "$WORK/components.plist" --scripts "$PKGSRC/scripts" \
    --identifier com.pepelee.ranesl2.driver --version "$VERSION" --install-location / \
    "$WORK/pkgs/RaneSL2-Core.pkg"

# The product package, with the installer's pages.
sed "s/@VERSION@/$VERSION/" "$PKGSRC/Distribution.xml" > "$WORK/Distribution.xml"
mkdir -p "$OUT"
productbuild --distribution "$WORK/Distribution.xml" --resources "$PKGSRC/resources" \
    --package-path "$WORK/pkgs" "$OUT/RaneSL2-macOS-Universal.pkg"

# The download zip: the Installer folder's user-facing files with the new package, and tools/firmware.
Z="$WORK/zip"
mkdir -p "$Z/Installer" "$Z/tools"
cp Installer/*.command Installer/LEEME-INSTRUCCIONES.txt "$OUT/RaneSL2-macOS-Universal.pkg" "$Z/Installer/"
git ls-files -z tools/firmware | (cd "$ROOT" && xargs -0 tar cf -) | (cd "$Z" && tar xf -)
rm -f "$OUT/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip"
(cd "$Z" && zip -qry "$OUT/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip" Installer tools)

echo "built $OUT/RaneSL2-macOS-Universal.pkg ($VERSION) and $OUT/Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip"
