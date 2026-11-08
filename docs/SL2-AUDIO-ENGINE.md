# SL 2 audio engine: low-latency streaming design, measurements and bug catalogue

This document describes how the SL 2 HAL plug-in (`plugin/SL2Device.m`) moves audio between CoreAudio and the
box. It explains why the design looks the way it does, and lists each bug found while building it, with the
symptom, cause, fix and a way to test for it again. The catalogue is written to guide the same work in the
SL 3 and SL 4 drivers, which share this architecture.

## Results

The measurements use a loopback cable from Left Deck Out L to Left Deck In L (line level), 44.1 kHz.

- **Unreported latency** is the delay beyond what the HAL's timestamps account for, found by playing clicks
  and locating them in the captured input (`debug-latency/rtlat.c`).
- **Estimated DVS round trip** adds the HAL's own per-cycle gap (safety offsets and IO buffers). It
  approximates input jack → application → output jack, for an application that responds in the same IO cycle.

| Driver | IO buffer | Unreported latency | Est. DVS round trip | Glitches under load |
|---|---|---|---|---|
| Before this work (`0672a0e`) | 128 frames | 76 ms | ~105 ms | — |
| Shallow queue, aligned timeline, 3 transfers | 128 frames | 4.2 ms | ~32 ms | dropouts about once a minute |
| **Deep schedule with late writes** (this design) | 128 frames | 2.8 ms | **18.6 ms** | **none in 10 min, idle and all cores loaded** |
| Deep schedule, Serato "USB buffer size" 1 ms | ~1 ms | — | **≈15 ms** (calculated) | none heard; driver counters clean |

**Blind test.** Serato DJ was run with real decks and timecode, with USB buffer size at 1 ms. The two builds,
`0672a0e` and the deep-schedule build, were assigned to "A" and "B" at random. The tester judged A "much
laggier" than B, conclusively. A was the old driver.

At the 1 ms buffer setting, the remaining round trip breaks down as:

| Part | Time |
|---|---|
| 2 × IO buffer | ~2 ms |
| input safety offset | 8 ms |
| output safety offset | 2 ms |
| output latency | 1.5 ms |
| the box (FIFO, converters) | ~1.3 ms |

## Background

**The HAL timeline.**
- A HAL plug-in does not push audio on its own schedule. The HAL drives IO and keeps a sample timeline.
- The plug-in's `GetZeroTimeStamp` tells the HAL which host time corresponds to which sample, in periods
  (2048 samples here).
- The HAL expects successive answers to lie on a straight line. If one falls off it, the HAL logs
  `clockResetReason: TimeStampOutOfLine` and resets its clock, which is an audible gap.
- WriteMix gives the driver output audio for timeline positions; ReadInput asks for input at timeline positions.

**USB.**
- The SL 2 is a USB 2.0 high-speed device with isochronous endpoints: OUT 0x06 (asynchronous) and IN 0x82
  (implicit feedback). Both have `wMaxPacketSize` 112, which is 7 frames of 16 bytes per 125 µs microframe.
- The driver uses `IOUSBHostPipe` transaction-list transfers of 8 packets, which is 1 ms each.
- *Implicit feedback* means the box tells the host how many frames to send by how many it sends: OUT
  packet sizes should follow IN packet sizes.

**Completion latency.**
- USB completions are delivered on a dispatch queue in the driver's process. The kernel can hold them for
  5–30 ms before any thread is woken.
- Real-time scheduling cannot be obtained for those threads from user space. `thread_policy_set` is refused
  on GCD threads with `KERN_POLICY_STATIC`, and joining a CoreAudio workgroup is refused for non-real-time
  threads. Even real-time threads see the same delays, because the delay comes before wake-up.
- Any design that must react to a completion within a few ms will drop out under some conditions.

## Design

### 1. Timeline clock (`clk_*`)

- **The timeline is a line:** sample `g_clk_sample` at host time `g_clk_host`, advancing one sample every
  `g_clk_tpf` host ticks.
  - It starts when streaming starts and never jumps.
  - It is published under a sequence lock, because `GetZeroTimeStamp` reads it on the HAL's IO thread.
- **`clk_track` keeps it on the box's clock.** Every 2048 captured frames it re-anchors the line where it is,
  so the line stays continuous. It sets the rate to the box's measured average plus a correction that pulls
  the line onto the box's real captured-frame count over 2 s. The SL 2 tested runs about −105 ppm against
  nominal 44.1 kHz, and the tracker holds the phase error under 2 frames.
