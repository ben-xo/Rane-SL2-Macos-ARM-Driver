# Rane SL2 firmware-upload protocol (reverse-engineered)

Source: `SL2Api.framework` (Scratch Live `SL2 1.0.1f4.pkg`), reverse-engineered with Ghidra.
Function names below (`UpdateFinalFirmware`, `_SL2_is_C0_device`, …) are the framework's own
exported symbols. Original source path leaked in asserts:
`/projects/Rane/SL3/mac/Sl3Api/source/SixtyEightApiState.mm`.

This is the host side of the protocol. `BOOTSTRAP-ANALYSIS.md` covers the device side;
`sl2flash` (`sl2flash.m`) is this folder's implementation of it.

## Hardware
- USB controller is a **Cypress EZ-USB FX2** family part (8051 core; CPUCS reset
  register at `0xE600`). Both firmware images are 8051 code.
- Device identity: **VID `0x1CC5`, PID `0x0013`**.
  - `bcdDevice 0x0000` = bootloader / "C0" mode: no firmware running, no audio
  - `bcdDevice 0x0100` = running audio+HID device (after upload). The bootstrap, once
    started by Stage 1, enumerates identically — same descriptors, same bcdDevice — so
    only command `0x01` (version) tells them apart (`BOOTSTRAP-ANALYSIS.md`).

## Persistence model (important)
Firmware is **not** volatile RAM that is re-uploaded on every plug-in. The board has an
**I2C EEPROM** (standard EZ-USB boot EEPROM):
- **C2 EEPROM** (lead byte `0xC2`) = full firmware in EEPROM; the FX2 boots it at
  power-on, no host needed. This is the normal, healthy state.
- **C0 EEPROM** (lead byte `0xC0`) = only VID/PID/DID present, no firmware; the FX2
  enumerates with those IDs and waits for a host download. A box whose firmware has been
  lost or invalidated ends up here.

The host checks this with `_SL2_is_C0_device`. The A0-loaded bootstrap is a
RAM-resident **EEPROM programmer**; Stage 2's `0x02` stream is written to the EEPROM,
so after reboot the device C2-boots the new firmware. Reflash once → persists.

## On-connect orchestration (`_SL2_set_update_firmware_from_embedded`)
1. `_SL2_is_C0_device(dev)` — if **C0** (boot mode): run **Stage 1** (bootstrap), then
   wait for re-enumeration (poll `OpenUserClient`, up to ~29×).
2. Run **Stage 2** (final firmware), then wait for re-enumeration (up to ~30×) as the
   running `bcdDevice 0x0100` device.
   (If the device is not in C0 mode, Stage 1 is skipped: the running firmware implements
   the same Stage 2 commands as the bootstrap, so a running box can be reflashed directly.)

## Firmware images
`extract-sl2-firmware.py` produces both from your own copy of the official driver
(they are not in this repo):
- `sl2_bootstrap_firmware.deobfuscated.bin` — 6247 B, raw 8051, loaded to RAM @0
- `sl2_final_firmware.deobfuscated.bin` — 65600 B = `0x40` header + **`0x10000` (64 KiB) payload**
  - Header (`IsValidFirmwareImage`): `[0x00]` "Copyright 20?? Rane Corporation",
    `[0x20]` 7-byte id `01 1C C5 00 13 01 00`, `[0x38]` BE payload length,
    `[0x3C]` BE payload checksum (CRC-32). Payload starts at `0x40`.
  - The payload is the full EEPROM image: the 8051 code as EZ-USB boot records, then a
    Xilinx FPGA bitstream that the firmware loads at startup (`BOOTSTRAP-ANALYSIS.md` →
    "The 64 KiB EEPROM image"). All 64 KiB must be written.

The upload is two stages. In bootloader mode you run **Stage 1**, then the device
exposes the EP1 command interface used by **Stage 2**.

---

## Stage 1 — Bootstrap, via EP0 vendor control transfers (`UpdateBootstrapFirmware`)

Standard EZ-USB "A0" RAM download. All transfers: `bRequest = 0xA0`, `wIndex = 0`.

1. **Halt 8051:** `bmRequestType=0x40, bRequest=0xA0, wValue=0xE600, wLength=1, data=[0x01]`
2. **Download** `sl2_bootstrap_firmware.deobfuscated.bin` (6247 B) in ≤32-byte chunks:
   for offset = 0, 32, 64, …: `bmRequestType=0x40, bRequest=0xA0, wValue=offset,
   wLength=chunkLen, data=chunk`
3. **(Optional) verify:** re-read each chunk with `bmRequestType=0xC0, bRequest=0xA0,
   wValue=offset, wLength=chunkLen` and compare.
4. **Run 8051:** `bmRequestType=0x40, bRequest=0xA0, wValue=0xE600, wLength=1, data=[0x00]`

The bootstrap now runs, re-enumerates, and accepts Stage 2 commands. Poll for the new
device before continuing.

---

## Stage 2 — Final firmware, via 64-byte reports on EP1 (`UpdateFinalFirmware`)

