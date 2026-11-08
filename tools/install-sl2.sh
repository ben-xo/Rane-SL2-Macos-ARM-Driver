#!/bin/bash
# Install the freshly built SL2Device into the HAL plug-in bundle and restart CoreAudio.
set -euo pipefail
# usage: sudo tools/install-sl2.sh [binary]   (default: SL2Device built by `make plugin` in this checkout)
SRC=${1:-$(cd "$(dirname "$0")/.." && pwd)/SL2Device}
echo "installing $SRC"
DST=/Library/Audio/Plug-Ins/HAL/SL2Device.driver
# Write beside the old binary and rename over it: the running helper keeps its mapped (old) file,
# instead of having its code pages rewritten under it (which gets it killed: Code Signature Invalid).
cp "$SRC" "$DST/Contents/MacOS/SL2Device.new"
mv -f "$DST/Contents/MacOS/SL2Device.new" "$DST/Contents/MacOS/SL2Device"
codesign --force --sign - "$DST"
killall coreaudiod || true
killall -9 AirPlayXPCHelper 2>/dev/null || true   # can loop re-registering with the new coreaudiod; ignores SIGTERM
# Apps holding the old coreaudiod's device list drop the SL2 and don't re-add it: refresh them.
sleep 2
killall ControlCenter 2>/dev/null || true
killall -9 QuickLookUIService 2>/dev/null || true   # ignores SIGTERM
echo "note: quit and reopen Audio MIDI Setup if it is open"
echo "installed $(shasum -a 256 "$DST/Contents/MacOS/SL2Device" | cut -c1-16) and restarted coreaudiod"
