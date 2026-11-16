/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_VIRTIO_GPU_H
#define HV_VIRTIO_GPU_H

#include <stdint.h>
#include "fb_display.h"
#include "virtio.h"

typedef struct HvVirtioGpu HvVirtioGpu;

/* Standard VirtIO GPU 2D (PCI 1af4:1050). No virgl/3D/host GPU passthrough. */
HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb,
                                  uint32_t preferred_width, uint32_t preferred_height);
/* Call under the machine device lock. A configuration interrupt asks a guest
 * driver to re-read preferred modes; the guest remains responsible for modeset. */
int hv_virtio_gpu_set_preferred(HvVirtioGpu *gpu, uint32_t width, uint32_t height);
int hv_virtio_gpu_driver_ready(const HvVirtioGpu *gpu);
/* Stop guest CPUs and hold the machine device lock before resetting. */
void hv_virtio_gpu_reset(HvVirtioGpu *gpu);

#endif
