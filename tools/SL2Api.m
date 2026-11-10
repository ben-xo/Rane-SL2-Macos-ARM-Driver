/*
 * SL2Api.m — Universal (arm64 + x86_64) replacement for /Library/Frameworks/SL2Api.framework
 *
 * Rane's SL2Api is the library Serato DJ Pro 2.5.5 and Rane's "SL 2 Audio Control Panel" load to
 * talk to an SL 2. This one implements the same exported functions, with the same arguments,
 * results and return codes as Rane's (compared with its disassembly), on top of the SL2Device
 * CoreAudio HAL plug-in's custom properties:
 *   'sl2h'  write a 64-byte HID command; the next read returns the box's reply
 *   'sl2s'  read the driver's status (SL2StatusPacket)
 *   'sl2q'  read this process's queued reports (the box's 0x40 reports and the driver's events)
 * Without the plug-in there is no path to the box: commands fail and only USB presence is known.
 *
 * Return codes, as Rane's: 0 = done, RH_ERR_BAD_ARG = bad handle or argument, RH_ERR_NOT_CONNECTED
 * = no box, RH_ERR_NO_REPLY = the box didn't answer. Callbacks are called on this library's own
 * serial queue, as Rane's are on its own monitor thread.
 */

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <os/log.h>

#define VID 0x1cc5
#define PID 0x0013

#define kSL2PropHIDCommand  'sl2h'
#define kSL2PropStatus      'sl2s'
#define kSL2PropUnsolQueue  'sl2q'

enum {
    RH_OK                = 0,
    RH_ERR_NO_REPLY      = 4,
    RH_ERR_BAD_ARG       = 8,
    RH_ERR_NOT_CONNECTED = 12,
};

/* The box's HID protocol (docs/SL2-COMMANDS.md): one 64-byte report per command and reply,
   [0] = command, [1..4] = tag, [5..] = arguments / results. */
enum {
    HID_REPORT_LEN         = 64,
    HID_MAX_ARGS           = HID_REPORT_LEN - 5,
    HIDI_MAX_LEN           = 58,     /* bytes of Hidi messages one 0x41 / 0x40 report carries */
    SL2_CMD_VERSION        = 0x01,
    SL2_CMD_PORT_SPEED     = 0x0a,
    SL2_CMD_GET_RATE       = 0x30,
    SL2_CMD_CHALLENGE      = 0x37,
    SL2_CMD_HIDI           = 0x41,
    SL2_REPORT_HIDI        = 0x40,
    SL2_REJECTED           = 0xFF,
    SL2_EVT_SAMPLE_RATE    = 0x4F,   /* the driver's own event: [5..7] rate, big-endian */
};

/* The driver's status ('sl2s'); must match SL2Device.m */
typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];
    uint8_t  thru[4];
    uint8_t  port_a;
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
    uint32_t boot_mode;
    uint32_t debug_build;
    uint32_t in_safety_us;
    uint32_t in_safety_setting_us;
    uint32_t early_read;
    uint32_t hub_depth;
    uint64_t in_dropouts;
} SL2StatusPacket;

/* Rane's API types */
typedef struct {
    uint8_t length;            /* bytes of data, 1..HIDI_MAX_LEN */
    uint8_t data[HID_MAX_ARGS];
} RH_hidimsg_data_t;

typedef struct {
    uint8_t length;
    uint8_t data[HID_MAX_ARGS];
} RH_bridgepacket_data_t;

typedef struct {
    int this_port;             /* 0 = disconnected, 1 or 2 = the port the box is on */
    int other_port;
} RH_usb_port_status_t;

typedef struct {
    int sample_rate;
} SL2_samplerate_t;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;   /* one command at a time per process */
static uint32_t g_seq = 1;
static int g_handle = 0x52414E32;    /* the one handle RH_open gives out */
static int g_open_count = 0;         /* RH_open calls not yet closed (under g_lock) */
static int g_buffer_ms = 5;          /* the latency slider's value; see RH_set_buffer_millisecs */

/* Callbacks, set by the client, called on g_poll_q */
static void (* _Atomic g_hidi_cb)(RH_hidimsg_data_t *) = NULL;
static void (* _Atomic g_bridge_cb)(RH_bridgepacket_data_t *) = NULL;
static void (* _Atomic g_port_cb)(RH_usb_port_status_t *) = NULL;
static void (* _Atomic g_sr_cb)(SL2_samplerate_t *) = NULL;
static dispatch_queue_t  g_poll_q;
static dispatch_source_t g_poll_timer;
static bool g_was_connected;         /* box connected at the last poll (g_poll_q) */
static bool g_poll_primed;           /* the first poll only records the state (g_poll_q) */

