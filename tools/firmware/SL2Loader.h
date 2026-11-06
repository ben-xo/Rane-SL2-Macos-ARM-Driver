// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * SL2Loader.h — loading firmware into a Rane SL 2 that is in its USB bootloader.
 *
 * The SL 2 is a Cypress EZ-USB FX2 (8051) whose firmware lives in an I2C EEPROM on the
 * box. It enumerates in two forms with the same VID/PID (1cc5:0013):
 *   bcdDevice 0x0100  running firmware: 4 interfaces, "Rane SL 2", the audio device
 *   bcdDevice 0x0000  bootloader ("C0" state): the FX2's ROM loader with only the
 *                     identity bytes from the EEPROM, no strings ("Unnamed Device").
 *                     The box gets here when the EEPROM's boot header is not bootable.
 *
 * Recovery is what Rane's SL2Api did on connect, in two stages:
 *   1. load an 8051 "bootstrap" (an EEPROM programmer) into RAM with EZ-USB vendor
 *      request 0xA0 and start it; the box re-enumerates running the bootstrap, which
 *      presents the same descriptors as the running firmware (bcdDevice 0x0100 included);
 *   2. stream the firmware image to the bootstrap in 64-byte reports on EP1
 *      (0x17 begin: EEPROM header marked C0 / 0x02 write 32-byte blocks at a 16-bit
 *      EEPROM address / 0x16 finalize: header marked C2, box restarts into firmware).
 * Afterwards the box boots on its own again; this is a one-time repair.
 *
 * The two images come from the user's own copy of Rane's SL2Api.framework (see
 * tools/firmware/extract-sl2-firmware.py); they are recognised by content, not by name.
 * Used only by the standalone flasher (tools/firmware/sl2flash.m) — the HAL audio plug-in
 * detects a bootloader-mode box but never writes firmware.
 *
 * STATUS: this over-USB path is reconstructed from Rane's SL2Api and the bootstrap's own 8051
 * code. A wrong 0x02 byte layout writes to the wrong EEPROM addresses and can brick the box, so
 * the layout must be exact (see stage2_final) and the whole image is read back and verified
 * before the irreversible 0x16 finalize, so a bad image can never be armed. This path has not
 * been run to completion on hardware here — the box in this project was recovered by a direct
 * EEPROM reflash (tools/firmware/RECOVERY.md), the proven route — so prefer that unless you have
 * reason to trust this one.
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

#define SL2_VID        0x1cc5
#define SL2_PID        0x0013
#define SL2_BCD_LOADER 0x0000
#define SL2_BCD_AUDIO  0x0100

/* Cypress EZ-USB FX2 default device: what the chip enumerates as when its EEPROM is
   absent or its boot header is neither 0xC0 nor 0xC2 — e.g. a box fitted with a new,
   completely blank EEPROM chip. It accepts the same 0xA0 RAM download as the Rane bootloader. */
#define FX2_DEFAULT_VID 0x04b4
#define FX2_DEFAULT_PID 0x8613

typedef void (*sl2_loader_log_fn)(const char *msg);

typedef struct {
    const char    *name;
    const uint8_t *data;
    size_t         len;
} SL2FirmwareImage;

/* bcdDevice of an IOUSBHostDevice service, or -1 if unreadable. */
int sl2_service_bcd(io_service_t svc);

/* Run the whole recovery on the bootloader-mode device 'c0' (an IOUSBHostDevice service
   with bcdDevice 0x0000 that nobody else holds open). 'images' must contain the bootstrap
   and the final image (any order, any names). With dry_run the device is opened and
   described and the images are validated, but nothing is sent. Blocks for the duration
   (typically 20-40 s); must not be called on the dispatch queue that owns 'c0'.
   Returns true once the box is back as the audio device (bcdDevice 0x0100). */
bool sl2_loader_run(io_service_t c0, const SL2FirmwareImage *images, size_t count,
                    bool dry_run, sl2_loader_log_fn log);
