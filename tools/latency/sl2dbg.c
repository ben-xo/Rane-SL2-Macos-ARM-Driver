// sl2dbg — send a debug command to the SL 2 driver (debug build only: make plugin DEBUG=1).
// The driver handles these itself and never sends them to the box; a release build refuses them.
//   sl2dbg stall <ms>         hold the driver's USB queue this long, once, as a stall in USB
//                             completion delivery would
//   sl2dbg errpkts <n>        treat the next n capture packets as errored
//   sl2dbg noearly 1|0        1: the early capture read places nothing, as on a Mac where it can't
//                             work (the driver then falls back to an 8 ms input safety offset)
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int usage(void) {
    fprintf(stderr, "usage: sl2dbg stall <ms> | errpkts <n> | noearly 1|0\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 3) return usage();

    // Build the command: opcode at [0], argument from [5] (bytes [1..4] are the request tag).
    UInt8 cmd[64] = {0};
    long v = strtol(argv[2], NULL, 10);
    if (!strcmp(argv[1], "stall"))     { cmd[0] = 0xF3; cmd[5] = (UInt8)(v >> 8); cmd[6] = (UInt8)v; }
    else if (!strcmp(argv[1], "errpkts"))   { cmd[0] = 0xF4; cmd[5] = (UInt8)v; }
    else if (!strcmp(argv[1], "noearly"))   { cmd[0] = 0xF5; cmd[5] = v ? 1 : 0; }
    else return usage();

    // Find the driver's device by its UID.
    AudioObjectPropertyAddress ta = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    AudioObjectID dev = 0; UInt32 sz = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &ta, sizeof(CFStringRef), &uid, &sz, &dev) || !dev) {
        fprintf(stderr, "SL 2 not found (no box attached, or the driver is not loaded)\n");
        return 1;
    }

    // Send it through the driver's 'sl2h' property; a release build answers with an error.
    CFDataRef d = CFDataCreate(NULL, cmd, sizeof cmd);
    AudioObjectPropertyAddress a = { 'sl2h', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    OSStatus e = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &d);
    CFRelease(d);
    if (e) {
        fprintf(stderr, "refused (error %d): is the driver a debug build (make plugin DEBUG=1)?\n", (int)e);
        return 1;
    }
    printf("%s %s: done\n", argv[1], argv[2]);
    return 0;
}
