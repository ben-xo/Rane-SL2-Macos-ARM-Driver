// setrate <device-name-substring> [rate]  — print or set a CoreAudio device's nominal sample rate
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: setrate <name-substring> [rate]\n"); return 2; }
    // List the CoreAudio devices (up to 64).
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    AudioObjectID ids[64]; if (sz > sizeof ids) sz = sizeof ids;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    for (UInt32 i = 0; i < sz / sizeof(AudioObjectID); i++) {
        // Skip any device whose name does not contain the given substring.
        CFStringRef nm = NULL; UInt32 s = sizeof nm;
        AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &s, &nm) || !nm) continue;
        char buf[256]; CFStringGetCString(nm, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(nm);
        if (!strstr(buf, argv[1])) continue;
        // Set the rate if one was given, otherwise print the current one.
        AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Float64 r = 0; s = sizeof r;
        if (argc >= 3) {
            r = atof(argv[2]);
            OSStatus e = AudioObjectSetPropertyData(ids[i], &ra, 0, NULL, sizeof r, &r);
            printf("%s: set %.0f -> err %d\n", buf, r, (int)e);
        } else {
            AudioObjectGetPropertyData(ids[i], &ra, 0, NULL, &s, &r);
            printf("%s: %.0f\n", buf, r);
        }
        return 0;
    }
    fprintf(stderr, "no device matching '%s'\n", argv[1]); return 1;
}
