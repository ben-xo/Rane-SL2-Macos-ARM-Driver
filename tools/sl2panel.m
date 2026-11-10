/*
 * sl2panel.m — Rane SL 2 Hardware Control Panel CLI
 *
 * Works seamlessly even while CoreAudio (coreaudiod) / Serato is streaming
 * by routing commands through the SL2Device CoreAudio HAL PlugIn ('sl2h' / 'sl2s').
 */
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>

#define kSL2PropHIDCommand  'sl2h'
#define kSL2PropStatus      'sl2s'
#define kSL2PropInSafety    'sl2i'

typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];
    uint8_t  thru[4];
    uint8_t  port_a;
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
    uint32_t boot_mode;      /* 1 = box is in its USB bootloader with no firmware loaded */
    uint32_t debug_build;    /* 1 = the driver is a debug build; 0 also from a driver too old to say */
    /* Input health (newer drivers; zero from an older one) */
    uint32_t in_safety_us;          /* the input safety offset the HAL is using, in us */
    uint32_t early_read;            /* 0 = not judged yet on this connection, 1 = working, 2 = not working */
    uint32_t hub_depth;             /* USB hubs between the box and the Mac: 0 = connected directly */
    uint64_t in_dropouts;           /* IO cycles in which input wasn't captured in time, since the device was
                                       set up (the box connected, or the input safety offset changed) */
} SL2StatusPacket;

static AudioObjectID find_hal_device(void) {
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    AudioObjectID devID = kAudioObjectUnknown;
    UInt32 sz = sizeof(devID);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &devID);
    return (st == noErr) ? devID : kAudioObjectUnknown;
}

/* An SL 2 is in the USB registry (in either mode). The driver only lists its device while a box is
   attached, so this tells "no box" from "driver not loaded". */
static bool sl2_on_usb(void) {
    /* Match USB devices with the SL 2's vendor and product IDs. */
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return false;
    int v = 0x1cc5, p = 0x0013;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    /* Any match means a box is attached. */
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) return false;
    IOObjectRelease(svc);
    return true;
}

/* Send one three-byte MIDI message (status, note, velocity) to the box through the driver.
   True if the driver returned a reply. */
static bool send_hidi(AudioObjectID dev, uint8_t st_byte, uint8_t note, uint8_t vel) {
    /* Build the 0x41 command: [1..4] tag, [5] message length, [6..8] the message. */
    uint8_t req[64] = {0};
    req[0] = 0x41;
    uint32_t seq = 1;
    memcpy(req + 1, &seq, 4);
    req[5] = 0x03;
    req[6] = st_byte;
    req[7] = note;
    req[8] = vel;
    /* Write it to the driver's 'sl2h' property, which sends it to the box. */
    AudioObjectPropertyAddress a = { kSL2PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef inData = CFDataCreate(kCFAllocatorDefault, req, 64);
    OSStatus s = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &inData);
    CFRelease(inData);
    /* Read the reply back; its contents are not checked. */
    if (s == noErr) {
        CFDataRef outData = NULL;
        UInt32 sz = sizeof(CFDataRef);
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &outData) == noErr && outData) {
            CFRelease(outData);
            return true;
        }
    }
    return false;
}

