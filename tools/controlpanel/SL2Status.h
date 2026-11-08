/*
 * SL2Status.h — the driver's status packet ('sl2s'), for the Swift control panel. A C struct, so
 * Swift sees the same layout the driver writes; it must match SL2StatusPacket in plugin/SL2Device.m.
 */
#include <stdint.h>

typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];       /* 1 = Phono, 0 = Line (one switch on the box, shared by both decks) */
    uint8_t  thru[4];        /* 1 = analogue thru, 0 = USB audio */
    uint8_t  port_a;
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
    uint32_t boot_mode;      /* 1 = the box is in its USB bootloader: no firmware loaded */
} SL2StatusPacket;
