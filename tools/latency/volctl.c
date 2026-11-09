// volctl <device> [get | <dB> [channel] | main <0..1> | mute | unmute]
// A device's output volume and mute through the HAL properties that Audio MIDI Setup uses:
//   <dB>          sets the main (master) volume; with a channel number, that output channel's volume
//   main <0..1>   sets the HAL's virtual main volume, as the menu bar and the volume keys do
//   mute, unmute  the output mute
// Prints the state as "volume <dB> dB, channels <dB ch1> <dB ch2> ... dB, mute <0|1>" (no channels
// part if the device has no per-channel controls). Exits 1 if the device has no main volume and
// mute, or a setting was refused or can't be read.
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // AudioHardwareService: the virtual main volume

static AudioObjectPropertyAddress vol_addr(UInt32 element) {
    return (AudioObjectPropertyAddress){ kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, element };
}
static const AudioObjectPropertyAddress kMute = { kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
static const AudioObjectPropertyAddress kMain = { kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: volctl <device> [get | <dB> [channel] | main <0..1> | mute | unmute]\n"); return 2; }
    AudioObjectID d = find(argv[1]);
    if (!d) { fprintf(stderr, "no device matching \"%s\"\n", argv[1]); return 1; }

    // The main volume and mute, and the output channels that have a volume control of their own.
    AudioObjectPropertyAddress mainvol = vol_addr(kAudioObjectPropertyElementMain);
    if (!AudioObjectHasProperty(d, &mainvol) || !AudioObjectHasProperty(d, &kMute)) {
        fprintf(stderr, "%s has no output volume and mute controls\n", argv[1]);
        return 1;
    }
    UInt32 nch = 0;
    for (UInt32 ch = 1; ch <= 64; ch++) {
        AudioObjectPropertyAddress a = vol_addr(ch);
        if (!AudioObjectHasProperty(d, &a)) break;
        nch = ch;
    }

    // Set what was asked for.
    const char *a = argc > 2 ? argv[2] : "get";
    OSStatus e = 0;
    if (!strcmp(a, "mute") || !strcmp(a, "unmute")) {
        UInt32 m = !strcmp(a, "mute");
        e = AudioObjectSetPropertyData(d, &kMute, 0, NULL, sizeof m, &m);
    } else if (!strcmp(a, "main")) {
        char *end; Float32 v = argc > 3 ? strtof(argv[3], &end) : -1;
        if (argc < 4 || end == argv[3] || *end || v < 0 || v > 1) { fprintf(stderr, "main takes a volume from 0 to 1\n"); return 2; }
        e = AudioHardwareServiceSetPropertyData(d, &kMain, 0, NULL, sizeof v, &v);
    } else if (strcmp(a, "get")) {
        char *end; Float32 db = strtof(a, &end);
        if (end == a || *end) { fprintf(stderr, "not a level in dB: '%s'\n", a); return 2; }
        UInt32 ch = argc > 3 ? (UInt32)atoi(argv[3]) : 0;
        if (argc > 3 && (ch < 1 || ch > nch)) { fprintf(stderr, "no volume control on output channel %s\n", argv[3]); return 2; }
        AudioObjectPropertyAddress va = vol_addr(ch);
        e = AudioObjectSetPropertyData(d, &va, 0, NULL, sizeof db, &db);
    }
    if (e) { fprintf(stderr, "setting %s refused: %d\n", a, (int)e); return 1; }

    // Report the state now, at full precision so a script can restore it exactly.
    for (UInt32 ch = 0; ch <= nch; ch++) {
        AudioObjectPropertyAddress va = vol_addr(ch);
        Float32 db = 0; UInt32 sz = sizeof db;
        if (AudioObjectGetPropertyData(d, &va, 0, NULL, &sz, &db)) { fprintf(stderr, "\nreading volume element %u failed\n", ch); return 1; }
        if (ch == 0) printf("volume %.9g dB", db);
        else         printf("%s%.9g", ch == 1 ? ", channels " : " ", db);
    }
    UInt32 m = 0, sz = sizeof m;
    if (AudioObjectGetPropertyData(d, &kMute, 0, NULL, &sz, &m)) { fprintf(stderr, "\nreading the mute failed\n"); return 1; }
    printf("%s, mute %u\n", nch ? " dB" : "", m);
    return 0;
}
