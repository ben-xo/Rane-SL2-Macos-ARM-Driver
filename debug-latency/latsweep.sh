#!/bin/bash
# latsweep.sh <queue sizes...> — round-trip latency at each playback queue size (128-frame buffer)
S=$(dirname "$0")
for n in "$@"; do
    "$S/setnxf" "$n" >/dev/null
    echo -n "queue $n: "
    "$S/rtlat" "SL 2" 1 1 4 128 | grep -E 'mean|not found' | head -1
done
