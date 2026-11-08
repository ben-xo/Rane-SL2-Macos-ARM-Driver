# Contributing to the Rane SL 2 macOS driver

Guidance for anyone changing this repository, human or AI agent. It records the coding standards the
code follows and the lessons that cost real time to learn, so that later work stays consistent with it.
The design and the bug history are in `docs/SL2-AUDIO-ENGINE.md`; the box's command protocol is in
`docs/SL2-COMMANDS.md`. Read both before changing the driver.

## What is here

| Path | What it is |
|---|---|
| `plugin/SL2Device.m` | The driver: a CoreAudio HAL plug-in (runs inside `coreaudiod`) that drives the box over IOUSBHost |
| `tools/SL2Api.m` | A replacement for Rane's `SL2Api.framework`, used by Serato DJ Pro 2.5.x and Rane's control panel |
| `tools/sl2panel.m` | Command-line status and control |
| `tools/SL2Passthrough.{h,m}` | Shared client for the driver's HID passthrough (`sl2h`) |
| `tools/sl2dump.m`, `tools/firmware/` | EEPROM read-back, the firmware flasher, and the SOIC-clip recovery toolkit |
| `tools/latency/` | Loopback latency and glitch tests (`make latency`), with a README |
| `tools/install-sl2.sh` | Installs a local build over an installed package and restarts what goes stale |
| `Installer/` | The end-user scripts shipped in the package (Spanish) |

`make` builds everything; `make plugin` is the release driver and `make plugin DEBUG=1` adds the
diagnostics and debug commands.

## Safety first

- **Some HID commands write the box's EEPROM or change how it enumerates** (marked ⚠ in
  `docs/SL2-COMMANDS.md`): `0x17` marks the firmware non-bootable, `0x02` writes EEPROM blocks, `0x16`
  marks it bootable and restarts the box, `0x1a` reconnects it under another product ID. Never send them
  to a working box to "see what happens". A box left after `0x17` without a `0x16` comes up in bootloader
  mode at its next power-up.
- **A wrong flash can brick the box beyond USB recovery.** The only proven recovery is reflashing the
  EEPROM directly with a SOIC-8 clip (`tools/firmware/RECOVERY.md`). Shorting the EEPROM's SDA line at
  power-on does not work; don't suggest it. `sl2flash` verifies the whole image before it sends `0x16`;
  keep that guarantee in any change to it.
- **Don't add gates the official software doesn't have.** The passthrough forwards these commands as
  Rane's driver does; protection belongs in documentation and in the tools, not in a driver-side filter.
- **Never commit Rane's firmware or binaries**: extracted images, disassembly, `SL2Api` binaries. They
  stay in git-ignored or local directories.
- **Connect the box directly or through one hub.** Isochronous streaming through nested hubs has
  kernel-panicked a Mac inside Apple's XHCI driver.

## Facts about the box that were learned the hard way

Verify a behaviour on the hardware, or in the firmware or Rane's binaries, before relying on it. Much of
the starting code was carried over from the SL 3 driver and was wrong for the SL 2.

- Isochronous endpoints are `0x06` OUT and `0x82` IN, 112-byte packets (7 frames × 4 channels × 4 bytes),
  not the SL 3's geometry.
- The firmware version comes from HID `0x01`; `bcdDevice` only says running firmware (`0x0100`) or
  bootloader (`0x0000`). The serial is the USB serial-number string.
- There is one LINE/PHONO switch for both decks, reported as note `0x61` (on = phono); reports need `0x36`
  enabled. It is a physical switch, so software can only read it.
- The box doesn't check the `0x37` heartbeat. `0x42` is not implemented (`0xFF` reply); `0xFF` means a
  rejected command.
- Rane's own `SL2Api.framework` and control panel are the reference for what clients expect: match their
  function signatures and behaviour (taken from their disassembly), not what seems reasonable.

## Platform lessons (CoreAudio HAL and IOUSBHost)

The full list is under "Platform facts worth knowing" in `docs/SL2-AUDIO-ENGINE.md`. The ones that shape
the design:

- **Real-time completion handling is not available from user space**, and USB completion delivery stalls
  for 5–30 ms regardless of priority. Never design so that audio depends on a completion arriving on
  time: playback keeps a deep schedule of queued transfers and writes audio into them late.
- **Clean up on the USB queue.** Teardown runs on the driver's serial queue (`dispatch_sync`), and work
  from a stopped stream checks the stream generation before touching anything. Release
  `ioDataWithCapacity:` buffers before the next stream claims the interface.
- **Respect the HAL's contracts**: clamp every property write to the caller's `inDataSize`; declare custom
  properties in `kAudioObjectPropertyCustomPropertyInfoList`; keep the zero-timestamp period at or above
  the documented minimum; change the sample rate through the configuration-change handshake; send
  `PropertiesChanged` when the device list or owned objects change.