static bool handle_ok(void *h) { return h == &g_handle; }

/* Every exported call is logged at debug level with its result, plus what was sent to and received
   from the box, so a client's use of the API can be followed without a debugger:
     log stream --level debug --predicate 'subsystem == "com.rane.sl2api"'
   Debug-level messages cost almost nothing unless a log stream asks for them. The SL2_* functions
   forward to RH_*, so they log under the RH_* name. */
static os_log_t api_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.rane.sl2api", "api"); });
    return log;
}
#define TRACE(fmt, ...) os_log_debug(api_log(), "%{public}s" fmt, __func__, ##__VA_ARGS__)
#define RET(e) ({ int ret_ = (e); TRACE(" -> %d", ret_); ret_; })

/* ============================================================================
 * The driver: its device, status and properties
 * ============================================================================ */

/* The SL 2's CoreAudio device, cached; the cache is dropped whenever the system's device list
   changes (the device only exists while a box is attached). */
static _Atomic AudioObjectID g_dev = kAudioObjectUnknown;
static OSStatus devices_changed(AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a, void *c) {
    atomic_store(&g_dev, kAudioObjectUnknown);
    return 0;
}

static AudioObjectID find_hal_device(void) {
    /* Once per process: listen for changes to the device list, which drop the cache. */
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AudioObjectPropertyAddress da = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &da, devices_changed, NULL);
    });
    /* Use the cached device while there is one. */
    AudioObjectID dev = atomic_load(&g_dev);
    if (dev != kAudioObjectUnknown) return dev;
    /* Otherwise look it up by the HAL plug-in's device UID, and cache it. */
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    UInt32 sz = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &dev) != noErr) return kAudioObjectUnknown;
    atomic_store(&g_dev, dev);
    return dev;
}

static bool hal_get_status(SL2StatusPacket *outSt) {
    /* Without the driver's device there is no status. */
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return false;
    /* Read the status property, which the driver returns as a CFData. */
    AudioObjectPropertyAddress a = { kSL2PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    bool ok = false;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) == noErr && d) {
        /* Copy what the driver sent (zero-filling the rest if it is shorter); it counts as a status
           if it holds every field before boot_mode. */
        memset(outSt, 0, sizeof *outSt);
        CFIndex n = CFDataGetLength(d);
        memcpy(outSt, CFDataGetBytePtr(d), (size_t)(n < (CFIndex)sizeof *outSt ? n : (CFIndex)sizeof *outSt));
        ok = n >= (CFIndex)offsetof(SL2StatusPacket, boot_mode);
        CFRelease(d);
    }
    return ok;
}

/* A box with the SL 2's vendor and product IDs is in the USB registry. */
static bool in_usb_registry(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return false;
    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    /* Any match means a box is attached. */
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (s) { IOObjectRelease(s); return true; }
    return false;
}

/* A box is attached: per the driver's status, or (without the driver) in the USB registry. */
static bool is_usb_present(void) {
    SL2StatusPacket st;
    if (hal_get_status(&st) && st.connected) return true;
    return in_usb_registry();
}

/* The SL 2 HAL plug-in is loaded in coreaudiod. */
static bool driver_loaded(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateBundleIDToPlugIn, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef bundle = CFSTR("io.github.pepeleedj.sl2device");
    AudioObjectID plugin = kAudioObjectUnknown;
    UInt32 sz = sizeof plugin;
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof bundle, &bundle, &sz, &plugin) == noErr &&
           plugin != kAudioObjectUnknown;
}

/* The driver's device, ready for commands (it has opened the box). Just after the box is plugged
   in, it is in the USB registry before the driver has opened it and listed its device: usually
   tens of milliseconds, about a second if macOS refuses the first open. A client that watches USB
   itself can call in that window (Serato DJ Pro 2.5.5 sends its hardware check about 25 ms after
   the box appears, and does not retry), so while the box is in the registry and the driver is
   loaded, wait for the device, up to READY_WAIT_MS. */
