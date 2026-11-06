// SPDX-License-Identifier: GPL-3.0-or-later
/* SL2Loader.m — see SL2Loader.h. Host side of Rane's SL2Api firmware update, replayed
 * over IOUSBHost. Protocol as reverse-engineered from SL2Api.framework 1.0.1f4
 * (UpdateBootstrapFirmware / UpdateFinalFirmware / SendHidRequest) and the bootstrap's
 * own 8051 code (EP1 interrupt transport, I2C EEPROM at 0x51, C0/C2 boot header). */
#import "SL2Loader.h"
#import <IOKit/usb/IOUSBLib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define FX2_CPUCS      0xE600   /* CPU control/status: bit 0 = 8051 in reset */
#define FX2_REQ_RAM    0xA0     /* EZ-USB vendor request: RAM read/write */
#define RAM_CHUNK      32
#define OP_BEGIN       0x17
#define OP_WRITE       0x02
#define OP_READ        0x03
#define OP_FINALIZE    0x16
#define REPORT         64
#define BLOCK          32
#define RANE_HDR       0x40


static int svc_int_prop(io_service_t svc, CFStringRef key) {
    CFNumberRef n = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0);
    if (!n) return -1;
    int v = -1;
    CFNumberGetValue(n, kCFNumberIntType, &v);
    CFRelease(n);
    return v;
}
int sl2_service_bcd(io_service_t svc) { return svc_int_prop(svc, CFSTR("bcdDevice")); }
static int svc_vid(io_service_t svc) { return svc_int_prop(svc, CFSTR("idVendor")); }
static int svc_pid(io_service_t svc) { return svc_int_prop(svc, CFSTR("idProduct")); }

/* A device we can start a firmware download into: the Rane bootloader (1cc5:0013 at
   bcdDevice 0x0000) or, when the EEPROM is blank, the bare Cypress FX2 default
   (04b4:8613). Both accept the 0xA0 RAM download. */
static bool svc_is_loadable(io_service_t svc) {
    if (svc_vid(svc) == FX2_DEFAULT_VID && svc_pid(svc) == FX2_DEFAULT_PID) return true;
    if (svc_vid(svc) == SL2_VID && svc_pid(svc) == SL2_PID && sl2_service_bcd(svc) == SL2_BCD_LOADER) return true;
    return false;
}

static void lg(sl2_loader_log_fn log, const char *fmt, ...) {
    char b[600];
    va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    if (log) log(b);
}

static void lghex(sl2_loader_log_fn log, const char *tag, const uint8_t *p, int n) {
    char b[3 * 64 + 1]; int o = 0;
    for (int i = 0; i < n && i < 64; i++) o += snprintf(b + o, sizeof b - o, "%02x ", p[i]);
    lg(log, "%s: %s", tag, b);
}

static uint32_t crc32_std(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) { c ^= p[i]; for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u))); }
    return c ^ 0xFFFFFFFFu;
}

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

static uint64_t entry_id(io_service_t s) { uint64_t id = 0; IORegistryEntryGetRegistryEntryID(s, &id); return id; }

/* ---- finding the box across its re-enumerations ---- */

static int find_devices(io_service_t *out, int max) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    int v = SL2_VID, p = SL2_PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v), pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_iterator_t it = 0; int n = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return 0;
    io_service_t s;
    while ((s = IOIteratorNext(it))) { if (n < max) out[n++] = s; else IOObjectRelease(s); }
    IOObjectRelease(it);
    return n;
}

/* A 1cc5:0013 device other than registry entry 'old_id', with bcdDevice 'want' (-1 = any),
   within 'seconds'. Returns a retained service or 0. */
static io_service_t wait_for_device(uint64_t old_id, int want, double seconds) {
    for (int i = 0; i < (int)(seconds * 10); i++) {
        io_service_t devs[8], hit = 0;
        int n = find_devices(devs, 8);
        for (int k = 0; k < n; k++) {
            if (!hit && entry_id(devs[k]) != old_id && (want < 0 || sl2_service_bcd(devs[k]) == want)) hit = devs[k];
            else IOObjectRelease(devs[k]);
        }
        if (hit) return hit;
        usleep(100000);
    }
    return 0;
}

