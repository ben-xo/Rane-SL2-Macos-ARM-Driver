# SL2 bootstrap firmware — device-side analysis (Ghidra, 8051)

Companion to `UPLOAD-PROTOCOL.md` (host side). This documents the **device side**:
what the A0-loaded bootstrap actually does with the bytes the host streams, and so
how and where the firmware persists. It also lists every command opcode the bootstrap
and the running SL 2 firmware handle.

## Sources and method
- **Bootstrap:** `sl2_bootstrap_firmware.deobfuscated.bin` (6247 B), produced by
  `extract-sl2-firmware.py` from your own copy of the official driver. Imported into Ghidra
  as raw binary at CODE:0000, language `8051:BE:16:default`. Reset vector `LJMP 0x1208`.
  Names of the form `FUN_CODE_xxxx` / `DAT_xxxx` are Ghidra's auto-generated labels from that
  import; the Ghidra project itself is not in the repo, so re-import the binary the same way
  to follow along.
- **Running firmware:** the payload of `sl2_final_firmware.deobfuscated.bin` (from offset
  `0x40`) is a standard EZ-USB "C2" EEPROM image: an 8-byte header, then load records of
  `[len:2 BE][addr:2 BE][data]`, ending with a record (top bit of `len` set) that writes
  CPUCS `0xE600`. Concatenating the records gives the 8051 code image (`0x0000–0x2181`).
- Ghidra does not follow the command jump table (see below), so its disassembly of the
  command handlers is misaligned in places. The handler descriptions here come from
  disassembling each jump-table target directly.

## Headline result — the firmware is persistent (EEPROM)
The board carries a **large I2C serial EEPROM** on the FX2's I2C bus at **7-bit
address `0x51`** (8-bit R/W addresses `0xA2`/`0xA3`) — a 16-bit-addressed part big
enough for the 64 KiB image (a 24LC512, U11). Normal boot = the FX2 **C2-boots the
firmware from this EEPROM** with no host, which is why a healthy SL 2 works on any
computer without a driver-side upload. Bootloader mode = the EEPROM's boot header has
been invalidated (`0xC0`), so the FX2 enumerates identity-only and waits for a host.

The A0-loaded bootstrap is an **EEPROM programmer**. It reprograms that EEPROM, so
after one successful reflash the device boots standalone again — it is **not** a
per-power-cycle RAM upload.

## FX2 registers the bootstrap uses
| addr | FX2 reg | use |
|------|---------|-----|
| `0xE600` | CPUCS | clock/reset |
| `0xE610–E615` | EP1OUTCFG…EP8CFG | endpoint config |
| `0xE678` | **I2CS** (14×) | I2C control/status (EEPROM) |
| `0xE679` | **I2DAT** (5×) | I2C data (EEPROM byte stream) |
| `0xE680` | USBCS | `DISCON` bit for re-enumeration |
| `0xE68A/B` | EP0BCH/L | EP0 arming |
| `0xE68D` | EP1OUTBC | EP1-OUT byte count (command ready) |
| `0xE68F` | EP1INBC | EP1-IN byte count (send reply) |
| `0xE6A0–A2` | EP0CS / EP1OUTCS / EP1INCS | endpoint busy status |
| `0xE6B3/B4` | SUDPTRH/L | descriptor responses |
| `0xE6B8–BF` | SETUPDAT | 8-byte control SETUP packet |
| `0xE740` | EP0BUF | control data |
| `0xE780` | **EP1OUTBUF** | inbound command reports |
| `0xE7C0` | **EP1INBUF** | outbound reply reports |

