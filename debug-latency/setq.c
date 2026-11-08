// setq <mode> <rt> — DEBUG: for the SL2 driver's next stream, choose the USB queue
// (0 = plain serial, 1 = workloop + audio work interval) and whether to request the realtime
// thread policy, via the 'sl2h' property with command byte 0xF1 (never sent to the box).
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: setq <mode 0|1> <rt 0|1>\n"); return 2; }
    AudioObjectPropertyAddress ta = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    AudioObjectID dev = 0; UInt32 sz = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &ta, sizeof(CFStringRef), &uid, &sz, &dev) || !dev) {
        fprintf(stderr, "SL2 not found\n"); return 1;
    }
    UInt8 cmd[64] = {0};
    cmd[0] = 0xF1; cmd[5] = (UInt8)atoi(argv[1]); cmd[6] = (UInt8)atoi(argv[2]);
    CFDataRef d = CFDataCreate(NULL, cmd, sizeof cmd);
    AudioObjectPropertyAddress a = { 'sl2h', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    OSStatus e = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &d);
    CFRelease(d);
    printf("next stream: queue mode %d, realtime %d (err %d)\n", cmd[5], cmd[6], (int)e);
    return e ? 1 : 0;
}
