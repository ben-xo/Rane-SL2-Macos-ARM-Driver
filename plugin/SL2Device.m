/*
 * SL2Device.m — Complete Self-Contained CoreAudio HAL Driver for Rane SL 2
 *
 * Drives the Rane SL 2 USB 2.0 DJ audio interface directly from inside the
 * CoreAudio HAL plugin (coreaudiod) using Apple's modern IOUSBHost framework.
 * No external daemon, no kernel extension, no root helper required.
 *
 * Capabilities:
 *   - 4-channel 24-bit (32-bit container) / 44.1 & 48 kHz Isochronous USB Audio
 *   - Low-latency playback: transfers queued 128 ms ahead, audio written into them shortly
 *     before they play; packet sizes predicted from the box's clock and steered to match capture
 *     (docs/SL2-AUDIO-ENGINE.md)
 *   - Automatic USB Audio / Analog Thru switching on StartIO / StopIO (HID 0x41)
 *   - Full HID Command/Response + Unsolicited Report Queue ('sl2h', 'sl2s', 'sl2q')
 *     for Serato DJ Pro (SL2Api.framework) and Control Panel
 *   - Automatic USB Hotplug detection (plug / unplug at any time): the device is listed only
 *     while a box is attached, and the decks are put on analogue thru when it connects
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
#define CAP_PKTS     8       /* 1 ms per transfer */
#define CAP_NXF      64
#define PLAY_PKTS    8       /* 1 ms per transfer */
#define RING_FRAMES  65536   /* ~1.36s @ 48kHz */
#define RING_MASK    (RING_FRAMES - 1)

/* Custom CoreAudio Property Selectors */
#define kSL2PropHIDCommand  'sl2h'   /* CFDataRef (64B cmd in -> 64B reply out) */
#define kSL2PropStatus      'sl2s'   /* CFDataRef (SL2StatusPacket out) */
#define kSL2PropUnsolQueue  'sl2q'   /* CFDataRef (this client's queued 64B reports, oldest first) */

/* The box's HID protocol (docs/SL2-COMMANDS.md). Every command and reply is one 64-byte report:
   [0] = command, [1..4] = tag (echoed in the reply), [5..] = arguments / results. */
enum {
    HID_REPORT_LEN         = 64,
    HID_MAX_ARGS           = HID_REPORT_LEN - 5,
    SL2_CMD_VERSION        = 0x01,   /* reply [5] major, [6] minor, [7..10] build stamp */
    SL2_CMD_EEPROM_WRITE   = 0x02,   /* refused (0xFF, stale tag) unless 0x17 enabled it */
    SL2_CMD_NO_REPLY       = 0x06,   /* the box sends no reply */
    SL2_CMD_PORT_SPEED     = 0x0a,   /* reply [5]: 0 unconfigured, 1 full speed, 2 high speed */
    SL2_CMD_SET_RATE       = 0x31,   /* [5..6] rate, big-endian: 44100 or 48000 */
    SL2_CMD_REPORTS        = 0x36,   /* [5] non-zero: send unsolicited 0x40 reports */
    SL2_CMD_CHALLENGE      = 0x37,   /* [5..12] challenge -> reply [5..12] response */
    SL2_CMD_HIDI           = 0x41,   /* [5] length, [6..] MIDI-style messages */
    SL2_CMD_PORT_STATUS    = 0x45,   /* reply [5..6], always 00 00 on the SL 2 */
    SL2_REPORT_HIDI        = 0x40,   /* the box's only unsolicited report: [5] length, [6..] messages */
    SL2_REJECTED           = 0xFF,   /* reply to a command the box refuses */
    SL2_NOTE_THRU_DECK1    = 0x5C,   /* Note On = analogue thru, Note Off = USB audio */
    SL2_NOTE_THRU_DECK2    = 0x5D,
    SL2_NOTE_PC7           = 0x60,   /* board input PC7 (not traced) */
    SL2_NOTE_LINE_PHONO    = 0x61,   /* the one LINE/PHONO switch: On = phono (reported only) */
    /* Reports the driver makes itself (not from the box), queued for clients like the box's: */
    SL2_EVT_SAMPLE_RATE    = 0x4F,   /* [5..7] rate, big-endian */
};

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
   "DBG" log lines) and the 'sl2h' debug commands 0xF2-0xF4 (input safety offset and test hooks,
   handled by the driver and never sent to the box; see dbg_command). A release build compiles
   none of it, and refuses every 'sl2h' command from 0xF0 up. */
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

#if SL2_DEBUG
/* Debug-only state. The counters and histograms describe one stream: dbg_reset clears them when
   it starts. The test hooks are set by the 'sl2h' debug commands (dbg_command). */
static uint32_t dbg_capdelay_hist[24];   /* capture handler time - bus start of its frame: 0.5 ms bins from -2 ms */
static double   dbg_capdelay_min, dbg_capdelay_max, dbg_capstamp_min, dbg_capstamp_max;
static uint32_t dbg_cap_pkt_err;         /* capture packets dropped: error status or impossible length */
static _Atomic uint32_t dbg_dp_written, dbg_dp_late, dbg_dp_unscheduled;   /* WriteMix samples, IO thread */
/* The HAL's WriteMix calling pattern (see SL2_DoIOOperation): thread switches, concurrent calls,
   and samples written to positions already written */
static _Atomic uint32_t dbg_wm_thread_switches, dbg_wm_concurrent, dbg_wm_rewritten;
static _Atomic uint64_t dbg_wm_last_thread, dbg_wm_high;
static uint32_t dbg_dp_enq_fail, dbg_dp_resync, dbg_dp_retry_later, dbg_dp_n;   /* deep schedule, g_q */
static double   dbg_dp_err_max;
/* Test hooks */
static _Atomic uint32_t dbg_stall_ms;      /* 0xF3: hold the USB queue (g_q) this many ms, once */
static _Atomic uint32_t dbg_err_pkts;      /* 0xF4: treat this many more capture packets as errored */

static void dbg_reset(void) {
    memset(dbg_capdelay_hist, 0, sizeof dbg_capdelay_hist);
    dbg_capdelay_min = dbg_capstamp_min = 1e9; dbg_capdelay_max = dbg_capstamp_max = -1e9;
    dbg_cap_pkt_err = 0;
    dbg_dp_written = dbg_dp_late = dbg_dp_unscheduled = 0;
    dbg_wm_thread_switches = dbg_wm_concurrent = dbg_wm_rewritten = 0;
    dbg_wm_last_thread = dbg_wm_high = 0;
    dbg_dp_enq_fail = dbg_dp_resync = dbg_dp_retry_later = dbg_dp_n = 0;
    dbg_dp_err_max = 0;
}

/* Test hook 0xF4: true if this capture packet should be treated as errored. */
static bool dbg_take_err_pkt(void) {
    uint32_t n = atomic_load(&dbg_err_pkts);
    while (n > 0 && !atomic_compare_exchange_weak(&dbg_err_pkts, &n, n - 1)) {}
    return n > 0;
}
#endif

static AudioServerPlugInHostRef g_host = NULL;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_hid_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_hout_mtx = PTHREAD_MUTEX_INITIALIZER;   /* writes to the HID OUT pipe */
static pthread_mutex_t g_unsol_mtx = PTHREAD_MUTEX_INITIALIZER;

static Float64  g_sr = 44100.0;
static UInt32   g_io_clients = 0;
static _Atomic bool g_io_running = false;
/* Stream generation: bumped when a stream starts and when it stops. Every USB completion and
   retry carries the generation it was queued in and does nothing once it has moved on, so work
   left over from a stopped stream can never touch the next one. */
static _Atomic uint32_t g_stream_gen = 0;
static bool stream_live(uint32_t gen) {
    return atomic_load(&g_io_running) && atomic_load(&g_stream_gen) == gen;
}
static _Atomic bool g_hw_connected = false;
static _Atomic bool g_boot_mode = false;     /* a bootloader-mode box (no firmware) is attached */
static _Atomic bool g_box_present = false;   /* a box with running firmware is attached */
static uint32_t g_ref_count = 0;

/* Capture ring buffer (Float32 interleaved, NCH channels), indexed by timeline position */
static float g_in_ring[RING_FRAMES * NCH];

/* The HAL's timeline (GetZeroTimeStamp), as a line: sample g_clk_sample at host time g_clk_host,
   advancing one sample every g_clk_tpf host ticks. It starts at sample 0 when streaming starts and
   must never jump (the HAL resets its clock if its timestamps fall off the line), but it must
   follow the box's own clock, or playback, which runs at the box's rate, drifts against it.
   So every CLK_FIX_FRAMES captured frames, clk_track re-anchors the line where it is (keeping it
   continuous) and sets its rate to the box's measured rate plus a correction that pulls the line
   onto the box's actual frame count over CLK_CORR_S seconds. clk_track (g_q) writes it while
   streaming and clk_reset (HAL threads, with streaming stopped) restarts it; GetZeroTimeStamp (the
   HAL's IO thread) reads it, so it is published under a sequence lock.

   Capture begins some milliseconds after the timeline starts: the first captured frame sits at
   the timeline position matching its arrival (g_cap_base), and the box's rate is measured from
   that frame's time (g_rate_anchor). These and g_clk_last_fix are touched only on g_q. */
