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
    uint32_t debug_build;    /* 1 = the driver is a debug build (make install DEBUG=1) */
    /* Input health (newer drivers; zero from an older one) */
    uint32_t in_safety_us;          /* the input safety offset the HAL is using, in us */
    uint32_t in_safety_setting_us;  /* the setting ('sl2i'); in_safety_us is larger while it has fallen back */
    uint32_t early_read;            /* 0 = not judged yet on this connection, 1 = working, 2 = not working */
    uint32_t hub_depth;             /* USB hubs between the box and the Mac: 0 = connected directly */
    uint64_t in_dropouts;           /* IO cycles since the box connected in which input wasn't captured in time */
} SL2StatusPacket;
