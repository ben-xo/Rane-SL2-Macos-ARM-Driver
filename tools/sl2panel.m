/*
 * sl2panel.m — Rane SL 2 Hardware Control Panel CLI
 *
 * Works seamlessly even while CoreAudio (coreaudiod) / Serato is streaming
 * by routing commands through the SL2Device CoreAudio HAL PlugIn ('sl2h' / 'sl2s').
 */
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

#define kSL2PropHIDCommand  'sl2h'
#define kSL2PropStatus      'sl2s'

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

static bool send_hidi(AudioObjectID dev, uint8_t st_byte, uint8_t note, uint8_t vel) {
    uint8_t req[64] = {0};
    req[0] = 0x41;
    uint32_t seq = 1;
    memcpy(req + 1, &seq, 4);
    req[5] = 0x03;
    req[6] = st_byte;
    req[7] = note;
    req[8] = vel;
    AudioObjectPropertyAddress a = { kSL2PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef inData = CFDataCreate(kCFAllocatorDefault, req, 64);
    OSStatus s = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &inData);
    CFRelease(inData);
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
    AudioObjectPropertyAddress a = { kSL2PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) != noErr || !d) {
        printf("Error: Could not read SL 2 status from CoreAudio HAL.\n");
        return;
    }
    SL2StatusPacket s;
    memcpy(&s, CFDataGetBytePtr(d), sizeof(s));
    CFRelease(d);

    printf("==================================================\n");
    printf("  Rane SL 2 — Hardware & CoreAudio Status\n");
    printf("==================================================\n");
    printf("  USB Connected : %s\n", s.connected ? "YES" : "NO");
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
    printf("==================================================\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        AudioObjectID dev = find_hal_device();
        if (dev == kAudioObjectUnknown) {
            printf("Error: SL 2 CoreAudio HAL driver not loaded in coreaudiod.\n");
            return 1;
        }
        if (argc < 2 || strcmp(argv[1], "status") == 0) {
            print_status(dev);
            return 0;
        }
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
        } else {
            /* LINE/PHONO is a physical switch on the box: reported in the status, not settable */
            printf("Usage: sl2panel [status | usb | thru | sr 44100|48000]\n");
        }
    }
    return 0;
}
