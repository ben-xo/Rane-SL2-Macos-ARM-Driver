// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl2dump — read the Rane SL 2's 64 KiB boot EEPROM out of the RUNNING device over USB, and
 * either save it or verify it against an image. The reads go through the HAL driver's 'sl2h'
 * passthrough (tools/SL2Passthrough.h) while it holds the device.
 *
 *   sl2dump FILE.bin            dump the EEPROM to FILE.bin
 *   sl2dump --verify FILE.bin   read the EEPROM and compare it to FILE.bin (no write)
 *
 * Mechanism: the running firmware answers command 0x03 with 32 EEPROM bytes at a 16-bit
 * address (docs/SL2-COMMANDS.md), covering the whole 0x0000..0xFFFF range.
 *
 * Byte 0 is the FX2 boot header: 0xC2 = boot the firmware, 0xC0 = start in the bootloader at
 * the next power-up. --verify compares the rest of the EEPROM and reports byte 0 separately,
 * so an image written with either header can be checked.
 *
 * This is a read-only diagnostic: a backup before any firmware operation, and an independent
 * check after one. Build: make dump
 */
#import <Foundation/Foundation.h>
#import "SL2Passthrough.h"

/* Read the whole EEPROM into buf (SL2_EEPROM_SIZE bytes). Returns the number of blocks that
   failed after retries (0 = a clean dump). */
static int read_eeprom(AudioObjectID dev, uint8_t *buf) {
    int fails = 0;
    for (uint32_t addr = 0; addr < SL2_EEPROM_SIZE; addr += SL2_EEPROM_BLOCK) {
        if (!sl2h_eeprom_read(dev, (uint16_t)addr, buf + addr)) { fails++; if (fails <= 5) fprintf(stderr, "read failed at 0x%04x\n", addr); }
        if ((addr & 0x3fff) == 0) { fprintf(stderr, "\r  reading %u/%u", addr, SL2_EEPROM_SIZE); fflush(stderr); }  /* every 16 KiB */
    }
    fprintf(stderr, "\r  read %u/%u bytes, %d failed block(s)\n", SL2_EEPROM_SIZE, SL2_EEPROM_SIZE, fails);
    return fails;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
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

        AudioObjectID dev = sl2h_find_device();
        if (dev == kAudioObjectUnknown) {
            fprintf(stderr, "SL 2 CoreAudio HAL driver not loaded (is the box connected and running firmware?)\n");
            return 1;
        }

        /* A partial read is not trustworthy, so bail if any block failed. */
        uint8_t *buf = malloc(SL2_EEPROM_SIZE);
        int fails = read_eeprom(dev, buf);
        if (fails) { fprintf(stderr, "dump is incomplete (%d failed block(s)); not trusting it\n", fails); free(buf); return 1; }

        const char *hdr = buf[0] == 0xC2 ? "bootable" : buf[0] == 0xC0 ? "NOT bootable: the box starts in its bootloader at the next power-up"
                                                                        : "invalid";
        if (verify) {
            NSData *img = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
            if (!img) { fprintf(stderr, "cannot read %s\n", path); free(buf); return 1; }
            if (img.length != SL2_EEPROM_SIZE) { fprintf(stderr, "%s is %lu bytes; expected %d\n", path, (unsigned long)img.length, SL2_EEPROM_SIZE); free(buf); return 1; }
            const uint8_t *want = img.bytes;
            int diffs = 0, first = -1;
            for (int i = 1; i < SL2_EEPROM_SIZE; i++)   /* byte 0 is reported below */
                if (buf[i] != want[i]) { if (first < 0) first = i; diffs++; }
            if (diffs == 0) printf("VERIFY OK — the EEPROM matches %s\n", path);
            else printf("VERIFY FAILED — %d byte(s) differ, first at 0x%04x (EEPROM 0x%02x, image 0x%02x)\n",
                        diffs, first, buf[first], want[first]);
            printf("boot header (byte 0): 0x%02x, %s\n", buf[0], hdr);
            free(buf);
            return diffs ? 1 : 0;
        }

        FILE *f = fopen(path, "wb");
        if (!f) { perror("fopen"); free(buf); return 1; }
        size_t w = fwrite(buf, 1, SL2_EEPROM_SIZE, f);
        fclose(f);
        if (w != SL2_EEPROM_SIZE) { fprintf(stderr, "short write to %s\n", path); free(buf); return 1; }
        printf("wrote %s (%d bytes); boot header 0x%02x, %s\n", path, SL2_EEPROM_SIZE, buf[0], hdr);
        free(buf);
        return 0;
    }
}
