/* SPDX-License-Identifier: GPL-2.0-or-later */
/* VirtIO 1.3 GPU 2D command protocol, implemented against the OASIS device
 * specification. Images stay in host memory and are presented through Metal;
 * no accelerated 3D features are advertised. */
#include "virtio_gpu.h"

#include <stdlib.h>
#include <string.h>

enum {
    CMD_DISPLAY_INFO = 0x100, CMD_CREATE_2D, CMD_UNREF, CMD_SCANOUT,
    CMD_FLUSH, CMD_TRANSFER, CMD_ATTACH, CMD_DETACH, CMD_CAPSET_INFO,
    CMD_CAPSET, CMD_EDID,
    CMD_UPDATE_CURSOR = 0x300, CMD_MOVE_CURSOR,
    RESP_OK = 0x1100, RESP_DISPLAY_INFO = 0x1101, RESP_EDID = 0x1104,
    ERR_UNSPEC = 0x1200, ERR_NO_MEMORY, ERR_SCANOUT, ERR_RESOURCE,
    ERR_CONTEXT, ERR_PARAMETER,
    RESOURCE_LIMIT = 64,
    BACKING_LIMIT = 65536,
    MAX_DIMENSION = 8192,
    CURSOR_SIZE = 64,
};
#define MAX_IMAGE_BYTES (UINT64_C(256) << 20)
#define MAX_TOTAL_BYTES (UINT64_C(512) << 20)

typedef struct Backing {
    uint64_t address;
    uint64_t offset;
    uint32_t length;
} Backing;

typedef struct Resource {
    uint32_t id, format, width, height;
    uint8_t *pixels;
    Backing *backing;
    uint32_t nbacking;
    uint64_t backing_bytes;
} Resource;

typedef struct Rect { uint32_t x, y, width, height; } Rect;

struct HvVirtioGpu {
    HvVirtio vio;
    HvFbDisplay *fb;
    Resource resources[RESOURCE_LIMIT];
    uint64_t resource_bytes;
    uint32_t preferred_width, preferred_height;
    uint32_t scanout_resource;
    Rect scanout_rect;
    uint8_t *scanout_pixels;
    uint32_t cursor_resource, cursor_x, cursor_y, cursor_hot_x, cursor_hot_y;
    uint8_t edid[128];
};

static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t u64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void put64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static Rect rect(const uint8_t *p) { return (Rect){u32(p), u32(p + 4), u32(p + 8), u32(p + 12)}; }

static int rect_valid(Rect r, const Resource *resource) {
    return r.x <= resource->width && r.y <= resource->height &&
        r.width <= resource->width - r.x && r.height <= resource->height - r.y;
}

static Resource *find_resource(HvVirtioGpu *g, uint32_t id) {
    if (!id) return NULL;
    for (unsigned i = 0; i < RESOURCE_LIMIT; i++)
        if (g->resources[i].id == id) return &g->resources[i];
    return NULL;
}

static int valid_format(uint32_t format) {
    return format == 1 || format == 2 || format == 67 || format == 134;
}

static void pixel_bgra(const Resource *resource, const uint8_t *src, uint8_t dst[4]) {
    if (resource->format == 67 || resource->format == 134) {
        dst[0] = src[2]; dst[1] = src[1]; dst[2] = src[0];
    } else {
        dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
    }
    dst[3] = resource->format == 1 || resource->format == 67 ? src[3] : 255;
}

