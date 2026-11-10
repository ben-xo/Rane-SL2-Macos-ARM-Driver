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
#define kSL2PropMeters      'sl2m'   /* CFDataRef (8 Float32: peak level of inputs 1-4, then outputs 1-4) */
#define kSL2PropInSafety    'sl2i'   /* CFNumberRef (int): the input safety offset setting in us; set with nothing streaming */

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
    uint32_t debug_build;    /* 1 = this driver was built with SL2_DEBUG (make plugin DEBUG=1) */
    /* Input health (see "Early read" and the input safety offset) */
    uint32_t in_safety_us;          /* the input safety offset the HAL is using, in us */
    uint32_t in_safety_setting_us;  /* the setting ('sl2i'); in_safety_us is larger while it has fallen back */
    uint32_t early_read;            /* 0 = not judged yet on this connection, 1 = working, 2 = not working */
    uint32_t hub_depth;             /* USB hubs between the box and the Mac: 0 = connected directly */
    uint64_t in_dropouts;           /* IO cycles since the box connected in which input wasn't captured in time */
} SL2StatusPacket;

enum {
    kObjPlugIn    = kAudioObjectPlugInObject,
    kObjDevice    = 2,
    kObjStreamIn  = 3,
    kObjStreamOut = 4,
    kObjVolume    = 5,   /* output master volume */
    kObjMute      = 6,   /* output master mute */
    kObjVolCh1    = 7,   /* output volume, channels 1-4 */
    kObjVolCh2    = 8,
    kObjVolCh3    = 9,
    kObjVolCh4    = 10,
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
static _Atomic bool     dbg_no_early;      /* 0xF5: the early reader places nothing, as where it can't work */

static void dbg_er_reset(void);
static void dbg_er_log(const char *what);
static void dbg_reset(void) {
    dbg_er_reset();
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

/* Input safety offset. It covers the early read (see "Early read"), not completion delivery: at
   1.5 ms, ReadInput found every frame it was asked for at least 0.6 ms early, idle and under load
   (measured).
   - g_in_safety_set_us is the setting: 'sl2i', kept in the plug-in's storage so it survives restarts.
   - Where the early read turns out not to work (early_read_judge), the offset falls back to
     IN_SAFETY_FALLBACK_US until the box is connected again or the setting is changed (g_in_fallback).
   - The HAL reads the offset only when it sets the device up, so g_in_safety_us, the value the
     property reports, changes only just before the device is listed (in_safety_apply): it is always
     the value the HAL is using. */
#define IN_SAFETY_DEFAULT_US   1500
#define IN_SAFETY_FALLBACK_US  8000
#define IN_SAFETY_MIN_US       500
#define IN_SAFETY_MAX_US       20000
#define IN_SAFETY_STORAGE_KEY  CFSTR("input safety offset us")
static _Atomic int  g_in_safety_set_us = IN_SAFETY_DEFAULT_US;
static _Atomic bool g_in_fallback;
static _Atomic int  g_in_safety_us = IN_SAFETY_DEFAULT_US;
/* The offset the device should be set up with: the setting, or the fallback if that is larger. */
static int in_safety_wanted_us(void) {
    int us = atomic_load(&g_in_safety_set_us);
    return (atomic_load(&g_in_fallback) && us < IN_SAFETY_FALLBACK_US) ? IN_SAFETY_FALLBACK_US : us;
}
/* Just before the device is listed, so the HAL reads it as it sets the device up. */
static void in_safety_apply(void) {
    atomic_store(&g_in_safety_us, in_safety_wanted_us());
}
/* The setting, from and to the plug-in's storage (the HAL keeps it for the plug-in). */
static void in_safety_load(void) {
    CFPropertyListRef v = NULL;
    if (!g_host || g_host->CopyFromStorage(g_host, IN_SAFETY_STORAGE_KEY, &v) != 0 || !v) return;
    int us = 0;
    if (CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &us) &&
        us >= IN_SAFETY_MIN_US && us <= IN_SAFETY_MAX_US)
        atomic_store(&g_in_safety_set_us, us);
    CFRelease(v);
}
static void in_safety_save(void) {
    if (!g_host) return;
    int us = atomic_load(&g_in_safety_set_us);
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &us);
    if (!n) return;
    g_host->WriteToStorage(g_host, IN_SAFETY_STORAGE_KEY, n);
    CFRelease(n);
}
static UInt32 in_safety_frames(void) {
    return (UInt32)(atomic_load(&g_in_safety_us) * g_sr / 1e6 + 0.5);
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
            /* The report's command byte [0] and its tag [1..4]. */
            const uint8_t *b = g_hbuf_in.bytes;
            uint32_t rseq = 0;
            memcpy(&rseq, b + 1, 4);

            /* The awaited reply: its command (or a rejection) with its tag. A refused EEPROM write
               carries a stale tag, so for that one any rejection is the answer. */
            bool reply = atomic_load(&g_waiting) &&
                         ((b[0] == g_wait_cmd && rseq == g_wait_seq) ||
                          (b[0] == SL2_REJECTED && (rseq == g_wait_seq || g_wait_cmd == SL2_CMD_EEPROM_WRITE)));
            if (reply) {
                /* Hand it to hid_cmd and wake it. */
                memcpy(g_reply_buf, b, HID_REPORT_LEN);
                atomic_store(&g_waiting, false);
                dispatch_semaphore_signal(g_hid_sem);

            /* An unsolicited report: note thru and switch state, and queue it for clients. */
            } else if (b[0] == SL2_REPORT_HIDI) {
                /* Its payload is 3-byte MIDI messages (status, note, velocity), [5] bytes long. */
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
        /* Queue the next read, unless the pipe was aborted or released (the box is closing). */
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
    /* One command at a time; clear any signal left by a reply to an earlier, abandoned command. */
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
            /* No reply in time: stop waiting, so hid_read doesn't take a late one as the answer. */
            atomic_store(&g_waiting, false);
            accepted = false;
            if (reply_out) memset(reply_out, 0, HID_REPORT_LEN);
        }
    } else if (reply_out) {
        /* A command the box never answers: report a reply of its own command and tag. */
        memset(reply_out, 0, HID_REPORT_LEN);
        reply_out[0] = cmd;
        memcpy(reply_out + 1, &seq, 4);
    }
    /* Give a client its own tag back in place of the driver's. */
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
    /* Port status (0x45), kept in the status packet for clients; always 00 00 on the SL 2. */
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
    /* The first isochronous endpoint in direction dir that the interface's descriptors list. */
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
    /* Otherwise the given endpoint addresses, in order. */
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
    /* Its bus time (now, if there is none) and the timeline position at that time. */
    uint64_t now = (hw_time > 0) ? hw_time : mach_absolute_time();
    double pos = clk_sample_at(now);
    /* The box's rate is measured from here; captured frames go into the ring from pos on. */
    g_rate_anchor = now;
    g_cap_base = pos > 0 ? (uint64_t)pos : 0;
    g_clk_last_fix = 0;
}

/* A capture transfer delivered `frames` frames, the first of which (captured-frame number
   count_before) arrived at host time ts. Keep the timeline on the box's clock (see g_clk_*). */
