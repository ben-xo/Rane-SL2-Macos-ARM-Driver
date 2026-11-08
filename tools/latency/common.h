// common.h — shared by the latency tools.
#pragma once
#include <CoreAudio/CoreAudio.h>
#include <string.h>

// The first CoreAudio device whose name contains `sub` (e.g. "SL 2"), or kAudioObjectUnknown.
static AudioObjectID find(const char *sub) {
    // List the devices (up to 64).
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    AudioObjectID ids[64]; if (sz > sizeof ids) sz = sizeof ids;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    // Return the first whose name contains `sub`.
    for (UInt32 i = 0; i < sz / sizeof(AudioObjectID); i++) {
        CFStringRef nm = NULL; UInt32 s = sizeof(CFStringRef);
        AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &s, &nm) || !nm) continue;
        char buf[256]; CFStringGetCString(nm, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(nm);
        if (strstr(buf, sub)) return ids[i];
    }
    return kAudioObjectUnknown;
}
