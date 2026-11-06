#!/usr/bin/env python3
"""Read / write / verify a 24LC512 (64 KB I2C EEPROM) from a Raspberry Pi — safely.

Flashes `eeprom-image-24lc512.bin` onto the Rane SL2's boot EEPROM (U11) so the box boots
again. **The primary reference is ../RECOVERY.md** — read it first: it has the clip wiring,
the Pi setup, the step-by-step procedure, and the electrical-safety warning (3.3 V only; the
SL2 off USB while the Pi powers the chip — an electrical mistake can permanently damage the
box). This header only summarises the command-line interface.

`write` is guarded so an interrupted or contended write can't silently re-brick the box:
pre-flight bus scan, a "bus quiet" stability gate (repeated reads must match — the FX2
back-powering the bus shows up as unstable reads), a timestamped backup before writing,
first-page fast-fail, and a full read-back verify. Worst case is a clean refusal.

Usage:
    pi-eeprom-24lc512.py scan                       # list responding I2C addresses
    pi-eeprom-24lc512.py check        [--addr 0x51] # bus-quiet / stability test only
    pi-eeprom-24lc512.py read  dump.bin
    pi-eeprom-24lc512.py verify eeprom-image-24lc512.bin
    pi-eeprom-24lc512.py write eeprom-image-24lc512.bin        # backup + write + verify
Flags: --bus N (default 1)  --addr 0xNN (default 0x51)  --yes  --no-backup  --samples N
"""
import argparse, datetime, os, sys, time
try:
    from smbus2 import SMBus, i2c_msg
except ImportError:
    sys.exit("smbus2 not installed:  pip3 install smbus2   (or --break-system-packages)")

SIZE = 65536          # 24LC512 = 512 Kbit = 64 KB
PAGE = 128            # write page size — writes must not cross a 128-byte boundary
CHUNK = 128           # read chunk — keep well under the kernel I2C transfer limit
TWC = 0.006           # write-cycle time (datasheet max 5 ms; 6 ms for margin)
PROBE = 256           # bytes sampled by the bus-quiet test
READ_RETRY = 3        # transient read retries


def _rd(bus, addr, off, n):
    w = i2c_msg.write(addr, [(off >> 8) & 0xFF, off & 0xFF])
    r = i2c_msg.read(addr, n)
    bus.i2c_rdwr(w, r)
    return bytes(list(r))   # list(msg) is the smbus2-documented way to get the data


def read_block(bus, addr, off, n):
    last = None
    for _ in range(READ_RETRY):
        try:
            return _rd(bus, addr, off, n)
        except OSError as e:
            last = e
            time.sleep(0.002)
    raise last


def read_all(bus, addr, size=SIZE):
    out = bytearray()
    for off in range(0, size, CHUNK):
        out += read_block(bus, addr, off, min(CHUNK, size - off))
    return bytes(out)


def responds(bus, addr):
    try:
        _rd(bus, addr, 0, 1)
        return True
    except OSError:
        return False


def scan(bus):
    return [a for a in range(0x50, 0x58) if responds(bus, a)]


def bus_quiet(bus, addr, samples):
    """Return (ok, detail). Reads the probe region `samples` times; a quiet bus with a
    static EEPROM yields byte-identical results every time. Variation or errors mean the
    bus isn't ours alone (FX2 back-powering/driving) — not safe to write."""
    ref, errs = None, 0
    for _ in range(samples):
        try:
            cur = _rd(bus, addr, 0, PROBE)
        except OSError as e:
            errs += 1
            continue
        if ref is None:
            ref = cur
        elif cur != ref:
            return False, "reads are not repeatable (bus is being driven by something else)"
        time.sleep(0.01)
    if ref is None:
        return False, f"no readable response at 0x{addr:02x} ({errs} errors)"
    if errs:
        return False, f"{errs}/{samples} reads errored (intermittent bus/clip contact)"
    return True, f"{samples} identical reads — bus looks quiet"


def preflight(bus, addr, samples, need_quiet):
    print("Pre-flight: make sure the SL2 is NOT plugged into USB, and the chip is 3.3 V.")
    found = scan(bus)
    if not found:
        sys.exit("nothing responds on the I2C bus; check the clip/wiring, power, and "
                 "`i2cdetect -y <bus>`")
    print(f"responding I2C addresses: {', '.join('0x%02x' % a for a in found)}")
    if addr not in found:
        sys.exit(f"target 0x{addr:02x} does not respond; try --addr "
                 f"{' or '.join('0x%02x' % a for a in found)}")
    if len(found) > 1:
        print(f"note: more than one address answered — make sure 0x{addr:02x} is the EEPROM")
    ok, detail = bus_quiet(bus, addr, samples)
    print(("bus check: " + detail) if ok else ("BUS NOT QUIET: " + detail))
    if not ok and need_quiet:
        sys.exit("refusing to write. If in-circuit, the FX2 is back-powering the bus — "
                 "hold it in reset, or desolder U11 and program it on a breadboard.")
    return ok