#define READY_WAIT_MS 2000
#define READY_POLL_MS 20
static AudioObjectID ready_hal_device(void) {
    for (int waited = 0; ; waited += READY_POLL_MS) {
        /* Ready: the device is listed and the driver reports the box open. */
        AudioObjectID dev = find_hal_device();
        SL2StatusPacket st;
        if (dev != kAudioObjectUnknown && hal_get_status(&st) && st.connected) return dev;
        /* Not ready, and not about to be (no box, or no driver to open it), or waited long enough. */
        if (waited >= READY_WAIT_MS || !in_usb_registry() || !driver_loaded()) return kAudioObjectUnknown;
        if (waited == 0) TRACE(": the box is attached but the driver has not opened it yet: waiting");
        usleep(READY_POLL_MS * 1000);
    }
}

/* Send one HID command through the driver and get the box's reply. RH_OK (reply_out holds the
   reply, which is SL2_REJECTED if the box refused the command), RH_ERR_NOT_CONNECTED or
   RH_ERR_NO_REPLY. */
static int send_hid_cmd(uint8_t cmd, const uint8_t *args, size_t nargs, uint8_t *reply_out) {
    /* No driver device (after waiting for one that is on its way) means no box; otherwise take the
       lock so each command gets its own reply. */
    AudioObjectID dev = ready_hal_device();
    if (dev == kAudioObjectUnknown) return RH_ERR_NOT_CONNECTED;
    pthread_mutex_lock(&g_lock);

    /* Build the request: the driver sends it when it is written, and the next read returns the
       reply with our tag. */
    uint8_t req[HID_REPORT_LEN] = {0};
    req[0] = cmd;
    uint32_t seq = g_seq++;
    memcpy(req + 1, &seq, 4);
    if (args && nargs > 0) memcpy(req + 5, args, nargs > HID_MAX_ARGS ? HID_MAX_ARGS : nargs);
    AudioObjectPropertyAddress a = { kSL2PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef in = CFDataCreate(kCFAllocatorDefault, req, HID_REPORT_LEN);
    OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &in);
    CFRelease(in);

    /* Read the reply back. */
    int result = RH_ERR_NO_REPLY;
    if (st == noErr) {
        CFDataRef out = NULL;
        UInt32 sz = sizeof(CFDataRef);
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &out) == noErr && out) {
            /* Copy at most one report, and accept it only if it carries our tag. */
            uint8_t reply[HID_REPORT_LEN] = {0};
            CFIndex n = CFDataGetLength(out);
            memcpy(reply, CFDataGetBytePtr(out), (size_t)(n < HID_REPORT_LEN ? n : HID_REPORT_LEN));
            CFRelease(out);
            if (memcmp(reply + 1, req + 1, 4) == 0) {
                if (reply_out) memcpy(reply_out, reply, HID_REPORT_LEN);
                result = RH_OK;
            }
        }
    }
    pthread_mutex_unlock(&g_lock);
    return result;
}

/* ============================================================================
 * Reports and events, polled from the driver and passed to the client's callbacks
 * ============================================================================ */

static void dispatch_report(const uint8_t pkt[HID_REPORT_LEN]) {
    /* The box's Hidi report: thru (notes 0x5C/0x5D), the LINE/PHONO switch (0x61) and 0x60. */
    void (*hidi)(RH_hidimsg_data_t *) = atomic_load(&g_hidi_cb);
    if (pkt[0] == SL2_REPORT_HIDI && hidi) {
        /* [5] = length of the messages (capped at what a report carries), [6..] = the messages. */
        RH_hidimsg_data_t m;
        memset(&m, 0, sizeof m);
        m.length = pkt[5] <= HIDI_MAX_LEN ? pkt[5] : HIDI_MAX_LEN;
        memcpy(m.data, pkt + 6, m.length);
        TRACE(": hidimsg callback %{public}.*P", (int)m.length, m.data);
        hidi(&m);
        return;
    }
    /* The driver's own sample-rate event. */
    void (*sr)(SL2_samplerate_t *) = atomic_load(&g_sr_cb);
    if (pkt[0] == SL2_EVT_SAMPLE_RATE && sr) {
        SL2_samplerate_t s = { .sample_rate = (pkt[5] << 16) | (pkt[6] << 8) | pkt[7] };
        TRACE(": sample-rate callback %d", s.sample_rate);
        sr(&s);
    }
}

/* Every 15 ms on g_poll_q: notice the box coming and going (the port-status callback: {1, 0} when
   it appears, {0, 0} when it goes, as Rane's sends), then pass on this process's queued reports. */
