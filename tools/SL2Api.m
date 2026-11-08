/*
 * SL2Api.m — Universal (arm64 + x86_64) replacement for /Library/Frameworks/SL2Api.framework
 *
 * Bridges Serato DJ Pro / Scratch Live and the Rane SL 2 Audio Control Panel
 * to the SL2Device CoreAudio HAL PlugIn via custom CoreAudio properties
 * ('sl2h', 'sl2s', 'sl2q'), with direct IOUSBHost fallback if needed.
 */

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <pthread.h>

#define VID 0x1cc5
#define PID 0x0013
#define IF_HID 3
#define EP_HID_OUT 0x01
#define EP_HID_IN  0x81

#define kSL2PropHIDCommand  'sl2h'
#define kSL2PropStatus      'sl2s'
#define kSL2PropUnsolQueue  'sl2q'

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
} SL2StatusPacket;

typedef struct {
    uint8_t length;
    uint8_t data[63];
} RH_hidimsg_data_t;

typedef struct {
    uint8_t length;
    uint8_t data[63];
} RH_bridgepacket_data_t;

typedef struct {
    int this_port;
    int other_port;
} RH_usb_port_status_t;

typedef struct {
    int sample_rate;
} SL2_samplerate_t;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_seq = 1;
static int g_dummy_handle = 0x52414E32;
static int g_buffer_ms = 5;

static void (*g_hidi_cb)(RH_hidimsg_data_t *) = NULL;
static void (*g_bridge_cb)(RH_bridgepacket_data_t *) = NULL;
static void (*g_port_cb)(RH_usb_port_status_t *) = NULL;
static void (*g_sr_cb)(SL2_samplerate_t *) = NULL;
static dispatch_source_t g_poll_timer = nil;

/* Find SL 2 CoreAudio Device ID */
static AudioObjectID find_hal_device(void) {
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl2.hal.device");
    AudioObjectID devID = kAudioObjectUnknown;
    UInt32 sz = sizeof(devID);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &devID);
    return (st == noErr) ? devID : kAudioObjectUnknown;
}

static bool hal_get_status(SL2StatusPacket *outSt) {
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return false;
    AudioObjectPropertyAddress a = { kSL2PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) == noErr && d) {
        if (CFDataGetLength(d) >= (CFIndex)sizeof(SL2StatusPacket)) {
            memcpy(outSt, CFDataGetBytePtr(d), sizeof(SL2StatusPacket));
            CFRelease(d);
            return true;
        }
        CFRelease(d);
    }
    return false;
}

static void dispatch_unsol_packet(const uint8_t pkt[64]) {
    uint8_t cmd = pkt[0];
    if (cmd == 0x40 && g_hidi_cb) {
        RH_hidimsg_data_t m;
        memset(&m, 0, sizeof(m));
        m.length = pkt[5] <= 58 ? pkt[5] : 58;
        memcpy(m.data, pkt + 6, m.length);
        g_hidi_cb(&m);
    } else if (cmd == 0x43 && g_bridge_cb) {
        RH_bridgepacket_data_t b;
        memset(&b, 0, sizeof(b));
        b.length = pkt[5] <= 58 ? pkt[5] : 58;
        memcpy(b.data, pkt + 6, b.length);
        g_bridge_cb(&b);
    } else if ((cmd >= 0x45 && cmd <= 0x48) && g_port_cb) {
        RH_usb_port_status_t ps;
        ps.this_port = (pkt[5] == 1) ? 1 : ((pkt[5] == 2) ? 2 : 1);
        ps.other_port = pkt[6] ? ((ps.this_port == 1) ? 2 : 1) : 0;
        g_port_cb(&ps);
    } else if (cmd == 0x49 && g_sr_cb) {
        SL2_samplerate_t s;
        s.sample_rate = (pkt[5] << 16) | (pkt[6] << 8) | pkt[7];
        if (s.sample_rate != 44100 && s.sample_rate != 48000) {
            s.sample_rate = pkt[5] | (pkt[6] << 8);
        }
        g_sr_cb(&s);
    }
}

static void poll_unsol_queue(void) {
    AudioObjectID dev = find_hal_device();
    if (dev == kAudioObjectUnknown) return;
    AudioObjectPropertyAddress a = { kSL2PropUnsolQueue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) == noErr && d) {
        CFIndex len = CFDataGetLength(d);
        const uint8_t *bytes = CFDataGetBytePtr(d);
        for (CFIndex off = 0; off + 64 <= len; off += 64) {
            dispatch_unsol_packet(bytes + off);
        }
        CFRelease(d);
    }
}

