#!/bin/bash
# restartcheck.sh — three streams in a row. Each must start the deep schedule cleanly (no "Failed to
# claim", no refused enqueues) and find all its loopback clicks. Works with release and debug builds.
# Exit status 0 = pass.
S=$(dirname "$0")
B="$S/bin"                                   # built by: make latency
DEV=${SL_DEVICE:-SL 2}                       # CoreAudio device name (substring)
SUBSYS=${SL_LOG_SUBSYSTEM:-com.rane.sl2}     # the driver's os_log subsystem
start=$(date '+%Y-%m-%d %H:%M:%S')
fail=0

# Three streams, each measuring round-trip latency with 4 clicks.
for i in 1 2 3; do
    echo -n "stream $i: "
    line=$("$B/rtlat" "$DEV" 1 1 4 128 | grep -E 'mean|not found' | head -1)
    echo "$line"
    echo "$line" | grep -q '(4/4 clicks)' || fail=1
done

# What the driver logged for them.
sleep 1
log=$(/usr/bin/log show --start "$start" --style compact --predicate "subsystem == \"$SUBSYS\"" 2>/dev/null \
    | grep -E 'Deep-schedule playback started|Failed to claim|enqueue refused|dp result' | sed -E 's/.*\] \[SL2\] //')
echo "$log"
[ "$(echo "$log" | grep -c 'Deep-schedule playback started')" -ge 3 ] || { echo "FAIL: fewer than 3 streams started"; fail=1; }
echo "$log" | grep -qE 'Failed to claim|enqueue refused' && { echo "FAIL: a stream did not start cleanly"; fail=1; }
[ $fail = 0 ] && echo "PASS" || echo "FAIL"
exit $fail