## Transport (device side) — EP1 interrupt endpoints
The command loop (`CODE:082b`) waits for `EP1OUTBC` (`0xE68D`) ≠ 0, reads the
report from `EP1OUTBUF` (`0xE780`), dispatches on the opcode, writes the reply into
`EP1INBUF` (`0xE7C0`) and arms it with `EP1INBC = 0x40` (`0xE68F`). So the Stage-2
channel is **EP1 interrupt OUT (commands) / EP1 interrupt IN (replies), 64-byte
reports**, byte[0] = opcode (echoed in the reply). EP1 belongs to interface 3, a HID
interface (class 3) with a 28-byte vendor-defined report descriptor. Rane's Mac driver
reached it through its kext user client (`IOConnectCallMethod(selector=7, 60-byte struct)`);
a kext-less host can open the EP1 interrupt pipes directly, as `sl2flash` does. The running
firmware uses the same transport and loop.

Opcode dispatch is an 8051 jump table (`FUN_CODE_073f`): inline records of
`[handlerHi][handlerLo][opcode]` straight after the dispatcher call (`CODE:0842`),
terminated by `00 00` and followed by the default handler's address. Both images' complete
tables are in `docs/SL2-COMMANDS.md`.

## Report layout (absolute byte offsets in the 64-byte report)

| byte | request | reply |
|------|---------|-------|
| 0 | opcode | opcode echoed (`0xFF` = rejected / unknown) |
| 1–4 | host-chosen 32-bit tag | the request's tag, copied back unchanged |
| 5… | command arguments | command results |

Every handler except `0x00` and `0x06` copies request bytes 1–4 into the reply (helper
`CODE:16dd` in the bootstrap). Rane's driver puts a sequence number there to match replies
to requests; `sl2flash` sends 0 and matches on the echoed address instead.

For the EEPROM commands:

| byte | `0x02` request | `0x03` request | reply to `0x02` / `0x03` |
|------|----------------|----------------|--------------------------|
| 5–6 | 16-bit EEPROM address, big-endian | same | address echoed |
| 7–38 | 32 data bytes | — | 32 bytes read back from the EEPROM |

The address is **not** at bytes 1–2 — that layout writes to the wrong EEPROM addresses.

## The three programming opcodes

### `0x17` — begin / invalidate  (`CODE:0a0d`)
Sets the "programming enabled" flag (bit `0x0d`), then writes boot-header byte **`0xC0`**
(non-bootable) to EEPROM address 0 on device `0x51`:
```
SETB 0x0d; DAT_2042/2043 = 00 00 (address); DAT_2044 = 0xC0
write 3 bytes @dev 0x51 (FUN_CODE_173f); ACK-poll (FUN_CODE_1580)
EP1INBUF[0] = 0x17   ; ack
```
Purpose: mark the EEPROM non-bootable *before* programming, so a power loss mid-flash
can't leave a half-written bootable image (safe-programming).

### `0x02` — write body block  (`CODE:09a2`; I2C engine `FUN_CODE_1100`)
- **Refused unless `0x17` has been sent first** (flag bit `0x0d`): otherwise the reply is
  `0xFF` and nothing is written.
- Takes the address from `EP1OUTBUF[5..6]` and 32 data bytes from `EP1OUTBUF[7..38]`.
- **Address 0 only: it overwrites the first 5 data bytes with `C0 C5 1C 13 00`**
  regardless of what the host sent (C0 = non-bootable lead byte, `1C C5` = VID,
  `00 13` = PID). So those 5 bytes always read back as the identity header.
- Writes the 34 bytes at `EP1OUTBUF[5..38]` (`[addrHi][addrLo][32 data]`) to EEPROM dev
  `0x51` as one I2C page write.
- Then **ACK-polls** (`FUN_CODE_1580`: repeat START + device address until the EEPROM
  ACKs), i.e. **waits for the ~5 ms EEPROM write cycle to finish**.
- Then falls into the `0x03` handler to build the reply.

### `0x03` — read block  (`CODE:09dd`)
Echoes the opcode and tag, copies the address to `EP1INBUF[5..6]`, writes the 2-byte
address to the EEPROM to set its read pointer, then **reads 32 bytes** into
`EP1INBUF[7..38]` and arms `EP1INBC=0x40`.