#define CLK_FIX_FRAMES 2048
/* GetZeroTimeStamp's period: AudioServerPlugIn.h requires at least 10923 frames (Apple's sample
   drivers use 16384). Unrelated to CLK_FIX_FRAMES: the timeline itself is a continuous line. */
#define ZTS_PERIOD_FRAMES 16384
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
   preempted mid-update, after 64 tries use the last copy any reader got rather than spin. (That
   copy is a plain static, not thread-local: thread-local storage in a loaded bundle can allocate
   on first use, which the real-time IO thread must not do. A torn fallback is harmless: it is
   only used in that rare case, and the line it describes moves by a fraction of a frame.) */
static _Atomic uint64_t g_clk_last_h;
static _Atomic double   g_clk_last_s, g_clk_last_tpf;
static void clk_get(uint64_t *host, double *sample, double *tpf) {
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = atomic_load_explicit(&g_clk_seq, memory_order_acquire);
        uint64_t h = g_clk_host; double s = g_clk_sample, t = g_clk_tpf;
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&g_clk_seq, memory_order_relaxed);
        if (!(s1 & 1) && s1 == s2) {
            *host = h; *sample = s; *tpf = t;
            atomic_store_explicit(&g_clk_last_h, h, memory_order_relaxed);
            atomic_store_explicit(&g_clk_last_s, s, memory_order_relaxed);
            atomic_store_explicit(&g_clk_last_tpf, t, memory_order_relaxed);
            return;
        }
    }
    *host = atomic_load_explicit(&g_clk_last_h, memory_order_relaxed);
    *sample = atomic_load_explicit(&g_clk_last_s, memory_order_relaxed);
    double t = atomic_load_explicit(&g_clk_last_tpf, memory_order_relaxed);
    *tpf = t > 0 ? t : nominal_tpf();
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
static _Atomic uint32_t g_seq = 1;   /* the tag of the next HID command (hid_cmd) */
static dispatch_semaphore_t g_hid_sem;
/* The command hid_cmd is waiting for a reply to (g_hid_mtx serialises commands; hid_read on g_q
   fills the reply and signals g_hid_sem) */
static _Atomic bool g_waiting = false;
static uint8_t  g_wait_cmd = 0;
static uint32_t g_wait_seq = 0;
static uint8_t  g_reply_buf[HID_REPORT_LEN];
static SL2StatusPacket g_st;


/* Reports for clients (see unsol_push) */
#define UNSOL_Q_MAX   256
#define UNSOL_READERS 16
typedef struct { bool used; pid_t pid; uint64_t cursor; uint64_t last; } UnsolReader;
static uint8_t  g_unsol_q[UNSOL_Q_MAX][HID_REPORT_LEN];
static uint64_t g_unsol_w = 0;
static UnsolReader g_unsol_readers[UNSOL_READERS];

/* 'sl2h': the last reply for each client process, returned (once) by its next read */
#define HID_CLIENTS 16
typedef struct { bool used, pending; pid_t pid; uint8_t reply[HID_REPORT_LEN]; uint64_t last; } HidClientReply;
static HidClientReply g_hid_replies[HID_CLIENTS];

/* IOKit Hotplug watcher */
static IONotificationPortRef g_notify_port = NULL;
static io_iterator_t g_added_iter = 0;
static io_iterator_t g_removed_iter = 0;

/* Reports for clients ('sl2q'): the box's unsolicited reports and the driver's own events, kept in
   a ring with a running count. Every client process reading 'sl2q' has its own read position,
   so each one gets every report (as Rane's driver delivers each report to every client); a client
   that falls more than UNSOL_Q_MAX behind skips to the oldest still kept. */
static void unsol_push(const uint8_t pkt[HID_REPORT_LEN]) {
    pthread_mutex_lock(&g_unsol_mtx);
    memcpy(g_unsol_q[g_unsol_w % UNSOL_Q_MAX], pkt, HID_REPORT_LEN);
    g_unsol_w++;
    pthread_mutex_unlock(&g_unsol_mtx);
}

/* The read position of client process pid (registered at its first read, from now on). */
static uint64_t *unsol_cursor(pid_t pid) {
    int oldest = 0;
    for (int i = 0; i < UNSOL_READERS; i++) {
        if (g_unsol_readers[i].pid == pid && g_unsol_readers[i].used) {
            g_unsol_readers[i].last = mach_absolute_time();
            return &g_unsol_readers[i].cursor;
        }
        if (!g_unsol_readers[i].used || g_unsol_readers[i].last < g_unsol_readers[oldest].last) oldest = i;
    }
    g_unsol_readers[oldest] = (UnsolReader){ .used = true, .pid = pid, .cursor = g_unsol_w, .last = mach_absolute_time() };
    return &g_unsol_readers[oldest].cursor;
}

static void push_sr_unsol(int sr) {
    uint8_t pkt[HID_REPORT_LEN] = {0};
    pkt[0] = SL2_EVT_SAMPLE_RATE;
    pkt[5] = (uint8_t)((sr >> 16) & 0xFF);
    pkt[6] = (uint8_t)((sr >> 8) & 0xFF);
    pkt[7] = (uint8_t)(sr & 0xFF);
    unsol_push(pkt);
}

/* ============================================================================
 * USB & HID Engine
 * ============================================================================ */

/* Keep one read queued on the HID IN pipe (runs on g_q). Each report is either the reply hid_cmd
   is waiting for, or an unsolicited report from the box,
   which updates the status and is queued for clients. */
static void hid_read(void) {
    if (!g_hpipe_in || !g_hbuf_in) return;
    [g_hpipe_in enqueueIORequestWithData:g_hbuf_in completionTimeout:0 error:nil completionHandler:^(IOReturn s, NSUInteger n) {
        if (s == kIOReturnSuccess && n > 0) {
            const uint8_t *b = g_hbuf_in.bytes;
            uint32_t rseq = 0;
            memcpy(&rseq, b + 1, 4);

            /* The awaited reply: its command (or a rejection) with its tag. A refused EEPROM write
               carries a stale tag, so for that one any rejection is the answer. */
            bool reply = atomic_load(&g_waiting) &&
                         ((b[0] == g_wait_cmd && rseq == g_wait_seq) ||
                          (b[0] == SL2_REJECTED && (rseq == g_wait_seq || g_wait_cmd == SL2_CMD_EEPROM_WRITE)));
            if (reply) {
                memcpy(g_reply_buf, b, HID_REPORT_LEN);
                atomic_store(&g_waiting, false);
                dispatch_semaphore_signal(g_hid_sem);

            /* An unsolicited report: note thru and switch state, and queue it for clients. */
            } else if (b[0] == SL2_REPORT_HIDI) {
                uint8_t len = b[5] > HID_MAX_ARGS - 1 ? HID_MAX_ARGS - 1 : b[5];
                for (uint8_t i = 0; i + 2 < len; i += 3) {
                    uint8_t st = b[6 + i], note = b[6 + i + 1];   /* [6 + i + 2], the velocity, is always 0x40 */
                    int on = ((st & 0xF0) == 0x90) ? 1 : 0;
                    if (note == SL2_NOTE_THRU_DECK1 || note == SL2_NOTE_THRU_DECK2) {
                        g_st.thru[note - SL2_NOTE_THRU_DECK1] = on;
                    } else if (note == SL2_NOTE_LINE_PHONO) {
                        /* the box's one LINE/PHONO switch (firmware input PE0), shared by both decks */
                        g_st.phono[0] = g_st.phono[1] = on;
                    }
                }
                unsol_push(b);
            }
            /* Anything else is a reply that came after hid_cmd gave up: not for clients. */
        }
        if (s != kIOReturnAborted && g_hpipe_in) hid_read();
    }];
}

/* Send a command and wait up to 150 ms for its reply. Every command gets one except
   SL2_CMD_NO_REPLY. The driver always tags the request with its own sequence number (so a reply can
   never be confused with another's); client_tag, if given, is put back into
   the reply returned. True if the box answered and accepted the command; reply_out then holds the
   reply, and holds the rejection (0xFF) if it refused it. */
