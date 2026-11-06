#!/bin/bash
# Firmware-SL2.command — restore the firmware of a Rane SL 2 that is in its USB bootloader.
#
# The SL 2 keeps its firmware in an EEPROM on the box. If that firmware is lost, the box comes
# up in bootloader mode — System Information shows "Unnamed Device" (vendor 0x1cc5, product
# 0x0013, bcdDevice 0x0000) — and passes no audio until firmware is loaded again. (A box that
# does not enumerate at all is bricked and needs tools/firmware/RECOVERY.md instead.)
# The firmware is Rane's and is not part of this driver, but it ships inside the free
# "Serato Scratch Live" download for Mac. This script:
#   1. finds that download in ~/Downloads (or opens the download page),
#   2. extracts the firmware from Rane's SL2 package (tools/firmware/extract-sl2-firmware.py),
#   3. installs it where sl2flash looks for it (/Library/Audio/Plug-Ins/HAL/SL2Device.firmware),
#   4. runs sl2flash to load it into the box over USB if one is attached in bootloader mode.
# Nothing else from the Scratch Live download is installed or kept.
#
# NOTE: the over-USB load (step 4) is reverse-engineered and unproven on hardware — see the
# STATUS note in tools/firmware/SL2Loader.h. The reliable fix for a bricked box is the direct
# EEPROM reflash in tools/firmware/RECOVERY.md.
set -e
URL="https://serato.com/scratchlive/downloads/mac"
DL="$HOME/Downloads"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FW="$ROOT/tools/firmware"
EXTRACT="$FW/extract-sl2-firmware.py"
INSTALL="$FW/sl2-firmware-install.sh"
FLASH="$ROOT/sl2flash"

command -v python3 >/dev/null || { echo "python3 is required (install the Xcode Command Line Tools)."; exit 1; }

DMG=$(find "$DL" -maxdepth 2 -iname "Serato Scratch Live*.dmg" 2>/dev/null | head -1)
if [ -z "$DMG" ]; then
    ZIP=$(find "$DL" -maxdepth 1 -iname "Serato Scratch Live*Mac*.zip" 2>/dev/null | head -1)
    if [ -n "$ZIP" ]; then
        echo "Unpacking $(basename "$ZIP") ..."
        unzip -q -o "$ZIP" -d "$DL"
        DMG=$(find "$DL" -maxdepth 2 -iname "Serato Scratch Live*.dmg" 2>/dev/null | head -1)
    fi
fi
if [ -z "$DMG" ]; then
    echo "Please download 'Serato Scratch Live' for Mac from:"
    echo "    $URL"
    echo "into your Downloads folder, then run this again."
    open "$URL" 2>/dev/null || true
    exit 1
fi
echo "Using $DMG"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl2fw.XXXXXX")
cleanup() { hdiutil detach "$WORK/dmg" -quiet 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/dmg"
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$WORK/dmg" "$DMG"
PKG=$(find "$WORK/dmg" -iname "SL2*.pkg" 2>/dev/null | head -1)
[ -n "$PKG" ] || { echo "The disk image has no Rane SL2 driver package."; exit 1; }

echo "Extracting firmware from $(basename "$PKG") ..."
python3 "$EXTRACT" "$PKG" "$WORK/out"
BOOT="$WORK/out/sl2_bootstrap_firmware.deobfuscated.bin"
FINAL="$WORK/out/sl2_final_firmware.deobfuscated.bin"
[ -f "$BOOT" ] && [ -f "$FINAL" ] || { echo "extraction did not produce the expected firmware images."; exit 1; }

echo
echo "Installing the firmware next to the driver (administrator password needed) ..."
sudo "$INSTALL" "$BOOT" "$FINAL"

echo
if [ -x "$FLASH" ]; then
    echo "Checking for an SL 2 in bootloader mode ..."
    "$FLASH" || true
else
    echo "(build the loader with 'make flash', then run ./sl2flash, to load a bootloader-mode box over USB)"
fi
echo "Done."
