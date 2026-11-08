#!/bin/bash
# dptest.sh <seconds> — glitch test on the current playback path, idle then with every core loaded,
# with the driver's deep-schedule counters
S=$(dirname "$0")
B="$S/bin"                                   # built by: make latency
DEV=${SL_DEVICE:-SL 2}                       # CoreAudio device name (substring)
SUBSYS=${SL_LOG_SUBSYSTEM:-com.rane.sl2}     # the driver's os_log subsystem
SECS=$1
NCPU=$(sysctl -n hw.ncpu)
for load in idle loaded; do
    pids=()
    if [ "$load" = loaded ]; then for i in $(seq "$NCPU"); do yes >/dev/null & pids+=($!); done; fi
    start=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== $load, $SECS s"
    "$B/sinetest" "$DEV" 1 1 "$SECS" 128 | grep -E 'RESULT|glitch at|level drop' | head -8
    [ ${#pids[@]} -gt 0 ] && { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; }
    sleep 1
    /usr/bin/log show --start "$start" --style compact --predicate "subsystem == \"$SUBSYS\"" 2>/dev/null \
        | grep -E 'dp result|dp enqueue refused|capture handler vs bus' | sed -E 's/.*\] \[SL2\] //' | tail -4
done
