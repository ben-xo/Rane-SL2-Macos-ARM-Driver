// setxp <mode> [lead] — DEBUG: late-write experiment for the SL2 driver's next stream
// (0 off, 1 late write, 2 write at submit), via 'sl2h' command byte 0xF3 (never sent to the box).
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: setxp <mode 0|1|2> [lead frames]\n"); return 2; }
    AudioObjectPropertyAddress ta = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    AudioObjectID dev = 0; UInt32 sz = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &ta, sizeof(CFStringRef), &uid, &sz, &dev) || !dev) {
        fprintf(stderr, "SL2 not found\n"); return 1;
    }
    UInt8 cmd[64] = {0};
    cmd[0] = 0xF3; cmd[5] = (UInt8)atoi(argv[1]); cmd[6] = (UInt8)(argc > 2 ? atoi(argv[2]) : 2);
    CFDataRef d = CFDataCreate(NULL, cmd, sizeof cmd);
    AudioObjectPropertyAddress a = { 'sl2h', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    OSStatus e = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &d);
    CFRelease(d);
    printf("next stream: experiment mode %d, lead %d (err %d)\n", cmd[5], cmd[6], (int)e);
    return e ? 1 : 0;
}
