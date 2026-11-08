#!/bin/bash
# qcompare.sh <seconds> <queue size> <mode:rt>... — one sine test per queue configuration,
# reporting glitches, the thread policy and the driver's timing histograms.
S=$(dirname "$0")
SECS=$1; NXF=$2; shift 2
"$S/setnxf" "$NXF" >/dev/null
for cfg in "$@"; do
    mode=${cfg%:*}; rt=${cfg#*:}
    "$S/setq" "$mode" "$rt" >/dev/null
    sleep 1
    start=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== queue $NXF, mode $mode (0 plain, 1 workloop), realtime $rt, $SECS s"
    "$S/sinetest" "SL 2" 1 1 "$SECS" 128 | grep RESULT
    sleep 1
    /usr/bin/log show --start "$start" --style compact --predicate 'subsystem == "com.rane.sl2"' 2>/dev/null \
        | grep -E 'handler thread|DBG hist|realtime:' | sed -E 's/.*\] \[SL2\] //'
done
