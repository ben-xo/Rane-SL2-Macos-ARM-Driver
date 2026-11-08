/*
 * SL2Device.m — Complete Self-Contained CoreAudio HAL Driver for Rane SL 2
 *
 * Drives the Rane SL 2 USB 2.0 DJ audio interface directly from inside the
 * CoreAudio HAL plugin (coreaudiod) using Apple's modern IOUSBHost framework.
 * No external daemon, no kernel extension, no root helper required.
 *
 * Capabilities:
 *   - 4-channel 24-bit (32-bit container) / 44.1 & 48 kHz Isochronous USB Audio
 *   - Implicit-feedback packet pacing from Capture to Playback
 *   - Automatic USB Audio / Analog Thru switching on StartIO / StopIO (HID 0x41)
 *   - 0x37 challenge heartbeat every 100 ms while streaming: the SL 2 only passes
 *     USB audio to its outputs while the host keeps this traffic going
 *   - Full HID Command/Response + Unsolicited Report Queue ('sl2h', 'sl2s', 'sl2q')
 *     for Serato DJ Pro (SL2Api.framework) and Control Panel
 *   - Automatic USB Hotplug detection (plug / unplug at any time)
 *   - Bootloader detection: a box whose EEPROM firmware is missing/corrupt enumerates in the
 *     USB bootloader (bcdDevice 0x0000, "Unnamed Device") and passes no audio. The driver
 *     detects this and reports it — in the log and via a boot_mode flag in the 'sl2s' status —
 *     so a client can tell the box needs its firmware restored.
 */

#import <Foundation/Foundation.h>
#import <CoreAudio/AudioServerPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <os/log.h>
#include <stdatomic.h>
#include <math.h>

#define VID          0x1cc5
#define PID          0x0013
#define BCD_LOADER   0x0000  /* USB bootloader: EEPROM has no bootable firmware ("Unnamed Device") */
#define BCD_AUDIO    0x0100  /* running firmware: the 4-interface audio device */
#define IF_PLAY      1
#define IF_CAP       2
#define IF_HID       3
#define EP_PLAY      0x06    /* IF1 alt1: isochronous OUT, asynchronous, bInterval 1 */
#define EP_CAP       0x82    /* IF2 alt1: isochronous IN, implicit feedback, bInterval 1 */
#define EP_HID_OUT   0x01
#define EP_HID_IN    0x81

#define NCH          4
#define FRAME_BYTES  16      /* 4 ch * 4 bytes (24-bit left-justified in 32-bit int) */
#define PKT_MAX      112     /* wMaxPacketSize of EP 0x06/0x82: 7 frames * 16 bytes per microframe */
#define HEARTBEAT_MS 100
#define CAP_PKTS     8       /* 1 ms per transfer */
#define CAP_NXF      64
#define PLAY_PKTS    8       /* 1 ms per transfer */
#define RING_FRAMES  65536   /* ~1.36s @ 48kHz */
#define RING_MASK    (RING_FRAMES - 1)

/* Custom CoreAudio Property Selectors */
#define kSL2PropHIDCommand  'sl2h'   /* CFDataRef (64B cmd in -> 64B reply out) */
#define kSL2PropStatus      'sl2s'   /* CFDataRef (SL2StatusPacket out) */
#define kSL2PropUnsolQueue  'sl2q'   /* CFDataRef (pop queued 64B unsolicited HID reports) */

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
} SL2StatusPacket;

enum {
    kObjPlugIn    = kAudioObjectPlugInObject,
    kObjDevice    = 2,
    kObjStreamIn  = 3,
    kObjStreamOut = 4,
};

static os_log_t g_log;
#define LOG(fmt, ...) os_log(g_log, "[SL2] " fmt, ##__VA_ARGS__)

/* Debug build (make plugin DEBUG=1): streaming diagnostics (counters, timing histograms, periodic
   "DBG" log lines) and the 'sl2h' debug command 0xF2 (intercepted, never sent to the box).
   A release build compiles none of it. */
#ifndef SL2_DEBUG
#define SL2_DEBUG 0
#endif
#if SL2_DEBUG
#define DBG_LOG(fmt, ...) LOG(fmt, ##__VA_ARGS__)
#define DBG_DO(stmt)      do { stmt; } while (0)
#else
#define DBG_LOG(fmt, ...) do { } while (0)
#define DBG_DO(stmt)      do { } while (0)
#endif

static AudioServerPlugInHostRef g_host = NULL;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_hid_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_hout_mtx = PTHREAD_MUTEX_INITIALIZER;   /* writes to the HID OUT pipe */
static pthread_mutex_t g_unsol_mtx = PTHREAD_MUTEX_INITIALIZER;

static Float64  g_sr = 44100.0;
static UInt32   g_io_clients = 0;
static _Atomic bool g_io_running = false;
static _Atomic bool g_hw_connected = false;
static _Atomic bool g_boot_mode = false;     /* a bootloader-mode box (no firmware) is attached */
static uint32_t g_ref_count = 0;

/* Capture ring buffer (Float32 interleaved, NCH channels), indexed by timeline position */
static float g_in_ring[RING_FRAMES * NCH];

/* The HAL's timeline (GetZeroTimeStamp), as a line: sample g_clk_sample at host time g_clk_host,
   advancing one sample every g_clk_tpf host ticks. It starts at sample 0 when streaming starts and
   must never jump (the HAL resets its clock if its timestamps fall off the line), but it must
   follow the box's own clock, or playback, which runs at the box's rate, drifts against it.
   So every CLK_FIX_FRAMES captured frames, clk_track re-anchors the line where it is (keeping it
   continuous) and sets its rate to the box's measured rate plus a correction that pulls the line
   onto the box's actual frame count over CLK_CORR_S seconds. g_q writes it; GetZeroTimeStamp
   (the HAL's IO thread) reads it, so it is published under a sequence lock.

   Capture begins some milliseconds after the timeline starts: the first captured frame sits at
   the timeline position matching its arrival (g_cap_base), and the box's rate is measured from
   that frame's time (g_rate_anchor). These and g_clk_last_fix are touched only on g_q. */
#define CLK_FIX_FRAMES 2048
#define CLK_CORR_S     2.0
static mach_timebase_info_data_t g_tb;
static _Atomic uint32_t g_clk_seq = 0;
static uint64_t g_clk_host = 0;
static double   g_clk_sample = 0;
static double   g_clk_tpf = 0;
static uint64_t g_rate_anchor = 0;
static uint64_t g_cap_base = 0;
static uint64_t g_clk_last_fix = 0;  /* captured-frame count at the last clk_track correction */

static _Atomic int g_in_safety_ms = 8;    /* DEBUG: settable via 'sl2h' 0xF2 (the HAL only reads it at device setup) */
static UInt32 in_safety_frames(void) {
    return (UInt32)(atomic_load(&g_in_safety_ms) * g_sr / 1000.0 + 0.5);
}
/* Output timing, reported to the HAL (see "Deep-schedule playback" below): every sample plays
   DP_OUT_LATENCY_MS after its timeline position, and the HAL writes DP_OUT_SAFETY_MS ahead. */
#define DP_OUT_SAFETY_MS  2.0
#define DP_OUT_LATENCY_MS 1.5
static UInt32 out_safety_frames(void) {
    return (UInt32)(DP_OUT_SAFETY_MS * g_sr / 1000.0 + 0.5);
}
static UInt32 out_latency_frames(void) {
    return (UInt32)(DP_OUT_LATENCY_MS * g_sr / 1000.0 + 0.5);
}
static _Atomic uint64_t g_total_cap_frames = 0;
static _Atomic uint64_t g_total_play_frames = 0;
static _Atomic uint64_t g_zts_seed = 1;     /* GetZeroTimeStamp seed: bumped when the timeline changes */

static double nominal_tpf(void) {
    return ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
}

/* Read the timeline consistently. Bounded, because the HAL's IO thread reads it: if the writer is
   preempted mid-update, after 64 tries use this thread's last good copy rather than spin. */
static void clk_get(uint64_t *host, double *sample, double *tpf) {
    static __thread uint64_t last_h;
    static __thread double last_s, last_tpf;
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = atomic_load_explicit(&g_clk_seq, memory_order_acquire);
        uint64_t h = g_clk_host; double s = g_clk_sample, t = g_clk_tpf;
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&g_clk_seq, memory_order_relaxed);
        if (!(s1 & 1) && s1 == s2) {
            last_h = *host = h; last_s = *sample = s; last_tpf = *tpf = t;
            return;
        }
    }
    *host = last_h; *sample = last_s;
    *tpf = last_tpf > 0 ? last_tpf : nominal_tpf();
}

static void clk_set(uint64_t host, double sample, double tpf) {
    atomic_fetch_add_explicit(&g_clk_seq, 1, memory_order_acq_rel);   /* odd: update in progress */
    atomic_thread_fence(memory_order_release);
    g_clk_host = host; g_clk_sample = sample; g_clk_tpf = tpf;
    atomic_fetch_add_explicit(&g_clk_seq, 1, memory_order_release);   /* even: consistent again */
}

/* Start a new timeline: sample 0 is now, at the nominal rate. */
static void clk_reset(void) {
    clk_set(mach_absolute_time(), 0, nominal_tpf());
}

/* Timeline position (in samples) at host time t. */
static double clk_sample_at(uint64_t t) {
    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    return s + ((double)t - (double)h) / tpf;
}

/* IOUSBHost state */
static dispatch_queue_t    g_q;
static uint32_t dbg_capdelay_hist[24];      /* capture handler time - bus start of its frame: 0.5 ms bins from -2 ms */
static double   dbg_capdelay_min, dbg_capdelay_max, dbg_capstamp_min, dbg_capstamp_max;
static IOUSBHostDevice    *g_dev;
static IOUSBHostInterface *g_play, *g_cap, *g_hid;
static IOUSBHostPipe      *g_ppipe, *g_cpipe, *g_hpipe_in, *g_hpipe_out;

/* Isoch transfer pools */
typedef struct {
    NSMutableData *buf;
    IOUSBHostIsochronousTransaction *tx;
} IsoXfer;
static IsoXfer g_cap_xf[CAP_NXF];
static uint64_t g_cap_xf_frame[CAP_NXF];   /* USB frame each capture transfer was scheduled for */
static uint64_t g_cap_frame = 0;

