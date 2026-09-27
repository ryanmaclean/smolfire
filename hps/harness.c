/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * harness.c -- host-side UART stimulus / differential harness for
 * durable_tid_v0 (issue #87, v0) over the Tang Console single-submit
 * serial protocol (`/dev/ttyUSB1` @115200-8-N-1; spec in rtl/README.md,
 * register map in rtl/durable_tid_v0.v header).
 *
 * HOST-PORTABLE: plain POSIX + termios only (Linux + macOS). No
 * ARM-specific code, no /dev/mem, no system-path installs. The old
 * /dev/mem MMIO skeleton is fully retired: the owner ruled the real
 * harness is C(termios), and the DUT busy window (~6 fabric cycles) is
 * unreachable over serial by construction, so reset-mid-commit and
 * submit-while-busy stay parallel-testbench-only windows.
 *
 * Build (both hosts):  cc -O2 -Wall -Wextra -o /tmp/harness hps/harness.c
 *
 *   ./harness ping              PING round trip (expect PONG + VERSION 0)
 *   ./harness magic             read MAGIC + VERSION identity registers
 *   ./harness read  <addr>      READ-REG one round trip
 *   ./harness write <addr> <v>  WRITE-REG one round trip (echo-checked)
 *   ./harness reset             RESET round trip (counter++, history kept)
 *   ./harness smoke <N>         N good submits, oracle-checked vs model
 *   ./harness diff  <N> [seed]  seeded differential mix:
 *                               good/dup/gap/malformed(DUT-level)/reads
 *                               FIRST mismatch stops, dumps transcript.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/time.h>

/* ---- transport ---- */
#define UART_PATH "/dev/ttyUSB1" /* BL616 debugger UART on the Tang Console */
#define UART_BAUD B115200

/* ---- protocol (must match rtl/dut_uart.v) ---- */
#define M_MAGIC0 0x44u
#define M_MAGIC1 0x55u

#define CMD_WRITE 0x01u
#define CMD_READ  0x02u
#define CMD_RESET 0x03u
#define CMD_PING  0x04u

#define RSP_WRITE 0x81u
#define RSP_READ  0x82u
#define RSP_RESET 0x83u
#define RSP_PING  0x84u

/* ---- DUT byte offsets (must match rtl/durable_tid_v0.v header) ---- */
#define R_EPOCH    0x00u
#define R_REQ_LO   0x04u
#define R_DUR_LO   0x0Cu
#define R_VIS_LO   0x10u
#define R_ERROR    0x18u
#define R_PROG     0x1Cu
#define R_RSTCNT   0x20u
#define R_CTRL     0x24u
#define R_STATUS   0x28u
#define R_DESC0    0x2Cu
#define R_DESC1    0x30u
#define R_DESC_CRC 0x34u
#define R_TID_LO   0x3Cu
#define R_REQ_HI   0x44u
#define R_DUR_HI   0x48u
#define R_VIS_HI   0x4Cu
#define R_MAGIC    0x54u
#define R_VERSION  0x58u

#define CTRL_SUBMIT 0x00000001u

#define ST_BUSY   0x00000001u
#define ST_CRC_OK 0x00000004u

#define ERR_CRC   (1u << 0)
#define ERR_DUP   (1u << 1)
#define ERR_GAP   (1u << 2)
#define ERR_MALF  (1u << 3)
#define ERR_RSTMID (1u << 4)
#define ERR_OVF   (1u << 5)
#define ERR_ALL   0x3Fu

#define RSP_TIMEOUT_MS 1000u
#define SILENCE_MS 400u

static int g_fd = -1;

/* ---- CRC-32/IEEE (independent software implementation: the oracle
 * cross-checks DUT CRC behavior against THIS, not against RTL) ---- */
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

/* Descriptor image: {DESC0, DESC1, REQ_LO, EPOCH} little-endian, i.e. byte0
 * = DESC0[7:0]. Matches the DUT {EPOCH,REQ_LO,DESC1,DESC0} word order with
 * LSB-first byte order inside each word (see dut_uart_tb.sv tb_crc32). */
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

/* ---- time ---- */
static uint64_t now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000u + (uint64_t)tv.tv_usec / 1000u;
}

