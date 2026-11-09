# SL 2 audio engine: low-latency streaming design, measurements and bug catalogue

This document describes how the SL 2 HAL plug-in (`plugin/SL2Device.m`) moves audio between CoreAudio and the
box, and how it handles the box coming and going and talking to clients (Serato, Rane's control panel). It
explains why the design looks the way it does, and lists each bug found while building it, with the symptom,
cause, fix and a way to test for it again. The catalogue is written to guide the same work in the SL 3 and
SL 4 drivers, which share much of this architecture.

> **Fixing a playback or capture bug? Start here.**
> 1. Build and install a debug driver: `make install DEBUG=1`, and the test tools:
>    `make latency`.
> 2. Connect a loopback cable from Left Deck Out L to Left Deck In L, with the LINE/PHONO switch on **LINE**
>    (`tools/latency/README.md`).
> 3. Run `tools/latency/restartcheck.sh` and `tools/latency/dptest.sh 60`. Both print PASS or FAIL. The driver's
>    counters should read as in [Testing](#testing).
> 4. Reproduce stalls and errors on demand with `tools/latency/bin/sl2dbg` (stall the USB queue, error capture
>    packets), and read the driver's log with `tools/latency/logq.sh`.
> 5. The [bug catalogue](#bug-catalogue) gives each past bug's symptom and regression test.

> **Porting these fixes to the SL 3 / SL 4?** See [Porting](#porting-to-the-sl-3--sl-4) for which fixes apply
> directly, which only with the deep-schedule design, and which are SL 2 only.

## Results

The measurements use a loopback cable from Left Deck Out L to Left Deck In L (line level), at 44.1 kHz
unless noted.

- **Unreported latency** is the delay beyond what the HAL's timestamps account for, found by playing clicks
  and locating them in the captured input (`tools/latency/rtlat.c`).
- **Estimated DVS round trip** adds the HAL's own per-cycle gap (safety offsets and IO buffers). It
  approximates input jack → application → output jack, for an application that responds in the same IO cycle.

| Driver | IO buffer | Unreported latency | Est. DVS round trip | Glitches under load |
|---|---|---|---|---|
| Baseline (`0672a0e`, before the latency work) | 128 frames | 76 ms | ~105 ms | — |
| Shallow queue, aligned timeline, 3 transfers | 128 frames | 4.2 ms | ~32 ms | dropouts about once a minute |
| **Deep schedule with late writes** (this design), measured | 128 frames | 2.8 ms | **18.6 ms** | **none in 10 min, idle and all cores loaded** |
| Deep schedule, 48 kHz, release build | 128 frames | 2.7 ms | **18.0 ms** | none in a 10 s check, idle |
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
  (16384 samples here; `AudioServerPlugIn.h` requires at least 10923).
- The HAL expects successive answers to lie on a straight line. If one falls off it, the HAL logs
  `clockResetReason: TimeStampOutOfLine` and resets its clock, which is an audible gap.
- WriteMix gives the driver output audio for timeline positions; ReadInput asks for input at timeline positions.

**USB.**
- The SL 2 is a USB 2.0 high-speed device with isochronous endpoints: OUT 0x06 (asynchronous) and IN 0x82
  (implicit feedback). Both have `wMaxPacketSize` 112, which is 7 frames of 16 bytes per 125 µs microframe.
  On a full-speed (USB 1.1) link the box offers only its HID interface, and there is no audio.
- The driver uses `IOUSBHostPipe` transaction-list transfers of 8 packets, which is 1 ms each.
- *Implicit feedback* means the box tells the host how many frames to send by how many it sends: OUT
  packet sizes should follow IN packet sizes.

**Completion latency.**
- USB completions are delivered on a dispatch queue in the driver's process. The kernel can hold them before
  any thread is woken: stalls of 5–11 ms about once a minute were measured here, and other projects report
  up to 30 ms under load.
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
    Readers on the IO thread are bounded: after 64 tries they use the last good copy rather than spin.
- **`clk_track` keeps it on the box's clock.** Every 2048 captured frames it re-anchors the line where it is,
  so the line stays continuous. It sets the rate to the box's measured average plus a correction that pulls
  the line onto the box's real captured-frame count over 2 s. The SL 2 tested runs about −105 ppm against
  nominal 44.1 kHz, and the tracker holds the phase error under 2 frames.
- **Times are bus times.**
  - A capture transfer's frame number gives its time on the bus, through a (microframe, host time)
    reference from `currentMicroframeWithTime:`. This is refreshed at most every 0.5 ms and read through a
    bounded sequence lock (`dp_ref_*`; `usb_frame_time` and `dp_frame_at` convert both ways).
  - Completion `timeStamp`s are not used. They record when the stack processed the transfer, which can be
    many ms after the bus.
  - The `frameNumberWithTime:` and microframe counters were checked to agree.

### 2. Capture

- **Placement on the timeline:**
  - The first captured frame goes at the timeline position matching its bus time (`g_cap_base`). Every
    later frame follows it contiguously in the input ring.
  - Capture publishes how far it has written (`g_cap_head`). ReadInput reads the ring at the HAL's input
    sample time, and returns silence for any position capture has not written yet, or wrote so long ago that
    the ring may have wrapped over it. A late capture therefore costs a short gap, never old audio.
- **Frames the host doesn't receive are filled with silence.** The box clocks a frame of audio whether or not
  the host gets it. An errored packet, or USB frames with no capture request queued (see below), are filled
  with silence at the box's measured rate (carrying the fraction of a frame to the next fill) and counted as
  captured. The ring, the clock tracker and the playback steering then all count what the box clocked.
- **Capture survives a long completion stall.** Each of the 64 capture transfers is re-queued from its own
  completion. After a stall longer than 64 ms, the next frame has passed: the request is re-anchored
  `DP_START_LEAD` frames ahead of the bus, and the frames skipped are filled when the next completion
  arrives (logged as "Capture: N ms not captured").
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
  still at least 1 USB frame (1 ms, `DP_WRITE_GUARD_FRAMES`) from starting.
- Completions only queue new transfers at the far end of the schedule. So a stall in completion delivery does
  not interrupt the audio unless it outlasts the queue: about 120 ms at small IO buffers (the 128 ms queued,
  less how far ahead the HAL writes, about two IO buffers plus the safety offset).

**Why late writes work.**
- The controller reads a transfer's buffer when the transfer starts, not when it is submitted. Apple DTS
  describes this as the intended use of the isochronous API (developer forums thread 853369), while noting
  that exactly when a controller reads the buffer is implementation-specific.
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
- The HAL writes each sample `DP_OUT_SAFETY_MS` (2 ms) ahead of "now". Together these 3.5 ms cover the up-to-
  1 ms span of positions within a frame plus the 1 ms guard, leaving 1.5 ms of margin for a late IO thread.

**Packet sizes.**
- Sizes are fixed when a transfer is queued, about 128 ms before it plays, so they cannot be copied from
  capture packets.
- They are predicted from the clock tracker's rate and steered so that the cumulative frames sent through
  each USB frame equal the cumulative frames captured through it (`dp_track_capture`, over about 1 s). The
  captured count includes silence-filled frames (see Capture).
- The SL 2 accepts predicted sizes. The sent − captured difference stays within ±2 frames.

**Refusals and recovery.**
- A refused enqueue publishes nothing. Its timeline positions move to the next frame, so the audio stays
  continuous, and it is not counted as sent, so the steering makes up the frames the box missed.
- A slot is never lost: after 4 refusals it is retried 2 ms later.
- If the schedule runs dry, it re-anchors 8 frames ahead of the bus (`DP_START_LEAD`). That only happens
  when it reaches less than 4 frames ahead (`DP_DRY_LEAD`), after a stall of nearly the schedule's length.

**Several clients.**
- When a second application plays to the device, the HAL calls WriteMix from more than one IO thread in
  turn. The calls never overlap and never repeat a timeline position: each carries the full mix for its
  stretch.
- So WriteMix overwrites; it does not mix. This was measured with Serato and a second client playing
  together, and both were heard.

**Stream start and stop.**
- Each stream has a generation number (`g_stream_gen`), bumped when it starts and when it stops. Every USB
  completion and retry carries the generation it was queued in and does nothing once it has moved on, so
  work left over from a stopped stream never touches the next one.
- `dp_stop` switches the schedule off and waits for any WriteMix still inside `dp_write`.
- `usb_release_audio` aborts the pipes, then frees the buffers and pipes **on the USB queue**
  (`dispatch_sync`), so no completion handler is still using them, then puts the interfaces back to
  alternate setting 0 and destroys them. The buffers keep the playback interface claimed until they are
  freed. Every failure path of `usb_open_all` uses the same function.

### 4. Reported properties

| Property | Value |
|---|---|
| Output device latency | 1.5 ms (66 frames at 44.1 kHz) |
| Output safety offset | 2 ms |
| Input device latency | 32 frames |
| Input safety offset | 8 ms |
| Output stream latency | 32 frames |
| Input stream latency | 0 |
| Zero-timestamp period | 16384 frames |

Clients add device and stream latency, so the reported total is 66 + 32 + 32 + 0 = 130 frames, or 2.95 ms.
The loopback measures 2.8 ms (`rtlat`'s unreported latency, since input moved to bus time): the report is
within 0.15 ms, on the safe side. Most of the 2.8 ms is fixed by design (the 1.5 ms output latency) or by
the box's converters and buffers, so it should not vary between Macs; a different USB controller might
shift it slightly. Only 44.1 kHz has been measured.

### 4a. Output volume (`vol_*`)

The SL 2 has no volume control of its own. No HID command sets a level, and the FPGA that carries the
audio gets no level from the host: after configuring it, the firmware only ever sends it one constant
word, when the LINE/PHONO switch moves. Rane's own driver had none either; its volume hooks were empty.
So the driver scales the samples itself: a master **Output Volume** and **Output Mute**, which the
menu-bar slider and the volume keys use, and a **volume for each output channel**, shown per channel
in Audio MIDI Setup. All run from −64 to 0 dB, with the bottom silent. The slider follows CoreAudio's
standard volume curve (its "2 over 1" transfer function: the slider position is the square of the
level's position in the dB range), as the Mac's built-in output and Apple-driven USB interfaces do, so
half-way is about −19 dB and each volume-key step is about 2 dB near the top and 3 dB around the middle.
The steps get coarser towards the bottom, where the last one goes from −48 dB to silence, as on the
Mac's own outputs.
A channel's gain is the master's times its own. The master is needed: without one, the HAL's virtual
main volume (the volume keys) moves only the preferred stereo pair, channels 1–2, because the four
channels are discrete rather than a speaker layout it could follow, so the keys would turn down one
deck and not the other.

- **Where:** in `ProcessMix`, which the HAL calls in place on the mix of all its clients, in the same IO
  cycle, just before WriteMix. It adds no buffering and moves no timing; the deep schedule, the reported
  latencies and the safety offsets are unchanged. At 0 dB, unmuted, no sample is touched. A change of
  level ramps at a fixed rate (5 ms for the full range, across IO cycles if need be), so a step doesn't
  click at any buffer size; a stream starts at the current level.
- **Every client follows it, Serato included**, so turning the volume down while Serato plays turns down
  the decks' output to the mixer. Like any device's, the volume and mute are remembered: the HAL saves
  them and sets them again when the device reappears (after a replug or a restart of coreaudiod). The
  driver keeps them only in memory.

Measured through the loopback cable (44.1 kHz, 128-frame buffer): clicks drop by exactly the volume
(−20.0 dB at −20 dB), whether set on the channel or with the volume keys (which set the master and
leave the channels' own levels), a level set on another channel leaves them alone, and they are gone
when muted. The DVS round trip at 0 dB is 18.6 ms, the
same as without the volume control. `rtlat` reads quieter clicks one to three frames later, but a click at half
amplitude reads the same with no volume applied: its fixed detection threshold is crossed by the
converters' pre-ringing, which is smaller on a quieter click. It is not latency.

### 5. Sample-rate changes

- Rates change through `RequestDeviceConfigurationChange` / `PerformDeviceConfigurationChange`.
- `0x31` from a client over `sl2h` to the other supported rate is routed the same way: the box only gets it
  from Perform, so the HAL's rate and the box's change together.
- The zero-timestamp seed is bumped, so the HAL resyncs.

### 6. Connect, disconnect and status

- **The device is listed only while a box is attached.** The plug-in's device list, owned objects and UID
  lookup include the device only then, and `PropertiesChanged` tells the HAL when that changes. A box in its
  USB bootloader keeps the device listed, so clients can read `boot_mode` from the status.
- **Opening the box at connect.** `connect_box` opens the device once and keeps it; if its HID interface is
  not registered yet (interfaces appear asynchronously after configuring), it looks again, every 100 ms for
  up to a second. The first open is occasionally refused while macOS is still setting the box up.
- **At connect, with nothing streaming,** the decks are put on analogue thru (the box powers up with thru on
  or off depending on a board input), and the box is given the driver's sample rate (it powers up at
  44.1 kHz). The link speed is checked: at full speed the log says so.
- **Status.** At open the driver enables the box's unsolicited reports (`0x36`) and asks for a state dump
  (`0x41` SysEx `F0 17 04 F7`). The reports give each deck's thru state and the LINE/PHONO switch (one
  physical switch for both decks, note `0x61`, On = phono), which the `sl2s` status carries.
- **Unplugging while streaming.** The stream stops (nothing is sent to the box), and the client count is
  reset: the device leaves the HAL's list, and a client using it again after a replug sends a new StartIO.
  Observed: the HAL does send a StopIO shortly after the device disappears; it is logged and ignored.
- **StartIO fails** (`kAudioHardwareNotRunningError`) when the box can't be opened, rather than running a
  timeline with no box behind it.

### 7. The HID path for clients (`sl2h`, `sl2s`, `sl2q`, `sl2m`)

- **`sl2h`:** writing a 64-byte command sends it to the box and keeps the reply for the calling process; the
  next read returns it once, and a read never sends anything. The driver tags each request with its own
  sequence number and puts the client's tag back in the reply. Every command waits for its reply except
  `0x06`, which gets none; a reply of `0xFF` with the request's tag means the box refused the command.
  No opcode is blocked (Rane's software has no explicit gate either), so EEPROM-writing commands can be sent:
  see `docs/SL2-COMMANDS.md`.
- **`sl2q`:** the box's unsolicited `0x40` reports and the driver's own events (`0x4F`: sample rate), kept
  in a ring of 256 with a read position per client process, so every client gets every report.
- **`sl2s`:** the status (connected, streaming, rate, version, serial, thru and LINE/PHONO, frame counts,
  boot mode). Reading it has no side effects.
- **`sl2m`:** level meters for the control panel: the peak level (0–1) of each input channel as captured and
  each output channel as sent (after the volume) since the last read, which resets them. The driver
  measures only while some client has read them in the last second, so they cost nothing otherwise. There
  is one set, so two clients reading at once share the peaks between them. They move only while a stream
  runs: with no app using the SL 2 the decks are on thru and the box sends no audio.
- **No heartbeat.** The driver doesn't send `0x37`: the firmware doesn't check for it, and a 45 s loopback
  test with no `0x37` at all passed with full level and no glitches. It is sent only when a client asks
  (Serato's hardware check, below).

### 8. SL2Api (`tools/SL2Api.m`)

- A replacement for Rane's `SL2Api.framework`, the library Serato DJ Pro 2.5.5 and Rane's "SL 2 Audio Control
  Panel" load. Newer Serato versions don't load it.
- Every exported function matches Rane's (compared with its disassembly) in arguments, results and return
  codes (12 not connected, 8 bad handle or argument, 4 no reply). Serato 2.5.5 imports seven: `SL2_open`,
  `SL2_close`, `SL2_driver_timer` (its genuine-hardware check: `0x37` challenge and answer),
  `SL2_get_usb_port_status`, `SL2_get_all_controls` (the state dump), `SL2_send_hidimsg` (per-deck thru),
  `SL2_set_hidimsg_callback`.
- Reports are polled from `sl2q` every 15 ms and passed to the client's callbacks on SL2Api's own queue.
  SL2Api notices the box coming and going itself and calls the port-status callback with `{1, 0}` / `{0, 0}`.
- Firmware update is deliberately not implemented (the functions are no-ops), and `SL2_is_C0_device` stays 0,
  so the control panel never starts an automatic update. `tools/firmware/` does that with safeguards.
- Every exported call is logged at debug level with its result, the challenge and answer, and the Hidi
  bytes sent and received: `log stream --level debug --predicate 'subsystem == "com.rane.sl2api"'`.
- `sl2apitest` (`make apitest`) loads the framework from the path Serato 2.5.5 uses and checks the seven
  calls as Serato makes them: the hardware-check answer, the state dump through the callback, and each
  deck's thru switched and restored. Serato 2.5.5 is Intel-only, so run it as `arch -x86_64 ./sl2apitest`
  as well as natively.
- Tested with Rane's control panel, `sl2apitest` (both slices), and Serato DJ Pro 2.5.5 with turntables on
  macOS 27: the hardware check passes, Rel/Abs are unlocked, thru switches per deck, and an unplug and
  replug is picked up again.

## Platform facts worth knowing

- Real-time priority for USB completion threads is not available from user space, and would not help anyway.
- Completion delivery stalls happen about once a minute, of 5–11 ms, and they are worst when the Mac is idle.
- `ioDataWithCapacity:` buffers keep their interface claimed. Release them before the next stream claims it.
- The HAL reads safety offsets only at device setup. Neither `PropertiesChanged` nor a no-op configuration
  change refreshes them.
- An isochronous transfer scheduled 4 frames ahead was refused (`0xe00002ee`) on an M-series Mac. Start 8 ahead.
- Capture completions are stamped about 0.9 ms into their frame (the last packet is microframe 7, at
  0.875 ms), so the stack stamps at the bus. Only delivery to the handler is delayed.
- When a device disappears while a client streams, the HAL sends that client's StopIO afterwards.
- A HAL client's property query can be answered by the HAL from its own model of the device without reaching
  the plug-in (e.g. `OwnedObjects` with a class qualifier).
- After `killall coreaudiod`, some long-running processes keep stale state:
  - QuickLookUIService and AirPlayXPCHelper ignore SIGTERM and need `kill -9`.
  - Control Center drops the device from its menu until it is restarted.

  `tools/install-sl2.sh` handles this.

## Porting to the SL 3 / SL 4

Entries refer to the [bug catalogue](#bug-catalogue).

| Applies | Entries |
|---|---|
| **Directly**: shared code or a shared HAL/USB pattern | 1 sample-rate handshake; 2 fixed timeline anchor; 4 clock tracking; 5, 31 reporting real latency (measure with `rtlat`); 15 bus time; 19, 20 capture gaps filled with silence; 21 ReadInput's write head; 22, 23 teardown on the USB queue and stream generations; 24, 25 failed opens and unplug while streaming; 26 opening at connect; 27 property buffer sizes; 28 the `sl2h` passthrough; 30 the zero-timestamp period; 39 the status frame count; 35 device listed only while attached; 38 retry a refused first open |
| **With the deep schedule** (late writes into queued transfers) | 7, 9, 10, 11, 12, 13, 14, 16, 17, 18 |
| **SL 2 only, or check on the SL 3/SL 4 first** | 8 input safety value (measure); 29 the heartbeat (check the SL 3/SL 4 firmware); 36 LINE/PHONO report (note `0x61`); 37 thru at connect (board input PC7); 32–34, 40–43 SL2Api, `sl2panel` and the test tools (each device's API has its own signatures; the SL 3 uses `0x10` for its version) |

## Bug catalogue

Each entry: symptom → cause → fix → how to test for it again → commit. Tests marked *(debug)* need a debug
build; *(hook)* uses `tools/latency/bin/sl2dbg`.

### Audio engine

1. **48 kHz falls back to 44.1 kHz and plays sharp.**
   - Cause: the rate setters changed the driver and the box without telling the HAL, which kept its cached
     rate.
   - Fix: the configuration-change handshake.
   - Test: select 48 kHz while playing; pitch must be right and the menu must stay at 48 kHz.
   - `0bee6e0`.
2. **Gap after the first buffer of every playback.**
   - Cause: the timeline anchor was moved to the first capture packet about 33 ms after IO began, so the
     HAL saw its timestamps jump (`TimeStampOutOfLine`).
   - Fix: the anchor stays fixed per stream, and capture is placed on the timeline.
   - Test: play from cold; no gap, and no `TimeStampOutOfLine` in coreaudiod's log.
   - `0672a0e`.
3. **About 56 ms of hidden output latency.**
   - Cause: the playback reader started from ring position 0, while the HAL was already writing at its
     current timeline position, which was 56 ms on by the time playback started.
   - Fix: the reader starts at the matching timeline position. This is superseded by the deep schedule,
     which places samples by timeline position directly.
   - Test: loopback round trip (`rtlat`).
   - `0a1f064`.
4. **The timeline drifts against the box.**
   - Cause: `ticks_per_frame` was a slow moving average applied to the whole elapsed time, so each update
     rescaled the past and slid the timeline against the box's frame count.
   - Fix: the `clk_track` re-anchoring loop.
   - Test: reader position against timeline stays constant over minutes, and `DBG clk` phase error stays
     under 2 frames *(debug)*.
   - `243583a`.
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
   - Test: `dptest.sh` (5 min idle and loaded).
   - `fa4b4d0`.
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
    - Test: no `enqueue refused for frame` at stream start (`restartcheck.sh`).
    - `0022ccb`.
11. **Playback goes silent after about 50 s.**
    - Cause: WriteMix estimated a sample's frame from the stream start at the nominal rate, which drifted
      about 0.1 frame/s at −105 ppm until the bounded search missed.
    - Fix: estimate from a recent frame.
    - Test: `sinetest` for over 2 min; `unscheduled` stays flat *(debug)*.
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
    - Fix: 128 transfers, and a write guard of 1 ms (was 0.25 ms), the margin the late-write experiment
      validated.
    - `e33861e`.
15. **Capture timing came from completion stamps.**
    - Cause: completion stamps include the stack's hold, which skewed the clock and the delay measurements.
    - Fix: bus time from the microframe reference.
    - `dbacee9`.
16. **Errored capture packets biased the steering.**
    - Cause: they added nothing to the captured count, which lowered the output rate target and drained the
      box's FIFO.
    - Fix: count them in the steering (completed by entry 20).
    - `3c7e6a6`.
17. **Every stream re-anchored immediately.**
    - Cause: the dry-schedule threshold equalled the start lead.
    - Fix: a separate `DP_DRY_LEAD` of 4.
    - Test: `resyncs 0` at stream start *(debug)*.
    - `19b5328`.
18. **A second application's audio was dropped.**
    - Cause: a new HAL IO thread, started when another client began playing, seeded its frame estimate from
      the stream start. 13 minutes in, that was about 80 frames off.
    - Fix: estimate from the newest published frame.
    - Test: stream for several minutes, then play a second client; `unscheduled` stays at 0 *(debug)*.
    - `90025d8`.
19. **Capture stops for good after a completion stall of more than ~64 ms.**
    - Cause: a re-queued capture request for a frame that had passed was refused, and a refused request
      never completes, so each of the 64 transfers dropped out in turn.
    - Fix: check the enqueue; re-anchor ahead of the bus; fill the frames not captured with silence.
    - Test: `sl2dbg stall 100` during `sinetest` *(hook)*: one gap, the log's "not captured" line, then clean.
    - `3c8b1e9`.
20. **Each errored capture packet moved playback ~6 frames against the timeline.**
    - Cause: the ring and the clock tracker didn't count errored packets while the steering did (entry 16);
      about 12 errors used up the write margin. A whole-packet fill size then over-counted slightly.
    - Fix: fill errored packets with silence at the box's measured rate and count them everywhere.
    - Test: `sl2dbg errpkts 20` during `sinetest` *(hook)*: a ~3 ms gap, sent − captured within ±2.
    - `3c8b1e9`, `4c16c53`.
21. **A late capture handed the HAL 1.36-second-old audio.**
    - Cause: ReadInput didn't check how far capture had written, so it returned the ring's previous lap.
    - Fix: capture's write head; silence beyond it.
    - Test: `sl2dbg stall 20` during `sinetest` *(hook)*: a short silent gap, no burst of old sine.
    - `3c8b1e9`.
22. **Stopping a stream could crash coreaudiod.**
    - Cause: buffers, pipes and interfaces were freed on the stopping thread while a USB completion handler
      could still be using them.
    - Fix: free them on the USB queue (`dispatch_sync`); `dp_start` does nothing once its stream is over.
    - Test: repeated rate changes and unplugs mid-stream; coreaudiod's pid stays the same.
    - `66d164d`.
23. **Completions from a stopped stream ran inside the next one.**
    - Cause: they only checked "is a stream running?"; after a quick stop/start a stale one could queue a
      transfer twice.
    - Fix: stream generations.
    - Test: as entry 22.
    - `66d164d`.
24. **A failed start left the interfaces claimed; they were never destroyed.**
    - Fix: one release path (`usb_release_audio`), used by stop and every failure; interfaces destroyed.
    - `66d164d`.
25. **A client streaming through an unplug got silence after the replug; StartIO succeeded with no box.**
    - Cause: the client count survived the unplug, and StartIO returned 0 whether or not streaming started.
    - Fix: reset the count on unplug; StartIO returns an error when the box can't be opened.
    - Test: play in Music, unplug, replug: playback resumes on the SL 2 (the log shows the late StopIO
      ignored and a fresh start).
    - `66d164d`.
26. **Opening at connect could re-open the device, ran inside Initialize, left a stale rate, and failed
    silently at full speed.**
    - Fix: open once and look again for the HID interface; drain the hot-plug iterators on their queue; set
      the rate at connect; check the link speed.
    - Test: replug with nothing playing: one "USB connected", sl2panel shows the driver's rate.
    - `ca22fea`.
27. **Property reads wrote past the caller's buffer.**
    - Cause: `GetPropertyData` ignored `inDataSize`. Also: `OwnedObjects` ignored its class qualifier;
      thread-local storage on the IO thread.
    - Fix: check the size first; clamp arrays, refuse a single value that doesn't fit.
    - Test: a one-ID Streams read returns 4 bytes and leaves the next word untouched; `devprobe` unchanged.
    - `797a7aa`.
28. **`sl2h` replayed commands, mixed up clients and misread replies.**
    - Cause: a read sent the last command written (after `sl2flash`, any read restarted the box); one slot
      for all processes; replies to `0x40`+ not waited for; rejections taken for timeouts; reports drained by
      whichever client read first.
    - Fix: send on write, reply per client, wait for every reply, `0xFF` = refused, a report queue per client.
    - Test: a bare read of `sl2h` returns zeros and changes nothing; `sl2dump` reads the EEPROM intact.
    - `9e53511`.
29. **The `0x37` heartbeat was unnecessary.**
    - Cause: an early belief that the box only passes audio while it flows; the firmware never checks it.
    - Fix: stop sending it (tested: 45 s loopback without it, full level, no glitches).
    - `5490729`.
30. **The zero-timestamp period was below the HAL's documented minimum** (2048 < 10923).
    - Fix: 16384.
    - Test: `restartcheck.sh`, `dptest.sh 60`; no `TimeStampOutOfLine` in coreaudiod's log.
    - `48cfe9f`.
31. **The reported latency was 0.9 ms more than measured.**
    - Cause: both streams added 32 frames on top of the device latency.
    - Fix: input stream latency 0 (130 frames reported vs 123 measured).
    - Test: `rtlat`'s hidden latency vs the reported total (`devprobe`).
    - `73f5784`.

### Connect, status and clients

32. **SL2Api's exported functions didn't match Rane's: Serato's hardware check and thru control broken.**
    - Cause: `SL2_driver_timer` and `SL2_send_hidimsg` had the wrong signatures (and most other exports had
      wrong signatures or return codes), written without Rane's framework to compare against.
    - Fix: every export matches Rane's; the control panel's disconnect event; the latency slider.
    - Test: `sl2apitest` (the seven functions Serato imports, called as Serato does); Rane's control panel;
      Serato DJ Pro 2.5.5 with turntables (the hardware check passes, Rel/Abs unlock, per-deck thru).
    - `014a0b2`.
33. **`RH_get_all_controls` sent `0x42`, which the firmware doesn't implement.**
    - Fix: the state-dump SysEx, as Rane's does. `7c14d7a`.
34. **SL2Api's firmware versions had the wrong layout, and asked with the SL 3's `0x10`.**
    - Fix: Rane's layouts (`{major, minor, 0, stamp}`, `{1, 10}`) and `0x01`. `7dd60cb`, `494af13`.
35. **The SL 2 stayed in the system's device lists with no box attached.**
    - Fix: the device is listed only while a box is attached (a bootloader-mode box keeps it).
    - Test: unplug: it disappears from Audio MIDI Setup; replug: it returns. `19b09a4`.
36. **The status always reported LINE.**
    - Cause: reports never enabled (`0x36`), note `0x61` misparsed, no state request at open.
    - Test: flip the switch; `sl2panel` follows; also after a replug on PHONO. `69f21fd`.
37. **After a replug, turntables didn't reach the mixer until a stream had run.**
    - Cause: the box powers up with thru on or off depending on a board input; nothing set it at connect.
    - Test: replug with nothing playing; `sl2panel` shows ANALOG THRU. `717c184`.
38. **A refused first open at connect left the decks off thru.**
    - Fix: retry the open for about a second (about 1 connect in 30 is refused at first). `a60bc35`.
39. **The status packet's playback frame count stayed at 0.** `226c7d2`.
40. **`sl2panel phono` / `line` did nothing**: LINE/PHONO is a physical switch. `08cf301`.
41. **`sl2panel` said "driver not loaded" with the box just unplugged.** `3c5b37e`.
42. **Test scripts passed silently against a release build, and the release build forwarded debug commands to
    the box.** `cde1bd7`.
43. **After an unplug and replug, Serato DJ Pro 2.5.5 lost the SL 2 until it was restarted.**
    - Cause: Serato watches USB itself and sends its hardware check about 25 ms after the box appears,
      before the driver has opened the box and listed its device; SL2Api answered 12 (not connected), and
      Serato doesn't retry.
    - Fix: SL2Api waits up to 2 s for the device while the box is in the USB registry and the driver is
      loaded.
    - Test: replug with Serato 2.5.5 open; it picks the box up again (SL2Api's log shows the wait).
      `de68e8d`.

## Testing

`make hwtest` runs the hardware tests in one go, in the order that needs the fewest physical steps, and
ends with a PASS / FAIL / SKIP summary (`ARGS="--loopback"` with the loopback cable in). It covers the
status, SL2Api as Serato calls it, rate switching, restarts, glitches (idle and loaded), 48 kHz, the
output volume and mute (and that they survive a replug), the level meters, the fault hooks, the LINE/PHONO report, and unplug and replug while idle and mid-stream.

The tools are in `tools/latency/` (build them with `make latency`). Its README covers the loopback setup,
what each tool does and the expected results. The main ones:

| Tool | What it does |
|---|---|
| `rtlat` | Round-trip latency through a loopback cable: hidden latency and estimated DVS round trip |
| `sinetest` | Plays a continuous 997 Hz sine through the loopback for N seconds. Flags any break in the sine recurrence (dropout, repeat, skip) and any drop in level |
| `dptest.sh` | `sinetest` for N s idle, then with every core busy, with the driver's counters (debug build); PASS/FAIL |
| `restartcheck.sh` | Three streams in a row; each must start cleanly and find its clicks; PASS/FAIL |
| `sl2dbg` | Debug build only: input safety offset, stall the USB queue, error capture packets |

`tools/install-sl2.sh` (run by `make install`) installs a build into the installed driver bundle (the
release package must be installed first) and restarts coreaudiod and the processes that go stale.
`--api` also installs a built SL2Api into `SL2Api.framework`, saving the previous one, which
`--restore-api` puts back.

**Debug build.** `make plugin DEBUG=1` defines `SL2_DEBUG`, which compiles in the streaming diagnostics
(counters, the capture timing histogram, the WriteMix calling-pattern check) and the debug commands
(`sl2dbg`). A plain `make plugin` builds none of it, refuses every debug command, and logs only: driver
start, connect and disconnect, bootloader mode, opens that needed a retry, stream start and stop, sample-rate
changes, capture gaps, refusals and errors. Both builds play through the deep schedule.

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

**Debug commands** (`tools/latency/bin/sl2dbg`, handled by the driver, never sent to the box):
- `insafe <ms>`: the input safety offset. The HAL reads safety offsets only at device setup, so it takes
  effect for a device set up again (e.g. after restarting coreaudiod), not the running one.
- `stall <ms>`: hold the USB queue once, as a completion-delivery stall would.
- `errpkts <n>`: treat the next n capture packets as errored.

## Still open

- Possibly lowering the input safety offset further. Capture data is written to memory on time and only the
  completion is late, so a real-time thread could detect it by marking each capture buffer's padding bytes.
  Untested.
