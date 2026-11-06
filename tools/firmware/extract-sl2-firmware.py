#!/usr/bin/env python3
"""Extract and de-obfuscate the Rane SL2 firmware images from the official macOS driver.

Source  : Serato Scratch Live installer DMG ->
          "Rane Device Drivers/SL2/SL2 1.0.1f4.pkg"
          (inside the pkg: Library/Frameworks/SL2Api.framework/Versions/A/SL2Api)
Output  : eeprom-image-24lc512.bin                  (65536 B, ready for a direct EEPROM reflash
                                                     with pi-eeprom-24lc512.py — boot header 0xC2)
          sl2_final_firmware.deobfuscated.bin       (65600 B: 0x40 Rane header + 64 KiB payload)
          sl2_bootstrap_firmware.deobfuscated.bin   (6247 B, 8051, the over-USB RAM loader)
          sl2_xor_key_256.bin                       (the 256-byte de-obfuscation key)

The direct-EEPROM path (this folder's RECOVERY.md) is the one proven on the hardware; it
uses eeprom-image-24lc512.bin. The de-obfuscated .bin pair is what an over-USB loader would use.

The two firmware images are embedded as static arrays inside the x86_64 slice of the
SL2Api dylib and obfuscated with a 256-byte repeating XOR key (kKeyBytes):
out[i] = in[i] ^ key[i % 256].

No vendor code is executed. Requires: macOS tools pkgutil, cpio, lipo, nm, otool.

Usage:
  extract-sl2-firmware.py <path-to-"SL2 1.0.1f4.pkg"> [outdir]
  extract-sl2-firmware.py "/Volumes/ScratchLive Installer" [outdir]   # finds the pkg
"""
import os, subprocess, sys, tempfile, zlib

# Offsets/sizes verified for SL2 1.0.1f4 (SL2Api, x86_64 slice). The script locates the
# arrays by symbol name (robust across identical builds); sizes are the exact memcpy
# lengths from Update{Final,Bootstrap}FirmwareFromEmbedded. A header check catches drift.
FINAL_LEN = 0x10040      # 65600
BOOT_LEN  = 0x1867       # 6247
KEY_LEN   = 0x100        # 256
SYM_FINAL = "UpdateFinalFirmwareFromEmbedded"
SYM_BOOT  = "UpdateBootstrapFirmwareFromEmbedded"
SYM_KEY   = "kKeyBytes"


def run(*cmd, **kw):
    """Run a command and return its stdout, raising if it fails."""
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def find_pkg(p):
    """Return the SL2 .pkg: the argument itself if it is one, else the first found under it."""
    if os.path.isfile(p) and p.endswith(".pkg"):
        return p
    for root, _, files in os.walk(p):
        for f in files:
            if f.endswith(".pkg") and "SL2" in f:
                return os.path.join(root, f)
    sys.exit(f"could not find an 'SL2*.pkg' under {p}")


def thin_slice(pkg, work):
    """Expand the pkg under `work` and return the path to SL2Api's x86_64 slice (also under
    `work`). nm/otool need a single-arch Mach-O to report unambiguous addresses; the slice is
    an intermediate, discarded with `work`."""
    run("pkgutil", "--expand", pkg, os.path.join(work, "pkg"))
    # The pkg Payload is a gzip'd cpio archive of the installed files; unpack it.
    payload = os.path.join(work, "pkg", "SL2.pkg", "Payload")
    extract = os.path.join(work, "payload"); os.makedirs(extract)
    with open(payload, "rb") as fp:
        gz = subprocess.Popen(["gunzip", "-c"], stdin=fp, stdout=subprocess.PIPE)
        subprocess.run(["cpio", "-idm"], stdin=gz.stdout, cwd=extract,
                       check=True, capture_output=True)
        gz.wait()
    fw = os.path.join(extract, "Library/Frameworks/SL2Api.framework/Versions/A/SL2Api")
    thin = os.path.join(work, "slice")
    run("lipo", "-thin", "x86_64", fw, "-output", thin)
    return thin


def const_section(binpath):
    """Return (vmaddr, fileoffset) of the __TEXT,__const section — the map from a symbol's
    vmaddr to its byte offset in the file."""
    seg = None
    out = run("otool", "-l", binpath).splitlines()
    for i, line in enumerate(out):
        s = line.strip()
        if s.startswith("segname "):
            seg = s.split()[1]
        if s == "sectname __const" and seg == "__TEXT":
            addr = offset = None
            for j in range(i + 1, i + 8):
                t = out[j].strip()
                if t.startswith("addr "):   addr = int(t.split()[1], 16)
                if t.startswith("offset "): offset = int(t.split()[1])
            return addr, offset
    sys.exit("could not locate __TEXT,__const")


