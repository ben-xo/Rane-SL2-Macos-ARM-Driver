# Changelog

All notable changes to the Rane SL 2 macOS ARM Driver project are documented in this file.

## [Unreleased]

### Added
- `sl2panel` shows the USB link speed and the box's own sample rate (`Box Rate`); the control panel warns about a full-speed connection, shows firmware older than 2.00 in red, and greys out the input meters (with a link to Sound Settings) while nothing streams.
- `sl2flash` saves the whole EEPROM to `sl2-eeprom-backup-<date>.bin` before writing it, and takes a blank Cypress FX2 for an SL 2 only with `--blank-fx2`.
- The firmware extractor reads Rane's 1.0.3f1 and 2.0.1f2 drivers (firmware 2.00) as well as 1.0.1f4, and checks every image against the known build's SHA-256.
- `make hwtest`: IO buffer sizes from 32 to 512 frames, the capture packet sizes (debug build), and a sleep/wake step.

### Fixed
- The chosen sample rate is kept across a coreaudiod restart.
- Thru and the sample rate are checked again 2 s after connecting and after the Mac wakes.
- Rane's firmware loader (bootstrap) is reported as boot mode, and the driver no longer streams from it or sends it thru and rate commands.
- A box that doesn't answer the version command no longer shows the previous box's version.
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