static bool hid_cmd(uint8_t cmd, const uint8_t *pl, size_t plen, uint8_t *reply_out, const uint8_t *client_tag) {
    if (!g_hpipe_out || !g_hid_sem) return false;
    pthread_mutex_lock(&g_hid_mtx);
    while (dispatch_semaphore_wait(g_hid_sem, DISPATCH_TIME_NOW) == 0) {}   /* drop a late signal */

    /* Build the request. */
    uint8_t buf[HID_REPORT_LEN] = {0};
    buf[0] = cmd;
    uint32_t seq = g_seq++;
    memcpy(buf + 1, &seq, 4);
    if (pl && plen > 0) memcpy(buf + 5, pl, plen > HID_MAX_ARGS ? HID_MAX_ARGS : plen);
    bool wait = cmd != SL2_CMD_NO_REPLY;
    g_wait_cmd = cmd;
    g_wait_seq = seq;
    atomic_store(&g_waiting, wait);

    /* Send it. */
    NSMutableData *d = [NSMutableData dataWithBytes:buf length:HID_REPORT_LEN];
    NSUInteger sent = 0;
    NSError *e = nil;
    pthread_mutex_lock(&g_hout_mtx);
    BOOL ok = [g_hpipe_out sendIORequestWithData:d bytesTransferred:&sent completionTimeout:0 error:&e];
    pthread_mutex_unlock(&g_hout_mtx);
    if (!ok) {
        atomic_store(&g_waiting, false);
        pthread_mutex_unlock(&g_hid_mtx);
        return false;
    }

    /* Wait for the reply. */
    bool accepted = true;
    if (wait) {
        if (dispatch_semaphore_wait(g_hid_sem, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC)) == 0) {
            if (reply_out) memcpy(reply_out, g_reply_buf, HID_REPORT_LEN);
            accepted = g_reply_buf[0] != SL2_REJECTED;
        } else {
            atomic_store(&g_waiting, false);
            accepted = false;
            if (reply_out) memset(reply_out, 0, HID_REPORT_LEN);
        }
    } else if (reply_out) {
        memset(reply_out, 0, HID_REPORT_LEN);
        reply_out[0] = cmd;
        memcpy(reply_out + 1, &seq, 4);
    }
    if (reply_out && client_tag) memcpy(reply_out + 1, client_tag, 4);
    pthread_mutex_unlock(&g_hid_mtx);
    return accepted;
}

static void refresh_hw_status(void) {
    /* Firmware version via HID command 0x01, as Rane's SL2Api reads it
       (SendHidRequest(dev, 0x01, ...) -> reply[5]=major, reply[6]=minor, 32-bit build stamp at
       reply[7..10]); c.f. the SL3, which uses 0x10. bcdDevice is only a mode marker
       (0x0100 = running firmware, 0x0000 = bootloader), not the version. */
    uint8_t r[64];
    for (int attempt = 0; attempt < 2; attempt++) {   /* the box may still be loading its FPGA */
        if (hid_cmd(SL2_CMD_VERSION, NULL, 0, r, NULL)) {
            g_st.version_maj = r[5];
            g_st.version_min = r[6];
            break;
        }
    }
    /* USB speed (0x0a: 1 = full speed, 2 = high speed). At full speed the box offers only its HID
       interface, so there is no audio: say so, as the only other sign is a failed stream start. */
    if (hid_cmd(SL2_CMD_PORT_SPEED, NULL, 0, r, NULL) && r[5] == 1)
        LOG("The SL 2 is on a full-speed (USB 1.1) link: no audio. Connect it to a USB 2.0 high-speed port.");
    /* Serial from the USB iSerialNumber string ("SL2.01.00"), a fixed device serial independent
       of the firmware version; c.f. the SL3, which queries it over HID 0x04. */
    CFTypeRef ser = IORegistryEntryCreateCFProperty(g_dev.ioService, CFSTR("USB Serial Number"), kCFAllocatorDefault, 0);
    if (ser) {
        if (CFGetTypeID(ser) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)ser, (char *)g_st.serial, sizeof g_st.serial, kCFStringEncodingUTF8);
        CFRelease(ser);
    }
    uint8_t req_ports[1] = {0};
    if (hid_cmd(SL2_CMD_PORT_STATUS, req_ports, 1, r, NULL)) {
        g_st.port_a = r[5];
        g_st.port_b = r[6];
    }
    /* Switch and thru state arrive as unsolicited 0x40 reports (parsed in hid_read), which the box
       sends only once 0x36 has enabled them. Then ask for a state dump (0x41 SysEx F0 17 04 F7),
       so the LINE/PHONO switch is known before it is first moved. */
    uint8_t enable[1] = { 1 };
    hid_cmd(SL2_CMD_REPORTS, enable, 1, NULL, NULL);
    uint8_t dump[5] = { 4, 0xF0, 0x17, 0x04, 0xF7 };
    hid_cmd(SL2_CMD_HIDI, dump, 5, NULL, NULL);
}

static void send_hw_samplerate(int sr) {
    uint8_t pl[2] = { (uint8_t)((sr >> 8) & 0xFF), (uint8_t)(sr & 0xFF) };
    hid_cmd(SL2_CMD_SET_RATE, pl, 2, NULL, NULL);
    push_sr_unsol(sr);
}

/* Switch both decks to USB audio (Note Off) or analogue thru (Note On), notes 0x5C / 0x5D through
   0x41. The box confirms each change with its own 0x40 report, which reaches clients. */
static void set_usb_switches(bool usb_mode) {
    uint8_t status_byte = usb_mode ? 0x80 : 0x90;
    for (int i = 0; i < 2; i++) {
        uint8_t pl[4] = { 0x03, status_byte, (uint8_t)(SL2_NOTE_THRU_DECK1 + i), 0x00 };
        hid_cmd(SL2_CMD_HIDI, pl, 4, NULL, NULL);
        g_st.thru[i] = usb_mode ? 0 : 1;
    }
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
 * Timeline clock: following the box's clock (clk_first_capture, clk_track)
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



/* ============================================================================
 * Deep-schedule playback
 *
 * USB completions can be delivered 5-30 ms late (the delay is in the USB stack, before any
 * thread is woken, so no thread priority fixes it). So rather than filling each playback
 * transfer when an earlier one completes, DP_SLOTS 1 ms transfers are kept queued ahead,
 * zero-filled, and the HAL's IO thread (WriteMix) writes each sample straight into the queued
 * transfer that will carry it, shortly before that transfer starts. This works because the
 * controller reads a transfer's buffer when the transfer starts: audio written into a queued
 * ioDataWithCapacity: buffer before then is what gets sent. Completions only queue new transfers
 * at the far end of the schedule, so a stall in completion delivery does not interrupt the audio
 * unless it outlasts the queue: about 120 ms at small IO buffers (the 128 ms queued, less how far
 * ahead the HAL writes: about two IO buffers plus the safety offset).
 *
 * Each queued USB frame carries a contiguous run of HAL timeline positions, published in
 * g_dp_sched (indexed by frame number) for the IO thread to look up. When the schedule is
 * anchored (dp_anchor), its first frame carries the position DP_OUT_LATENCY_MS before that
 * frame's start time; because the packet sizes follow the box's clock, every sample then plays
 * DP_OUT_LATENCY_MS after its timeline position. The HAL writes each sample DP_OUT_SAFETY_MS
 * ahead of "now". Together (3.5 ms) they cover the up-to-1 ms span of positions within a frame
 * plus DP_WRITE_GUARD_FRAMES (1 ms), leaving 1.5 ms of margin for a late IO thread.
 *
 * Packet sizes are fixed when a transfer is queued, ~DP_SLOTS ms before it plays, so they cannot
 * be copied from the matching capture packets (implicit feedback). They are predicted from the
 * box's measured rate and steered (dp_track_capture) so that the frames sent through each USB
 * frame track the frames the box captured through it. A frame whose enqueue is refused is not
 * sent: its positions move to the next frame (the audio stays continuous) and it does not count
 * as sent, so the steering makes up the frames the box missed.
 * ============================================================================ */
#define DP_SLOTS       128         /* transfers kept queued: 128 ms, covering both how far ahead the HAL
                                      writes (~2 IO buffers + safety) and completion stalls */
#define DP_SCHED_N     512         /* schedule ring entries: power of two, >= 2 x (DP_SLOTS + HAL lead) */
#define DP_START_LEAD  8           /* (re)anchor this many frames ahead of the bus (a transfer only
                                      4 frames ahead can be refused: 0xe00002ee) */
#define DP_DRY_LEAD    4           /* the schedule counts as run dry when it reaches less than this far ahead */
#define DP_CORR_S      1.0         /* sent-vs-captured frame difference is removed over this many seconds */
#define DP_WRITE_GUARD_FRAMES 1.0  /* a frame is written only if it starts at least this many USB frames
                                      (1 ms each) from now */
#define DP_TRIES       4           /* enqueue attempts per call before retrying the slot later */

typedef struct {
    _Atomic uint64_t frame;        /* USB frame this entry describes, 0 = none (seqlock tag) */
    uint64_t first;                /* timeline position of the frame's first sample */
    uint64_t sent_cum;             /* frames queued from the anchor through this frame */
    uint16_t off[PLAY_PKTS + 1];   /* sample offset of each packet in the frame; [PLAY_PKTS] = total */
    uint8_t *buf;                  /* the frame's transfer buffer */
} DPEntry;

/* Shared with WriteMix (the HAL's IO thread): the schedule ring (a seqlock per entry), the
   transfer buffers it points into, and atomics. Allocated and released by usb_open_all /
   usb_release_audio, written by dp_submit on g_q. */
