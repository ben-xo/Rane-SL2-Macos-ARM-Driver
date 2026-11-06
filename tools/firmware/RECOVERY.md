# Rane SL 2 — EEPROM recovery / un‑brick guide

How to bring a Rane SL 2 back when it won't enumerate — including the worst case, a
**bricked boot EEPROM** (the box never finishes enumerating: no vendor/product ID, and it
never recovers on its own). Proven: this is exactly how the unit in this project was recovered.

> The firmware itself is proprietary Rane/Serato code and is **not** included here. You
> extract it from **your own** copy of the official driver (see Step 1). Everything in
> this folder is our own tooling.

## Background (30 seconds)
The SL 2's USB controller is a **Cypress EZ‑USB FX2LP (CY7C68013A, U14)**. It has no
internal flash — its firmware lives in an external **I²C EEPROM (24LC512, U11)** at bus
address **0x51**. At power‑up the FX2 ROM reads EEPROM byte 0:
- `0xC2` → load firmware from EEPROM and run it  → device enumerates as **"Rane SL 2",
  `bcdDevice 0x0100`** (the healthy state)
- `0xC0` → identity only, wait for a host firmware download (`bcdDevice 0x0000`)
- no/invalid EEPROM → FX2 falls back to its **mask‑ROM default device `04b4:8613`**

A brick = byte 0 is `0xC2` but the firmware body is garbage, so the FX2 boots nonsense
and never comes up. The fix is to rewrite the EEPROM with a correct image. A *corrupt
EEPROM* is always recoverable this way — the FX2's boot ROM is mask ROM and a bad image
can't damage it. **Physical damage is another matter entirely:** the reflash procedure
below is electrically hazardous, and a wiring or voltage slip can destroy the FX2 or the
board permanently. Read the warning before you start.

(An over-USB firmware loader, `sl2flash`, with its protocol write-up in `UPLOAD-PROTOCOL.md`
and `BOOTSTRAP-ANALYSIS.md`, is in this folder; this guide is the direct EEPROM reflash, which
fixes every case including a hard brick.)

---

## Which situation are you in?
Check the USB tree (macOS `ioreg -p IOUSB -l -w0 | grep -iA6 rane`, or `system_profiler
SPUSBDataType`; Linux `lsusb | grep 1cc5`):

| What you see | State | Fix |
|---|---|---|
| "Rane SL 2", `bcdDevice 0x0100`, ~4 interfaces | healthy | nothing to do |
| "Unnamed Device", VID `1cc5`/PID `0013`, `bcdDevice 0x0000` (bootloader mode) | C0 / blank EEPROM | the USB firmware loader (`sl2flash`) can upload over USB — **or** reflash the EEPROM (below) |
| A device with no VID/PID that never finishes enumerating | **bricked** (C2 + garbage) | **reflash the EEPROM directly** (below) — USB recovery can't reach it |

The direct‑EEPROM reflash below fixes *all* of these and is the surest route, but comes at your own risk, as there is a non-zero risk of damaging your hardware if you do not follow the procedure with care.

---

## Direct EEPROM reflash (Raspberry Pi + SOIC‑8 clip)

> ⚠️ **Physically risky — read before you start.** Reflashing fixes a *corrupt EEPROM*
> reliably, but you are clipping onto a live, fine‑pitch chip and powering it yourself. An
> **electrical** mistake — 5 V instead of 3.3 V, a reversed or misaligned clip, a slipped
> probe shorting two pins, or leaving the SL 2 on USB while the Pi also powers it — can
> **permanently destroy the FX2 or the board, and no reflash can undo that.** Unlike a bad
> firmware image, hardware damage is not recoverable. Work unhurried on an unpowered board,
> and **double‑check voltage, clip orientation, and that USB is unplugged before applying
> power** (full checklist under "Safety" below). If you're not comfortable doing this, don't.

### You need
- A Raspberry Pi (any with a 40‑pin header; the GPIO I²C is **3.3 V**, which matches)
- A **SOIC‑8 test clip** + jumper wires
- Your own copy of the official **Serato Scratch Live** installer (for the firmware),
  from <https://serato.com/scratchlive/downloads/mac>

