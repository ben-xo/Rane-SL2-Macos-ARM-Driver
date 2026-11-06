# Rane SL 2 — USB command protocol

The SL 2 is controlled through 64-byte reports on its HID interface. This document lists
every command the SL 2's firmware accepts, what it does, and the unsolicited reports the
box sends back. It covers both firmware images the box can run:

- the **running firmware** — the normal audio device, booted from the box's EEPROM; and
- the **bootstrap** — a small EEPROM programmer that a host loads into RAM to restore the
  firmware (see `tools/firmware/UPLOAD-PROTOCOL.md`).

Both are reverse-engineered from the images in Rane's `SL2Api.framework` (Scratch Live
`SL2 1.0.1f4.pkg`); `tools/firmware/extract-sl2-firmware.py` extracts them from your own
copy. Command names in the "SL2Api" column are the names of the SL2Api functions that send
them. `tools/firmware/BOOTSTRAP-ANALYSIS.md` covers how the images were analysed and the
EEPROM-programming commands in depth.

## Transport

- USB interface 3 is a HID interface (class 3) with a 28-byte vendor-defined report
  descriptor (usage page `0xFF00`): 64-byte input and output reports, no report IDs.
- Commands go out on **EP1 interrupt OUT** (`0x01`), replies come back on **EP1 interrupt
  IN** (`0x81`), interval 1 at high speed.
- Every command gets at most one reply. The firmware handles one command at a time.
- Rane's Mac driver sent the reports through its kext's user client
  (`IOConnectCallMethod(selector=7, 60-byte struct)`); a kext-less host can open the EP1
  interrupt pipes directly or use the HID interface.

### Report layout

| byte | request | reply |
|------|---------|-------|
| 0 | opcode | opcode echoed; `0xFF` = rejected or unknown command |
| 1–4 | host-chosen 32-bit tag | the request's tag, copied back unchanged |
| 5… | arguments | results |

Every command except `0x00` and `0x06` copies the tag into its reply. Rane's driver puts a
sequence number there to match replies to requests; FX2 endpoint buffering can deliver a
stale reply, so a host should check the tag (or, for EEPROM commands, the echoed address).

## Commands

"Boot" and "run" give the handler address in the bootstrap and running firmware; `—` means
that image does not implement the command (it replies `0xFF`).

| op | SL2Api | boot | run | request | reply / effect |
|----|--------|------|-----|---------|----------------|
| `0x00` | — | `0870` | `0175` | — | ping: reply byte 0 = `0x00`; tag **not** echoed |
| `0x01` | `RH_get_firmware_version` | `087b` | `0180` | — | firmware version: `[5]` major, `[6]` minor, `[7..10]` 32-bit big-endian build stamp |
| `0x02` | `UpdateFinalFirmware` | `09a2` | `05a8` | `[5..6]` EEPROM address, `[7..38]` data | write 32 EEPROM bytes, reply with them read back; requires `0x17` first |
| `0x03` | — | `09dd` | `05e3` | `[5..6]` EEPROM address | read 32 EEPROM bytes: `[5..6]` address echoed, `[7..38]` the data; read-only, no `0x17` needed |
| `0x06` | — | `0878` | `017d` | — | does nothing; **no reply is sent** |
| `0x0a` | `RH_get_port_speed` | `08b0` | `01b6` | — | USB connection speed in `[5]`: 0 = not configured, 1 = full speed, 2 = high speed |
| `0x16` | `UpdateFinalFirmware` | `0a35` | `063c` | — | finalize: write `0xC2` boot header, disconnect, restart from EEPROM |
| `0x17` | `UpdateFinalFirmware` | `0a0d` | `0613` | — | begin: write `0xC0` (non-bootable) boot header, enable `0x02` |
| `0x1a` | `RH_set_alt_product_id` | — | `06bf` | — | reconnect to USB as product ID `0x0014` |
| `0x1b` | — | — | `06bf` | — | reconnect to USB as product ID `0x0013` (the normal identity) |
| `0x30` | `SL2_get_sample_rate` | `08d1` | `01db` | — | get the sample rate: `[5..6]`, big-endian |
| `0x31` | — | `08e7` | `01f1` | `[5..6]` sample rate, big-endian | set the sample rate; only 44100 and 48000 are accepted, anything else → `0xFF` |
| `0x36` | — | `0938` | `0250` | `[5]` on/off | enable (non-zero) or disable (zero) unsolicited `0x40` reports |
| `0x37` | `RH_driver_timer` | `0951` | `054b` | `[5..12]` 8-byte challenge | challenge/response (see below): `[5..12]` 8-byte response |
| `0x41` | (Hidi messages) | — | `0269` | `[5]` length (≤ 58), `[6..]` MIDI bytes | MIDI-style control messages, see below; `0xFF` if too long |
| `0x45` | `RH_get_usb_port_status` | `08be` | `01c8` | — | USB port status: `[5..6]` = `00 00`, always |
| other | | `0aac` | `0739` | — | unknown command: reply byte 0 = `0xFF` |