static DPEntry        g_dp_sched[DP_SCHED_N];
static NSMutableData *g_dp_data[DP_SLOTS];
static uint8_t       *g_dp_ptr[DP_SLOTS];
static _Atomic bool     g_dp_active;          /* WriteMix writes into the schedule */
static _Atomic int      g_dp_writers;         /* WriteMix calls currently inside dp_write */
static _Atomic uint64_t g_dp_x0, g_dp_F0;     /* current anchor: first position / frame */
static _Atomic uint64_t g_dp_newest;          /* newest published frame: where WriteMix starts looking */

/* The schedule's bookkeeping, used only on g_q (reset by usb_open_all before capture starts). */
static IOUSBHostIsochronousTransaction g_dp_tx[DP_SLOTS][PLAY_PKTS];
static bool     g_dp_started;
static uint64_t g_dp_next_frame, g_dp_next_pos, g_dp_sent_cum, g_dp_in_cum;
static double   g_dp_acc, g_dp_err;

/* The USB frame clock: microframe g_dp_ref_uframe is associated with host time g_dp_ref_time.
   Written by dp_ref_refresh (g_q, or usb_open_all before streaming), read on any thread through
   dp_ref_get (seqlock). */
static _Atomic uint32_t g_dp_ref_seq;
static uint64_t g_dp_ref_uframe, g_dp_ref_time, g_dp_last_refresh;

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
   writer: after 64 tries it uses the last copy any reader got (a plain static: see clk_get). */
static _Atomic uint64_t g_dp_ref_last_uf, g_dp_ref_last_ut;
static void dp_ref_get(uint64_t *uf, uint64_t *ut) {
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = atomic_load_explicit(&g_dp_ref_seq, memory_order_acquire);
        uint64_t a = g_dp_ref_uframe, b = g_dp_ref_time;
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&g_dp_ref_seq, memory_order_relaxed);
        if (!(s1 & 1) && s1 == s2) {
            *uf = a; *ut = b;
            atomic_store_explicit(&g_dp_ref_last_uf, a, memory_order_relaxed);
            atomic_store_explicit(&g_dp_ref_last_ut, b, memory_order_relaxed);
            return;
        }
    }
    *uf = atomic_load_explicit(&g_dp_ref_last_uf, memory_order_relaxed);
    *ut = atomic_load_explicit(&g_dp_ref_last_ut, memory_order_relaxed);
}

/* USB frame (1 ms, fractional) at host time t. Safe on any thread. */
static double dp_frame_at(uint64_t t) {
    uint64_t uf, ut;
    dp_ref_get(&uf, &ut);
    return ((double)uf + ((double)t - (double)ut) / (ticks_per_ms() / 8.0)) / 8.0;
}

/* Host time at which (fractional) USB frame usb_frame starts on the bus; the inverse of
   dp_frame_at. A packet k of a frame starts k / 8 frames in (a microframe is 1/8 ms). */
static uint64_t usb_frame_time(double usb_frame) {
    uint64_t uf, ut;
    dp_ref_get(&uf, &ut);
    return (uint64_t)((double)ut + (8.0 * usb_frame - (double)uf) * (ticks_per_ms() / 8.0));
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
    double x0 = clk_sample_at(usb_frame_time((double)F)) - DP_OUT_LATENCY_MS * g_sr / 1000.0;
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
static void dp_submit(int slot, uint32_t gen) {
    for (int attempt = 0; attempt < DP_TRIES; attempt++) {
        if (!stream_live(gen) || !g_ppipe || !g_dp_ptr[slot]) return;
        if ((double)(mach_absolute_time() - g_dp_last_refresh) > 0.5 * ticks_per_ms()) dp_ref_refresh();
        uint64_t now_f = (uint64_t)dp_frame_at(mach_absolute_time());
        if (g_dp_next_frame < now_f + DP_DRY_LEAD) {
            /* The schedule has (almost) run dry: under DP_DRY_LEAD frames ahead of the bus, after
               a completion stall of nearly DP_SLOTS ms (or repeated refusals). Re-anchor ahead. */
            dp_anchor(now_f + DP_START_LEAD);
            DBG_DO(dbg_dp_resync++);
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
            if (stream_live(gen) && st != kIOReturnAborted && !dp_gone(st)) dp_submit(slot, gen);
        }];
        if (ok) {
            g_dp_next_pos += off;
            g_dp_sent_cum += off;
            e->sent_cum = g_dp_sent_cum;
            atomic_fetch_add_explicit(&g_total_play_frames, off, memory_order_relaxed);   /* status packet */
            atomic_store_explicit(&e->frame, f, memory_order_release);   /* publish */
            atomic_store_explicit(&g_dp_newest, f, memory_order_release);
            return;
        }
        /* Refused: nothing is published, and the next frame carries these positions instead. */
        DBG_DO(dbg_dp_enq_fail++);
        DBG_LOG("DBG dp enqueue refused for frame %llu (now ~%llu): %{public}@", f, now_f, err.localizedDescription);
    }
    /* Still refused: try this slot again shortly rather than losing it from the schedule. */
    DBG_DO(dbg_dp_retry_later++);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC), g_q, ^{ dp_submit(slot, gen); });
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

static void dp_start(uint32_t gen) {
    if (!stream_live(gen)) return;
    dp_ref_refresh();
#if SL2_DEBUG   /* check frameNumberWithTime: and the microframe reference agree */
    IOUSBHostTime t = 0;
    uint64_t fn = [g_dev frameNumberWithTime:&t];
    DBG_LOG("DBG frameNumber %llu vs microframe estimate %.2f", fn, dp_frame_at(t));
#endif
    dp_anchor((uint64_t)dp_frame_at(mach_absolute_time()) + DP_START_LEAD);
    atomic_store_explicit(&g_dp_active, true, memory_order_release);
    for (int i = 0; i < DP_SLOTS; i++) dp_submit(i, gen);
    g_dp_started = true;
    LOG("Deep-schedule playback started at frame %llu, %d x 1 ms queued, output latency %.1f + safety %.1f ms",
        atomic_load(&g_dp_F0), DP_SLOTS, DP_OUT_LATENCY_MS, DP_OUT_SAFETY_MS);
}

/* A capture completion for USB frame fc placed `frames` frames: everything the box clocked since
   the previous one, silence-filled frames included. Steer the predicted OUT sizes so that the frames sent through each USB frame
   track the frames the box captured through it. */
static void dp_track_capture(uint64_t fc, int frames) {
    if (!g_dp_started || fc < atomic_load(&g_dp_F0)) return;
    g_dp_in_cum += frames;
    DPEntry *e = &g_dp_sched[fc & (DP_SCHED_N - 1)];
    if (atomic_load_explicit(&e->frame, memory_order_acquire) != fc) return;   /* not sent */
    g_dp_err = (double)e->sent_cum - (double)g_dp_in_cum;
#if SL2_DEBUG   /* the deep schedule's health, every ~2 s */
    if (fabs(g_dp_err) > dbg_dp_err_max) dbg_dp_err_max = fabs(g_dp_err);
    if (++dbg_dp_n % 2000 == 0)
        DBG_LOG("DBG dp: sent-captured %.1f frames (max %.1f) | written %u, late %u, unscheduled %u | "
            "enqueue refused %u, retried later %u, resyncs %u | WriteMix thread switches %u, concurrent %u, "
            "rewritten samples %u | capture packet errors %u",
            g_dp_err, dbg_dp_err_max, atomic_load(&dbg_dp_written), atomic_load(&dbg_dp_late),
            atomic_load(&dbg_dp_unscheduled), dbg_dp_enq_fail, dbg_dp_retry_later, dbg_dp_resync,
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
            DBG_DO(atomic_fetch_add_explicit(&dbg_dp_unscheduled, skip, memory_order_relaxed));
            i += skip;
            continue;
        }
        hint_frame = (uint64_t)fg; hint_first = first;
        uint32_t n = (uint32_t)(first + off[PLAY_PKTS] - p);
        if (n > frames - i) n = frames - i;
        if ((double)fg - now_f < DP_WRITE_GUARD_FRAMES) {
            DBG_DO(atomic_fetch_add_explicit(&dbg_dp_late, n, memory_order_relaxed));
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
            DBG_DO(atomic_fetch_add_explicit(&dbg_dp_written, n, memory_order_relaxed));
        }
        i += n;
    }
}

/* ============================================================================
 * Capture
 *
 * CAP_NXF 1 ms isochronous IN transfers are kept queued, each re-queued from its own completion
 * for the next free USB frame (g_cap_frame). Every captured frame goes into g_in_ring at its
 * timeline position, contiguously from the first (g_cap_base), and g_cap_head publishes how far
 * that is, so ReadInput never hands the HAL a position capture has not written.
 *
 * The box clocks a frame of audio whether or not the host receives it. When the host doesn't (an
 * errored packet, or USB frames with no capture request queued after a completion stall long
 * enough for re-queued requests to be refused), the missing frames are filled with silence and
 * counted as captured, so the ring, the clock tracker and the playback steering all keep counting
 * what the box clocked, and the audio that follows lands at its own timeline position.
 * ============================================================================ */
