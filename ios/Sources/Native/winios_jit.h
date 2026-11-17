/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Dual-mapped RX/RW JIT allocator for iOS 17..27 (including iOS 26/27 TXM).
 * Adapted from Henge (Leviidev/Henge, GPL-2.0-or-later).
 */
#ifndef WINIOS_JIT_H
#define WINIOS_JIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WinIosDualMapping {
    uint8_t *rw_addr;
    uint8_t *rx_addr;
    size_t   size;
} WinIosDualMapping;

typedef enum WinIosGuestRamKind {
    WINIOS_GUEST_RAM_NONE = 0,
    WINIOS_GUEST_RAM_LEDGER_EXEMPT = 1,
    WINIOS_GUEST_RAM_FILE_BACKED = 2,
} WinIosGuestRamKind;

#define WINIOS_JIT_DEFAULT_BYTES ((size_t)384u << 20) /* 384 MiB */

void winios_jit_install_trap_handler(void);
bool winios_jit_is_debugger_attached(void);
bool winios_jit_acquire(size_t bytes, bool detach_after);
bool winios_jit_is_live(void);
/* Debugger helper handshake; a normal Xcode debugger is not a JIT provider. */
uint64_t winios_jit_helper_token_address(void);
WinIosDualMapping winios_jit_mapping(void);
void *winios_jit_guest_ram(uint64_t *out_bytes);
WinIosGuestRamKind winios_jit_guest_ram_kind(void);
/* Caller must check the device's physical-memory policy first. Call only
 * before creating the engine: a different size replaces the prior mapping
 * after the replacement succeeds. No guest allocation is silently shrunk. */
bool winios_jit_reserve_guest_ram(uint64_t memory_mb, const char *backing_template,
                                 char *error, size_t error_size);
/* Sets the next debugger-assisted RAM reservation; existing mappings are kept. */
void winios_jit_set_guest_memory_mb(uint64_t memory_mb);
const char *winios_jit_status_text(void);
size_t winios_available_memory_bytes(void);
/* Process ledger footprint, excluding any ledger-exempt guest mappings. */
bool winios_process_footprint_bytes(uint64_t *out_bytes);
void winios_jit_copy_guest_ram_status(char *buffer, size_t size);

#ifdef __cplusplus
}
#endif

#endif
