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
#define PLAY_NXF     20
#define PLAY_START_MS 24     /* first playback transfer is scheduled this many USB frames (ms) ahead */
#define OUT_SAFETY_MS 2      /* how far ahead of "now" the HAL writes output: one 1 ms transfer + 1 ms headroom */
#define RING_FRAMES  65536   /* ~1.36s @ 48kHz */
#define RING_MASK    (RING_FRAMES - 1)
#define FIFO_N       2048

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

/* Ring buffers (Float32 interleaved, NCH channels) */
static float g_in_ring[RING_FRAMES * NCH];
static float g_out_ring[RING_FRAMES * NCH];

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
   that frame's time (g_rate_anchor). These, g_play_base and g_clk_last_fix are touched only on g_q. */
#define CLK_FIX_FRAMES 2048
#define CLK_CORR_S     2.0
static mach_timebase_info_data_t g_tb;
static _Atomic uint32_t g_clk_seq = 0;
static uint64_t g_clk_host = 0;
static double   g_clk_sample = 0;
static double   g_clk_tpf = 0;
static uint64_t g_rate_anchor = 0;
static uint64_t g_cap_base = 0;
static uint64_t g_play_base = 0;     /* timeline position playback starts reading from */
static uint64_t g_clk_last_fix = 0;  /* captured-frame count at the last clk_track correction */

/* Output timing. With g_play_nxf 1 ms transfers queued, a transfer is filled when the one
   g_play_nxf before it completes, about g_play_nxf ms before it plays. Reading each frame
   out_latency_frames() (g_play_nxf ms) after its timeline position puts the end of each read at
   most 1 ms (one transfer) ahead of the HAL's "now"; the HAL writes OUT_SAFETY_MS ahead. Both are
   reported to the HAL, so clients see the true output latency: their sum. */
static _Atomic int g_play_nxf = PLAY_NXF;   /* transfers queued; DEBUG: settable via 'sl2h' 0xF0 */
static _Atomic int g_in_safety_ms = 20;   /* DEBUG: settable via 'sl2h' 0xF2 */
static UInt32 in_safety_frames(void) {
    return (UInt32)(atomic_load(&g_in_safety_ms) * g_sr / 1000.0 + 0.5);
}
static UInt32 out_safety_frames(void) {
    return (UInt32)(OUT_SAFETY_MS * g_sr / 1000.0 + 0.5);
}
static UInt32 out_latency_frames(void) {
    return (UInt32)(atomic_load(&g_play_nxf) * (PLAY_PKTS / 8) * g_sr / 1000.0 + 0.5);
}
static _Atomic uint64_t g_total_cap_frames = 0;
static _Atomic uint64_t g_total_play_frames = 0;
static _Atomic uint64_t g_zts_seed = 1;     /* GetZeroTimeStamp seed: bumped when the timeline changes */

static double nominal_tpf(void) {
    return ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
}

static void clk_get(uint64_t *host, double *sample, double *tpf) {
    uint32_t s1, s2;
    do {
        s1 = atomic_load_explicit(&g_clk_seq, memory_order_acquire);
        *host = g_clk_host; *sample = g_clk_sample; *tpf = g_clk_tpf;
        atomic_thread_fence(memory_order_acquire);
        s2 = atomic_load_explicit(&g_clk_seq, memory_order_relaxed);
    } while ((s1 & 1) || s1 != s2);
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

/* Implicit feedback packet-size FIFO */
static int g_fifo[FIFO_N];
static _Atomic uint32_t g_fifo_w = 0;
static _Atomic uint32_t g_fifo_r = 0;
static uint32_t g_faccum = 0;

/* IOUSBHost state */
static dispatch_queue_t    g_q;
static uint32_t dbg_margin_hist[8];         /* playback submit margin: <0, 0, 1, ..., 5, >=6 frames */
static uint32_t dbg_capdelay_hist[7];       /* capture delivery delay: <1, <2, <3, <5, <10, <20, >=20 ms */
static IOUSBHostDevice    *g_dev;
static IOUSBHostInterface *g_play, *g_cap, *g_hid;
static IOUSBHostPipe      *g_ppipe, *g_cpipe, *g_hpipe_in, *g_hpipe_out;

/* Isoch transfer pools */
typedef struct {
    NSMutableData *buf;
    IOUSBHostIsochronousTransaction *tx;
} IsoXfer;
static IsoXfer g_cap_xf[CAP_NXF];
static IsoXfer g_play_xf[PLAY_NXF];
static uint64_t g_cap_frame = 0;
static uint64_t g_play_frame = 0;
static _Atomic int g_play_inflight = 0;

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

    static uint32_t dbg_n;   /* DEBUG (temporary) */
    if (++dbg_n % 40 == 0)
        LOG("DBG clk: phase error %.1f frames (%.3f ms), rate %.1f ppm vs nominal",
            err, 1000.0 * err / g_sr, (rate / nom_rate - 1.0) * 1e6);
}