/* HID state */
static NSMutableData *g_hbuf_in;
static _Atomic uint32_t g_seq = 1;   /* bumped by hid_cmd (any thread) and the heartbeat (g_q) */
static dispatch_semaphore_t g_hid_sem;
static uint8_t  g_wait_cmd = 0;
static uint32_t g_wait_seq = 0;
static uint8_t  g_reply_buf[64];
static uint8_t  g_last_cmd_in[64];
static SL2StatusPacket g_st;

/* 0x37 heartbeat (8 random challenge bytes, the box answers with 8 derived bytes) */
static dispatch_source_t g_hb_timer;
static uint32_t g_hb_seq;

/* Unsolicited HID packet ring buffer for SL2Api callbacks */
#define UNSOL_Q_MAX 64
static uint8_t  g_unsol_q[UNSOL_Q_MAX][64];
static uint32_t g_unsol_w = 0;
static uint32_t g_unsol_r = 0;

/* IOKit Hotplug watcher */
static IONotificationPortRef g_notify_port = NULL;
static io_iterator_t g_added_iter = 0;
static io_iterator_t g_removed_iter = 0;

static void unsol_push(const uint8_t pkt[64]) {
    pthread_mutex_lock(&g_unsol_mtx);
    if (g_unsol_w - g_unsol_r < UNSOL_Q_MAX) {
        memcpy(g_unsol_q[g_unsol_w % UNSOL_Q_MAX], pkt, 64);
        g_unsol_w++;
    }
    pthread_mutex_unlock(&g_unsol_mtx);
}

static void push_sr_unsol(int sr) {
    uint8_t pkt[64] = {0};
    pkt[0] = 0x49;
    pkt[5] = (uint8_t)((sr >> 16) & 0xFF);
    pkt[6] = (uint8_t)((sr >> 8) & 0xFF);
    pkt[7] = (uint8_t)(sr & 0xFF);
    unsol_push(pkt);
}

/* ============================================================================
 * USB & HID Engine
 * ============================================================================ */

static void hb_read(void) {
    if (!g_hpipe_in || !g_hbuf_in) return;
    [g_hpipe_in enqueueIORequestWithData:g_hbuf_in completionTimeout:0 error:nil completionHandler:^(IOReturn s, NSUInteger n) {
        if (s == kIOReturnSuccess && n > 0) {
            const uint8_t *b = g_hbuf_in.bytes;
            uint32_t rseq = 0;
            memcpy(&rseq, b + 1, 4);
            if (g_wait_cmd && b[0] == g_wait_cmd && (g_wait_seq == 0 || rseq == g_wait_seq)) {
                memcpy(g_reply_buf, b, 64);
                g_wait_cmd = 0;
                dispatch_semaphore_signal(g_hid_sem);
            } else if (b[0] == 0x37 && rseq == g_hb_seq) {
                /* reply to our own heartbeat: not a notification for clients */
            } else {
                /* Unsolicited notification from SL2 hardware */
                if (b[0] == 0x40) {
                    uint8_t len = b[5];
                    if (len > 58) len = 58;
                    for (uint8_t i = 0; i + 2 < len; i += 3) {
                        uint8_t st = b[6 + i];
                        uint8_t note = b[6 + i + 1];
                        uint8_t vel = b[6 + i + 2];
                        int on = ((st & 0xF0) == 0x90) ? 1 : 0;
                        if (note >= 0x5C && note <= 0x5D) {
                            g_st.thru[note - 0x5C] = on;
                        } else if (note == 0x61 && vel < 4) {
                            g_st.phono[vel] = on;
                        }
                    }
                } else if (b[0] == 0x45) {
                    g_st.port_a = b[5];
                    g_st.port_b = b[6];
                }
                unsol_push(b);
            }
        }
        if (s != kIOReturnAborted && g_hpipe_in) hb_read();
    }];
}

static bool hid_cmd(uint8_t cmd, const uint8_t *pl, size_t plen, uint8_t *reply_out, uint32_t *seq_override) {
    if (!g_hpipe_out || !g_hid_sem) return false;
    pthread_mutex_lock(&g_hid_mtx);
    while (dispatch_semaphore_wait(g_hid_sem, DISPATCH_TIME_NOW) == 0) {}

    uint8_t buf[64] = {0};
    buf[0] = cmd;
    uint32_t seq = seq_override ? *seq_override : g_seq++;
    memcpy(buf + 1, &seq, 4);
    if (pl && plen > 0 && plen <= 59) memcpy(buf + 5, pl, plen);

    g_wait_cmd = (cmd >= 0x40) ? 0 : cmd;
    g_wait_seq = seq;

    NSMutableData *d = [NSMutableData dataWithBytes:buf length:64];
    NSUInteger sent = 0;
    NSError *e = nil;
    pthread_mutex_lock(&g_hout_mtx);
    [g_hpipe_out sendIORequestWithData:d bytesTransferred:&sent completionTimeout:0 error:&e];
    pthread_mutex_unlock(&g_hout_mtx);

    bool ok = true;
    if (g_wait_cmd != 0) {
        if (dispatch_semaphore_wait(g_hid_sem, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC)) == 0) {
            if (reply_out) memcpy(reply_out, g_reply_buf, 64);
        } else {
            g_wait_cmd = 0;
            ok = false;
        }
    } else if (reply_out) {
        memset(reply_out, 0, 64);
        reply_out[0] = cmd;
        memcpy(reply_out + 1, &seq, 4);
    }
    pthread_mutex_unlock(&g_hid_mtx);
    return ok;
}

static void refresh_hw_status(void) {
    /* Firmware version via HID command 0x01, as Rane's SL2Api reads it
       (SendHidRequest(dev, 0x01, ...) -> reply[5]=major, reply[6]=minor, 32-bit build stamp at
       reply[7..10]); c.f. the SL3, which uses 0x10. bcdDevice is only a mode marker
       (0x0100 = running firmware, 0x0000 = bootloader), not the version. */
    uint8_t r[64];
    if (hid_cmd(0x01, NULL, 0, r, NULL)) {
        g_st.version_maj = r[5];
        g_st.version_min = r[6];
    }
    /* Serial from the USB iSerialNumber string ("SL2.01.00"), a fixed device serial independent
       of the firmware version; c.f. the SL3, which queries it over HID 0x04. */
    CFTypeRef ser = IORegistryEntryCreateCFProperty(g_dev.ioService, CFSTR("USB Serial Number"), kCFAllocatorDefault, 0);
    if (ser) {
        if (CFGetTypeID(ser) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)ser, (char *)g_st.serial, sizeof g_st.serial, kCFStringEncodingUTF8);
        CFRelease(ser);
    }
    uint8_t req_ports[1] = {0};
    if (hid_cmd(0x45, req_ports, 1, r, NULL)) {   /* 0x45 = port status */
        g_st.port_a = r[5];
        g_st.port_b = r[6];
    }
}

static void send_hw_samplerate(int sr) {
    uint8_t pl[2] = { (uint8_t)((sr >> 8) & 0xFF), (uint8_t)(sr & 0xFF) };
    hid_cmd(0x31, pl, 2, NULL, NULL);
    push_sr_unsol(sr);
}

static void set_usb_switches(bool usb_mode) {
    /* SL2 uses Hidi Note Off (0x80 = USB Audio / Thru Off) and Note On (0x90 = Analog Thru On)
       via HID command 0x41 on notes 0x5C (Deck 1) and 0x5D (Deck 2) */
    uint8_t status_byte = usb_mode ? 0x80 : 0x90;
    for (int i = 0; i < 2; i++) {
        uint8_t pl[4] = { 0x03, status_byte, (uint8_t)(0x5C + i), 0x00 };
        hid_cmd(0x41, pl, 4, NULL, NULL);
        g_st.thru[i] = usb_mode ? 0 : 1;
        /* Also push unsolicited 0x40 so Control Panel updates immediately */
        uint8_t notify[64] = {0};
        notify[0] = 0x40;
        notify[5] = 0x03;
        notify[6] = status_byte | 0x01;
        notify[7] = (uint8_t)(0x5C + i);
        notify[8] = 0x00;
        unsol_push(notify);
    }
}

/* Heartbeat. Like the SL 3, the SL 2 answers command 0x37 (8 challenge bytes -> 8 derived
   bytes) and keeps its decks on USB audio only while this traffic flows; without it the
   outputs stay silent even with the thru switches off. Rane's SL2_driver_timer did this.
   Runs on g_q every HEARTBEAT_MS while streaming. */
static void hb_tick(void) {
    if (!atomic_load(&g_io_running) || !g_hpipe_out) return;
    uint8_t buf[64] = {0};
    buf[0] = 0x37;
    g_hb_seq = g_seq++;
    memcpy(buf + 1, &g_hb_seq, 4);
    arc4random_buf(buf + 5, 8);
    NSMutableData *d = [NSMutableData dataWithBytes:buf length:64];
    pthread_mutex_lock(&g_hout_mtx);
    [g_hpipe_out enqueueIORequestWithData:d completionTimeout:0 error:nil completionHandler:^(IOReturn s, NSUInteger n) { (void)s; (void)n; }];
    pthread_mutex_unlock(&g_hout_mtx);
}

static void hb_start(void) {
    if (g_hb_timer || !g_q) return;
    g_hb_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
    dispatch_source_set_timer(g_hb_timer, dispatch_time(DISPATCH_TIME_NOW, 0), HEARTBEAT_MS * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_hb_timer, ^{ hb_tick(); });
    dispatch_resume(g_hb_timer);
}

static void hb_stop(void) {
    if (!g_hb_timer) return;
    dispatch_source_cancel(g_hb_timer);
    g_hb_timer = nil;
}

