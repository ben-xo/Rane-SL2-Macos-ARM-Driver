#!/bin/bash
# Restart CoreAudio and the apps that keep a stale device list across a coreaudiod restart.
killall coreaudiod || true
# AirPlayXPCHelper can get stuck re-registering AirPlay.driver with the new coreaudiod in a loop,
# keeping it at 100-200% CPU; restart it too (launchd relaunches it).
killall -9 AirPlayXPCHelper 2>/dev/null || true   # ignores SIGTERM
sleep 2
killall ControlCenter 2>/dev/null || true
killall -9 QuickLookUIService 2>/dev/null || true   # ignores SIGTERM
echo "restarted coreaudiod, ControlCenter, QuickLookUIService (reopen Audio MIDI Setup if open)"