/* DEBUG (temporary): playback/capture health counters, reset per stream, logged every ~2 s */
static uint32_t dbg_late, dbg_enq_fail, dbg_play_st_err, dbg_play_pkt_err, dbg_fifo_empty, dbg_cap_pkt_err;
static uint32_t dbg_aborted, dbg_restarts, dbg_skipped_ms;
/* DEBUG: are USB completions really serialised on g_q? */
static int dbg_q_key;
static _Atomic int dbg_in_handler;
static _Atomic uint32_t dbg_overlap, dbg_off_queue;
static _Atomic uint64_t dbg_last_play_done;
static bool     dbg_slot_pending[PLAY_NXF];
static uint32_t dbg_enq_ok, dbg_completions, dbg_double_done, dbg_reuse_pending;
static void dbg_enter(void) {
    if (atomic_fetch_add(&dbg_in_handler, 1) > 0) atomic_fetch_add(&dbg_overlap, 1);
    if (!dispatch_get_specific(&dbg_q_key)) atomic_fetch_add(&dbg_off_queue, 1);
}
static void dbg_leave(void) { atomic_fetch_sub(&dbg_in_handler, 1); }
static int64_t  dbg_min_margin = 1 << 30;
static int      dbg_enq_err_code;

static void play_submit(int idx) {
    if (!atomic_load(&g_io_running) || !g_ppipe) return;
    IsoXfer *xf = &g_play_xf[idx];
    uint8_t *buf = xf->buf.mutableBytes;
    IOUSBHostIsochronousTransaction *tx = xf->tx;
    uint64_t f = g_play_frame;
    g_play_frame += PLAY_PKTS / 8;

    int total_frames = 0;
    int pkt_n[PLAY_PKTS];
    for (int k = 0; k < PLAY_PKTS; k++) {
        int n;
        uint32_t r = atomic_load_explicit(&g_fifo_r, memory_order_relaxed);
        uint32_t w = atomic_load_explicit(&g_fifo_w, memory_order_acquire);
        if (r < w) {
            n = g_fifo[r % FIFO_N];
            atomic_store_explicit(&g_fifo_r, r + 1, memory_order_release);
        } else {
            dbg_fifo_empty++;   /* DEBUG */
            uint32_t sr8 = (uint32_t)g_sr;
            g_faccum += sr8;
            n = g_faccum / 8000;
            g_faccum %= 8000;
        }
        if (n < 4) n = 5;
        if (n * FRAME_BYTES > PKT_MAX) n = PKT_MAX / FRAME_BYTES;
        pkt_n[k] = n;
        total_frames += n;
    }

    uint64_t rp = g_play_base + atomic_fetch_add_explicit(&g_total_play_frames, total_frames, memory_order_acq_rel);

    /* The HAL guarantees output only up to "now + output safety offset" on its timeline. Frames
       beyond that (the burst of transfers queued when playback starts) play as silence. */
    double tl_now = clk_sample_at(mach_absolute_time());
    uint64_t written_to = tl_now > 0 ? (uint64_t)tl_now + out_safety_frames() : 0;

    /* DEBUG (temporary): reader position vs the HAL timeline, every ~2 s */
    static uint64_t dbg_base; static uint32_t dbg_submits, dbg_silent;
    if (dbg_base != g_play_base) {
        dbg_base = g_play_base; dbg_submits = 0; dbg_silent = 0;
    }
    if (++dbg_submits % 2000 == 0) {
        LOG("DBG play q%d: read %.2f ms ahead (limit %.1f) | silent %u | min margin %lld fr, late %u | "
            "enqueue fail %u (0x%x) | play err %u/%u pkts | cap pkt err %u | fifo empty %u | aborted %u | restarts %u | skipped %u ms",
            atomic_load(&g_play_nxf), 1000.0 * ((double)(rp + total_frames) - tl_now) / g_sr,
            1000.0 * out_safety_frames() / g_sr, dbg_silent, (long long)dbg_min_margin, dbg_late,
            dbg_enq_fail, dbg_enq_err_code, dbg_play_st_err, dbg_play_pkt_err, dbg_cap_pkt_err, dbg_fifo_empty,
            dbg_aborted, dbg_restarts, dbg_skipped_ms);
        dbg_min_margin = 1 << 30;   /* per-interval minimum */
    }

    for (int k = 0; k < PLAY_PKTS; k++) {
        int n = pkt_n[k];
        tx[k] = (IOUSBHostIsochronousTransaction){
            .requestCount = (uint32_t)(n * FRAME_BYTES),
            .offset = (uint32_t)(k * PKT_MAX)
        };

        uint8_t *dst = buf + k * PKT_MAX;
        for (int s = 0; s < n; s++) {
            uint32_t ridx = ((uint32_t)(rp & RING_MASK)) * NCH;
            uint8_t *q = dst + s * FRAME_BYTES;
            bool ready = rp < written_to;
            if (!ready && dbg_submits > (uint32_t)atomic_load(&g_play_nxf)) dbg_silent++;   /* DEBUG */
            for (int c = 0; c < NCH; c++) {
                float v = ready ? g_out_ring[ridx + c] : 0.0f;
                if (ready) g_out_ring[ridx + c] = 0.0f;
                if (v > 1.0f) v = 1.0f;
                else if (v < -1.0f) v = -1.0f;
                int32_t raw32 = (int32_t)(v * 2147483392.0f);
                memcpy(q + c * 4, &raw32, 4);
            }
            rp++;
        }
    }

    atomic_fetch_add(&g_play_inflight, 1);
    if (dbg_slot_pending[idx]) dbg_reuse_pending++;   /* DEBUG */
    NSError *e = nil;
    BOOL queued = [g_ppipe enqueueIORequestWithData:xf->buf
                      transactionList:tx
                  transactionListCount:PLAY_PKTS
                      firstFrameNumber:f
                               options:IOUSBHostIsochronousTransferOptionsNone
                                 error:&e
                     completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        dbg_enter();   /* DEBUG */
        atomic_store(&dbg_last_play_done, mach_absolute_time());
        dbg_completions++;
        if (!dbg_slot_pending[idx]) dbg_double_done++;
        dbg_slot_pending[idx] = false;
        atomic_fetch_sub(&g_play_inflight, 1);
        if (st != kIOReturnSuccess && st != kIOReturnAborted) dbg_play_st_err++;   /* DEBUG */
        if (st == kIOReturnAborted && atomic_load(&g_io_running)) {
            dbg_aborted++;
            LOG("DBG playback transfer aborted while streaming (in flight now %d)", atomic_load(&g_play_inflight));
        }
        for (int k = 0; k < PLAY_PKTS && st != kIOReturnAborted; k++)
            if (done[k].status != kIOReturnSuccess) dbg_play_pkt_err++;
        if (atomic_load(&g_io_running) && st != kIOReturnAborted) {
            uint32_t before = dbg_enq_ok + dbg_enq_fail;   /* DEBUG */
            play_submit(idx);
            if (dbg_enq_ok + dbg_enq_fail == before)
                LOG("DBG play_submit(%d) returned without enqueueing (st 0x%x, running %d, ppipe %p)",
                    idx, st, atomic_load(&g_io_running), g_ppipe);
        } else {
            LOG("DBG play completion not resubmitted: slot %d, st 0x%x, running %d", idx, st, atomic_load(&g_io_running));
        }
        dbg_leave();   /* DEBUG */
    }];
    if (!queued) {
        atomic_fetch_sub(&g_play_inflight, 1);
        dbg_enq_fail++; dbg_enq_err_code = (int)e.code;   /* DEBUG */
        LOG("DBG play enqueue failed: slot %d, frame %llu is %lld frames from now, error 0x%x %{public}@",
            idx, f, (long long)f - (long long)[g_dev frameNumberWithTime:NULL], (int)e.code, e.localizedDescription);
    } else {
        dbg_enq_ok++; dbg_slot_pending[idx] = true;   /* DEBUG */
    }
}

