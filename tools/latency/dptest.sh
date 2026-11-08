#!/bin/bash
# dptest.sh <seconds> — glitch test on playback, idle and then with every core loaded, plus the
# driver's deep-schedule counters from its log. The counters come from a debug build
# (make plugin DEBUG=1); without them the test fails, so a release build can't look like a pass.
# Exit status 0 = no glitches in either run and counters present.
S=$(dirname "$0")
B="$S/bin"                                   # built by: make latency
DEV=${SL_DEVICE:-SL 2}                       # CoreAudio device name (substring)
SUBSYS=${SL_LOG_SUBSYSTEM:-com.rane.sl2}     # the driver's os_log subsystem
SECS=${1:?usage: dptest.sh <seconds>}
NCPU=$(sysctl -n hw.ncpu)
fail=0
# Run twice: once idle, once with every core busy.
for load in idle loaded; do
    # Load every core for the second run.
    pids=()
    if [ "$load" = loaded ]; then for i in $(seq "$NCPU"); do yes >/dev/null & pids+=($!); done; fi
    start=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== $load, $SECS s"

    # The glitch test itself.
    out=$("$B/sinetest" "$DEV" 1 1 "$SECS" 128)
    echo "$out" | grep -E 'RESULT|glitch at|level drop|not found' | head -8
    echo "$out" | grep -q 'RESULT: 0 glitches, 0 level drops' || fail=1
    [ ${#pids[@]} -gt 0 ] && { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; }

    # The driver's counters for that stream (debug build only).
    sleep 1
    counters=$(/usr/bin/log show --start "$start" --style compact --predicate "subsystem == \"$SUBSYS\"" 2>/dev/null \
        | grep -E 'dp result|dp enqueue refused|capture handler vs bus' | sed -E 's/.*\] \[SL2\] //' | tail -4)
    if [ -z "$counters" ]; then
        echo "FAIL: no driver counters in the log (is the driver a debug build? make plugin DEBUG=1)"
        fail=1
    else
        echo "$counters"
    fi
done
[ $fail = 0 ] && echo "PASS" || echo "FAIL"
exit $fail
