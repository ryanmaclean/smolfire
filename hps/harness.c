/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * harness.c -- HPS-side stimulus / fault-injection skeleton for
 * durable_tid_v0 (issue #87, v0). Target: Cyclone V HPS (ARM Cortex-A9)
 * Linux on the MiSTer / SuperStation One path; talks to OUR peripheral
 * region through /dev/mem mmap of the lwhps2fpga window.
 *
 * STATUS: SKELETON -- NOT built, NOT run. No cross toolchain, no device
 * access, and no Quartus host exist yet (see rtl/README.md owner asks).
 * Offsets below mirror rtl/durable_tid_v0.sv (+0x000..+0x058); the absolute
 * peripheral BASE must be filled in after the Qsys build assigns it.
 *
 * SAFETY: the offset-gated helpers REFUSE any address inside the
 * 0xFF200000 bridge-control window (write-bricks-FPGA). All DUT work stays
 * inside OUR 4 KB peripheral region. Gaming SD (/media/fat) is untouched.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* ---- bridge / region layout (fill in BASE after Qsys build) ---- */
#define LWHPS2FPGA_BASE   0xFF400000u   /* lightweight bridge window base */
#define DUT_REGION_OFFSET 0x00000000u   /* TBD: OUR peripheral offset in window */
#define DUT_REGION_SPAN   0x00001000u   /* 4 KB */

/* Bridge-control window that must NEVER be mapped or written. */
#define BRIDGE_CTRL_BASE  0xFF200000u
#define BRIDGE_CTRL_SPAN  0x00001000u

/* Register offsets (byte offsets from OUR peripheral base). */
#define R_EPOCH     0x000
#define R_REQ_LO    0x004
#define R_PEND_LO   0x008
#define R_DUR_LO    0x00C
#define R_VIS_LO    0x010
#define R_FSM       0x014
#define R_ERROR     0x018
#define R_PROG      0x01C
#define R_RSTCNT    0x020
#define R_CTRL      0x024
#define R_STATUS    0x028
#define R_DESC0     0x02C
#define R_DESC1     0x030
#define R_DESC_CRC  0x034
#define R_CRC_CALC  0x038
#define R_TID_LO    0x03C
#define R_TID_HI    0x040
#define R_REQ_HI    0x044
#define R_DUR_HI    0x048
#define R_VIS_HI    0x04C
#define R_PEND_HI   0x050
#define R_MAGIC     0x054
#define R_VERSION   0x058

#define CTRL_SUBMIT  0x00000001u
#define CTRL_SOFTRST 0x00000002u
#define CTRL_RECOVER 0x00000004u

#define ST_BUSY      0x00000001u
#define ST_COMPLETE  0x00000002u
#define ST_CRC_OK    0x00000004u

#define ERR_CRC      (1u << 0)
#define ERR_DUP      (1u << 1)
#define ERR_GAP      (1u << 2)
#define ERR_MALF     (1u << 3)
#define ERR_RSTMID   (1u << 4)
#define ERR_OVF      (1u << 5)

static volatile uint32_t *g_regs = NULL;

/* CRC-32/IEEE (independent software implementation: the differential
 * oracle cross-checks DUT CRC_CALC against THIS, not against RTL). */
static uint32_t sw_crc32(const uint8_t *buf, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    size_t i;
    int b;
    for (i = 0; i < len; i++) {
        crc ^= buf[i];
        for (b = 0; b < 8; b++)
            crc = (crc & 1u) ? (crc >> 1) ^ 0xEDB88320u : (crc >> 1);
    }
    return ~crc;
}

/* Descriptor image: {EPOCH, REQ_LO, DESC1, DESC0} little-endian. */
static uint32_t desc_crc(uint32_t d0, uint32_t d1, uint32_t req,
                         uint32_t epoch)
{
    uint8_t b[16];
    memcpy(b + 0, &d0, 4);
    memcpy(b + 4, &d1, 4);
    memcpy(b + 8, &req, 4);
    memcpy(b + 12, &epoch, 4);
    return sw_crc32(b, sizeof b);
}

/* Offset-gated MMIO: refuse anything outside OUR 4 KB region, and refuse
 * the bridge-control window even if the caller computes a bad address. */
static int gated_ok(uint32_t off)
{
    if (off >= DUT_REGION_SPAN) {
        fprintf(stderr, "harness: offset 0x%x outside DUT region\n", off);
        return 0;
    }
    {
        /* Defence in depth: absolute-address paranoia. */
        uintptr_t abs = (uintptr_t)(LWHPS2FPGA_BASE + DUT_REGION_OFFSET + off);
        if (abs >= BRIDGE_CTRL_BASE &&
            abs < BRIDGE_CTRL_BASE + BRIDGE_CTRL_SPAN) {
            fprintf(stderr, "harness: REFUSED bridge-control address\n");
            return 0;
        }
    }
    return 1;
}

static uint32_t mm_read(uint32_t off)
{
    if (!gated_ok(off))
        exit(1);
    return g_regs[off >> 2];
}

static void mm_write(uint32_t off, uint32_t val)
{
    if (!gated_ok(off))
        exit(1);
    g_regs[off >> 2] = val;
}

static uint64_t read_durable(void)
{
    uint64_t lo = mm_read(R_DUR_LO), hi = mm_read(R_DUR_HI);
    return (hi << 32) | lo;
}

static uint64_t read_visible(void)
{
    uint64_t lo = mm_read(R_VIS_LO), hi = mm_read(R_VIS_HI);
    return (hi << 32) | lo;
}

static int wait_idle(int timeout_ms)
{
    while (timeout_ms-- > 0) {
        if (!(mm_read(R_STATUS) & ST_BUSY))
            return 0;
        usleep(1000);
    }
    return -1;
}

/* Submit one descriptor; returns 0 on commit, nonzero DUT error bits. */
static uint32_t submit_desc(uint32_t req, uint32_t d0, uint32_t d1,
                            uint32_t epoch, int corrupt_crc)
{
    uint32_t crc = desc_crc(d0, d1, req, epoch);
    if (corrupt_crc)
        crc = ~crc;
    mm_write(R_DESC0, d0);
    mm_write(R_DESC1, d1);
    mm_write(R_REQ_LO, req);
    mm_write(R_REQ_HI, 0);
    mm_write(R_DESC_CRC, crc);
    mm_write(R_CTRL, CTRL_SUBMIT);
    if (wait_idle(1000) != 0) {
        fprintf(stderr, "harness: submit %u timed out (busy stuck)\n", req);
        return 0x80000000u;
    }
    return mm_read(R_ERROR);
}

/* Fault-injection routines (each: setup, inject, observe, report). */
static uint32_t fault_duplicate(uint32_t committed_seq, uint32_t epoch)
{
    /* Re-drive an already-durable seq: expect ERR_DUP, watermark held. */
    return submit_desc(committed_seq, 0xA0A0A0A0u, 0xB0B0B0B0u, epoch, 0);
}

static uint32_t fault_replay(uint32_t old_seq, uint32_t epoch)
{
    return submit_desc(old_seq, 0xC0C0C0C0u, 0xD0D0D0D0u, epoch, 0);
}

static uint32_t fault_malformed_crc(uint32_t req, uint32_t epoch)
{
    return submit_desc(req, 0x11111111u, 0x22222222u, epoch, 1);
}

static uint32_t fault_malformed_ctrl(void)
{
    mm_write(R_CTRL, 0xFFFFFFF8u); /* reserved bits -> ERR_MALF */
    return mm_read(R_ERROR);
}

static uint32_t fault_queue_full(uint32_t req, uint32_t epoch)
{
    /* v0 has no queue: two back-to-back submits; second must be rejected
     * with ERR_MALF while the first commits normally. */
    uint32_t crc = desc_crc(0xAAAAAAAAu, 0x55555555u, req, epoch);
    mm_write(R_DESC0, 0xAAAAAAAAu);
    mm_write(R_DESC1, 0x55555555u);
    mm_write(R_REQ_LO, req);
    mm_write(R_REQ_HI, 0);
    mm_write(R_DESC_CRC, crc);
    mm_write(R_CTRL, CTRL_SUBMIT);
    mm_write(R_CTRL, CTRL_SUBMIT); /* arrives while busy/pending */
    if (wait_idle(1000) != 0)
        return 0x80000000u;
    return mm_read(R_ERROR);
}

static uint32_t fault_reset_midcommit(uint32_t req, uint32_t epoch)
{
    /* Best-effort 1-cycle reset during COMMIT (narrow window: COMMIT
     * latency is 2 fabric cycles; HPS MMIO timing is coarse, so this may
     * land in SUBMIT/COMPLETE instead -- the RTL testbench covers the
     * exact-cycle case deterministically). */
    uint32_t crc = desc_crc(0xDEAD0000u | req, 0xBEEF0000u | req, req, epoch);
    mm_write(R_DESC0, 0xDEAD0000u | req);
    mm_write(R_DESC1, 0xBEEF0000u | req);
    mm_write(R_REQ_LO, req);
    mm_write(R_REQ_HI, 0);
    mm_write(R_DESC_CRC, crc);
    mm_write(R_CTRL, CTRL_SUBMIT);
    mm_write(R_CTRL, CTRL_SOFTRST);
    if (wait_idle(1000) != 0)
        return 0x80000000u;
    return mm_read(R_ERROR);
}

/* Recovery consistency: after a harness restart (fresh mmap, no reset
 * issued), durable/visible must read back monotonic and equal the last
 * values the oracle saw. Returns 0 on consistent. */
static int recovery_consistency(uint64_t oracle_durable, uint64_t oracle_visible)
{
    uint64_t d = read_durable(), v = read_visible();
    if (d != oracle_durable || v != oracle_visible) {
        fprintf(stderr,
                "harness: RECOVERY DIVERGENCE dut(d=%llu,v=%llu) oracle(d=%llu,v=%llu)\n",
                (unsigned long long)d, (unsigned long long)v,
                (unsigned long long)oracle_durable,
                (unsigned long long)oracle_visible);
        return -1;
    }
    return 0;
}

/*
 * Differential-compare hook vs the SS1-A software oracle.
 * The oracle (outside this file) replays the same submitted sequence and
 * tracks software.last_tid; after every batch this hook asserts
 * software.last_tid == fpga.last_tid with matching TID/payload per record.
 * STUB: returns 0. Wired to the real oracle when the validation ladder
 * (MISTER-DUT-PLAN section 6) runs.
 */
static int oracle_compare(uint64_t sw_last_tid, uint64_t fpga_last_tid)
{
    (void)sw_last_tid;
    (void)fpga_last_tid;
    /* TODO: per-record TID/payload/hash match + monotonicity assertions. */
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s <smoke|fault|recover> [args...]\n"
            "  smoke   N        submit N good descriptors, compare vs oracle\n"
            "  fault   <vector> duplicate|replay|badcrc|badctrl|full|rstmid\n"
            "  recover <d> <v>  check durable/visible equal oracle d/v\n",
            argv0);
}

