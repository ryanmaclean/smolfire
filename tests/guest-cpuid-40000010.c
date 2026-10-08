/* SPDX-License-Identifier: Apache-2.0 */
/* Branch-only diagnostic: run after READY in the guest; never a product dependency. */
#include <stdint.h>
#include <stdio.h>

static void
read_cpuid(uint32_t leaf, uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
    uint32_t *edx)
{
    uint32_t a, b, c, d;

    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d)
        : "a"(leaf), "c"(0));
    *eax = a;
    *ebx = b;
    *ecx = c;
    *edx = d;
}

int
main(void)
{
    uint32_t max_leaf, ebx, ecx, edx;
    uint32_t tsc_khz = 0, lapic_khz = 0, reserved_ecx = 0, reserved_edx = 0;

    read_cpuid(0x40000000u, &max_leaf, &ebx, &ecx, &edx);
    if (max_leaf >= 0x40000010u) {
        read_cpuid(0x40000010u, &tsc_khz, &lapic_khz, &reserved_ecx,
            &reserved_edx);
    }
    printf("CPUID_40000010 max=%u eax=%u ebx=%u ecx=%u edx=%u\n",
        max_leaf, tsc_khz, lapic_khz, reserved_ecx, reserved_edx);
    return 0;
}