static void poll_driver(void) {
    /* Connected or not. */
    AudioObjectID dev = find_hal_device();
    SL2StatusPacket st;
    bool connected = dev != kAudioObjectUnknown && hal_get_status(&st) && st.connected;
    /* Tell the client when that changes; the first poll after poll_start only records it. */
    void (*port)(RH_usb_port_status_t *) = atomic_load(&g_port_cb);
    if (!g_poll_primed) g_poll_primed = true;
    else if (connected != g_was_connected && port) {
        RH_usb_port_status_t ps = { connected ? 1 : 0, 0 };
        TRACE(": port-status callback {%d, %d}", ps.this_port, ps.other_port);
        port(&ps);
    }
    /* Remember the state for the next poll; without a box there are no reports to read. */
    g_was_connected = connected;
    if (!connected) return;

    /* This process's reports since the last poll. */
    AudioObjectPropertyAddress a = { kSL2PropUnsolQueue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) == noErr && d) {
        CFIndex len = CFDataGetLength(d);
        const uint8_t *bytes = CFDataGetBytePtr(d);
        /* The queue is a run of 64-byte reports: pass each one on. */
        for (CFIndex off = 0; off + HID_REPORT_LEN <= len; off += HID_REPORT_LEN) dispatch_report(bytes + off);
        CFRelease(d);
    }
}

/* Start polling (from the first RH_open); RH_close stops it again with the last handle. */
static void poll_start(void) {
    /* Already polling: nothing to do. */
    if (g_poll_timer) return;
    /* Create the serial queue once, and have the first poll only record the box's state. */
    if (!g_poll_q) g_poll_q = dispatch_queue_create("com.rane.sl2api.poll", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_poll_q, ^{ g_poll_primed = false; });
    /* Poll every 15 ms (5 ms leeway), starting now. */
    g_poll_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_poll_q);
    dispatch_source_set_timer(g_poll_timer, DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_poll_timer, ^{ poll_driver(); });
    dispatch_resume(g_poll_timer);
}

static void poll_stop(void) {
    if (!g_poll_timer) return;
    dispatch_source_cancel(g_poll_timer);
    g_poll_timer = nil;
}

/* ============================================================================
 * Exported RH_* functions, as Rane's
 * ============================================================================ */

#define EXPORT __attribute__((visibility("default")))

EXPORT void *RH_open(void) {
    pthread_mutex_lock(&g_lock);
    g_open_count++;
    TRACE(": open handles %d", g_open_count);
    poll_start();
    pthread_mutex_unlock(&g_lock);
    return &g_handle;
}
EXPORT void *RH_open_private(int v) { (void)v; return RH_open(); }
EXPORT int   RH_private_last_connection_error(void) { return RET(0); }

EXPORT int RH_close(void *h) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    pthread_mutex_lock(&g_lock);
    if (g_open_count > 0 && --g_open_count == 0) poll_stop();
    TRACE(": open handles %d", g_open_count);
    pthread_mutex_unlock(&g_lock);
    return RET(RH_OK);
}

EXPORT int RH_get_vendor_id(void *h, int *v)  { if (!handle_ok(h) || !v) return RET(RH_ERR_BAD_ARG); *v = VID; return RET(RH_OK); }
EXPORT int RH_get_product_id(void *h, int *p) { if (!handle_ok(h) || !p) return RET(RH_ERR_BAD_ARG); *p = PID; return RET(RH_OK); }

/* Rane's takes only the output: four values, {1, 1, 2, 5}. */
EXPORT int RH_get_api_version(uint32_t v[4]) {
    if (!v) return RET(RH_ERR_BAD_ARG);
    v[0] = 1; v[1] = 1; v[2] = 2; v[3] = 5;
    return RET(RH_OK);
}

/* Rane's reports its kernel extension's version (16 bytes). There is no kernel extension here:
   report 1.0.0.0. */
EXPORT int RH_get_driver_version(void *h, uint32_t v[4]) {
    if (!handle_ok(h) || !v) return RET(RH_ERR_BAD_ARG);
    v[0] = 1; v[1] = 0; v[2] = 0; v[3] = 0;
    return RET(RH_OK);
}

/* The control panel's latency slider. Rane's kernel extension used it as the USB buffer size; the
   HAL plug-in's playback latency is fixed (it does not depend on a buffer size), so a value is
   validated (1-50 ms) and kept, and reading it back gives the plug-in's real output latency plus
   safety offset, rounded up. */
