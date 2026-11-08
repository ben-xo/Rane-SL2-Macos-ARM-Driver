// sinetest <device-name-substring> <out-ch> <in-ch> <seconds> [buffer-frames]
// Glitch detector through a physical loopback. Plays a continuous 997 Hz sine on <out-ch>, captures
// <in-ch>, and checks every captured sample against the sine recurrence
//     x[n+1] - 2 cos(w) x[n] + x[n-1] = 0
// which holds for any amplitude and phase (and survives the linear DAC/ADC filtering). A dropout,
// repeat, skip or click breaks it. Reports glitches (residual far above the noise floor) after the
// first second, and the HAL's own IO overloads.
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FREQ 997.0
#define AMP  0.4

static int g_out_ch, g_in_ch;
static double g_sr = 44100, g_phase;
static float *g_in;
static size_t g_len, g_n;
static double g_in0 = -1, g_last_in_end = -1;
static int g_in_gaps;              /* input cycles whose sample time did not follow the previous one */
static _Atomic int g_overloads;

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

static OSStatus overload_listener(AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a, void *c) {
    g_overloads++;
    return 0;
}

static OSStatus proc(AudioObjectID d, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                     AudioBufferList *out, const AudioTimeStamp *ot, void *ctx) {
    if (in && in->mNumberBuffers > 0) {
        const AudioBuffer *ab = &in->mBuffers[0];
        UInt32 nch = ab->mNumberChannels, frames = ab->mDataByteSize / (nch * sizeof(float));
        if (g_last_in_end >= 0 && it->mSampleTime != g_last_in_end) g_in_gaps++;
        g_last_in_end = it->mSampleTime + frames;
        for (UInt32 f = 0; f < frames && g_n < g_len; f++)
            g_in[g_n++] = ((UInt32)(g_in_ch - 1) < nch) ? ((const float *)ab->mData)[f * nch + (g_in_ch - 1)] : 0;
    }
    if (out && out->mNumberBuffers > 0) {
        AudioBuffer *ab = &out->mBuffers[0];
        UInt32 nch = ab->mNumberChannels, frames = ab->mDataByteSize / (nch * sizeof(float));
        float *p = ab->mData;
        memset(p, 0, ab->mDataByteSize);
        double w = 2 * M_PI * FREQ / g_sr;
        for (UInt32 f = 0; f < frames; f++) {
            if ((UInt32)(g_out_ch - 1) < nch) p[f * nch + (g_out_ch - 1)] = (float)(AMP * sin(g_phase));
            g_phase += w;
        }
        g_phase = fmod(g_phase, 2 * M_PI);
    }
    return 0;
}

static int cmpf(const void *a, const void *b) { float x = *(const float *)a, y = *(const float *)b; return (x > y) - (x < y); }

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: sinetest <device> <out-ch> <in-ch> <seconds> [buffer-frames]\n"); return 2; }
    AudioObjectID d = find(argv[1]);
    if (!d) { fprintf(stderr, "device not found\n"); return 1; }
    g_out_ch = atoi(argv[2]); g_in_ch = atoi(argv[3]);
    double secs = atof(argv[4]);
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 s = sizeof g_sr; AudioObjectGetPropertyData(d, &ra, 0, NULL, &s, &g_sr);
    AudioObjectPropertyAddress ba = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (argc > 5) { UInt32 bf = (UInt32)atoi(argv[5]); AudioObjectSetPropertyData(d, &ba, 0, NULL, sizeof bf, &bf); }
    UInt32 bufsz = 0; s = sizeof bufsz; AudioObjectGetPropertyData(d, &ba, 0, NULL, &s, &bufsz);
    AudioObjectPropertyAddress oa = { kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListener(d, &oa, overload_listener, NULL);

    g_len = (size_t)(secs * g_sr) + 8192;
    g_in = calloc(g_len, sizeof(float));
    AudioDeviceIOProcID id = NULL;
    if (AudioDeviceCreateIOProcID(d, proc, NULL, &id)) { fprintf(stderr, "CreateIOProcID failed\n"); return 1; }
    AudioDeviceStart(d, id);
    usleep((useconds_t)(secs * 1e6));
    AudioDeviceStop(d, id);
    AudioDeviceDestroyIOProcID(d, id);
    AudioObjectRemovePropertyListener(d, &oa, overload_listener, NULL);

    size_t start = (size_t)g_sr;          /* skip the first second (stream start-up) */
    if (g_n < start + 1000) { printf("too little captured (%zu frames)\n", g_n); return 1; }
    double c2 = 2 * cos(2 * M_PI * FREQ / g_sr);
    size_t m = g_n - 1 - start;
    float *r = malloc(m * sizeof(float)), *sorted = malloc(m * sizeof(float));
    float peak = 0;
    for (size_t i = 0; i < m; i++) {
        size_t n = start + i;
        r[i] = fabsf((float)(g_in[n + 1] - c2 * g_in[n] + g_in[n - 1]));
        if (fabsf(g_in[n]) > peak) peak = fabsf(g_in[n]);
    }
    memcpy(sorted, r, m * sizeof(float));
    qsort(sorted, m, sizeof(float), cmpf);
    float median = sorted[m / 2], p999 = sorted[(size_t)(m * 0.999)];
    float thresh = fmaxf(median * 30.0f, peak * 0.02f);
    int glitches = 0; size_t last = 0; float worst = 0;
    for (size_t i = 0; i < m; i++) {
        if (r[i] > worst) worst = r[i];
        if (r[i] > thresh) {
            size_t n = start + i;
            if (glitches == 0 || n - last > 64) {
                if (glitches < 10) printf("  glitch at %.3f s (residual %.4f)\n", (double)n / g_sr, r[i]);
                glitches++;
            }
            last = n;
        }
    }
    /* level check: silence or a level drop satisfies the recurrence too, so also flag any 10 ms
       window whose peak falls below half the typical window peak */
    size_t win = (size_t)(g_sr / 100), nw = m / win;
    float *wp = malloc(nw * sizeof(float)), *ws = malloc(nw * sizeof(float));
    for (size_t j = 0; j < nw; j++) {
        float p = 0;
        for (size_t i = 0; i < win; i++) { float v = fabsf(g_in[start + j * win + i]); if (v > p) p = v; }
        wp[j] = ws[j] = p;
    }
    qsort(ws, nw, sizeof(float), cmpf);
    float typical = ws[nw / 2];
    int drops = 0; size_t drop_frames = 0;
    for (size_t j = 0; j < nw; j++) {
        if (wp[j] < typical * 0.5f) {
            if (drops == 0 || wp[j - 1] >= typical * 0.5f) {
                if (drops < 10) printf("  level drop at %.3f s (window peak %.3f vs typical %.3f)\n",
                                       (double)(start + j * win) / g_sr, wp[j], typical);
                drops++;
            }
            drop_frames += win;
        }
    }

    printf("rate %.0f Hz, IO buffer %u, %.1f s analysed, signal peak %.3f, typical level %.3f, residual median %.5f p99.9 %.5f max %.4f\n",
           g_sr, bufsz, (double)m / g_sr, peak, typical, median, p999, worst);
    printf("RESULT: %d glitches, %d level drops (%.2f s total), %d HAL overloads, %d input timestamp gaps\n",
           glitches, drops, (double)drop_frames / g_sr, (int)g_overloads, g_in_gaps);
    return (glitches || drops) ? 3 : 0;
}
