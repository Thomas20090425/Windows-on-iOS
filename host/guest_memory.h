/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_GUEST_MEMORY_H
#define HV_GUEST_MEMORY_H
#include <stdint.h>

#define HV_GUEST_MIN_MEMORY_MB 4096ULL
#define HV_GUEST_HOST_HEADROOM_MB 3072ULL
/* Additional process budget for engine metadata, JIT working set and UI.
 * A file-backed guest mapping is not charged as anonymous guest-size RAM. */
#define HV_GUEST_ENGINE_HEADROOM_MB 1024ULL
/* RAM starts at 1 GiB and must end before the high PCIe ECAM aperture. */
#define HV_GUEST_MAP_MAX_MEMORY_MB ((0x4010000000ULL - 0x40000000ULL) >> 20)

static inline uint64_t hv_guest_memory_limit_mb(uint64_t physical_bytes) {
    uint64_t physical_mb = physical_bytes >> 20;
    uint64_t maximum = physical_mb > HV_GUEST_HOST_HEADROOM_MB ?
        physical_mb - HV_GUEST_HOST_HEADROOM_MB : 0;
    return maximum < HV_GUEST_MAP_MAX_MEMORY_MB ? maximum : HV_GUEST_MAP_MAX_MEMORY_MB;
}
#endif
