/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "usb_storage.h"

#include <limits.h>
#include <string.h>

/* BOT wire layout follows USB-IF Bulk-Only Transport Revision 1.0.
 * Command/response bytes are encoded explicitly, without packed host structs. */
static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }
static uint32_t le32(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void put_be16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put_be32(uint8_t *p, uint32_t v) { for (int i = 3; i >= 0; --i) { p[i] = (uint8_t)v; v >>= 8; } }
static void put_be64(uint8_t *p, uint64_t v) { put_be32(p, (uint32_t)(v >> 32)); put_be32(p + 4, (uint32_t)v); }
static void put_le32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; ++i) { p[i] = (uint8_t)v; v >>= 8; } }

static uint32_t block_size(const HvUsbStorage *s) { return s->lun ? 512 : 2048; }
static uint64_t blocks(const HvUsbStorage *s) { return s->media[s->lun] ? s->media[s->lun]->size / block_size(s) : 0; }
static int ready(const HvUsbStorage *s) { return blocks(s) > 0 && (s->lun || !s->optical_ejected); }

void hv_usb_storage_reset(HvUsbStorage *s) {
    s->phase = HV_USB_STORAGE_CBW;
    s->cbw_used = s->response_length = s->response_offset = s->csw_offset = 0;
    s->read_remaining = 0;
    s->host_length = s->residue = 0;
    s->status = 0;
}

void hv_usb_storage_init(HvUsbStorage *s, HvDisk *iso, HvDisk *answer) {
    memset(s, 0, sizeof *s);
    s->media[0] = iso;
    s->media[1] = answer;
    hv_usb_storage_reset(s);
}

static void fail(HvUsbStorage *s, uint8_t key, uint8_t asc) {
    s->status = 1;
    s->sense_key[s->lun] = key;
    s->sense_asc[s->lun] = asc;
    s->sense_ascq[s->lun] = 0;
}

static void begin_csw(HvUsbStorage *s) {
    put_le32(s->csw, 0x53425355); /* USBS */
    put_le32(s->csw + 4, s->tag);
    put_le32(s->csw + 8, s->residue);
    s->csw[12] = s->status;
    s->csw_offset = 0;
    s->phase = HV_USB_STORAGE_CSW;
}

static void response(HvUsbStorage *s, uint32_t length, uint32_t allocation) {
    if (length > allocation) length = allocation;
    if (length > s->host_length) length = s->host_length;
    s->response_length = length;
}

static void read_blocks(HvUsbStorage *s, uint64_t lba, uint64_t count) {
    uint64_t total = blocks(s);
    uint32_t unit = block_size(s);
    if (!ready(s)) { fail(s, 2, 0x3a); return; }
    if (lba > total || count > total - lba) { fail(s, 5, 0x21); return; }
    if (count > UINT32_MAX / unit) { fail(s, 5, 0x24); return; }
    uint64_t bytes = count * unit;
    s->read_offset = lba * unit;
    s->read_remaining = bytes < s->host_length ? bytes : s->host_length;
    if (bytes > s->host_length) s->status = 2; /* Host/device transfer length phase error. */
}

static void toc_address(uint8_t *out, uint32_t lba, int msf) {
    if (msf) {
        uint32_t frame = lba + 150;
        out[0] = 0; out[1] = (uint8_t)(frame / (75 * 60));
        out[2] = (uint8_t)((frame / 75) % 60); out[3] = (uint8_t)(frame % 75);
    } else put_be32(out, lba);
}

