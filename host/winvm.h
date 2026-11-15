/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_WINVM_H
#define HV_WINVM_H

#include <stddef.h>
#include <stdint.h>

#include "winvirt.h"

typedef struct HvWinVmConfig {
    const char *code_fd;      /* 64 MB EDK2 UEFI firmware (read-only) */
    const char *vars_fd;      /* 64 MB UEFI NVRAM (read/write persistent) */
    const char *disk0;        /* Primary NVMe disk image (raw or .hvsparse) */
    const char *disk1;        /* Optional secondary/installer NVMe disk image (read-only) */
    const char *installer_iso; /* Optional read-only USB CD-ROM, 2048-byte optical sectors. */
    const char *installer_answer_disk; /* Optional read-only 512-byte removable setup disk. */
    const char *share_dir;    /* Optional host folder shared over WebDAV at http://10.0.2.4/ */
    const char *share_sock;   /* Path for internal WebDAV Unix domain socket */
    int ncpus;
    uint64_t ram_mb;
    size_t jit_bytes;
    void *jit_rx;             /* Optional split RX/RW JIT pointers for iOS TXM */
    void *jit_rw;
    void *prealloc_ram;       /* Optional pre-allocated Guest RAM (ledger-exempt on iOS) */
    int no_net;
    int enable_sound;
    int log;
    int stats_interval;
    int disk0_readonly;
    int disable_microphone;
    int display_refresh_hz;   /* 0 = 60 Hz; supported host presentation rates: 30/60/120 */
    int tcp_forward_host_port; /* 0 disables; otherwise loopback TCP only */
    int tcp_forward_guest_port;
} HvWinVmConfig;

int hv_winvm_create(const HvWinVmConfig *cfg, char *err, size_t errlen);
void hv_winvm_start(int spawn_cpu0, void (*on_exit)(int reason));
int hv_winvm_run_cpu0(void);
void hv_winvm_stop(void);
void hv_winvm_power_button(void);
void hv_winvm_flush_disks(void);

/* Display & screenshot hooks (any thread) */
void hv_winvm_set_display_layer(void *ca_metal_layer);
int hv_winvm_display_size(uint32_t *w, uint32_t *h);
uint64_t hv_winvm_display_frames(void);
int hv_winvm_save_png(const char *path);

/* Input hooks (any thread) */
void hv_winvm_key_hid(uint8_t usage, int down);
void hv_winvm_key_linux(uint16_t code, int down);
/* Normalized tablet pointer: x_norm, y_norm in [0.0, 1.0] mapped to 0..32767;
 * buttons: bit0=Left, bit1=Right, bit2=Middle; wheel: -127..127. */
void hv_winvm_tablet(double x_norm, double y_norm, uint8_t buttons, int8_t wheel);
void hv_winvm_tablet_scroll(double x_norm, double y_norm, uint8_t buttons,
                            int8_t wheel, int8_t horizontal_wheel);
void hv_winvm_send_ctrl_alt_del(void);
void hv_winvm_usb_stats(int *kbd_ready, int *tab_ready, uint64_t *delivered);
void hv_winvm_engine_stats(uint64_t *jit_used_bytes, uint64_t *jit_cap_bytes,
                           uint64_t *jit_full_flushes, uint64_t *wfi_ticks);
int hv_winvm_share_up(void);
int hv_winvm_network_up(void);

HvMachine *hv_winvm_machine(void);
HvWinVirt *hv_winvm_board(void);
const char *hv_winvm_reason_name(int reason);

#endif
