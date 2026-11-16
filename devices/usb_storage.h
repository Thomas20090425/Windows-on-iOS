/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_USB_STORAGE_H
#define WINIOS_USB_STORAGE_H

#include <stddef.h>
#include <stdint.h>
#include "disk.h"

#define HV_USB_STORAGE_MEDIA 3

/* USB Mass Storage Bulk-Only Transport, with an optical ISO at LUN 0, an
 * optional guarded answer-file disk at LUN 1, and the bundled Windows driver
 * disk at LUN 2. Every backing image remains read-only. Empty lower-numbered
 * LUNs are real removable drives reporting NOT READY / MEDIUM NOT PRESENT. */
typedef struct HvUsbStorage {
    HvDisk *media[HV_USB_STORAGE_MEDIA];
    uint8_t sense_key[HV_USB_STORAGE_MEDIA];
    uint8_t sense_asc[HV_USB_STORAGE_MEDIA], sense_ascq[HV_USB_STORAGE_MEDIA];
    uint8_t cbw[31], response[512], csw[13];
    uint32_t cbw_used, tag, host_length, residue;
    uint32_t response_length, response_offset, csw_offset;
    uint64_t read_offset, read_remaining;
    uint8_t lun, status, direction_in, phase, optical_ejected;
} HvUsbStorage;

enum { HV_USB_STORAGE_CBW, HV_USB_STORAGE_DATA_IN, HV_USB_STORAGE_DATA_OUT,
       HV_USB_STORAGE_CSW, HV_USB_STORAGE_INVALID };

void hv_usb_storage_init(HvUsbStorage *s, HvDisk *iso, HvDisk *answer);
void hv_usb_storage_reset(HvUsbStorage *s);
int hv_usb_storage_has_media(const HvUsbStorage *s);
uint8_t hv_usb_storage_max_lun(const HvUsbStorage *s);
/* OUT accepts CBW/data; -1 means halt until Bulk-Only Reset. */
int hv_usb_storage_write(HvUsbStorage *s, const uint8_t *data, uint32_t length);
/* IN emits one phase at a time; -2 waits for OUT, -1 requests endpoint halt. */
int hv_usb_storage_read(HvUsbStorage *s, uint8_t *data, uint32_t capacity);

#endif