/* ---- UART open/config: 115200-8-N-1, raw, nonblocking-ish reads ---- */
static int uart_open(const char *path)
{
    struct termios tio;
    int fd = open(path, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        fprintf(stderr, "harness: open %s: %s\n", path, strerror(errno));
        return -1;
    }
    memset(&tio, 0, sizeof tio);
    tio.c_cflag = CS8 | CLOCAL | CREAD;
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 1; /* 100 ms read quantum; deadline loop below */
    if (cfsetispeed(&tio, UART_BAUD) != 0 ||
        cfsetospeed(&tio, UART_BAUD) != 0) {
        fprintf(stderr, "harness: cfsetspeed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    if (tcsetattr(fd, TCSANOW, &tio) != 0) {
        fprintf(stderr, "harness: tcsetattr %s: %s\n", path,
                strerror(errno));
        close(fd);
        return -1;
    }
    tcflush(fd, TCIOFLUSH);
    g_fd = fd;
    return 0;
}

/* ---- frame TX/RX with checksum ---- */
static int write_all(const uint8_t *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(g_fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "harness: uart write: %s\n",
                    strerror(errno));
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/* Strict request-response: exactly one RSP per well-formed CMD. Flush RX
 * before each CMD so a stale byte can never glue onto a fresh frame. */
static int cmd_frame(uint8_t cmd, uint8_t addr, uint32_t data)
{
    uint8_t f[9];
    f[0] = M_MAGIC0;
    f[1] = M_MAGIC1;
    f[2] = cmd;
    f[3] = addr;
    f[4] = (uint8_t)(data & 0xFFu);
    f[5] = (uint8_t)((data >> 8) & 0xFFu);
    f[6] = (uint8_t)((data >> 16) & 0xFFu);
    f[7] = (uint8_t)((data >> 24) & 0xFFu);
    f[8] = (uint8_t)(cmd + addr + f[4] + f[5] + f[6] + f[7]);
    tcflush(g_fd, TCIFLUSH);
    return write_all(f, sizeof f);
}

/* Returns 0 on a fully validated RSP, -1 on timeout/short read, -2 on
 * framing (magic) failure, -3 on checksum failure, -4 on wrong RSP code. */
static int rsp_frame(uint8_t want, uint32_t *data, unsigned timeout_ms)
{
    uint8_t f[8];
    uint8_t sum;
    size_t got = 0;
    uint64_t deadline = now_ms() + timeout_ms;
    while (got < sizeof f) {
        ssize_t n = read(g_fd, f + got, sizeof f - got);
        if (n > 0) {
            got += (size_t)n;
            continue;
        }
        if (n < 0 && errno != EINTR && errno != EAGAIN) {
            fprintf(stderr, "harness: uart read: %s\n",
                    strerror(errno));
            return -1;
        }
        if (now_ms() >= deadline)
            break;
        usleep(1000);
    }
    if (got != sizeof f)
        return -1;
    if (f[0] != M_MAGIC0 || f[1] != M_MAGIC1)
        return -2;
    sum = (uint8_t)(f[2] + f[3] + f[4] + f[5] + f[6]);
    if (sum != f[7])
        return -3;
    if (f[2] != want)
        return -4;
    *data = (uint32_t)f[3] | ((uint32_t)f[4] << 8) |
            ((uint32_t)f[5] << 16) | ((uint32_t)f[6] << 24);
    return 0;
}

/* ---- commands PING/WRITE/READ/RESET ---- */
static int u_write(uint8_t addr, uint32_t val)
{
    uint32_t echo = 0;
    if (cmd_frame(CMD_WRITE, addr, val) != 0)
        return -1;
    if (rsp_frame(RSP_WRITE, &echo, RSP_TIMEOUT_MS) != 0)
        return -1;
    return (echo == val) ? 0 : -1;
}

static int u_read(uint8_t addr, uint32_t *val)
{
    if (cmd_frame(CMD_READ, addr, 0) != 0)
        return -1;
    return rsp_frame(RSP_READ, val, RSP_TIMEOUT_MS);
}

static int u_ping(uint32_t *ver)
{
    if (cmd_frame(CMD_PING, 0, 0) != 0)
        return -1;
    if (rsp_frame(RSP_PING, ver, RSP_TIMEOUT_MS) != 0)
        return -1;
    return (*ver == 0) ? 0 : -1;
}

static int u_reset(uint32_t *rcnt)
{
    if (cmd_frame(CMD_RESET, 0, 0) != 0)
        return -1;
    return rsp_frame(RSP_RESET, rcnt, RSP_TIMEOUT_MS);
}

/* ---- register-level helpers over the serial path ---- */
static int wait_idle(unsigned max_polls)
{
    unsigned i;
    for (i = 0; i < max_polls; i++) {
        uint32_t st = 0;
        if (u_read(R_STATUS, &st) != 0)
            return -1;
        if (!(st & ST_BUSY))
            return 0;
    }
    return -1;
}

static int read_durable(uint64_t *d)
{
    uint32_t lo = 0, hi = 0;
    if (u_read(R_DUR_LO, &lo) != 0)
        return -1;
    if (u_read(R_DUR_HI, &hi) != 0)
        return -1;
    *d = ((uint64_t)hi << 32) | lo;
    return 0;
}

static int read_visible(uint64_t *v)
{
    uint32_t lo = 0, hi = 0;
    if (u_read(R_VIS_LO, &lo) != 0)
        return -1;
    if (u_read(R_VIS_HI, &hi) != 0)
        return -1;
    *v = ((uint64_t)hi << 32) | lo;
    return 0;
}

static int clear_errors(void)
{
    uint32_t e = 0;
    if (u_write(R_ERROR, ERR_ALL) != 0) /* rw1c: clear defined bits */
        return -1;
    if (u_read(R_ERROR, &e) != 0)
        return -1;
    return (e == 0) ? 0 : -1;
}

/* Submit one descriptor for sequence req under epoch; returns 0 once the
 * DUT is idle again (commit OR clean reject -- caller checks ERROR). */
static int submit_desc(uint32_t req, uint32_t d0, uint32_t d1,
                       uint32_t epoch, int corrupt_crc)
{
    uint32_t crc = desc_crc(d0, d1, req, epoch);
    if (corrupt_crc)
        crc = ~crc;
    if (u_write(R_DESC0, d0) != 0)
        return -1;
    if (u_write(R_DESC1, d1) != 0)
        return -1;
    if (u_write(R_REQ_LO, req) != 0)
        return -1;
    if (u_write(R_REQ_HI, 0) != 0)
        return -1;
    if (u_write(R_DESC_CRC, crc) != 0)
        return -1;
    if (u_write(R_CTRL, CTRL_SUBMIT) != 0)
        return -1;
    return wait_idle(30);
}

/*
 * Differential-compare hook vs the software model. The model replays the
 * same submitted sequence and tracks software watermarks; after every op
 * this asserts software == FPGA with matching durable/visible counts.
 * Returns 0 on match, nonzero with a diagnostic on divergence.
 */
static int oracle_compare(uint64_t sw_durable, uint64_t fpga_durable,
                          uint64_t sw_visible, uint64_t fpga_visible)
{
    if (sw_durable != fpga_durable || sw_visible != fpga_visible) {
        fprintf(stderr,
                "harness: ORACLE DIVERGENCE sw(d=%llu,v=%llu)"
                " fpga(d=%llu,v=%llu)\n",
                (unsigned long long)sw_durable,
                (unsigned long long)sw_visible,
                (unsigned long long)fpga_durable,
                (unsigned long long)fpga_visible);
        return -1;
    }
    return 0;
}

/* ---- seeded PRNG (xorshift32: deterministic across Linux/macOS) ---- */
static uint32_t rng_state = 0x9E3779B9u;
static uint32_t rng_next(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

/* ---- mismatch transcript (last TR_N ops, dumped on FIRST mismatch) ---- */
#define TR_N 32
#define TR_SZ 192
static char tr_ring[TR_N][TR_SZ];
static unsigned tr_pos = 0;
static unsigned tr_count = 0;

static void tr_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tr_ring[tr_pos % TR_N], TR_SZ, fmt, ap);
    va_end(ap);
    tr_pos++;
    tr_count++;
}

static void tr_dump(void)
{
    unsigned n = (tr_count < TR_N) ? tr_count : TR_N;
    unsigned i, start = tr_count - n;
    fprintf(stderr, "harness: --- transcript (last %u ops) ---\n", n);
    for (i = 0; i < n; i++)
        fprintf(stderr, "harness: [%u] %s\n", start + i,
                tr_ring[(start + i) % TR_N]);
    fprintf(stderr, "harness: --- end transcript ---\n");
}

/* ---- sanity: PING + MAGIC/VERSION + silent-drop link check ---- */
static int sanity(void)
{
    uint32_t v = 0, m = 0, v2 = 0, dummy = 0;
    uint8_t bad[9];
    int rc;
    if (u_ping(&v) != 0) {
        fprintf(stderr, "harness: sanity: PING failed\n");
        return -1;
    }
    printf("harness: ping ok (PONG version=%u)\n", v);
    if (u_read(R_MAGIC, &m) != 0 || m != 0x44555230u) {
        fprintf(stderr, "harness: sanity: MAGIC mismatch 0x%08x\n", m);
        return -1;
    }
    if (u_read(R_VERSION, &v2) != 0 || v2 != 0) {
        fprintf(stderr, "harness: sanity: VERSION mismatch 0x%08x\n", v2);
        return -1;
    }
    printf("harness: magic DUR0 + version v0 ok\n");
    /* UART-level malformed frame (bad checksum) must get NO response;
     * then the link must still be alive (TB U6 analogue). */
    bad[0] = M_MAGIC0;
    bad[1] = M_MAGIC1;
    bad[2] = CMD_READ;
    bad[3] = R_DUR_LO;
    bad[4] = bad[5] = bad[6] = bad[7] = 0;
    bad[8] = 0xFFu; /* wrong CHK */
    tcflush(g_fd, TCIFLUSH);
    if (write_all(bad, sizeof bad) != 0)
        return -1;
    rc = rsp_frame(RSP_READ, &dummy, SILENCE_MS);
    if (rc == 0) {
        fprintf(stderr,
                "harness: sanity: bad-checksum frame got a response\n");
        return -1;
    }
    printf("harness: bad-checksum frame silently dropped (rc=%d)\n", rc);
    if (u_ping(&v) != 0) {
        fprintf(stderr, "harness: sanity: link dead after rejection\n");
        return -1;
    }
    printf("harness: link alive after rejection\n");
    return 0;
}

/* ---- differential op vectors (each returns 0 or fails the run) ---- */
static uint32_t g_epoch = 1;

static int vec_good(uint64_t *next, unsigned opno)
{
    uint32_t req = (uint32_t)*next;
    uint32_t d0 = 0xA0000000u | (req & 0x0FFFFFFFu);
    uint32_t d1 = 0xB0000000u | (req & 0x0FFFFFFFu);
    uint32_t err = 0, st = 0;
    uint64_t d = 0, v = 0;
    if (submit_desc(req, d0, d1, g_epoch, 0) != 0) {
        tr_log("op %u GOOD req=%u: submit round trip failed", opno, req);
        return -1;
    }
    if (u_read(R_ERROR, &err) != 0 || err != 0) {
        tr_log("op %u GOOD req=%u: ERROR=0x%x, want 0x0", opno, req, err);
        return -1;
    }
    if (u_read(R_STATUS, &st) != 0 || !(st & ST_CRC_OK)) {
        tr_log("op %u GOOD req=%u: crc_ok_last clear (st=0x%x)", opno, req,
               st);
        return -1;
    }
    if (read_durable(&d) != 0 || read_visible(&v) != 0)
        return -1;
    (*next)++;
    if (oracle_compare(*next, d, *next, v) != 0) {
        tr_log("op %u GOOD req=%u: oracle vs d=%llu v=%llu", opno, req,
               (unsigned long long)d, (unsigned long long)v);
        return -1;
    }
    tr_log("op %u GOOD req=%u d=%llu", opno, req,
           (unsigned long long)d);
    return 0;
}

static int vec_dup(uint64_t base, uint64_t next, unsigned opno)
{
    uint32_t req;
    uint32_t err = 0;
    uint64_t d = 0;
    if (next == base)
        return vec_good(&next, opno) == 0 ? 1 : -1; /* no history: do good */
    req = (uint32_t)(base + (rng_next() % (uint32_t)(next - base)));
    if (submit_desc(req, 0xA0A0A0A0u, 0xB0B0B0B0u, g_epoch, 0) != 0) {
        tr_log("op %u DUP req=%u: submit round trip failed", opno, req);
        return -1;
    }
    if (u_read(R_ERROR, &err) != 0 || err != ERR_DUP) {
        tr_log("op %u DUP req=%u: ERROR=0x%x, want DUP", opno, req, err);
        return -1;
    }
    if (read_durable(&d) != 0 || d != next) {
        tr_log("op %u DUP req=%u: durable moved to %llu", opno, req,
               (unsigned long long)d);
        return -1;
    }
    tr_log("op %u DUP req=%u held d=%llu", opno, req,
           (unsigned long long)d);
    return (clear_errors() == 0) ? 0 : -1;
}

static int vec_gap(uint64_t next, unsigned opno)
{
    uint32_t req = (uint32_t)next + 1u + (rng_next() % 4u);
    uint32_t err = 0;
    uint64_t d = 0;
    if (submit_desc(req, 0xC0C0C0C0u, 0xD0D0D0D0u, g_epoch, 0) != 0) {
        tr_log("op %u GAP req=%u: submit round trip failed", opno, req);
        return -1;
    }
    if (u_read(R_ERROR, &err) != 0 || err != ERR_GAP) {
        tr_log("op %u GAP req=%u: ERROR=0x%x, want GAP", opno, req, err);
        return -1;
    }
    if (read_durable(&d) != 0 || d != next) {
        tr_log("op %u GAP req=%u: durable moved to %llu", opno, req,
               (unsigned long long)d);
        return -1;
    }
    tr_log("op %u GAP req=%u held d=%llu", opno, req,
           (unsigned long long)d);
    return (clear_errors() == 0) ? 0 : -1;
}

static int vec_malformed(uint64_t next, unsigned opno)
{
    uint32_t kind = rng_next() % 3u;
    uint32_t err = 0;
    uint64_t d = 0;
    if (kind == 0) { /* bad descriptor CRC */
        if (submit_desc((uint32_t)next, 0x11111111u, 0x22222222u, g_epoch,
                        1) != 0) {
            tr_log("op %u MALF-badcrc: submit failed", opno);
            return -1;
        }
        if (u_read(R_ERROR, &err) != 0 || err != ERR_CRC) {
            tr_log("op %u MALF-badcrc: ERROR=0x%x, want CRC", opno, err);
            return -1;
        }
    } else if (kind == 1) { /* reserved CTRL bits */
        if (u_write(R_CTRL, 0xFFFFFFF8u) != 0) {
            tr_log("op %u MALF-badctrl: write failed", opno);
            return -1;
        }
        if (u_read(R_ERROR, &err) != 0 || err != ERR_MALF) {
            tr_log("op %u MALF-badctrl: ERROR=0x%x, want MALF", opno,
                   err);
            return -1;
        }
    } else { /* REQ_HI mismatch */
        uint32_t req = (uint32_t)next;
        uint32_t crc = desc_crc(0x11111111u, 0x22222222u, req, g_epoch);
        if (u_write(R_REQ_LO, req) != 0 ||
            u_write(R_REQ_HI, 0xDEADBEEFu) != 0 ||
            u_write(R_DESC0, 0x11111111u) != 0 ||
            u_write(R_DESC1, 0x22222222u) != 0 ||
            u_write(R_DESC_CRC, crc) != 0 ||
            u_write(R_CTRL, CTRL_SUBMIT) != 0 || wait_idle(30) != 0) {
            tr_log("op %u MALF-reqhi: submit failed", opno);
            return -1;
        }
        if (u_write(R_REQ_HI, 0) != 0) { /* restore for later good ops */
            tr_log("op %u MALF-reqhi: REQ_HI restore failed", opno);
            return -1;
        }
        if (u_read(R_ERROR, &err) != 0 || err != ERR_MALF) {
            tr_log("op %u MALF-reqhi: ERROR=0x%x, want MALF", opno, err);
            return -1;
        }
    }
    if (read_durable(&d) != 0 || d != next) {
        tr_log("op %u MALF kind=%u: durable moved to %llu", opno, kind,
               (unsigned long long)d);
        return -1;
    }
    tr_log("op %u MALF kind=%u held d=%llu", opno, kind,
           (unsigned long long)d);
    return (clear_errors() == 0) ? 0 : -1;
}

static int vec_read(uint64_t next, unsigned opno)
{
    static const uint8_t addrs[] = {
        R_DUR_LO, R_DUR_HI, R_VIS_LO, R_VIS_HI, R_ERROR, R_STATUS, R_MAGIC,
        R_VERSION, R_PROG, R_TID_LO, R_RSTCNT
    };
    uint8_t a = addrs[rng_next() % (sizeof addrs)];
    uint32_t v = 0;
    if (u_read(a, &v) != 0) {
        tr_log("op %u READ 0x%02x: round trip failed", opno, a);
        return -1;
    }
    switch (a) {
    case R_DUR_LO:
        if (v != (uint32_t)next) {
            tr_log("op %u READ DUR_LO=0x%x want 0x%x", opno, v,
                   (uint32_t)next);
            return -1;
        }
        break;
    case R_VIS_LO:
        if (v != (uint32_t)next) {
            tr_log("op %u READ VIS_LO=0x%x want 0x%x", opno, v,
                   (uint32_t)next);
            return -1;
        }
        break;
    case R_MAGIC:
        if (v != 0x44555230u) {
            tr_log("op %u READ MAGIC=0x%x", opno, v);
            return -1;
        }
        break;
    case R_VERSION:
        if (v != 0) {
            tr_log("op %u READ VERSION=0x%x", opno, v);
            return -1;
        }
        break;
    default:
        break;
    }
    tr_log("op %u READ 0x%02x=0x%08x", opno, a, v);
    return 0;
}

/* ---- smoke: N good submits ---- */
static int run_smoke(unsigned long n)
{
    uint64_t next = 0, d = 0, v = 0;
    unsigned long i;
    uint64_t t0, t1;
    if (u_write(R_EPOCH, g_epoch) != 0 || clear_errors() != 0 ||
        read_durable(&next) != 0) {
        fprintf(stderr, "harness: smoke setup failed\n");
        return 1;
    }
    printf("harness: smoke base durable=%llu\n",
           (unsigned long long)next);
    t0 = now_ms();
    for (i = 0; i < n; i++) {
        if (vec_good(&next, (unsigned)i) != 0) {
            tr_dump();
            return 1;
        }
        if ((i + 1) % 500 == 0)
            printf("harness: smoke %lu/%lu (%.1f ops/s)\n", i + 1, n,
                   (1000.0 * (double)(i + 1)) /
                       (double)(now_ms() - t0 + 1));
    }
    t1 = now_ms();
    if (read_durable(&d) != 0 || read_visible(&v) != 0)
        return 1;
    printf("harness: smoke OK n=%lu durable=%llu visible=%llu %.1f ops/s\n",
           n, (unsigned long long)d, (unsigned long long)v,
           (1000.0 * (double)n) / (double)(t1 - t0 + 1));
    return (oracle_compare(next, d, next, v) == 0) ? 0 : 1;
}

/* ---- diff: seeded mix, FIRST mismatch stops ---- */
static int run_diff(unsigned long n, uint32_t seed)
{
    uint64_t base = 0, next = 0, d = 0, v = 0;
    uint32_t rc0 = 0, rc1 = 0;
    unsigned long i, c_good = 0, c_dup = 0, c_gap = 0, c_malf = 0,
                  c_read = 0;
    uint64_t t0, t1;
    rng_state = (seed != 0) ? seed : 0x9E3779B9u;
    if (u_write(R_EPOCH, g_epoch) != 0 || clear_errors() != 0 ||
        read_durable(&base) != 0 || read_visible(&v) != 0) {
        fprintf(stderr, "harness: diff setup failed\n");
        return 1;
    }
    next = base;
    /* RESET sanity inside the run: idle reset preserves history. */
    if (u_read(R_RSTCNT, &rc0) != 0 || u_reset(&rc1) != 0 ||
        rc1 != rc0 + 1) {
        fprintf(stderr, "harness: diff: RESET sanity failed\n");
        return 1;
    }
    if (read_durable(&d) != 0 || d != base) {
        fprintf(stderr, "harness: diff: RESET moved durable\n");
        return 1;
    }
    printf("harness: diff base d=%llu v=%llu reset %u->%u seed=%u\n",
           (unsigned long long)base, (unsigned long long)v, rc0, rc1,
           rng_state);
    t0 = now_ms();
    for (i = 0; i < n; i++) {
        uint32_t r = rng_next() % 100u;
        int rc = 0;
        if (r < 60) {
            rc = vec_good(&next, (unsigned)i);
            if (rc == 1) { /* dup-slot fallback consumed as good */
                c_good++;
                rc = 0;
            } else if (rc == 0) {
                c_good++;
            }
        } else if (r < 70) {
            rc = vec_dup(base, next, (unsigned)i);
            if (rc == 1) {
                c_good++;
                next++;
                rc = 0;
            } else if (rc == 0) {
                c_dup++;
            }
        } else if (r < 78) {
            rc = vec_gap(next, (unsigned)i);
            if (rc == 0)
                c_gap++;
        } else if (r < 88) {
            rc = vec_malformed(next, (unsigned)i);
            if (rc == 0)
                c_malf++;
        } else {
            rc = vec_read(next, (unsigned)i);
            if (rc == 0)
                c_read++;
        }
        if (rc != 0) {
            fprintf(stderr,
                    "harness: MISMATCH at op %lu (seed=%u base=%llu)\n",
                    i, rng_state, (unsigned long long)base);
            tr_dump();
            return 1;
        }
        if ((i + 1) % 500 == 0)
            printf("harness: diff %lu/%lu (%.1f ops/s)\n", i + 1, n,
                   (1000.0 * (double)(i + 1)) /
                       (double)(now_ms() - t0 + 1));
    }
    t1 = now_ms();
    if (read_durable(&d) != 0 || read_visible(&v) != 0)
        return 1;
    printf("harness: diff OK n=%lu seed=%u good=%lu dup=%lu gap=%lu"
           " malf=%lu read=%lu d=%llu v=%llu %.1f ops/s\n",
           n, seed, c_good, c_dup, c_gap, c_malf, c_read,
           (unsigned long long)d, (unsigned long long)v,
           (1000.0 * (double)n) / (double)(t1 - t0 + 1));
    return (oracle_compare(next, d, next, v) == 0) ? 0 : 1;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [-t tty] <ping|magic|read|write|reset|smoke|diff>"
            " [args...]\n"
            "  ping                  PING round trip (PONG + VERSION 0)\n"
            "  magic                 read MAGIC + VERSION\n"
            "  read  <addr>          READ-REG one round trip\n"
            "  write <addr> <val>    WRITE-REG one round trip (echo-checked)\n"
            "  reset                 RESET round trip\n"
            "  smoke <N>             N good submits, oracle-checked\n"
            "  diff  <N> [seed]      seeded differential mix (good/dup/gap/\n"
            "                        malformed/reads); FIRST mismatch stops\n"
            "  default tty: " UART_PATH " @115200-8-N-1\n",
            argv0);
}

