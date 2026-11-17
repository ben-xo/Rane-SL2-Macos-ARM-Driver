#!/usr/bin/env python3
"""Extract and de-obfuscate the Rane SL2 firmware images from the official macOS driver.

Source  : Rane's SL2 driver package: "SL2 1.0.1f4.pkg" from the Serato Scratch Live installer DMG
          ("Rane Device Drivers/SL2/"; firmware 1.10), the 1.0.3f1 package (1.10), or
          "RaneSL2_2.0.1f2.pkg", which Serato DJ Pro 2.5.5 bundles (firmware 2.00). Inside it:
          Library/Frameworks/SL2Api.framework/Versions/A/SL2Api. The SL2Api binary itself, or a
          folder holding either (an expanded package, a mounted disk), will do too.
Output  : eeprom-image-24lc512.bin                  (65536 B, ready for a direct EEPROM reflash
                                                     with pi-eeprom-24lc512.py — boot header 0xC2)
          sl2_final_firmware.deobfuscated.bin       (65600 B: 0x40 Rane header + 64 KiB payload)
          sl2_bootstrap_firmware.deobfuscated.bin   (6247 B, 8051, the over-USB RAM loader)
          sl2_xor_key_256.bin                       (the 256-byte de-obfuscation key)

The direct-EEPROM path (this folder's RECOVERY.md) uses eeprom-image-24lc512.bin; sl2flash, over
USB, uses the de-obfuscated .bin pair.

The two firmware images are embedded in the x86_64 slice of the SL2Api dylib and obfuscated with
a 256-byte repeating XOR key (the local symbol kKeyBytes): out[i] = in[i] ^ key[i % 256]. Only the
1.0.1f4 build names the images, so their offsets are those of the known builds below. Every
result is checked against the Rane header's length and CRC-32 and against the SHA-256 of the known
build, so a different build, a wrong offset or a damaged file stops here instead of producing an
image that could leave the box unbootable.

No vendor code is executed. Requires: macOS tools pkgutil, gunzip, cpio, lipo, nm, otool.

Usage:
  extract-sl2-firmware.py <SL2 .pkg | SL2Api | folder> [outdir]
  extract-sl2-firmware.py "/Volumes/ScratchLive Installer" [outdir]   # finds the pkg
"""
import hashlib, os, subprocess, sys, tempfile, zlib

KEY_LEN  = 0x100
SYM_KEY  = "kKeyBytes"
RANE_HDR = 0x40
FINAL_LEN = 0x10040      # the memcpy lengths in Update{Final,Bootstrap}FirmwareFromEmbedded
BOOT_LEN  = 0x1867
# Known builds: the file offsets of the final image and the bootstrap in the x86_64 slice, and the
# SHA-256 of each once de-obfuscated. The bootstrap is the same in all of them.
BOOT_SHA = "2539364a5714a50a6e91389219199d2908c8977122d7d7139b343a54a8f1aaac"
FINAL_110 = "48edbaafd2ff5166732ccf61c25d6208724077882602a506851dca2dcc9075e0"
FINAL_200 = "c6d92094af190e26480f901633102221714347f1fccf12a8783dc406c5be26ea"
BUILDS = {
    "1.0.1f4": {"final": (0xb270, FINAL_LEN, FINAL_110), "bootstrap": (0x1b2b0, BOOT_LEN, BOOT_SHA)},
    "1.0.3f1": {"final": (0xaf30, FINAL_LEN, FINAL_110), "bootstrap": (0x1af70, BOOT_LEN, BOOT_SHA)},
    "2.0.1f2": {"final": (0x7eb0, FINAL_LEN, FINAL_200), "bootstrap": (0x17ef0, BOOT_LEN, BOOT_SHA)},
}