def confirm(prompt):
    try:
        return input(prompt + " [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def backup(bus, addr, outdir):
    data = read_all(bus, addr)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(outdir, f"eeprom-backup-0x{addr:02x}-{ts}.bin")
    with open(path, "wb") as f:
        f.write(data)
    print(f"backup of current contents → {path} (byte0=0x{data[0]:02x})")
    return data, path


def write_all(bus, addr, data):
    for off in range(0, len(data), PAGE):
        chunk = data[off:off + PAGE]
        bus.i2c_rdwr(i2c_msg.write(addr, [(off >> 8) & 0xFF, off & 0xFF] + list(chunk)))
        time.sleep(TWC)
        # fast-fail: confirm the very first page actually took before writing 64 KB
        if off == 0:
            back = read_block(bus, addr, 0, PAGE)
            if back != chunk:
                i = next(k for k in range(PAGE) if back[k] != chunk[k])
                sys.exit(f"first page did not verify (wrote 0x{chunk[i]:02x}, read 0x{back[i]:02x} "
                         f"at 0x{i:04x}) — chip is write-protected (WP not grounded) or the bus "
                         f"is contended. Nothing further written.")
            print("first page verified; writing the rest…", flush=True)
        elif off % 8192 == 0:
            print(f"  {off}/{len(data)} bytes", flush=True)


def load_image(path):
    data = open(path, "rb").read()
    if len(data) != SIZE:
        sys.exit(f"{path} is {len(data)} bytes; a 24LC512 image must be exactly {SIZE}")
    if data[0] not in (0xC0, 0xC2):
        print(f"warning: image byte0 is 0x{data[0]:02x}, not 0xC0/0xC2 — is this an FX2 "
              f"boot image? (the SL2 recovery image should be 0xC2)")
    return data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["scan", "check", "read", "verify", "write"])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--bus", type=int, default=1)
    ap.add_argument("--addr", type=lambda x: int(x, 0), default=0x51)
    ap.add_argument("--samples", type=int, default=5, help="bus-quiet read samples")
    ap.add_argument("--yes", action="store_true", help="skip the write confirmation")
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()

    with SMBus(a.bus) as bus:
        if a.action == "scan":
            found = scan(bus)
            print("responding:", ", ".join("0x%02x" % x for x in found) or "(none)")
            return
        if a.action == "check":
            preflight(bus, a.addr, a.samples, need_quiet=False)
            return

        if not a.file:
            sys.exit("this action needs a file argument")

        if a.action == "read":
            preflight(bus, a.addr, a.samples, need_quiet=False)
            data = read_all(bus, a.addr)
            with open(a.file, "wb") as f:
                f.write(data)
            print(f"read {len(data)} bytes → {a.file}")
            print(f"  byte0=0x{data[0]:02x} (C2=bootable, C0=identity-only, else garbage)  "
                  f"header={data[:8].hex()}")
            return

        want = load_image(a.file)

        if a.action == "verify":
            preflight(bus, a.addr, a.samples, need_quiet=False)
            got = read_all(bus, a.addr)
            if got == want:
                print("VERIFY OK — EEPROM matches the image.")
            else:
                diffs = [i for i in range(SIZE) if got[i] != want[i]]
                print(f"VERIFY FAILED — {len(diffs)} byte(s) differ, first at 0x{diffs[0]:04x} "
                      f"(image 0x{want[diffs[0]]:02x}, chip 0x{got[diffs[0]]:02x})")
                sys.exit(1)
            return

        # ---- write ----
        preflight(bus, a.addr, a.samples, need_quiet=True)
        cur = None
        if not a.no_backup:
            cur, _ = backup(bus, a.addr, os.path.dirname(os.path.abspath(a.file)) or ".")
        print(f"about to WRITE {len(want)} bytes to 0x{a.addr:02x} on i2c-{a.bus}"
              + (f"  (chip byte0 0x{cur[0]:02x} → image byte0 0x{want[0]:02x})" if cur else ""))
        if not a.yes and not confirm("proceed?"):
            sys.exit("aborted.")
        print("writing…", flush=True)
        write_all(bus, a.addr, want)
        print("verifying…", flush=True)
        got = read_all(bus, a.addr)
        if got == want:
            print("VERIFY OK — unclip, plug the SL2 into USB; it should boot its firmware.")
        else:
            diffs = [i for i in range(SIZE) if got[i] != want[i]]
            print(f"VERIFY FAILED after write — {len(diffs)} byte(s) differ, first at "
                  f"0x{diffs[0]:04x} (image 0x{want[diffs[0]]:02x}, chip 0x{got[diffs[0]]:02x}). "
                  f"Re-run 'write' (it's idempotent); if it keeps failing, the FX2 is "
                  f"contending — desolder U11 and program on a breadboard.")
            sys.exit(1)


if __name__ == "__main__":
    main()