EXPORT int RH_set_buffer_millisecs(void *h, int ms) {
    if (!handle_ok(h) || ms < 1 || ms > 50) return RET(RH_ERR_BAD_ARG);
    if (!is_usb_present()) return RET(RH_ERR_NOT_CONNECTED);
    g_buffer_ms = ms;
    return RET(RH_OK);
}
EXPORT int RH_get_buffer_millisecs(void *h, int *ms) {
    if (!handle_ok(h) || !ms) return RET(RH_ERR_BAD_ARG);
    /* Needs the driver's device. */
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return RET(RH_ERR_NOT_CONNECTED);
    /* Read the output latency and safety offset (in frames). */
    UInt32 lat = 0, safety = 0, sz = sizeof(UInt32);
    Float64 sr = 0;
    AudioObjectPropertyAddress la = { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress sa = { kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(dev, &la, 0, NULL, &sz, &lat);
    sz = sizeof(UInt32);
    AudioObjectGetPropertyData(dev, &sa, 0, NULL, &sz, &safety);
    /* Read the sample rate and convert the frames to ms, rounded up; without a usable rate, give
       back the slider's stored value. */
    sz = sizeof(Float64);
    if (AudioObjectGetPropertyData(dev, &ra, 0, NULL, &sz, &sr) != noErr || sr <= 0) { *ms = g_buffer_ms; return RET(RH_OK); }
    *ms = (int)ceil((double)(lat + safety) * 1000.0 / sr);
    return RET(RH_OK);
}

/* {this port, other port}: the SL 2 has one USB port, so {1, 0} while connected. */
EXPORT int RH_get_usb_port_status(void *h, int st[2]) {
    if (!handle_ok(h) || !st) return RET(RH_ERR_BAD_ARG);
    if (!is_usb_present()) return RET(RH_ERR_NOT_CONNECTED);
    st[0] = 1; st[1] = 0;
    return RET(RH_OK);
}

/* The box's USB link speed (0x0a): 0 unconfigured, 1 full speed (no audio), 2 high speed. */
EXPORT int RH_get_port_speed(void *h, int *speed) {
    if (!handle_ok(h) || !speed) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL2_CMD_PORT_SPEED, NULL, 0, r);
    if (e) return RET(e);
    if (r[0] != SL2_CMD_PORT_SPEED) return RET(RH_ERR_NO_REPLY);
    *speed = r[5];
    return RET(RH_OK);
}

/* Rane's sends SysEx F0 17 52 <cp> F7 for control point 1 or 2; the SL 2's firmware implements no
   such message, so this only checks its arguments. */
EXPORT int RH_set_control_point(void *h, const int *cp) {
    if (!handle_ok(h) || !cp || *cp < 1 || *cp > 2) return RET(RH_ERR_BAD_ARG);
    if (!is_usb_present()) return RET(RH_ERR_NOT_CONNECTED);
    return RET(RH_OK);
}

/* The challenge Serato uses to check it is talking to genuine Rane hardware: send the 8-byte
   challenge with 0x37 and return the box's 8-byte answer. */
EXPORT int RH_driver_timer(void *h, const uint8_t *in, uint32_t inlen, uint8_t *out, uint32_t outlen) {
    TRACE(": challenge %{public}.*P (%u bytes, answer buffer %u)", in && inlen <= HID_MAX_ARGS ? (int)inlen : 0, in, inlen, outlen);
    if (!handle_ok(h) || !in || !out || inlen != 8 || outlen != 8) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL2_CMD_CHALLENGE, in, 8, r);
    if (e) return RET(e);
    if (r[0] != SL2_CMD_CHALLENGE) return RET(RH_ERR_NO_REPLY);
    memcpy(out, r + 5, 8);
    TRACE(": answer %{public}.*P", 8, out);
    return RET(RH_OK);
}

/* Ask the box (0x01): four values, major, minor, 0, and the 32-bit build stamp from reply[7..10]
   (big-endian). */
EXPORT int RH_get_firmware_version(void *h, uint32_t v[4]) {
    if (!handle_ok(h) || !v) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL2_CMD_VERSION, NULL, 0, r);
    if (e) return RET(e);
    if (r[0] != SL2_CMD_VERSION) return RET(RH_ERR_NO_REPLY);
    v[0] = r[5];
    v[1] = r[6];
    v[2] = 0;
    v[3] = ((uint32_t)r[7] << 24) | ((uint32_t)r[8] << 16) | ((uint32_t)r[9] << 8) | r[10];
    return RET(RH_OK);
}

