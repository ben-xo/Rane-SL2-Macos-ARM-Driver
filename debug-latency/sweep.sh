#!/bin/bash
# sweep.sh <seconds-per-sine-test> <queue sizes...>
# For each playback queue size: latency (rtlat), then glitch test idle and with every CPU core busy.
S=$(dirname "$0")
SECS=$1; shift
NCPU=$(sysctl -n hw.ncpu)
for n in "$@"; do
    echo "=== queue $n transfers"
    "$S/setnxf" "$n" >/dev/null
    sleep 4   # let any signal circulating through analog thru + the loopback cable die away
    "$S/rtlat" "SL 2" 1 1 4 128 | grep -E 'mean|not found' | head -1
    echo -n "idle:   "; "$S/sinetest" "SL 2" 1 1 "$SECS" 128 | grep -E 'RESULT|glitch at' | tr '\n' ' '; echo
    pids=()
    for i in $(seq "$NCPU"); do yes >/dev/null & pids+=($!); done
    echo -n "loaded: "; "$S/sinetest" "SL 2" 1 1 "$SECS" 128 | grep -E 'RESULT|glitch at' | tr '\n' ' '; echo
    kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null
done
