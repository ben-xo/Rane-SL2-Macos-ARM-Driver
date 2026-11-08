// rtlat <device-name-substring> <out-ch> <in-ch> [clicks] [buffer-frames]
// Round-trip latency through a physical loopback cable (device output -> device input).
// Starts IO from cold, writes a short click on <out-ch> every 0.5 s, finds each click in <in-ch>,
// and reports, using the HAL's own sample timestamps:
//   hidden   = input sample where the click is found - output sample it was written at
//              (latency in driver/USB/box that the timestamps don't account for)
//   cycle    = outputTime - inputTime within one IO cycle (safety offsets + IO buffer, as the HAL sees it)
//   DVS est. = hidden + cycle: input jack -> app -> output jack, for an app that responds in the same cycle
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "common.h"

#define MAXCLICK 64
#define CLICK_LEN 48
#define CLICK_AMP 0.5f

static int g_out_ch, g_in_ch, g_nclicks;
static double g_sr = 44100, g_interval;
static double g_next_click = -1;            /* output sample time of the next click to write */
static double g_click_out[MAXCLICK];        /* output sample time each click was written at */
static int g_written;
static double g_cycle_gap = 0;              /* outputTime - inputTime, last cycle */
static float *g_in;                         /* captured input channel, indexed by (input sample time - g_in0) */
static double g_in0 = -1;
static size_t g_in_len;