- **Times are bus times.**
  - A capture transfer's frame number gives its time on the bus, through a (microframe, host time)
    reference from `currentMicroframeWithTime:`. This is refreshed at most every 0.5 ms and read through a
    bounded sequence lock (`dp_ref_*`).
  - Completion `timeStamp`s are not used. They record when the stack processed the transfer, which can be
    many ms after the bus.
  - The `frameNumberWithTime:` and microframe counters were checked to agree.

### 2. Capture

- **Placement on the timeline:**
  - The first captured frame goes at the timeline position matching its bus time (`g_cap_base`). Every
    later frame follows it contiguously in the input ring.
  - ReadInput reads the ring at the HAL's input sample time.
- **The input safety offset is 8 ms. It was measured, not assumed.**
  - Capture handlers ran at most 1.5 ms after their frame's bus start 99.99% of the time.
  - The worst cases were 5–7.6 ms, and they happened when the Mac was **idle**, not loaded (3.95 ms
    worst under full load).
  - The HAL only reads safety offsets when it sets the device up. Changing them takes a coreaudiod restart.

### 3. Playback: deep schedule with late writes (`dp_*`)

**The approach.**
- 128 transfers of 1 ms are kept queued ahead, in buffers from `-[IOUSBHostObject ioDataWithCapacity:]`,
  zero-filled when submitted.
- WriteMix writes each sample straight into the queued transfer that will carry it, while that transfer is
  still at least 1 ms (`DP_WRITE_GUARD`) from starting.
- Completions only recycle transfers at the far end of the schedule. A completion stall shorter than about
  120 ms costs nothing.

**Why late writes work.**
- The controller reads a transfer's buffer when the transfer starts, not when it is submitted. Apple DTS
  describes this as the intended use of the isochronous API (developer forums thread 853369).
- It was verified on the SL 2: 59,473 transfers were written 1–2 frames before their start, with 0 missed,
  and the tone written into them came through continuously.

**The schedule ring.**
- `g_dp_sched[512]` is indexed by USB frame. For each queued frame it holds the timeline position of its
  first sample, each packet's sample offset, its cumulative sent count and its buffer.
- An entry is published, with its frame number as a sequence-lock tag, only after its enqueue succeeds.
- WriteMix finds a sample's frame by estimating from the **newest published frame** (`g_dp_newest`) and
  stepping. It takes no locks and makes no IOKit calls.

**Timing budget.**
- A schedule's first frame (`dp_anchor`) carries the timeline position `DP_OUT_LATENCY_MS` (1.5 ms) before
  that frame's start. Every sample then plays 1.5 ms after its timeline position.
- The HAL writes each sample `DP_OUT_SAFETY_MS` (2 ms) ahead of "now". A sample's frame starts at least
  0.5 ms after the sample's position.
- So the write happens at least 2.5 ms before its frame starts. 1 ms of that is the guard, and 1.5 ms is
  margin for a late IO thread.

**Packet sizes.**
- Sizes are fixed when a transfer is queued, about 128 ms before it plays, so they cannot be copied from
  capture packets.
- They are predicted from the clock tracker's rate and steered so that the cumulative frames sent through
  each USB frame equal the cumulative frames captured through it (`dp_track_capture`, over about 1 s).
- Errored capture packets count at the last good size.
- The SL 2 accepts predicted sizes. The sent − captured difference stays within ±2 frames.

**Refusals and recovery.**
- A refused enqueue publishes nothing. Its timeline positions move to the next frame, so the audio stays
  continuous, and it is not counted as sent, so the steering makes up the frames the box missed.
- A slot is never lost: after 4 refusals it is retried 2 ms later.
- If the schedule runs dry, it re-anchors 8 frames ahead of the bus (`DP_START_LEAD`). That only happens
  when it reaches less than 4 frames ahead (`DP_DRY_LEAD`), meaning a stall longer than the schedule.

**Several clients.**
- When a second application plays to the device, the HAL calls WriteMix from more than one IO thread in
  turn. The calls never overlap and never repeat a timeline position: each carries the full mix for its
  stretch.
- So WriteMix overwrites; it does not mix. This was measured with Serato and a second client playing
  together, and both were heard.

**Stream stop.**
- `dp_stop` switches the schedule off and waits for any WriteMix still inside `dp_write`.
- `dp_release` then frees the buffers, after the pipes are aborted. The buffers keep the playback
  interface claimed until they are freed.

### 4. Reported properties

| Property | Value |
|---|---|
| Output device latency | 1.5 ms (66 frames at 44.1 kHz) |
| Output safety offset | 2 ms |
| Input device latency | 32 frames |
| Input safety offset | 8 ms |
| Stream latency, in and out | 32 frames each |

Clients add device and stream latency, so the reported total is 66 + 32 + 32 + 32 = 162 frames, or 3.67 ms.
That matches the 3.7 ms of hidden latency measured on the loopback, before input moved to bus time.