/* Exclusive open, with a few retries in case another client is just letting go. */
static IOUSBHostDevice *open_device(io_service_t svc, dispatch_queue_t q, sl2_loader_log_fn log, const char *what) {
    NSError *e = nil;
    for (int attempt = 0; attempt < 10; attempt++) {
        IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone
                                                                    queue:q error:&e interestHandler:nil];
        if (dev) return dev;
        usleep(300000);
    }
    lg(log, "cannot open the %s device: %s", what, e.localizedDescription.UTF8String);
    return nil;
}

/* ---- stage 1: EZ-USB RAM download of the bootstrap over EP0 ---- */

static bool fx2_request(IOUSBHostDevice *dev, uint8_t type, uint16_t value, NSMutableData *buf, sl2_loader_log_fn log, const char *what) {
    IOUSBDeviceRequest r = { .bmRequestType = type, .bRequest = FX2_REQ_RAM, .wValue = value, .wIndex = 0, .wLength = (uint16_t)buf.length };
    NSError *e = nil; NSUInteger n = 0;
    if (![dev sendDeviceRequest:r data:buf bytesTransferred:&n completionTimeout:2.0 error:&e] || n != buf.length) {
        lg(log, "%s (wValue 0x%04x): control transfer failed: %s (%lu/%lu bytes)", what, value,
           e ? e.localizedDescription.UTF8String : "short transfer", (unsigned long)n, (unsigned long)buf.length);
        return false;
    }
    return true;
}

static bool stage1_bootstrap(IOUSBHostDevice *dev, const uint8_t *img, size_t len, sl2_loader_log_fn log) {
    NSMutableData *one = [NSMutableData dataWithLength:1];
    ((uint8_t *)one.mutableBytes)[0] = 1;
    if (!fx2_request(dev, 0x40, FX2_CPUCS, one, log, "halt 8051")) return false;
    for (size_t off = 0; off < len; off += RAM_CHUNK) {
        size_t n = (len - off < RAM_CHUNK) ? len - off : RAM_CHUNK;
        NSMutableData *d = [NSMutableData dataWithBytes:img + off length:n];
        if (!fx2_request(dev, 0x40, (uint16_t)off, d, log, "write RAM")) return false;
    }
    for (size_t off = 0; off < len; off += RAM_CHUNK) {
        size_t n = (len - off < RAM_CHUNK) ? len - off : RAM_CHUNK;
        NSMutableData *d = [NSMutableData dataWithLength:n];
        if (!fx2_request(dev, 0xC0, (uint16_t)off, d, log, "read RAM")) return false;
        if (memcmp(d.bytes, img + off, n) != 0) { lg(log, "RAM verify failed at 0x%04zx", off); return false; }
    }
    lg(log, "bootstrap: %zu bytes written to RAM and verified; starting it", len);
    ((uint8_t *)one.mutableBytes)[0] = 0;
    if (!fx2_request(dev, 0x40, FX2_CPUCS, one, log, "run 8051"))
        lg(log, "(the run request did not complete cleanly; the box may already be restarting)");
    return true;
}

/* ---- stage 2: 64-byte reports to the bootstrap on EP1 interrupt OUT/IN ---- */

typedef struct { IOUSBHostInterface *intf; IOUSBHostPipe *out, *in; } hid_t;

