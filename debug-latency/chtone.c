// chtone <device-name-substring> <seconds> <ch...>  — play a 440 Hz sine on the given 1-based
// output channels of a device via a direct IOProc (the way Audio MIDI Setup's test tone does).
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_mask = 0;
static double g_phase = 0, g_sr = 44100;

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

static OSStatus proc(AudioObjectID d, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                     AudioBufferList *out, const AudioTimeStamp *ot, void *ctx) {
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *ab = &out->mBuffers[b];
        UInt32 nch = ab->mNumberChannels, frames = ab->mDataByteSize / (nch * sizeof(float));
        float *p = ab->mData;
        double ph = g_phase;
        for (UInt32 f = 0; f < frames; f++) {
            float v = 0.4f * (float)sin(ph);
            ph += 2 * M_PI * 440.0 / g_sr;
            for (UInt32 c = 0; c < nch; c++) p[f * nch + c] = (g_mask & (1 << c)) ? v : 0.0f;
        }
        if (b == out->mNumberBuffers - 1) g_phase = fmod(ph, 2 * M_PI);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: chtone <device> <seconds> <ch...>\n"); return 2; }
    AudioObjectID d = find(argv[1]);
    if (!d) { fprintf(stderr, "device not found\n"); return 1; }
    for (int i = 3; i < argc; i++) g_mask |= 1 << (atoi(argv[i]) - 1);
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 s = sizeof g_sr; AudioObjectGetPropertyData(d, &ra, 0, NULL, &s, &g_sr);
    AudioDeviceIOProcID id = NULL;
    if (AudioDeviceCreateIOProcID(d, proc, NULL, &id)) { fprintf(stderr, "CreateIOProcID failed\n"); return 1; }
    AudioDeviceStart(d, id);
    printf("tone on channel mask 0x%x for %ss at %.0f Hz\n", g_mask, argv[2], g_sr); fflush(stdout);
    usleep((useconds_t)(atof(argv[2]) * 1e6));
    AudioDeviceStop(d, id);
    AudioDeviceDestroyIOProcID(d, id);
    return 0;
}
