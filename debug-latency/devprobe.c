// devprobe <name-substring> — dump the HAL properties output-device pickers typically check
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static AudioObjectID find(const char *sub) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    AudioObjectID ids[64]; if (sz > sizeof ids) sz = sizeof ids;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    for (UInt32 i = 0; i < sz / sizeof(AudioObjectID); i++) {
        CFStringRef nm = NULL; UInt32 s = sizeof(CFStringRef);
        AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &s, &nm) || !nm) continue;
        char buf[256]; CFStringGetCString(nm, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(nm);
        if (strstr(buf, sub)) return ids[i];
    }
    return kAudioObjectUnknown;
}

static void u32(AudioObjectID d, const char *label, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { sel, sc, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(d, &a)) { printf("  %-28s : (absent)\n", label); return; }
    UInt32 v = 0, s = sizeof v; OSStatus e = AudioObjectGetPropertyData(d, &a, 0, NULL, &s, &v);
    if (e) printf("  %-28s : err %d\n", label, (int)e); else printf("  %-28s : %u\n", label, v);
}

static void str(AudioObjectID d, const char *label, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(d, &a)) { printf("  %-28s : (absent)\n", label); return; }
    CFStringRef v = NULL; UInt32 s = sizeof(CFStringRef);
    OSStatus e = AudioObjectGetPropertyData(d, &a, 0, NULL, &s, &v);
    char buf[256] = "(null)"; if (!e && v) { CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(v); }
    if (e) printf("  %-28s : err %d\n", label, (int)e); else printf("  %-28s : %s\n", label, buf);
}

static void cfg(AudioObjectID d, const char *label, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration, sc, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; OSStatus e = AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &sz);
    if (e) { printf("  %-28s : size err %d\n", label, (int)e); return; }
    AudioBufferList *bl = malloc(sz); e = AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, bl);
    if (e) { printf("  %-28s : err %d\n", label, (int)e); free(bl); return; }
    printf("  %-28s : %u buffers:", label, bl->mNumberBuffers);
    for (UInt32 i = 0; i < bl->mNumberBuffers; i++) printf(" %uch", bl->mBuffers[i].mNumberChannels);
    printf("\n"); free(bl);
}

static void count(AudioObjectID d, const char *label, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { sel, sc, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; OSStatus e = AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &sz);
    if (e) printf("  %-28s : err %d\n", label, (int)e); else printf("  %-28s : %u ids\n", label, sz / 4);
}

int main(int argc, char **argv) {
    AudioObjectID d = find(argc > 1 ? argv[1] : "SL 2");
    if (!d) { fprintf(stderr, "not found\n"); return 1; }
    printf("device id %u\n", d);
    str(d, "UID", kAudioDevicePropertyDeviceUID);
    str(d, "ModelUID", kAudioDevicePropertyModelUID);
    u32(d, "TransportType", kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
    u32(d, "IsAlive", kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal);
    u32(d, "IsHidden", kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal);
    u32(d, "CanBeDefault (out)", kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput);
    u32(d, "CanBeDefaultSystem (out)", kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput);
    count(d, "Streams (out)", kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    count(d, "Streams (in)", kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    count(d, "Streams (global)", kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal);
    cfg(d, "StreamConfiguration (out)", kAudioObjectPropertyScopeOutput);
    cfg(d, "StreamConfiguration (in)", kAudioObjectPropertyScopeInput);
    u32(d, "Latency (out)", kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput);
    u32(d, "SafetyOffset (out)", kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput);
    u32(d, "BufferFrameSize", kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
    count(d, "PreferredStereo (out)", kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput);
    count(d, "PreferredLayout (out)", kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput);
    return 0;
}
