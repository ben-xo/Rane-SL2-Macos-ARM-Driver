#!/bin/bash
# longtest.sh <seconds> <queue sizes...> — long glitch test per queue size, with the driver's health counters
S=$(dirname "$0")
SECS=$1; shift
for n in "$@"; do
    "$S/setnxf" "$n" >/dev/null
    sleep 1
    start=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== queue $n, $SECS s, from $start"
    "$S/sinetest" "SL 2" 1 1 "$SECS" 128 | grep -E 'RESULT|glitch at|level drop'
    /usr/bin/log show --start "$start" --style compact --predicate 'subsystem == "com.rane.sl2"' 2>/dev/null \
        | grep -E 'DBG play skip|restarted|enqueue failed' | cut -c12-23,120-260
    /usr/bin/log show --start "$start" --style compact --predicate 'subsystem == "com.rane.sl2"' 2>/dev/null \
        | grep -E 'DBG play q' | tail -1 | sed -E 's/.*\] \[SL2\] //'
done