SL2Api's code is shared with other Rane devices and contains senders for opcodes the SL 2
does not implement (`0x13`, `0x14`, `0x15`, `0x42`); the SL 2 answers all of them `0xFF`.

### Details

- **`0x01` version.** The bootstrap reports `01 02`, the running firmware `01 0a`. The
  4-byte value is a constant at `CODE:0800` in each image; read as a Unix time it is
  2011-01-06 (bootstrap, `0x4D252003`) and 2011-01-29 (running, `0x4D4376D8`), so it is
  most likely a build timestamp.
- **`0x0a` port speed.** At full speed (a USB 1.1 port or hub) the SL 2 offers a different
  configuration with **only the HID interface** — no audio interfaces — and asks for
  100 mA instead of 300 mA. So the box needs a high-speed (USB 2.0) connection to pass
  audio; `0x0a` returning 1 is the way to tell.
- **EEPROM commands (`0x02`, `0x03`, `0x16`, `0x17`).** The running firmware implements
  them exactly as the bootstrap does, so a running box can be reflashed without loading
  the bootstrap. A consequence worth guarding against: **`0x17` sent to a working box
  immediately marks its EEPROM non-bootable**, and the box will come up in bootloader mode
  at its next power-up unless `0x16` follows. The layout and safe-programming sequence are
  in `tools/firmware/UPLOAD-PROTOCOL.md`. `sl2flash` (`tools/firmware/sl2flash.m`) uses
  these commands on both images, and both have been exercised on hardware.
- **`0x1a` / `0x1b` product ID.** Both images contain two USB device descriptors that are
  identical except for the product ID (`0x0013` and `0x0014`, both bcdDevice `0x0100`).
  In the running firmware these commands ack, power down the audio side (as for USB
  suspend, below) unless input PC7 is high, disconnect from USB, wait 1.5 s, and reconnect
  with the chosen descriptor. The choice is not stored: after a power cycle the box is
  `0x0013` again. SL2Api calls `0x1a` "set alternate product ID"; Rane's own kext only
  matches `0x0013`, and what the `0x0014` identity was for is not known. The bootstrap has
  the second descriptor but no command to select it.
- **`0x31` sample rate.** On a change of rate the running firmware mutes (output PA0 low)
  for 500 ms and switches the audio master clock (outputs PE4/PE5, one per rate). The
  default at power-up is 44100. The bootstrap stores the rate and reports it — including on
  EP0 as a 3-byte little-endian value, the format of the USB Audio Class sampling-frequency
  control — although it has no audio path; it shares this code with the running firmware.
