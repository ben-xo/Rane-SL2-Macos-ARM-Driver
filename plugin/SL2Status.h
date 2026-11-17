/*
 * SL2Status.h — the driver's status packet ('sl2s'): the one definition, used by the driver
 * (plugin/SL2Device.m), SL2Api, sl2panel and the control panel (a C struct, so Swift sees the same
 * layout the driver writes). New fields go at the end, so an older client reads a newer packet
 * (clients zero-fill a shorter one).
 */
#ifndef SL2_STATUS_H
#define SL2_STATUS_H
#include <stdint.h>

typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];       /* 1 = Phono, 0 = Line */
    uint8_t  thru[4];        /* 1 = Analog Thru, 0 = USB Audio */
    uint8_t  port_a;
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
    uint32_t boot_mode;      /* 1 = the box is in its USB bootloader; no audio until firmware is loaded */
    uint32_t debug_build;    /* 1 = this driver was built with SL2_DEBUG (make plugin DEBUG=1) */
    /* Input health (see "Early read" and the input safety offset) */
    uint32_t in_safety_us;          /* the input safety offset the HAL is using, in us */
    uint32_t early_read;            /* 0 = not judged yet on this connection, 1 = working, 2 = not working */
    uint32_t hub_depth;             /* USB hubs between the box and the Mac: 0 = connected directly */
    uint64_t in_dropouts;           /* IO cycles in which input wasn't captured in time, since the device was
                                       set up (the box connected, or the input safety offset changed) */
    uint32_t usb_link;              /* the box's USB link (0x0a): 2 = high speed, 1 = full speed (no audio),
                                       0 = not known */
} SL2StatusPacket;

#endif