### 5. Sample-rate changes

- Rates change through `RequestDeviceConfigurationChange` / `PerformDeviceConfigurationChange`.
- `0x31` from a client over `sl2h` is routed the same way.
- The zero-timestamp seed is bumped, so the HAL resyncs.

## Platform facts worth knowing

- Real-time priority for USB completion threads is not available from user space, and would not help anyway.
- Completion delivery stalls happen about once a minute, of 5–11 ms, and they are worst when the Mac is idle.
- `ioDataWithCapacity:` buffers keep their interface claimed. Release them before the next stream claims it.
- The HAL reads safety offsets only at device setup. Neither `PropertiesChanged` nor a no-op configuration
  change refreshes them.
- An isochronous transfer scheduled 4 frames ahead was refused (`0xe00002ee`) on an M-series Mac. Start 8 ahead.
- Capture completions are stamped about 0.9 ms into their frame (the last packet is microframe 7, at
  0.875 ms), so the stack stamps at the bus. Only delivery to the handler is delayed.
- After `killall coreaudiod`, some long-running processes keep stale state:
  - QuickLookUIService and AirPlayXPCHelper ignore SIGTERM and need `kill -9`.
  - Control Center drops the device from its menu until it is restarted.

  `debug-latency/install-sl2.sh` handles this.

## Bug catalogue

Each entry: symptom → cause → fix → how to test for it again → commit. **Applies to SL 3/SL 4** marks bugs
that come from shared code or a shared design.

1. **48 kHz falls back to 44.1 kHz and plays sharp.**
   - Cause: the rate setters changed the driver and the box without telling the HAL, which kept its cached
     rate.
   - Fix: the configuration-change handshake.
   - Test: select 48 kHz while playing; pitch must be right and the menu must stay at 48 kHz.
   - `0bee6e0`. Applies to SL 3/SL 4.
2. **Gap after the first buffer of every playback.**
   - Cause: the timeline anchor was moved to the first capture packet about 33 ms after IO began, so the
     HAL saw its timestamps jump (`TimeStampOutOfLine`).
   - Fix: the anchor stays fixed per stream, and capture is placed on the timeline.
   - Test: play from cold; no gap, and no `TimeStampOutOfLine` in coreaudiod's log.
   - `0672a0e`. Applies to SL 3/SL 4.
3. **About 56 ms of hidden output latency.**
   - Cause: the playback reader started from ring position 0, while the HAL was already writing at its
     current timeline position, which was 56 ms on by the time playback started.
   - Fix: the reader starts at the matching timeline position. This is superseded by the deep schedule,
     which places samples by timeline position directly.
   - Test: loopback round trip (`rtlat`).
   - `0a1f064`. Applies to SL 3/SL 4.
4. **The timeline drifts against the box.**
   - Cause: `ticks_per_frame` was a slow moving average applied to the whole elapsed time, so each update
     rescaled the past and slid the timeline against the box's frame count.
   - Fix: the `clk_track` re-anchoring loop.
   - Test: reader position against timeline stays constant over minutes, and `DBG clk` phase error stays
     under 2 frames.
   - `243583a`. Applies to SL 3/SL 4.
5. **Reported latency was wrong.**
   - Cause: the driver reported 32 frames of output latency and a 64-frame safety offset, regardless of the
     real figures.
   - Fix: report the real output latency and safety offset.
   - Test: hidden latency in `rtlat` against the reported total.
   - `0a1f064`.
6. **Silence for the rest of the stream after a playback restart.**
   - Cause: the restart recomputed the reader base without subtracting the frames already played.
   - Fix: subtract them. The restart path was removed with the deep schedule.
   - `23f4ede`.
7. **Dropouts about once a minute with a shallow playback queue.**
   - Cause: a completion stall longer than the queue lead meant the next transfer's frame had passed. The
     enqueue was refused and that transfer chain ended.
   - Fix: the deep schedule. Interim mitigations (skip ahead, retry) are in `23f4ede`.
   - Test: `sinetest` for 5 min idle and loaded.
   - `fa4b4d0`. Applies to SL 3/SL 4.
8. **Input safety offset was 20 ms on a wrong premise.**
   - Cause: it was based on the belief that capture completions arrive 10–20 ms late. Measured from bus
     time, 99.99% arrive within 1.5 ms and the worst is about 7.6 ms.
   - Fix: 8 ms.
   - `fa4b4d0` (20 → 4 ms), `1168377` (measurement), `a91aad6` (8 ms).