static void clk_track(uint64_t count_before, int frames, uint64_t ts) {
    /* Count the frames; correct the line only every CLK_FIX_FRAMES of them. */
    atomic_fetch_add_explicit(&g_total_cap_frames, frames, memory_order_relaxed);
    if (!frames || !ts || count_before - g_clk_last_fix < CLK_FIX_FRAMES) return;
    g_clk_last_fix = count_before;

    /* Where the line is at ts, and how far that is from where the box's frame count puts it. */
    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    if (ts <= h) return;
    double here = s + (double)(ts - h) / tpf;                     /* timeline position at ts */
    double err  = (double)(g_cap_base + count_before) - here;     /* > 0: timeline behind the box */

    /* The box's average rate since the first capture (nominal until there are enough frames to
       measure it), plus the correction that removes err over CLK_CORR_S. */
    double nom_rate = 1.0 / nominal_tpf();                         /* frames per host tick */
    double elapsed  = (double)(ts - g_rate_anchor);
    double rate = (count_before >= 8 * CLK_FIX_FRAMES && elapsed > 0) ? (double)count_before / elapsed : nom_rate;
    double ticks_per_s = 1e9 * (double)g_tb.denom / (double)g_tb.numer;
    rate += err / (CLK_CORR_S * ticks_per_s);

    /* Keep it within 0.5% of nominal, and re-anchor the line where it is now at that rate. */
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
    /* Ask the controller for the current microframe and its host time. */
    IOUSBHostTime t = 0;
    NSError *e = nil;
    uint64_t uf = [g_dev currentMicroframeWithTime:&t error:&e];
    if (!uf || !t) return;
    /* Publish the pair under the seqlock (odd while it is being written). */
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
    /* Steer: remove the sent-vs-captured difference over DP_CORR_S (8000 microframes a second). */
    rate -= g_dp_err / (8000.0 * DP_CORR_S);
    /* Whole frames this packet, carrying the fraction to the next; within what a packet can hold. */
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

        /* The current USB frame (refreshing the frame clock if its reference is over 0.5 ms old). */
        if ((double)(mach_absolute_time() - g_dp_last_refresh) > 0.5 * ticks_per_ms()) dp_ref_refresh();
        uint64_t now_f = (uint64_t)dp_frame_at(mach_absolute_time());
        if (g_dp_next_frame < now_f + DP_DRY_LEAD) {
            /* The schedule has (almost) run dry: under DP_DRY_LEAD frames ahead of the bus, after
               a completion stall of nearly DP_SLOTS ms (or repeated refusals). Re-anchor ahead. */
            dp_anchor(now_f + DP_START_LEAD);
            DBG_DO(dbg_dp_resync++);
        }

        /* Take the next frame of the schedule and its ring entry. */
        uint64_t f = g_dp_next_frame++;
        DPEntry *e = &g_dp_sched[f & (DP_SCHED_N - 1)];
        /* unpublish while it is rewritten (seqlock writer) */
        atomic_store_explicit(&e->frame, 0, memory_order_relaxed);
        atomic_thread_fence(memory_order_release);

        /* Size each packet from the predicted rate, recording where each packet's samples start. */
        uint16_t off = 0;
        for (int k = 0; k < PLAY_PKTS; k++) {
            int n = dp_packet_frames();
            e->off[k] = off;
            g_dp_tx[slot][k] = (IOUSBHostIsochronousTransaction){
                .requestCount = (uint32_t)(n * FRAME_BYTES), .offset = (uint32_t)(k * PKT_MAX) };
            off += n;
        }
        /* The frame's first timeline position and its buffer, zeroed: silence until WriteMix writes. */
        e->off[PLAY_PKTS] = off;
        e->first = g_dp_next_pos;
        e->buf = g_dp_ptr[slot];
        memset(g_dp_ptr[slot], 0, PLAY_PKTS * PKT_MAX);

        /* Queue it for frame f; its completion queues this slot again at the far end. */
        NSError *err = nil;
        BOOL ok = [g_ppipe enqueueIORequestWithData:g_dp_data[slot] transactionList:g_dp_tx[slot]
                               transactionListCount:PLAY_PKTS firstFrameNumber:f
                                            options:IOUSBHostIsochronousTransferOptionsNone error:&err
                                  completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
            if (stream_live(gen) && st != kIOReturnAborted && !dp_gone(st)) dp_submit(slot, gen);
        }];
        if (ok) {
            /* Queued: advance the positions and sent count, then publish the entry for WriteMix. */
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

/* Start playback (from the capture handler, once capture has run a few ms): fill the schedule. */
static void dp_start(uint32_t gen) {
    if (!stream_live(gen)) return;
    /* A fresh USB frame clock reference. */
    dp_ref_refresh();
#if SL2_DEBUG   /* check frameNumberWithTime: and the microframe reference agree */
    IOUSBHostTime t = 0;
    uint64_t fn = [g_dev frameNumberWithTime:&t];
    DBG_LOG("DBG frameNumber %llu vs microframe estimate %.2f", fn, dp_frame_at(t));
#endif
    /* Anchor the schedule a few frames ahead of the bus, let WriteMix in, and queue every slot. */
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
    /* Count what the box captured since the schedule's anchor. */
    if (!g_dp_started || fc < atomic_load(&g_dp_F0)) return;
    g_dp_in_cum += frames;
    /* Compare it with what was sent through the same frame; dp_packet_frames steers by the gap. */
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
    if (dbg_dp_n % 2000 == 0) dbg_er_log("so far");
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
        /* Find the queued frame carrying position p: estimate from the hint, then step to it. */
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
        /* The samples from p that this frame carries; the frame found is the next search's hint. */
        hint_frame = (uint64_t)fg; hint_first = first;
        uint32_t n = (uint32_t)(first + off[PLAY_PKTS] - p);
        if (n > frames - i) n = frames - i;
        /* Too close to its start: the controller may already be reading it, so drop them. */
        if ((double)fg - now_f < DP_WRITE_GUARD_FRAMES) {
            DBG_DO(atomic_fetch_add_explicit(&dbg_dp_late, n, memory_order_relaxed));
        } else {
            /* Otherwise write each sample into its packet: j is its offset in the frame, k its
               packet. */
            uint32_t j = (uint32_t)(p - first);
            int k = 0;
            for (uint32_t s = 0; s < n; s++, j++) {
                while (k < PLAY_PKTS - 1 && j >= off[k + 1]) k++;
                uint8_t *q = fbuf + k * PKT_MAX + (j - off[k]) * FRAME_BYTES;
                const float *src = buf + (size_t)(i + s) * NCH;
                /* Clip to [-1, 1] and convert to the box's 32-bit integer samples. */
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
 * Level meters ('sl2m', for the control panel)
 *
 * The peak absolute sample level (0..1) on each input and output channel since the meters were last
 * read: inputs as captured, outputs as sent to the box (after the volume). Each client process has
 * its own set (up to METER_READERS), so two readers (the control panel and the meters tool, say) each
 * see every peak. Reading the property returns the caller's peaks and starts its next ones. They are
 * measured only while some client has read them in the last METER_IDLE_MS, so they cost nothing when
 * no meter is shown.
 * ============================================================================ */
#define METER_IDLE_MS 1000
#define METER_READERS 4
typedef struct {
    pid_t            pid;               /* the reader; set under g_meter_mtx */
    _Atomic uint64_t last_read;         /* host time of its last read; 0 = slot free */
    _Atomic float    peak[2 * NCH];     /* [0..NCH) inputs, [NCH..2*NCH) outputs */
} MeterReader;
static MeterReader g_meters[METER_READERS];
static pthread_mutex_t g_meter_mtx = PTHREAD_MUTEX_INITIALIZER;   /* reads (property threads only) */

static bool meter_slot_live(MeterReader *m, uint64_t now) {
    uint64_t t = atomic_load_explicit(&m->last_read, memory_order_relaxed);
    return t && (double)(now - t) < METER_IDLE_MS * ticks_per_ms();
}

static bool meter_active(void) {
    uint64_t now = mach_absolute_time();
    for (int r = 0; r < METER_READERS; r++) if (meter_slot_live(&g_meters[r], now)) return true;
    return false;
}

/* Raise a peak to at least v (lock-free: its reader resets it concurrently). */
static void meter_raise(_Atomic float *peak, float v) {
    float cur = atomic_load_explicit(peak, memory_order_relaxed);
    while (v > cur && !atomic_compare_exchange_weak_explicit(peak, &cur, v, memory_order_relaxed, memory_order_relaxed)) {}
}

/* The peaks of `frames` interleaved frames, into every live reader's meters base..base+NCH-1. */
static void meter_frames(int base, const float *buf, UInt32 frames) {
    float pk[NCH] = { 0 };
    for (UInt32 f = 0; f < frames; f++)
        for (int c = 0; c < NCH; c++) pk[c] = fmaxf(pk[c], fabsf(buf[f * NCH + c]));
    uint64_t now = mach_absolute_time();
    for (int r = 0; r < METER_READERS; r++)
        if (meter_slot_live(&g_meters[r], now))
            for (int c = 0; c < NCH; c++) meter_raise(&g_meters[r].peak[base + c], pk[c]);
}

/* A reader's peaks since its last read, reset as they are taken. A new reader takes a free slot, or
   the one read longest ago, and starts from silence. */
static void meter_take(pid_t pid, Float32 out[2 * NCH]) {
    pthread_mutex_lock(&g_meter_mtx);
    MeterReader *m = NULL;
    for (int r = 0; r < METER_READERS && !m; r++)
        if (g_meters[r].pid == pid && atomic_load(&g_meters[r].last_read)) m = &g_meters[r];
    if (!m) {
        m = &g_meters[0];
        for (int r = 1; r < METER_READERS; r++)
            if (atomic_load(&g_meters[r].last_read) < atomic_load(&m->last_read)) m = &g_meters[r];
        m->pid = pid;
        for (int i = 0; i < 2 * NCH; i++) atomic_store(&m->peak[i], 0.0f);
    }
    for (int i = 0; i < 2 * NCH; i++) out[i] = atomic_exchange_explicit(&m->peak[i], 0.0f, memory_order_relaxed);
    atomic_store_explicit(&m->last_read, mach_absolute_time(), memory_order_relaxed);
    pthread_mutex_unlock(&g_meter_mtx);
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

/* ----------------------------------------------------------------------------
 * Early read
 *
 * A capture completion can be delivered up to ~8 ms after its frame, but the controller writes
 * each packet straight into the transfer's buffer during the packet's own microframe. So ReadInput
 * (the HAL's IO thread) reads packets out of the queued buffers itself, shortly after their
 * microframe, and the input safety offset only has to cover that, not the completion delay.
 *
 * - How many frames a packet carried is only reported with its completion. So every buffer is
 *   filled with CAP_MARK before it is queued: the low byte of a real sample is always 0 (24-bit
 *   audio, left-justified in 32 bits), so the frames whose first byte reads 0 are the ones that
 *   arrived.
 * - A packet is read only once its microframe has been over for CAP_SETTLE_UF microframes (one can
 *   be caught part-written during its microframe), and not if the kernel has already marked it
 *   errored in the transaction list.
 * - The early reader starts where the completions have got to (g_cap_prog_*: the next USB frame to
 *   complete, and the timeline position its first frame goes at), and walks forward packet by
 *   packet, placing each frame at the position the completion will. It stops at the first packet
 *   it can't read yet, a packet with no frames (missing or errored: the completion fills it with
 *   silence), or a USB frame with no transfer queued.
 * - The completion stays in charge. It writes every frame again (the same values), and keeps the
 *   clock tracking, the playback steering, the meters and the silence fills. If it places frames
 *   differently (an errored packet that still carried data), the early reader's position for the
 *   next USB frame doesn't match the completion's, and it starts again from the completion's.
 * - A buffer is tagged with its USB frame while queued (g_cap_tag), and 0 while it is refilled for
 *   its next frame. The early reader checks the tag before and after reading a packet, converting
 *   into a scratch buffer in between, so it never puts a refilled buffer's contents in the ring.
 * ---------------------------------------------------------------------------- */
#define CAP_MARK       0xFF
#define CAP_SETTLE_UF  1           /* microframes after a packet's own before it is read early */
#define CAP_MAP_N      128         /* USB frame -> transfer map entries: power of two, >= 2 x CAP_NXF */
static uint8_t *g_cap_bytes[CAP_NXF];             /* the capture buffers' bytes, for the IO thread */
static _Atomic uint64_t g_cap_tag[CAP_NXF];       /* USB frame the buffer holds, 0 while refilled */
static _Atomic int      g_cap_idx_of[CAP_MAP_N];  /* the transfer queued for USB frame f, at [f % CAP_MAP_N] */
/* The completions' progress (g_q writes, the IO thread reads; seqlock): the next USB frame to
   complete and the timeline position of its first frame. fc 0 = no completion yet. */
static _Atomic uint32_t g_cap_prog_seq;
static uint64_t g_cap_prog_fc, g_cap_prog_pos;
static _Atomic uint64_t g_cap_early_head;         /* timeline position just past the early reader's last frame */
/* The early reader's own state: IO thread, one at a time (g_er_busy). */
static _Atomic bool g_er_busy;
static uint32_t g_er_gen;                         /* stream generation the state belongs to */
static uint64_t g_er_fc, g_er_pos;                /* next packet to read: USB frame, packet, position */
static int      g_er_k;
static uint64_t g_er_at_fc[CAP_MAP_N], g_er_at_pos[CAP_MAP_N];   /* position at each USB frame's start */
/* Whether the early read works on this connection. Each stream judges it once there is a second of
   capture and ReadInput has asked for half a second of it (early_read_judge): it works if it placed
   frames and the completions found almost none of them different. If it doesn't, the input safety
   offset falls back (g_in_fallback). Reported in the status, with the input dropouts. */
enum { EARLY_UNKNOWN = 0, EARLY_WORKING = 1, EARLY_FAILED = 2 };
static _Atomic uint32_t g_early_state;            /* this connection's latest judgement */
static _Atomic uint64_t g_er_placed;              /* frames placed early in this stream */
static uint64_t g_er_differ;                      /* g_q: of those, frames the completion found different */
static bool     g_er_judged;                      /* g_q: this stream has been judged */
static _Atomic uint64_t g_rd_frames;              /* frames ReadInput asked for in this stream, after the first capture */
static _Atomic uint64_t g_in_dropouts;            /* IO cycles since the box connected in which some input frame
                                                     wasn't captured in time (ReadInput returned silence) */
#if SL2_DEBUG
static _Atomic uint32_t dbg_er_restarts, dbg_er_torn, dbg_er_cc_differs, dbg_er_errored;
static _Atomic uint64_t dbg_rd_early, dbg_rd_short;   /* ReadInput, after the first capture */
static _Atomic int64_t  dbg_rd_margin_min;        /* frames between the read's end and the head, least */
static void dbg_er_reset(void) {
    dbg_er_restarts = dbg_er_torn = dbg_er_cc_differs = dbg_er_errored = 0;
    dbg_rd_early = dbg_rd_short = 0;
    dbg_rd_margin_min = INT64_MAX;
}
static void dbg_er_log(const char *what) {
    int64_t m = atomic_load(&dbg_rd_margin_min);
    DBG_LOG("DBG early read %{public}s: frames placed early %llu, restarts %u, torn %u, errored %u, count "
        "differs %u | completion found %llu different | ReadInput frames %llu: only there early %llu, "
        "SILENCE (not captured yet) %llu | least margin %.2f ms",
        what, atomic_load(&g_er_placed), atomic_load(&dbg_er_restarts), atomic_load(&dbg_er_torn),
        atomic_load(&dbg_er_errored), atomic_load(&dbg_er_cc_differs), g_er_differ,
        atomic_load(&g_rd_frames), atomic_load(&dbg_rd_early), atomic_load(&dbg_rd_short),
        m == INT64_MAX ? 0.0 : 1000.0 * (double)m / g_sr);
}
#endif

/* One captured frame: each 32-bit sample holds 24-bit audio in its top bytes; scale to float. */
static inline void cap_frame_to_float(const uint8_t *q, float *fr) {
    for (int c = 0; c < NCH; c++) {
        int32_t raw32;
        memcpy(&raw32, q + c * 4, 4);
        fr[c] = (float)(raw32 >> 8) * (1.0f / 8388608.0f);
    }
}
/* The same, from a buffer the controller may still be writing (the early reader). */
static inline void cap_frame_to_float_live(const volatile uint8_t *q, float *fr) {
    for (int c = 0; c < NCH; c++) {
        uint32_t u = (uint32_t)q[c * 4] | (uint32_t)q[c * 4 + 1] << 8 | (uint32_t)q[c * 4 + 2] << 16 |
                     (uint32_t)q[c * 4 + 3] << 24;
        fr[c] = (float)((int32_t)u >> 8) * (1.0f / 8388608.0f);
    }
}

/* The completions' progress (g_q). */
static void cap_prog_publish(uint64_t fc, uint64_t pos) {
    uint32_t s = atomic_load_explicit(&g_cap_prog_seq, memory_order_relaxed);
    atomic_store_explicit(&g_cap_prog_seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    g_cap_prog_fc = fc; g_cap_prog_pos = pos;
    atomic_store_explicit(&g_cap_prog_seq, s + 2, memory_order_release);
}
/* ... read consistently (any thread). Bounded, as dp_ref_get: after 64 tries (a writer preempted
   mid-publish) it uses the last copy any reader got, which is only a little behind. The early
   reader carries on from there; the next completion's progress puts it right. */
static _Atomic uint64_t g_cap_prog_last_fc, g_cap_prog_last_pos;
static void cap_prog_get(uint64_t *fc, uint64_t *pos) {
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = atomic_load_explicit(&g_cap_prog_seq, memory_order_acquire);
        uint64_t a = g_cap_prog_fc, b = g_cap_prog_pos;
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&g_cap_prog_seq, memory_order_relaxed);
        if (!(s1 & 1) && s1 == s2) {
            *fc = a; *pos = b;
            atomic_store_explicit(&g_cap_prog_last_fc, a, memory_order_relaxed);
            atomic_store_explicit(&g_cap_prog_last_pos, b, memory_order_relaxed);
            return;
        }
    }
    *fc = atomic_load_explicit(&g_cap_prog_last_fc, memory_order_relaxed);
    *pos = atomic_load_explicit(&g_cap_prog_last_pos, memory_order_relaxed);
}

/* The completions' progress for the early reader; false before the stream's first completion. */
static bool pfc_get(uint64_t *fc, uint64_t *pos) {
    cap_prog_get(fc, pos);
    return *fc != 0;
}

/* ReadInput (IO thread): place the packets that have arrived since the last completion (see "Early
   read"). No locks, no allocation, no IOKit calls. */
static void cap_read_early(void) {
#if SL2_DEBUG
    if (atomic_load_explicit(&dbg_no_early, memory_order_relaxed)) return;   /* test hook 0xF5 */
#endif
    if (atomic_exchange_explicit(&g_er_busy, true, memory_order_acquire)) return;   /* another IO thread is */
    uint32_t gen = atomic_load_explicit(&g_stream_gen, memory_order_acquire);
    uint64_t pfc, ppos;
    if (!atomic_load_explicit(&g_io_running, memory_order_acquire) || !pfc_get(&pfc, &ppos)) goto out;

    /* Carry on from where we got to, if that agrees with the completions; otherwise start again
       from them (a new stream, the completions overtook us, or they placed frames differently). */
    uint64_t at = pfc & (CAP_MAP_N - 1);
    if (g_er_gen != gen || g_er_fc < pfc || g_er_at_fc[at] != pfc || g_er_at_pos[at] != ppos) {
#if SL2_DEBUG
        if (g_er_gen == gen && g_er_fc > pfc) atomic_fetch_add_explicit(&dbg_er_restarts, 1, memory_order_relaxed);
#endif
        g_er_gen = gen; g_er_fc = pfc; g_er_k = 0; g_er_pos = ppos;
        g_er_at_fc[at] = pfc; g_er_at_pos[at] = ppos;
    }

    /* The USB frame clock, to tell which packets' microframes are over. */
    uint64_t now = mach_absolute_time(), uf, ut;
    dp_ref_get(&uf, &ut);
    double tpu = ticks_per_ms() / 8.0;   /* host ticks per microframe */
    float tmp[(PKT_MAX / FRAME_BYTES) * NCH];
    for (int budget = CAP_NXF * CAP_PKTS; budget > 0; budget--) {
        uint64_t f = g_er_fc;
        int k = g_er_k;
        /* Not until its microframe (8f + k) has been over for CAP_SETTLE_UF more. */
        double ready = (double)ut + ((double)(8 * f + k + 1 + CAP_SETTLE_UF) - (double)uf) * tpu;
        if ((double)now < ready) break;
        /* The transfer queued for frame f, if one is. */
        int idx = atomic_load_explicit(&g_cap_idx_of[f & (CAP_MAP_N - 1)], memory_order_relaxed);
        if (idx < 0 || idx >= CAP_NXF || atomic_load_explicit(&g_cap_tag[idx], memory_order_acquire) != f) break;
        /* Already reported errored by the kernel: leave it to the completion. */
        const volatile IOUSBHostIsochronousTransaction *t = &g_cap_xf[idx].tx[k];
        uint32_t cc = t->completeCount;
        if (cc && (t->status != kIOReturnSuccess || cc > PKT_MAX)) {
            DBG_DO(atomic_fetch_add_explicit(&dbg_er_errored, 1, memory_order_relaxed));
            break;
        }
        /* Count the frames that arrived by their marks; none means missing or errored. A frame counts
           only once the pad bytes of its first and last samples both read 0, so one caught part-way
           through being written is not taken. */
        const volatile uint8_t *p = g_cap_bytes[idx] + k * PKT_MAX;
        int n = 0;
        while (n < PKT_MAX / FRAME_BYTES && p[n * FRAME_BYTES] == 0x00 &&
               p[n * FRAME_BYTES + (NCH - 1) * 4] == 0x00) n++;
        if (n == 0) break;
        if (cc && (int)(cc / FRAME_BYTES) != n) {   /* the kernel's count disagrees: let the completion decide */
            DBG_DO(atomic_fetch_add_explicit(&dbg_er_cc_differs, 1, memory_order_relaxed));
            break;
        }
        for (int i = 0; i < n; i++) cap_frame_to_float_live(p + i * FRAME_BYTES, &tmp[i * NCH]);
        /* Still frame f's buffer, not refilled while we read it? */
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&g_cap_tag[idx], memory_order_relaxed) != f) {
            DBG_DO(atomic_fetch_add_explicit(&dbg_er_torn, 1, memory_order_relaxed));
            break;
        }
        /* Into the ring, where the completion will put them too. */
        for (int i = 0; i < n; i++)
            memcpy(&g_in_ring[((g_er_pos + i) & RING_MASK) * NCH], &tmp[i * NCH], NCH * sizeof(float));
        g_er_pos += n;
        atomic_fetch_add_explicit(&g_er_placed, n, memory_order_relaxed);
        if (++g_er_k == CAP_PKTS) {
            g_er_k = 0; g_er_fc++;
            g_er_at_fc[g_er_fc & (CAP_MAP_N - 1)] = g_er_fc;
            g_er_at_pos[g_er_fc & (CAP_MAP_N - 1)] = g_er_pos;
        }
    }
    atomic_store_explicit(&g_cap_early_head, g_er_pos, memory_order_release);
out:
    atomic_store_explicit(&g_er_busy, false, memory_order_release);
}

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

/* Judge whether the early read works on this connection (g_q; see g_early_state), and if it doesn't,
   fall back to IN_SAFETY_FALLBACK_US from the next time no app is using the device (SL2_StopIO). */
static void early_read_judge(void) {
    g_er_judged = true;
    uint64_t placed = atomic_load(&g_er_placed);
    bool works = placed > 0 && g_er_differ * 100 <= placed;
    atomic_store(&g_early_state, works ? EARLY_WORKING : EARLY_FAILED);
    if (works) return;
    if (!atomic_exchange(&g_in_fallback, true))
        LOG("Capture can't be read early on this connection (%llu frames placed early, %llu of them differently "
            "from their completion): input safety offset %.1f ms once no app is using the SL 2",
            placed, g_er_differ, in_safety_wanted_us() / 1000.0);
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
    uint64_t early_head = atomic_load_explicit(&g_cap_early_head, memory_order_acquire);   /* placed early below it */
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
        /* A good packet: into the ring. */
        int n = done[k].completeCount / FRAME_BYTES;
        const uint8_t *p = b + k * PKT_MAX;
        for (int s = 0; s < n; s++) {
            float *fr = &g_in_ring[((ring_pos + got) & RING_MASK) * NCH];
            /* A frame the early reader placed must be the same frame (early_read_judge counts those
               that aren't). */
            float was[NCH];
            bool early = ring_pos + got < early_head;
            if (early) memcpy(was, fr, sizeof was);
            cap_frame_to_float(p + s * FRAME_BYTES, fr);
            if (early && memcmp(was, fr, sizeof was)) g_er_differ++;
            got++;
        }
    }

    /* The input meters, if shown: the frames just placed (the ring may wrap within them). After a
       long gap the silence fill can be many times the ring, so take at most the newest ring's worth. */
    if (meter_active()) {
        uint64_t span = got < RING_FRAMES ? got : RING_FRAMES;
        for (uint64_t left = span, at = (ring_pos + got - span) & RING_MASK; left > 0; ) {
            uint64_t run = RING_FRAMES - at < left ? RING_FRAMES - at : left;
            meter_frames(0, &g_in_ring[at * NCH], (UInt32)run);
            left -= run; at = 0;
        }
    }

    /* Publish the ring's new head for ReadInput, then keep the timeline on the box's clock. */
    atomic_store_explicit(&g_cap_head, ring_pos + got, memory_order_release);
    cap_prog_publish(g_cap_next_fc, ring_pos + got);   /* where the early reader starts from */
    clk_track(before, (int)got, ts);

    /* Playback: start after a few ms of capture, then steer it by what the box clocked. */
    if (!g_dp_started && before >= (uint64_t)(8 * g_sr / 1000)) dp_start(gen);
    dp_track_capture(fc, (int)got);

    /* After a second of capture, with ReadInput reading it: does the early read work here? (An app
       that only plays leaves ReadInput uncalled, and the early read unjudged.) */
    if (!g_er_judged && before >= (uint64_t)g_sr && atomic_load(&g_rd_frames) >= (uint64_t)(g_sr / 2))
        early_read_judge();
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

        /* Untag the buffer while it is refilled for frame f (see "Early read"), mark every frame
           as not arrived, and ask for one full-size packet per microframe. */
        atomic_store_explicit(&g_cap_tag[idx], 0, memory_order_relaxed);
        atomic_thread_fence(memory_order_release);
        memset(g_cap_bytes[idx], CAP_MARK, CAP_PKTS * PKT_MAX);
        IOUSBHostIsochronousTransaction *tx = g_cap_xf[idx].tx;
        for (int k = 0; k < CAP_PKTS; k++)
            tx[k] = (IOUSBHostIsochronousTransaction){ .requestCount = PKT_MAX, .offset = (uint32_t)(k * PKT_MAX) };

        /* Queue it for frame f; its completion hands the packets to cap_complete. */
        NSError *e = nil;
        BOOL ok = [g_cpipe enqueueIORequestWithData:g_cap_xf[idx].buf transactionList:tx
                                transactionListCount:CAP_PKTS firstFrameNumber:f
                                             options:IOUSBHostIsochronousTransferOptionsNone error:&e
                                   completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
            if (!stream_live(gen) || st == kIOReturnAborted || dp_gone(st)) return;
            cap_complete(idx, f, done, gen);
        }];
        if (ok) {
            /* Queued: let the early reader find it (its completion, on this queue, can't run first). */
            atomic_store_explicit(&g_cap_idx_of[f & (CAP_MAP_N - 1)], idx, memory_order_relaxed);
            atomic_store_explicit(&g_cap_tag[idx], f, memory_order_release);
            return;
        }
        /* Refused (the frame passed while this ran): take the next one. */
        LOG("Capture enqueue refused for frame %llu (now ~%llu): %{public}@", f, now_f, e.localizedDescription);
        /* Never backwards: frames after f may already be queued on other transfers. */
        uint64_t next = now_f + DP_START_LEAD + attempt + 1;
        if (next > g_cap_frame) g_cap_frame = next;
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

/* The attached SL 2 running its firmware (the caller releases it), or IO_OBJECT_NULL. */
/* USB hubs between the box and the Mac: the USB devices among the box's ancestors (each hub is one;
   the Mac's own ports belong to its controller). Reported in the status. */
static _Atomic uint32_t g_hub_depth;
static uint32_t usb_hub_depth(io_service_t svc) {
    uint32_t hubs = 0;
    io_registry_entry_t e = svc, parent;
    IOObjectRetain(e);
    for (int i = 0; i < 32 && IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) == KERN_SUCCESS; i++) {
        IOObjectRelease(e);
        e = parent;
        if (IOObjectConformsTo(e, "IOUSBHostDevice")) hubs++;
    }
    IOObjectRelease(e);
    return hubs;
}

