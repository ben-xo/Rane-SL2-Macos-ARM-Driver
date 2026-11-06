// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl2dump — read the Rane SL 2's 64 KiB boot EEPROM out of the RUNNING device over USB, and
 * either save it or verify it against an image. The reads are routed through the running
 * HAL plug-in's 'sl2h' HID passthrough while it holds the device.
 *
 *   sl2dump FILE.bin            dump the EEPROM to FILE.bin
 *   sl2dump --verify FILE.bin   read the EEPROM and compare it to FILE.bin (no write)
 *
 * Mechanism: the running firmware answers HID command 0x01 with its version and HID command
 * 0x03 as an EEPROM read — a 16-bit big-endian address in request bytes [5] (high) and [6]
 * (low), 32 data bytes returned at reply[7..38], addressing the whole 0x0000..0xFFFF range.
 * Each reply echoes the address at reply[5..6], which we use to reject a stale/mis-paired
 * reply and retry.
 *
 * Byte 0 reads back as the device's live boot-mode status byte, not the value stored in the
 * EEPROM, so --verify ignores it when comparing against an image.
 *
 * This is a read-only diagnostic: a safe backup before any firmware operation, and an
 * independent post-flash check from the running firmware (separate from the bootstrap's own
 * read-back in the loader). Build: make dump
 */
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

#define kSL2PropHIDCommand  'sl2h'
#define EEPROM_SIZE 65536
#define READ_LEN    32            /* data bytes returned per 0x03 read (reply[7..38]) */

static AudioObjectID find_hal_device(void) {
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &dev);
    return (st == noErr) ? dev : kAudioObjectUnknown;
}

/* One 0x03 EEPROM read of READ_LEN bytes at 'addr' into out[]; returns true on a reply whose
   echoed address matches the request. 'seq' aids the driver's request/reply correlation. */
static bool read_block(AudioObjectID dev, uint32_t addr, uint8_t *out, uint32_t seq) {
    /* Build the request: opcode 0x03, a correlation seq, and the 16-bit big-endian address. */
    uint8_t req[64] = {0};
    req[0] = 0x03;
    memcpy(req + 1, &seq, 4);
    req[5] = (uint8_t)(addr >> 8);
    req[6] = (uint8_t)(addr & 0xFF);

    /* Hand the request to the driver (property write), then read its reply (property read). */
    AudioObjectPropertyAddress a = { kSL2PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef in = CFDataCreate(kCFAllocatorDefault, req, 64);
    OSStatus s = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &in);
    CFRelease(in);
    if (s != noErr) return false;

    CFDataRef out_d = NULL;
    UInt32 osz = sizeof(out_d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &osz, &out_d) != noErr || !out_d) return false;

    /* Accept the reply only if it echoes our opcode and address, then copy the 32 data bytes. */
    const uint8_t *r = CFDataGetBytePtr(out_d);
    bool ok = (CFDataGetLength(out_d) >= 7 + READ_LEN && r[0] == 0x03 && r[5] == req[5] && r[6] == req[6]);
    if (ok) memcpy(out, r + 7, READ_LEN);
    CFRelease(out_d);
    return ok;
}

/* Read the whole EEPROM into buf (EEPROM_SIZE bytes). Returns the number of blocks that failed
   after retries (0 = a clean dump). */
static int read_eeprom(AudioObjectID dev, uint8_t *buf) {
    uint32_t seq = 1;
    int fails = 0;
    /* Walk the whole EEPROM low-to-high in READ_LEN-byte blocks. */
    for (uint32_t addr = 0; addr < EEPROM_SIZE; addr += READ_LEN) {
        /* Retry each block a few times to absorb an occasional stale/mis-paired reply. */
        bool ok = false;
        for (int attempt = 0; attempt < 3 && !ok; attempt++) ok = read_block(dev, addr, buf + addr, seq++);
        if (!ok) { fails++; if (fails <= 5) fprintf(stderr, "read failed at 0x%04x\n", addr); }
        if ((addr & 0x3fff) == 0) { fprintf(stderr, "\r  reading %u/%u", addr, EEPROM_SIZE); fflush(stderr); }  /* progress, every 16 KiB */
    }
    fprintf(stderr, "\r  read %u/%u bytes, %d failed block(s)\n", EEPROM_SIZE, EEPROM_SIZE, fails);
    return fails;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        /* Parse arguments: optional --verify, then the image path. */
        bool verify = false;
        const char *path = NULL;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--verify")) verify = true;
            else path = argv[i];
        }
        if (!path) {
            fprintf(stderr, "usage: sl2dump FILE.bin            dump the SL 2 EEPROM to FILE.bin\n");
            fprintf(stderr, "       sl2dump --verify FILE.bin   compare the EEPROM to FILE.bin\n");
            return 2;
        }

        /* Find the running SL 2 HAL device; the dump routes through its 'sl2h' property. */
        AudioObjectID dev = find_hal_device();
        if (dev == kAudioObjectUnknown) {
            fprintf(stderr, "SL 2 CoreAudio HAL driver not loaded (is the box connected and running firmware?)\n");
            return 1;
        }

        /* Read the whole EEPROM; a partial read is not trustworthy, so bail if any block failed. */
        uint8_t *buf = malloc(EEPROM_SIZE);
        int fails = read_eeprom(dev, buf);
        if (fails) { fprintf(stderr, "dump is incomplete (%d failed block(s)); not trusting it\n", fails); free(buf); return 1; }

        /* --verify: compare the live EEPROM against an image, ignoring the volatile byte 0. */
        if (verify) {
            NSData *img = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
            if (!img) { fprintf(stderr, "cannot read %s\n", path); free(buf); return 1; }
            if (img.length != EEPROM_SIZE) { fprintf(stderr, "%s is %lu bytes; expected %d\n", path, (unsigned long)img.length, EEPROM_SIZE); free(buf); return 1; }
            const uint8_t *want = img.bytes;
            int diffs = 0, first = -1;
            for (int i = 1; i < EEPROM_SIZE; i++)   /* skip byte 0: live boot-mode status, not stored */
                if (buf[i] != want[i]) { if (first < 0) first = i; diffs++; }
            if (diffs == 0) printf("VERIFY OK — the EEPROM matches %s (byte 0 ignored)\n", path);
            else printf("VERIFY FAILED — %d byte(s) differ, first at 0x%04x (EEPROM 0x%02x, image 0x%02x)\n",
                        diffs, first, buf[first], want[first]);
            free(buf);
            return diffs ? 1 : 0;
        }

        /* Default: save the dump to disk. */
        FILE *f = fopen(path, "wb");
        if (!f) { perror("fopen"); free(buf); return 1; }
        size_t w = fwrite(buf, 1, EEPROM_SIZE, f);
        fclose(f);
        if (w != EEPROM_SIZE) { fprintf(stderr, "short write to %s\n", path); free(buf); return 1; }
        printf("wrote %s (%d bytes)\n", path, EEPROM_SIZE);
        free(buf);
        return 0;
    }
}
