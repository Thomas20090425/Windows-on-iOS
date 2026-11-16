/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_CPU_MODEL_H
#define HV_CPU_MODEL_H

#include <stdint.h>

/* One guest identity shared by MIDR, device tree, SMBIOS and the host UI.
 * This describes the translator's compatibility profile, not the host Apple
 * chip. Feature ID registers continue to describe the implemented guest ISA.
 * The timing rate is nominal virtual accounting, not measured JIT throughput
 * or the physical processor's current/max frequency. */
#define HV_CPU_MIDR UINT64_C(0x414fd0b1)
#define HV_CPU_MODEL_NAME "Arm Cortex-A76 r4p1 (virtual)"
#define HV_CPU_MANUFACTURER "Arm"
#define HV_CPU_FDT_COMPATIBLE "arm,cortex-a76"
#define HV_CPU_COUNTER_HZ UINT64_C(24000000)
#define HV_CPU_PMCCNTR_SCALE UINT64_C(128)
#define HV_CPU_NOMINAL_CLOCK_MHZ ((HV_CPU_COUNTER_HZ * HV_CPU_PMCCNTR_SCALE) / UINT64_C(1000000))

#endif