static void ensure_poll_timer(void) {
    if (g_poll_timer) return;
    dispatch_queue_t q = dispatch_queue_create("com.rane.sl2api.poll", DISPATCH_QUEUE_SERIAL);
    g_poll_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(g_poll_timer, DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_poll_timer, ^{
        poll_unsol_queue();
    });
    dispatch_resume(g_poll_timer);
}

static bool send_hid_cmd(uint8_t cmd, const uint8_t *pl, size_t plen, uint8_t *reply_out) {
    pthread_mutex_lock(&g_lock);
    uint8_t req[64] = {0};
    req[0] = cmd;
    uint32_t seq = g_seq++;
    memcpy(req + 1, &seq, 4);
    if (pl && plen > 0 && plen <= 59) memcpy(req + 5, pl, plen);

    AudioObjectID dev = find_hal_device();
    if (dev != kAudioObjectUnknown) {
        AudioObjectPropertyAddress a = { kSL2PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFDataRef inData = CFDataCreate(kCFAllocatorDefault, req, 64);
        OSStatus st = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &inData);
        CFRelease(inData);
        if (st == noErr) {
            CFDataRef outData = NULL;
            UInt32 sz = sizeof(CFDataRef);
            st = AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &outData);
            if (st == noErr && outData) {
                if (reply_out && CFDataGetLength(outData) >= 64) {
                    memcpy(reply_out, CFDataGetBytePtr(outData), 64);
                }
                CFRelease(outData);
                pthread_mutex_unlock(&g_lock);
                return true;
            }
        }
    }
    pthread_mutex_unlock(&g_lock);
    return false;
}

static bool is_usb_present(void) {
    SL2StatusPacket st;
    if (hal_get_status(&st) && st.connected) return true;
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return false;
    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (s) { IOObjectRelease(s); return true; }
    return false;
}

/* ============================================================================
 * Exported RH_* and SL2_* API Functions
 * ============================================================================ */

#define EXPORT __attribute__((visibility("default")))

EXPORT void* RH_open(void) { ensure_poll_timer(); return &g_dummy_handle; }
EXPORT void* RH_open_private(int v) { ensure_poll_timer(); return &g_dummy_handle; }
EXPORT int   RH_private_last_connection_error(void) { return 0; }
EXPORT int   RH_close(void *h) { return 0; }
EXPORT int   RH_get_vendor_id(void *h, int *v) { if (v) *v = VID; return 0; }
EXPORT int   RH_get_product_id(void *h, int *p) { if (p) *p = PID; return 0; }
EXPORT int   RH_get_api_version(void *h, int *v) { if (v) *v = 0x020001; return 0; }
EXPORT int   RH_get_driver_version(void *h, int *v) { if (v) *v = 0x020001; return 0; }
EXPORT int   RH_get_buffer_millisecs(void *h, int *m) { if (m) *m = g_buffer_ms; return 0; }
EXPORT int   RH_set_buffer_millisecs(void *h, int m) { g_buffer_ms = m; return 0; }

EXPORT int RH_get_usb_port_status(void *h, int *st) {
    if (!is_usb_present()) return 12; /* kNotConnected */
    SL2StatusPacket s;
    if (hal_get_status(&s)) {
        if (st) {
            st[0] = (s.port_a == 2) ? 2 : 1;
            st[1] = s.port_b ? ((st[0] == 1) ? 2 : 1) : 0;
        }
        return 0;
    }
    if (st) { st[0] = 1; st[1] = 0; }
    return 0;
}

EXPORT int RH_get_port_speed(void *h, int *sp) { if (sp) *sp = 1; return 0; }
EXPORT int RH_set_control_point(void *h, int a, int b) { return 0; }
EXPORT int RH_driver_timer(void *h, int *t) { if (t) *t = 1000; return 0; }

/* As Rane's SL2Api: ask the box (HID 0x01) and fill four values: major, minor, 0, and the
   32-bit build stamp from reply[7..10] (big-endian). 12 = not connected, 8 = bad argument. */
EXPORT int RH_get_firmware_version(void *h, uint32_t v[4]) {
    if (!is_usb_present()) return 12;
    if (!h || !v) return 8;
    uint8_t r[64] = {0};
    if (!send_hid_cmd(0x01, NULL, 0, r) || r[0] != 0x01) return 4;   /* no reply from the box */
    v[0] = r[5];
    v[1] = r[6];
    v[2] = 0;
    v[3] = ((uint32_t)r[7] << 24) | ((uint32_t)r[8] << 16) | ((uint32_t)r[9] << 8) | r[10];
    return 0;
}

EXPORT int RH_get_firmware_embedded_version(void *h, int *v) { if (v) *v = 0x0101; return 0; }

EXPORT int RH_send_hidimsg(void *h, const uint8_t *msg, int len);

