// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * SL2Passthrough — send commands to a Rane SL 2 through the HAL driver's 'sl2h' property.
 *
 * While the HAL plug-in (plugin/SL2Device.m) runs, it holds the box's USB interfaces, so a tool
 * cannot open the command endpoints itself. Instead it writes a 64-byte command report to the
 * driver's 'sl2h' property and then reads the property back: the read sends the command on EP1
 * and returns the box's 64-byte reply. The report layout and the command set are in
 * docs/SL2-COMMANDS.md.
 *
 * The write/read pair is not atomic across processes: with two 'sl2h' clients running at once
 * (sl2panel, Serato through SL2Api), one can end up sending the other's command. Run tools that
 * write the EEPROM as the only client.
 */
#import <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define SL2_REPORT        64
#define SL2_EEPROM_SIZE   0x10000
#define SL2_EEPROM_BLOCK  32      /* bytes per 0x02 write / 0x03 read */

/* The SL 2's HAL device, or kAudioObjectUnknown if the driver is not loaded. The device exists
   whenever the driver is loaded, whether or not a box is connected. */
AudioObjectID sl2h_find_device(void);

/* Send one command report and fetch its reply. Fills in the tag (req[1..4]) itself. True if the
   reply echoes the opcode and tag; the driver returns an all-zero reply when the box does not
   answer in time, so a timeout reads as false too. */
bool sl2h_command(AudioObjectID dev, uint8_t req[SL2_REPORT], uint8_t reply[SL2_REPORT]);

/* Command 0x01: the firmware version (reply bytes 01 02 from the bootstrap, 01 0a = 1.10 from
   the running firmware). */
bool sl2h_version(AudioObjectID dev, uint8_t *major, uint8_t *minor);

/* Command 0x03: read 32 EEPROM bytes at 'addr'. */
bool sl2h_eeprom_read(AudioObjectID dev, uint16_t addr, uint8_t out[SL2_EEPROM_BLOCK]);

/* Command 0x02: write 32 EEPROM bytes at 'addr' (only accepted after 0x17); 'readback' gets the
   bytes the box read back from the EEPROM after the write cycle. */
bool sl2h_eeprom_write(AudioObjectID dev, uint16_t addr, const uint8_t data[SL2_EEPROM_BLOCK],
                       uint8_t readback[SL2_EEPROM_BLOCK]);

/* True if any process is doing audio I/O on the SL 2. */
bool sl2h_is_streaming(AudioObjectID dev);
