#!/bin/bash
# usage: logq.sh [minutes] [lines]
M=${1:-30}; N=${2:-300}
/usr/bin/log show --last "${M}m" --style compact \
  --predicate 'subsystem == "com.rane.sl2" OR (process == "coreaudiod" AND (eventMessage CONTAINS[c] "SL 2" OR eventMessage CONTAINS[c] "sl2" OR eventMessage CONTAINS[c] "error" OR eventMessage CONTAINS[c] "fail")) OR (process == "Audio MIDI Setup")' \
  2>&1 | tail -n "$N"