static IOUSBHostPipe *copy_isoch_pipe(IOUSBHostInterface *intf, uint8_t dir, uint8_t fallback1, uint8_t fallback2) {
    const IOUSBConfigurationDescriptor *cfg = intf.configurationDescriptor;
    const IOUSBInterfaceDescriptor *ifd = intf.interfaceDescriptor;
    if (cfg && ifd) {
        const IOUSBEndpointDescriptor *ep = NULL;
        while ((ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep)) != NULL) {
            if (IOUSBGetEndpointDirection(ep) == dir && IOUSBGetEndpointType(ep) == kIOUSBEndpointTypeIsochronous) {
                NSError *e = nil;
                IOUSBHostPipe *p = [intf copyPipeWithAddress:ep->bEndpointAddress error:&e];
                if (p) return p;
            }
        }
    }
    NSError *e = nil;
    IOUSBHostPipe *p = [intf copyPipeWithAddress:fallback1 error:&e];
    if (p) return p;
    return [intf copyPipeWithAddress:fallback2 error:&e];
}

/* ============================================================================
 * Isochronous Audio Streaming (Capture + Implicit-Feedback Playback)
 * ============================================================================ */

/* First capture of a stream: note when it arrived, and where on the HAL's timeline it belongs. */
static void clk_first_capture(uint64_t hw_time) {
    uint64_t now = (hw_time > 0) ? hw_time : mach_absolute_time();
    double pos = clk_sample_at(now);
    g_rate_anchor = now;
    g_cap_base = pos > 0 ? (uint64_t)pos : 0;
    g_clk_last_fix = 0;
}

/* A capture transfer delivered `frames` frames, the first of which (captured-frame number
   count_before) arrived at host time ts. Keep the timeline on the box's clock (see g_clk_*). */
static void clk_track(uint64_t count_before, int frames, uint64_t ts) {
    atomic_fetch_add_explicit(&g_total_cap_frames, frames, memory_order_relaxed);
    if (!frames || !ts || count_before - g_clk_last_fix < CLK_FIX_FRAMES) return;
    g_clk_last_fix = count_before;

    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    if (ts <= h) return;
    double here = s + (double)(ts - h) / tpf;                     /* timeline position at ts */
    double err  = (double)(g_cap_base + count_before) - here;     /* > 0: timeline behind the box */

    double nom_rate = 1.0 / nominal_tpf();                         /* frames per host tick */
    double elapsed  = (double)(ts - g_rate_anchor);
    double rate = (count_before >= 8 * CLK_FIX_FRAMES && elapsed > 0) ? (double)count_before / elapsed : nom_rate;
    double ticks_per_s = 1e9 * (double)g_tb.denom / (double)g_tb.numer;
    rate += err / (CLK_CORR_S * ticks_per_s);
    if (rate > nom_rate * 1.005) rate = nom_rate * 1.005;
    if (rate < nom_rate * 0.995) rate = nom_rate * 0.995;
    clk_set(ts, here, 1.0 / rate);

#if SL2_DEBUG
    static uint32_t dbg_n;
    if (++dbg_n % 40 == 0)
        DBG_LOG("DBG clk: phase error %.1f frames (%.3f ms), rate %.1f ppm vs nominal",
            err, 1000.0 * err / g_sr, (rate / nom_rate - 1.0) * 1e6);
#endif
}

/* DEBUG: capture packets with an error status, per stream */
static uint32_t dbg_cap_pkt_err;



/* ============================================================================
 * Deep-schedule playback
 *
 * USB completions can be delivered 5-30 ms late (the delay is in the USB stack, before any
 * thread is woken, so no thread priority fixes it). So rather than filling each playback
 * transfer when an earlier one completes, DP_SLOTS 1 ms transfers are kept queued ahead,
 * zero-filled, and the HAL's IO thread (WriteMix) writes each sample straight into the queued
 * transfer that will carry it, shortly before that transfer starts. This works because the
 * controller reads a transfer's buffer when the transfer starts: audio written into a queued
 * ioDataWithCapacity: buffer before then is what gets sent. Completions only recycle transfers
 * at the far end of the schedule, so a stall shorter than the schedule costs nothing.
 *
 * Each queued USB frame carries a contiguous run of HAL timeline positions, published in
 * g_dp_sched (indexed by frame number) for the IO thread to look up. When the schedule is
 * anchored (dp_anchor), its first frame carries the position DP_OUT_LATENCY_MS before that
 * frame's start time; because the packet sizes follow the box's clock, every sample then plays
 * DP_OUT_LATENCY_MS after its timeline position. The HAL writes each sample DP_OUT_SAFETY_MS
 * ahead of "now"; together they cover the up-to-1 ms between a sample's position and its frame's
 * start plus DP_WRITE_GUARD, with the rest as margin for a late IO thread.
 *
 * Packet sizes are fixed when a transfer is queued, ~DP_SLOTS ms before it plays, so they cannot
 * be copied from the matching capture packets (implicit feedback). They are predicted from the
 * box's measured rate and steered (dp_track_capture) so that the frames sent through each USB
 * frame track the frames the box captured through it. A frame whose enqueue is refused is not
 * sent: its positions move to the next frame (the audio stays continuous) and it does not count
 * as sent, so the steering makes up the frames the box missed.
 * ============================================================================ */
#define DP_SLOTS       128         /* transfers kept queued: 128 ms (the HAL writes up to ~2 IO buffers ahead) */
#define DP_SCHED_N     512         /* schedule ring entries: power of two, >= 2 x (DP_SLOTS + HAL lead) */
#define DP_START_LEAD  8           /* (re)anchor this many frames ahead of the bus (+4 was refused) */
#define DP_DRY_LEAD    4           /* the schedule counts as run dry when it reaches less than this far ahead */
#define DP_CORR_S      1.0         /* sent-vs-captured frame difference is removed over this many seconds */
#define DP_WRITE_GUARD 1.0         /* a frame is written only if it starts at least this many ms from now */
#define DP_TRIES       4           /* enqueue attempts per call before retrying the slot later */

typedef struct {
    _Atomic uint64_t frame;        /* USB frame this entry describes, 0 = none (seqlock tag) */
    uint64_t first;                /* timeline position of the frame's first sample */
    uint64_t sent_cum;             /* frames queued from the anchor through this frame */
    uint16_t off[PLAY_PKTS + 1];   /* sample offset of each packet in the frame; [PLAY_PKTS] = total */
    uint8_t *buf;                  /* the frame's transfer buffer */
} DPEntry;

static DPEntry        g_dp_sched[DP_SCHED_N];
static NSMutableData *g_dp_data[DP_SLOTS];
static uint8_t       *g_dp_ptr[DP_SLOTS];
static IOUSBHostIsochronousTransaction g_dp_tx[DP_SLOTS][PLAY_PKTS];
static _Atomic bool     g_dp_active;          /* WriteMix writes into the schedule */
static _Atomic int      g_dp_writers;         /* WriteMix calls currently inside dp_write */
static _Atomic uint64_t g_dp_x0, g_dp_F0;     /* current anchor: first position / frame */
static _Atomic uint64_t g_dp_newest;          /* newest published frame: where WriteMix starts looking */
static bool     g_dp_stream, g_dp_started;    /* g_q only from here down */
static uint64_t g_dp_next_frame, g_dp_next_pos, g_dp_sent_cum, g_dp_in_cum, g_dp_last_refresh;
static double   g_dp_acc, g_dp_err;
/* USB frame clock: microframe g_dp_ref_uframe is associated with host time g_dp_ref_time (seqlock) */
static _Atomic uint32_t g_dp_ref_seq;
static uint64_t g_dp_ref_uframe, g_dp_ref_time;
/* DEBUG counters */
static _Atomic uint32_t dp_late, dp_unscheduled, dp_written;
/* DEBUG: does the HAL call WriteMix once per IO cycle with every client mixed, or once per client
   IO context? Thread switches, concurrent calls, and samples written to positions already written. */
static _Atomic uint32_t dbg_wm_thread_switches, dbg_wm_concurrent, dbg_wm_rewritten;
static _Atomic uint64_t dbg_wm_last_thread, dbg_wm_high;
static uint32_t dp_enq_fail, dp_resync, dp_retry_later, dp_dbg_n;
static double   dp_err_max;

static double ticks_per_ms(void) {
    return 1e6 * (double)g_tb.denom / (double)g_tb.numer;
}

static void dp_ref_refresh(void) {
    IOUSBHostTime t = 0;
    NSError *e = nil;
    uint64_t uf = [g_dev currentMicroframeWithTime:&t error:&e];
    if (!uf || !t) return;
    uint32_t s = atomic_load_explicit(&g_dp_ref_seq, memory_order_relaxed);
    atomic_store_explicit(&g_dp_ref_seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    g_dp_ref_uframe = uf; g_dp_ref_time = t;
    atomic_store_explicit(&g_dp_ref_seq, s + 2, memory_order_release);
    g_dp_last_refresh = mach_absolute_time();
}

/* The microframe reference, consistently. Bounded so the IO thread never spins on a preempted
   writer: after 64 tries it uses this thread's last good copy. */
static void dp_ref_get(uint64_t *uf, uint64_t *ut) {
    static __thread uint64_t last_uf, last_ut;
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = atomic_load_explicit(&g_dp_ref_seq, memory_order_acquire);
        uint64_t a = g_dp_ref_uframe, b = g_dp_ref_time;
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&g_dp_ref_seq, memory_order_relaxed);
        if (!(s1 & 1) && s1 == s2) { last_uf = *uf = a; last_ut = *ut = b; return; }
    }
    *uf = last_uf; *ut = last_ut;
}

/* USB frame (1 ms, fractional) at host time t. Safe on any thread. */
static double dp_frame_at(uint64_t t) {
    uint64_t uf, ut;
    dp_ref_get(&uf, &ut);
    return ((double)uf + ((double)t - (double)ut) / (ticks_per_ms() / 8.0)) / 8.0;
}

/* Host time at which (fractional) microframe uframe starts on the bus. */
static uint64_t dp_time_of_uframe(double uframe) {
    uint64_t uf, ut;
    dp_ref_get(&uf, &ut);
    return (uint64_t)((double)ut + (uframe - (double)uf) * (ticks_per_ms() / 8.0));
}

/* Frames in the next OUT packet: the box's measured rate, steered by dp_track_capture. */
static int dp_packet_frames(void) {
    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    double rate = (ticks_per_ms() / 8.0) / tpf;   /* frames per 125 us microframe */
    rate -= g_dp_err / (8000.0 * DP_CORR_S);
    g_dp_acc += rate;
    int n = (int)g_dp_acc;
    g_dp_acc -= n;
    if (n < 4) n = 4;
    if (n > PKT_MAX / FRAME_BYTES) n = PKT_MAX / FRAME_BYTES;
    return n;
}