static io_service_t find_sl2_service(void) {
    /* Every USB device with the SL 2's vendor and product IDs. */
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
    /* The USB queue and hid_cmd's reply semaphore, created once and kept. */
    if (!g_q) g_q = usb_queue_create();
    if (!g_hid_sem) g_hid_sem = dispatch_semaphore_create(0);

    /* The device: open it and select configuration 1, unless already done. */
    if (!g_dev) {
        io_service_t svc = find_sl2_service();
        if (!svc) return false;
        g_dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
        uint32_t hubs = usb_hub_depth(svc);
        atomic_store(&g_hub_depth, hubs);
        if (hubs) LOG("Rane SL 2 is connected through %u USB hub%s (directly to the Mac is best)", hubs, hubs > 1 ? "s" : "");
        IOObjectRelease(svc);
        if (!g_dev) { LOG("Failed to open IOUSBHostDevice: %{public}@", e); return false; }
    }
    if (!g_dev.configurationDescriptor) [g_dev configureWithValue:1 matchInterfaces:YES error:&e];

    /* The HID interface: the device's child service with bInterfaceNumber IF_HID. */
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
    /* Connected, and running firmware (only such a box is opened: find_sl2_service). */
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
    /* Abort the pipes: their queued transfers complete with kIOReturnAborted. */
    if (g_cpipe) [g_cpipe abortWithError:nil];
    if (g_ppipe) [g_ppipe abortWithError:nil];
    /* Release buffers and pipes on g_q, behind any completion handler already queued there. */
    if (g_q) dispatch_sync(g_q, ^{
        dp_release();
        g_cpipe = nil; g_ppipe = nil;
    });
    /* Put the interfaces back to alternate setting 0 and let them go for the next stream. */
    if (g_cap)  { [g_cap selectAlternateSetting:0 error:nil];  [g_cap destroy];  g_cap = nil; }
    if (g_play) { [g_play selectAlternateSetting:0 error:nil]; [g_play destroy]; g_play = nil; }
}