static void create_edid(HvVirtioGpu *g) {
    uint8_t *e = g->edid;
    memset(e, 0, 128);
    const uint8_t magic[8] = {0, 255, 255, 255, 255, 255, 255, 0};
    memcpy(e, magic, 8);
    e[8] = 0x5d; e[9] = 0x2e; /* WIN manufacturer */
    e[10] = 1; e[12] = 1;
    e[16] = 1; e[17] = 36; /* 2026 */
    e[18] = 1; e[19] = 4;
    e[20] = 0xa0; /* Digital, 8-bit components */
    e[21] = 32; e[22] = 24; e[23] = 120; e[24] = 0x0e;
    e[35] = 0x20; e[36] = 0x08; /* 640x480 and 1024x768 at 60 Hz */
    for (unsigned i = 38; i < 54; i += 2) e[i] = e[i + 1] = 1;
    uint32_t width = g->preferred_width, height = g->preferred_height;
    uint32_t hb = 160, vb = 45;
    uint32_t clock = ((width + hb) * (height + vb) * 60 + 9999) / 10000;
    if (clock > 65535) clock = ((width + hb) * (height + vb) * 30 + 9999) / 10000;
    uint8_t *d = e + 54;
    d[0] = (uint8_t)clock; d[1] = (uint8_t)(clock >> 8);
    d[2] = (uint8_t)width; d[3] = (uint8_t)hb;
    d[4] = (uint8_t)(((width >> 8) << 4) | (hb >> 8));
    d[5] = (uint8_t)height; d[6] = (uint8_t)vb;
    d[7] = (uint8_t)(((height >> 8) << 4) | (vb >> 8));
    d[8] = 48; d[9] = 32; d[10] = 0x35;
    d[12] = 0x40; d[13] = 0xf0; d[14] = 0x10; d[17] = 0x1a;
    uint8_t *name = e + 72;
    name[3] = 0xfc;
    memcpy(name + 5, "WindowsiOS\n  ", 13);
    uint8_t *serial = e + 90;
    serial[3] = 0xff;
    memcpy(serial + 5, "VirtIO GPU\n  ", 13);
    uint8_t *unused = e + 108;
    unused[3] = 0x10;
    unsigned sum = 0;
    for (unsigned i = 0; i < 127; ++i) sum += e[i];
    e[127] = (uint8_t)(0u - sum);
}

/* Called with fb->mu held; the display owns a composition buffer independent
 * of guest resources, so releasing backing pages never races the presenter. */
static void render_scanout(HvVirtioGpu *g) {
    Resource *r = find_resource(g, g->scanout_resource);
    if (!r || !g->scanout_pixels) return;
    Rect s = g->scanout_rect;
    g->fb->generation++;
    for (uint32_t y = 0; y < s.height; ++y) {
        const uint8_t *source = r->pixels + ((uint64_t)(s.y + y) * r->width + s.x) * 4;
        uint8_t *destination = g->scanout_pixels + (uint64_t)y * s.width * 4;
        if (r->format == 1 || r->format == 2) memcpy(destination, source, (size_t)s.width * 4);
        else for (uint32_t x = 0; x < s.width; ++x) pixel_bgra(r, source + x * 4, destination + x * 4);
    }
    Resource *cursor = find_resource(g, g->cursor_resource);
    if (cursor && cursor->width == CURSOR_SIZE && cursor->height == CURSOR_SIZE) {
        for (uint32_t y = 0; y < CURSOR_SIZE; y++) for (uint32_t x = 0; x < CURSOR_SIZE; x++) {
            int64_t sx = (int64_t)g->cursor_x + x - g->cursor_hot_x;
            int64_t sy = (int64_t)g->cursor_y + y - g->cursor_hot_y;
            if (sx < 0 || sy < 0 || sx >= s.width || sy >= s.height) continue;
            uint8_t color[4];
            pixel_bgra(cursor, cursor->pixels + ((size_t)y * CURSOR_SIZE + x) * 4, color);
            uint8_t *pixel = g->scanout_pixels + ((uint64_t)sy * s.width + (uint64_t)sx) * 4;
            for (unsigned c = 0; c < 3; c++)
                pixel[c] = (uint8_t)((color[c] * color[3] + pixel[c] * (255 - color[3]) + 127) / 255);
            pixel[3] = 255;
        }
    }
}

static void clear_scanout(HvVirtioGpu *g, int return_to_firmware) {
    static const uint8_t black_pixel[4] = {0, 0, 0, 255};
    pthread_mutex_lock(&g->fb->mu);
    if (g->fb->gpu_active) {
        g->fb->active = !return_to_firmware;
        g->fb->fb_host = return_to_firmware ? NULL : black_pixel;
        g->fb->width = g->fb->height = return_to_firmware ? 0 : 1;
        g->fb->stride = return_to_firmware ? 0 : 4;
        g->fb->generation++;
        if (return_to_firmware) g->fb->gpu_active = 0;
    }
    free(g->scanout_pixels);
    g->scanout_pixels = NULL;
    g->scanout_resource = 0;
    memset(&g->scanout_rect, 0, sizeof g->scanout_rect);
    pthread_mutex_unlock(&g->fb->mu);
}

static void reset_device(HvVirtio *v) {
    HvVirtioGpu *g = v->dev;
    clear_scanout(g, 1);
    for (unsigned i = 0; i < RESOURCE_LIMIT; ++i) {
        free(g->resources[i].pixels);
        free(g->resources[i].backing);
    }
    memset(g->resources, 0, sizeof g->resources);
    g->resource_bytes = 0;
    g->cursor_resource = 0;
    memset(v->config, 0, sizeof v->config);
    put32(v->config + 8, 1); /* one scanout, no 3D capsets */
}