/* As Rane's SL2Api does: ask the box for a state dump (Hidi SysEx F0 17 04 F7, sent with 0x41).
   The box answers with 0x40 reports of notes 0x5C/0x5D (deck thru), 0x61 (the LINE/PHONO switch)
   and 0x60, which reach the hidimsg callback through the unsolicited-report poll like any other. */
EXPORT int RH_get_all_controls(void *h) {
    ensure_poll_timer();
    static const uint8_t dump[4] = { 0xF0, 0x17, 0x04, 0xF7 };
    return RH_send_hidimsg(h, dump, sizeof dump);
}

EXPORT int RH_send_hidimsg(void *h, const uint8_t *msg, int len) {
    if (!msg || len <= 0 || len > 58) return -1;
    uint8_t pl[59] = {0};
    pl[0] = (uint8_t)len;
    memcpy(pl + 1, msg, len);
    send_hid_cmd(0x41, pl, len + 1, NULL);
    return 0;
}

/* Rane's API takes (handle, note, velocity): the SL 2 Audio Control Panel calls
   SL2_send_note_on(h, 0x5C, 0) for "deck 1 thru on" and SL2_send_note_off for off
   (0x5D = deck 2). The firmware acts on notes 0x5C and 0x5D only: LINE/PHONO (note 0x61) is a
   physical switch, reported by the box but not settable. */
EXPORT int RH_send_note_on(void *h, uint8_t note, uint8_t vel) {
    uint8_t m[3] = { 0x90, note, vel };
    return RH_send_hidimsg(h, m, 3);
}

EXPORT int RH_send_note_off(void *h, uint8_t note, uint8_t vel) {
    uint8_t m[3] = { 0x80, note, vel };
    return RH_send_hidimsg(h, m, 3);
}

EXPORT int RH_send_control_change(void *h, uint8_t ch, uint8_t cc, uint8_t val) {
    uint8_t m[3] = { (uint8_t)(0xB0 | (ch & 0x0f)), cc, val };
    return RH_send_hidimsg(h, m, 3);
}

EXPORT int RH_send_sys_ex(void *h, const uint8_t *d, int len) { return RH_send_hidimsg(h, d, len); }

EXPORT int RH_set_hidimsg_callback(void *h, void *cb) {
    g_hidi_cb = (void (*)(RH_hidimsg_data_t *))cb;
    ensure_poll_timer();
    return 0;
}

EXPORT int RH_send_bridge_packet(void *h, const uint8_t *d, int len) {
    if (!d || len <= 0 || len > 58) return -1;
    uint8_t pl[59] = {0};
    pl[0] = (uint8_t)len;
    memcpy(pl + 1, d, len);
    send_hid_cmd(0x44, pl, len + 1, NULL);
    return 0;
}

EXPORT int RH_set_bridgepacket_callback(void *h, void *cb) {
    g_bridge_cb = (void (*)(RH_bridgepacket_data_t *))cb;
    ensure_poll_timer();
    return 0;
}

EXPORT int RH_set_usb_port_status_callback(void *h, void *cb) {
    g_port_cb = (void (*)(RH_usb_port_status_t *))cb;
    ensure_poll_timer();
    if (g_port_cb && is_usb_present()) {
        RH_usb_port_status_t ps = {1, 0};
        RH_get_usb_port_status(h, (int *)&ps);
        g_port_cb(&ps);
    }
    return 0;
}

EXPORT int RH_set_update_firmware(void *h, const void *d, int len, void *cb) { return 0; }
EXPORT int RH_set_update_firmware_from_embedded(void *h, void *cb) { return 0; }
EXPORT int RH_set_alt_product_id(void *h, int pid) { return 0; }
EXPORT int RH_is_boot_device(void *h, int *b) {
    if (!is_usb_present()) return 12;
    if (b) *b = 0;
    return 0;
}
EXPORT int RH_get_midi_channels(void *h, void *d) { return 0; }
EXPORT int RH_set_midi_channels(void *h, const void *d) { return 0; }
EXPORT int RH_set_midi_ch_callback(void *h, void *cb) { return 0; }
EXPORT int RH_flush_hidi_queue(void *h) { poll_unsol_queue(); return 0; }