/* Start streaming: claim the audio interfaces, open their isochronous pipes, switch the decks to
   USB audio and queue the capture transfers (playback starts from the capture handler). On any
   failure, everything opened so far is released again. */
static bool usb_open_all(void) {
    if (!usb_ensure_hid()) return false;
    NSError *e = nil;

    /* Playback stays off until the capture handler starts it; clear the debug counters. */
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
        g_cap_bytes[i] = g_cap_xf[i].buf.mutableBytes;
        atomic_store(&g_cap_tag[i], 0);
    }

    /* Decks to USB audio. */
    set_usb_switches(true);

    /* A new timeline and an empty capture ring. */
    memset(g_in_ring, 0, sizeof(g_in_ring));
    atomic_store(&g_cap_head, 0);
    atomic_store(&g_cap_early_head, 0);
    atomic_store(&g_er_placed, 0);
    atomic_store(&g_rd_frames, 0);
    g_er_differ = 0;
    g_er_judged = false;
    cap_prog_publish(0, 0);
    atomic_store(&g_cap_prog_last_fc, 0);
    atomic_store(&g_cap_prog_last_pos, 0);
    for (int i = 0; i < CAP_MAP_N; i++) atomic_store(&g_cap_idx_of[i], -1);
    g_cap_next_fc = 0;
    g_cap_fill_frac = 0;
    clk_reset();
    atomic_store(&g_total_cap_frames, 0);
    atomic_store(&g_total_play_frames, 0);

    /* A new stream generation, then queue the capture transfers, starting 32 frames (32 ms) ahead
       of the bus. */
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
    /* Nothing more to do if no stream is running. */
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
    dbg_er_log("result");