9. **The second stream fails with "Failed to claim Play/Cap interfaces".**
   - Cause: `ioDataWithCapacity:` buffers outlived the stream and kept the interface claimed.
   - Fix: release them at stream stop, after waiting for WriteMix to leave the schedule.
   - Test: three streams in a row (`restartcheck.sh`).
   - `96866aa`.
10. **The first transfer was refused at +4 frames.**
    - Fix: start at +8.
    - Test: no `enqueue refused` at stream start.
    - `0022ccb`.
11. **Playback goes silent after about 50 s.**
    - Cause: WriteMix estimated a sample's frame from the stream start at the nominal rate, which drifted
      about 0.1 frame/s at −105 ppm until the bounded search missed.
    - Fix: estimate from a recent frame.
    - Test: `sinetest` for over 2 min; `unscheduled` stays flat.
    - `8a05f12`.
12. **Frames never sent were counted as sent, and slots could be lost.**
    - Cause: a refused frame's positions and count were committed before the enqueue. Three refusals ended
      a slot permanently.
    - Fix: publish after success, roll positions forward, retry later.
    - `7341046`.
13. **The schedule ring was not a correct sequence lock.** The IO thread could also spin on a preempted
    writer.
    - Fix: proper writer and reader fences, a re-check of the tag, and bounded readers with a last-good
      fallback.
    - `fd08549`.
14. **The schedule was too short for large IO buffers.**
    - Cause: the HAL writes about `2 × buffer + safety` ahead, and 64 ms did not cover large buffers during
      stalls.
    - Fix: 128 transfers.
    - `e33861e`.
15. **Capture timing came from completion stamps.**
    - Cause: completion stamps include the stack's hold, which skewed the clock and the delay measurements.
    - Fix: bus time from the microframe reference.
    - `dbacee9`.
16. **Errored capture packets biased the steering.**
    - Cause: they added nothing to the captured count, which lowered the output rate target and drained the
      box's FIFO.
    - Fix: count them at the last good size.
    - `3c7e6a6`.
17. **Every stream re-anchored immediately.**
    - Cause: the dry-schedule threshold equalled the start lead.
    - Fix: a separate `DP_DRY_LEAD` of 4.
    - Test: `resyncs 0` at stream start.
    - `19b5328`.
18. **A second application's audio was dropped.**
    - Cause: a new HAL IO thread, started when another client began playing, seeded its frame estimate from
      the stream start. 13 minutes in, that was about 80 frames off.
    - Fix: estimate from the newest published frame.
    - Test: stream for several minutes, then play a second client; `unscheduled` stays at 0.
    - `90025d8`.

## Testing

The tools are in `debug-latency/`. Build each with `clang -O2 -framework CoreAudio -framework CoreFoundation X.c -o X`.

| Tool | What it does |
|---|---|
| `rtlat` | Round-trip latency through a loopback cable: hidden latency and estimated DVS round trip |
| `sinetest` | Plays a continuous 997 Hz sine through the loopback for N seconds. Flags any break in the sine recurrence (dropout, repeat, skip) and any drop in level |
| `dptest.sh` | `sinetest` for N s idle, then with every core busy, with the driver's counters |
| `restartcheck.sh` | Three streams in a row; each must start the deep schedule |
| `chtone`, `chrec` | Tone on chosen channels, and cold-start capture to WAV |
| `install-sl2.sh` | Installs a build and restarts coreaudiod and the processes that go stale |

**Debug build.** `make plugin DEBUG=1` defines `SL2_DEBUG`, which compiles in the streaming diagnostics
(counters, the capture timing histogram, the WriteMix calling-pattern check) and one debug command. A plain
`make plugin` builds none of it and logs only stream start/stop and errors. Both builds play through the
deep schedule.

**Superseded code, kept in history.** The shallow-queue playback path is in the history up to `c30df0d`,
selectable there with `sl2h` 0xF4 in a debug build, along with its queue-size command (0xF0) and sweep
scripts. The late-write experiment is in `d470c7e`, and the workloop / real-time attempts are in `10c1d87`.
Each was removed from the tip in its own commit.

**Driver counters.** The debug build logs `DBG dp` every ~2 s and a result line at stream stop. They should read:
- `late 0`;
- `unscheduled` flat after start-up;
- `enqueue refused 0`;
- `resyncs 0`;
- sent − captured within ±2;
- `rewritten samples 0`;
- `capture packet errors` rarely above 0.

The debug build's one control is `sl2h` command byte 0xF2 (`setinsafe`), intercepted by the driver and never
sent to the box. It sets the input safety offset, but the HAL reads safety offsets only at device setup, so
it only takes effect for a device that is set up again.

## Still open

- Possibly lowering the input safety offset further. Capture data is written to memory on time and only the
  completion is late, so a real-time thread could detect it by marking each capture buffer's padding bytes.
  Untested.