static int backing_read(HvVirtioGpu *g, const Resource *r, uint64_t offset, void *buffer, uint32_t length) {
    uint8_t *out = buffer;
    if (offset > r->backing_bytes || length > r->backing_bytes - offset) return -1;
    uint32_t low = 0, high = r->nbacking;
    while (low < high) {
        uint32_t middle = low + (high - low) / 2;
        if (r->backing[middle].offset + r->backing[middle].length <= offset) low = middle + 1;
        else high = middle;
    }
    for (uint32_t i = low; i < r->nbacking && length; i++) {
        const Backing *entry = r->backing + i;
        uint64_t within = offset - entry->offset;
        uint32_t n = entry->length - (uint32_t)within;
        if (n > length) n = length;
        const uint8_t *source = hv_phys_ptr(g->vio.m, entry->address + within, n);
        if (!source) return -1;
        memcpy(out, source, n);
        out += n; length -= n; offset += n;
    }
    return length ? -1 : 0;
}

static uint32_t handle_command(HvVirtioGpu *g, const HvVirtqElem *element,
                                const uint8_t *request, uint32_t request_size,
                                uint8_t *response, uint32_t *response_size) {
    uint32_t type = u32(request);
    uint32_t id = request_size >= 28 ? u32(request + 24) : 0;
    Resource *resource;
    if (u32(request + 4) & ~1u) return ERR_PARAMETER;
    switch (type) {
    case CMD_DISPLAY_INFO:
        memset(response + 24, 0, 16 * 24);
        put32(response + 32, g->preferred_width);
        put32(response + 36, g->preferred_height);
        put32(response + 40, 1);
        *response_size = 24 + 16 * 24;
        return RESP_DISPLAY_INFO;
    case CMD_EDID:
        if (request_size < 32) return ERR_PARAMETER;
        if (id) return ERR_SCANOUT;
        memset(response + 24, 0, 8 + 1024);
        put32(response + 24, 128);
        memcpy(response + 32, g->edid, 128);
        *response_size = 24 + 8 + 1024;
        return RESP_EDID;
    case CMD_CREATE_2D: {
        if (request_size < 40 || !id || find_resource(g, id)) return ERR_RESOURCE;
        uint32_t format = u32(request + 28), width = u32(request + 32), height = u32(request + 36);
        if (!valid_format(format) || !width || !height || width > MAX_DIMENSION || height > MAX_DIMENSION)
            return ERR_PARAMETER;
        uint64_t bytes = (uint64_t)width * height * 4;
        if (bytes > MAX_IMAGE_BYTES || bytes > MAX_TOTAL_BYTES - g->resource_bytes) return ERR_NO_MEMORY;
        resource = NULL;
        for (unsigned i = 0; i < RESOURCE_LIMIT; ++i)
            if (!g->resources[i].id) { resource = &g->resources[i]; break; }
        if (!resource) return ERR_NO_MEMORY;
        uint8_t *pixels = calloc(1, (size_t)bytes);
        if (!pixels) return ERR_NO_MEMORY;
        *resource = (Resource){.id = id, .format = format, .width = width, .height = height, .pixels = pixels};
        g->resource_bytes += bytes;
        return RESP_OK;
    }
    case CMD_UNREF:
        if (request_size < 32 || !(resource = find_resource(g, id))) return ERR_RESOURCE;
        if (g->scanout_resource == id) clear_scanout(g, 0);
        if (g->cursor_resource == id) {
            g->cursor_resource = 0;
            pthread_mutex_lock(&g->fb->mu);
            render_scanout(g);
            pthread_mutex_unlock(&g->fb->mu);
        }
        g->resource_bytes -= (uint64_t)resource->width * resource->height * 4;
        free(resource->pixels); free(resource->backing);
        memset(resource, 0, sizeof *resource);
        return RESP_OK;
    case CMD_ATTACH: {
        if (request_size < 32 || !(resource = find_resource(g, id))) return ERR_RESOURCE;
        uint32_t count = u32(request + 28);
        if (!count || count > BACKING_LIMIT || resource->backing) return ERR_PARAMETER;
        Backing *entries = calloc(count, sizeof *entries);
        if (!entries) return ERR_NO_MEMORY;
        uint64_t total = 0;
        for (uint32_t i = 0; i < count; i++) {
            uint8_t entry[16];
            if (hv_virtq_read(&g->vio, element, 32 + i * 16, entry, 16) != 16) { free(entries); return ERR_PARAMETER; }
            uint64_t address = u64(entry);
            uint32_t length = u32(entry + 8);
            if (!length || length > MAX_IMAGE_BYTES || address > UINT64_MAX - length || total > MAX_IMAGE_BYTES - length ||
                    !hv_phys_ptr(g->vio.m, address, length)) { free(entries); return ERR_PARAMETER; }
            entries[i] = (Backing){.address = address, .offset = total, .length = length};
            total += length;
        }
        if (total < (uint64_t)resource->width * resource->height * 4) { free(entries); return ERR_PARAMETER; }
        resource->backing = entries;
        resource->nbacking = count;
        resource->backing_bytes = total;
        return RESP_OK;
    }
    case CMD_DETACH:
        if (request_size < 32 || !(resource = find_resource(g, id))) return ERR_RESOURCE;
        free(resource->backing); resource->backing = NULL;
        resource->nbacking = 0; resource->backing_bytes = 0;
        return RESP_OK;
    case CMD_TRANSFER: {
        if (request_size < 56) return ERR_PARAMETER;
        Rect area = rect(request + 24);
        resource = find_resource(g, u32(request + 48));
        uint64_t offset = u64(request + 40);
        if (!resource) return ERR_RESOURCE;
        if (!resource->backing || !rect_valid(area, resource)) return ERR_PARAMETER;
        if (!area.width || !area.height) return RESP_OK;
        uint64_t stride = (uint64_t)resource->width * 4;
        uint64_t span = (uint64_t)(area.height - 1) * stride + (uint64_t)area.width * 4;
        if (offset > resource->backing_bytes || span > resource->backing_bytes - offset) return ERR_PARAMETER;
        if (!area.x && area.width == resource->width) {
            return backing_read(g, resource, offset,
                resource->pixels + (uint64_t)area.y * stride,
                (uint32_t)((uint64_t)area.height * stride)) ? ERR_PARAMETER : RESP_OK;
        }
        for (uint32_t y = 0; y < area.height; ++y) {
            uint8_t *destination = resource->pixels + ((uint64_t)(area.y + y) * resource->width + area.x) * 4;
            if (backing_read(g, resource, offset + y * stride, destination, area.width * 4)) return ERR_PARAMETER;
        }
        return RESP_OK;
    }
    case CMD_SCANOUT: {
        if (request_size < 48) return ERR_PARAMETER;
        Rect area = rect(request + 24);
        uint32_t scanout = u32(request + 40), resource_id = u32(request + 44);
        if (scanout) return ERR_SCANOUT;
        if (!resource_id) { clear_scanout(g, 0); return RESP_OK; }
        resource = find_resource(g, resource_id);
        if (!resource) return ERR_RESOURCE;
        if (!area.width || !area.height || !rect_valid(area, resource)) return ERR_PARAMETER;
        uint8_t *pixels = calloc((size_t)area.width * area.height, 4);
        if (!pixels) return ERR_NO_MEMORY;
        pthread_mutex_lock(&g->fb->mu);
        free(g->scanout_pixels);
        g->scanout_pixels = pixels;
        g->scanout_resource = resource_id;
        g->scanout_rect = area;
        render_scanout(g);
        g->fb->gpu_active = 1;
        g->fb->fb_pa = 0;
        g->fb->fb_host = pixels;
        g->fb->width = area.width; g->fb->height = area.height; g->fb->stride = area.width * 4;
        g->fb->fourcc = 0x34325258u;
        g->fb->active = 1;
        pthread_mutex_unlock(&g->fb->mu);
        return RESP_OK;
    }
    case CMD_FLUSH: {
        if (request_size < 48) return ERR_PARAMETER;
        resource = find_resource(g, u32(request + 40));
        if (!resource) return ERR_RESOURCE;
        if (!rect_valid(rect(request + 24), resource)) return ERR_PARAMETER;
        if (resource->id == g->scanout_resource) {
            pthread_mutex_lock(&g->fb->mu);
            render_scanout(g);
            pthread_mutex_unlock(&g->fb->mu);
        }
        return RESP_OK;
    }
    case CMD_CAPSET_INFO: case CMD_CAPSET:
        return ERR_PARAMETER; /* no 3D capsets advertised */
    default: return ERR_UNSPEC;
    }
}

