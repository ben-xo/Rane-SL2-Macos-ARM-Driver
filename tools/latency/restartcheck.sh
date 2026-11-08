#!/bin/bash
# restartcheck.sh — three streams in a row; each must start the deep schedule and measure latency
S=$(dirname "$0")
B="$S/bin"                                   # built by: make latency
DEV=${SL_DEVICE:-SL 2}                       # CoreAudio device name (substring)
SUBSYS=${SL_LOG_SUBSYSTEM:-com.rane.sl2}     # the driver's os_log subsystem
start=$(date '+%Y-%m-%d %H:%M:%S')
for i in 1 2 3; do
    echo -n "stream $i: "
    "$B/rtlat" "$DEV" 1 1 4 128 | grep -E 'mean|not found' | head -1
done
sleep 1
/usr/bin/log show --start "$start" --style compact --predicate "subsystem == \"$SUBSYS\"" 2>/dev/null \
    | grep -E 'Deep-schedule playback started|Failed to claim|enqueue refused|dp result' | sed -E 's/.*\] \[SL2\] //'
