#ifndef WINVM_FB_DISPLAY_H
#define WINVM_FB_DISPLAY_H

#include <pthread.h>
#include <stdint.h>

#include "fw_cfg.h"
#include "machine.h"
#include "pcie.h"

/* Linear framebuffer display supporting QEMU `ramfb` (etc/ramfb in fw_cfg, used by
   EDK2 ArmVirtQemu GOP -> winload.efi -> Windows 11 BasicDisplay.sys + DWM)
   as well as optional VBE/bochs scanout. Zero MMIO exits per pixel write! */

typedef struct HvFbDisplay {
    HvMachine *m;
    pthread_mutex_t mu;

    /* Active scanout geometry (protected by mu) */
    uint64_t fb_pa;
    const uint8_t *fb_host;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t fourcc; /* DRM fourcc, e.g. XR24 / AR24 (32-bit BGRX) */
    int active;
    int gpu_active; /* A real guest GPU scanout supersedes firmware ramfb. */
    uint64_t generation; /* GPU flush/cursor generation, protected by mu. */
    int presentation_hz; /* Set before Metal presenter creation; zero means 60 Hz. */

    /* Metal presenter handle (created lazily by fb_metal.m) */
    void *metal;
} HvFbDisplay;

HvFbDisplay *hv_fb_display_create(HvMachine *m, HvFwCfg *fw_cfg);
/* Thread-safe snapshot of current scanout pointer and dimensions; returns 0 if active, -1 if not yet set. */
int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride);
/* Hold the frame lock while dereferencing pixels. Dynamic GPU resources can be
 * replaced/freed on another CPU; get_frame alone is for geometry snapshots. */
int hv_fb_display_lock_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride);
void hv_fb_display_unlock_frame(HvFbDisplay *fb);

/* Metal layer presentation & PNG screenshot helpers (implemented in devices/fb_metal.m) */
void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer);
uint64_t hv_fb_metal_frames(HvFbDisplay *fb);
int hv_fb_save_png(HvFbDisplay *fb, const char *path);

#endif
