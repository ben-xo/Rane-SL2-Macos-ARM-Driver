#!/bin/bash
# Install a freshly built driver (SL2Device) into the installed HAL plug-in bundle and restart
# CoreAudio; with --api, also install a freshly built SL2Api into the installed SL2Api.framework
# (what Serato and Rane's control panel load); --restore-api puts back the framework binary that
# was there before the first --api install.
#
# Prerequisite: the driver and framework bundles must already be installed, by the release package
# (Installer/RaneSL2-macOS-Universal.pkg). This script only replaces the binaries inside them.
#
# usage: sudo tools/install-sl2.sh [--api] [driver-binary]
#        sudo tools/install-sl2.sh --restore-api
#   default driver: SL2Device built by `make plugin` in this checkout; --api: SL2Api built by `make api`
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DRV=/Library/Audio/Plug-Ins/HAL/SL2Device.driver
FW=/Library/Frameworks/SL2Api.framework
BACKUP=/Library/Frameworks/SL2Api.before-install   # beside the framework, not inside it (that would break its signature)

# Write beside the old binary and rename over it: a process that has it loaded keeps its mapped
# (old) file, instead of having its code pages rewritten under it (which gets it killed: Code
# Signature Invalid). Then re-sign the bundle.
install_binary() {   # <source> <bundle> <path of the binary inside the bundle>
    cp "$1" "$2/$3.new"
    mv -f "$2/$3.new" "$2/$3"
    codesign --force --sign - "$2"
}

need_bundle() {   # <bundle>
    if [ ! -d "$1" ]; then
        echo "$1 is not installed. Install the release package first (Installer/RaneSL2-macOS-Universal.pkg);" >&2
        echo "this script only replaces the binaries inside the installed bundles." >&2
        exit 1
    fi
}

# --restore-api: the framework binary saved by the first --api install goes back.
if [ "${1:-}" = "--restore-api" ]; then
    need_bundle "$FW"
    [ -f "$BACKUP" ] || { echo "no saved framework binary at $BACKUP" >&2; exit 1; }
    install_binary "$BACKUP" "$FW" Versions/A/SL2Api
    echo "restored SL2Api from $BACKUP: restart Serato to load it"
    exit 0
fi

API=0
if [ "${1:-}" = "--api" ]; then API=1; shift; fi
SRC=${1:-$ROOT/SL2Device}

# --api: save the framework binary the first time (an older version of this script kept it in the
# checkout; move that one here), then install the built one.
if [ "$API" = 1 ]; then
    need_bundle "$FW"
    if [ ! -e "$BACKUP" ]; then
        if [ -f "$ROOT/SL2Api.before-install" ]; then mv "$ROOT/SL2Api.before-install" "$BACKUP"
        else cp "$FW/Versions/A/SL2Api" "$BACKUP"; fi
        echo "saved the previous SL2Api as $BACKUP (put it back with --restore-api)"
    fi
    echo "installing $ROOT/SL2Api"
    install_binary "$ROOT/SL2Api" "$FW" Versions/A/SL2Api
    echo "installed SL2Api $(shasum -a 256 "$FW/Versions/A/SL2Api" | cut -c1-16): restart Serato to load it"
fi

# The driver, then restart CoreAudio and the processes that go stale when it restarts.
need_bundle "$DRV"
echo "installing $SRC"
install_binary "$SRC" "$DRV" Contents/MacOS/SL2Device
killall coreaudiod || true
killall -9 AirPlayXPCHelper 2>/dev/null || true   # can loop re-registering with the new coreaudiod; ignores SIGTERM
# Apps holding the old coreaudiod's device list drop the SL2 and don't re-add it: refresh them.
sleep 2
killall ControlCenter 2>/dev/null || true
killall -9 QuickLookUIService 2>/dev/null || true   # ignores SIGTERM
echo "installed $(shasum -a 256 "$DRV/Contents/MacOS/SL2Device" | cut -c1-16) and restarted coreaudiod"
