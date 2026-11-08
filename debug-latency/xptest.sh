#!/bin/bash
# xptest.sh <seconds> <mode:lead>... — late-write experiment runs, glitch-checked through the loopback
S=$(dirname "$0")
SECS=$1; shift
for cfg in "$@"; do
    mode=${cfg%:*}; lead=${cfg#*:}
    "$S/setxp" "$mode" "$lead" >/dev/null
    sleep 1
    start=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== experiment mode $mode (1 late write, 2 at submit), lead $lead, $SECS s"
    "$S/sinetest" "SL 2" 1 1 "$SECS" 128 | grep -E 'RESULT|signal peak|glitch at|level drop' | head -6
    sleep 1
    /usr/bin/log show --start "$start" --style compact --predicate 'subsystem == "com.rane.sl2"' 2>/dev/null \
        | grep -E 'DBG xp' | sed -E 's/.*\] \[SL2\] //'
done
"$S/setxp" 0 >/dev/null
