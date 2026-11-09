// sl2apitest: check SL2Api the way Serato DJ Pro 2.5.5 uses it. Serato loads the framework from the
// path below and looks up seven functions; this loads it the same way, makes the same calls with
// Rane's signatures, and prints PASS or FAIL for each check.
//
//   make apitest
//   arch -x86_64 ./sl2apitest     Serato 2.5.5 is Intel-only, so this is the slice it loads
//   ./sl2apitest [path]           the arm64 slice, or another build of the framework
//
// Needs the driver installed and a box attached, with no audio playing: the test switches each
// deck between analogue thru and USB, and puts it back as it found it.
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SERATO_PATH "/Library/Frameworks/Sl2Api.framework/SL2Api"

enum { RH_OK = 0, RH_ERR_BAD_ARG = 8 };
enum { NOTE_THRU_1 = 0x5C, NOTE_THRU_2 = 0x5D, NOTE_CD_PHONO = 0x61 };

typedef struct { uint8_t length; uint8_t data[59]; } RH_hidimsg_data_t;

static void *(*SL2_open)(void);
static int (*SL2_close)(void *);
static int (*SL2_driver_timer)(void *, const uint8_t *, uint32_t, uint8_t *, uint32_t);
static int (*SL2_get_usb_port_status)(void *, int *);
static int (*SL2_get_all_controls)(void *);
static int (*SL2_send_hidimsg)(void *, const RH_hidimsg_data_t *);
static int (*SL2_set_hidimsg_callback)(void *, void (*)(RH_hidimsg_data_t *));

// The last message the box reported for each note (status, velocity), filled by the callback.
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_note_status[128], g_note_vel[128];
static int g_reports;

static int g_failed;
static void check(int ok, const char *what) {
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    fflush(stdout);
    if (!ok) g_failed = 1;
}

// The hidimsg callback: the box's reports, a run of MIDI-style messages. Keep each note message.
static void on_hidimsg(RH_hidimsg_data_t *m) {
    pthread_mutex_lock(&g_mtx);
    g_reports++;
    for (int i = 0; i + 2 < m->length; ) {
        uint8_t st = m->data[i];
        // Note on / note off: three bytes. Anything else ends what this test reads of the report.
        if ((st & 0xE0) != 0x80) break;
        g_note_status[m->data[i + 1] & 0x7F] = st;
        g_note_vel[m->data[i + 1] & 0x7F] = m->data[i + 2];
        i += 3;
    }
    pthread_mutex_unlock(&g_mtx);
}

// Ask for a state dump and wait for the callback to deliver it; returns the note's last message
// as (status << 8 | velocity), or -1 if the dump didn't report the note.
static int dump_note(void *h, int note) {
    // Forget the note's previous state, then ask for a fresh dump.
    pthread_mutex_lock(&g_mtx);
    g_note_status[note] = 0;
    pthread_mutex_unlock(&g_mtx);
    if (SL2_get_all_controls(h) != RH_OK) return -1;
    // The library polls the driver every 15 ms: wait up to a second for the note to arrive.
    for (int i = 0; i < 100; i++) {
        usleep(10000);
        pthread_mutex_lock(&g_mtx);
        int v = g_note_status[note] ? (g_note_status[note] << 8 | g_note_vel[note]) : -1;
        pthread_mutex_unlock(&g_mtx);
        if (v >= 0) return v;
    }
    return -1;
}

static int send_note(void *h, uint8_t status, uint8_t note) {
    RH_hidimsg_data_t m = { .length = 3, .data = { status, note, 0x00 } };
    return SL2_send_hidimsg(h, &m);
}

// Switch a deck with Note Off and Note On (as Serato and Rane's control panel do) and check each
// reaches the box, by the box's own state dump; leave the deck as it was.
static void check_thru(void *h, int note, const char *deck) {
    char what[128];
    int before = dump_note(h, note);
    snprintf(what, sizeof what, "%s: the state dump reports its thru note (0x%02X)", deck, note);
    check(before >= 0, what);
    if (before < 0) return;
    // Note Off, then Note On: each must be accepted and must change what the box reports.
    int e_off = send_note(h, 0x80, note);
    int after_off = dump_note(h, note);
    int e_on = send_note(h, 0x90, note);
    int after_on = dump_note(h, note);
    snprintf(what, sizeof what, "%s: send_hidimsg Note Off / Note On accepted (%d, %d)", deck, e_off, e_on);
    check(e_off == RH_OK && e_on == RH_OK, what);
    snprintf(what, sizeof what, "%s: the box's state follows (initial %04x, after off %04x, after on %04x)",
             deck, before, after_off, after_on);
    check(after_off >= 0 && after_on >= 0 && after_off != after_on && (before == after_off || before == after_on), what);
    // Put the deck back as it was.
    if (before == after_off) send_note(h, 0x80, note);
    snprintf(what, sizeof what, "%s: restored", deck);
    check(dump_note(h, note) == before, what);
}