- **Report latency you have measured** with `tools/latency/rtlat`, not latency you have calculated.
- **The HAL reads safety offsets only at device setup**, so test changes to them after restarting
  `coreaudiod`.
- After `killall coreaudiod`, Control Center, QuickLookUIService and AirPlayXPCHelper keep stale state;
  `tools/install-sl2.sh` restarts them. Judge a change only after that.

## Coding standards

**Structure**
- Group code by subsystem with a prefix: `clk_` (timeline clock), `cap_` (capture), `dp_` (playback deep
  schedule), `usb_`, `hid_`, `dbg_`. Globals start with `g_`.
- Name protocol values: `SL2_CMD_*`, `SL2_NOTE_*`, `HID_REPORT_LEN` and friends, each with a comment
  giving the request and reply layout. No bare command numbers in code.
- Debug-only code goes behind `SL2_DEBUG` (`DBG_LOG`, `DBG_DO`, the `dbg_` block). The release build must
  stay quiet: log connect, disconnect, stream start and stop, rate changes, retries, refusals and errors,
  nothing per-cycle. The release build refuses debug commands (`0xF0` and above).
- Code that is replaced is removed from the tip in its own commit, so it stays findable in history. Don't
  leave dead paths or switches for old behaviour in the tip.
- Shared helpers live in one place (`SL2Passthrough`, `tools/latency/common.h`); don't copy them.

**Comments**
- Describe what the code does now and why. No code archaeology: not "the original code used…", "used to",
  "an early version…". Where a contrast helps, use a neutral cross-reference ("c.f. the SL 3, which uses
  `0x10`"). Commit messages are where the history goes.
- Write for a first-time reader who wasn't part of the debugging: no "your box", no references to our own
  failed experiments, standard terms ("bootloader mode", "EP1 interrupt").
- In any function that reads as a procedure, put a one-line comment before each step saying what the next
  lines do. Lookup tables (the property switch statements) get one separator per section, not per case.
- Keep comments and docs true when the code changes; a stale comment is a bug.

**Docs**
- `docs/SL2-AUDIO-ENGINE.md` is the design record. A fix to the audio engine, connect/status handling or
  the client interfaces adds an entry to its bug catalogue (symptom → cause → fix → test → commit) and,
  where it applies, to the SL 3 / SL 4 porting table.
- When moving content between documents, move it verbatim and check nothing was lost.

**Tools**
- Test scripts print a clear PASS or FAIL. Match log lines on text that can't also appear in a counter
  line.
- Tools that only read the box go through the driver's passthrough, so they work while the driver runs.

## Commits and pull requests

- **One bug per commit.** The message gives the symptom, the cause, how it was found and how to test for
  it again. The history is used for regression hunting and as the guide for porting fixes to the SL 3 and
  SL 4 drivers.
- **Sign every commit** (GPG). History rewrites with `git filter-branch` drop signatures; after any
  rewrite, check `git log --format=%G? main..HEAD` shows `G` for every commit.
- AI-assisted commits keep a `Co-Authored-By:` line but no session links.
- Stage explicit paths, not `git add -A`; local debug material must not slip in.
- Finish a branch locally (code, comments, build, diff review) before pushing. Once a branch is pushed,
  add follow-up commits rather than force-pushing.
- Keep PRs focused. README restructures go in their own PR. Don't rebuild the committed `.pkg`/`.zip`
  installers in a PR; the maintainer does that.
- A PR description says what was tested on hardware, on what, and what was **not** tested.

## Testing

- Build both `make plugin` and `make plugin DEBUG=1`; build every tool you touched.
- Install with `tools/install-sl2.sh` (needs `sudo`).
- Audio changes: a loopback cable from Left Deck Out L to Left Deck In L, with the LINE/PHONO switch on
  LINE (PHONO's preamp clips the test tones). Then `tools/latency/dptest.sh` and
  `tools/latency/restartcheck.sh`, both PASS, and `rtlat` if latency could have changed. Use the debug
  hooks (`sl2dbg stall`, `sl2dbg errpkts`) to reproduce stalls and errors instead of waiting for them.
- Connect and status changes: unplug and replug while idle and while streaming; check Audio MIDI Setup
  and `sl2panel`.
- Client changes: Rane's SL 2 control panel, and Serato DJ Pro where possible. Serato DJ Pro 4.x uses the
  driver directly; only 2.5.x loads `SL2Api`.
- When testing with someone at the hardware, ask for each physical step explicitly (connect the
  loopback, flip a switch, replug), and order the tests so they need the fewest of those steps.
