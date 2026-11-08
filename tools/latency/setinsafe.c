// setinsafe <ms> — DEBUG: set the SL2 driver's input safety offset (whole ms), via the 'sl2h'
// property with command byte 0xF2 (intercepted by the debug build, never sent to the box).
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: setinsafe <ms>\n"); return 2; }
    AudioObjectPropertyAddress ta = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    AudioObjectID dev = 0; UInt32 sz = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &ta, sizeof(CFStringRef), &uid, &sz, &dev) || !dev) {
        fprintf(stderr, "SL2 not found\n"); return 1;
    }
    UInt8 cmd[64] = {0};
    cmd[0] = 0xF2; cmd[5] = (UInt8)atoi(argv[1]);
    CFDataRef d = CFDataCreate(NULL, cmd, sizeof cmd);
    AudioObjectPropertyAddress a = { 'sl2h', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    OSStatus e = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &d);
    CFRelease(d);
    printf("input safety offset -> %d ms (err %d)\n", cmd[5], (int)e);
    return e ? 1 : 0;
}