int main(int argc, char **argv) {
    // Load the framework as Serato does, and look up the seven functions it uses.
    const char *path = argc > 1 ? argv[1] : SERATO_PATH;
#if defined(__x86_64__)
    printf("loading %s (x86_64)\n", path);
#else
    printf("loading %s (arm64)\n", path);
#endif
    void *lib = dlopen(path, RTLD_NOW);
    if (!lib) { printf("FAIL  dlopen: %s\n", dlerror()); return 1; }
    SL2_open = dlsym(lib, "SL2_open");
    SL2_close = dlsym(lib, "SL2_close");
    SL2_driver_timer = dlsym(lib, "SL2_driver_timer");
    SL2_get_usb_port_status = dlsym(lib, "SL2_get_usb_port_status");
    SL2_get_all_controls = dlsym(lib, "SL2_get_all_controls");
    SL2_send_hidimsg = dlsym(lib, "SL2_send_hidimsg");
    SL2_set_hidimsg_callback = dlsym(lib, "SL2_set_hidimsg_callback");
    check(SL2_open && SL2_close && SL2_driver_timer && SL2_get_usb_port_status && SL2_get_all_controls &&
          SL2_send_hidimsg && SL2_set_hidimsg_callback, "all seven functions Serato uses are exported");
    if (g_failed) return 1;

    // Open, register the callback, and check the box is reported connected.
    void *h = SL2_open();
    check(h != NULL, "SL2_open returns a handle");
    check(SL2_set_hidimsg_callback(h, on_hidimsg) == RH_OK, "SL2_set_hidimsg_callback");
    int ps[2] = { -1, -1 };
    int e = SL2_get_usb_port_status(h, ps);
    char what[160];
    snprintf(what, sizeof what, "SL2_get_usb_port_status -> %d {%d, %d} (expect 0 {1, 0}: connected)", e, ps[0], ps[1]);
    check(e == RH_OK && ps[0] == 1 && ps[1] == 0, what);
    if (e != RH_OK) { printf("no box connected: stopping\n"); return 1; }

    // The state dump: thru for both decks and the CD/PHONO switch arrive through the callback.
    int t1 = dump_note(h, NOTE_THRU_1), t2 = dump_note(h, NOTE_THRU_2), lp = dump_note(h, NOTE_CD_PHONO);
    snprintf(what, sizeof what, "SL2_get_all_controls: callback reports left deck (1/2) %04x, right deck (3/4) %04x, CD/PHONO %04x", t1, t2, lp);
    check(t1 >= 0 && t2 >= 0 && lp >= 0, what);

    // The genuine-hardware check: the box's 8-byte answer is a function of the 8-byte challenge.
    uint8_t c1[8] = { 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF }, c2[8] = { 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10 };
    uint8_t a1[8] = {0}, a1b[8] = {0}, a2[8] = {0}, zero[8] = {0};
    int e1 = SL2_driver_timer(h, c1, 8, a1, 8), e1b = SL2_driver_timer(h, c1, 8, a1b, 8), e2 = SL2_driver_timer(h, c2, 8, a2, 8);
    snprintf(what, sizeof what, "SL2_driver_timer -> %d, %d, %d; answer %02x%02x%02x%02x%02x%02x%02x%02x", e1, e1b, e2,
             a1[0], a1[1], a1[2], a1[3], a1[4], a1[5], a1[6], a1[7]);
    check(e1 == RH_OK && e1b == RH_OK && e2 == RH_OK, what);
    check(memcmp(a1, zero, 8) != 0 && memcmp(a1, c1, 8) != 0, "SL2_driver_timer: the answer is non-zero and not the challenge echoed");
    check(memcmp(a1, a1b, 8) == 0, "SL2_driver_timer: the same challenge gives the same answer");
    check(memcmp(a1, a2, 8) != 0, "SL2_driver_timer: a different challenge gives a different answer");
    check(SL2_driver_timer(h, c1, 7, a1, 8) == RH_ERR_BAD_ARG, "SL2_driver_timer: a 7-byte challenge is refused (8)");

    // Per-deck thru, as Serato switches it.
    RH_hidimsg_data_t empty = { 0 };
    check(SL2_send_hidimsg(h, &empty) == RH_ERR_BAD_ARG, "SL2_send_hidimsg: an empty message is refused (8)");
    check_thru(h, NOTE_THRU_1, "left deck (1/2)");
    check_thru(h, NOTE_THRU_2, "right deck (3/4)");

    // Close.
    check(SL2_close(h) == RH_OK, "SL2_close");
    printf("%s\n", g_failed ? "FAIL" : "PASS: all checks");
    return g_failed;
}