static bool open_hid(IOUSBHostDevice *dev, hid_t *h, sl2_loader_log_fn log) {
    NSError *e = nil;
    if (![dev configureWithValue:1 matchInterfaces:YES error:&e] && e)
        lg(log, "set configuration 1: %s (continuing)", e.localizedDescription.UTF8String);
    for (int attempt = 0; attempt < 30; attempt++) {
        io_iterator_t it = 0;
        if (IORegistryEntryGetChildIterator(dev.ioService, kIOServicePlane, &it) == KERN_SUCCESS) {
            io_service_t ch;
            while ((ch = IOIteratorNext(it))) {
                int idx = -1;
                CFNumberRef n = IORegistryEntryCreateCFProperty(ch, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
                if (n) { CFNumberGetValue(n, kCFNumberIntType, &idx); CFRelease(n); }
                if (idx < 0) { IOObjectRelease(ch); continue; }
                e = nil;
                IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone
                                                                                    queue:dev.queue error:&e interestHandler:nil];
                IOObjectRelease(ch);
                if (!intf) { lg(log, "open interface %d: %s", idx, e.localizedDescription.UTF8String); continue; }
                const IOUSBConfigurationDescriptor *cfg = intf.configurationDescriptor;
                const IOUSBInterfaceDescriptor *ifd = NULL;
                while (cfg && (ifd = IOUSBGetNextInterfaceDescriptor(cfg, (const IOUSBDescriptorHeader *)ifd)) != NULL) {
                    if (ifd->bInterfaceNumber != idx) continue;
                    bool out = false, in = false;
                    const IOUSBEndpointDescriptor *ep = NULL;
                    while ((ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep)) != NULL) {
                        if (IOUSBGetEndpointType(ep) != kIOUSBEndpointTypeInterrupt) continue;
                        if (ep->bEndpointAddress == 0x01) out = true;
                        if (ep->bEndpointAddress == 0x81) in = true;
                    }
                    if (!(out && in)) continue;
                    if (ifd->bAlternateSetting != 0 && ![intf selectAlternateSetting:ifd->bAlternateSetting error:&e]) {
                        lg(log, "select interface %d alt %u: %s", idx, ifd->bAlternateSetting, e.localizedDescription.UTF8String);
                        break;
                    }
                    h->out = [intf copyPipeWithAddress:0x01 error:&e];
                    h->in  = [intf copyPipeWithAddress:0x81 error:&e];
                    if (h->out && h->in) {
                        h->intf = intf;
                        IOObjectRelease(it);
                        lg(log, "bootstrap device: interface %d alt %u, EP1 interrupt OUT/IN open", idx, ifd->bAlternateSetting);
                        return true;
                    }
                    lg(log, "pipes on interface %d: %s", idx, e.localizedDescription.UTF8String);
                    break;
                }
                [intf destroy];
            }
            IOObjectRelease(it);
        }
        usleep(100000);
    }
    lg(log, "no interface with EP1 interrupt OUT/IN appeared on the bootstrap device");
    return false;
}

static void close_hid(hid_t *h) {
    if (h->in)  [h->in abortWithError:nil];
    if (h->out) [h->out abortWithError:nil];
    if (h->intf) [h->intf destroy];
    h->in = h->out = nil; h->intf = nil;
}

/* One report out, one reply in (armed first). The reply's byte 0 echoes the opcode. */
static bool hid_xfer(hid_t *h, const uint8_t report[REPORT], uint8_t reply[REPORT], sl2_loader_log_fn log, const char *what) {
    NSError *e = nil; NSUInteger n = 0;
    NSMutableData *in = [NSMutableData dataWithLength:REPORT];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block IOReturn st = kIOReturnError; __block NSUInteger got = 0;
    if (![h->in enqueueIORequestWithData:in completionTimeout:0 error:&e completionHandler:^(IOReturn s, NSUInteger g) {
            st = s; got = g; dispatch_semaphore_signal(sem); }]) {
        lg(log, "%s: cannot arm the reply read: %s", what, e.localizedDescription.UTF8String);
        return false;
    }
    NSMutableData *out = [NSMutableData dataWithBytes:report length:REPORT];
    if (![h->out sendIORequestWithData:out bytesTransferred:&n completionTimeout:0 error:&e]) {
        lg(log, "%s: send failed: %s", what, e.localizedDescription.UTF8String);
        [h->in abortWithError:nil]; dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        return false;
    }
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        [h->in abortWithError:nil]; dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        lg(log, "%s: no reply within 3 s", what);
        return false;
    }
    if (st != kIOReturnSuccess || got < 1) { lg(log, "%s: reply read failed (0x%x, %lu bytes)", what, (unsigned)st, (unsigned long)got); return false; }
    memcpy(reply, in.bytes, REPORT);
    if (reply[0] != report[0]) { lg(log, "%s: reply opcode 0x%02x, expected 0x%02x", what, reply[0], report[0]); lghex(log, "reply", reply, 16); return false; }
    return true;
}

/* op03: pure read of 32 bytes at an EEPROM address (reply[5..6]=echoed address,
   reply[7..38]=data). Used for the full independent verify before finalize. */