static void command(HvUsbStorage *s, const uint8_t *cdb) {
    uint8_t *r = s->response;
    memset(r, 0, sizeof s->response);
    s->response_length = s->response_offset = 0;
    s->read_remaining = 0;
    s->status = 0;
    switch (cdb[0]) {
    case 0x00: /* TEST UNIT READY */
        if (!ready(s)) fail(s, 2, 0x3a);
        break;
    case 0x03: /* REQUEST SENSE, fixed-format response */
        r[0] = 0x70; r[2] = s->sense_key[s->lun]; r[7] = 10;
        r[12] = s->sense_asc[s->lun]; r[13] = s->sense_ascq[s->lun];
        response(s, 18, cdb[4]);
        s->sense_key[s->lun] = s->sense_asc[s->lun] = s->sense_ascq[s->lun] = 0;
        break;
    case 0x12: /* INQUIRY */
        r[0] = s->lun ? 0 : 5;
        if (cdb[1] & 1) {
            r[1] = cdb[2];
            if (cdb[2] == 0) { r[3] = 3; r[4] = 0; r[5] = 0x80; r[6] = 0x83; response(s, 7, cdb[4]); }
            else if (cdb[2] == 0x80) {
                r[3] = 8; memcpy(r + 4, s->lun ? "ANSWER01" : "WINISO01", 8); response(s, 12, cdb[4]);
            } else if (cdb[2] == 0x83) {
                r[3] = 12; r[4] = 2; r[5] = 0; r[7] = 8;
                memcpy(r + 8, s->lun ? "ANSWER01" : "WINISO01", 8); response(s, 16, cdb[4]);
            } else fail(s, 5, 0x24);
        } else {
            r[1] = 0x80; r[2] = 5; r[3] = 2; r[4] = 31;
            memcpy(r + 8, "WINIOS  ", 8);
            memcpy(r + 16, s->lun ? "SETUP ANSWER    " : "INSTALLER DVD   ", 16);
            memcpy(r + 32, "1.00", 4);
            response(s, 36, cdb[4]);
        }
        break;
    case 0x1a: /* MODE SENSE(6) */
    case 0x5a: { /* MODE SENSE(10), CD capabilities + write-protect */
        int ten = cdb[0] == 0x5a, header = ten ? 8 : 4;
        uint8_t page = cdb[2] & 0x3f;
        uint32_t length = (uint32_t)header;
        r[ten ? 3 : 2] = 0x80;
        if (!s->lun && (page == 0x2a || page == 0x3f)) {
            r[header] = 0x2a; r[header + 1] = 0x1e;
            r[header + 2] = 0x08; /* DVD-ROM read */
            r[header + 4] = 0x71; /* audio-play, mode2/form1/form2 read */
            r[header + 5] = 0x60; r[header + 6] = 0x29; /* tray, lock, eject */
            put_be16(r + header + 8, 0x2a30); put_be16(r + header + 14, 0x2a30);
            length += 32;
        } else if (s->lun && (page == 8 || page == 0x3f)) {
            r[header] = 8; r[header + 1] = 18; length += 20;
        } else if (page != 0) { fail(s, 5, 0x24); break; }
        if (ten) put_be16(r, (uint16_t)(length - 2)); else r[0] = (uint8_t)(length - 1);
        response(s, length, ten ? be16(cdb + 7) : cdb[4]);
        break;
    }
    case 0x1b: /* START STOP UNIT; retain source file even after guest eject. */
        if (!s->lun && (cdb[4] & 2)) s->optical_ejected = (cdb[4] & 1) == 0;
        break;
    case 0x1e: /* PREVENT/ALLOW MEDIUM REMOVAL */
    case 0x35: /* SYNCHRONIZE CACHE: all attached media is read-only */
    case 0xbb: /* SET CD SPEED */
        break;
    case 0x25: /* READ CAPACITY(10) */
        if (!ready(s)) { fail(s, 2, 0x3a); break; }
        put_be32(r, blocks(s) - 1 > UINT32_MAX ? UINT32_MAX : (uint32_t)(blocks(s) - 1));
        put_be32(r + 4, block_size(s)); response(s, 8, 8);
        break;
    case 0x9e: /* READ CAPACITY(16), service action 0x10 */
        if ((cdb[1] & 31) != 0x10) { fail(s, 5, 0x24); break; }
        if (!ready(s)) { fail(s, 2, 0x3a); break; }
        put_be64(r, blocks(s) - 1); put_be32(r + 8, block_size(s)); response(s, 32, be32(cdb + 10));
        break;
    case 0x23: /* READ FORMAT CAPACITIES */
        if (!ready(s)) { fail(s, 2, 0x3a); break; }
        r[3] = 8; put_be32(r + 4, (uint32_t)blocks(s)); r[8] = 2;
        r[9] = (uint8_t)(block_size(s) >> 16); r[10] = (uint8_t)(block_size(s) >> 8); r[11] = (uint8_t)block_size(s);
        response(s, 12, be16(cdb + 7)); break;
    case 0x28: read_blocks(s, be32(cdb + 2), be16(cdb + 7)); break;
    case 0xa8: read_blocks(s, be32(cdb + 2), be32(cdb + 6)); break;
    case 0x88: read_blocks(s, be64(cdb + 2), be32(cdb + 10)); break;
    case 0xbe: /* READ CD, user-data-only Mode 1 sectors. */
        if (s->lun || (cdb[9] & 0xf8) != 0x10 || cdb[10]) { fail(s, 5, 0x24); break; }
        read_blocks(s, be32(cdb + 2), (uint32_t)cdb[6] << 16 | (uint32_t)cdb[7] << 8 | cdb[8]); break;
    case 0x43: { /* READ TOC, single closed data track */
        if (s->lun) { fail(s, 5, 0x20); break; }
        if (!ready(s)) { fail(s, 2, 0x3a); break; }
        uint8_t format = cdb[2] & 15;
        r[2] = r[3] = 1; r[5] = 0x14; r[6] = 1;
        toc_address(r + 8, 0, cdb[1] & 2);
        if (format == 0) {
            r[13] = 0x14; r[14] = 0xaa;
            toc_address(r + 16, (uint32_t)blocks(s), cdb[1] & 2);
            put_be16(r, 18); response(s, 20, be16(cdb + 7));
        } else if (format == 1) { put_be16(r, 10); response(s, 12, be16(cdb + 7)); }
        else fail(s, 5, 0x24);
        break;
    }
    case 0x46: /* GET CONFIGURATION, DVD-ROM profile and readable block feature */
        if (s->lun) { fail(s, 5, 0x20); break; }
        put_be16(r + 6, ready(s) ? 0x10 : 0);
        if (be16(cdb + 2) == 0) {
            put_be16(r + 8, 0); r[10] = 3; r[11] = 8;
            put_be16(r + 12, 8); put_be16(r + 16, 0x10); r[18] = 1;
            put_be32(r, 16); response(s, 20, be16(cdb + 7));
        } else { put_be32(r, 4); response(s, 8, be16(cdb + 7)); }
        break;
    case 0x4a: /* GET EVENT STATUS NOTIFICATION, no pending event. */
        if (s->lun) { fail(s, 5, 0x20); break; }
        put_be16(r, 6); r[2] = 4; r[3] = 0x10; r[5] = ready(s) ? 2 : 0;
        response(s, 8, be16(cdb + 7)); break;
    case 0x51: /* READ DISC INFORMATION, complete single-session disc. */
        if (s->lun) { fail(s, 5, 0x20); break; }
        put_be16(r, 32); r[2] = 0x0e; r[3] = r[4] = r[5] = r[6] = 1;
        response(s, 34, be16(cdb + 7)); break;
    case 0x15: case 0x55: /* MODE SELECT, media remain immutable. */
        break;
    case 0x2a: case 0xaa: case 0x8a:
        fail(s, 7, 0x27); break; /* DATA PROTECT, WRITE PROTECTED */
    default: fail(s, 5, 0x20); break;
    }
    if (s->host_length && s->direction_in) {
        s->phase = HV_USB_STORAGE_DATA_IN;
    } else if (s->host_length) {
        /* Consume unsupported write parameters before the failure CSW. */
        if (s->response_length || s->read_remaining) s->status = 2;
        s->response_length = 0; s->read_remaining = 0;
        s->phase = HV_USB_STORAGE_DATA_OUT;
    } else begin_csw(s);
}