#endif
    /* Release the audio interfaces, then put the decks back on analogue thru if the box is here. */
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
    /* Abort the HID pipes, so the pending read completes and is not queued again. */
    if (g_hpipe_in)  [g_hpipe_in abortWithError:nil];
    if (g_hpipe_out) [g_hpipe_out abortWithError:nil];
    /* Release them on g_q, and not while hid_cmd is sending on the OUT pipe. */
    if (g_q) dispatch_sync(g_q, ^{
        pthread_mutex_lock(&g_hout_mtx);
        g_hpipe_in = nil; g_hpipe_out = nil;
        pthread_mutex_unlock(&g_hout_mtx);
    });
    /* Then the HID interface and the device itself; the next box is opened from scratch. */
    if (g_hid)  { [g_hid destroy]; g_hid = nil; }
    if (g_dev)  { [g_dev destroy]; g_dev = nil; }
    atomic_store(&g_hw_connected, false);
}

/* The device is published (in the plug-in's device list, so it shows in the system's device
   lists) only while a box is attached. A box in its bootloader keeps it published so clients can
   read boot_mode from the 'sl2s' status. */
static _Atomic bool g_unlisted;   /* briefly out of the list, to be set up again (relist_device) */
static bool device_published(void) {
    if (atomic_load(&g_unlisted)) return false;
    return atomic_load(&g_box_present) || atomic_load(&g_boot_mode);
}

/* Which boxes are attached now: running firmware and/or bootloader. */
static void scan_attached(bool *audio, bool *bootloader) {
    *audio = *bootloader = false;
    /* Every USB device with the SL 2's vendor and product IDs. */
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
    /* Tell them apart by bcdDevice. */
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

/* Have the HAL set the device up again, so it reads a changed input safety offset (it reads safety
   offsets only at device setup; a configuration change doesn't refresh them): take the device out of
   the device list and put it back half a second later. Only with nothing streaming; on the hot-plug
   queue. */
static void relist_device(void) {
    if (atomic_load(&g_io_running) || !device_published()) return;
    if (atomic_exchange(&g_unlisted, true)) return;   /* already being set up again */
    notify_device_list_changed();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), g_hotplug_q, ^{
        in_safety_apply();
        atomic_store(&g_unlisted, false);
        notify_device_list_changed();
        LOG("Device set up again: input safety offset %.1f ms", atomic_load(&g_in_safety_us) / 1000.0);
    });
}
/* ... if the offset the device should have differs from the one it was set up with. */
static void relist_if_safety_changed(void) {
    if (!g_hotplug_q) return;
    dispatch_async(g_hotplug_q, ^{
        if (atomic_load(&g_in_safety_us) != in_safety_wanted_us()) relist_device();
    });
}

/* Open a newly attached box and, with no stream running, put its decks on analogue thru (the box
   powers up with thru on or off depending on a board input), as at stream stop, so turntables
   reach the mixer until an app streams. The first open can be refused ("exclusive open of usb
   object failed") while macOS is still setting the box up, about 1 connect in 30: retry for
   about a second. */
#define CONNECT_TRIES    10
#define CONNECT_RETRY_MS 100
static void connect_box(int attempt) {
    if (!atomic_load(&g_box_present)) return;   /* unplugged meanwhile */
    /* Open it; unless a stream is already running, set thru and the current rate. */
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
    /* Refused: try again on the hot-plug queue shortly, up to CONNECT_TRIES times in all. */
    if (attempt + 1 < CONNECT_TRIES)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, CONNECT_RETRY_MS * NSEC_PER_MSEC), g_hotplug_q,
                       ^{ connect_box(attempt + 1); });
    else
        LOG("Rane SL 2: could not open the box after %d attempts", CONNECT_TRIES);
}

/* Hot-plug: SL 2 USB devices appeared (on the hot-plug queue). */
static void on_usb_added(void *refcon, io_iterator_t iter) {
    /* Which kinds arrived: running firmware and/or bootloader (draining also re-arms the iterator). */
    io_service_t s;
    bool audio = false, bootloader = false;
    while ((s = IOIteratorNext(iter))) {
        if (svc_bcd(s) == BCD_LOADER) bootloader = true;
        else                          audio = true;
        IOObjectRelease(s);
    }
    if (!audio && !bootloader) return;
    bool was_published = device_published();

    /* A box with firmware: open it. */
    if (audio) {
        /* A new connection: its early read is judged afresh, without a fallback. */
        atomic_store(&g_in_fallback, false);
        atomic_store(&g_early_state, EARLY_UNKNOWN);
        atomic_store(&g_in_dropouts, 0);
        atomic_store(&g_boot_mode, false);
        atomic_store(&g_box_present, true);
        LOG("Rane SL 2 USB connected");
        connect_box(0);
    }
    /* A box in its bootloader: only note it, so clients can see it needs its firmware. */
    if (bootloader) {
        atomic_store(&g_boot_mode, true);
        note_bootloader_device();
    }
    /* The device has just appeared in the HAL's list: tell the HAL, which sets it up. */
    if (!was_published) {
        in_safety_apply();
        notify_device_list_changed();
    }
}

/* Hot-plug: SL 2 USB devices went away (on the hot-plug queue). */
static void on_usb_removed(void *refcon, io_iterator_t iter) {
    /* Drain the iterator (which re-arms it); stop if nothing was actually removed. */
    io_service_t s;
    bool removed = false;
    while ((s = IOIteratorNext(iter))) { IOObjectRelease(s); removed = true; }
    if (!removed) return;
    /* The removed service can no longer be asked what it was: see what is still attached. */
    bool audio, bootloader;
    scan_attached(&audio, &bootloader);
    bool was_published = device_published();

    /* The box with firmware is gone: close everything that was open on it. */
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
    /* Bootloader mode follows what is still attached; tell the HAL if the device left its list. */
    atomic_store(&g_boot_mode, bootloader);
    if (was_published != device_published()) notify_device_list_changed();
}