static bool read_block(hid_t *h, uint32_t addr, uint8_t *out, uint32_t n, sl2_loader_log_fn log) {
    uint8_t rep[REPORT], reply[REPORT];
    memset(rep, 0, REPORT);
    rep[0] = OP_READ;
    rep[5] = (uint8_t)(addr >> 8);
    rep[6] = (uint8_t)(addr & 0xFF);
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!hid_xfer(h, rep, reply, log, "read block")) return false;
        if (reply[5] == rep[5] && reply[6] == rep[6]) { memcpy(out, reply + 7, n); return true; }
        lg(log, "  read for 0x%04x carried address 0x%02x%02x; retrying", addr, reply[5], reply[6]);
    }
    lg(log, "could not correlate the read for EEPROM offset 0x%04x", addr);
    return false;
}

static bool stage2_final(hid_t *h, const uint8_t *img, size_t len, sl2_loader_log_fn log) {
    const uint8_t *pay = img + RANE_HDR;
    uint32_t plen = be32(img + 0x38);
    uint8_t rep[REPORT], reply[REPORT];
    memset(rep, 0, REPORT); rep[0] = OP_BEGIN;
    if (!hid_xfer(h, rep, reply, log, "begin (0x17)")) return false;
    lg(log, "begin acknowledged; writing %u bytes in %u blocks", plen, (plen + BLOCK - 1) / BLOCK);
    for (uint32_t off = 0; off < plen; off += BLOCK) {
        uint32_t n = (plen - off < BLOCK) ? plen - off : BLOCK;
        /* op02 write report: [0]=opcode, [5..6]=EEPROM byte address (big-endian),
           [7..38]=32 data bytes. The device page-writes, waits the EEPROM write cycle,
           then reads it back: reply[0]=opcode, reply[5..6]=echoed address, reply[7..38]=
           the bytes read from the EEPROM (not an echo of the request). */
        memset(rep, 0, REPORT);
        rep[0] = OP_WRITE;
        rep[5] = (uint8_t)(off >> 8);
        rep[6] = (uint8_t)(off & 0xFF);
        memcpy(rep + 7, pay + off, n);

        /* FX2 endpoint buffering can hand back the previous chunk's reply, so correlate
           each reply to this request by the address it echoes, and retry once if it does
           not match. */
        bool correlated = false;
        for (int attempt = 0; attempt < 2 && !correlated; attempt++) {
            if (!hid_xfer(h, rep, reply, log, "write block")) { lg(log, "failed at EEPROM offset 0x%04x", off); return false; }
            if (reply[5] == rep[5] && reply[6] == rep[6]) correlated = true;
            else lg(log, "  read-back for 0x%04x carried address 0x%02x%02x; retrying", off, reply[5], reply[6]);
        }
        if (!correlated) { lg(log, "could not correlate the read-back for EEPROM offset 0x%04x", off); return false; }

        if (off == 0) { lghex(log, "  sent ", rep, 39); lghex(log, "  reply", reply, 39); }
        /* Compare the read-back to what we wrote. The first block's bytes 0..4 are forced
           by the device to the identity header C0 C5 1C 13 00, so skip those. */
        for (uint32_t i = 0; i < n; i++) {
            uint8_t sent = pay[off + i], got = reply[7 + i];
            if (sent != got && !(off == 0 && i < 5)) {
                lg(log, "EEPROM verify failed at image offset 0x%04x: wrote %02x, read %02x", off + i, sent, got);
                lghex(log, "  sent ", rep, 39); lghex(log, "  reply", reply, 39);
                return false;
            }
        }
        if (off && (off % 8192) == 0) lg(log, "  %u / %u bytes verified", off, plen);
    }
    /* Independent full re-read before arming the boot header. Finalize (0x16) is the only
       step that makes a bad image permanently bootable, so it is gated behind a complete
       verify of every byte: if anything differs, the EEPROM header stays 0xC0 (non-bootable)
       and the box remains software-recoverable. Pre-finalize, EEPROM byte 0 is 0xC0, which
       equals the image's own first byte, so an exact match is expected throughout. */
    lg(log, "all blocks written; re-reading the whole image to verify before arming boot");
    for (uint32_t off = 0; off < plen; off += BLOCK) {
        uint32_t n = (plen - off < BLOCK) ? plen - off : BLOCK;
        uint8_t got[BLOCK];
        if (!read_block(h, off, got, n, log)) return false;
        for (uint32_t i = 0; i < n; i++) {
            if (got[i] != pay[off + i]) {
                lg(log, "full verify failed at image offset 0x%04x: image %02x, EEPROM %02x — NOT arming boot (box stays recoverable)", off + i, pay[off + i], got[i]);
                return false;
            }
        }
        if (off && (off % 16384) == 0) lg(log, "  verified %u / %u bytes", off, plen);
    }
    lg(log, "full image verified against the EEPROM; arming boot (finalize)");
    memset(rep, 0, REPORT); rep[0] = OP_FINALIZE;
    if (!hid_xfer(h, rep, reply, log, "finalize (0x16)")) return false;
    lg(log, "finalize acknowledged: EEPROM marked bootable, the box is restarting into its firmware");
    return true;
}