static void handle_cursor(HvVirtioGpu *g, const uint8_t *request, uint32_t length) {
    if (length < 56 || u32(request + 24)) return;
    uint32_t type = u32(request);
    if (type != CMD_UPDATE_CURSOR && type != CMD_MOVE_CURSOR) return;
    if (type == CMD_UPDATE_CURSOR) {
        uint32_t id = u32(request + 40), hot_x = u32(request + 44), hot_y = u32(request + 48);
        Resource *resource = find_resource(g, id);
        if (id && (!resource || resource->width != CURSOR_SIZE || resource->height != CURSOR_SIZE ||
                   hot_x >= CURSOR_SIZE || hot_y >= CURSOR_SIZE)) return;
        g->cursor_resource = id; g->cursor_hot_x = hot_x; g->cursor_hot_y = hot_y;
    }
    g->cursor_x = u32(request + 28); g->cursor_y = u32(request + 32);
    pthread_mutex_lock(&g->fb->mu);
    render_scanout(g);
    pthread_mutex_unlock(&g->fb->mu);
}

static void notify(HvVirtio *v, int queue) {
    HvVirtioGpu *g = v->dev;
    int completed = 0;
    for (unsigned budget = 0; budget < HV_VIRTQ_MAX_SIZE; ++budget) {
        HvVirtqElem element;
        int result = hv_virtq_pop(v, queue, &element);
        if (!result) break;
        uint32_t written = 0;
        if (result > 0) {
            uint8_t request[64] = {0};
            uint32_t length = hv_virtq_read(v, &element, 0, request, sizeof request);
            if (queue == 1) handle_cursor(g, request, length);
            else if (length >= 24 && hv_virtq_writable(&element) >= 24) {
                uint8_t response[24 + 8 + 1024] = {0};
                uint32_t response_size = 24;
                uint32_t type = handle_command(g, &element, request, length, response, &response_size);
                if (type >= ERR_UNSPEC) response_size = 24;
                if (hv_virtq_writable(&element) < response_size) { type = ERR_PARAMETER; response_size = 24; }
                put32(response, type);
                if (u32(request + 4) & 1) {
                    put32(response + 4, 1);
                    put64(response + 8, u64(request + 8));
                    put32(response + 16, u32(request + 16));
                }
                written = hv_virtq_write(v, &element, 0, response, response_size);
            }
        }
        hv_virtq_push(v, queue, &element, written);
        completed = 1;
    }
    if (completed) hv_virtio_queue_interrupt(v, queue);
}

