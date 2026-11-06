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
- **Over USB, with `sl2flash`.** Programs the EEPROM through the box's own USB command
  interface, the way Rane's driver did: directly on a running box (a firmware update), or, for
  a box in its bootloader, after first loading Rane's bootstrap (a small EEPROM programmer) into
  its RAM. The commands go through this project's HAL driver, so the driver must be installed.
  A box that doesn't enumerate at all needs the direct reflash instead. Spec:
  **`UPLOAD-PROTOCOL.md`**, **`BOOTSTRAP-ANALYSIS.md`**.

  Tested on hardware: rewriting a running box, and recovering a box from bootloader mode both
  by re-marking an intact EEPROM bootable and by a full rewrite. Not tested: a box with a
  blank EEPROM (the Cypress default device, `04b4:8613`), which `sl2flash` accepts but which
  can't be produced over USB to test it.

`Installer/Firmware-SL2.command` wraps the over-USB flow (download → extract → install →
check → flash, asking before it writes). It runs from a checkout of this repository, not from
the installer zip.

## Usage

```
make flash dump
./sl2flash --dry-run                # check the images and the box; change nothing
./sl2flash                          # write the firmware if the EEPROM doesn't already hold it
./sl2dump --verify eeprom-image-24lc512.bin   # independent check of a running box's EEPROM
```

`sl2flash` reads the images from `/Library/Audio/Plug-Ins/HAL/SL2Device.firmware` (where
`sl2-firmware-install.sh` puts them), or from `--firmware DIR`. It needs no root. Stop any
audio on the SL 2 and quit sl2panel and Serato first: they talk to the box through the same
driver channel.

The box's LEDs show what it is doing: all off = bootloader mode (no firmware running); main
LED blinking = the firmware is loading the FPGA, which takes a few seconds after power-up or
after a flash; both on = running.

## Files
- `extract-sl2-firmware.py` — de-obfuscate the firmware out of your own copy of
  SL2Api.framework (Mac); produces `eeprom-image-24lc512.bin` (for the Pi reflash and for
  `sl2dump --verify`) plus the bootstrap and final images (for `sl2flash`).
- `pi/pi-eeprom-24lc512.py` — safety-gated read / write / verify of the EEPROM from a Pi.
- `sl2flash.m` — the over-USB flasher.
- `sl2-firmware-install.sh` — install firmware images next to the HAL driver for `sl2flash`.
- `RECOVERY.md`, `UPLOAD-PROTOCOL.md`, `BOOTSTRAP-ANALYSIS.md` — the guides and protocol spec.

Outside this folder: `tools/sl2dump.m` reads the EEPROM of a running box over USB (backup and
verify), and `tools/SL2Passthrough.{h,m}`, shared by both tools, sends commands to the box
through the HAL driver.

The SL 2's full USB command set (of both the running firmware and the bootstrap) is in
`docs/SL2-COMMANDS.md` at the repository root.

## Licensing
The firmware is proprietary Rane / Serato code, extracted only for interoperability with
hardware you own. Do not commit the extracted images or redistribute them — supply your own
copy of the official driver.