/* The firmware Rane's framework embeds is v1.10: two values {major, minor}. */
EXPORT int RH_get_firmware_embedded_version(void *h, uint32_t v[2]) {
    if (!handle_ok(h) || !v) return RET(RH_ERR_BAD_ARG);
    v[0] = 1;
    v[1] = 10;
    return RET(RH_OK);
}

/* Send MIDI-style messages to the box with 0x41: m->length bytes from m->data. The firmware acts
   on Note On / Note Off of notes 0x5C and 0x5D (deck thru) and on the state-dump SysEx; it stops
   reading the message at anything else. */
EXPORT int RH_send_hidimsg(void *h, const RH_hidimsg_data_t *m) {
    TRACE(": %{public}.*P", m && m->length <= HIDI_MAX_LEN ? (int)m->length : 0, m ? m->data : NULL);
    if (!handle_ok(h) || !m || m->length == 0 || m->length > HIDI_MAX_LEN) return RET(RH_ERR_BAD_ARG);
    uint8_t args[1 + HIDI_MAX_LEN];
    args[0] = m->length;
    memcpy(args + 1, m->data, m->length);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL2_CMD_HIDI, args, 1u + m->length, r);
    if (e) return RET(e);
    return RET(r[0] == SL2_CMD_HIDI ? RH_OK : RH_ERR_NO_REPLY);
}

static int send_three(void *h, uint8_t a, uint8_t b, uint8_t c) {
    RH_hidimsg_data_t m = { .length = 3, .data = { a, b, c } };
    return RH_send_hidimsg(h, &m);
}

/* Ask the box for a state dump (SysEx F0 17 04 F7), as Rane's does. The box answers with 0x40
   reports of notes 0x5C/0x5D (deck thru), 0x61 (the LINE/PHONO switch) and 0x60, which reach the
   hidimsg callback like any other report. */
EXPORT int RH_get_all_controls(void *h) {
    TRACE(": state dump requested");
    RH_hidimsg_data_t m = { .length = 4, .data = { 0xF0, 0x17, 0x04, 0xF7 } };
    return RH_send_hidimsg(h, &m);
}

/* Rane's API: the SL 2 Audio Control Panel calls SL2_send_note_on(h, 0x5C, 0) for "deck 1 thru on"
   and SL2_send_note_off(h, 0x5C) for off (0x5D = deck 2). LINE/PHONO (note 0x61) is a physical
   switch: the box reports it but ignores a note sent for it. */
EXPORT int RH_send_note_on(void *h, uint8_t note, uint8_t vel) { return send_three(h, 0x90, note, vel); }
EXPORT int RH_send_note_off(void *h, uint8_t note)             { return send_three(h, 0x80, note, 0x00); }

/* Sends B0 <cc> <val> as Rane's does; the SL 2's firmware ignores control changes. */
EXPORT int RH_send_control_change(void *h, uint8_t cc, uint8_t val) { return send_three(h, 0xB0, cc, val); }

/* SysEx: Rane's wraps the bytes as F0 17 <bytes> F7. */
EXPORT int RH_send_sys_ex(void *h, const uint8_t *d, uint8_t len) {
    /* The wrapped message (the bytes plus F0 17 and F7) must fit in one report. */
    if (!handle_ok(h) || (!d && len) || len + 3u > HIDI_MAX_LEN) return RET(RH_ERR_BAD_ARG);
    /* Build F0 17 <bytes> F7 and send it as one Hidi message. */
    RH_hidimsg_data_t m = { .length = (uint8_t)(len + 3) };
    m.data[0] = 0xF0; m.data[1] = 0x17;
    if (len) memcpy(m.data + 2, d, len);
    m.data[2 + len] = 0xF7;
    return RH_send_hidimsg(h, &m);
}

EXPORT int RH_set_hidimsg_callback(void *h, void *cb) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    atomic_store(&g_hidi_cb, (void (*)(RH_hidimsg_data_t *))cb);
    return RET(RH_OK);
}

/* Bridge packets: Rane's sends HID 0x42, which the SL 2's firmware does not implement, and the box
   never sends one. Kept for the API: arguments are checked, nothing is sent, the callback never
   fires. */
EXPORT int RH_send_bridge_packet(void *h, const RH_bridgepacket_data_t *d) {
    if (!handle_ok(h) || !d) return RET(RH_ERR_BAD_ARG);
    return RET(is_usb_present() ? RH_OK : RH_ERR_NOT_CONNECTED);
}
EXPORT int RH_set_bridgepacket_callback(void *h, void *cb) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    atomic_store(&g_bridge_cb, (void (*)(RH_bridgepacket_data_t *))cb);
    return RET(RH_OK);
}