static uint64_t g_cap_next_fc;          /* USB frame the next capture completion should cover (g_q) */
static double   g_cap_fill_frac;        /* fraction of a frame carried between silence fills (g_q) */
static _Atomic uint64_t g_cap_head;     /* timeline position just past the last frame written to the ring */
#define CAP_VALID_SPAN (RING_FRAMES / 2)   /* ReadInput trusts positions this far behind the head */

/* Write n frames of silence into the ring from timeline position pos (at most the ring's size). */
static void cap_fill_silence(uint64_t pos, uint64_t n) {
    if (n > RING_FRAMES) { pos += n - RING_FRAMES; n = RING_FRAMES; }
    for (uint64_t i = 0; i < n; i++)
        memset(&g_in_ring[((pos + i) & RING_MASK) * NCH], 0, NCH * sizeof(float));
}

/* Audio frames the box clocks in `uframes` microframes (125 us each), at its measured rate. The
   fraction of a frame left over is carried to the next call, so successive fills add up to the
   box's real count (e.g. 5.51 frames per packet at 44.1 kHz). */
static uint64_t cap_frames_in(uint64_t uframes) {
    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    double f = (double)uframes * (ticks_per_ms() / 8.0) / tpf + g_cap_fill_frac;
    uint64_t n = (uint64_t)f;
    g_cap_fill_frac = f - (double)n;
    return n;
}

static void cap_submit(int idx, uint32_t gen);

/* A capture transfer for USB frame fc completed: put its frames in the ring, keep the clock and the
   playback steering up to date, and queue the transfer again. */