### `0x16` — finalize  (`CODE:0a35`)
Writes boot-header byte **`0xC2`** (bootable) to EEPROM address 0, acks, waits for the
reply to leave EP1-IN, then re-enumerates so the FX2 re-boots from the freshly written
EEPROM:
```
DAT_2042/2043 = 00 00; DAT_2044 = 0xC2; write 3 bytes @dev 0x51; ACK-poll
EP1INBUF[0] = 0x16   ; ack, then wait while EP1INCS busy
clear EP1OUT/IN cfg (0xE610–E615); USBCS |= DISCON (0xE680); wait 1000 ms (FUN_CODE_14f6)
pulse port C bit 5 (SETB/CLR 0xA5, OEC |= 0x20)
```
`0x16` does **not** check the "programming enabled" flag. PC5 is otherwise never driven —
the running firmware's port setup leaves it an input — so `0x16` makes it an output only to
pull it low after disconnecting. It is not traced on the board, but the sequence fits a
line to the FX2's reset, making the chip reboot from the freshly written EEPROM.

## Write + read-back mechanics — which read-back differences are expected

Every `0x02` is **write page → wait for write cycle → read page back**, all in one
round-trip. The reply is the *actual EEPROM contents*, not an echo, and it carries
its own address in `EP1INBUF[5..6]`, so a response can be matched to the chunk it belongs to.

**The only *expected* read-back differences are:**
1. bytes 0..4 of the image — forced to `C0 C5 1C 13 00` on the first-block write; and
2. byte 0 again after `0x16` finalize — flipped `0xC0` → `0xC2` (bootable).

Any other differences are not the protocol transforming data. The likely causes in a
host implementation:
- **Response/request mis-correlation.** The device read-back is reliable, but if the host
  reads an EP1-IN packet without matching it to the request, FX2 endpoint buffering can
  hand it the *previous* chunk's reply → everything looks shifted by one block.
  **Fix:** validate each reply against the address it echoes in `EP1INBUF[5..6]`, the
  echoed opcode in `[0]`, and/or the tag in `[1..4]`; don't assume strict packet ordering.
- **Bypassing the device's ACK-poll.** If the host writes with one command and
  immediately reads with `0x03` without anything waiting for the write cycle, the read
  races the ~5 ms write and returns stale or partial bytes. `0x02` ACK-polls internally,
  so using its own reply avoids this.

## Other commands
Besides the four EEPROM commands, the bootstrap and the running firmware accept a dozen more
(identify, port speed, sample rate, the `0x37` challenge, …), and the running firmware adds
`0x1a`/`0x1b`/`0x41`. `docs/SL2-COMMANDS.md` lists every opcode both images implement,
with their handler addresses, plus the unsolicited `0x40` reports.

## The 64 KiB EEPROM image
The final image's 64 KiB payload is not all 8051 code:

| EEPROM range | contents |
|--------------|----------|
| `0x0000–0x0007` | C2/C0 boot header: lead byte, VID, PID, DID, config byte |
| `0x0008–0x21AD` | 8051 code as EZ-USB load records (code `0x0000–0x2181`), ending with the CPUCS record |
| `0x21AE–0x2A77` | unused (`0xFF`) |
| `0x2A78–0xFFFF` | **FPGA configuration bitstream** for the board's Xilinx Spartan-3A XC3S50A (54,664 bytes) |

The FX2's boot ROM stops at the CPUCS record, so it never reads the bitstream. The running
firmware loads it itself at startup: it reads EEPROM bytes `0x2A98–0x2A99` and requires
`55 99`, pulses PC2 (PROG), checks PC0 (INIT), then reads the EEPROM from `0x2A78` to the end
in 64-byte blocks and shifts each byte out through the 8051 serial port (mode 0, LSB first),
and finally clocks until PC1 (DONE) rises. Because the serial port sends LSB first, the
bitstream is stored bit-reversed: reversed, it begins with `FF…FF AA99 30A1 0007 …` — the
Xilinx sync word followed by Spartan-3A 16-bit configuration packets. The length matches
too: 54,664 bytes is exactly the XC3S50A's configuration size (437,312 bits). Until the FPGA is loaded the
status LED blinks and the audio side stays powered down.