/* (Re)start the schedule at frame F: it carries the timeline position DP_OUT_LATENCY_MS before
   F's start time, and the sent-vs-captured count starts again from F. */
static void dp_anchor(uint64_t F) {
    double x0 = clk_sample_at(dp_time_of_uframe(8.0 * (double)F)) - DP_OUT_LATENCY_MS * g_sr / 1000.0;
    g_dp_next_frame = F;
    g_dp_next_pos = x0 > 0 ? (uint64_t)x0 : 0;
    g_dp_sent_cum = 0; g_dp_in_cum = 0; g_dp_err = 0; g_dp_acc = 0;
    atomic_store(&g_dp_x0, g_dp_next_pos);
    atomic_store(&g_dp_F0, F);
}

static bool dp_gone(IOReturn st) {
    return st == kIOReturnNoDevice || st == kIOReturnNotAttached || st == kIOReturnNotResponding ||
           st == kIOReturnOffline;
}

/* Queue `slot` for the next frame of the schedule, zero-filled, and publish where its samples go. */
static void dp_submit(int slot) {
    for (int attempt = 0; attempt < DP_TRIES; attempt++) {
        if (!atomic_load(&g_io_running) || !g_ppipe || !g_dp_ptr[slot]) return;
        if ((double)(mach_absolute_time() - g_dp_last_refresh) > 0.5 * ticks_per_ms()) dp_ref_refresh();
        uint64_t now_f = (uint64_t)dp_frame_at(mach_absolute_time());
        if (g_dp_next_frame < now_f + DP_DRY_LEAD) {
            /* The schedule ran dry: a stall longer than DP_SLOTS ms. Re-anchor ahead of the bus. */
            dp_anchor(now_f + DP_START_LEAD);
            DBG_DO(dp_resync++);
        }
        uint64_t f = g_dp_next_frame++;
        DPEntry *e = &g_dp_sched[f & (DP_SCHED_N - 1)];
        /* unpublish while it is rewritten (seqlock writer) */
        atomic_store_explicit(&e->frame, 0, memory_order_relaxed);
        atomic_thread_fence(memory_order_release);
        uint16_t off = 0;
        for (int k = 0; k < PLAY_PKTS; k++) {
            int n = dp_packet_frames();
            e->off[k] = off;
            g_dp_tx[slot][k] = (IOUSBHostIsochronousTransaction){
                .requestCount = (uint32_t)(n * FRAME_BYTES), .offset = (uint32_t)(k * PKT_MAX) };
            off += n;
        }
        e->off[PLAY_PKTS] = off;
        e->first = g_dp_next_pos;
        e->buf = g_dp_ptr[slot];
        memset(g_dp_ptr[slot], 0, PLAY_PKTS * PKT_MAX);

        NSError *err = nil;
        BOOL ok = [g_ppipe enqueueIORequestWithData:g_dp_data[slot] transactionList:g_dp_tx[slot]
                               transactionListCount:PLAY_PKTS firstFrameNumber:f
                                            options:IOUSBHostIsochronousTransferOptionsNone error:&err
                                  completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
            if (atomic_load(&g_io_running) && st != kIOReturnAborted && !dp_gone(st)) dp_submit(slot);
        }];
        if (ok) {
            g_dp_next_pos += off;
            g_dp_sent_cum += off;
            e->sent_cum = g_dp_sent_cum;
            atomic_store_explicit(&e->frame, f, memory_order_release);   /* publish */
            atomic_store_explicit(&g_dp_newest, f, memory_order_release);
            return;
        }
        /* Refused: nothing is published, and the next frame carries these positions instead. */
        DBG_DO(dp_enq_fail++);
        DBG_LOG("DBG dp enqueue refused for frame %llu (now ~%llu): %{public}@", f, now_f, err.localizedDescription);
    }
    /* Still refused: try this slot again shortly rather than losing it from the schedule. */
    DBG_DO(dp_retry_later++);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC), g_q, ^{ dp_submit(slot); });
}

/* Allocate the transfer buffers (from the playback interface; dp_release frees them). */
static bool dp_alloc(void) {
    NSError *e = nil;
    for (int i = 0; i < DP_SLOTS; i++) {
        g_dp_data[i] = [g_play ioDataWithCapacity:PLAY_PKTS * PKT_MAX error:&e];
        if (!g_dp_data[i]) { LOG("Deep-schedule playback: buffer allocation failed: %{public}@", e); return false; }
        g_dp_ptr[i] = g_dp_data[i].mutableBytes;
    }
    for (int i = 0; i < DP_SCHED_N; i++) atomic_store(&g_dp_sched[i].frame, 0);
    return true;
}

static void dp_start(void) {
    dp_ref_refresh();
#if SL2_DEBUG   /* check frameNumberWithTime: and the microframe reference agree */
    IOUSBHostTime t = 0;
    uint64_t fn = [g_dev frameNumberWithTime:&t];
    DBG_LOG("DBG frameNumber %llu vs microframe estimate %.2f", fn, dp_frame_at(t));
#endif
    dp_anchor((uint64_t)dp_frame_at(mach_absolute_time()) + DP_START_LEAD);
    atomic_store_explicit(&g_dp_active, true, memory_order_release);
    for (int i = 0; i < DP_SLOTS; i++) dp_submit(i);
    g_dp_started = true;
    LOG("Deep-schedule playback started at frame %llu, %d x 1 ms queued, output latency %.1f + safety %.1f ms",
        atomic_load(&g_dp_F0), DP_SLOTS, DP_OUT_LATENCY_MS, DP_OUT_SAFETY_MS);
}

/* A capture transfer for USB frame fc covered `frames` frames (errored packets counted at their
   expected size). Steer the predicted OUT sizes so that the frames sent through each USB frame
   track the frames the box captured through it. */
static void dp_track_capture(uint64_t fc, int frames) {
    if (!g_dp_started || fc < atomic_load(&g_dp_F0)) return;
    g_dp_in_cum += frames;
    DPEntry *e = &g_dp_sched[fc & (DP_SCHED_N - 1)];
    if (atomic_load_explicit(&e->frame, memory_order_acquire) != fc) return;   /* not sent */
    g_dp_err = (double)e->sent_cum - (double)g_dp_in_cum;
#if SL2_DEBUG   /* the deep schedule's health, every ~2 s */
    if (fabs(g_dp_err) > dp_err_max) dp_err_max = fabs(g_dp_err);
    if (++dp_dbg_n % 2000 == 0)
        DBG_LOG("DBG dp: sent-captured %.1f frames (max %.1f) | written %u, late %u, unscheduled %u | "
            "enqueue refused %u, retried later %u, resyncs %u | WriteMix thread switches %u, concurrent %u, "
            "rewritten samples %u | capture packet errors %u",
            g_dp_err, dp_err_max, atomic_load(&dp_written), atomic_load(&dp_late),
            atomic_load(&dp_unscheduled), dp_enq_fail, dp_retry_later, dp_resync,
            atomic_load(&dbg_wm_thread_switches), atomic_load(&dbg_wm_concurrent), atomic_load(&dbg_wm_rewritten),
            dbg_cap_pkt_err);
#endif
}

/* Read schedule entry for frame f consistently (seqlock reader). False if f is not published. */
static bool dp_entry_get(uint64_t f, uint64_t *first, uint16_t off[PLAY_PKTS + 1], uint8_t **buf) {
    DPEntry *c = &g_dp_sched[f & (DP_SCHED_N - 1)];
    if (atomic_load_explicit(&c->frame, memory_order_acquire) != f) return false;
    *first = c->first;
    memcpy(off, c->off, sizeof c->off);
    *buf = c->buf;
    atomic_thread_fence(memory_order_acquire);
    return atomic_load_explicit(&c->frame, memory_order_relaxed) == f;
}

/* WriteMix, on the HAL's IO thread: write the mix straight into the queued transfers. Lock-free;
   no IOKit calls. Samples whose frame starts too soon, or is not queued, are dropped. */
static void dp_write(const float *buf, UInt32 frames, uint64_t pos) {
    /* Where to start looking: the newest published frame. It is at most DP_SLOTS frames from any
       frame WriteMix can still write, so a nominal-rate estimate from it is off by well under a
       frame whatever the box's clock error, on every IO thread (the HAL can run more than one, for
       example when another app plays to the device). */
    uint64_t hint_frame = atomic_load_explicit(&g_dp_newest, memory_order_acquire), hint_first = 0;
    {
        uint16_t o[PLAY_PKTS + 1]; uint8_t *b;
        if (!hint_frame || !dp_entry_get(hint_frame, &hint_first, o, &b)) {
            hint_frame = atomic_load(&g_dp_F0); hint_first = atomic_load(&g_dp_x0);
        }
    }
    double now_f = dp_frame_at(mach_absolute_time());
    double per_frame = g_sr / 1000.0;
    UInt32 i = 0;
    while (i < frames) {
        uint64_t p = pos + i;
        int64_t fg = (int64_t)hint_frame + (int64_t)floor(((double)p - (double)hint_first) / per_frame);
        uint64_t first = 0;
        uint16_t off[PLAY_PKTS + 1];
        uint8_t *fbuf = NULL;
        bool found = false;
        for (int tries = 0; tries < 8 && fg > 0; tries++) {
            if (!dp_entry_get((uint64_t)fg, &first, off, &fbuf)) break;
            if (p < first) { fg--; continue; }
            if (p >= first + off[PLAY_PKTS]) { fg++; continue; }
            found = true;
            break;
        }
        if (!found) {
            /* Frame fg is not queued (refused, or beyond the schedule). Drop only up to the next
               queued frame's samples; if none is near, drop the rest of this buffer. */
            uint32_t skip = frames - i;
            for (int64_t g = fg + 1; g > 0 && g <= fg + 4; g++) {
                uint64_t f2; uint16_t o2[PLAY_PKTS + 1]; uint8_t *b2;
                if (dp_entry_get((uint64_t)g, &f2, o2, &b2) && f2 > p) {
                    if (f2 - p < skip) skip = (uint32_t)(f2 - p);
                    break;
                }
            }
            DBG_DO(atomic_fetch_add_explicit(&dp_unscheduled, skip, memory_order_relaxed));
            i += skip;
            continue;
        }
        hint_frame = (uint64_t)fg; hint_first = first;
        uint32_t n = (uint32_t)(first + off[PLAY_PKTS] - p);
        if (n > frames - i) n = frames - i;
        if ((double)fg - now_f < DP_WRITE_GUARD) {
            DBG_DO(atomic_fetch_add_explicit(&dp_late, n, memory_order_relaxed));
        } else {
            uint32_t j = (uint32_t)(p - first);
            int k = 0;
            for (uint32_t s = 0; s < n; s++, j++) {
                while (k < PLAY_PKTS - 1 && j >= off[k + 1]) k++;
                uint8_t *q = fbuf + k * PKT_MAX + (j - off[k]) * FRAME_BYTES;
                const float *src = buf + (size_t)(i + s) * NCH;
                for (int c = 0; c < NCH; c++) {
                    float v = src[c];
                    if (v > 1.0f) v = 1.0f;
                    else if (v < -1.0f) v = -1.0f;
                    int32_t raw = (int32_t)(v * 2147483392.0f);
                    memcpy(q + c * 4, &raw, 4);
                }
            }
            DBG_DO(atomic_fetch_add_explicit(&dp_written, n, memory_order_relaxed));
        }
        i += n;
    }
}

