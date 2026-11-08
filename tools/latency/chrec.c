// chrec <device-name-substring> <seconds> <out.wav>
// Start IO on a device from cold, capture its input, write a float WAV, and report when signal
// first appears and any dropouts (runs of >= 32 consecutive all-zero frames) after that.
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "common.h"

static float *g_buf;
static size_t g_cap_frames, g_frames;
static UInt32 g_nch;


static OSStatus proc(AudioObjectID d, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                     AudioBufferList *out, const AudioTimeStamp *ot, void *ctx) {
    if (!in || in->mNumberBuffers == 0) return 0;
    const AudioBuffer *ab = &in->mBuffers[0];
    UInt32 nch = ab->mNumberChannels, frames = ab->mDataByteSize / (nch * sizeof(float));
    if (!g_nch) g_nch = nch;
    for (UInt32 f = 0; f < frames && g_frames < g_cap_frames; f++, g_frames++)
        for (UInt32 c = 0; c < nch && c < 8; c++)
            g_buf[g_frames * 8 + c] = ((const float *)ab->mData)[f * nch + c];
    return 0;
}

static void w32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void w16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: chrec <device> <seconds> <out.wav>\n"); return 2; }
    AudioObjectID d = find(argv[1]);
    if (!d) { fprintf(stderr, "device not found\n"); return 1; }
    Float64 sr = 44100; UInt32 s = sizeof sr;
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(d, &ra, 0, NULL, &s, &sr);
    double secs = atof(argv[2]);
    g_cap_frames = (size_t)(secs * sr);
    g_buf = calloc(g_cap_frames * 8, sizeof(float));

    AudioDeviceIOProcID id = NULL;
    if (AudioDeviceCreateIOProcID(d, proc, NULL, &id)) { fprintf(stderr, "CreateIOProcID failed\n"); return 1; }
    AudioDeviceStart(d, id);
    usleep((useconds_t)(secs * 1e6) + 300000);
    AudioDeviceStop(d, id);
    AudioDeviceDestroyIOProcID(d, id);

    size_t n = g_frames; UInt32 nch = g_nch > 8 ? 8 : g_nch;
    printf("captured %zu frames, %u channels at %.0f Hz\n", n, nch, sr);
    for (UInt32 c = 0; c < nch; c++) {
        size_t first = n; float peak = 0;
        for (size_t i = 0; i < n; i++) { float v = g_buf[i * 8 + c]; if (v < 0) v = -v; if (v > peak) peak = v; if (first == n && v > 1e-4f) first = i; }
        if (first == n) { printf("  ch%u: silent\n", c + 1); continue; }
        int drops = 0; size_t run = 0, longest = 0;
        for (size_t i = first; i < n; i++) {
            if (g_buf[i * 8 + c] == 0.0f) { run++; } else { if (run >= 32) { drops++; if (run > longest) longest = run; } run = 0; }
        }
        printf("  ch%u: peak %.3f, signal from frame %zu (%.1f ms), dropouts after that: %d (longest %zu frames)\n",
               c + 1, peak, first, 1000.0 * first / sr, drops, longest);
    }

    FILE *f = fopen(argv[3], "wb");
    uint32_t data = (uint32_t)(n * nch * 4);
    fwrite("RIFF", 1, 4, f); w32(f, 36 + data); fwrite("WAVEfmt ", 1, 8, f);
    w32(f, 16); w16(f, 3); w16(f, (uint16_t)nch); w32(f, (uint32_t)sr); w32(f, (uint32_t)sr * nch * 4); w16(f, (uint16_t)(nch * 4)); w16(f, 32);
    fwrite("data", 1, 4, f); w32(f, data);
    for (size_t i = 0; i < n; i++) fwrite(&g_buf[i * 8], 4, nch, f);
    fclose(f);
    printf("wrote %s\n", argv[3]);
    return 0;
}
