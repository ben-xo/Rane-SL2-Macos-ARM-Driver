// meters <device> [seconds]
// Reads the SL 2 driver's level meters ('sl2m') ten times a second for the given time (default 1 s)
// and prints the highest peak of each input and output channel, in dB (or "-inf" for silence). The
// meters move only while an app is streaming through the SL 2.
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "common.h"

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: meters <device> [seconds]\n"); return 2; }
    AudioObjectID d = find(argv[1]);
    if (!d) { fprintf(stderr, "no device matching \"%s\"\n", argv[1]); return 1; }
    double secs = argc > 2 ? atof(argv[2]) : 1.0;

    // Read the meters every 100 ms, keeping each channel's highest peak.
    AudioObjectPropertyAddress a = { 'sl2m', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    float peak[8] = { 0 };
    for (int i = 0; i <= (int)(secs * 10); i++) {
        CFDataRef cf = NULL;
        UInt32 sz = sizeof(CFDataRef);   // the property's value is the CFDataRef itself
        if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &cf) || !cf) {
            fprintf(stderr, "the driver has no level meters ('sl2m')\n");
            return 1;
        }
        if (CFDataGetLength(cf) == sizeof peak) {
            const float *v = (const float *)CFDataGetBytePtr(cf);
            for (int c = 0; c < 8; c++) if (v[c] > peak[c]) peak[c] = v[c];
        }
        CFRelease(cf);
        usleep(100000);
    }

    // Print them in dB: inputs 1-4, then outputs 1-4.
    printf("in");
    for (int c = 0; c < 8; c++) {
        if (c == 4) printf(", out");
        if (peak[c] > 0) printf(" %.1f", 20 * log10f(peak[c]));
        else             printf(" -inf");
    }
    printf(" dB\n");
    return 0;
}