def run(*cmd, **kw):
    """Run a command and return its stdout, raising if it fails."""
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def is_macho(path):
    """True if path is a Mach-O file (thin or universal)."""
    with open(path, "rb") as f:
        magic = f.read(4)
    return magic in (b"\xca\xfe\xba\xbe", b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")


def find_source(p):
    """The SL2 .pkg or the SL2Api binary: the argument itself, or the first found under it. (An
    expanded package's component is a folder named SL2.pkg, so the binary is looked for first.)"""
    if os.path.isfile(p):
        return p
    for root, _, files in os.walk(p):
        for f in sorted(files):
            full = os.path.join(root, f)
            if f == "SL2Api" and not os.path.islink(full) and is_macho(full):
                return full
    for root, _, files in os.walk(p):
        for f in sorted(files):
            if f.endswith(".pkg") and "SL2" in f.upper():
                return os.path.join(root, f)
    sys.exit(f"could not find an SL2 .pkg or an SL2Api binary under {p}")


def sl2api_from_pkg(pkg, work):
    """Expand the package under `work` and return the path of the SL2Api binary in its payload."""
    run("pkgutil", "--expand", pkg, os.path.join(work, "pkg"))
    payload = None
    for root, _, files in os.walk(os.path.join(work, "pkg")):
        if "Payload" in files and os.path.basename(root).upper().startswith("SL2"):
            payload = os.path.join(root, "Payload")
    if not payload:
        sys.exit("the package has no SL2 component payload")
    # The payload is a gzip'd cpio archive of the installed files; unpack it.
    extract = os.path.join(work, "payload")
    os.makedirs(extract)
    with open(payload, "rb") as fp:
        gz = subprocess.Popen(["gunzip", "-c"], stdin=fp, stdout=subprocess.PIPE)
        subprocess.run(["cpio", "-idm"], stdin=gz.stdout, cwd=extract, check=True, capture_output=True)
        gz.wait()
    fw = os.path.join(extract, "Library/Frameworks/SL2Api.framework/Versions/A/SL2Api")
    if not os.path.isfile(fw):
        sys.exit("the package's payload has no SL2Api.framework")
    return fw


def x86_64_slice(binpath, work):
    """A thin x86_64 copy of the binary (it ships with i386 and x86_64 slices), under `work`."""
    thin = os.path.join(work, "slice")
    archs = run("lipo", "-archs", binpath).split()
    if archs == ["x86_64"]:
        return binpath
    if "x86_64" not in archs:
        sys.exit(f"{binpath} has no x86_64 slice ({' '.join(archs)})")
    run("lipo", "-thin", "x86_64", binpath, "-output", thin)
    return thin


def file_offset(binpath, vmaddr):
    """The file offset of a virtual address, from the section that contains it."""
    out = run("otool", "-l", binpath).splitlines()
    for i, line in enumerate(out):
        if line.strip().startswith("sectname "):
            addr = size = offset = None
            for t in (s.strip() for s in out[i + 1:i + 9]):
                if t.startswith("addr "):   addr = int(t.split()[1], 16)
                if t.startswith("size "):   size = int(t.split()[1], 16)
                if t.startswith("offset "): offset = int(t.split()[1])
            if addr is not None and size and offset and addr <= vmaddr < addr + size:
                return offset + (vmaddr - addr)
    sys.exit(f"no section holds address 0x{vmaddr:x}")


def key_offset(binpath):
    """The file offset of the XOR key, from its local symbol."""
    for line in run("nm", "-n", binpath).splitlines():
        parts = line.split()
        if len(parts) >= 3 and SYM_KEY in parts[-1]:
            return file_offset(binpath, int(parts[0], 16))
    sys.exit(f"no {SYM_KEY} symbol: not Rane's SL2Api, or a build this script doesn't know")


def deobfuscate(data, key):
    """Undo the repeating-XOR obfuscation."""
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def check_final(final):
    """The Rane header: copyright, payload length, and the CRC-32 (big-endian) over the payload."""
    if not final.startswith(b"Copyright 20"):
        sys.exit("the final image lacks the Rane copyright header")
    paylen = int.from_bytes(final[0x38:0x3c], "big")
    if paylen + RANE_HDR != len(final):
        sys.exit(f"the final image's payload length 0x{paylen:x} + 0x40 is not its size 0x{len(final):x}")
    want = int.from_bytes(final[0x3c:0x40], "big")
    got = zlib.crc32(final[RANE_HDR:]) & 0xFFFFFFFF
    if got != want:
        sys.exit(f"the final image's CRC 0x{got:08x} doesn't match its header (0x{want:08x})")
    return paylen, want


def main():
    # The source and the output directory.
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = find_source(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else "sl2-fw-out"
    print(f"[*] source: {src}")

    # Find SL2Api's x86_64 slice and carve the key and images out of it, in a temporary folder that
    # is discarded on exit, so no copy of the vendor binary is left behind.
    with tempfile.TemporaryDirectory(prefix="sl2fw.") as work:
        binpath = sl2api_from_pkg(src, work) if src.endswith(".pkg") else src
        thin = x86_64_slice(binpath, work)
        with open(thin, "rb") as f:
            blob = f.read()
        koff = key_offset(thin)
        key = blob[koff:koff + KEY_LEN]
        # Try each known build: the one whose images de-obfuscate to the known contents.
        found = None
        for build, imgs in BUILDS.items():
            got = {}
            for name, (off, length, sha) in imgs.items():
                img = deobfuscate(blob[off:off + length], key)
                if hashlib.sha256(img).hexdigest() != sha:
                    break
                got[name] = img
            else:
                found = (build, got)
                break
    if not found:
        sys.exit("the images don't match a known SL2Api build (known: " + ", ".join(BUILDS) + ")")
    build, imgs = found
    final, boot = imgs["final"], imgs["bootstrap"]
    paylen, crc = check_final(final)
    if boot[0] != 0x02:
        sys.exit("the bootstrap doesn't start with an 8051 LJMP")

    # Build the direct-EEPROM image: the raw 64 KiB payload with the FX2 boot header forced to
    # 0xC2 ("boot firmware from EEPROM"). The extracted payload starts with 0xC0 (non-bootable);
    # a chip programmed directly must already carry 0xC2 so the FX2 boots it at power-on.
    eeprom = bytearray(final[RANE_HDR:])
    eeprom[0] = 0xC2

    # Write the outputs (all firmware images; *.bin are git-ignored).
    os.makedirs(out, exist_ok=True)
    for name, blob in (("eeprom-image-24lc512.bin", bytes(eeprom)),
                       ("sl2_xor_key_256.bin", key),
                       ("sl2_final_firmware.deobfuscated.bin", final),
                       ("sl2_bootstrap_firmware.deobfuscated.bin", boot)):
        with open(os.path.join(out, name), "wb") as f:
            f.write(blob)
        print(f"[+] wrote {name} ({len(blob)} B)")
    print(f"[*] SL2Api {build}: firmware {final[0x27]}.{final[0x28]:02d}, payload 0x{paylen:x} B, "
          f"CRC 0x{crc:08x}; bootstrap {len(boot)} B")


if __name__ == "__main__":
    main()
