#!/bin/bash
# ratetest.sh <device-name> <switch-to-rate> <restore-rate>
# Speak a long sentence on the device, switch its rate 2 s in, time how long speech takes.
S=$(dirname "$0")
DEV="$1"; TO="$2"; BACK="$3"
T="this is a rate change test, one two three four five six seven eight nine ten eleven twelve"
# Speak on the device (or the default output, if SAY_DEFAULT is set), switching rate 2 s in.
t0=$(date +%s)
( sleep 2; "$S/bin/setrate" "$DEV" "$TO" ) &
if [ -n "$SAY_DEFAULT" ]; then say "$T"; else say -a "$DEV" "$T"; fi
echo "$DEV: say took $(( $(date +%s) - t0 ))s"
# Wait for the switch, then put the rate back.
wait
"$S/bin/setrate" "$DEV" "$BACK"
