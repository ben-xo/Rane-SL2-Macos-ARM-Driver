# Latency and glitch test tools

These tools measure what a DJ feels: the round trip from a deck input, through the computer, back out to
the deck output, and whether that audio ever breaks up. They were used to take the SL 2 driver's estimated
DVS round trip from ~105 ms to ~15 ms with no glitches under load. See `docs/SL2-AUDIO-ENGINE.md`.

They are written for the SL 2 driver, but they are a model for testing the SL 3 and SL 4 drivers. The
measurement tools work with any CoreAudio device. The scripts take the device name and the driver's log
subsystem from two environment variables:

```
SL_DEVICE="SL 3" SL_LOG_SUBSYSTEM=com.rane.sl3 tools/latency/restartcheck.sh
```

The log lines the scripts look for are the SL 2 driver's, so they need adapting for another driver.

## Setup

1. Build the tools: `make latency` (into `tools/latency/bin/`).
2. Connect a **loopback cable** from Left Deck Out L to Left Deck In L. Use nothing else on that output:
   the tools send clicks and a loud tone into it.
3. Set the input to **LINE**, not phono. A line-level signal into the phono preamp clips, and the glitch
   test then reports a glitch at its first analysed sample.
4. Install the driver build under test: `make plugin && sudo tools/install-sl2.sh`.

## Tools

| Tool | What it does |
|---|---|
| `bin/rtlat <device> <out-ch> <in-ch> [clicks] [buffer]` | Round-trip latency. Plays clicks, finds them in the input, and reports the latency the HAL's timestamps don't account for ("hidden") and the estimated DVS round trip |
| `bin/sinetest <device> <out-ch> <in-ch> <seconds> [buffer]` | Glitch test. Plays a continuous 997 Hz sine and checks every captured sample against the sine recurrence: any dropout, repeat, skip or click breaks it. Analysis starts after the first second |
| `dptest.sh <seconds>` | `sinetest` idle, then with every core busy, plus the driver's counters from its log |
| `restartcheck.sh` | Three streams in a row: each must start cleanly and measure the same latency |
| `bin/chtone <device> <seconds> <ch...>` | A 440 Hz tone on chosen output channels, the way Audio MIDI Setup's test tone plays it |
| `bin/chrec <device> <seconds> <out.wav>` | Starts IO from cold and records the input, reporting when signal first appears and any dropouts |
| `envelope.py <wav>` | Peak level of a `chrec` recording in 100 ms windows |
| `bin/devprobe <device>` | Dumps the HAL properties that output-device pickers check |
| `bin/setrate <device> [rate]` | Prints or sets a device's sample rate |
| `ratetest.sh <device> <rate> <back>` | Speaks a sentence on the device and switches its rate mid-sentence |
| `logq.sh [minutes] [lines]` | The driver's log, with coreaudiod's and Audio MIDI Setup's relevant lines |
| `bin/setinsafe <ms>` | SL 2 debug build only: sets the driver's input safety offset (`sl2h` 0xF2). The HAL reads it only at device setup |

Also in `tools/`: `install-sl2.sh` installs a driver build and restarts coreaudiod and the processes that
go stale when it restarts; `restart-audio.sh` does the restart alone.

## Expected results (SL 2, 44.1 kHz, 128-frame buffer)

- `restartcheck.sh`: three streams, each "DVS round trip est. 18.6 ms (4/4 clicks)".
- `dptest.sh 60`: "0 glitches" idle and loaded.
- With a debug build (`make plugin DEBUG=1`), the `DBG dp` counters in `logq.sh` read: late 0, unscheduled
  flat after start-up, enqueue refused 0, resyncs 0, sent − captured within ±2, rewritten samples 0.
