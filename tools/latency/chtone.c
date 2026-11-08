// chtone <device-name-substring> <seconds> <ch...>  — play a 440 Hz sine on the given 1-based
// output channels of a device via a direct IOProc (the way Audio MIDI Setup's test tone does).
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "common.h"

static int g_mask = 0;
static double g_phase = 0, g_sr = 44100;


static OSStatus proc(AudioObjectID d, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                     AudioBufferList *out, const AudioTimeStamp *ot, void *ctx) {
    // Fill every output buffer: the sine on the chosen channels, silence on the rest.
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
    // Turn the 1-based channel list into a bit mask.
    for (int i = 3; i < argc; i++) g_mask |= 1 << (atoi(argv[i]) - 1);
    // Read the sample rate, so the tone is 440 Hz at any rate.
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 s = sizeof g_sr; AudioObjectGetPropertyData(d, &ra, 0, NULL, &s, &g_sr);
    // Play the tone for the requested time.
    AudioDeviceIOProcID id = NULL;
    if (AudioDeviceCreateIOProcID(d, proc, NULL, &id)) { fprintf(stderr, "CreateIOProcID failed\n"); return 1; }
    AudioDeviceStart(d, id);
    printf("tone on channel mask 0x%x for %ss at %.0f Hz\n", g_mask, argv[2], g_sr); fflush(stdout);
    usleep((useconds_t)(atof(argv[2]) * 1e6));
    AudioDeviceStop(d, id);
    AudioDeviceDestroyIOProcID(d, id);
    return 0;
}
