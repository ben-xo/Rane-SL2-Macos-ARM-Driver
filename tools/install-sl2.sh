#!/bin/bash
# Install a freshly built SL2Device into the HAL plug-in bundle and restart CoreAudio; with --api,
# also install the freshly built SL2Api into SL2Api.framework (what Serato loads).
set -euo pipefail
# usage: sudo tools/install-sl2.sh [--api] [driver-binary]
#   default driver: SL2Device built by `make plugin` in this checkout; --api: SL2Api built by `make api`
ROOT=$(cd "$(dirname "$0")/.." && pwd)
API=0
if [ "${1:-}" = "--api" ]; then API=1; shift; fi
SRC=${1:-$ROOT/SL2Device}

# Write beside the old binary and rename over it: a process that has it loaded keeps its mapped
# (old) file, instead of having its code pages rewritten under it (which gets it killed: Code
# Signature Invalid).
install_binary() {   # <source> <bundle> <path of the binary inside the bundle>
    cp "$1" "$2/$3.new"
    mv -f "$2/$3.new" "$2/$3"
    codesign --force --sign - "$2"
}

if [ "$API" = 1 ]; then
    FW=/Library/Frameworks/SL2Api.framework
    # Keep the binary that was there before the first install from this checkout, to go back to.
    BACKUP="$ROOT/SL2Api.before-install"
    if [ ! -e "$BACKUP" ]; then cp "$FW/Versions/A/SL2Api" "$BACKUP"; echo "saved the previous SL2Api as $BACKUP"; fi
    echo "installing $ROOT/SL2Api"
    install_binary "$ROOT/SL2Api" "$FW" Versions/A/SL2Api
    echo "installed SL2Api $(shasum -a 256 "$FW/Versions/A/SL2Api" | cut -c1-16): restart Serato to load it"
fi

echo "installing $SRC"
DST=/Library/Audio/Plug-Ins/HAL/SL2Device.driver
install_binary "$SRC" "$DST" Contents/MacOS/SL2Device
killall coreaudiod || true
killall -9 AirPlayXPCHelper 2>/dev/null || true   # can loop re-registering with the new coreaudiod; ignores SIGTERM
# Apps holding the old coreaudiod's device list drop the SL2 and don't re-add it: refresh them.
sleep 2
killall ControlCenter 2>/dev/null || true
killall -9 QuickLookUIService 2>/dev/null || true   # ignores SIGTERM
echo "note: quit and reopen Audio MIDI Setup if it is open"
echo "installed $(shasum -a 256 "$DST/Contents/MacOS/SL2Device" | cut -c1-16) and restarted coreaudiod"