/* Stored only, as Rane's: it is called when the box appears ({1, 0}) or goes ({0, 0}). */
EXPORT int RH_set_usb_port_status_callback(void *h, void *cb) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    atomic_store(&g_port_cb, (void (*)(RH_usb_port_status_t *))cb);
    return RET(RH_OK);
}

/* Firmware update and re-enumeration are deliberately not implemented: the firmware tools
   (tools/firmware/) do that with safeguards, and a client must never trigger it by accident. */
EXPORT int RH_set_update_firmware(void *h, const void *d, int len, void *cb) { return RET(handle_ok(h) ? RH_OK : RH_ERR_BAD_ARG); }
EXPORT int RH_set_update_firmware_from_embedded(void *h, void *cb)            { return RET(handle_ok(h) ? RH_OK : RH_ERR_BAD_ARG); }
EXPORT int RH_set_alt_product_id(void *h, int pid)                            { return RET(handle_ok(h) ? RH_OK : RH_ERR_BAD_ARG); }

/* Rane's asks the box (0x13), which the SL 2 rejects: never a boot device by that test. */
EXPORT int RH_is_boot_device(void *h, int *b) {
    if (!handle_ok(h) || !b) return RET(RH_ERR_BAD_ARG);
    if (!is_usb_present()) return RET(RH_ERR_NOT_CONNECTED);
    *b = 0;
    return RET(RH_OK);
}

/* MIDI channels belonged to Rane's kernel extension; the SL 2 has no MIDI ports. */
EXPORT int RH_get_midi_channels(void *h, uint32_t ch[2]) {
    if (!handle_ok(h) || !ch) return RET(RH_ERR_BAD_ARG);
    ch[0] = ch[1] = 0;
    return RET(RH_OK);
}
EXPORT int RH_set_midi_channels(void *h, const uint32_t ch[2]) { return RET(handle_ok(h) && ch ? RH_OK : RH_ERR_BAD_ARG); }
EXPORT int RH_set_midi_ch_callback(void *h, void *cb)          { return RET(handle_ok(h) ? RH_OK : RH_ERR_BAD_ARG); }

/* Rane's flushes its queue of outgoing messages; every message here is sent at once. */
EXPORT int RH_flush_hidi_queue(void *h) { return RET(handle_ok(h) ? RH_OK : RH_ERR_BAD_ARG); }

/* ============================================================================
 * Exported SL2_* functions: Rane's forward to the RH_* ones, except the sample rate and
 * SL2_is_C0_device
 * ============================================================================ */