So the whole 64 KiB matters: a reflash that wrote only the 8051 code would leave a box that
enumerates but, by the firmware's own logic, never starts its audio side.

## I2C primitives
- `FUN_CODE_1100` / `CODE:1120–11db` — low-level I2C: set START/STOP via `I2CS`
  (`0xE678`, bit7=START `ORL #0x80`, bit6=STOP `ORL #0x40`), byte in/out via `I2DAT`
  (`0xE679`), poll DONE/ACK in `I2CS`.
- `FUN_CODE_173f` → `FUN_CODE_1622` — write N bytes to an I2C device.
- `FUN_CODE_1723` — read N bytes from an I2C device (used by `0x03`).
- `FUN_CODE_1580` — ACK-poll: wait until the EEPROM finishes its write cycle.
- `FUN_CODE_1654` (called from `CODE:10cc`) — I2C read (used for the C0/C2 state check,
  i.e. what the host's `_SL2_is_C0_device` queries).
- EEPROM device selection: `R7 = 0x51`; the engine forms 8-bit `0xA2` (write) / `0xA3`
  (read) — confirmed by `CJNE A,#0xA2` / `ADD A,#0xA1` sites.

## What this means for `sl2flash`
1. The host does **not** reimplement the bootstrap — it talks to it, replaying the host
   protocol in `UPLOAD-PROTOCOL.md`:
   - Stage 1: EP0 control `bRequest=0xA0` to load `sl2_bootstrap_firmware.deobfuscated.bin`
     to RAM @0 and run it (CPUCS `0xE600`).
   - Stage 2: 64-byte reports on EP1 interrupt OUT — `0x17` begin, then `0x02` blocks
     (layout above) across the 64 KiB payload, then `0x16` finalize. Read the EP1 IN reply
     after each; byte 0 echoes the opcode.
2. It is a **one-time repair**. After `0x16` the EEPROM is C2/bootable and the device
   ReNumerates as the running audio device; it then boots firmware on its own.
3. Once started, the bootstrap enumerates **exactly like a working SL 2**: its 512-byte
   descriptor block (device, qualifier, both configurations, HID report descriptor, strings
   including "Rane SL 2" and the audio interfaces) is byte-identical to the running
   firmware's, bcdDevice `0x0100` included. Nothing in USB enumeration tells them apart;
   command `0x01` does (version `01 02` for the bootstrap, `01 0a` for the running
   firmware). So an audio driver that matches on VID/PID/bcdDevice will see the bootstrap
   as an SL 2 and may try to open it during a flash.
4. Safe-programming is built in (C0 before, C2 after). If a flash is interrupted
   between `0x17` and `0x16`, the EEPROM is left C0 (non-bootable) → the device returns to
   bootloader mode and the whole sequence can simply be run again. The dangerous case is
   finalizing a wrong image, which is why `sl2flash` verifies the whole EEPROM with `0x03`
   before sending `0x16`.
5. The device identity (VID `0x1CC5` / PID `0x0013`) lives in the EEPROM identity bytes.
   If the box enumerates as `1cc5:0013` with `bcdDevice 0x0000`, those bytes are intact and
   this over-USB path can reach it. If they are lost too, the box needs the direct EEPROM
   reflash in `RECOVERY.md`.

## Confidence summary
- **Confirmed:** EEPROM at I2C `0x51` (64 KiB); C0/C2 safe-programming via `0x17`/`0x16`;
  EP1 interrupt transport; the `0x02`/`0x03` byte layout and the tag echo in bytes 1–4.
- **Confirmed:** the layout of the 64 KiB image, including the FPGA bitstream and the
  sequence that loads it.
- **Inferred:** that PC5 resets the FX2.