static void cap_submit(int idx) {
    if (!atomic_load(&g_io_running) || !g_cpipe) return;
    IsoXfer *xf = &g_cap_xf[idx];
    IOUSBHostIsochronousTransaction *tx = xf->tx;
    uint64_t f = g_cap_frame;
    g_cap_frame += CAP_PKTS / 8;
    g_cap_xf_frame[idx] = f;

    for (int k = 0; k < CAP_PKTS; k++) {
        tx[k] = (IOUSBHostIsochronousTransaction){
            .requestCount = PKT_MAX,
            .offset = (uint32_t)(k * PKT_MAX)
        };
    }

    NSError *e = nil;
    [g_cpipe enqueueIORequestWithData:xf->buf
                      transactionList:tx
                  transactionListCount:CAP_PKTS
                      firstFrameNumber:f
                               options:IOUSBHostIsochronousTransferOptionsNone
                                 error:&e
                     completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        if (!atomic_load(&g_io_running) || st == kIOReturnAborted) return;
        /* Times below are bus times, from the USB frame clock (dp_ref_*): a completion's own
           timeStamp is when the stack processed it, which can be many ms after the bus. */
        if ((double)(mach_absolute_time() - g_dp_last_refresh) > 0.5 * ticks_per_ms()) dp_ref_refresh();
        uint64_t fc = g_cap_xf_frame[idx];   /* USB frame this transfer covered */
#if SL2_DEBUG
        {   /* when this handler runs, and the stack's completion stamp, relative to the bus
               start of the transfer's frame (the transfer covers [0, 1) ms of it) */
            double start = (double)dp_time_of_uframe(8.0 * (double)fc);
            double ms = ((double)mach_absolute_time() - start) / ticks_per_ms();
            double stamp = done[CAP_PKTS - 1].timeStamp ? ((double)done[CAP_PKTS - 1].timeStamp - start) / ticks_per_ms() : 0;
            int bin = (int)floor((ms + 2.0) / 0.5);
            dbg_capdelay_hist[bin < 0 ? 0 : bin > 23 ? 23 : bin]++;
            if (ms < dbg_capdelay_min) dbg_capdelay_min = ms;
            if (ms > dbg_capdelay_max) dbg_capdelay_max = ms;
            if (stamp < dbg_capstamp_min) dbg_capstamp_min = stamp;
            if (stamp > dbg_capstamp_max) dbg_capstamp_max = stamp;
        }
#endif
        const uint8_t *b = xf->buf.bytes;
        uint64_t wp = atomic_load_explicit(&g_total_cap_frames, memory_order_relaxed);
        int got = 0;
        uint64_t ts = 0;

        if (wp == 0) {   /* nothing captured yet: place this transfer's first frame on the timeline */
            for (int k = 0; k < CAP_PKTS; k++) {
                if (done[k].status == kIOReturnSuccess && done[k].completeCount >= FRAME_BYTES &&
                    done[k].completeCount <= PKT_MAX) {
                    clk_first_capture(dp_time_of_uframe(8.0 * (double)fc + k));
                    break;
                }
            }
        }
        uint64_t ring_pos = g_cap_base + wp;   /* timeline position of this transfer's first frame */

        int errored = 0;
        static int last_n = 0;   /* size of the last good packet, for counting errored ones */
        if (!last_n) last_n = (int)(g_sr / 8000.0 + 0.5);
        for (int k = 0; k < CAP_PKTS; k++) {
            /* Drop errored packets and impossible lengths. The first completion after a
               killed helper can carry a residual from the old request (e.g. 0xFFFFFE00),
               and the frame loop must never run past the 112-byte packet. */
            if (done[k].status != kIOReturnSuccess || done[k].completeCount > PKT_MAX) {
                DBG_DO(dbg_cap_pkt_err++);
                errored++;
                continue;
            }
            int n = done[k].completeCount / FRAME_BYTES;
            if (n >= 4) {
                last_n = n;
            }
            if (n > 0) {
                if (!ts) ts = dp_time_of_uframe(8.0 * (double)fc + k);
                const uint8_t *p = b + k * PKT_MAX;
                for (int s = 0; s < n; s++) {
                    const uint8_t *q = p + s * FRAME_BYTES;
                    float *fr = &g_in_ring[((ring_pos + got) & RING_MASK) * NCH];
                    for (int c = 0; c < NCH; c++) {
                        int32_t raw32 = 0;
                        memcpy(&raw32, q + c * 4, 4);
                        int32_t s24 = raw32 >> 8;
                        fr[c] = (float)s24 * (1.0f / 8388608.0f);
                    }
                    got++;
                }
            }
        }
        clk_track(wp, got, ts);

        if (g_dp_stream) {   /* deep-schedule playback: start after a few ms of capture */
            if (!g_dp_started && wp >= (uint64_t)(8 * g_sr / 1000)) dp_start();
            /* the box clocked errored packets too: count them at the last good size */
            dp_track_capture(fc, got + errored * last_n);
        }
        cap_submit(idx);
    }];
}

/* ============================================================================
 * USB Open / Close Lifecycle
 * ============================================================================ */

/* bcdDevice of a USB device service, or -1 if unreadable: BCD_AUDIO (running firmware) vs
   BCD_LOADER (USB bootloader, no firmware). */
static int svc_bcd(io_service_t svc) {
    CFNumberRef n = IORegistryEntryCreateCFProperty(svc, CFSTR("bcdDevice"), kCFAllocatorDefault, 0);
    if (!n) return -1;
    int v = -1;
    CFNumberGetValue(n, kCFNumberIntType, &v);
    CFRelease(n);
    return v;
}