int hv_usb_storage_write(HvUsbStorage *s, const uint8_t *data, uint32_t length) {
    if (s->phase == HV_USB_STORAGE_INVALID) return -1;
    if (s->phase == HV_USB_STORAGE_DATA_OUT) {
        if (length > s->host_length - s->response_offset) { s->phase = HV_USB_STORAGE_INVALID; return -1; }
        /* No writes reach the backing images. Do not count discarded payload
         * as processed: dCSWDataResidue reports the unprocessed host data. */
        s->response_offset += length;
        if (!s->status) s->residue -= length;
        if (s->response_offset >= s->host_length) begin_csw(s);
        return 0;
    }
    if (s->phase != HV_USB_STORAGE_CBW || length > sizeof s->cbw - s->cbw_used) {
        s->phase = HV_USB_STORAGE_INVALID; return -1;
    }
    memcpy(s->cbw + s->cbw_used, data, length); s->cbw_used += length;
    if (s->cbw_used != sizeof s->cbw) return 0;
    const uint8_t *b = s->cbw;
    if (le32(b) != 0x43425355 || (b[12] & 0x7f) || b[13] > 1 || (b[14] & 0xe0) || !(b[14] & 31) || (b[14] & 31) > 16) {
        s->phase = HV_USB_STORAGE_INVALID; return -1;
    }
    s->tag = le32(b + 4); s->host_length = s->residue = le32(b + 8);
    s->direction_in = b[12] >> 7; s->lun = b[13];
    command(s, b + 15);
    return 0;
}

int hv_usb_storage_read(HvUsbStorage *s, uint8_t *data, uint32_t capacity) {
    if (s->phase == HV_USB_STORAGE_INVALID) return -1;
    if (s->phase == HV_USB_STORAGE_CBW || s->phase == HV_USB_STORAGE_DATA_OUT) return -2;
    if (s->phase == HV_USB_STORAGE_CSW) {
        uint32_t n = sizeof s->csw - s->csw_offset;
        if (n > capacity) n = capacity;
        memcpy(data, s->csw + s->csw_offset, n); s->csw_offset += n;
        if (s->csw_offset == sizeof s->csw) hv_usb_storage_reset(s);
        return (int)n;
    }
    uint32_t n = 0;
    if (s->read_remaining) {
        n = s->read_remaining < capacity ? (uint32_t)s->read_remaining : capacity;
        if (hv_disk_read(s->media[s->lun], s->read_offset, data, n) != 0) {
            fail(s, 3, 0x11); s->read_remaining = 0; begin_csw(s); return 0;
        }
        s->read_offset += n; s->read_remaining -= n;
    } else {
        n = s->response_length - s->response_offset;
        if (n > capacity) n = capacity;
        memcpy(data, s->response + s->response_offset, n); s->response_offset += n;
    }
    s->residue -= n;
    if (!s->read_remaining && s->response_offset == s->response_length) begin_csw(s);
    return (int)n;
}