/* Watch for the box being plugged in and unplugged, and handle one already attached. */
static void start_hotplug_monitor(void) {
    /* A serial queue for hot-plug work, and an IOKit notification port that delivers onto it. */
    dispatch_queue_t hq = g_hotplug_q = dispatch_queue_create("com.rane.sl2.hotplug", DISPATCH_QUEUE_SERIAL);
    g_notify_port = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(g_notify_port, hq);

    /* The SL 2's vendor and product IDs, for the matching dictionaries below. */
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
    in_safety_load();
    in_safety_apply();
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
        /* Stop any stream still running at the old rate. */
        bool was_streaming = atomic_load(&g_io_running);
        if (was_streaming) usb_stop_streaming(true);
        /* Switch the rate and start a new timeline at it. */
        g_sr = (Float64)action;
        clk_reset();
        atomic_fetch_add(&g_zts_seed, 1);   /* new timeline for the HAL */
        /* Restart the stream at the new rate, or, with none running, just tell the box. */
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

/* ----------------------------------------------------------------------------
 * Output volume and mute. The SL 2 has no volume control of its own: no HID command sets a level,
 * and the box's FPGA, which carries the audio, takes no level from the host. So the driver scales
 * the samples itself: a master volume and mute (element 0, what the menu bar and the volume keys
 * use) and a volume for each output channel (elements 1-4, shown per channel in Audio MIDI Setup).
 * A channel's gain is the master's times its own. Without the master, the HAL's virtual main volume
 * (the volume keys) would move only the preferred stereo pair, channels 1-2: the channels are
 * discrete, not a speaker layout it could follow.
 *
 * The gain is applied in ProcessMix: the HAL calls it in place on the mix of all its clients, in the
 * same IO cycle, just before WriteMix. Applying it there adds no buffering and moves no timing.
 * Every client follows the volume, Serato included. The driver keeps the levels and mute only in
 * memory, starting at 0 dB, unmuted; the HAL saves them per device and sets them again whenever the
 * device is published (after a replug or a restart of coreaudiod), as it does for any device.
 * ---------------------------------------------------------------------------- */
#define VOL_MIN_DB      (-64.0f)   /* scalar 0 is silence (see vol_scalar_to_db for the curve) */
#define VOL_MAX_DB      0.0f
#define VOL_RAMP_MS     5.0f       /* a full-scale change of gain (0 to 1) takes this long */

/* The volume controls' levels: [0] the master, [1..NCH] each channel. */
static _Atomic float g_vol_db[1 + NCH] = { VOL_MAX_DB, VOL_MAX_DB, VOL_MAX_DB, VOL_MAX_DB, VOL_MAX_DB };
static _Atomic bool  g_vol_mute = false;
/* Each channel's linear gain from the levels and mute, and the gain the last ProcessMix ended at.
   The HAL can call ProcessMix from more than one IO thread, but never two at once, so relaxed loads
   and stores are enough. */
static _Atomic float g_vol_gain[NCH]    = { 1.0f, 1.0f, 1.0f, 1.0f };
static _Atomic float g_vol_applied[NCH] = { 1.0f, 1.0f, 1.0f, 1.0f };

/* Every control the device owns, in its ControlList order: the volumes (master, then each channel),
   then the mute. kVolObjs is the volumes: the first 1 + NCH entries. */
#define VOL_NCONTROLS   (2 + NCH)
static const AudioObjectID kControlObjs[VOL_NCONTROLS] = { kObjVolume, kObjVolCh1, kObjVolCh2, kObjVolCh3, kObjVolCh4, kObjMute };
#define kVolObjs kControlObjs
/* Serialises volume and mute changes (on the HAL's property threads; never taken on the IO path), so
   two changes at once can't leave the gains computed from a half-updated state. */
static pthread_mutex_t g_vol_mtx = PTHREAD_MUTEX_INITIALIZER;

/* Which level a volume control sets (0 = master, 1..NCH = channel), or -1 if oid is not one. */
static int vol_index(AudioObjectID oid) {
    for (int i = 0; i <= NCH; i++) if (kVolObjs[i] == oid) return i;
    return -1;
}
static bool vol_is_control(AudioObjectID oid) { return oid == kObjMute || vol_index(oid) >= 0; }

/* Slider position (the scalar, 0..1) and level, by CoreAudio's standard volume curve (its "2 over 1"
   transfer function): the scalar is the square of the level's position in the dB range. The Mac's
   built-in output and Apple-driven USB interfaces follow it, so the slider and the volume keys feel
   the same here as there: half-way is about -19 dB, not half the dB range. */
static float vol_scalar_to_db(float s) {
    if (!isfinite(s) || s < 0) s = 0; else if (s > 1) s = 1;
    return VOL_MIN_DB + sqrtf(s) * (VOL_MAX_DB - VOL_MIN_DB);
}
static float vol_db_to_scalar(float db) {
    if (!isfinite(db) || db <= VOL_MIN_DB) return 0;
    if (db >= VOL_MAX_DB) return 1;
    float x = (db - VOL_MIN_DB) / (VOL_MAX_DB - VOL_MIN_DB);
    return x * x;
}
/* A level's linear gain; the bottom of the range is silence. */
static float vol_db_to_gain(float db) { return db <= VOL_MIN_DB ? 0.0f : powf(10.0f, db / 20.0f); }

/* Recompute each channel's gain after a change of level or mute. */
static void vol_update_gain(void) {
    float master = atomic_load(&g_vol_mute) ? 0.0f : vol_db_to_gain(atomic_load(&g_vol_db[0]));
    for (int ch = 0; ch < NCH; ch++)
        atomic_store(&g_vol_gain[ch], master * vol_db_to_gain(atomic_load(&g_vol_db[1 + ch])));
}

/* Tell the HAL's clients that a volume control's value (both its scalar and dB forms) or the mute
   control's value changed. */
static void vol_notify(AudioObjectID oid) {
    if (!g_host) return;
    if (oid == kObjMute) {
        AudioObjectPropertyAddress mute = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        g_host->PropertiesChanged(g_host, kObjMute, 1, &mute);
    } else {
        AudioObjectPropertyAddress vol[2] = {
            { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        };
        g_host->PropertiesChanged(g_host, oid, 2, vol);
    }
}

/* ProcessMix, on the IO thread: scale each channel of the mix by its gain. A channel at unity gain
   is not touched. A change of gain ramps at a fixed rate (VOL_RAMP_MS for the full range), carrying
   on into the next cycles if need be, so a step doesn't click whatever the IO buffer size. */
static void vol_process_mix(float *buf, UInt32 frames) {
    /* Each channel's target and current gain; nothing to do if every channel is steady at unity. */
    float target[NCH], g[NCH];
    bool unity = true, ramping = false;
    for (int ch = 0; ch < NCH; ch++) {
        target[ch] = atomic_load_explicit(&g_vol_gain[ch], memory_order_relaxed);
        g[ch] = atomic_load_explicit(&g_vol_applied[ch], memory_order_relaxed);
        if (g[ch] != target[ch]) ramping = true;
        if (g[ch] != 1.0f || target[ch] != 1.0f) unity = false;
    }
    if (unity) return;

    /* Steady: one gain per channel, in a single pass. */
    if (!ramping) {
        for (UInt32 f = 0; f < frames; f++)
            for (int ch = 0; ch < NCH; ch++) buf[f * NCH + ch] *= target[ch];
        return;
    }
    /* Ramping: each channel moves towards its target by at most one step per frame. */
    float step = 1000.0f / (VOL_RAMP_MS * (float)g_sr);
    for (UInt32 f = 0; f < frames; f++)
        for (int ch = 0; ch < NCH; ch++) {
            g[ch] = g[ch] < target[ch] ? fminf(g[ch] + step, target[ch]) : fmaxf(g[ch] - step, target[ch]);
            buf[f * NCH + ch] *= g[ch];
        }
    for (int ch = 0; ch < NCH; ch++) atomic_store_explicit(&g_vol_applied[ch], g[ch], memory_order_relaxed);
}

/* A new stream starts at the current gains rather than ramping from where the last one ended. */
static void vol_snap(void) {
    for (int ch = 0; ch < NCH; ch++) atomic_store(&g_vol_applied[ch], atomic_load(&g_vol_gain[ch]));
}

/* The volume and mute controls' properties. */
static UInt32 vol_property_size(AudioObjectID oid, AudioObjectPropertySelector s) {
    switch (s) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:              return sizeof(AudioClassID);
        case kAudioObjectPropertyOwner:              return sizeof(AudioObjectID);
        case kAudioObjectPropertyOwnedObjects:       return 0;
        case kAudioObjectPropertyName:               return sizeof(CFStringRef);
        case kAudioControlPropertyScope:             return sizeof(AudioObjectPropertyScope);
        case kAudioControlPropertyElement:           return sizeof(AudioObjectPropertyElement);
    }
    if (vol_index(oid) >= 0) switch (s) {
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: return sizeof(Float32);
        case kAudioLevelControlPropertyDecibelRange:            return sizeof(AudioValueRange);
    }
    if (oid == kObjMute && s == kAudioBooleanControlPropertyValue) return sizeof(UInt32);
    return UINT32_MAX;   /* not a property of this control */
}

static bool vol_has_property(AudioObjectID oid, AudioObjectPropertySelector s) {
    return vol_property_size(oid, s) != UINT32_MAX;
}

static bool vol_property_settable(AudioObjectID oid, AudioObjectPropertySelector s) {
    return (vol_index(oid) >= 0 && (s == kAudioLevelControlPropertyScalarValue || s == kAudioLevelControlPropertyDecibelValue)) ||
           (oid == kObjMute && s == kAudioBooleanControlPropertyValue);
}

static OSStatus vol_get_property(AudioObjectID oid, AudioObjectPropertySelector s, UInt32 inSize, UInt32 *outSize, void *outData) {
    static CFStringRef const names[1 + NCH] = {
        CFSTR("Output Volume"), CFSTR("Left Deck Out L"), CFSTR("Left Deck Out R"),
        CFSTR("Right Deck Out L"), CFSTR("Right Deck Out R")
    };
    UInt32 need = vol_property_size(oid, s);
    if (need == UINT32_MAX) return kAudioHardwareUnknownPropertyError;
    if (inSize < need) return kAudioHardwareBadPropertySizeError;
    *outSize = need;
    int v = vol_index(oid);   /* -1 for the mute control */
    switch (s) {
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = v >= 0 ? kAudioLevelControlClassID : kAudioBooleanControlClassID; return 0;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = v >= 0 ? kAudioVolumeControlClassID : kAudioMuteControlClassID; return 0;
        case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kObjDevice; return 0;
        case kAudioObjectPropertyOwnedObjects: return 0;
        case kAudioObjectPropertyName: *(CFStringRef*)outData = v >= 0 ? names[v] : CFSTR("Output Mute"); return 0;
        case kAudioControlPropertyScope: *(AudioObjectPropertyScope*)outData = kAudioObjectPropertyScopeOutput; return 0;
        case kAudioControlPropertyElement: *(AudioObjectPropertyElement*)outData = v > 0 ? (UInt32)v : kAudioObjectPropertyElementMain; return 0;
        case kAudioLevelControlPropertyScalarValue: *(Float32*)outData = vol_db_to_scalar(atomic_load(&g_vol_db[v])); return 0;
        case kAudioLevelControlPropertyDecibelValue: *(Float32*)outData = atomic_load(&g_vol_db[v]); return 0;
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange *r = (AudioValueRange*)outData;
            r->mMinimum = VOL_MIN_DB; r->mMaximum = VOL_MAX_DB;
            return 0;
        }
        /* The conversions take their input in the output buffer. */
        case kAudioLevelControlPropertyConvertScalarToDecibels: *(Float32*)outData = vol_scalar_to_db(*(Float32*)outData); return 0;
        case kAudioLevelControlPropertyConvertDecibelsToScalar: *(Float32*)outData = vol_db_to_scalar(*(Float32*)outData); return 0;
        case kAudioBooleanControlPropertyValue: *(UInt32*)outData = atomic_load(&g_vol_mute) ? 1 : 0; return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus vol_set_property(AudioObjectID oid, AudioObjectPropertySelector s, UInt32 inSize, const void *inData) {
    if (!vol_property_settable(oid, s)) return kAudioHardwareUnsupportedOperationError;
    if (!inData || inSize < vol_property_size(oid, s)) return kAudioHardwareBadPropertySizeError;
    int v = vol_index(oid);
    if (v >= 0 && !isfinite(*(const Float32*)inData)) return kAudioHardwareIllegalOperationError;
    /* Store the new level or mute and recompute the gains as one step. */
    bool changed;
    pthread_mutex_lock(&g_vol_mtx);
    if (v >= 0) {
        Float32 x = *(const Float32*)inData;
        float db = s == kAudioLevelControlPropertyScalarValue ? vol_scalar_to_db(x)
                 : (x < VOL_MIN_DB ? VOL_MIN_DB : x > VOL_MAX_DB ? VOL_MAX_DB : x);
        changed = db != atomic_load(&g_vol_db[v]);
        atomic_store(&g_vol_db[v], db);
    } else {
        bool mute = *(const UInt32*)inData != 0;
        changed = mute != atomic_load(&g_vol_mute);
        atomic_store(&g_vol_mute, mute);
    }
    if (changed) vol_update_gain();
    pthread_mutex_unlock(&g_vol_mtx);
    if (changed) vol_notify(oid);
    return 0;
}

static Boolean SL2_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr) {
    if (!addr) return false;
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    /* The plug-in object */
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
    /* The device, including the SL 2's custom properties ('sl2h', 'sl2s', 'sl2q') */
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
            case kSL2PropMeters:
            case kSL2PropInSafety:
            case kAudioObjectPropertyCustomPropertyInfoList:
                return true;
        }
        return false;
    }
    /* The input and output streams */
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
    /* The output volume and mute controls */
    if (vol_is_control(oid)) return vol_has_property(oid, s);
    (void)sc;
    return false;
}