int main(int argc, char **argv)
{
    int fd;
    off_t map_base;
    void *map;
    uint32_t epoch = 1;

    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    /* NOT built, NOT run: everything below is a skeleton for bring-up. */
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("harness: open /dev/mem");
        return 1;
    }
    map_base = (off_t)(LWHPS2FPGA_BASE + DUT_REGION_OFFSET);
    map = mmap(NULL, DUT_REGION_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED,
               fd, map_base);
    if (map == MAP_FAILED) {
        perror("harness: mmap");
        return 1;
    }
    g_regs = (volatile uint32_t *)map;

    if (mm_read(R_MAGIC) != 0x44555230u) {
        fprintf(stderr, "harness: MAGIC mismatch (no DUT at region?)\n");
        return 1;
    }

    if (strcmp(argv[1], "smoke") == 0) {
        long n = (argc > 2) ? atol(argv[2]) : 1000;
        uint64_t sw_tid = 0;
        long i;
        mm_write(R_EPOCH, epoch);
        for (i = 0; i < n; i++) {
            uint32_t err = submit_desc((uint32_t)sw_tid, 0xA0000000u | (uint32_t)i,
                                       0xB0000000u | (uint32_t)i, epoch, 0);
            if (err != 0) {
                fprintf(stderr, "harness: op %ld error bits 0x%x\n", i, err);
                mm_write(R_ERROR, 0x3Fu);
                return 1;
            }
            sw_tid++;
            if (oracle_compare(sw_tid, read_durable()) != 0)
                return 1;
        }
        printf("harness: smoke OK n=%ld durable=%llu visible=%llu\n", n,
               (unsigned long long)read_durable(),
               (unsigned long long)read_visible());
    } else if (strcmp(argv[1], "fault") == 0) {
        const char *vec = (argc > 2) ? argv[2] : "";
        uint64_t d0 = read_durable();
        uint32_t err = 0;
        mm_write(R_EPOCH, epoch);
        if (strcmp(vec, "duplicate") == 0)
            err = fault_duplicate((uint32_t)(d0 > 0 ? d0 - 1 : 0), epoch);
        else if (strcmp(vec, "replay") == 0)
            err = fault_replay((uint32_t)(d0 > 2 ? d0 - 3 : 0), epoch);
        else if (strcmp(vec, "badcrc") == 0)
            err = fault_malformed_crc((uint32_t)d0, epoch);
        else if (strcmp(vec, "badctrl") == 0)
            err = fault_malformed_ctrl();
        else if (strcmp(vec, "full") == 0)
            err = fault_queue_full((uint32_t)d0, epoch);
        else if (strcmp(vec, "rstmid") == 0)
            err = fault_reset_midcommit((uint32_t)d0, epoch);
        else {
            usage(argv[0]);
            return 2;
        }
        printf("harness: fault %s -> error bits 0x%x durable=%llu (was %llu)\n",
               vec, err, (unsigned long long)read_durable(),
               (unsigned long long)d0);
        mm_write(R_ERROR, 0x3Fu);
    } else if (strcmp(argv[1], "recover") == 0) {
        uint64_t d, v;
        if (argc < 4) {
            usage(argv[0]);
            return 2;
        }
        d = strtoull(argv[2], NULL, 0);
        v = strtoull(argv[3], NULL, 0);
        if (recovery_consistency(d, v) != 0)
            return 1;
        printf("harness: recovery consistent d=%llu v=%llu\n",
               (unsigned long long)d, (unsigned long long)v);
    } else {
        usage(argv[0]);
        return 2;
    }
    return 0;
}
