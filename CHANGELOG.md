# Changelog

All notable changes to the Rane SL 2 macOS ARM Driver project are documented in this file.

## [Unreleased]

### Changed
- `Firmware-SL2.command` installs firmware 2.00, the newest: it downloads Rane's SL 2 driver 2.0.1f2 from the Internet Archive (Rane no longer hosts it) and checks it against the original's SHA-256. The Scratch Live download (firmware 1.10) is the fallback when that fails, as before.

### Added
- The SL 2 Control Panel offers "Update Firmware…" beside firmware older than 2.00, and "Restore Firmware…" for a box in bootloader mode. Both run `Firmware-SL2.command`, which the app now carries, in Terminal; it no longer needs a checkout or `make flash`.

## [1.4.1] — 2026-11-17

### Changed
- The installer's pages are in English and Spanish (it shows the Mac's language), and the Welcome page shows the installer's own version (it said 1.0.0).

### Fixed
- After a replug mid-stream, a second unplug and replug before the app restarted its stream could put the decks back on thru (and Serato's decks in THRU) a second after the replug.
- The driver resets the box's USB configuration only when another driver really holds its HID interface, and logs why an open failed.
- A box that restarts (a firmware update) is reopened even if its new device is seen before the old one goes, instead of the driver staying on the old device and refusing to stream.
- The check after connecting and after a Mac wake no longer puts a deck back on thru that was put on USB on purpose (`sl2panel usb`, Rane's control panel) with nothing streaming.
- `sl2flash` refuses `--dry-run` with `--backup-only`, which loaded the bootstrap into a box in its bootloader.
- `make hwtest` takes the loopback channel from `SL_LOOP_CH` in every step.
- Hardening from the SL 3 driver's code review (none seen on an SL 2): playback can no longer be let back in after a stop and its buffers freed under it; a refused or failing HID read is retried instead of stopping commands or spinning; a reply arriving as its command times out can no longer reach the next command; the status is never read half-updated; a late StopIO from before an unplug no longer stops the stream started after the replug; a rate change while streaming sends the rate once.
- SL2Api no longer waits 2 s on each call while a box in its bootloader is attached.

## [1.4.0] — 2026-11-17

### Added
- `sl2panel` shows the USB link speed and the box's own sample rate (`Box Rate`); the control panel warns about a full-speed connection, shows firmware older than 2.00 in red, and greys out the input meters (with a link to Sound Settings) while nothing streams.
- `sl2flash` saves the whole EEPROM to `sl2-eeprom-backup-<date>.bin` before writing it, takes a blank Cypress FX2 for an SL 2 only with `--blank-fx2`, and `--backup-only` saves the EEPROM without writing anything.
- The firmware extractor reads Rane's 1.0.3f1 and 2.0.1f2 drivers (firmware 2.00) as well as 1.0.1f4, and checks every image against the known build's SHA-256.
- `make hwtest`: IO buffer sizes from 32 to 512 frames, the capture packet sizes (debug build), and a sleep/wake step.

### Fixed
- The chosen sample rate is kept across a coreaudiod restart.
- Thru and the sample rate are checked again 2 s after connecting and after the Mac wakes.
- After a replug while an app is streaming, the decks keep the routing they had (Serato no longer comes back with every deck in THRU); they go back on thru if no stream restarts within 5 s.
- Rane's firmware loader (bootstrap) is reported as boot mode, and the driver no longer streams from it or sends it thru and rate commands.
- A box that doesn't answer the version command no longer shows the previous box's version.
- After a macOS userspace reboot with the SL 2 attached, the box no longer stays unusable until it is replugged: macOS's HID driver can no longer take its command interface, and the driver recovers the box if it has.
- `sl2flash` no longer writes older firmware over newer (the Scratch Live driver's 1.10 over 2.00) unless given `--force`, and no longer reports a successful flash as failed ("does not answer through the driver").
- `tools/install-sl2.sh` installs the driver's `Info.plist` with the binary, so the control panel shows the installed driver's version.
- The driver's start-up log line shows its version instead of `<private>`.

## [1.3.0] — 2026-11-10

### Added
- **Ultra-low-latency audio engine (9.3 ms DVS round trip at 64 frames / 48 kHz):**
  - Deep-scheduled playback (`dp_write`): keeps 128 ms of USB isochronous OUT transfers queued ahead of time while CoreAudio's `WriteMix` writes audio directly into the already-queued transfer buffer shortly before hardware playback, immune to macOS USB completion delays (`docs/SL2-AUDIO-ENGINE.md`).
  - Early capture read (`cap_read_early`): CoreAudio's `ReadInput` reads captured 24-bit audio frames directly out of queued USB IN DMA buffers before the 8-microframe completion callback arrives, lowering the default input safety offset from 8 ms to **1.5 ms**.
  - Automatic early-read health check, input dropout counter, USB hub depth detection, and runtime `sl2i` (`sl2panel safety [ms]`) input safety offset adjustment.
- **SL 2 Control Panel (`SL 2 Control Panel.app`):** Native Universal (arm64 + x86_64) SwiftUI macOS application replacing Rane's legacy Intel-only System Settings preference pane, featuring live input/output peak level meters (`'sl2m'`), Deck 1/2 CD/Phono and Analog Thru controls, master output volume/mute, input safety offset selector, and connection/health diagnostics.
- **Native macOS Output Volume & Mute:** Master and per-channel output volume (`-64 dB` to `0 dB` following CoreAudio's standard curve with 5 ms click-free ramping) and mute controls in `SL2Device.driver`, controllable from the macOS menu bar, keyboard volume keys, and Audio MIDI Setup.
- **Hardware Test Suite (`make hwtest`):** Automated hardware verification script (`tools/hwtest.sh`) and latency/glitch measurement utilities (`tools/latency/`).
- **Repository Package Builder (`make package`):** Builds `RaneSL2-macOS-Universal.pkg` and `Rane-SL2-Installer-Mac-M1-M2-M3-M4.zip` 100% from source (`Installer/build-pkg.sh`) with zero proprietary Rane binaries.
- **Contributor & Architecture Documentation:** Added `AGENTS.md`, `CLAUDE.md`, and `docs/SL2-AUDIO-ENGINE.md`.

### Fixed
- **Serato DJ Pro 2.5.5 compatibility with open-source `SL2Api.framework`:** Fixed `SL2_driver_timer`, `SL2_send_hidimsg`, `RH_get_firmware_version`, `RH_get_firmware_embedded_version`, `RH_get_all_controls`, and hot-plug startup wait so Serato DJ Pro 2.5.5 unlocks DVS (`ABS`/`REL`) and controls Thru reliably using the open-source `SL2Api`.
- **USB Hot-plug & Device Listing:** The CoreAudio HAL device is now published only while an SL 2 is physically connected on USB, and automatically switches decks to Analog Thru on connect/disconnect.
- **Sample-Rate Switching:** Routed sample-rate changes (44.1 kHz / 48 kHz) through CoreAudio's `RequestDeviceConfigurationChange` handshake.
- **Line / Phono Status:** Fixed reading of the hardware `LINE/PHONO` switch (`0x61`) so `sl2panel` and `SL 2 Control Panel.app` report the true switch state.

### Removed
- Removed Rane's proprietary `SL 2 Audio Control Panel.prefPane` from the installer package; the `postinstall` script removes any copy left by earlier installs.

## [1.2.0] — 2026-11-05

### Added
- Over-USB EEPROM firmware reader (`sl2dump`) and firmware flasher (`sl2flash`), plus direct-EEPROM recovery toolkit (`tools/firmware/`) and complete command protocol documentation (`docs/SL2-COMMANDS.md`).
- USB bootloader mode detection (`bcdDevice 0x0000`) in `SL2Device.driver` and `sl2panel`.

### Fixed
- Fixed firmware version and serial number reporting in `SL2Device` and `sl2panel` using HID command `0x01`.

## [1.1.0] — 2026-11-02

### Fixed
- Fixed 24-bit 4-channel USB packet sizing (`PKT_MAX = 112`), removed SL3-only `0x37` periodic heartbeat on SL2, and fixed CoreAudio HAL stream format and zero-timestamp anchoring so audio passes cleanly in both directions.

## [1.0.0] — 2026-10-31

### Added
- Initial release of the Rane SL 2 macOS ARM User-Space CoreAudio Driver (`SL2Device.driver`), `SL2Api.framework` bridge for Serato DJ Pro 2.5.5, and `sl2panel` CLI.