static OSStatus SL2_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, Boolean *outSettable) {
    *outSettable = false;
    if (oid == kObjDevice && (addr->mSelector == kAudioDevicePropertyNominalSampleRate || addr->mSelector == kSL2PropHIDCommand ||
                              addr->mSelector == kSL2PropInSafety)) {
        *outSettable = true;
    } else if ((oid == kObjStreamIn || oid == kObjStreamOut) &&
               (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        *outSettable = true;
    } else if (vol_is_control(oid)) {
        if (!vol_has_property(oid, addr->mSelector)) return kAudioHardwareUnknownPropertyError;
        *outSettable = vol_property_settable(oid, addr->mSelector);
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

/* Whether the class qualifier wants a control of class cls, which derives from base and that from
   kAudioControlClassID. */
static bool control_wanted(UInt32 qsz, const void *qd, AudioClassID cls, AudioClassID base) {
    return owned_class_wanted(qsz, qd, cls) || owned_class_wanted(qsz, qd, base) ||
           owned_class_wanted(qsz, qd, kAudioControlClassID);
}

/* The device's owned objects in a scope, filtered by the class qualifier: the streams, and the
   output volume and mute controls. */
#define DEVICE_NOWNED   (2 + VOL_NCONTROLS)   /* the two streams and the controls */
static UInt32 device_owned_objects(AudioObjectPropertyScope sc, UInt32 qsz, const void *qd, AudioObjectID ids[DEVICE_NOWNED]) {
    UInt32 n = 0;
    bool in = sc != kAudioObjectPropertyScopeOutput, out = sc != kAudioObjectPropertyScopeInput;
    if (in  && owned_class_wanted(qsz, qd, kAudioStreamClassID)) ids[n++] = kObjStreamIn;
    if (out && owned_class_wanted(qsz, qd, kAudioStreamClassID)) ids[n++] = kObjStreamOut;
    bool vol  = out && control_wanted(qsz, qd, kAudioVolumeControlClassID, kAudioLevelControlClassID);
    bool mute = out && control_wanted(qsz, qd, kAudioMuteControlClassID, kAudioBooleanControlClassID);
    for (int i = 0; i < VOL_NCONTROLS; i++)
        if (kControlObjs[i] == kObjMute ? mute : vol) ids[n++] = kControlObjs[i];
    return n;
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

    /* The plug-in object */
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
    /* The device, including the SL 2's custom properties */
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
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID ids[DEVICE_NOWNED];
                *outSize = device_owned_objects(sc, qsz, qd, ids) * sizeof(AudioObjectID);
                return 0;
            }
            case kAudioDevicePropertyStreams:
                if (sc == kAudioObjectPropertyScopeInput || sc == kAudioObjectPropertyScopeOutput) *outSize = sizeof(AudioObjectID);
                else *outSize = 2 * sizeof(AudioObjectID);
                return 0;
            case kAudioObjectPropertyControlList: *outSize = sizeof kControlObjs; return 0;
            case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = 2 * sizeof(AudioValueRange); return 0;
            case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); return 0;
            case kAudioDevicePropertyPreferredChannelLayout:
                *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + NCH * sizeof(AudioChannelDescription);
                return 0;
            case kSL2PropHIDCommand:
            case kSL2PropStatus:
            case kSL2PropUnsolQueue:
            case kSL2PropMeters: *outSize = sizeof(CFDataRef); return 0;
            case kSL2PropInSafety: *outSize = sizeof(CFNumberRef); return 0;
            case kAudioObjectPropertyCustomPropertyInfoList: *outSize = 5 * sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
        }
    }
    /* The input and output streams */
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
    /* The output volume and mute controls */
    if (vol_is_control(oid)) {
        UInt32 n = vol_property_size(oid, s);
        if (n == UINT32_MAX) return kAudioHardwareUnknownPropertyError;
        *outSize = n;
        return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus get_property_data(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, UInt32 *outSize, void *outData) {
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    /* The plug-in object */
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

    /* The device, including the SL 2's custom properties */
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
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID ids[DEVICE_NOWNED];
                UInt32 n = device_owned_objects(sc, qsz, qd, ids);
                memcpy(outData, ids, n * sizeof(AudioObjectID));
                *outSize = n * sizeof(AudioObjectID);
                return 0;
            }
            case kAudioDevicePropertyStreams: {
                AudioObjectID *ids = (AudioObjectID*)outData;
                if (sc == kAudioObjectPropertyScopeInput) { ids[0] = kObjStreamIn; *outSize = sizeof(AudioObjectID); }
                else if (sc == kAudioObjectPropertyScopeOutput) { ids[0] = kObjStreamOut; *outSize = sizeof(AudioObjectID); }
                else { ids[0] = kObjStreamIn; ids[1] = kObjStreamOut; *outSize = 2 * sizeof(AudioObjectID); }
                return 0;
            }
            case kAudioObjectPropertyControlList:
                memcpy(outData, kControlObjs, sizeof kControlObjs);
                *outSize = sizeof kControlObjs;
                return 0;
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
                static const AudioServerPlugInCustomPropertyInfo all[5] = {
                    { kSL2PropHIDCommand, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL2PropStatus,     kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL2PropUnsolQueue, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL2PropMeters,     kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL2PropInSafety,   kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                };
                UInt32 n = inSize / sizeof(AudioServerPlugInCustomPropertyInfo);
                if (n > 5) n = 5;
                memcpy(outData, all, n * sizeof(AudioServerPlugInCustomPropertyInfo));
                *outSize = n * sizeof(AudioServerPlugInCustomPropertyInfo);
                return 0;
            }
            case kSL2PropHIDCommand: {
                /* The reply to this client's last 'sl2h' write (sent then), once; never sends. */
                uint8_t reply[HID_REPORT_LEN] = {0};
                /* Take this client's pending reply, if any (all zeros if none). */
                pthread_mutex_lock(&g_mutex);
                for (int i = 0; i < HID_CLIENTS; i++)
                    if (g_hid_replies[i].used && g_hid_replies[i].pid == pid && g_hid_replies[i].pending) {
                        memcpy(reply, g_hid_replies[i].reply, HID_REPORT_LEN);
                        g_hid_replies[i].pending = false;
                    }
                pthread_mutex_unlock(&g_mutex);
                /* Return it as a new CFData, which the caller releases. */
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, reply, HID_REPORT_LEN);
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL2PropStatus: {
                /* The status packet: fill in the live fields (the HID code keeps the rest up to
                   date), then return a copy as CFData. */
                pthread_mutex_lock(&g_mutex);
                g_st.connected = atomic_load(&g_hw_connected) ? 1 : 0;
                g_st.streaming = atomic_load(&g_io_running) ? 1 : 0;
                g_st.sample_rate = (uint32_t)g_sr;
                g_st.cap_frames = atomic_load(&g_total_cap_frames);
                g_st.play_frames = atomic_load(&g_total_play_frames);
                g_st.boot_mode = atomic_load(&g_boot_mode) ? 1 : 0;
                g_st.debug_build = SL2_DEBUG ? 1 : 0;
                g_st.in_safety_us = (uint32_t)atomic_load(&g_in_safety_us);
                g_st.in_safety_setting_us = (uint32_t)atomic_load(&g_in_safety_set_us);
                g_st.early_read = atomic_load(&g_early_state);
                g_st.hub_depth = atomic_load(&g_hub_depth);
                g_st.in_dropouts = atomic_load(&g_in_dropouts);
                pthread_mutex_unlock(&g_mutex);
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, (const UInt8*)&g_st, sizeof(g_st));
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL2PropInSafety: {
                /* The input safety offset setting, in us (the status says what the HAL is using). */
                int us = atomic_load(&g_in_safety_set_us);
                *(CFNumberRef*)outData = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &us);
                *outSize = sizeof(CFNumberRef);
                return 0;
            }
            case kSL2PropMeters: {
                /* The peaks since the last read, each reset as it is taken; reading also keeps the
                   meters running for another METER_IDLE_MS. */
                Float32 v[2 * NCH];
                meter_take(pid, v);
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, (const UInt8*)v, sizeof v);
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL2PropUnsolQueue: {
                /* This client's reports since its last read, oldest first. */
                pthread_mutex_lock(&g_unsol_mtx);
                /* Its read position; if it fell over UNSOL_Q_MAX behind, skip to the oldest kept. */
                uint64_t *r = unsol_cursor(pid);
                if (g_unsol_w - *r > UNSOL_Q_MAX) *r = g_unsol_w - UNSOL_Q_MAX;
                /* Copy every report from there to the newest, moving its position past them. */
                CFMutableDataRef md = CFDataCreateMutable(kCFAllocatorDefault, (CFIndex)(g_unsol_w - *r) * HID_REPORT_LEN);
                for (; *r < g_unsol_w; (*r)++) CFDataAppendBytes(md, g_unsol_q[*r % UNSOL_Q_MAX], HID_REPORT_LEN);
                pthread_mutex_unlock(&g_unsol_mtx);
                *(CFDataRef*)outData = md;
                *outSize = sizeof(CFDataRef);
                return 0;
            }
        }
    }

    /* The input and output streams */
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
    /* The output volume and mute controls */
    if (vol_is_control(oid)) return vol_get_property(oid, s, inSize, outSize, outData);
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
     0xF3 <ms hi> <lo> hold the USB queue this long, once, as a completion stall would
     0xF4 <n>          treat the next n capture packets as errored
     0xF5 <0|1>        1: the early reader places nothing, as on a Mac where it can't work */