static void cap_complete(int idx, uint64_t fc, IOUSBHostIsochronousTransaction *done, uint32_t gen) {
#if SL2_DEBUG
    {   /* test hook 0xF3: hold g_q, as a stall in the USB stack's completion delivery would */
        uint32_t ms = atomic_exchange(&dbg_stall_ms, 0);
        if (ms) { DBG_LOG("DBG stalling the USB queue for %u ms", ms); usleep(ms * 1000); }
    }
#endif
    /* Times below are bus times, from the USB frame clock (dp_ref_*): a completion's own
       timeStamp is when the stack processed it, which can be many ms after the bus. */
    if ((double)(mach_absolute_time() - g_dp_last_refresh) > 0.5 * ticks_per_ms()) dp_ref_refresh();
#if SL2_DEBUG
    {   /* when this handler runs, and the stack's completion stamp, relative to the bus
           start of the transfer's frame (the transfer covers [0, 1) ms of it) */
        double start = (double)usb_frame_time((double)fc);
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
    uint64_t before = atomic_load_explicit(&g_total_cap_frames, memory_order_relaxed);   /* frames captured so far */

    /* First capture of the stream: place this transfer's first good frame on the timeline (a
       transfer with no good packet places nothing; the next one tries again). */
    if (before == 0) {
        int k = 0;
        while (k < CAP_PKTS && !(done[k].status == kIOReturnSuccess && done[k].completeCount >= FRAME_BYTES &&
                                 done[k].completeCount <= PKT_MAX)) k++;
        if (k == CAP_PKTS) { cap_submit(idx, gen); return; }
        clk_first_capture(usb_frame_time((double)fc + k / 8.0));
        g_cap_next_fc = fc;
    }
    uint64_t ring_pos = g_cap_base + before;   /* timeline position of the next frame to write */
    uint64_t got = 0;                          /* frames placed by this completion, fill included */
    uint64_t ts = 0;                           /* bus time of the first of them */

    /* USB frames between the last completion and this one carried no capture request (they were
       refused after a stall): the box clocked them anyway, so fill them with silence. */
    if (before > 0 && fc > g_cap_next_fc) {
        uint64_t missed = fc - g_cap_next_fc;
        uint64_t n = cap_frames_in(8 * missed);
        ts = usb_frame_time((double)g_cap_next_fc);
        cap_fill_silence(ring_pos, n);
        got += n;
        LOG("Capture: %llu ms not captured (USB frames %llu-%llu), filled with silence",
            missed, g_cap_next_fc, fc - 1);
    }
    g_cap_next_fc = fc + 1;

    /* Each packet: convert its frames into the ring, or fill an errored one with silence. */
    const uint8_t *b = g_cap_xf[idx].buf.bytes;
    for (int k = 0; k < CAP_PKTS; k++) {
        /* An errored packet, or an impossible length (a completion can report a completeCount far
           above the packet size, e.g. 0xFFFFFE00): the frame loop must never run past the
           112-byte packet, and the box clocked a packet's worth of frames regardless. */
        bool bad = done[k].status != kIOReturnSuccess || done[k].completeCount > PKT_MAX;
#if SL2_DEBUG
        if (!bad && dbg_take_err_pkt()) bad = true;   /* test hook 0xF4 */
#endif
        if (!ts) ts = usb_frame_time((double)fc + k / 8.0);
        if (bad) {
            DBG_DO(dbg_cap_pkt_err++);
            uint64_t n = cap_frames_in(1);
            cap_fill_silence(ring_pos + got, n);
            got += n;
            continue;
        }
        int n = done[k].completeCount / FRAME_BYTES;
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

    /* Publish the ring's new head for ReadInput, then keep the timeline on the box's clock. */
    atomic_store_explicit(&g_cap_head, ring_pos + got, memory_order_release);
    clk_track(before, (int)got, ts);

    /* Playback: start after a few ms of capture, then steer it by what the box clocked. */
    if (!g_dp_started && before >= (uint64_t)(8 * g_sr / 1000)) dp_start(gen);
    dp_track_capture(fc, (int)got);
    cap_submit(idx, gen);
}

/* Queue capture transfer idx for the next free USB frame. If the frame has already passed (after
   a completion stall), re-anchor ahead of the bus; the frames skipped are filled with silence
   when the next completion arrives. */
static void cap_submit(int idx, uint32_t gen) {
    for (int attempt = 0; attempt < DP_TRIES; attempt++) {
        if (!stream_live(gen) || !g_cpipe) return;

        /* The next free USB frame, unless that has already passed. */
        if ((double)(mach_absolute_time() - g_dp_last_refresh) > 0.5 * ticks_per_ms()) dp_ref_refresh();
        uint64_t now_f = (uint64_t)dp_frame_at(mach_absolute_time());
        if (g_cap_frame < now_f + DP_DRY_LEAD) g_cap_frame = now_f + DP_START_LEAD;
        uint64_t f = g_cap_frame++;
        g_cap_xf_frame[idx] = f;

        /* One full-size packet per microframe. */
        IOUSBHostIsochronousTransaction *tx = g_cap_xf[idx].tx;
        for (int k = 0; k < CAP_PKTS; k++)
            tx[k] = (IOUSBHostIsochronousTransaction){ .requestCount = PKT_MAX, .offset = (uint32_t)(k * PKT_MAX) };

        NSError *e = nil;
        BOOL ok = [g_cpipe enqueueIORequestWithData:g_cap_xf[idx].buf transactionList:tx
                                transactionListCount:CAP_PKTS firstFrameNumber:f
                                             options:IOUSBHostIsochronousTransferOptionsNone error:&e
                                   completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
            if (!stream_live(gen) || st == kIOReturnAborted || dp_gone(st)) return;
            cap_complete(idx, f, done, gen);
        }];
        if (ok) return;
        /* Refused (the frame passed while this ran): take the next one. */
        LOG("Capture enqueue refused for frame %llu (now ~%llu): %{public}@", f, now_f, e.localizedDescription);
        g_cap_frame = now_f + DP_START_LEAD + attempt + 1;
    }
    /* Still refused: try again shortly rather than losing this transfer for the rest of the stream. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC), g_q, ^{ cap_submit(idx, gen); });
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

/* Open the box's HID side (device, HID interface, its two pipes), if not already open. The device
   is opened once and kept: if its HID interface isn't registered yet (interfaces appear
   asynchronously after the device is configured), a later call only looks for it again. */
static bool usb_ensure_hid(void) {
    if (g_dev && g_hid && g_hpipe_in && g_hpipe_out) return true;
    NSError *e = nil;
    if (!g_q) g_q = usb_queue_create();
    if (!g_hid_sem) g_hid_sem = dispatch_semaphore_create(0);

    /* The device: open it and select configuration 1, unless already done. */
    if (!g_dev) {
        io_service_t svc = find_sl2_service();
        if (!svc) return false;
        g_dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
        IOObjectRelease(svc);
        if (!g_dev) { LOG("Failed to open IOUSBHostDevice: %{public}@", e); return false; }
    }
    if (!g_dev.configurationDescriptor) [g_dev configureWithValue:1 matchInterfaces:YES error:&e];

    /* The HID interface. */
    if (!g_hid) {
        io_iterator_t it = 0;
        IORegistryEntryGetChildIterator(g_dev.ioService, kIOServicePlane, &it);
        io_service_t ch;
        while ((ch = IOIteratorNext(it))) {
            CFNumberRef n = IORegistryEntryCreateCFProperty(ch, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
            if (n) {
                int idx = -1;
                CFNumberGetValue(n, kCFNumberIntType, &idx);
                CFRelease(n);
                if (idx == IF_HID && !g_hid)
                    g_hid = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
            }
            IOObjectRelease(ch);
        }
        IOObjectRelease(it);
        if (!g_hid) return false;
    }

    /* Its pipes; start reading the box's reports and replies, then read its status. */
    g_hpipe_out = [g_hid copyPipeWithAddress:EP_HID_OUT error:&e];
    g_hpipe_in  = [g_hid copyPipeWithAddress:EP_HID_IN error:&e];
    if (!g_hpipe_out || !g_hpipe_in) return false;
    g_hbuf_in   = [NSMutableData dataWithLength:64];
    hid_read();
    refresh_hw_status();
    atomic_store(&g_hw_connected, true);
    atomic_store(&g_boot_mode, false);
    return true;
}

/* Switch the deep schedule off and wait for any WriteMix still writing into it, after which its
   buffers can be released. */
static void dp_stop(void) {
    atomic_store_explicit(&g_dp_active, false, memory_order_seq_cst);
    while (atomic_load_explicit(&g_dp_writers, memory_order_seq_cst) > 0) usleep(50);
}

/* Release the deep schedule's transfer buffers. They hold the playback interface open, so they
   must go before the next stream claims it. Call on g_q, after the pipes are aborted. */
static void dp_release(void) {
    for (int i = 0; i < DP_SLOTS; i++) { g_dp_data[i] = nil; g_dp_ptr[i] = NULL; }
    for (int i = 0; i < DP_SCHED_N; i++) atomic_store(&g_dp_sched[i].frame, 0);
    atomic_store(&g_dp_newest, 0);
}

/* Undo whatever usb_open_all set up for the audio interfaces: abort the pipes, then release the
   buffers and pipes on g_q, so no completion handler is still using them (one that runs later
   sees the stream generation has moved on and does nothing), then put the interfaces back to
   alternate setting 0 and destroy them so the next stream can claim them. Not called on g_q. */
static void usb_release_audio(void) {
    if (g_cpipe) [g_cpipe abortWithError:nil];
    if (g_ppipe) [g_ppipe abortWithError:nil];
    if (g_q) dispatch_sync(g_q, ^{
        dp_release();
        g_cpipe = nil; g_ppipe = nil;
    });
    if (g_cap)  { [g_cap selectAlternateSetting:0 error:nil];  [g_cap destroy];  g_cap = nil; }
    if (g_play) { [g_play selectAlternateSetting:0 error:nil]; [g_play destroy]; g_play = nil; }
}

/* Start streaming: claim the audio interfaces, open their isochronous pipes, switch the decks to
   USB audio and queue the capture transfers (playback starts from the capture handler). On any
   failure, everything opened so far is released again. */
static bool usb_open_all(void) {
    if (!usb_ensure_hid()) return false;
    NSError *e = nil;

    g_dp_started = false;
    atomic_store(&g_dp_active, false);
    DBG_DO(dbg_reset());

    /* Claim the playback and capture interfaces. */
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
        usb_release_audio();
        return false;
    }

    /* Set the box's rate, select the streaming alternate settings and open the pipes. */
    send_hw_samplerate((int)g_sr);
    [g_play selectAlternateSetting:1 error:&e];
    g_ppipe = copy_isoch_pipe(g_play, kIOUSBEndpointDirectionOut, EP_PLAY, 0x02);
    [g_cap selectAlternateSetting:1 error:&e];
    g_cpipe = copy_isoch_pipe(g_cap, kIOUSBEndpointDirectionIn, EP_CAP, 0x86);
    if (!g_ppipe || !g_cpipe) {
        LOG("Failed to open Isoch pipes");
        usb_release_audio();
        return false;
    }

    /* Buffers: the playback schedule's (from the playback interface) and capture's. */
    dp_ref_refresh();   /* USB frame clock, used for bus times from the first capture on */
    if (!dp_alloc()) {
        usb_release_audio();
        return false;
    }
    for (int i = 0; i < CAP_NXF; i++) {
        if (!g_cap_xf[i].buf) g_cap_xf[i].buf = [NSMutableData dataWithLength:CAP_PKTS * PKT_MAX];
        if (!g_cap_xf[i].tx)  g_cap_xf[i].tx  = calloc(CAP_PKTS, sizeof(IOUSBHostIsochronousTransaction));
    }

    /* Decks to USB audio. */
    set_usb_switches(true);

    /* A new timeline and an empty capture ring. */
    memset(g_in_ring, 0, sizeof(g_in_ring));
    atomic_store(&g_cap_head, 0);
    g_cap_next_fc = 0;
    g_cap_fill_frac = 0;
    clk_reset();
    atomic_store(&g_total_cap_frames, 0);
    atomic_store(&g_total_play_frames, 0);

    /* A new stream generation, then queue the capture transfers. */
    uint32_t gen = atomic_fetch_add(&g_stream_gen, 1) + 1;
    atomic_store(&g_io_running, true);
    g_cap_frame = [g_dev frameNumberWithTime:NULL] + 32;
    for (int i = 0; i < CAP_NXF; i++) cap_submit(i, gen);

    LOG("Streaming started on Rane SL 2 (%.0f Hz)", g_sr);
    return true;
}

/* Stop streaming. box_attached false means the box is gone, so nothing is sent to it. */
static void usb_stop_streaming(bool box_attached) {
    dp_stop();   /* WriteMix stops touching the schedule */
    if (!atomic_exchange(&g_io_running, false)) return;
    atomic_fetch_add(&g_stream_gen, 1);   /* completions and retries of this stream now do nothing */
#if SL2_DEBUG   /* this stream's results */
    if (g_dp_started)
        DBG_LOG("DBG dp result: written %u, late %u, unscheduled %u | enqueue refused %u, resyncs %u | "
            "sent-captured now %.1f, max %.1f frames",
            atomic_load(&dbg_dp_written), atomic_load(&dbg_dp_late), atomic_load(&dbg_dp_unscheduled),
            dbg_dp_enq_fail, dbg_dp_resync, g_dp_err, dbg_dp_err_max);
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
    usb_release_audio();
    if (box_attached) {
        set_usb_switches(false);
        LOG("Streaming stopped; Analog Thru restored");
    } else {
        LOG("Streaming stopped (box disconnected)");
    }
}

/* The box is gone: stop streaming, then release the HID side (on g_q, like the audio side). */
static void usb_close_all(void) {
    usb_stop_streaming(false);
    if (g_hpipe_in)  [g_hpipe_in abortWithError:nil];
    if (g_hpipe_out) [g_hpipe_out abortWithError:nil];
    if (g_q) dispatch_sync(g_q, ^{
        pthread_mutex_lock(&g_hout_mtx);
        g_hpipe_in = nil; g_hpipe_out = nil;
        pthread_mutex_unlock(&g_hout_mtx);
    });
    if (g_hid)  { [g_hid destroy]; g_hid = nil; }
    if (g_dev)  { [g_dev destroy]; g_dev = nil; }
    atomic_store(&g_hw_connected, false);
}

/* The device is published (in the plug-in's device list, so it shows in the system's device
   lists) only while a box is attached. A box in its bootloader keeps it published so clients can
   read boot_mode from the 'sl2s' status. */
static bool device_published(void) {
    return atomic_load(&g_box_present) || atomic_load(&g_boot_mode);
}

/* Which boxes are attached now: running firmware and/or bootloader. */
static void scan_attached(bool *audio, bool *bootloader) {
    *audio = *bootloader = false;
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return;
    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        if (svc_bcd(s) == BCD_LOADER) *bootloader = true;
        else                          *audio = true;
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
}

/* Tell the HAL the device list changed (the device appeared or went away), and that the device's
   IsAlive did. */
static void notify_device_list_changed(void) {
    if (!g_host) return;
    AudioObjectPropertyAddress plug[2] = {
        { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    AudioObjectPropertyAddress alive = {
        kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    g_host->PropertiesChanged(g_host, kObjDevice, 1, &alive);
    g_host->PropertiesChanged(g_host, kObjPlugIn, 2, plug);
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

static dispatch_queue_t g_hotplug_q;

/* Open a newly attached box and, with no stream running, put its decks on analogue thru (the box
   powers up with thru on or off depending on a board input), as at stream stop, so turntables
   reach the mixer until an app streams. The first open can be refused ("exclusive open of usb
   object failed") while macOS is still setting the box up, about 1 connect in 30: retry for
   about a second. */
#define CONNECT_TRIES    10
#define CONNECT_RETRY_MS 100
static void connect_box(int attempt) {
    if (!atomic_load(&g_box_present)) return;   /* unplugged meanwhile */
    pthread_mutex_lock(&g_mutex);
    bool ok = usb_ensure_hid();
    if (ok && !atomic_load(&g_io_running)) {
        set_usb_switches(false);
        send_hw_samplerate((int)g_sr);   /* the box powers up at 44.1 kHz */
    }
    pthread_mutex_unlock(&g_mutex);
    if (ok) {
        if (attempt > 0) LOG("Rane SL 2 opened on attempt %d", attempt + 1);
        return;
    }
    if (attempt + 1 < CONNECT_TRIES)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, CONNECT_RETRY_MS * NSEC_PER_MSEC), g_hotplug_q,
                       ^{ connect_box(attempt + 1); });
    else
        LOG("Rane SL 2: could not open the box after %d attempts", CONNECT_TRIES);
}

static void on_usb_added(void *refcon, io_iterator_t iter) {
    io_service_t s;
    bool audio = false, bootloader = false;
    while ((s = IOIteratorNext(iter))) {
        if (svc_bcd(s) == BCD_LOADER) bootloader = true;
        else                          audio = true;
        IOObjectRelease(s);
    }
    if (!audio && !bootloader) return;
    bool was_published = device_published();
    if (audio) {
        atomic_store(&g_boot_mode, false);
        atomic_store(&g_box_present, true);
        LOG("Rane SL 2 USB connected");
        connect_box(0);
    }
    if (bootloader) {
        atomic_store(&g_boot_mode, true);
        note_bootloader_device();
    }
    if (!was_published) notify_device_list_changed();
}

static void on_usb_removed(void *refcon, io_iterator_t iter) {
    io_service_t s;
    bool removed = false;
    while ((s = IOIteratorNext(iter))) { IOObjectRelease(s); removed = true; }
    if (!removed) return;
    /* The removed service can no longer be asked what it was: see what is still attached. */
    bool audio, bootloader;
    scan_attached(&audio, &bootloader);
    bool was_published = device_published();
    if (!audio && atomic_load(&g_box_present)) {
        LOG("Rane SL 2 USB disconnected");
        atomic_store(&g_box_present, false);
        pthread_mutex_lock(&g_mutex);
        usb_close_all();
        /* The device leaves the HAL's list with the box, and a client using it again after a
           replug sends a new StartIO: start counting clients from zero. */
        if (g_io_clients) LOG("%u client(s) were streaming when the box was unplugged", g_io_clients);
        g_io_clients = 0;
        pthread_mutex_unlock(&g_mutex);
    }
    atomic_store(&g_boot_mode, bootloader);
    if (was_published != device_published()) notify_device_list_changed();
}

static void start_hotplug_monitor(void) {
    dispatch_queue_t hq = g_hotplug_q = dispatch_queue_create("com.rane.sl2.hotplug", DISPATCH_QUEUE_SERIAL);
    g_notify_port = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(g_notify_port, hq);

    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);

    /* Notifications for the box arriving and leaving (both delivered on the hot-plug queue). */
    CFMutableDictionaryRef m1 = IOServiceMatching(kIOUSBDeviceClassName);
    CFDictionarySetValue(m1, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m1, CFSTR(kUSBProductID), pn);
    kern_return_t k1 = IOServiceAddMatchingNotification(g_notify_port, kIOFirstMatchNotification, m1, on_usb_added, NULL, &g_added_iter);
    CFMutableDictionaryRef m2 = IOServiceMatching(kIOUSBDeviceClassName);
    CFDictionarySetValue(m2, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m2, CFSTR(kUSBProductID), pn);
    kern_return_t k2 = IOServiceAddMatchingNotification(g_notify_port, kIOTerminatedNotification, m2, on_usb_removed, NULL, &g_removed_iter);
    CFRelease(vn); CFRelease(pn);
    if (k1 != KERN_SUCCESS || k2 != KERN_SUCCESS)
        LOG("USB hot-plug notifications could not be set up (0x%x, 0x%x): plug and unplug won't be seen", k1, k2);

    /* Each iterator must be drained once to arm it. Do that on the hot-plug queue too, so a box
       already attached is handled there like any later arrival (not inside Initialize). */
    dispatch_async(hq, ^{
        on_usb_added(NULL, g_added_iter);
        io_service_t o;
        while ((o = IOIteratorNext(g_removed_iter))) IOObjectRelease(o);
    });
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
        if (was_streaming) usb_stop_streaming(true);
        g_sr = (Float64)action;
        clk_reset();
        atomic_fetch_add(&g_zts_seed, 1);   /* new timeline for the HAL */
        if (was_streaming && !usb_open_all()) LOG("Could not restart streaming at %.0f Hz", g_sr);   /* sends 0x31 itself */
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

/* kAudioObjectPropertyOwnedObjects can carry a qualifier: a list of class IDs. Only objects of
   one of those classes (or of a class derived from it) are returned; no qualifier means all. */
static bool owned_class_wanted(UInt32 qsz, const void *qd, AudioClassID cls) {
    UInt32 n = qd ? qsz / sizeof(AudioClassID) : 0;
    if (n == 0) return true;
    const AudioClassID *c = (const AudioClassID *)qd;
    for (UInt32 i = 0; i < n; i++)
        if (c[i] == cls || c[i] == kAudioObjectClassID) return true;
    return false;
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
                *outSize = (device_published() && owned_class_wanted(qsz, qd, kAudioDeviceClassID)) ? sizeof(AudioObjectID) : 0;
                return 0;
            case kAudioPlugInPropertyDeviceList: *outSize = device_published() ? sizeof(AudioObjectID) : 0; return 0;
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
                if (!owned_class_wanted(qsz, qd, kAudioStreamClassID)) *outSize = 0;
                else *outSize = (sc == kAudioObjectPropertyScopeInput || sc == kAudioObjectPropertyScopeOutput)
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

static OSStatus get_property_data(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, UInt32 *outSize, void *outData) {
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
                if (s == kAudioObjectPropertyOwnedObjects && !owned_class_wanted(qsz, qd, kAudioDeviceClassID)) {
                    *outSize = 0;
                } else if (device_published() && inSize >= sizeof(AudioObjectID)) {
                    *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID);
                } else {
                    *outSize = 0;
                }
                return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                CFStringRef u = (qd && qsz >= sizeof(CFStringRef)) ? *(CFStringRef*)qd : NULL;
                *(AudioObjectID*)outData = (device_published() && u && CFEqual(u, CFSTR("com.rane.sl2.hal.device")))
                                         ? kObjDevice : kAudioObjectUnknown;
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
            case kAudioDevicePropertyDeviceIsAlive: *(UInt32*)outData = device_published() ? 1 : 0; *outSize = sizeof(UInt32); return 0;
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
            case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32*)outData = ZTS_PERIOD_FRAMES; *outSize = sizeof(UInt32); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams: {
                AudioObjectID *ids = (AudioObjectID*)outData;
                if (s == kAudioObjectPropertyOwnedObjects && !owned_class_wanted(qsz, qd, kAudioStreamClassID)) {
                    *outSize = 0;
                    return 0;
                }
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
                /* The reply to this client's last 'sl2h' write (sent then), once; never sends. */
                uint8_t reply[HID_REPORT_LEN] = {0};
                pthread_mutex_lock(&g_mutex);
                for (int i = 0; i < HID_CLIENTS; i++)
                    if (g_hid_replies[i].used && g_hid_replies[i].pid == pid && g_hid_replies[i].pending) {
                        memcpy(reply, g_hid_replies[i].reply, HID_REPORT_LEN);
                        g_hid_replies[i].pending = false;
                    }
                pthread_mutex_unlock(&g_mutex);
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, reply, HID_REPORT_LEN);
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL2PropStatus: {
                pthread_mutex_lock(&g_mutex);
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
                /* This client's reports since its last read, oldest first. */
                pthread_mutex_lock(&g_unsol_mtx);
                uint64_t *r = unsol_cursor(pid);
                if (g_unsol_w - *r > UNSOL_Q_MAX) *r = g_unsol_w - UNSOL_Q_MAX;
                CFMutableDataRef md = CFDataCreateMutable(kCFAllocatorDefault, (CFIndex)(g_unsol_w - *r) * HID_REPORT_LEN);
                for (; *r < g_unsol_w; (*r)++) CFDataAppendBytes(md, g_unsol_q[*r % UNSOL_Q_MAX], HID_REPORT_LEN);
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
            case kAudioStreamPropertyLatency:
                /* Clients add device and stream latency. With 32 frames on the output stream and
                   none on the input, the device's total (66 + 32 out, 32 in = 130 frames, 2.95 ms
                   at 44.1 kHz) matches the round trip measured through a loopback cable (rtlat:
                   2.8 ms), slightly over rather than under. */
                *(UInt32*)outData = (oid == kObjStreamOut) ? 32 : 0;
                *outSize = sizeof(UInt32); return 0;
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

/* The size of one element of an array-valued property, or 0 if the property is a single value. */
static UInt32 property_element_size(AudioObjectPropertySelector s) {
    switch (s) {
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioObjectPropertyControlList:                 return sizeof(AudioObjectID);
        case kAudioDevicePropertyAvailableNominalSampleRates: return sizeof(AudioValueRange);
        case kAudioDevicePropertyPreferredChannelsForStereo:  return sizeof(UInt32);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:    return sizeof(AudioStreamRangedDescription);
        case kAudioObjectPropertyCustomPropertyInfoList:      return sizeof(AudioServerPlugInCustomPropertyInfo);
    }
    return 0;
}

/* GetPropertyData: never write past the caller's buffer (inSize). A buffer big enough for the whole
   property gets it; a smaller one gets as many whole elements of an array as fit; a single value
   that doesn't fit is an error. */
static OSStatus SL2_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (!addr || !outSize || !outData) return kAudioHardwareIllegalOperationError;

    /* How much the property needs, and the common case: the buffer is big enough. */
    UInt32 need = 0;
    OSStatus st = SL2_GetPropertyDataSize(d, oid, pid, addr, qsz, qd, &need);
    if (st) return st;
    if (inSize >= need) return get_property_data(d, oid, pid, addr, qsz, qd, inSize, outSize, outData);

    /* Too small: produce the whole array in a scratch buffer and copy the elements that fit. */
    UInt32 elem = property_element_size(addr->mSelector);
    uint8_t tmp[1024];
    if (!elem || need > sizeof tmp) return kAudioHardwareBadPropertySizeError;
    UInt32 got = 0;
    st = get_property_data(d, oid, pid, addr, qsz, qd, need, &got, tmp);
    if (st) return st;
    UInt32 n = (inSize / elem) * elem;
    if (n > got) n = got;
    memcpy(outData, tmp, n);
    *outSize = n;
    return 0;
}

#if SL2_DEBUG
/* 'sl2h' debug commands. Each takes its argument from byte [5] onwards:
     0xF2 <ms>         input safety offset (the HAL reads it only at device setup, so it applies to
                       a device set up again, not to the running one)
     0xF3 <ms hi> <lo> hold the USB queue this long, once, as a completion stall would
     0xF4 <n>          treat the next n capture packets as errored */
static OSStatus dbg_command(const uint8_t *c, CFIndex len) {
    if (len < 6) return kAudioHardwareBadPropertySizeError;
    switch (c[0]) {
        case 0xF2: {
            int ms = c[5] < 1 ? 1 : c[5];
            atomic_store(&g_in_safety_ms, ms);
            DBG_LOG("DBG input safety offset set to %d ms (%u frames)", ms, in_safety_frames());
            return 0;
        }
        case 0xF3:
            if (len < 7) return kAudioHardwareBadPropertySizeError;
            atomic_store(&dbg_stall_ms, ((uint32_t)c[5] << 8) | c[6]);
            DBG_LOG("DBG next capture completion stalls the USB queue for %u ms", atomic_load(&dbg_stall_ms));
            return 0;
        case 0xF4:
            atomic_store(&dbg_err_pkts, c[5]);
            DBG_LOG("DBG next %u capture packets treated as errored", c[5]);
            return 0;
    }
    return kAudioHardwareIllegalOperationError;
}
#endif

static OSStatus SL2_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, const void *inData) {
    if (oid == kObjDevice && addr->mSelector == kSL2PropHIDCommand) {
        if (inSize == sizeof(CFDataRef) && inData) {
            CFDataRef cd = *(CFDataRef*)inData;
            /* Debug commands (0xF0 and up) are handled by the driver, never sent to the box. */
            if (cd && CFGetTypeID(cd) == CFDataGetTypeID() && CFDataGetLength(cd) >= 1 &&
                CFDataGetBytePtr(cd)[0] >= 0xF0) {
#if SL2_DEBUG
                return dbg_command(CFDataGetBytePtr(cd), CFDataGetLength(cd));
#else
                return kAudioHardwareIllegalOperationError;
#endif
            }
            if (!cd || CFGetTypeID(cd) != CFDataGetTypeID() || CFDataGetLength(cd) < 1 ||
                CFDataGetLength(cd) > HID_REPORT_LEN) return kAudioHardwareBadPropertySizeError;
            uint8_t req[HID_REPORT_LEN] = {0};
            memcpy(req, CFDataGetBytePtr(cd), (size_t)CFDataGetLength(cd));
            uint8_t reply[HID_REPORT_LEN] = {0};
            bool answered;

            /* A rate change (0x31) to the other supported rate goes through the HAL's handshake
               (PerformDeviceConfigurationChange sends it to the box), so the HAL's rate and the box's
               change together; the client gets the box's usual reply. Anything else, including the
               current rate or an invalid one (which the box rejects), goes to the box now. */
            int sr = (req[5] << 8) | req[6];
            if (req[0] == SL2_CMD_SET_RATE && (sr == 44100 || sr == 48000) && (Float64)sr != g_sr && g_host) {
                OSStatus st = g_host->RequestDeviceConfigurationChange(g_host, kObjDevice, (UInt64)sr, NULL);
                if (st) return st;
                reply[0] = SL2_CMD_SET_RATE;
                memcpy(reply + 1, req + 1, 4);
                answered = true;
            } else {
                pthread_mutex_lock(&g_mutex);
                answered = usb_ensure_hid() && hid_cmd(req[0], req + 5, HID_MAX_ARGS, reply, req + 1);
                pthread_mutex_unlock(&g_mutex);
                if (reply[0] == SL2_REJECTED) answered = true;   /* the client sees the rejection */
            }

            /* Keep the reply for this client's next read of 'sl2h'. */
            pthread_mutex_lock(&g_mutex);
            int slot = 0;
            for (int i = 0; i < HID_CLIENTS; i++) {
                if (g_hid_replies[i].used && g_hid_replies[i].pid == pid) { slot = i; break; }
                if (!g_hid_replies[i].used || g_hid_replies[i].last < g_hid_replies[slot].last) slot = i;
            }
            g_hid_replies[slot] = (HidClientReply){ .used = true, .pending = true, .pid = pid, .last = mach_absolute_time() };
            memcpy(g_hid_replies[slot].reply, reply, HID_REPORT_LEN);
            pthread_mutex_unlock(&g_mutex);
            return answered ? 0 : kAudioHardwareUnspecifiedError;
        }
        return kAudioHardwareBadPropertySizeError;
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
    /* The first client starts the stream; if the box can't be opened, the client gets an error
       rather than silence on a timeline with no box behind it. */
    pthread_mutex_lock(&g_mutex);
    if (g_io_clients == 0 && !usb_open_all()) {
        pthread_mutex_unlock(&g_mutex);
        LOG("StartIO failed: the SL 2 could not be opened");
        return kAudioHardwareNotRunningError;
    }
    g_io_clients++;
    pthread_mutex_unlock(&g_mutex);
    return 0;
}

static OSStatus SL2_StopIO(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid) {
    pthread_mutex_lock(&g_mutex);
    if (g_io_clients > 0) {
        g_io_clients--;
        if (g_io_clients == 0) usb_stop_streaming(true);
    } else {
        LOG("StopIO with no client running (the box was unplugged while it streamed)");
    }
    pthread_mutex_unlock(&g_mutex);
    return 0;
}

static OSStatus SL2_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    double pos = s + ((double)mach_absolute_time() - (double)h) / tpf;
    double period = pos > 0 ? floor(pos / ZTS_PERIOD_FRAMES) * ZTS_PERIOD_FRAMES : 0;   /* latest period boundary */

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
        /* Copy each frame from the capture ring, or silence where capture has not written yet (it
           is later than the input safety offset, or the box is gone) or wrote too long ago. */
        uint64_t pos = (uint64_t)ci->mInputTime.mSampleTime;
        uint64_t head = atomic_load_explicit(&g_cap_head, memory_order_acquire);
        for (UInt32 f = 0; f < frames; f++) {
            uint64_t p = pos + f;
            if (p >= head || head - p > CAP_VALID_SPAN) {
                memset(buf + f * NCH, 0, NCH * sizeof(float));
                continue;
            }
            memcpy(buf + f * NCH, &g_in_ring[(p & RING_MASK) * NCH], NCH * sizeof(float));
        }
    } else if (op == kAudioServerPlugInIOOperationWriteMix) {
        uint64_t pos = (uint64_t)ci->mOutputTime.mSampleTime;
        /* Register as a writer before checking g_dp_active, so dp_stop either sees this call
           or this call sees the schedule switched off. */
        int writers = atomic_fetch_add_explicit(&g_dp_writers, 1, memory_order_seq_cst);
        if (atomic_load_explicit(&g_dp_active, memory_order_seq_cst)) {
#if SL2_DEBUG
            {   /* WriteMix calling pattern: with several clients the HAL calls it from more than one
                   IO thread, but never concurrently and never for a position already written (each
                   call carries the full mix; these counters check that), which is what lets
                   dp_write overwrite rather than mix */
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