static void cap_submit(int idx) {
    if (!atomic_load(&g_io_running) || !g_cpipe) return;
    IsoXfer *xf = &g_cap_xf[idx];
    IOUSBHostIsochronousTransaction *tx = xf->tx;
    uint64_t f = g_cap_frame;
    g_cap_frame += CAP_PKTS / 8;

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
        dbg_enter();   /* DEBUG */
        {   /* DEBUG: how long after its last packet this capture transfer was delivered */
            uint64_t last = done[CAP_PKTS - 1].timeStamp, nowt = mach_absolute_time();
            if (last && nowt > last) {
                double ms = (double)(nowt - last) * g_tb.numer / g_tb.denom / 1e6;
                dbg_capdelay_hist[ms < 1 ? 0 : ms < 2 ? 1 : ms < 3 ? 2 : ms < 5 ? 3 : ms < 10 ? 4 : ms < 20 ? 5 : 6]++;
            }
        }
        const uint8_t *b = xf->buf.bytes;
        uint64_t wp = atomic_load_explicit(&g_total_cap_frames, memory_order_relaxed);
        int got = 0;
        uint64_t ts = 0;

        if (wp == 0) {   /* nothing captured yet: place this transfer's first frame on the timeline */
            for (int k = 0; k < CAP_PKTS; k++) {
                if (done[k].status == kIOReturnSuccess && done[k].completeCount >= FRAME_BYTES &&
                    done[k].completeCount <= PKT_MAX) {
                    clk_first_capture(done[k].timeStamp);
                    break;
                }
            }
        }
        uint64_t ring_pos = g_cap_base + wp;   /* timeline position of this transfer's first frame */

        for (int k = 0; k < CAP_PKTS; k++) {
            /* Drop errored packets and impossible lengths. The first completion after a
               killed helper can carry a residual from the old request (e.g. 0xFFFFFE00),
               and the frame loop must never run past the 112-byte packet. */
            if (done[k].status != kIOReturnSuccess || done[k].completeCount > PKT_MAX) { dbg_cap_pkt_err++; continue; }
            int n = done[k].completeCount / FRAME_BYTES;
            if (n >= 4) {
                uint32_t w = atomic_load_explicit(&g_fifo_w, memory_order_relaxed);
                uint32_t r = atomic_load_explicit(&g_fifo_r, memory_order_acquire);
                if (w - r < FIFO_N) {
                    g_fifo[w % FIFO_N] = n;
                    atomic_store_explicit(&g_fifo_w, w + 1, memory_order_release);
                }
            }
            if (n > 0) {
                if (!ts) ts = done[k].timeStamp;
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

        if (atomic_load(&g_play_inflight) == 0 &&
            (atomic_load(&g_fifo_w) - atomic_load(&g_fifo_r)) >= (uint32_t)(atomic_load(&g_play_nxf) * PLAY_PKTS)) {
            uint64_t usb_now = [g_dev frameNumberWithTime:NULL];
            g_play_frame = usb_now + PLAY_START_MS;
            /* Read so that each frame plays out_latency_frames() after its HAL timeline position:
               the first transfer plays PLAY_START_MS (1 ms per USB frame) from now. */
            double tl_now = clk_sample_at(mach_absolute_time());
            double first = tl_now + PLAY_START_MS * g_sr / 1000.0 - out_latency_frames();
            g_play_base = first > 0 ? (uint64_t)first : 0;
            for (int j = 0; j < atomic_load(&g_play_nxf); j++) play_submit(j);
        }
        cap_submit(idx);
        dbg_leave();   /* DEBUG */
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

static bool usb_ensure_hid(void) {
    if (g_dev && g_hid && g_hpipe_in && g_hpipe_out) return true;
    io_service_t svc = find_sl2_service();
    if (!svc) return false;

    NSError *e = nil;
    if (!g_q) {
        dispatch_queue_attr_t qa = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        g_q = dispatch_queue_create("com.rane.sl2.usb", qa);
        dispatch_queue_set_specific(g_q, &dbg_q_key, &dbg_q_key, NULL);   /* DEBUG */
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

    LOG("DBG playback queue %d", atomic_load(&g_play_nxf));
    memset(dbg_margin_hist, 0, sizeof dbg_margin_hist);
    memset(dbg_capdelay_hist, 0, sizeof dbg_capdelay_hist);

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

    for (int i = 0; i < CAP_NXF; i++) {
        if (!g_cap_xf[i].buf) g_cap_xf[i].buf = [NSMutableData dataWithLength:CAP_PKTS * PKT_MAX];
        if (!g_cap_xf[i].tx)  g_cap_xf[i].tx  = calloc(CAP_PKTS, sizeof(IOUSBHostIsochronousTransaction));
    }
    for (int i = 0; i < PLAY_NXF; i++) {
        if (!g_play_xf[i].buf) g_play_xf[i].buf = [NSMutableData dataWithLength:PLAY_PKTS * PKT_MAX];
        if (!g_play_xf[i].tx)  g_play_xf[i].tx  = calloc(PLAY_PKTS, sizeof(IOUSBHostIsochronousTransaction));
    }

    set_usb_switches(true);
    hb_start();

    memset(g_in_ring, 0, sizeof(g_in_ring));
    memset(g_out_ring, 0, sizeof(g_out_ring));
    atomic_store(&g_fifo_w, 0);
    atomic_store(&g_fifo_r, 0);
    atomic_store(&g_play_inflight, 0);
    g_faccum = 0;

    clk_reset();
    atomic_store(&g_total_cap_frames, 0);
    atomic_store(&g_total_play_frames, 0);
    dbg_aborted = dbg_restarts = dbg_skipped_ms = 0;   /* DEBUG */
    dbg_late = dbg_enq_fail = dbg_play_st_err = dbg_play_pkt_err = dbg_fifo_empty = dbg_cap_pkt_err = 0;
    dbg_min_margin = 1 << 30; dbg_enq_err_code = 0;
    dbg_enq_ok = dbg_completions = dbg_double_done = dbg_reuse_pending = 0;
    memset(dbg_slot_pending, 0, sizeof dbg_slot_pending);

    atomic_store(&g_io_running, true);
    g_cap_frame = [g_dev frameNumberWithTime:NULL] + 32;
    for (int i = 0; i < CAP_NXF; i++) cap_submit(i);

    LOG("Streaming started on Rane SL 2 (%.0f Hz)", g_sr);
    return true;
}

static void usb_stop_streaming(void) {
    if (!atomic_exchange(&g_io_running, false)) return;
    hb_stop();
    {   /* DEBUG: this stream's timing histograms */
        const uint32_t *m = dbg_margin_hist, *c = dbg_capdelay_hist;
        LOG("DBG hist play margin (frames) <0:%u 0:%u 1:%u 2:%u 3:%u 4:%u 5:%u >=6:%u | "
            "capture delivery <1ms:%u <2:%u <3:%u <5:%u <10:%u <20:%u >=20:%u | skipped %u ms",
            m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], c[0], c[1], c[2], c[3], c[4], c[5], c[6], dbg_skipped_ms);
    }
    if (g_cpipe) [g_cpipe abortWithError:nil];
    if (g_ppipe) [g_ppipe abortWithError:nil];
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
            if (cd && CFGetTypeID(cd) == CFDataGetTypeID() && CFDataGetLength(cd) >= 6 &&
                CFDataGetBytePtr(cd)[0] == 0xF0) {
                /* DEBUG (temporary): set the playback queue size for the next stream; not sent to the box */
                int n = CFDataGetBytePtr(cd)[5];
                if (n < 2) n = 2;
                if (n > PLAY_NXF) n = PLAY_NXF;
                atomic_store(&g_play_nxf, n);
                LOG("DBG playback queue set to %d transfers", n);
                return 0;
            }
            if (cd && CFGetTypeID(cd) == CFDataGetTypeID() && CFDataGetLength(cd) >= 6 &&
                CFDataGetBytePtr(cd)[0] == 0xF2) {
                /* DEBUG (temporary): input safety offset in ms; tell the HAL so it re-reads it */
                int ms = CFDataGetBytePtr(cd)[5];
                if (ms < 1) ms = 1;
                atomic_store(&g_in_safety_ms, ms);
                LOG("DBG input safety offset set to %d ms (%u frames)", ms, in_safety_frames());
                /* the HAL caches the safety offset; a (no-op) configuration change makes it re-read
                   the device's properties */
                if (g_host) g_host->RequestDeviceConfigurationChange(g_host, kObjDevice, (UInt64)g_sr, NULL);
                return 0;
            }
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
        for (UInt32 f = 0; f < frames; f++) {
            uint32_t idx = ((uint32_t)((pos + f) & RING_MASK)) * NCH;
            for (int c = 0; c < NCH; c++) {
                g_out_ring[idx + c] = buf[f * NCH + c];
            }
        }
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