static OSStatus dbg_command(const uint8_t *c, CFIndex len) {
    /* Every command needs at least its first argument byte, [5]. */
    if (len < 6) return kAudioHardwareBadPropertySizeError;
    switch (c[0]) {
        case 0xF3:
            if (len < 7) return kAudioHardwareBadPropertySizeError;
            atomic_store(&dbg_stall_ms, ((uint32_t)c[5] << 8) | c[6]);
            DBG_LOG("DBG next capture completion stalls the USB queue for %u ms", atomic_load(&dbg_stall_ms));
            return 0;
        case 0xF4:
            atomic_store(&dbg_err_pkts, c[5]);
            DBG_LOG("DBG next %u capture packets treated as errored", c[5]);
            return 0;
        case 0xF5:
            atomic_store(&dbg_no_early, c[5] != 0);
            DBG_LOG("DBG early capture read %{public}s", c[5] ? "off" : "on");
            return 0;
    }
    return kAudioHardwareIllegalOperationError;
}
#endif

static OSStatus SL2_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, const void *inData) {
    /* 'sl2i': the input safety offset setting, in us (IN_SAFETY_MIN_US to IN_SAFETY_MAX_US). The HAL
       reads safety offsets only when it sets the device up, so it changes only with nothing
       streaming: refused otherwise. The setting is kept, and the device set up again with it. Setting
       it also clears a fallback (see early_read_judge): the next stream judges the early read afresh. */
    if (oid == kObjDevice && addr->mSelector == kSL2PropInSafety) {
        if (inSize != sizeof(CFNumberRef) || !inData) return kAudioHardwareBadPropertySizeError;
        CFNumberRef n = *(CFNumberRef*)inData;
        int us = 0;
        if (!n || CFGetTypeID(n) != CFNumberGetTypeID() || !CFNumberGetValue(n, kCFNumberIntType, &us) ||
            us < IN_SAFETY_MIN_US || us > IN_SAFETY_MAX_US) return kAudioHardwareIllegalOperationError;
        if (atomic_load(&g_io_running)) return kAudioHardwareIllegalOperationError;
        atomic_store(&g_in_safety_set_us, us);
        atomic_store(&g_in_fallback, false);
        atomic_store(&g_early_state, EARLY_UNKNOWN);
        in_safety_save();
        LOG("Input safety offset setting: %.1f ms", us / 1000.0);
        relist_if_safety_changed();
        return 0;
    }
    /* 'sl2h': a client's HID command for the box (a CFData report); its reply is kept for the
       client's next read of 'sl2h'. */
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
            /* A box command: copy it into a full-length, zero-padded report. */
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

            /* Keep the reply for this client's next read of 'sl2h', in its own slot or else the
               slot used least recently. */
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
    /* A new rate, set on the device or through a stream's format: ask the HAL to change it. */
    if (oid == kObjDevice && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64) || !inData) return kAudioHardwareBadPropertySizeError;
        return request_sample_rate(*(const Float64*)inData);
    }
    if ((oid == kObjStreamIn || oid == kObjStreamOut) &&
        (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize < sizeof(AudioStreamBasicDescription) || !inData) return kAudioHardwareBadPropertySizeError;
        return request_sample_rate(((const AudioStreamBasicDescription*)inData)->mSampleRate);
    }
    /* The output volume and mute controls */
    if (vol_is_control(oid)) return vol_set_property(oid, addr->mSelector, inSize, inData);
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SL2_StartIO(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid) {
    /* The first client starts the stream; if the box can't be opened, the client gets an error
       rather than silence on a timeline with no box behind it. */
    pthread_mutex_lock(&g_mutex);
    /* No IO is running yet, so a new stream starts at the current gain rather than ramping from
       the level the last one ended at. */
    if (g_io_clients == 0) vol_snap();
    if (g_io_clients == 0 && !usb_open_all()) {
        pthread_mutex_unlock(&g_mutex);
        LOG("StartIO failed: the SL 2 could not be opened");
        return kAudioHardwareNotRunningError;
    }
    /* Count the client; StopIO stops the stream when the last one leaves. */
    g_io_clients++;
    pthread_mutex_unlock(&g_mutex);
    return 0;
}

static OSStatus SL2_StopIO(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid) {
    /* The last client stops the stream and puts the decks back on analogue thru. The count is
       already zero if the box was unplugged while streaming (on_usb_removed resets it). */
    pthread_mutex_lock(&g_mutex);
    if (g_io_clients > 0) {
        g_io_clients--;
        if (g_io_clients == 0) usb_stop_streaming(true);
    } else {
        LOG("StopIO with no client running (the box was unplugged while it streamed)");
    }
    bool idle = g_io_clients == 0;
    pthread_mutex_unlock(&g_mutex);
    /* Nothing streams now: if the early read was found not to work, set the device up again with the
       fallback offset. */
    if (idle) relist_if_safety_changed();
    return 0;
}

/* The latest period boundary on the timeline (see g_clk_*) at or before now, and its host time.
   Every answer lies on the same line, so the HAL never sees a timestamp out of line. */
static OSStatus SL2_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    /* The timeline position now. */
    uint64_t h; double s, tpf;
    clk_get(&h, &s, &tpf);
    double pos = s + ((double)mach_absolute_time() - (double)h) / tpf;
    double period = pos > 0 ? floor(pos / ZTS_PERIOD_FRAMES) * ZTS_PERIOD_FRAMES : 0;   /* latest period boundary */

    /* That boundary, its host time on the line, and the seed (changed when the timeline restarts). */
    *outSampleTime = period;
    *outHostTime   = (uint64_t)((double)h + (period - s) * tpf);
    *outSeed       = atomic_load(&g_zts_seed);
    return 0;
}

static OSStatus SL2_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, Boolean *outWillDo, Boolean *outIsInPlace) {
    *outIsInPlace = true;
    /* ProcessMix applies the output volume to the mix, in place, just before WriteMix (see
       vol_process_mix). */
    *outWillDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationProcessMix ||
                  op == kAudioServerPlugInIOOperationWriteMix);
    return 0;
}

static OSStatus SL2_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { return 0; }

static OSStatus SL2_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, AudioObjectID sid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci, void *ioMain, void *ioSec) {
    float *buf = (float*)ioMain;
    /* ReadInput: from the capture ring, at the HAL's input sample time. */
    if (op == kAudioServerPlugInIOOperationReadInput) {
        /* Copy each frame from the capture ring, or silence where capture has not written yet (it
           is later than the input safety offset, or the box is gone) or wrote too long ago. */
        uint64_t pos = (uint64_t)ci->mInputTime.mSampleTime;
        /* First the packets that have arrived since the last completion (see "Early read"). */
        cap_read_early();
        uint64_t done_head = atomic_load_explicit(&g_cap_head, memory_order_acquire);
        uint64_t early_head = atomic_load_explicit(&g_cap_early_head, memory_order_acquire);
        uint64_t head = early_head > done_head ? early_head : done_head;
        /* After the first capture: count what ReadInput asked for, and the cycles it had to fill with
           silence because the frames weren't captured in time. */
        if (done_head) {
            atomic_fetch_add_explicit(&g_rd_frames, frames, memory_order_relaxed);
            if (pos + frames > head) atomic_fetch_add_explicit(&g_in_dropouts, 1, memory_order_relaxed);
        }
#if SL2_DEBUG
        if (done_head) {   /* how much the early read gave, and the margin */
            uint64_t end = pos + frames;
            if (end > done_head) {
                uint64_t from = pos > done_head ? pos : done_head;
                uint64_t upto = end < head ? end : head;
                if (upto > from) atomic_fetch_add_explicit(&dbg_rd_early, upto - from, memory_order_relaxed);
            }
            if (end > head) atomic_fetch_add_explicit(&dbg_rd_short, end - (pos > head ? pos : head), memory_order_relaxed);
            int64_t margin = (int64_t)head - (int64_t)end;
            if (margin < atomic_load_explicit(&dbg_rd_margin_min, memory_order_relaxed))
                atomic_store_explicit(&dbg_rd_margin_min, margin, memory_order_relaxed);
        }
#endif
        for (UInt32 f = 0; f < frames; f++) {
            uint64_t p = pos + f;
            if (p >= head || head - p > CAP_VALID_SPAN) {
                memset(buf + f * NCH, 0, NCH * sizeof(float));
                continue;
            }
            memcpy(buf + f * NCH, &g_in_ring[(p & RING_MASK) * NCH], NCH * sizeof(float));
        }

        /* ProcessMix: the mix of all clients, before WriteMix: apply the output volume. */
    } else if (op == kAudioServerPlugInIOOperationProcessMix) {
        if (sid == kObjStreamOut && buf) {
            vol_process_mix(buf, frames);
            if (meter_active()) meter_frames(NCH, buf, frames);
        }

        /* WriteMix: into the deep schedule's queued transfers, at the HAL's output sample time. */
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
        /* The schedule is off (not started yet, or stopping): the mix is dropped. */
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