- **`0x37` challenge/response.** The 8 request bytes are run through a routine
  (bootstrap `CODE:0100`, running `CODE:0804`) containing `0x9E3779B9`, the round
  constant of the TEA / XTEA block ciphers, which have an 8-byte block. A host only has to
  send a challenge; it does not need to check the answer. Rane's driver sends this
  periodically while streaming (SL2Api's `RH_driver_timer`).
  **The box does not enforce it.** The routine (`CODE:0804–0c7b`) only computes in
  internal RAM — no port, FPGA or flag access — and the handler copies the result into the
  reply and nothing else. The firmware has no timeout that `0x37` could be resetting:
  its only timers are the input debounce, the `0x31` mute and the LED blink. Nothing the
  8051 sends to the FPGA (the signals in the hardware map below) depends on `0x37` either.
  So the box behaves the same whether or not the challenge arrives; its evident purpose is
  to let the *host* software confirm it is talking to genuine Rane hardware.
- **`0x45` USB port status** returns zeros in both images, so it carries no information on
  the SL 2. SL2Api sends it (with `[5]=0`) when a box connects.
- **`0x06`** is a no-op in both images: the handler only re-arms EP1 OUT for the next
  command. It changes no state and sends **no reply**, so a host waiting for one will time
  out. SL2Api never sends it.

## `0x41` — Hidi messages (running firmware only)

The bytes from `[6]` are MIDI-style messages, processed in order:

| message | effect |
|---------|--------|
| Note Off `0x80`, note `0x5C` | deck 1 analogue thru **off** (USB audio) — output PE2 low |
| Note On `0x90`, note `0x5C` | deck 1 analogue thru **on** — PE2 high |
| Note Off / On, note `0x5D` | the same for deck 2 (PE1) |
| SysEx `F0 17 04 F7` | report the current state of notes `0x5C`, `0x5D`, `0x61`, `0x60` as `0x40` messages |

Each thru change is confirmed with an unsolicited `0x40` message (`0x81` / `0x91`, same note,
velocity `0x40`). At power-up both thru switches start **on** if input PC7 is high and
**off** if it is low.

## Unsolicited `0x40` reports (device → host)

`[0]=0x40`, `[1..4]=1C C5 00 13` (the USB identity, in place of a tag), `[5]` = byte count
(≤ 58), `[6..]` = Hidi messages using channel 2 (`0x81` Note Off / `0x91` Note On,
velocity `0x40`):

| note | sent when | meaning |
|------|-----------|---------|
| `0x5C` / `0x5D` | a `0x41` message changes it, or on a state dump | deck 1 / deck 2 analogue thru (On = thru on) |
| `0x60` | input PC7 changes (debounced), or on a state dump | state of PC7 |
| `0x61` | input PE0 changes, or on a state dump | state of PE0 |

These reports are sent **only after `0x36` has enabled them**; until then, queued messages
are discarded. The bootstrap contains the same sender but nothing in it ever queues a
message. What PC7 and PE0 are wired to on the board was not traced.

## Running-firmware hardware map (as far as traced)

| signal | direction | use |
|--------|-----------|-----|
| PA0 | out | mute: low for 500 ms on a sample-rate change |
| PA1 | out | toggled on every USB start-of-frame (8 kHz) while configured at high speed — a USB-timing reference, presumably for the FPGA |
| PA7 | out | status LED: blinks (250 ms) until the FPGA is loaded; then on while configured at high speed |
| PC0, PC1, PC2 | in, in, out | FPGA configuration — by their use in the loading sequence: INIT, DONE, PROG |
| PC5 | out (only in `0x16`) | pulsed low after disconnecting in `0x16`; most likely resets the FX2 so it reboots from EEPROM |
| PC6, PE4, PE5 | out | audio clock / power: PE4 = 44.1 kHz, PE5 = 48 kHz; all raised when powering down |
| PC7 | in | unknown input (debounced, 6 ms); reported as note `0x60`; decides the thru default and whether the audio side is powered down on suspend |
| PE0 | in | unknown input; reported as note `0x61`; a change also sends the word `0x8000` to the FPGA |
| PE1, PE2 | out | deck 2 / deck 1 analogue thru |
| PE6 | out | select line for 16-bit writes to the FPGA over serial port 0 |
| serial port 0 | out | FPGA configuration data and clock (LSB first), then 16-bit FPGA writes |

At startup the running firmware loads the board's **Xilinx Spartan-3A XC3S50A FPGA** from the EEPROM (bytes
`0x2A78–0xFFFF` of the 64 KiB image) before the audio interface works; see
`tools/firmware/BOOTSTRAP-ANALYSIS.md` → "The 64 KiB EEPROM image". Timings above assume
the firmware's 1 ms timer tick (Timer 0, mode 0, 48 MHz CPU clock / 12, reload `0x821F`).
