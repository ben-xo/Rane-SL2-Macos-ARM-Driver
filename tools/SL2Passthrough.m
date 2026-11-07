// SPDX-License-Identifier: GPL-3.0-or-later
/* SL2Passthrough.m — see SL2Passthrough.h. */
#import "SL2Passthrough.h"
#import <Foundation/Foundation.h>
#include <string.h>

#define kSL2PropHIDCommand  'sl2h'
#define OP_VERSION  0x01
#define OP_WRITE    0x02
#define OP_READ     0x03

AudioObjectID sl2h_find_device(void) {
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

bool sl2h_command(AudioObjectID dev, uint8_t req[SL2_REPORT], uint8_t reply[SL2_REPORT]) {
    /* A non-zero tag: the driver matches the box's reply to it (with 0 it uses its own). */
    static uint32_t tag = 0;
    if (++tag == 0) tag = 1;
    memcpy(req + 1, &tag, 4);

    AudioObjectPropertyAddress a = { kSL2PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef in = CFDataCreate(kCFAllocatorDefault, req, SL2_REPORT);
    OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &in);
    CFRelease(in);
    if (st != noErr) return false;

    CFDataRef out = NULL;
    UInt32 sz = sizeof(out);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &out) != noErr || !out) return false;
    memset(reply, 0, SL2_REPORT);
    CFIndex n = CFDataGetLength(out);
    memcpy(reply, CFDataGetBytePtr(out), (size_t)(n < SL2_REPORT ? n : SL2_REPORT));
    CFRelease(out);
    return reply[0] == req[0] && memcmp(reply + 1, req + 1, 4) == 0;
}

bool sl2h_version(AudioObjectID dev, uint8_t *major, uint8_t *minor) {
    uint8_t req[SL2_REPORT] = { OP_VERSION }, reply[SL2_REPORT];
    if (!sl2h_command(dev, req, reply)) return false;
    *major = reply[5];
    *minor = reply[6];
    return true;
}

/* 0x02 and 0x03 echo the address at reply[5..6]; checking it as well as the tag guards against
   a reply that belongs to a different block. */
static bool eeprom_cmd(AudioObjectID dev, uint8_t op, uint16_t addr, const uint8_t *data, uint8_t out[SL2_EEPROM_BLOCK], int attempts) {
    for (int i = 0; i < attempts; i++) {
        uint8_t req[SL2_REPORT] = { op }, reply[SL2_REPORT];
        req[5] = (uint8_t)(addr >> 8);
        req[6] = (uint8_t)(addr & 0xFF);
        if (data) memcpy(req + 7, data, SL2_EEPROM_BLOCK);
        if (sl2h_command(dev, req, reply) && reply[5] == req[5] && reply[6] == req[6]) {
            memcpy(out, reply + 7, SL2_EEPROM_BLOCK);
            return true;
        }
    }
    return false;
}

bool sl2h_eeprom_read(AudioObjectID dev, uint16_t addr, uint8_t out[SL2_EEPROM_BLOCK]) {
    return eeprom_cmd(dev, OP_READ, addr, NULL, out, 3);
}

/* Rewriting a block with the same data is harmless, so a write whose reply went missing is
   simply sent again. */
bool sl2h_eeprom_write(AudioObjectID dev, uint16_t addr, const uint8_t data[SL2_EEPROM_BLOCK],
                       uint8_t readback[SL2_EEPROM_BLOCK]) {
    return eeprom_cmd(dev, OP_WRITE, addr, data, readback, 2);
}

bool sl2h_is_streaming(AudioObjectID dev) {
    AudioObjectPropertyAddress a = {
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 running = 0, sz = sizeof(running);
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &running) == noErr && running;
}