### Step 1 — build the firmware image (on a Mac, from your own driver copy)
Mount the Scratch Live installer DMG, then:
```
python3 extract-sl2-firmware.py "/Volumes/ScratchLive Installer" .
```
This expands `Rane Device Drivers/SL2/SL2 1.0.1f4.pkg`, pulls the two firmware images out
of `SL2Api.framework`, XOR‑deobfuscates them, and writes **`eeprom-image-24lc512.bin`**
(65 536 bytes) — the exact contents a healthy EEPROM holds (C2 boot header + firmware).
It self‑checks the Rane header and CRC, so a wrong/garbled extract fails loudly.

### Step 2 — prepare the Pi (once)
```
sudo raspi-config nonint do_i2c 0      # enable the GPIO I2C bus
sudo reboot                            # /dev/i2c-1 appears after reboot
sudo apt install -y i2c-tools ; pip3 install smbus2   # (--break-system-packages if needed)
```
Copy `pi/pi-eeprom-24lc512.py` and `eeprom-image-24lc512.bin` to the Pi.

### Step 3 — wire the clip (SL 2 UNPOWERED — not plugged into USB)
The Pi powers the chip through the clip; never have USB and the Pi powering it at once.

| 24LC512 (U11) pin | → | Pi header |
|---|---|---|
| 8 VCC | → | pin 1 (3V3) — **3.3 V, never 5 V** |
| 4 VSS | → | pin 6 (GND) |
| 5 SDA | → | pin 3 (GPIO2 / SDA1) |
| 6 SCL | → | pin 5 (GPIO3 / SCL1) |

Leave clip pins 1/2/3/7 (A0/A1/A2/WP) unconnected — the board already straps them
(that's what makes it `0x51` with writes enabled). Chip pinout, if you need to confirm
orientation with a continuity probe: **1 A0=VCC, 2 A1=GND, 3 A2=GND, 4 VSS=GND,
5 SDA, 6 SCL, 7 WP=GND, 8 VCC** (pins 1↔8 beep together; 2‑3‑4‑7 all to GND).

### Step 4 — flash it (on the Pi)
```
python3 pi-eeprom-24lc512.py scan                    # expect 0x51
python3 pi-eeprom-24lc512.py check                   # want "bus looks quiet"
python3 pi-eeprom-24lc512.py read bricked-dump.bin   # keep a dump (confirms the brick)
python3 pi-eeprom-24lc512.py write eeprom-image-24lc512.bin   # backup → quiet-gate → confirm → fast-fail → write → verify
```
`write` won't proceed unless the bus is provably quiet, makes a timestamped backup first,
aborts after the first 128 bytes if the chip is write‑protected or contended, and
full‑verifies after writing. Worst case is a clean refusal, never a half‑written chip.

### Step 5 — test
Shut down / disconnect the Pi, **remove the clip**, then plug the SL 2 into USB. Confirm:
```
ioreg -p IOUSB -l -w0 | grep -iA6 rane      # macOS (system_profiler may be sandboxed/empty)
```
You want **"Rane SL 2", `bcdDevice 0x0100`** — a fully running, recovered box.

---

## Safety / gotchas
- **3.3 V only.** Never put 5 V on the chip or the SL 2 rail.
- **One power source.** SL 2 off USB whenever the Pi is clipped on.
- **In‑circuit contention:** powering the chip via the clip back‑feeds the board rail and
  can wake the FX2 onto the bus. The `check`/quiet‑gate catches this; if `write` keeps
  failing verify, **desolder U11** and program it on a breadboard (`--addr 0x50` if you
  strap A0 low there), then resolder.

## Don't re‑brick it
A healthy reflash depends on a complete, verified write. `pi-eeprom-24lc512.py` guards this:
it refuses to write unless the bus is provably quiet, backs up the current contents first,
fast‑fails if the first page doesn't take, and full‑verifies after writing — so the worst case
is a clean refusal, never a half‑written chip. If verify ever fails, re‑run `write` (it's
idempotent); if it keeps failing, desolder U11 and program it on a breadboard.

## Files here
- `pi/pi-eeprom-24lc512.py` — read / write / verify the 24LC512 from a Pi (safety‑gated)
- `extract-sl2-firmware.py` — build `eeprom-image-24lc512.bin` from your own driver copy
- `sl2flash.m`, `SL2Loader.{h,m}` — the over-USB loader (see `README.md` in this folder)
