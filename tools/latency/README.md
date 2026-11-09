# Latency and glitch test tools

These tools measure what a DJ feels: the round trip from a deck input, through the computer, back out to
the deck output, and whether that audio ever breaks up. They were used to take the SL 2 driver's estimated
DVS round trip from ~105 ms to 18.6 ms measured at a 128-frame IO buffer (≈15 ms calculated at Serato's
1 ms USB buffer setting), with no glitches under load. See `docs/SL2-AUDIO-ENGINE.md`.

They are written for the SL 2 driver, but they are a model for testing the SL 3 and SL 4 drivers. The
measurement tools work with any CoreAudio device. `dptest.sh`, `restartcheck.sh` and `logq.sh` take the
device name and the driver's log subsystem from two environment variables (the other tools take the device
name as an argument):

```
SL_DEVICE="SL 3" SL_LOG_SUBSYSTEM=com.rane.sl3 tools/latency/restartcheck.sh
```

The log lines the scripts look for are the SL 2 driver's, so they need adapting for another driver.

## Setup

1. Build the tools: `make latency` (into `tools/latency/bin/`).
2. Connect a **loopback cable** from Left Deck Out L to Left Deck In L. Use nothing else on that output:
   the tools send clicks and a loud tone into it.
3. Set the box's LINE/PHONO switch to **LINE**. A line-level signal into the phono preamp clips, and the
   glitch test then reports a glitch at its first analysed sample.
4. Install the driver build under test: `make plugin && sudo tools/install-sl2.sh` (add `DEBUG=1` for the
   driver's counters and `sl2dbg`). The script replaces the binary inside the installed driver, so the
   release package (`Installer/RaneSL2-macOS-Universal.pkg`) must be installed first. `--api` also installs
   a built SL2Api (`make api`), saving the previous one; `--restore-api` puts that back.

## Running everything

`make hwtest` runs the SL 2's hardware tests in one go (`tools/hwtest.sh`) and ends with a PASS / FAIL /
SKIP summary; the full output goes to a log file it names. It runs them in the order that needs the
fewest physical steps:

1. with only the box attached: the driver's status, SL2Api as Serato DJ Pro 2.5.5 calls it (`sl2apitest`,
   both slices), and sample-rate switching;
2. with `ARGS="--loopback"`, which says the loopback cable is in (the tests play clicks and a loud tone
   into Left Deck Out): `restartcheck.sh`, a 30 s glitch test, 48 kHz, and with a debug build `dptest.sh`
   and the `sl2dbg` fault hooks (a USB stall, errored capture packets);
3. steps for someone at the box: flipping the LINE/PHONO switch, and unplugging and replugging while idle
   and while a (silent) stream runs. The script prints each step and waits until it sees the change, so
   nothing needs typing. `ARGS="--no-physical"` skips them.

Run it in a Terminal window, so the steps show as they come up. A release build skips the tests that
need the debug build's counters and hooks; run it again with a debug build to cover those.

## Tools

| Tool | What it does | Pass |
|---|---|---|
| `bin/rtlat <device> <out-ch> <in-ch> [clicks] [buffer]` | Round-trip latency. Plays clicks, finds them in the input, and reports the latency the HAL's timestamps don't account for ("hidden") and the estimated DVS round trip | every click found; hidden latency close to the driver's reported total |
| `bin/sinetest <device> <out-ch> <in-ch> <seconds> [buffer]` | Glitch test. Plays a continuous 997 Hz sine and checks every captured sample against the sine recurrence: any dropout, repeat, skip or click breaks it. Analysis starts after the first second | "0 glitches, 0 level drops" |
| `dptest.sh <seconds>` | `sinetest` idle, then with every core busy, plus the driver's counters from its log (debug build) | prints PASS |
| `restartcheck.sh` | Three streams in a row: each must start cleanly and find all its clicks | prints PASS |
| `bin/sl2dbg insafe <ms> \| stall <ms> \| errpkts <n>` | Debug build only: the input safety offset (the HAL reads it only at device setup), and test hooks that stall the driver's USB queue or error capture packets on demand | — |
| `bin/chtone <device> <seconds> <ch...>` | A 440 Hz tone on chosen output channels, the way Audio MIDI Setup's test tone plays it | heard on each channel |
| `bin/chrec <device> <seconds> <out.wav>` | Starts IO from cold and records the input, reporting when signal first appears and any dropouts | no dropouts |
| `envelope.py <wav>` | Peak level of a `chrec` recording in 100 ms windows | — |
| `bin/devprobe <device>` | Dumps the HAL properties that output-device pickers check | — |
| `bin/setrate <device> [rate]` | Prints or sets a device's sample rate | — |
| `ratetest.sh <device> <rate> <back>` | Speaks a sentence on the device and switches its rate mid-sentence | speech continues at the right pitch |
| `logq.sh [minutes] [lines]` | The driver's log, with coreaudiod's and Audio MIDI Setup's relevant lines | — |

Also in `tools/`: `install-sl2.sh` installs a driver build and restarts coreaudiod and the processes that
go stale when it restarts; `restart-audio.sh` does the restart alone.

## Expected results (SL 2, 44.1 kHz, 128-frame buffer)

- `restartcheck.sh`: three streams, each "DVS round trip est. 18.6 ms (4/4 clicks)", then PASS.
- `dptest.sh 60` (debug build): "0 glitches" idle and loaded, then PASS.
- The debug build's `DBG dp` counters (`logq.sh`): late 0, unscheduled flat after start-up, enqueue refused
  0, resyncs 0, sent − captured within ±2, rewritten samples 0.
- `sl2dbg stall 100` during a `sinetest`: one gap, shorter than the stall (the 64 one-millisecond capture
  transfers already queued keep receiving audio, so only the rest is lost: about 40 ms for a 100 ms stall),
  the driver logs "Capture: N ms not captured", and the stream carries on. `sl2dbg errpkts 20`: a gap of about 3 ms, sent − captured within ±2.