def symbol_addr(binpath, needle, want_local=True):
    """Return the vmaddr of the first symbol whose name contains `needle` (a local data symbol)."""
    for line in run("nm", "-n", binpath).splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        addr, typ, name = parts[0], parts[1], " ".join(parts[2:])
        if needle in name and (not want_local or typ in ("s", "S", "d", "D")):
            return int(addr, 16)
    sys.exit(f"symbol containing {needle!r} not found")


def carve(binpath, vmaddr, length, const_addr, const_off):
    """Read `length` bytes of __const at `vmaddr` from the file, via the section's vmaddr->fileoff."""
    foff = const_off + (vmaddr - const_addr)
    with open(binpath, "rb") as f:
        f.seek(foff)
        return f.read(length)


def deobfuscate(data, key):
    """Undo the repeating-XOR obfuscation on `data` with `key`."""
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def main():
    # Parse arguments: the pkg (or a dir/volume to search) and the output directory.
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    pkg = find_pkg(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else "sl2-fw-out"
    os.makedirs(out, exist_ok=True)
    print(f"[*] pkg   : {pkg}")

    # Unpack the driver and pull the embedded arrays out of its binary. All of this works in a
    # temp dir that is discarded on exit, so no copy of the vendor binary is left behind.
    with tempfile.TemporaryDirectory(prefix="sl2fw.") as work:
        binpath = thin_slice(pkg, work)

        # Locate the two firmware images and the XOR key by symbol name, mapping each vmaddr to
        # a file offset via the __TEXT,__const section.
        const_addr, const_off = const_section(binpath)
        a_final = symbol_addr(binpath, SYM_FINAL)
        a_boot  = symbol_addr(binpath, SYM_BOOT)
        a_key   = symbol_addr(binpath, SYM_KEY)
        print(f"[*] __const vmaddr=0x{const_addr:x} fileoff={const_off}")
        print(f"[*] final@0x{a_final:x}  bootstrap@0x{a_boot:x}  key@0x{a_key:x}")

        # Carve the raw bytes and de-obfuscate the two images with the key.
        key   = carve(binpath, a_key,   KEY_LEN,   const_addr, const_off)
        final = deobfuscate(carve(binpath, a_final, FINAL_LEN, const_addr, const_off), key)
        boot  = deobfuscate(carve(binpath, a_boot,  BOOT_LEN,  const_addr, const_off), key)

    # Validate the result against the Rane header the image carries: copyright string, payload
    # length (header + payload == file length) and the big-endian CRC-32 over the payload. A
    # wrong key/offset or a drifted build fails here instead of producing an image that would
    # re-brick the box.
    if not final.startswith(b"Copyright 20"):
        sys.exit("de-obfuscation failed: final image lacks the Rane copyright header "
                 "(offsets/key may differ for this build)")
    paylen = int.from_bytes(final[0x38:0x3c], "big")
    if paylen + 0x40 != len(final):
        sys.exit(f"sanity check failed: payloadLen 0x{paylen:x}+0x40 != 0x{len(final):x}")
    want_crc = int.from_bytes(final[0x3c:0x40], "big")
    got_crc = zlib.crc32(final[0x40:0x40 + paylen]) & 0xFFFFFFFF
    if got_crc != want_crc:
        sys.exit(f"sanity check failed: payload CRC 0x{got_crc:08x} != header 0x{want_crc:08x}")

    # Build the direct-EEPROM image: the raw 64 KiB payload with the FX2 boot header forced to
    # 0xC2 ("boot firmware from EEPROM"). The extracted payload starts with 0xC0 (non-bootable);
    # a chip programmed directly must already carry 0xC2 so the FX2 boots it at power-on.
    eeprom = bytearray(final[0x40:])
    eeprom[0] = 0xC2

    # Write the outputs (all firmware images; *.bin are git-ignored).
    for name, blob in (("eeprom-image-24lc512.bin", bytes(eeprom)),
                       ("sl2_xor_key_256.bin", key),
                       ("sl2_final_firmware.deobfuscated.bin", final),
                       ("sl2_bootstrap_firmware.deobfuscated.bin", boot)):
        with open(os.path.join(out, name), "wb") as f:
            f.write(blob)
        print(f"[+] wrote {name} ({len(blob)} B)")
    print(f"[*] done. final image: {final[:0x20].split(chr(0).encode())[0].decode('latin1')} "
          f"(payload {paylen} B, CRC 0x{want_crc:08x} ok)")


if __name__ == "__main__":
    main()