Transport: each command is a **64-byte report** sent on **EP1 interrupt OUT**; the device
replies with a 64-byte report on **EP1 interrupt IN** whose byte 0 echoes the opcode.
EP1 belongs to the box's HID interface (interface 3); SL2Api calls these "HID requests"
(`SendHidRequest`/`PostHidRequest`) and sent them through Rane's kext user client
(`IOConnectCallMethod(selector=7, inStruct=60B)`). A kext-less host can open the EP1
interrupt pipes itself; `sl2flash` instead sends the reports through this project's HAL
driver, which holds the interface (its `sl2h` passthrough, `tools/SL2Passthrough.h`).

The bootstrap programs a 64 KiB I2C EEPROM (device `0x51`): `0x17` writes the
non-bootable `0xC0` boot header, `0x02` writes the body at the supplied 16-bit address,
`0x16` writes the bootable `0xC2` header and re-enumerates. So the write is
**persistent** (safe-programmed C0 → body → C2); it is a one-time repair, not a per-boot
RAM load. See `BOOTSTRAP-ANALYSIS.md` for the device-side evidence.

### Report layout — use these absolute byte offsets

| byte | `0x02` write request | `0x03` read request | reply to `0x02` / `0x03` |
|------|---------------------|---------------------|--------------------------|
| 0 | `0x02` | `0x03` | opcode echoed |
| 1–4 | tag | tag | tag echoed |
| 5 | EEPROM address, high byte | address high | address echoed, high |
| 6 | EEPROM address, low byte | address low | address echoed, low |
| 7–38 | 32 data bytes | — | 32 bytes read back from the EEPROM |
| 39–63 | `0` | `0` | — |

The address is **not** at bytes 1–2. Bytes 1–4 are a host-chosen 32-bit tag that the
device copies into the reply unchanged; Rane's driver uses a sequence number there, and so
does `sl2flash`, which also checks the echoed address. Getting this layout wrong writes the image to the wrong EEPROM
addresses — and if that image is then finalized with `0x16`, the box is bricked (see
`RECOVERY.md`).

### Sequence

1. **Begin:** opcode **`0x17`**, rest of the report zero. The device marks the EEPROM
   non-bootable (`0xC0`) and acks.
2. **Write blocks:** for each 32-byte chunk of the **payload** (image bytes from `0x40`,
   64 KiB total → 2048 chunks), send a `0x02` report with EEPROM address = chunkIndex × 32.
   The last chunk may be < 32 bytes.
   - **The device writes the page to its EEPROM, waits for the write cycle (ACK-poll),
     then reads the 32 bytes back from EEPROM and returns them** in the same reply. So
     the reply is the real EEPROM contents, not an echo.
   - The Rane driver verifies **per chunk, interleaved** (write → reply → compare → next;
     abort on mismatch) — it does not write everything then read back separately.
   - Match each reply to its request by the echoed address in bytes 5–6: FX2 endpoint
     buffering can otherwise hand you the previous chunk's reply.
   - Expected read-back differences: image bytes 0..4 are forced to the identity header
     `C0 C5 1C 13 00`, and byte 0 becomes `0xC2` after finalize. Anything else differing
     is a real write failure or a mis-correlated reply, not a protocol transform. See
     `BOOTSTRAP-ANALYSIS.md` → "Write + read-back mechanics".
3. **Finalize:** opcode **`0x16`**, rest of the report zero. The device writes the
   bootable `0xC2` header, then disconnects and re-enumerates; the FX2 boots the new
   firmware from EEPROM and comes back as `bcdDevice 0x0100`.

`0x16` is the irreversible step: it makes whatever is in the EEPROM bootable. `sl2flash`
therefore re-reads the whole image with `0x03` and only sends `0x16` if every byte matches.
If anything fails before `0x16`, the EEPROM stays `0xC0` and the box returns to bootloader
mode at its next power-up (a running box keeps working until then), ready for another attempt.

---

## Programming opcodes
| opcode | meaning |
|--------|---------|
| `0x17` | begin: write `0xC0` (non-bootable) boot header; required before `0x02` |
| `0x02` | write a 32-byte EEPROM block and read it back (layout above) |
| `0x03` | read a 32-byte EEPROM block (layout above) |
| `0x16` | finalize: write `0xC2` boot header, re-enumerate into the new firmware |

The bootstrap and the running firmware handle further commands (identify, sample rate,
the `0x37` challenge, …); `docs/SL2-COMMANDS.md` (at the repository root) lists every opcode
both images accept.

## Implementation notes
- The audio driver (`plugin/SL2Device.m`) only *detects* a bootloader-mode box and reports
  it; it never writes firmware. Loading is done by the standalone `sl2flash` tool.
- Stage 1 = IOUSBHost control transfers on EP0. `sl2flash` opens the bootloader-mode box
  itself, as a normal user (no root needed); the driver never opens a box in that mode.
- Stage 2 = 64-byte interrupt transfers on EP1 OUT, each followed by one EP1 IN reply.
  The bootstrap enumerates like a running box, so the driver opens it as one, and `sl2flash`
  sends Stage 2 through the driver in both cases.
- Before writing, `sl2flash` reads the EEPROM: if it already holds the image, a running box
  is left alone and a bootloader-mode box only gets `0x16`.
- Use the **de-obfuscated** images. The XOR-256 key (`sl2_xor_key_256.bin`, also written
  by `extract-sl2-firmware.py`) is only how they were stored in the Mac binary; the device
  expects de-obfuscated bytes.
- Don't commit or ship the proprietary images (see `README.md` in this folder).