/* ---- orchestration ---- */

bool sl2_loader_run(io_service_t c0, const SL2FirmwareImage *images, size_t count, bool dry_run, sl2_loader_log_fn log) {
    const SL2FirmwareImage *boot = NULL, *fin = NULL;
    for (size_t i = 0; i < count; i++) {
        if (images[i].len > RANE_HDR && memcmp(images[i].data, "Copyright 20", 12) == 0) { if (!fin) fin = &images[i]; }
        else if (!boot) boot = &images[i];
    }
    if (!dry_run || count) {
        if (!fin || !boot) { lg(log, "need two images: the bootstrap and the final image with its Rane header (have %zu)", count); return false; }
        uint32_t plen = be32(fin->data + 0x38), pcrc = be32(fin->data + 0x3C);
        if (fin->len != RANE_HDR + plen) { lg(log, "%s: header says %u payload bytes but the file has %zu", fin->name, plen, fin->len - RANE_HDR); return false; }
        uint32_t crc = crc32_std(fin->data + RANE_HDR, plen);
        if (crc != pcrc) { lg(log, "%s: CRC %08x does not match its header (%08x); refusing to flash it", fin->name, crc, pcrc); return false; }
        if (boot->len > 0x4000 || boot->data[0] != 0x02) { lg(log, "%s does not look like an 8051 bootstrap", boot->name); return false; }
        lg(log, "images ok: bootstrap %s (%zu bytes), final %s (%u-byte payload, CRC %08x, version bytes %u.%u)",
           boot->name, boot->len, fin->name, plen, pcrc, fin->data[0x27], fin->data[0x28]);
    }
    if (!svc_is_loadable(c0)) { lg(log, "device is not a loadable FX2 (vid 0x%04x pid 0x%04x bcd 0x%04x)", svc_vid(c0), svc_pid(c0), sl2_service_bcd(c0)); return false; }
    if (svc_vid(c0) == FX2_DEFAULT_VID) lg(log, "starting from the bare Cypress FX2 default device (recovery)");

    dispatch_queue_t q = dispatch_queue_create("sl2.loader.io", DISPATCH_QUEUE_SERIAL);
    uint64_t id0 = entry_id(c0);
    IOUSBHostDevice *dev = open_device(c0, q, log, "bootloader");
    if (!dev) return false;
    const IOUSBDeviceDescriptor *dd = dev.deviceDescriptor;
    lg(log, "bootloader device open: bcdDevice 0x%04x, %u configuration(s)%s", dd ? dd->bcdDevice : 0, dd ? dd->bNumConfigurations : 0, dry_run ? " (dry run: stopping here)" : "");
    if (dry_run) { [dev destroy]; return true; }

    bool ok = stage1_bootstrap(dev, boot->data, boot->len, log);
    [dev destroy];
    if (!ok) return false;

    io_service_t s2 = wait_for_device(id0, -1, 20.0);
    if (!s2) { lg(log, "the box did not re-enumerate after starting the bootstrap"); return false; }
    lg(log, "box re-enumerated as bcdDevice 0x%04x; opening the bootstrap", sl2_service_bcd(s2));
    uint64_t id1 = entry_id(s2);
    IOUSBHostDevice *dev2 = open_device(s2, q, log, "bootstrap");
    IOObjectRelease(s2);
    if (!dev2) return false;
    hid_t h = {0};
    ok = open_hid(dev2, &h, log) && stage2_final(&h, fin->data, fin->len, log);
    close_hid(&h);
    [dev2 destroy];
    if (!ok) return false;

    io_service_t s3 = wait_for_device(id1, SL2_BCD_AUDIO, 30.0);
    if (!s3) { lg(log, "the box did not come back as the audio device within 30 s"); return false; }
    IOObjectRelease(s3);
    lg(log, "the SL 2 is back as the audio device (bcdDevice 0x0100)");
    return true;
}
