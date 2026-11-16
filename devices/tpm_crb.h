/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_TPM_CRB_H
#define HV_TPM_CRB_H

#include <stddef.h>
#include <stdint.h>

#define HV_TPM_CRB_BASE UINT64_C(0x090c0000)
#define HV_TPM_CRB_SIZE UINT64_C(0x10000)
#define HV_TPM_CRB_CONTROL_OFFSET UINT64_C(0x40)
#define HV_TPM_TIS_BASE UINT64_C(0x090d0000)
#define HV_TPM_TIS_SIZE UINT64_C(0x10000)

typedef struct HvMachine HvMachine;
typedef struct HvTpmCrb HvTpmCrb;

/* One software TPM with CRB for ACPI/Windows and FIFO/TIS for bundled EDK2.
 * TIS is placed at crb_base + HV_TPM_CRB_SIZE. State is private to this VM.
 * Failure never registers a device or replaces unreadable existing state.
 * The library is process-global; a second live instance is rejected. */
HvTpmCrb *hv_tpm_crb_create(HvMachine *m, uint64_t crb_base, const char *state_dir,
                            char *error, size_t error_size);
/* Call only with guest CPUs stopped and the machine's device lock held. */
int hv_tpm_crb_reset(HvTpmCrb *tpm);
int hv_tpm_crb_flush(HvTpmCrb *tpm);
/* A non-NULL latched error means execution must stop, preserving TPM state. */
const char *hv_tpm_crb_error(const HvTpmCrb *tpm);
/* The caller must first stop all CPUs and release device ownership. */
void hv_tpm_crb_destroy(HvTpmCrb *tpm);

#endif