static io_service_t find_sl2_service(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return IO_OBJECT_NULL;
    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return IO_OBJECT_NULL;
    io_service_t s, found = IO_OBJECT_NULL;
    while ((s = IOIteratorNext(it))) {
        /* Only the running firmware (bcdDevice 0x0100) has the audio interfaces. A box in its
           bootloader must stay untouched so the standalone firmware tools can reach it. */
        if (!found && svc_bcd(s) == BCD_AUDIO) found = s;
        else IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}

/* The USB queue (g_q): completions for the HID and audio interfaces. A plain high-priority serial
   queue: its handlers can be delivered 5-30 ms late (the delay is in the USB stack, before any thread
   is woken), so the streaming design does not depend on them being prompt; see
   docs/SL2-AUDIO-ENGINE.md. */
static dispatch_queue_t usb_queue_create(void) {
    dispatch_queue_attr_t qa = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    return dispatch_queue_create("com.rane.sl2.usb", qa);
}

static bool usb_ensure_hid(void) {
    if (g_dev && g_hid && g_hpipe_in && g_hpipe_out) return true;
    io_service_t svc = find_sl2_service();
    if (!svc) return false;

    NSError *e = nil;
    if (!g_q) {
        g_q = usb_queue_create();
    }
    if (!g_hid_sem) g_hid_sem = dispatch_semaphore_create(0);

    g_dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
    IOObjectRelease(svc);
    if (!g_dev) { LOG("Failed to open IOUSBHostDevice: %{public}@", e); return false; }
    [g_dev configureWithValue:1 matchInterfaces:YES error:&e];

    io_iterator_t it = 0;
    IORegistryEntryGetChildIterator(g_dev.ioService, kIOServicePlane, &it);
    io_service_t ch;
    while ((ch = IOIteratorNext(it))) {
        CFNumberRef n = IORegistryEntryCreateCFProperty(ch, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
        if (n) {
            int idx = -1;
            CFNumberGetValue(n, kCFNumberIntType, &idx);
            CFRelease(n);
            if (idx == IF_HID) {
                g_hid = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
            }
        }
        IOObjectRelease(ch);
    }
    IOObjectRelease(it);

    if (g_hid) {
        g_hpipe_out = [g_hid copyPipeWithAddress:EP_HID_OUT error:&e];
        g_hpipe_in  = [g_hid copyPipeWithAddress:EP_HID_IN error:&e];
        g_hbuf_in   = [NSMutableData dataWithLength:64];
        hb_read();
        refresh_hw_status();
        atomic_store(&g_hw_connected, true);
        atomic_store(&g_boot_mode, false);
        return true;
    }
    return false;
}

static bool usb_open_all(void) {
    if (!usb_ensure_hid()) return false;
    NSError *e = nil;

    g_dp_stream = true;
    g_dp_started = false;
    atomic_store(&g_dp_active, false);
#if SL2_DEBUG
    memset(dbg_capdelay_hist, 0, sizeof dbg_capdelay_hist);
    dbg_capdelay_min = dbg_capstamp_min = 1e9; dbg_capdelay_max = dbg_capstamp_max = -1e9;
    dp_late = dp_unscheduled = dp_written = 0;
    dbg_wm_thread_switches = dbg_wm_concurrent = dbg_wm_rewritten = 0;
    dbg_wm_last_thread = dbg_wm_high = 0;
    dp_enq_fail = dp_resync = dp_retry_later = dp_dbg_n = 0; dp_err_max = 0;
    dbg_cap_pkt_err = 0;
#endif

    io_iterator_t it = 0;
    IORegistryEntryGetChildIterator(g_dev.ioService, kIOServicePlane, &it);
    io_service_t ch;
    while ((ch = IOIteratorNext(it))) {
        CFNumberRef n = IORegistryEntryCreateCFProperty(ch, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
        if (n) {
            int idx = -1;
            CFNumberGetValue(n, kCFNumberIntType, &idx);
            CFRelease(n);
            if (idx == IF_PLAY && !g_play) g_play = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
            if (idx == IF_CAP  && !g_cap)  g_cap  = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
        }
        IOObjectRelease(ch);
    }
    IOObjectRelease(it);

    if (!g_play || !g_cap) {
        LOG("Failed to claim Play/Cap interfaces");
        return false;
    }

    send_hw_samplerate((int)g_sr);

    [g_play selectAlternateSetting:1 error:&e];
    g_ppipe = copy_isoch_pipe(g_play, kIOUSBEndpointDirectionOut, EP_PLAY, 0x02);

    [g_cap selectAlternateSetting:1 error:&e];
    g_cpipe = copy_isoch_pipe(g_cap, kIOUSBEndpointDirectionIn, EP_CAP, 0x86);

    if (!g_ppipe || !g_cpipe) {
        LOG("Failed to open Isoch pipes");
        return false;
    }
    dp_ref_refresh();   /* USB frame clock, used for bus times from the first capture on */
    if (g_dp_stream && !dp_alloc()) g_dp_stream = false;

    for (int i = 0; i < CAP_NXF; i++) {
        if (!g_cap_xf[i].buf) g_cap_xf[i].buf = [NSMutableData dataWithLength:CAP_PKTS * PKT_MAX];
        if (!g_cap_xf[i].tx)  g_cap_xf[i].tx  = calloc(CAP_PKTS, sizeof(IOUSBHostIsochronousTransaction));
    }

    set_usb_switches(true);
    hb_start();

    memset(g_in_ring, 0, sizeof(g_in_ring));

    clk_reset();
    atomic_store(&g_total_cap_frames, 0);
    atomic_store(&g_total_play_frames, 0);

    atomic_store(&g_io_running, true);
    g_cap_frame = [g_dev frameNumberWithTime:NULL] + 32;
    for (int i = 0; i < CAP_NXF; i++) cap_submit(i);

    LOG("Streaming started on Rane SL 2 (%.0f Hz)", g_sr);
    return true;
}

/* Switch the deep schedule off and wait for any WriteMix still writing into it, after which its
   buffers can be released. */
static void dp_stop(void) {
    atomic_store_explicit(&g_dp_active, false, memory_order_seq_cst);
    while (atomic_load_explicit(&g_dp_writers, memory_order_seq_cst) > 0) usleep(50);
}

/* Release the deep schedule's transfer buffers. They hold the playback interface open, so they
   must go before the next stream claims it. Call after the pipes are aborted. */
static void dp_release(void) {
    for (int i = 0; i < DP_SLOTS; i++) { g_dp_data[i] = nil; g_dp_ptr[i] = NULL; }
    for (int i = 0; i < DP_SCHED_N; i++) atomic_store(&g_dp_sched[i].frame, 0);
    atomic_store(&g_dp_newest, 0);
}

static void usb_stop_streaming(void) {
    dp_stop();   /* WriteMix stops touching the schedule */
    if (!atomic_exchange(&g_io_running, false)) return;
    hb_stop();
#if SL2_DEBUG   /* this stream's results */
    if (g_dp_started)
        DBG_LOG("DBG dp result: written %u, late %u, unscheduled %u | enqueue refused %u, resyncs %u | "
            "sent-captured now %.1f, max %.1f frames",
            atomic_load(&dp_written), atomic_load(&dp_late), atomic_load(&dp_unscheduled),
            dp_enq_fail, dp_resync, g_dp_err, dp_err_max);
    {
        const uint32_t *c = dbg_capdelay_hist;
        char hb[600]; int o = 0;
        for (int i = 0; i < 24; i++)
            if (c[i]) o += snprintf(hb + o, sizeof hb - o, " %+.1f:%u", -2.0 + 0.5 * i, c[i]);
        DBG_LOG("DBG capture handler vs bus start of its frame (ms, bin start:count):%{public}s | "
            "min %.2f max %.2f | stack stamp min %.2f max %.2f",
            hb, dbg_capdelay_min, dbg_capdelay_max, dbg_capstamp_min, dbg_capstamp_max);
    }
#endif
    if (g_cpipe) [g_cpipe abortWithError:nil];
    if (g_ppipe) [g_ppipe abortWithError:nil];
    dp_release();
    if (g_cap)   [g_cap selectAlternateSetting:0 error:nil];
    if (g_play)  [g_play selectAlternateSetting:0 error:nil];
    set_usb_switches(false);
    g_cpipe = nil; g_ppipe = nil;
    g_cap = nil;   g_play = nil;
    LOG("Streaming stopped; Analog Thru restored");
}

static void usb_close_all(void) {
    usb_stop_streaming();
    if (g_hpipe_in)  [g_hpipe_in abortWithError:nil];
    if (g_hpipe_out) [g_hpipe_out abortWithError:nil];
    g_hpipe_in = nil; g_hpipe_out = nil;
    if (g_hid)  { [g_hid destroy]; g_hid = nil; }
    if (g_dev)  { [g_dev destroy]; g_dev = nil; }
    atomic_store(&g_hw_connected, false);
}

static void notify_alive_changed(void) {
    if (!g_host) return;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    g_host->PropertiesChanged(g_host, kObjDevice, 1, &addr);
}

/* ----------------------------------------------------------------------------
 * Bootloader detection. The SL 2 keeps its firmware in an on-board I2C EEPROM. If that is blank
 * or corrupt the box enumerates in the Cypress FX2 USB bootloader (bcdDevice 0x0000: one vendor
 * interface, no strings, shown as "Unnamed Device") and passes no audio until the EEPROM is
 * written again. The driver reports this — in the log and via a boot_mode flag in the 'sl2s'
 * status — so a client knows the box needs its firmware restored.
 * ---------------------------------------------------------------------------- */
static void note_bootloader_device(void) {
    LOG("Rane SL 2 is in USB bootloader mode (bcdDevice 0x0000): no firmware loaded, so no "
        "audio until the box's firmware is restored.");
}

static void on_usb_added(void *refcon, io_iterator_t iter) {
    io_service_t s;
    bool audio = false, bootloader = false;
    while ((s = IOIteratorNext(iter))) {
        if (svc_bcd(s) == BCD_LOADER) bootloader = true;
        else                          audio = true;
        IOObjectRelease(s);
    }
    if (audio) {
        atomic_store(&g_boot_mode, false);
        LOG("Rane SL 2 USB connected");
        pthread_mutex_lock(&g_mutex);
        usb_ensure_hid();
        pthread_mutex_unlock(&g_mutex);
        notify_alive_changed();
    }
    if (bootloader) {
        atomic_store(&g_boot_mode, true);
        note_bootloader_device();
    }
}

static void on_usb_removed(void *refcon, io_iterator_t iter) {
    io_service_t s;
    bool removed = false;
    while ((s = IOIteratorNext(iter))) { IOObjectRelease(s); removed = true; }
    if (removed) {
        LOG("Rane SL 2 USB disconnected");
        pthread_mutex_lock(&g_mutex);
        usb_close_all();
        pthread_mutex_unlock(&g_mutex);
        notify_alive_changed();
    }
}

static void start_hotplug_monitor(void) {
    dispatch_queue_t hq = dispatch_queue_create("com.rane.sl2.hotplug", DISPATCH_QUEUE_SERIAL);
    g_notify_port = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(g_notify_port, hq);

    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);

    CFMutableDictionaryRef m1 = IOServiceMatching(kIOUSBDeviceClassName);
    CFDictionarySetValue(m1, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m1, CFSTR(kUSBProductID), pn);
    IOServiceAddMatchingNotification(g_notify_port, kIOFirstMatchNotification, m1, on_usb_added, NULL, &g_added_iter);
    on_usb_added(NULL, g_added_iter);

    CFMutableDictionaryRef m2 = IOServiceMatching(kIOUSBDeviceClassName);
    CFDictionarySetValue(m2, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m2, CFSTR(kUSBProductID), pn);
    IOServiceAddMatchingNotification(g_notify_port, kIOTerminatedNotification, m2, on_usb_removed, NULL, &g_removed_iter);
    while (IOIteratorNext(g_removed_iter)) {}

    CFRelease(vn); CFRelease(pn);
}

/* ============================================================================
 * CoreAudio AudioServerPlugIn Interface
 * ============================================================================ */

static HRESULT SL2_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef iunk = IUnknownUUID;
    CFUUIDRef p2 = kAudioServerPlugInDriverInterfaceUUID;
    if (CFEqual(req, iunk) || CFEqual(req, p2)) {
        CFRelease(req);
        g_ref_count++;
        *outInterface = inDriver;
        return kAudioHardwareNoError;
    }
    CFRelease(req);
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG SL2_AddRef(void *inDriver) { return ++g_ref_count; }
static ULONG SL2_Release(void *inDriver) { return g_ref_count > 0 ? --g_ref_count : 0; }

static OSStatus SL2_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    g_log = os_log_create("com.rane.sl2", "HAL");
    g_host = inHost;
    mach_timebase_info(&g_tb);
    clk_reset();
    start_hotplug_monitor();
    LOG("SL2Device AudioServerPlugIn Initialized");
    return kAudioHardwareNoError;
}

static OSStatus SL2_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *outID) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus SL2_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus SL2_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) { return kAudioHardwareNoError; }
static OSStatus SL2_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) { return kAudioHardwareNoError; }
/* Sample-rate changes go through the HAL's configuration-change handshake: the setters call
   RequestDeviceConfigurationChange with the new rate as the action, and the HAL calls this with
   IO stopped, then re-reads the device's rate and formats. The HAL caches the rate, so a plug-in
   must not change it any other way: the HAL would keep rendering at the cached rate into a box
   clocked at the new one. */