static void print_status(AudioObjectID dev) {
    /* Read the driver's status ('sl2s'). */
    AudioObjectPropertyAddress a = { kSL2PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) != noErr || !d) {
        printf("Error: Could not read SL 2 status from CoreAudio HAL.\n");
        return;
    }
    /* Copy what the driver sent; an older driver's packet may be shorter (no boot_mode). */
    SL2StatusPacket s;
    memset(&s, 0, sizeof s);
    CFIndex n = CFDataGetLength(d);
    memcpy(&s, CFDataGetBytePtr(d), (size_t)(n < (CFIndex)sizeof s ? n : (CFIndex)sizeof s));
    CFRelease(d);

    /* Print it; a box in its bootloader has no other status to show. */
    printf("==================================================\n");
    printf("  Rane SL 2 — Hardware & CoreAudio Status\n");
    printf("==================================================\n");
    printf("  USB Connected : %s\n", s.connected ? "YES" : "NO");
    printf("  Driver Build  : %s\n", s.debug_build ? "DEBUG" : "release");
    if (s.boot_mode) {
        printf("  Firmware      : NOT LOADED — box is in USB bootloader mode\n");
        printf("                  the box needs its firmware restored\n");
        printf("==================================================\n");
        return;
    }
    printf("  Streaming I/O : %s\n", s.streaming ? "ACTIVE" : "IDLE");
    printf("  Sample Rate   : %u Hz\n", s.sample_rate);
    printf("  Firmware Ver  : %u.%02u\n", s.version_maj, s.version_min);
    printf("  Serial Number : %s\n", s.serial[0] ? (const char *)s.serial : "N/A");
    printf("  Deck 1 Input  : %s  |  Mode: %s\n", s.phono[0] ? "PHONO" : "LINE ", s.thru[0] ? "ANALOG THRU" : "USB AUDIO");
    printf("  Deck 2 Input  : %s  |  Mode: %s\n", s.phono[1] ? "PHONO" : "LINE ", s.thru[1] ? "ANALOG THRU" : "USB AUDIO");
    printf("  Captured Frms : %llu\n", s.cap_frames);
    printf("  Playback Frms : %llu\n", s.play_frames);
    if (s.in_safety_us) {
        printf("  Input Safety  : %g ms\n", s.in_safety_us / 1000.0);
        printf("  Early Read    : %s\n", s.early_read == 1 ? "working" : s.early_read == 2 ? "NOT WORKING (use an input safety offset of 8 ms)" : "not judged yet");
        printf("  Input Dropouts: %llu\n", s.in_dropouts);
        printf("  USB Hubs      : %u%s\n", s.hub_depth, s.hub_depth ? "" : " (connected directly)");
    }
    printf("==================================================\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        /* Find the driver's device; without it, say whether a box is attached at all. */
        AudioObjectID dev = find_hal_device();
        if (dev == kAudioObjectUnknown) {
            if (sl2_on_usb())
                printf("Error: an SL 2 is connected, but the SL 2 CoreAudio driver is not loaded in coreaudiod.\n");
            else
                printf("No SL 2 connected.\n");
            return 1;
        }
        /* No command, or "status": print the status. */
        if (argc < 2 || strcmp(argv[1], "status") == 0) {
            print_status(dev);
            return 0;
        }
        /* "thru" / "usb": Note On / Note Off of notes 0x5C and 0x5D turns decks 1 and 2's thru
           on or off. "sr": set the rate through CoreAudio, which changes the box's rate with it. */
        if (strcmp(argv[1], "thru") == 0) {
            send_hidi(dev, 0x90, 0x5C, 0x00);
            send_hidi(dev, 0x90, 0x5D, 0x00);
            printf("Enabled Analog Feed-Thru on Decks 1 & 2.\n");
        } else if (strcmp(argv[1], "usb") == 0) {
            send_hidi(dev, 0x80, 0x5C, 0x00);
            send_hidi(dev, 0x80, 0x5D, 0x00);
            printf("Enabled USB Audio (Feed-Thru Off) on Decks 1 & 2.\n");
        } else if (strcmp(argv[1], "sr") == 0 && argc >= 3) {
            Float64 sr = atof(argv[2]);
            AudioObjectPropertyAddress a = {
                kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(Float64), &sr);
            printf("Set Sample Rate to %.0f Hz.\n", sr);
        } else if (strcmp(argv[1], "safety") == 0) {
            /* "safety [ms]": the input safety offset setting. The driver takes it only with nothing
               streaming, and sets the device up again with it (about half a second). */
            AudioObjectPropertyAddress a = { kSL2PropInSafety, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            if (argc >= 3) {
                int us = (int)lround(atof(argv[2]) * 1000.0);
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &us);
                OSStatus e = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof n, &n);
                CFRelease(n);
                if (e) {
                    printf("Refused (error %d): the setting must be 0.5 to 20 ms, with nothing streaming.\n", (int)e);
                    return 1;
                }
                printf("Input safety offset setting: %g ms.\n", us / 1000.0);
            } else {
                CFNumberRef n = NULL;
                UInt32 sz = sizeof n;
                int us = 0;
                if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &n) || !n) {
                    printf("This driver has no input safety offset setting.\n");
                    return 1;
                }
                CFNumberGetValue(n, kCFNumberIntType, &us);
                CFRelease(n);
                printf("Input safety offset setting: %g ms.\n", us / 1000.0);
            }
        } else {
            /* LINE/PHONO is a physical switch on the box: reported in the status, not settable */
            printf("Usage: sl2panel [status | usb | thru | sr 44100|48000 | safety [ms]]\n");
        }
    }
    return 0;
}