EXPORT void *SL2_open(void)                                   { return RH_open(); }
EXPORT int SL2_close(void *h)                                 { return RH_close(h); }
EXPORT int SL2_get_vendor_id(void *h, int *v)                 { return RH_get_vendor_id(h, v); }
EXPORT int SL2_get_product_id(void *h, int *p)                { return RH_get_product_id(h, p); }
EXPORT int SL2_get_api_version(uint32_t v[4])                 { return RH_get_api_version(v); }
EXPORT int SL2_get_driver_version(void *h, uint32_t v[4])     { return RH_get_driver_version(h, v); }
EXPORT int SL2_get_buffer_millisecs(void *h, int *ms)         { return RH_get_buffer_millisecs(h, ms); }
EXPORT int SL2_set_buffer_millisecs(void *h, int ms)          { return RH_set_buffer_millisecs(h, ms); }
EXPORT int SL2_get_usb_port_status(void *h, int st[2])        { return RH_get_usb_port_status(h, st); }
EXPORT int SL2_get_port_speed(void *h, int *speed)            { return RH_get_port_speed(h, speed); }
EXPORT int SL2_driver_timer(void *h, const uint8_t *in, uint32_t inlen, uint8_t *out, uint32_t outlen) {
    return RH_driver_timer(h, in, inlen, out, outlen);
}
EXPORT int SL2_get_firmware_version(void *h, uint32_t v[4])          { return RH_get_firmware_version(h, v); }
EXPORT int SL2_get_firmware_embedded_version(void *h, uint32_t v[2]) { return RH_get_firmware_embedded_version(h, v); }
EXPORT int SL2_get_all_controls(void *h)                             { return RH_get_all_controls(h); }
EXPORT int SL2_send_hidimsg(void *h, const RH_hidimsg_data_t *m)     { return RH_send_hidimsg(h, m); }
EXPORT int SL2_send_note_on(void *h, uint8_t note, uint8_t vel)      { return RH_send_note_on(h, note, vel); }
EXPORT int SL2_send_note_off(void *h, uint8_t note)                  { return RH_send_note_off(h, note); }
EXPORT int SL2_send_sys_ex(void *h, const uint8_t *d, uint8_t len)   { return RH_send_sys_ex(h, d, len); }
EXPORT int SL2_set_hidimsg_callback(void *h, void *cb)               { return RH_set_hidimsg_callback(h, cb); }
EXPORT int SL2_send_bridge_packet(void *h, const RH_bridgepacket_data_t *d) { return RH_send_bridge_packet(h, d); }
EXPORT int SL2_set_bridgepacket_callback(void *h, void *cb)          { return RH_set_bridgepacket_callback(h, cb); }
EXPORT int SL2_set_usb_port_status_callback(void *h, void *cb)       { return RH_set_usb_port_status_callback(h, cb); }
EXPORT int SL2_set_update_firmware(void *h, const void *d, int len, void *cb) { return RH_set_update_firmware(h, d, len, cb); }
EXPORT int SL2_set_update_firmware_from_embedded(void *h, void *cb)  { return RH_set_update_firmware_from_embedded(h, cb); }
EXPORT int SL2_set_alt_product_id(void *h, int pid)                  { return RH_set_alt_product_id(h, pid); }
EXPORT int SL2_is_boot_device(void *h, int *b)                       { return RH_is_boot_device(h, b); }
EXPORT int SL2_flush_hidi_queue(void *h)                             { return RH_flush_hidi_queue(h); }

/* Whether the box is in its bootloader (Rane's asked its kernel extension). Always 0: reporting 1
   would start the control panel's automatic firmware update, which is deliberately not
   implemented here. A box in its bootloader shows up in the driver's status (boot_mode) and log. */
EXPORT int SL2_is_C0_device(void *h, int *b) {
    if (!handle_ok(h) || !b) return RET(RH_ERR_BAD_ARG);
    if (!is_usb_present()) return RET(RH_ERR_NOT_CONNECTED);
    *b = 0;
    return RET(RH_OK);
}

/* The box's sample rate, asked from the box (0x30): [5..6], big-endian. */
EXPORT int SL2_get_sample_rate(void *h, int *rate) {
    if (!handle_ok(h) || !rate) return RET(RH_ERR_BAD_ARG);
    uint8_t r[HID_REPORT_LEN];
    int e = send_hid_cmd(SL2_CMD_GET_RATE, NULL, 0, r);
    if (e) return RET(e);
    if (r[0] != SL2_CMD_GET_RATE) return RET(RH_ERR_NO_REPLY);
    *rate = (r[5] << 8) | r[6];
    return RET(RH_OK);
}

/* Change the rate through CoreAudio: the HAL plug-in then changes the HAL's rate and the box's
   together (a rate set only on the box would leave the HAL rendering at the old one). */
EXPORT int SL2_set_sample_rate(void *h, const int *rate) {
    if (!handle_ok(h) || !rate || (*rate != 44100 && *rate != 48000)) return RET(RH_ERR_BAD_ARG);
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return RET(RH_ERR_NOT_CONNECTED);
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 fsr = (Float64)*rate;
    return RET(AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(Float64), &fsr) == noErr ? RH_OK : RH_ERR_NO_REPLY);
}

/* Not in Rane's API: this library's own callback for the driver's sample-rate event. */
EXPORT int SL2_set_samplerate_callback(void *h, void *cb) {
    if (!handle_ok(h)) return RET(RH_ERR_BAD_ARG);
    atomic_store(&g_sr_cb, (void (*)(SL2_samplerate_t *))cb);
    return RET(RH_OK);
}

/* C++ entry points Rane's framework also exports */
EXPORT void *_Z8RaneOpenv(void)                      { return RH_open(); }
EXPORT void *_Z15RH_open_privatei(int v)             { return RH_open_private(v); }
EXPORT void *_Z15RaneOpenPrivatei(int v)             { return RH_open_private(v); }
EXPORT int   _Z32RH_private_last_connection_errorv(void) { return 0; }
EXPORT int   _Z18SL2_set_sampleratei(int sr)         { return SL2_set_sample_rate(&g_handle, &sr); }