static OSStatus proc(AudioObjectID d, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                     AudioBufferList *out, const AudioTimeStamp *ot, void *ctx) {
    /* input: store the chosen channel by HAL input sample time */
    if (in && in->mNumberBuffers > 0) {
        const AudioBuffer *ab = &in->mBuffers[0];
        UInt32 nch = ab->mNumberChannels, frames = ab->mDataByteSize / (nch * sizeof(float));
        if (g_in0 < 0) g_in0 = it->mSampleTime;
        for (UInt32 f = 0; f < frames; f++) {
            double idx = it->mSampleTime + f - g_in0;
            if (idx >= 0 && idx < g_in_len && (UInt32)(g_in_ch - 1) < nch)
                g_in[(size_t)idx] = ((const float *)ab->mData)[f * nch + (g_in_ch - 1)];
        }
    }
    /* output: silence, plus clicks at their scheduled output sample times */
    if (out && out->mNumberBuffers > 0) {
        AudioBuffer *ab = &out->mBuffers[0];
        UInt32 nch = ab->mNumberChannels, frames = ab->mDataByteSize / (nch * sizeof(float));
        float *p = ab->mData;
        memset(p, 0, ab->mDataByteSize);
        // The "cycle" figure: how far ahead of input this cycle's output is, in samples.
        g_cycle_gap = ot->mSampleTime - it->mSampleTime;
        if (g_next_click < 0) g_next_click = ot->mSampleTime + g_sr * 0.75;   /* let things settle first */
        // Write every click due in this buffer [t0, t1) and step on to the next one.
        double t0 = ot->mSampleTime, t1 = t0 + frames;
        while (g_written < g_nclicks && g_next_click < t1) {
            if (g_next_click >= t0) {
                UInt32 start = (UInt32)(g_next_click - t0);
                for (UInt32 f = start; f < frames && f < start + CLICK_LEN; f++)
                    if ((UInt32)(g_out_ch - 1) < nch) p[f * nch + (g_out_ch - 1)] = CLICK_AMP;
                g_click_out[g_written++] = g_next_click;
            }
            g_next_click += g_interval;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: rtlat <device> <out-ch> <in-ch> [clicks] [buffer-frames]\n"); return 2; }
    // Find the device and read the arguments.
    AudioObjectID d = find(argv[1]);
    if (!d) { fprintf(stderr, "device not found\n"); return 1; }
    g_out_ch = atoi(argv[2]); g_in_ch = atoi(argv[3]);
    g_nclicks = argc > 4 ? atoi(argv[4]) : 6; if (g_nclicks > MAXCLICK) g_nclicks = MAXCLICK;

    // Read the sample rate (a click every 0.5 s) and apply the IO buffer size, if given.
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 s = sizeof g_sr; AudioObjectGetPropertyData(d, &ra, 0, NULL, &s, &g_sr);
    g_interval = g_sr * 0.5;
    if (argc > 5) {
        UInt32 bf = (UInt32)atoi(argv[5]);
        AudioObjectPropertyAddress ba = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectSetPropertyData(d, &ba, 0, NULL, sizeof bf, &bf);
    }
    // Read back the IO buffer size in use, for the report.
    UInt32 bufsz = 0; s = sizeof bufsz;
    AudioObjectPropertyAddress ba = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(d, &ba, 0, NULL, &s, &bufsz);

    // Capture buffer: the settling time, every click, and a second for the last one to come back.
    double secs = 0.75 + g_nclicks * 0.5 + 1.0;
    g_in_len = (size_t)(secs * g_sr) + 8192;
    g_in = calloc(g_in_len, sizeof(float));

    // Start IO from cold, run until every click has had time to come back, then stop.
    AudioDeviceIOProcID id = NULL;
    if (AudioDeviceCreateIOProcID(d, proc, NULL, &id)) { fprintf(stderr, "CreateIOProcID failed\n"); return 1; }
    AudioDeviceStart(d, id);
    usleep((useconds_t)(secs * 1e6));
    AudioDeviceStop(d, id);
    AudioDeviceDestroyIOProcID(d, id);

    /* noise floor from the stretch before the first click could have arrived, skipping the first
       300 ms: the box needs ~100 ms to leave analog thru, and with a loopback cable whatever was
       circulating through thru shows up there */
    float noise = 0;
    size_t quiet_end = (g_written > 0 && g_click_out[0] > g_in0) ? (size_t)(g_click_out[0] - g_in0) : 0;
    for (size_t i = (size_t)(0.3 * g_sr); i < quiet_end && i < g_in_len; i++) if (fabsf(g_in[i]) > noise) noise = fabsf(g_in[i]);
    float thresh = fmaxf(noise * 4.0f, 0.02f);

    // Report the setup and the cycle gap.
    printf("rate %.0f Hz, IO buffer %u frames, out ch%d -> in ch%d, noise floor %.4f, threshold %.4f\n",
           g_sr, bufsz, g_out_ch, g_in_ch, noise, thresh);
    printf("cycle gap (outputTime - inputTime): %.0f frames = %.1f ms\n", g_cycle_gap, 1000.0 * g_cycle_gap / g_sr);
    // Find each click: the first input sample above the threshold after the click was written.
    double sum = 0; int found = 0;
    for (int c = 0; c < g_written; c++) {
        double o = g_click_out[c] - g_in0;           /* output sample time, in input-buffer index units */
        size_t from = o > 0 ? (size_t)o : 0, to = (size_t)(o + g_interval * 0.9);
        long hit = -1; float pk = 0;
        for (size_t i = from; i < to && i < g_in_len; i++) {
            if (hit < 0 && fabsf(g_in[i]) > thresh) hit = (long)i;
            if (fabsf(g_in[i]) > pk) pk = fabsf(g_in[i]);
        }
        if (hit < 0) { printf("  click %d: not found (peak in window %.4f)\n", c + 1, pk); continue; }
        double hidden = (double)hit - o;
        printf("  click %d: hidden %.0f frames = %.1f ms   DVS est. %.1f ms   (peak %.3f)\n",
               c + 1, hidden, 1000.0 * hidden / g_sr, 1000.0 * (hidden + g_cycle_gap) / g_sr, pk);
        sum += hidden; found++;
    }
    // Average the hidden latency over the clicks found.
    if (found) {
        double h = sum / found;
        printf("mean: hidden %.1f ms, DVS round trip est. %.1f ms (%d/%d clicks)\n",
               1000.0 * h / g_sr, 1000.0 * (h + g_cycle_gap) / g_sr, found, g_written);
    }
    return 0;
}