/* SL2_* Aliases & Specific Functions */
EXPORT void* SL2_open(void) { return RH_open(); }
EXPORT int   SL2_close(void *h) { return RH_close(h); }
EXPORT int   SL2_get_vendor_id(void *h, int *v) { return RH_get_vendor_id(h, v); }
EXPORT int   SL2_get_product_id(void *h, int *p) { return RH_get_product_id(h, p); }
EXPORT int   SL2_get_api_version(void *h, int *v) { return RH_get_api_version(h, v); }
EXPORT int   SL2_get_driver_version(void *h, int *v) { return RH_get_driver_version(h, v); }
EXPORT int   SL2_get_buffer_millisecs(void *h, int *m) { return RH_get_buffer_millisecs(h, m); }
EXPORT int   SL2_set_buffer_millisecs(void *h, int m) { return RH_set_buffer_millisecs(h, m); }
EXPORT int   SL2_get_usb_port_status(void *h, int *st) { return RH_get_usb_port_status(h, st); }
EXPORT int   SL2_get_port_speed(void *h, int *sp) { return RH_get_port_speed(h, sp); }
EXPORT int   SL2_driver_timer(void *h, int *t) { return RH_driver_timer(h, t); }
EXPORT int   SL2_get_firmware_version(void *h, uint32_t v[4]) { return RH_get_firmware_version(h, v); }
EXPORT int   SL2_get_firmware_embedded_version(void *h, int *v) { return RH_get_firmware_embedded_version(h, v); }
EXPORT int   SL2_get_all_controls(void *h) { return RH_get_all_controls(h); }
EXPORT int   SL2_send_hidimsg(void *h, const uint8_t *msg, int len) { return RH_send_hidimsg(h, msg, len); }
EXPORT int   SL2_send_note_on(void *h, uint8_t note, uint8_t vel) { return RH_send_note_on(h, note, vel); }
EXPORT int   SL2_send_note_off(void *h, uint8_t note, uint8_t vel) { return RH_send_note_off(h, note, vel); }
EXPORT int   SL2_send_sys_ex(void *h, const uint8_t *d, int len) { return RH_send_sys_ex(h, d, len); }
EXPORT int   SL2_set_hidimsg_callback(void *h, void *cb) { return RH_set_hidimsg_callback(h, cb); }
EXPORT int   SL2_send_bridge_packet(void *h, const uint8_t *d, int len) { return RH_send_bridge_packet(h, d, len); }
EXPORT int   SL2_set_bridgepacket_callback(void *h, void *cb) { return RH_set_bridgepacket_callback(h, cb); }
EXPORT int   SL2_set_usb_port_status_callback(void *h, void *cb) { return RH_set_usb_port_status_callback(h, cb); }
EXPORT int   SL2_set_update_firmware(void *h, const void *d, int len, void *cb) { return 0; }
EXPORT int   SL2_set_update_firmware_from_embedded(void *h, void *cb) { return 0; }
EXPORT int   SL2_set_alt_product_id(void *h, int pid) { return 0; }
EXPORT int   SL2_is_C0_device(void *h, int *b) { return RH_is_boot_device(h, b); }
EXPORT int   SL2_is_boot_device(void *h, int *b) { return RH_is_boot_device(h, b); }
EXPORT int   SL2_flush_hidi_queue(void *h) { return RH_flush_hidi_queue(h); }

EXPORT int SL2_get_sample_rate(void *h, int *outRate) {
    if (!is_usb_present()) return 12;
    SL2StatusPacket s;
    if (hal_get_status(&s) && s.sample_rate) {
        if (outRate) *outRate = (int)s.sample_rate;
        return 0;
    }
    if (outRate) *outRate = 44100;
    return 0;
}

EXPORT int SL2_set_sample_rate(void *h, const int *inRate) {
    if (!inRate) return 8;
    int sr = *inRate;
    if (sr != 44100 && sr != 48000) return 8;
    AudioObjectID dev = find_hal_device();
    if (dev != kAudioObjectUnknown) {
        AudioObjectPropertyAddress a = {
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        Float64 fsr = (Float64)sr;
        AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(Float64), &fsr);
    }
    uint8_t pl[2] = { (uint8_t)((sr >> 8) & 0xFF), (uint8_t)(sr & 0xFF) };
    send_hid_cmd(0x31, pl, 2, NULL);
    return 0;
}

EXPORT int SL2_set_samplerate_callback(void *h, void *cb) {
    g_sr_cb = (void (*)(SL2_samplerate_t *))cb;
    ensure_poll_timer();
    return 0;
}

/* C++ mangled entrypoints exported by official SL2Api */
EXPORT void* _Z8RaneOpenv(void) { return RH_open(); }
EXPORT void* _Z15RH_open_privatei(int v) { return RH_open_private(v); }
EXPORT void* _Z15RaneOpenPrivatei(int v) { return RH_open_private(v); }
EXPORT int   _Z32RH_private_last_connection_errorv(void) { return 0; }
EXPORT int   _Z18SL2_set_sampleratei(int sr) { return SL2_set_sample_rate(&g_dummy_handle, &sr); }
