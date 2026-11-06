# Rane SL 2 firmware tools

Everything for getting firmware onto a Rane SL 2. The SL 2's USB controller (a Cypress
EZ-USB FX2LP) has no internal flash — its firmware lives in an on-board I2C EEPROM. If that
EEPROM is blank or corrupt the box comes up in the FX2 USB bootloader ("Unnamed Device",
`bcdDevice 0x0000`) and passes no audio until firmware is written again; a healthy box runs
as "Rane SL 2", `bcdDevice 0x0100`.

The firmware is Rane's and is **not** included here. You extract it from **your own** copy of
the official Serato Scratch Live driver with `extract-sl2-firmware.py`; `.gitignore` keeps the
extracted images out of the repo.

## Two ways to write it

- **Direct EEPROM reflash (proven).** Reflash the 24LC512 chip directly from a Raspberry Pi
  + SOIC-8 clip. Fixes every case, including a hard brick where USB can't reach the box.
  Guide: **`RECOVERY.md`**; tools: `extract-sl2-firmware.py`, `pi/pi-eeprom-24lc512.py`.
- **Over-USB load (reconstructed, unproven on hardware).** Drive the FX2 bootloader over USB
  to program the EEPROM, the way Rane's own driver did. Tool: `sl2flash` (engine:
  `SL2Loader.{h,m}`). Read the STATUS note in `SL2Loader.h` before relying on it, and prefer
  the direct reflash. Spec: **`UPLOAD-PROTOCOL.md`**, **`BOOTSTRAP-ANALYSIS.md`**.

`Installer/Firmware-SL2.command` wraps the over-USB flow for end users (download → extract →
install → flash).

## Files
- `extract-sl2-firmware.py` — de-obfuscate the firmware out of your own copy of
  SL2Api.framework (Mac); produces `eeprom-image-24lc512.bin` (for the Pi reflash) plus the
  bootstrap and final images (for the over-USB loader).
- `pi/pi-eeprom-24lc512.py` — safety-gated read / write / verify of the EEPROM from a Pi.
- `sl2flash.m`, `SL2Loader.{h,m}` — the over-USB flasher and its loader engine.
- `sl2-firmware-install.sh` — install firmware images next to the HAL driver for `sl2flash`.
- `RECOVERY.md`, `UPLOAD-PROTOCOL.md`, `BOOTSTRAP-ANALYSIS.md` — the guides and protocol spec.

The SL 2's full USB command set (of both the running firmware and the bootstrap) is in
`docs/SL2-COMMANDS.md` at the repository root.

## Licensing
The firmware is proprietary Rane / Serato code, extracted only for interoperability with
hardware you own. Do not commit the extracted images or redistribute them — supply your own
copy of the official driver.