static OSStatus SL2_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    if (id != kObjDevice || (action != 44100 && action != 48000)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&g_mutex);
    if ((Float64)action != g_sr) {
        bool was_streaming = atomic_load(&g_io_running);
        if (was_streaming) usb_stop_streaming();
        g_sr = (Float64)action;
        clk_reset();
        atomic_fetch_add(&g_zts_seed, 1);   /* new timeline for the HAL */
        if (was_streaming) usb_open_all();   /* sends 0x31 itself */
        else if (usb_ensure_hid()) send_hw_samplerate((int)g_sr);
        LOG("Sample rate changed to %.0f Hz", g_sr);
    }
    pthread_mutex_unlock(&g_mutex);
    return kAudioHardwareNoError;
}

/* Ask the HAL to switch the device to rate; it then stops IO and calls
   SL2_PerformDeviceConfigurationChange. Re-selecting the current rate just re-sends it to the box. */
static OSStatus request_sample_rate(Float64 rate) {
    if (rate != 44100.0 && rate != 48000.0) return kAudioDeviceUnsupportedFormatError;
    if (rate == g_sr) {
        pthread_mutex_lock(&g_mutex);
        if (usb_ensure_hid()) send_hw_samplerate((int)rate);
        pthread_mutex_unlock(&g_mutex);
        return kAudioHardwareNoError;
    }
    if (!g_host) return kAudioHardwareNotRunningError;
    return g_host->RequestDeviceConfigurationChange(g_host, kObjDevice, (UInt64)rate, NULL);
}
static OSStatus SL2_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) { return kAudioHardwareNoError; }

static Boolean SL2_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr) {
    if (!addr) return false;
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    if (oid == kObjPlugIn) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle:
                return true;
        }
        return false;
    }
    if (oid == kObjDevice) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyModelName:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyPreferredChannelLayout:
            case kAudioObjectPropertyElementName:
            case kSL2PropHIDCommand:
            case kSL2PropStatus:
            case kSL2PropUnsolQueue:
            case kAudioObjectPropertyCustomPropertyInfoList:
                return true;
        }
        return false;
    }
    if (oid == kObjStreamIn || oid == kObjStreamOut) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
        }
        return false;
    }
    (void)sc;
    return false;
}

static OSStatus SL2_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, Boolean *outSettable) {
    *outSettable = false;
    if (oid == kObjDevice && (addr->mSelector == kAudioDevicePropertyNominalSampleRate || addr->mSelector == kSL2PropHIDCommand)) {
        *outSettable = true;
    } else if ((oid == kObjStreamIn || oid == kObjStreamOut) &&
               (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        *outSettable = true;
    }
    return kAudioHardwareNoError;
}

static void fill_asbd(AudioStreamBasicDescription *a, Float64 sr) {
    memset(a, 0, sizeof(*a));
    a->mSampleRate       = sr;
    a->mFormatID         = kAudioFormatLinearPCM;
    a->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    a->mBytesPerPacket   = NCH * sizeof(Float32);
    a->mFramesPerPacket  = 1;
    a->mBytesPerFrame    = NCH * sizeof(Float32);
    a->mChannelsPerFrame = NCH;
    a->mBitsPerChannel   = 32;
}

static OSStatus SL2_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 *outSize) {
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    if (oid == kObjPlugIn) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle: *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: *outSize = sizeof(AudioObjectID); return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); return 0;
        }
    }
    if (oid == kObjDevice) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyModelName:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioObjectPropertyElementName: *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod: *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyRelatedDevices: *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects:
                *outSize = (sc == kAudioObjectPropertyScopeInput || sc == kAudioObjectPropertyScopeOutput)
                         ? sizeof(AudioObjectID) : 2 * sizeof(AudioObjectID);
                return 0;
            case kAudioDevicePropertyStreams:
                if (sc == kAudioObjectPropertyScopeInput || sc == kAudioObjectPropertyScopeOutput) *outSize = sizeof(AudioObjectID);
                else *outSize = 2 * sizeof(AudioObjectID);
                return 0;
            case kAudioObjectPropertyControlList: *outSize = 0; return 0;
            case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = 2 * sizeof(AudioValueRange); return 0;
            case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); return 0;
            case kAudioDevicePropertyPreferredChannelLayout:
                *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + NCH * sizeof(AudioChannelDescription);
                return 0;
            case kSL2PropHIDCommand:
            case kSL2PropStatus:
            case kSL2PropUnsolQueue: *outSize = sizeof(CFDataRef); return 0;
            case kAudioObjectPropertyCustomPropertyInfoList: *outSize = 3 * sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
        }
    }
    if (oid == kObjStreamIn || oid == kObjStreamOut) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyName: *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency: *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: *outSize = sizeof(AudioStreamBasicDescription); return 0;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: *outSize = 2 * sizeof(AudioStreamRangedDescription); return 0;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SL2_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, UInt32 *outSize, void *outData) {
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    if (oid == kObjPlugIn) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioPlugInClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kAudioObjectUnknown; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyManufacturer: *(CFStringRef*)outData = CFSTR("Rane Corporation"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioPlugInPropertyResourceBundle: *(CFStringRef*)outData = CFSTR(""); *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                CFStringRef u = *(CFStringRef*)qd;
                *(AudioObjectID*)outData = (u && CFEqual(u, CFSTR("com.rane.sl2.hal.device"))) ? kObjDevice : kAudioObjectUnknown;
                *outSize = sizeof(AudioObjectID);
                return 0;
            }
        }
    }

    if (oid == kObjDevice) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioDeviceClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kObjPlugIn; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyName: *(CFStringRef*)outData = CFSTR("SL 2"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyManufacturer: *(CFStringRef*)outData = CFSTR("Rane Corporation"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyModelName: *(CFStringRef*)outData = CFSTR("Rane SL 2"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyDeviceUID: *(CFStringRef*)outData = CFSTR("com.rane.sl2.hal.device"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyModelUID: *(CFStringRef*)outData = CFSTR("com.rane.sl2.hal.model"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyTransportType: *(UInt32*)outData = kAudioDeviceTransportTypeUSB; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyRelatedDevices: *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioDevicePropertyClockDomain: *(UInt32*)outData = 0x52414E32; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceIsAlive: *(UInt32*)outData = 1; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceIsRunning: *(UInt32*)outData = (g_io_clients > 0) ? 1 : 0; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *(UInt32*)outData = 1; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyLatency:
                *(UInt32*)outData = (sc == kAudioObjectPropertyScopeOutput) ? out_latency_frames() : 32;
                *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertySafetyOffset:
                *(UInt32*)outData = (sc == kAudioObjectPropertyScopeInput) ? in_safety_frames() : out_safety_frames();
                *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyIsHidden: *(UInt32*)outData = 0; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32*)outData = 2048; *outSize = sizeof(UInt32); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams: {
                AudioObjectID *ids = (AudioObjectID*)outData;
                if (sc == kAudioObjectPropertyScopeInput) { ids[0] = kObjStreamIn; *outSize = sizeof(AudioObjectID); }
                else if (sc == kAudioObjectPropertyScopeOutput) { ids[0] = kObjStreamOut; *outSize = sizeof(AudioObjectID); }
                else { ids[0] = kObjStreamIn; ids[1] = kObjStreamOut; *outSize = 2 * sizeof(AudioObjectID); }
                return 0;
            }
            case kAudioObjectPropertyControlList: *outSize = 0; return 0;
            case kAudioDevicePropertyNominalSampleRate: *(Float64*)outData = g_sr; *outSize = sizeof(Float64); return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange *r = (AudioValueRange*)outData;
                r[0].mMinimum = 44100.0; r[0].mMaximum = 44100.0;
                r[1].mMinimum = 48000.0; r[1].mMaximum = 48000.0;
                *outSize = 2 * sizeof(AudioValueRange);
                return 0;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32 *c = (UInt32*)outData; c[0] = 1; c[1] = 2; *outSize = 2 * sizeof(UInt32); return 0;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                AudioChannelLayout *l = (AudioChannelLayout*)outData;
                l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                l->mChannelBitmap = 0;
                l->mNumberChannelDescriptions = NCH;
                for (UInt32 i = 0; i < NCH; i++) {
                    l->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Discrete_0 + i;
                    l->mChannelDescriptions[i].mChannelFlags = 0;
                }
                *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + NCH * sizeof(AudioChannelDescription);
                return 0;
            }
            case kAudioObjectPropertyElementName: {
                static CFStringRef const inNames[4] = {
                    CFSTR("Left Deck In L"), CFSTR("Left Deck In R"),
                    CFSTR("Right Deck In L"), CFSTR("Right Deck In R")
                };
                static CFStringRef const outNames[4] = {
                    CFSTR("Left Deck Out L"), CFSTR("Left Deck Out R"),
                    CFSTR("Right Deck Out L"), CFSTR("Right Deck Out R")
                };
                UInt32 el = addr->mElement;
                if (el >= 1 && el <= NCH) {
                    CFStringRef nm = (sc == kAudioObjectPropertyScopeInput) ? inNames[el-1] : outNames[el-1];
                    CFRetain(nm);
                    *(CFStringRef*)outData = nm;
                } else {
                    *(CFStringRef*)outData = CFSTR("");
                }
                *outSize = sizeof(CFStringRef);
                return 0;
            }
            case kAudioObjectPropertyCustomPropertyInfoList: {
                /* Declares the custom properties so the HAL marshals them to clients
                   (SL2Api.framework, sl2panel). Without this, clients get 'who?'. */
                static const AudioServerPlugInCustomPropertyInfo all[3] = {
                    { kSL2PropHIDCommand, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL2PropStatus,     kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL2PropUnsolQueue, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                };
                UInt32 n = inSize / sizeof(AudioServerPlugInCustomPropertyInfo);
                if (n > 3) n = 3;
                memcpy(outData, all, n * sizeof(AudioServerPlugInCustomPropertyInfo));
                *outSize = n * sizeof(AudioServerPlugInCustomPropertyInfo);
                return 0;
            }
            case kSL2PropHIDCommand: {
                pthread_mutex_lock(&g_mutex);
                usb_ensure_hid();
                uint8_t reply[64] = {0};
                uint32_t seq_in = 0;
                memcpy(&seq_in, g_last_cmd_in + 1, 4);
                hid_cmd(g_last_cmd_in[0], g_last_cmd_in + 5, 59, reply, seq_in ? &seq_in : NULL);
                pthread_mutex_unlock(&g_mutex);
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, reply, 64);
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL2PropStatus: {
                pthread_mutex_lock(&g_mutex);
                usb_ensure_hid();
                g_st.connected = atomic_load(&g_hw_connected) ? 1 : 0;
                g_st.streaming = atomic_load(&g_io_running) ? 1 : 0;
                g_st.sample_rate = (uint32_t)g_sr;
                g_st.cap_frames = atomic_load(&g_total_cap_frames);
                g_st.play_frames = atomic_load(&g_total_play_frames);
                g_st.boot_mode = atomic_load(&g_boot_mode) ? 1 : 0;
                pthread_mutex_unlock(&g_mutex);
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, (const UInt8*)&g_st, sizeof(g_st));
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL2PropUnsolQueue: {
                pthread_mutex_lock(&g_unsol_mtx);
                uint32_t count = g_unsol_w - g_unsol_r;
                if (count > UNSOL_Q_MAX) count = UNSOL_Q_MAX;
                CFMutableDataRef md = CFDataCreateMutable(kCFAllocatorDefault, count * 64);
                while (g_unsol_r < g_unsol_w) {
                    CFDataAppendBytes(md, g_unsol_q[g_unsol_r % UNSOL_Q_MAX], 64);
                    g_unsol_r++;
                }
                pthread_mutex_unlock(&g_unsol_mtx);
                *(CFDataRef*)outData = md;
                *outSize = sizeof(CFDataRef);
                return 0;
            }
        }
    }

    if (oid == kObjStreamIn || oid == kObjStreamOut) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioStreamClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyName:
                *(CFStringRef*)outData = (oid == kObjStreamIn) ? CFSTR("SL 2 Input Stream") : CFSTR("SL 2 Output Stream");
                *outSize = sizeof(CFStringRef); return 0;
            case kAudioStreamPropertyIsActive: *(UInt32*)outData = 1; *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyDirection: *(UInt32*)outData = (oid == kObjStreamIn) ? 1 : 0; *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyTerminalType:
                *(UInt32*)outData = (oid == kObjStreamIn) ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker;
                *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyStartingChannel: *(UInt32*)outData = 1; *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyLatency: *(UInt32*)outData = 32; *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                fill_asbd((AudioStreamBasicDescription*)outData, g_sr);
                *outSize = sizeof(AudioStreamBasicDescription);
                return 0;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription *rd = (AudioStreamRangedDescription*)outData;
                fill_asbd(&rd[0].mFormat, 44100.0);
                rd[0].mSampleRateRange.mMinimum = 44100.0; rd[0].mSampleRateRange.mMaximum = 44100.0;
                fill_asbd(&rd[1].mFormat, 48000.0);
                rd[1].mSampleRateRange.mMinimum = 48000.0; rd[1].mSampleRateRange.mMaximum = 48000.0;
                *outSize = 2 * sizeof(AudioStreamRangedDescription);
                return 0;
            }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SL2_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, const void *inData) {
    if (oid == kObjDevice && addr->mSelector == kSL2PropHIDCommand) {
        if (inSize == sizeof(CFDataRef) && inData) {
            CFDataRef cd = *(CFDataRef*)inData;
#if SL2_DEBUG   /* debug command 0xF2: handled here, never sent to the box */
            if (cd && CFGetTypeID(cd) == CFDataGetTypeID() && CFDataGetLength(cd) >= 6 &&
                CFDataGetBytePtr(cd)[0] == 0xF2) {
                /* input safety offset in ms. Of limited use: the HAL reads safety offsets only at
                   device setup (neither PropertiesChanged nor a configuration change refreshes them),
                   and a coreaudiod restart reloads the driver with its default. */
                int ms = CFDataGetBytePtr(cd)[5];
                if (ms < 1) ms = 1;
                atomic_store(&g_in_safety_ms, ms);
                DBG_LOG("DBG input safety offset set to %d ms (%u frames)", ms, in_safety_frames());
                return 0;
            }
#endif
            if (cd && CFGetTypeID(cd) == CFDataGetTypeID() && CFDataGetLength(cd) <= 64) {
                memset(g_last_cmd_in, 0, 64);
                memcpy(g_last_cmd_in, CFDataGetBytePtr(cd), CFDataGetLength(cd));
                if (g_last_cmd_in[0] == 0x31 && CFDataGetLength(cd) >= 7) {
                    int sr = (g_last_cmd_in[5] << 8) | g_last_cmd_in[6];
                    /* A client (Serato) changing the rate over HID: route it through the HAL
                       so CoreAudio's rate and the box's stay in step. */
                    if (sr == 44100 || sr == 48000) {
                        if ((Float64)sr != g_sr && g_host)
                            g_host->RequestDeviceConfigurationChange(g_host, kObjDevice, (UInt64)sr, NULL);
                        push_sr_unsol(sr);
                    }
                }
            }
        }
        return 0;
    }
    if (oid == kObjDevice && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64) || !inData) return kAudioHardwareBadPropertySizeError;
        return request_sample_rate(*(const Float64*)inData);
    }
    if ((oid == kObjStreamIn || oid == kObjStreamOut) &&
        (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize < sizeof(AudioStreamBasicDescription) || !inData) return kAudioHardwareBadPropertySizeError;
        return request_sample_rate(((const AudioStreamBasicDescription*)inData)->mSampleRate);
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SL2_StartIO(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid) {
    pthread_mutex_lock(&g_mutex);
    if (g_io_clients == 0) {
        if (!usb_open_all()) {
            clk_reset();
            atomic_store(&g_total_cap_frames, 0);
            atomic_store(&g_total_play_frames, 0);
        }
    }
    g_io_clients++;
    pthread_mutex_unlock(&g_mutex);
    return 0;
}

static OSStatus SL2_StopIO(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid) {
    pthread_mutex_lock(&g_mutex);
    if (g_io_clients > 0) {
        g_io_clients--;
        if (g_io_clients == 0) usb_stop_streaming();
    }
    pthread_mutex_unlock(&g_mutex);
    return 0;
}

static OSStatus SL2_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    double pos = s + ((double)mach_absolute_time() - (double)h) / tpf;
    double period = pos > 0 ? floor(pos / 2048.0) * 2048.0 : 0;   /* latest period boundary */

    *outSampleTime = period;
    *outHostTime   = (uint64_t)((double)h + (period - s) * tpf);
    *outSeed       = atomic_load(&g_zts_seed);
    return 0;
}