int main(int argc, char **argv)
{
    const char *tty = UART_PATH;
    const char *cmd;
    int ai = 1;
    uint32_t val = 0;
    if (argc >= 4 && strcmp(argv[1], "-t") == 0) {
        tty = argv[2];
        ai = 3;
    }
    if (ai >= argc) {
        usage(argv[0]);
        return 2;
    }
    cmd = argv[ai];
    if (uart_open(tty) != 0)
        return 1;

    if (strcmp(cmd, "ping") == 0) {
        if (u_ping(&val) != 0) {
            fprintf(stderr, "harness: PING failed\n");
            return 1;
        }
        printf("harness: PONG version=%u\n", val);
    } else if (strcmp(cmd, "magic") == 0) {
        uint32_t m = 0, version = 0;
        if (u_read(R_MAGIC, &m) != 0 || u_read(R_VERSION, &version) != 0)
            return 1;
        printf("harness: MAGIC=0x%08x VERSION=0x%08x\n", m, version);
        if (m != 0x44555230u || version != 0)
            return 1;
    } else if (strcmp(cmd, "read") == 0) {
        uint32_t a;
        if (ai + 1 >= argc) {
            usage(argv[0]);
            return 2;
        }
        a = (uint32_t)strtoul(argv[ai + 1], NULL, 0);
        if (u_read((uint8_t)a, &val) != 0) {
            fprintf(stderr, "harness: READ 0x%x failed\n", a);
            return 1;
        }
        printf("harness: READ 0x%02x = 0x%08x\n", a & 0xFFu, val);
    } else if (strcmp(cmd, "write") == 0) {
        uint32_t a, w;
        if (ai + 2 >= argc) {
            usage(argv[0]);
            return 2;
        }
        a = (uint32_t)strtoul(argv[ai + 1], NULL, 0);
        w = (uint32_t)strtoul(argv[ai + 2], NULL, 0);
        if (u_write((uint8_t)a, w) != 0) {
            fprintf(stderr, "harness: WRITE 0x%x failed\n", a);
            return 1;
        }
        printf("harness: WRITE 0x%02x = 0x%08x acked\n", a & 0xFFu, w);
    } else if (strcmp(cmd, "reset") == 0) {
        if (u_reset(&val) != 0) {
            fprintf(stderr, "harness: RESET failed\n");
            return 1;
        }
        printf("harness: RESET-DONE reset_cnt=%u\n", val);
    } else if (strcmp(cmd, "smoke") == 0) {
        unsigned long n;
        if (ai + 1 >= argc) {
            usage(argv[0]);
            return 2;
        }
        if (sanity() != 0)
            return 1;
        n = strtoul(argv[ai + 1], NULL, 0);
        return run_smoke(n);
    } else if (strcmp(cmd, "diff") == 0) {
        unsigned long n;
        uint32_t seed = 0xC0FFEEu;
        if (ai + 1 >= argc) {
            usage(argv[0]);
            return 2;
        }
        if (ai + 2 < argc)
            seed = (uint32_t)strtoul(argv[ai + 2], NULL, 0);
        n = strtoul(argv[ai + 1], NULL, 0);
        if (sanity() != 0)
            return 1;
        return run_diff(n, seed);
    } else {
        usage(argv[0]);
        return 2;
    }
    return 0;
}