static void config_write(HvVirtio *v, uint32_t offset, uint64_t value, unsigned size) {
    if (offset == 4 && size == 4) put32(v->config, u32(v->config) & ~(uint32_t)value);
}

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb,
                                  uint32_t width, uint32_t height) {
    if (!m || !bus || !fb || width < 64 || height < 64 || width > 4095 || height > 4095) return NULL;
    HvVirtioGpu *g = calloc(1, sizeof *g);
    if (!g) return NULL;
    g->fb = fb;
    g->preferred_width = width; g->preferred_height = height;
    hv_virtio_init(&g->vio, m, 16, 0x038000, 2, 1u << 1); /* EDID only */
    g->vio.dev = g;
    g->vio.notify = notify;
    g->vio.reset = reset_device;
    g->vio.config_write = config_write;
    g->vio.config_len = 16;
    /* Retain the transport's subsystem device 0x0010. The pinned EDK2
     * Virtio10 driver deliberately excludes subsystem IDs below 0x40; this
     * keeps its PixelBltOnly GPU GOP from displacing the linear RAMFB boot
     * console. Modern Windows matches PCI 1af4:1050 independently of subsys. */
    hv_virtio_enable_msix(&g->vio, 4);
    put32(g->vio.config + 8, 1);
    create_edid(g);
    if (hv_pcie_attach(bus, &g->vio.pci) < 0) { free(g); return NULL; }
    return g;
}

int hv_virtio_gpu_set_preferred(HvVirtioGpu *g, uint32_t width, uint32_t height) {
    if (!g || width < 64 || height < 64 || width > 4095 || height > 4095) return -1;
    if (g->preferred_width == width && g->preferred_height == height) return 0;
    g->preferred_width = width; g->preferred_height = height;
    create_edid(g);
    put32(g->vio.config, u32(g->vio.config) | 1u);
    g->vio.config_gen++;
    if (g->vio.status & 4) hv_virtio_config_interrupt(&g->vio);
    return 0;
}

int hv_virtio_gpu_driver_ready(const HvVirtioGpu *g) {
    return g && (g->vio.status & 4) && g->scanout_resource && g->scanout_pixels;
}

void hv_virtio_gpu_reset(HvVirtioGpu *g) {
    if (g) hv_virtio_reset(&g->vio);
}
