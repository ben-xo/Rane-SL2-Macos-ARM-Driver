#!/bin/bash
# Firmware-SL2.command — restore (or update) the firmware of a Rane SL 2 over USB.
#
# The SL 2 keeps its firmware in an EEPROM on the box. If that firmware is lost, the box comes
# up in bootloader mode — all its LEDs stay off, and System Information shows "Unnamed Device"
# (vendor 0x1cc5, product 0x0013, bcdDevice 0x0000) — and passes no audio until the firmware is
# written again. (A box that does not enumerate at all needs tools/firmware/RECOVERY.md instead.)
# The firmware is Rane's and is not part of this driver, but it ships inside the free
# "Serato Scratch Live" download for Mac. This script:
#   1. finds that download (.dmg, or the .zip it comes in) in ~/Downloads, or opens the
#      download page,
#   2. extracts the firmware from Rane's SL2 package (tools/firmware/extract-sl2-firmware.py),
#   3. installs it where sl2flash looks for it (/Library/Audio/Plug-Ins/HAL/SL2Device.firmware),
#   4. checks the attached box with sl2flash and, if its EEPROM does not already hold this
#      firmware, asks before writing it.
# Nothing else from the Scratch Live download is installed or kept, and the download itself is
# left untouched. Desinstalar-Rane-SL2.command removes the installed firmware with the driver.
#
# Run it from a checkout of this repository, with the SL 2 audio driver installed
# (Instalar-Rane-SL2.command) and sl2flash built (`make flash`); see tools/firmware/README.md.
set -e
URL="https://serato.com/scratchlive/downloads/mac"
DL="$HOME/Downloads"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FW="$ROOT/tools/firmware"
EXTRACT="$FW/extract-sl2-firmware.py"
INSTALL="$FW/sl2-firmware-install.sh"
FLASH="$ROOT/sl2flash"
DRIVER="/Library/Audio/Plug-Ins/HAL/SL2Device.driver"

command -v python3 >/dev/null || { echo "python3 is required (install the Xcode Command Line Tools)."; exit 1; }
[ -d "$DRIVER" ] || { echo "The SL 2 audio driver is not installed; run Instalar-Rane-SL2.command first."; exit 1; }

# Everything unpacked or extracted goes in WORK, which is deleted on exit; only the download
# itself is left in ~/Downloads.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl2fw.XXXXXX")
cleanup() { hdiutil detach "$WORK/dmg" -quiet 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

DMG=$(find "$DL" -maxdepth 2 -iname "Serato Scratch Live*.dmg" 2>/dev/null | head -1)
if [ -z "$DMG" ]; then
    ZIP=$(find "$DL" -maxdepth 1 -iname "Serato Scratch Live*Mac*.zip" 2>/dev/null | head -1)
    if [ -n "$ZIP" ]; then
        echo "Unpacking $(basename "$ZIP") ..."
        unzip -q -o "$ZIP" -d "$WORK/zip"
        DMG=$(find "$WORK/zip" -maxdepth 2 -iname "Serato Scratch Live*.dmg" 2>/dev/null | head -1)
    fi
fi
if [ -z "$DMG" ]; then
    echo "Please download 'Scratch Live 2.5.0 for Mac OS X' from:"
    echo "    $URL"
    echo "(the page asks you to sign in; a free Serato account is enough)"
    echo "into your Downloads folder, then run this again."
    open "$URL" 2>/dev/null || true
    exit 1
fi
echo "Using $(basename "$DMG")"

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
if [ ! -x "$FLASH" ]; then
    echo "(build the flasher with 'make flash', then run ./sl2flash, to write the firmware over USB)"
    exit 0
fi
echo "Checking the SL 2 ..."
rc=0; "$FLASH" --dry-run || rc=$?
case $rc in
    0)  ;;   # already holds this firmware
    3)  echo
        echo "Stop any audio on the SL 2 and quit Serato and sl2panel before continuing."
        read -r -p "Write the firmware to the SL 2 now? [y/N] " answer
        if [[ "$answer" =~ ^[Yy] ]]; then "$FLASH"; else echo "Nothing written."; fi ;;
    *)  echo "sl2flash could not check the box (see above); connect it and run this again."; exit 1 ;;
esac
echo "Done."
