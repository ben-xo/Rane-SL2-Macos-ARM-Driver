// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl2flash — load firmware into a Rane SL 2 that is sitting in its USB bootloader
 * (System Information shows it as "Unnamed Device" with vendor 0x1cc5 / product 0x0013).
 *
 *   sl2flash [--dry-run] [--firmware DIR] [--wait SECONDS]
 *     --firmware DIR  directory holding the bootstrap and final images (*.bin, recognised
 *                     by content); default: /Library/Audio/Plug-Ins/HAL/SL2Device.firmware
 *     --dry-run       open the bootloader and describe it, send nothing
 *     --wait SECONDS  wait up to this long for a loadable box to be connected
 *
 * It also accepts the bare Cypress FX2 default device (04b4:8613), which is what the box
 * enumerates as when its EEPROM is completely blank (e.g. a newly fitted chip).
 *
 * The HAL audio plug-in never touches a bootloader-mode box (it only reports it), so this
 * tool can open and flash it without stopping coreaudiod. The images are taken from the
 * user's own copy of an official Rane / Serato driver; see tools/firmware/extract-sl2-firmware.py.
 *
 * NOTE: this over-USB flash path is reverse-engineered and guarded by a full read-back
 * verify before it arms the boot header, but it has not been proven end-to-end on hardware
 * here; the direct EEPROM reflash in tools/firmware/ is the tested route. See the
 * STATUS note in SL2Loader.h before relying on this.
 */
#import "SL2Loader.h"
#import <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void out(const char *m) { printf("%s\n", m); fflush(stdout); }

static io_service_t find_vid_pid(int vid, int pid, int want_bcd) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &vid), pn = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return IO_OBJECT_NULL;
    io_service_t s, found = IO_OBJECT_NULL;
    while ((s = IOIteratorNext(it))) {
        if (!found && (want_bcd < 0 || sl2_service_bcd(s) == want_bcd)) found = s;
        else IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}
static io_service_t find_device(int want_bcd) { return find_vid_pid(SL2_VID, SL2_PID, want_bcd); }

/* A device we can start a firmware download into: the Rane bootloader, or the bare Cypress
   FX2 default (04b4:8613) when the EEPROM is blank. */
static io_service_t find_loadable(void) {
    io_service_t s = find_device(SL2_BCD_LOADER);
    if (s) return s;
    return find_vid_pid(FX2_DEFAULT_VID, FX2_DEFAULT_PID, -1);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *dir = "/Library/Audio/Plug-Ins/HAL/SL2Device.firmware";
    bool dry = false;
    int waitsecs = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dry-run")) dry = true;
        else if (!strcmp(argv[i], "--firmware") && i + 1 < argc) dir = argv[++i];
        else if (!strcmp(argv[i], "--wait") && i + 1 < argc) waitsecs = atoi(argv[++i]);
        else { fprintf(stderr, "usage: %s [--dry-run] [--firmware DIR] [--wait SECONDS]\n", argv[0]); return 2; }
    }

    io_service_t svc = find_loadable();
    if (!svc && waitsecs > 0) {
        printf("waiting up to %d s for the SL 2 bootloader (1cc5:0013) or the Cypress FX2\n"
               "default (04b4:8613, a blank EEPROM) — connect it now...\n", waitsecs);
        for (int i = 0; i < waitsecs * 10 && !svc; i++) {
            usleep(100000);
            svc = find_loadable();
        }
    }
    if (!svc) {
        io_service_t a = find_device(SL2_BCD_AUDIO);
        if (a) { IOObjectRelease(a); printf("the SL 2 is already running its firmware (bcdDevice 0x0100); nothing to do\n"); return 0; }
        printf("no loadable SL 2 found (neither the Rane bootloader nor a Cypress FX2 default)\n");
        return 1;
    }
    printf("loadable FX2 found; starting.\n");

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSData *> *datas = [NSMutableArray array];
    NSString *d = [NSString stringWithUTF8String:dir];
    NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:d error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *f in files) {
        if (![f.pathExtension isEqualToString:@"bin"]) continue;
        NSData *x = [NSData dataWithContentsOfFile:[d stringByAppendingPathComponent:f]];
        if (x.length) { [names addObject:f]; [datas addObject:x]; }
    }
    if (!dry && !datas.count) { printf("no firmware images (*.bin) in %s\n", dir); IOObjectRelease(svc); return 1; }
    SL2FirmwareImage images[16];
    size_t n = 0;
    for (NSUInteger i = 0; i < datas.count && n < 16; i++, n++) {
        images[n].name = names[i].UTF8String;
        images[n].data = datas[i].bytes;
        images[n].len  = datas[i].length;
    }

    bool ok = sl2_loader_run(svc, images, n, dry, out);
    IOObjectRelease(svc);
    if (dry) return ok ? 0 : 1;
    printf(ok ? "done: the SL 2 is running its firmware again\n" : "upload failed; the box is left in bootloader mode (safe to retry)\n");
    return ok ? 0 : 1;
  }
}
