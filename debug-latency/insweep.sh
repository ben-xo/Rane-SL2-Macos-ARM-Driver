#!/bin/bash
# insweep.sh <seconds> <queue size> <input safety ms...> — for each input safety offset:
# round-trip latency, then a sine glitch test (which also catches input read before it was written).
S=$(dirname "$0")
SECS=$1; NXF=$2; shift 2
"$S/setnxf" "$NXF" >/dev/null
"$S/setq" 1 0 >/dev/null
for ms in "$@"; do
    "$S/setinsafe" "$ms" >/dev/null
    sleep 1
    echo "=== queue $NXF, input safety $ms ms"
    "$S/rtlat" "SL 2" 1 1 4 128 | grep -E 'cycle gap|mean|not found' | head -2
    "$S/sinetest" "SL 2" 1 1 "$SECS" 128 | grep -E 'RESULT|glitch at|level drop' | head -6
done