static OSStatus SL2_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, Boolean *outWillDo, Boolean *outIsInPlace) {
    *outIsInPlace = true;
    *outWillDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    return 0;
}

static OSStatus SL2_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { return 0; }

static OSStatus SL2_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, AudioObjectID sid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci, void *ioMain, void *ioSec) {
    float *buf = (float*)ioMain;
    if (op == kAudioServerPlugInIOOperationReadInput) {
        uint64_t pos = (uint64_t)ci->mInputTime.mSampleTime;
        for (UInt32 f = 0; f < frames; f++) {
            uint32_t idx = ((uint32_t)((pos + f) & RING_MASK)) * NCH;
            memcpy(buf + f * NCH, &g_in_ring[idx], NCH * sizeof(float));
        }
    } else if (op == kAudioServerPlugInIOOperationWriteMix) {
        uint64_t pos = (uint64_t)ci->mOutputTime.mSampleTime;
        /* Register as a writer before checking g_dp_active, so dp_stop either sees this call
           or this call sees the schedule switched off. */
        int writers = atomic_fetch_add_explicit(&g_dp_writers, 1, memory_order_seq_cst);
        if (atomic_load_explicit(&g_dp_active, memory_order_seq_cst)) {
#if SL2_DEBUG
            {   /* WriteMix calling pattern: with several clients the HAL calls it from more than one
                   IO thread; it was measured never to overlap or repeat a position (each call carries
                   the full mix), which is what lets dp_write overwrite rather than mix */
                uint64_t tid = (uint64_t)pthread_mach_thread_np(pthread_self());
                if (atomic_exchange_explicit(&dbg_wm_last_thread, tid, memory_order_relaxed) != tid)
                    atomic_fetch_add_explicit(&dbg_wm_thread_switches, 1, memory_order_relaxed);
                if (writers > 0) atomic_fetch_add_explicit(&dbg_wm_concurrent, 1, memory_order_relaxed);
                uint64_t hi = atomic_load_explicit(&dbg_wm_high, memory_order_relaxed);
                if (pos < hi) {
                    uint64_t over = hi - pos;
                    atomic_fetch_add_explicit(&dbg_wm_rewritten, (uint32_t)(over < frames ? over : frames), memory_order_relaxed);
                }
                if (pos + frames > hi) atomic_store_explicit(&dbg_wm_high, pos + frames, memory_order_relaxed);
            }
#else
            (void)writers;
#endif
            dp_write(buf, frames, pos);
            atomic_fetch_sub_explicit(&g_dp_writers, 1, memory_order_release);
            return 0;
        }
        atomic_fetch_sub_explicit(&g_dp_writers, 1, memory_order_release);
    }
    return 0;
}

static OSStatus SL2_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { return 0; }

static AudioServerPlugInDriverInterface g_interface = {
    NULL,
    SL2_QueryInterface,
    SL2_AddRef,
    SL2_Release,
    SL2_Initialize,
    SL2_CreateDevice,
    SL2_DestroyDevice,
    SL2_AddDeviceClient,
    SL2_RemoveDeviceClient,
    SL2_PerformDeviceConfigurationChange,
    SL2_AbortDeviceConfigurationChange,
    SL2_HasProperty,
    SL2_IsPropertySettable,
    SL2_GetPropertyDataSize,
    SL2_GetPropertyData,
    SL2_SetPropertyData,
    SL2_StartIO,
    SL2_StopIO,
    SL2_GetZeroTimeStamp,
    SL2_WillDoIOOperation,
    SL2_BeginIOOperation,
    SL2_DoIOOperation,
    SL2_EndIOOperation
};

static AudioServerPlugInDriverInterface *g_driver_ptr = &g_interface;

__attribute__((visibility("default")))
void* SL2Device_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return &g_driver_ptr;
    }
    return NULL;
}
