#!/bin/bash
# usage: logq.sh [minutes] [lines]
DEV=${SL_DEVICE:-SL 2}                       # CoreAudio device name, as coreaudiod logs it
SUBSYS=${SL_LOG_SUBSYSTEM:-com.rane.sl2}     # the driver's os_log subsystem
M=${1:-30}; N=${2:-300}
# The driver's log, coreaudiod lines naming the device or an error, and Audio MIDI Setup.
/usr/bin/log show --last "${M}m" --style compact \
  --predicate "subsystem == \"$SUBSYS\" OR (process == \"coreaudiod\" AND (eventMessage CONTAINS[c] \"$DEV\" OR eventMessage CONTAINS[c] \"error\" OR eventMessage CONTAINS[c] \"fail\")) OR (process == \"Audio MIDI Setup\")" \
  2>&1 | tail -n "$N"
