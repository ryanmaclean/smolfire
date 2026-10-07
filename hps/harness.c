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
 *   ./harness ping              PING round trip (expect PONG + VERSION 1)
 *   ./harness magic             read MAGIC + VERSION identity registers
 *   ./harness read  <addr>      READ-REG one round trip
 *   ./harness write <addr> <v>  WRITE-REG one round trip (echo-checked)
 *   ./harness reset             RESET round trip (counter++, history kept)
 *   ./harness smoke <N>         N good submits, oracle-checked vs model
 *   ./harness diff  <N> [seed]  seeded differential mix:
 *                               good/dup/gap/invalid(DUT-level)/reads
 *                               FIRST mismatch stops, dumps transcript.
 *   Burst path (CMD 0x05 / RSP 0x85, spec in rtl/README.md + dut_uart.v):
 *   ./harness burst <N> [seed]  seeded burst differential: N total submits
 *                               in frames of randomized COUNT 1..64, entry
 *                               mix good/dup/gap/badcrc; per-entry result
 *                               bytes oracle-checked (CODE + no-cascade
 *                               continue), FIRST mismatch stops.
 *   ./harness burstmax          one COUNT=64 all-good max frame (1029 B CMD)
 *   ./harness burstdrop         one bad-checksum burst: silent drop, link
 *                               alive, watermark unmoved.
 *
 * Single-submit frames stay byte-identical (0x05 is the next free CMD;
 * RSP keeps the CMD|0x80 convention).
 *
 * Durability v1 (FPGA orders, host persists): [-l logpath] (default
 * ./durable.log) appends one COMMIT line per commit receipt and fsyncs
 * once per frame (group commit -- never per op inside a burst). Only the
 * post-fsync host_persisted watermark is durable; the fabric DURABLE
 * count is the ordered claim. Crash window: <=1 frame of
 * acked-but-unpersisted receipts on host crash (see block below).
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
#include <sys/stat.h>
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
#define CMD_BURST 0x05u

#define RSP_WRITE 0x81u
#define RSP_READ  0x82u
#define RSP_RESET 0x83u
#define RSP_PING  0x84u
#define RSP_BURST 0x85u

#define BURST_MAX_N 64u

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
#define PROTOCOL_VERSION 1u /* caller-supplied TID ABI; reject old hardware */

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

/* ---- host-anchored durability v1 (FPGA orders, host persists) ----
 *
 * Architecture: the fabric only ORDERS acceptance (DURABLE_LO/HI registers
 * report the ordered count -- ordered-until-host-persisted, NOT crash-safe
 * on its own). Crash safety is anchored on the HOST: after each frame that
 * carries commit receipts, the harness appends one COMMIT line per
 * committed receipt to the host log and fsyncs ONCE per frame (group
 * commit -- never per op inside a burst). Only the post-fsync watermark
 * `host_persisted` is exposed as durable in outputs; the fabric claim is
 * reported separately as `fpga_ordered` and must never be read as durable.
 *
 * CRASH WINDOW: a host crash between the fabric ACK and the frame fsync
 * loses at most ONE frame of acknowledged-but-unpersisted receipts.
 * Recovery re-drives from host_persisted; reqs the fabric already ordered
 * come back as DUP rejects (window check precedes CRC, no side effect), so
 * re-drive cannot double-apply -- but the host must still compare any
 * re-driven payload against the log before re-acknowledging it to the
 * application (this DUT cannot compare retry payloads itself).
 *
 * Single-submit ops are one-entry frames, so they fsync per submit; burst
 * frames fsync once for all N entries.
 */
static const char *g_logpath = "./durable.log";
static int g_logfd = -1;
static uint64_t g_fpga_ordered = 0; /* fabric claim: NEVER durable */
static uint64_t g_host_persisted = 0; /* post-fsync: the only durable value */
static unsigned long g_log_receipts = 0; /* COMMIT lines recovered at open */

/* Open (or create) the host durability log and recover host_persisted as
 * the max persisted watermark found. Prints the recovery line so a
 * restart-and-resume is auditable. Returns 0 on success, -1 on failure. */
static int durable_log_open(void)
{
    int rfd;
    struct stat st;
    if (g_logfd >= 0)
        return 0;
    g_logfd = open(g_logpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_logfd < 0) {
        fprintf(stderr, "harness: open durable log %s: %s\n", g_logpath,
                strerror(errno));
        return -1;
    }
    rfd = open(g_logpath, O_RDONLY);
    if (rfd < 0) {
        fprintf(stderr, "harness: reopen durable log %s: %s\n", g_logpath,
                strerror(errno));
        return -1;
    }
    if (fstat(rfd, &st) != 0) {
        fprintf(stderr, "harness: fstat durable log %s: %s\n", g_logpath,
                strerror(errno));
        close(rfd);
        return -1;
    }
    if (st.st_size > 0) {
        char *buf;
        size_t got = 0;
        buf = (char *)malloc((size_t)st.st_size + 1u);
        if (buf == NULL) {
            fprintf(stderr, "harness: durable log recovery: no memory\n");
            close(rfd);
            return -1;
        }
        while (got < (size_t)st.st_size) {
            ssize_t n = read(rfd, buf + got,
                             (size_t)st.st_size - got);
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                fprintf(stderr, "harness: durable log read %s: %s\n",
                        g_logpath, strerror(errno));
                free(buf);
                close(rfd);
                return -1;
            }
            if (n == 0)
                break;
            got += (size_t)n;
        }
        buf[got] = '\0';
        {
            char *save = NULL, *ln;
            for (ln = strtok_r(buf, "\n", &save); ln != NULL;
                 ln = strtok_r(NULL, "\n", &save)) {
                unsigned int t_req = 0, t_d0 = 0, t_d1 = 0, t_epoch = 0;
                unsigned long long t_ord = 0, t_per = 0;
                /* Scope the match to our own COMMIT lines; ignore
                 * anything else so a foreign line can never move the
                 * watermark. Payload hex must round-trip exactly. */
                if (sscanf(ln,
                           "COMMIT req=%u d0=0x%x d1=0x%x epoch=%u"
                           " ordered=%llu persisted=%llu",
                           &t_req, &t_d0, &t_d1, &t_epoch, &t_ord,
                           &t_per) == 6) {
                    (void)t_req;
                    (void)t_d0;
                    (void)t_d1;
                    (void)t_epoch;
                    (void)t_ord;
                    g_log_receipts++;
                    if (t_per > g_host_persisted)
                        g_host_persisted = t_per;
                }
            }
        }
        free(buf);
    }
    close(rfd);
    printf("harness: durable log %s: recovered host_persisted=%llu"
           " receipts=%lu\n",
           g_logpath, (unsigned long long)g_host_persisted,
           g_log_receipts);
    return 0;
}

static int durable_log_write(const char *line)
{
    size_t len = strlen(line), off = 0;
    while (off < len) {
        ssize_t n = write(g_logfd, line + off, len - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "harness: durable log write %s: %s\n",
                    g_logpath, strerror(errno));
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/* Persist one single-submit commit receipt: append + fsync (the submit is
 * its own frame). Updates both watermarks; durable == host_persisted. */
static int durable_persist_one(uint32_t req, uint32_t d0, uint32_t d1,
                               uint32_t epoch, uint64_t fpga_ordered)
{
    char line[160];
    int n = snprintf(line, sizeof line,
                     "COMMIT req=%u d0=0x%08x d1=0x%08x epoch=%u"
                     " ordered=%llu persisted=%llu\n",
                     req, d0, d1, epoch,
                     (unsigned long long)fpga_ordered,
                     (unsigned long long)fpga_ordered);
    if (n < 0 || (size_t)n >= sizeof line)
        return -1;
    if (g_logfd < 0)
        return -1;
    g_fpga_ordered = fpga_ordered;
    if (durable_log_write(line) != 0)
        return -1;
    if (fsync(g_logfd) != 0) {
        fprintf(stderr, "harness: durable log fsync %s: %s\n", g_logpath,
                strerror(errno));
        return -1;
    }
    g_host_persisted = fpga_ordered;
    return 0;
}

/* Report the run-start watermarks; warn only when a NON-EMPTY log
 * disagrees with the fabric (the crash-window gap: ordered past what the
 * host persisted -- safe to re-drive, fabric DUP-rejects the overlap). */
static void durable_run_start(uint64_t fpga_base)
{
    g_fpga_ordered = fpga_base;
    printf("harness: watermarks fpga_ordered=%llu host_persisted=%llu"
           " (durable=host_persisted)\n",
           (unsigned long long)g_fpga_ordered,
           (unsigned long long)g_host_persisted);
    if (g_log_receipts > 0 && fpga_base != g_host_persisted)
        printf("harness: durability gap: fabric ordered past host-persisted"
               " (base=%llu persisted=%llu); re-drive overlaps are DUP"
               " rejects, no double-apply\n",
               (unsigned long long)fpga_base,
               (unsigned long long)g_host_persisted);
}

static void durable_run_done(const char *what)
{
    printf("harness: durability %s fpga_ordered=%llu host_persisted=%llu"
           " durable=host_persisted log=%s\n",
           what, (unsigned long long)g_fpga_ordered,
           (unsigned long long)g_host_persisted, g_logpath);
}

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
    return (*ver == PROTOCOL_VERSION) ? 0 : -1;
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
    if (v != PROTOCOL_VERSION) {
        fprintf(stderr, "harness: sanity: PONG VERSION mismatch 0x%08x\n", v);
        return -1;
    }
    printf("harness: ping ok (PONG version=%u)\n", v);
    if (u_read(R_MAGIC, &m) != 0 || m != 0x44555230u) {
        fprintf(stderr, "harness: sanity: MAGIC mismatch 0x%08x\n", m);
        return -1;
    }
    if (u_read(R_VERSION, &v2) != 0 || v2 != PROTOCOL_VERSION) {
        fprintf(stderr, "harness: sanity: VERSION mismatch 0x%08x\n", v2);
        return -1;
    }
    printf("harness: magic DUR0 + version v1 ok\n");
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
    if (u_ping(&v) != 0 || v != PROTOCOL_VERSION) {
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
    if (durable_persist_one(req, d0, d1, g_epoch, d) != 0) {
        tr_log("op %u GOOD req=%u: durable log persist failed", opno, req);
        return -1;
    }
    tr_log("op %u GOOD req=%u d=%llu", opno, req,
           (unsigned long long)d);
    return 0;
}

static int vec_dup(uint64_t base, uint64_t next, unsigned opno)
{
    /* Negative fault vector: deliberately change the payload of an old
     * request. Returning 0 means the harness observed DUT rejection; it is
     * never an application-level idempotent ACK or a persisted-byte match. */
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
    tr_log("op %u DUP req=%u rejected, durable held d=%llu", opno, req,
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

static int vec_invalid(uint64_t next, unsigned opno)
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
    } else { /* high-half request ahead of the durable count */
        uint32_t req = (uint32_t)next;
        uint32_t crc = desc_crc(0x11111111u, 0x22222222u, req, g_epoch);
        if (u_write(R_REQ_LO, req) != 0 ||
            u_write(R_REQ_HI, 0xDEADBEEFu) != 0 ||
            u_write(R_DESC0, 0x11111111u) != 0 ||
            u_write(R_DESC1, 0x22222222u) != 0 ||
            u_write(R_DESC_CRC, crc) != 0 ||
            u_write(R_CTRL, CTRL_SUBMIT) != 0 || wait_idle(30) != 0) {
            tr_log("op %u GAP-reqhi: submit failed", opno);
            return -1;
        }
        if (u_write(R_REQ_HI, 0) != 0) { /* restore for later good ops */
            tr_log("op %u GAP-reqhi: REQ_HI restore failed", opno);
            return -1;
        }
        if (u_read(R_ERROR, &err) != 0 || err != ERR_GAP) {
            tr_log("op %u GAP-reqhi: ERROR=0x%x, want GAP", opno, err);
            return -1;
        }
    }
    if (read_durable(&d) != 0 || d != next) {
        tr_log("op %u INVALID kind=%u: durable moved to %llu", opno, kind,
               (unsigned long long)d);
        return -1;
    }
    tr_log("op %u INVALID kind=%u held d=%llu", opno, kind,
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
        if (v != PROTOCOL_VERSION) {
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

/* ---- burst path (CMD_BURST 0x05 / RSP_BURST 0x85) ----
 * Frame builder + RSP parser + batch oracle. The single-submit path above
 * is untouched (byte-identical frames).
 *
 * Entry mix note: a well-formed burst entry carries only
 * {REQ_LO,DESC0,DESC1,DESC_CRC} -- the bridge pins REQ_HI=0, CTRL=1 and
 * settles past the commit pipeline per entry, so result CODEs 4
 * (MALFORMED) and 5 (OVERFLOW) are unreachable by construction. The
 * generator exercises CODEs 0 (commit) / 1 (CRC_ERR) / 2 (DUP_SEQ) /
 * 3 (GAP_SEQ); the parser accepts 0..5 and rejects 6..7 + any
 * COMMITTED/REJECT/CODE inconsistency. */

/* Entry kinds for the burst differential mix. */
enum {
    BK_GOOD = 0, /* req == live next, correct CRC -> COMMITTED CODE 0 */
    BK_DUP = 1, /* req < live next -> REJECT CODE 2 (checked pre-CRC) */
    BK_GAP = 2, /* req > live next -> REJECT CODE 3 (checked pre-CRC) */
    BK_BADCRC = 3 /* req == live next, corrupt CRC -> REJECT CODE 1 */
};

struct b_entry {
    uint32_t req, d0, d1, crc;
    int kind;
};

/* Build a burst CMD frame into out (caller provides 5+16*64 bytes).
 * Layout: [MAGIC0][MAGIC1][0x05][COUNT] + N x 16 B entries
 * (REQ_LO,DESC0,DESC1,DESC_CRC, each LE) + [CHK]. Returns frame length. */
static size_t burst_build(uint8_t n, const struct b_entry *e, uint8_t *out)
{
    size_t i, j, k, len;
    unsigned sum = (unsigned)CMD_BURST + (unsigned)n;
    out[0] = M_MAGIC0;
    out[1] = M_MAGIC1;
    out[2] = CMD_BURST;
    out[3] = n;
    for (i = 0; i < n; i++) {
        uint32_t w[4];
        w[0] = e[i].req;
        w[1] = e[i].d0;
        w[2] = e[i].d1;
        w[3] = e[i].crc;
        for (j = 0; j < 4; j++) {
            for (k = 0; k < 4; k++) {
                uint8_t b = (uint8_t)((w[j] >> (8 * k)) & 0xFFu);
                out[4 + i * 16 + j * 4 + k] = b;
                sum += b;
            }
        }
    }
    len = (size_t)4 + (size_t)n * 16u;
    out[len] = (uint8_t)(sum & 0xFFu);
    return len + 1;
}

/* Read + validate one BURST-RSP for COUNT n (results holds 64 bytes).
 * Returns 0 on a fully validated RSP, -1 timeout/short, -2 framing,
 * -3 checksum, -4 wrong RSP code / COUNT echo, -5 invalid result byte. */
static int rsp_burst(uint8_t n, uint8_t *results, uint64_t *dur,
                     unsigned timeout_ms)
{
    /* Max RSP: 13 + 64 bytes. */
    uint8_t f[13 + 64];
    size_t want = (size_t)13 + (size_t)n, got = 0, i;
    uint64_t deadline = now_ms() + timeout_ms;
    uint32_t lo, hi;
    unsigned sum;
    while (got < want) {
        ssize_t r = read(g_fd, f + got, want - got);
        if (r > 0) {
            got += (size_t)r;
            continue;
        }
        if (r < 0 && errno != EINTR && errno != EAGAIN) {
            fprintf(stderr, "harness: uart read: %s\n",
                    strerror(errno));
            return -1;
        }
        if (now_ms() >= deadline)
            break;
        usleep(1000);
    }
    if (got != want)
        return -1;
    if (f[0] != M_MAGIC0 || f[1] != M_MAGIC1)
        return -2;
    if (f[2] != RSP_BURST || f[3] != n)
        return -4;
    sum = (unsigned)RSP_BURST + (unsigned)n;
    for (i = 0; i < n; i++) {
        uint8_t rb = f[4 + i];
        unsigned committed = (unsigned)(rb & 1u);
        unsigned reject = (unsigned)((rb >> 1) & 1u);
        unsigned code = (unsigned)((rb >> 2) & 7u);
        if ((rb >> 5) != 0)
            return -5; /* reserved bits[7:5] must be 0 */
        if (committed == reject)
            return -5; /* COMMITTED / REJECT must be complementary */
        if (code > 5)
            return -5; /* CODE 6..7 reserved */
        if ((code == 0) != (committed == 1))
            return -5; /* CODE 0 iff COMMITTED */
        sum += rb;
    }
    lo = (uint32_t)f[4 + n] | ((uint32_t)f[4 + n + 1] << 8) |
         ((uint32_t)f[4 + n + 2] << 16) | ((uint32_t)f[4 + n + 3] << 24);
    hi = (uint32_t)f[4 + n + 4] | ((uint32_t)f[4 + n + 5] << 8) |
         ((uint32_t)f[4 + n + 6] << 16) | ((uint32_t)f[4 + n + 7] << 24);
    sum += f[4 + n] + f[4 + n + 1] + f[4 + n + 2] + f[4 + n + 3] +
           f[4 + n + 4] + f[4 + n + 5] + f[4 + n + 6] + f[4 + n + 7];
    if ((uint8_t)(sum & 0xFFu) != f[4 + n + 8])
        return -3;
    memcpy(results, f + 4, n);
    *dur = ((uint64_t)hi << 32) | lo;
    return 0;
}

/* Send one burst frame, parse the RSP. Timeout scales with COUNT: the CMD
 * alone is up to 1029 bytes (~90 ms at 115200) plus per-entry fabric feed. */
static int u_burst(uint8_t n, const struct b_entry *e, uint8_t *results,
                   uint64_t *dur)
{
    static uint8_t tx[5 + 16 * 64];
    size_t len = burst_build(n, e, tx);
    unsigned timeout = 2000u + (unsigned)n * 100u;
    tcflush(g_fd, TCIFLUSH);
    if (write_all(tx, len) != 0)
        return -1;
    return rsp_burst(n, results, dur, timeout);
}

/* Batch oracle: expected result byte for one burst entry against the live
 * model (*sw_next = pre-burst durable count; runs stay < 2^32 so the
 * high half is 0, matching the bridge-pinned REQ_HI=0).
 *
 * Mirrors DUT precedence (durable_tid_v0.v S_IDLE before S_CRC): the REQ
 * window check precedes the CRC gate, so an off-window entry with a bad
 * CRC still reports DUP/GAP. Mid-burst rejects record their code and the
 * model CONTINUES (no cascade): only COMMITTED entries advance *sw_next. */
static uint8_t burst_expect(uint64_t *sw_next, const struct b_entry *e,
                            uint32_t epoch)
{
    unsigned code;
    if ((uint64_t)e->req != *sw_next) {
        /* DUT: req_full < durable count -> DUP, req_full > durable
         * count -> GAP. The engine settles each entry before the next. */
        code = ((uint64_t)e->req < *sw_next) ? 2u : 3u;
    } else if (e->crc != desc_crc(e->d0, e->d1, e->req, epoch)) {
        code = 1u;
    } else {
        (*sw_next)++;
        return 0x01u;
    }
    return (uint8_t)(0x02u | (code << 2));
}

static const char *bkind_name(int k)
{
    switch (k) {
    case BK_GOOD:
        return "GOOD";
    case BK_DUP:
        return "DUP";
    case BK_GAP:
        return "GAP";
    default:
        return "BADCRC";
    }
}

/* Persist one burst frame's commit receipts: append one line per COMMITTED
 * entry, then a SINGLE fsync for the whole frame (group commit, NOT per
 * op). res[i]==0x01 marks committed entries. */
static int durable_persist_frame(const struct b_entry *ents,
                                 const uint8_t *res, uint8_t n,
                                 uint32_t epoch, uint64_t fpga_ordered)
{
    uint8_t i;
    if (g_logfd < 0)
        return -1;
    g_fpga_ordered = fpga_ordered;
    for (i = 0; i < n; i++) {
        char line[160];
        int m;
        if (res[i] != 0x01u)
            continue;
        m = snprintf(line, sizeof line,
                     "COMMIT req=%u d0=0x%08x d1=0x%08x epoch=%u"
                     " ordered=%llu persisted=%llu\n",
                     ents[i].req, ents[i].d0, ents[i].d1, epoch,
                     (unsigned long long)fpga_ordered,
                     (unsigned long long)fpga_ordered);
        if (m < 0 || (size_t)m >= sizeof line)
            return -1;
        if (durable_log_write(line) != 0)
            return -1;
    }
    if (fsync(g_logfd) != 0) {
        fprintf(stderr, "harness: durable log fsync %s: %s\n", g_logpath,
                strerror(errno));
        return -1;
    }
    g_host_persisted = fpga_ordered;
    return 0;
}

/* ---- burst differential: N total submits in randomized 1..64 frames ---- */
static int run_burst_diff(unsigned long total, uint32_t seed)
{
    static struct b_entry ents[BURST_MAX_N];
    static uint8_t res[BURST_MAX_N], exp[BURST_MAX_N];
    uint64_t base = 0, sw_next = 0, oline = 0, d = 0, v = 0, rsp_dur = 0;
    uint32_t epoch = 0, err = 0;
    unsigned long done = 0, nb = 0, c_commit = 0, c_code[6] = { 0, 0, 0,
                                                                0, 0, 0 };
    uint64_t t0, t1;
    uint8_t i, n;
    rng_state = (seed != 0) ? seed : 0x9E3779B9u;
    if (u_write(R_EPOCH, g_epoch) != 0 || clear_errors() != 0 ||
        u_read(R_EPOCH, &epoch) != 0 || epoch != g_epoch ||
        read_durable(&base) != 0 || read_visible(&v) != 0) {
        fprintf(stderr, "harness: burst diff setup failed\n");
        return 1;
    }
    if (durable_log_open() != 0)
        return 1;
    durable_run_start(base);
    sw_next = base;
    printf("harness: burst diff base d=%llu v=%llu epoch=%u seed=%u\n",
           (unsigned long long)base, (unsigned long long)v, epoch,
           rng_state);
    t0 = now_ms();
    while (done < total) {
        uint64_t tmp;
        int rc;
        n = (uint8_t)(1u + rng_next() % BURST_MAX_N);
        if ((unsigned long)n > total - done)
            n = (uint8_t)(total - done);
        /* Generate the seeded entry mix against a shadow model so GOOD
         * REQs chain across mid-burst commits exactly like the DUT. */
        tmp = sw_next;
        for (i = 0; i < n; i++) {
            uint32_t r = rng_next() % 100u;
            uint32_t req;
            if (r < 60) { /* good */
                req = (uint32_t)tmp;
                ents[i].req = req;
                ents[i].d0 = 0xA0000000u | (req & 0x0FFFFFFFu);
                ents[i].d1 = 0xB0000000u | (req & 0x0FFFFFFFu);
                ents[i].crc = desc_crc(ents[i].d0, ents[i].d1, req,
                                       epoch);
                ents[i].kind = BK_GOOD;
                tmp++;
            } else if (r < 70) { /* dup (CRC value irrelevant: REQ
                                  * checked first; send correct CRC) */
                if (tmp == base) { /* no history: emit good instead */
                    req = (uint32_t)tmp;
                    ents[i].req = req;
                    ents[i].d0 = 0xA0000000u | (req & 0x0FFFFFFFu);
                    ents[i].d1 = 0xB0000000u | (req & 0x0FFFFFFFu);
                    ents[i].crc = desc_crc(ents[i].d0, ents[i].d1,
                                           req, epoch);
                    ents[i].kind = BK_GOOD;
                    tmp++;
                } else {
                    req = (uint32_t)(base +
                                     (rng_next() %
                                      (uint32_t)(tmp - base)));
                    ents[i].req = req;
                    ents[i].d0 = 0xA0A0A0A0u;
                    ents[i].d1 = 0xB0B0B0B0u;
                    ents[i].crc = desc_crc(ents[i].d0, ents[i].d1,
                                           req, epoch);
                    ents[i].kind = BK_DUP;
                }
            } else if (r < 78) { /* gap */
                req = (uint32_t)tmp + 1u + (rng_next() % 4u);
                ents[i].req = req;
                ents[i].d0 = 0xC0C0C0C0u;
                ents[i].d1 = 0xD0D0D0D0u;
                ents[i].crc = desc_crc(ents[i].d0, ents[i].d1, req,
                                       epoch);
                ents[i].kind = BK_GAP;
            } else { /* bad CRC on the live REQ */
                req = (uint32_t)tmp;
                ents[i].req = req;
                ents[i].d0 = 0x11111111u ^ ((uint32_t)tmp << 8);
                ents[i].d1 = 0x22222222u ^ (uint32_t)tmp;
                ents[i].crc = ~desc_crc(ents[i].d0, ents[i].d1, req,
                                        epoch);
                ents[i].kind = BK_BADCRC;
            }
        }
        /* Independent expectation pass over the software model. */
        oline = sw_next;
        for (i = 0; i < n; i++)
            exp[i] = burst_expect(&oline, &ents[i], epoch);
        rc = u_burst(n, ents, res, &rsp_dur);
        if (rc != 0) {
            fprintf(stderr,
                    "harness: burst %lu MISMATCH: u_burst n=%u rc=%d"
                    " (done=%lu base=%llu)\n",
                    nb, n, rc, done, (unsigned long long)base);
            tr_dump();
            return 1;
        }
        for (i = 0; i < n; i++) {
            if (res[i] != exp[i]) {
                tr_log("burst %lu entry %u FIRST mismatch: kind=%s"
                       " req=%u got=0x%02x(C=%u,CODE=%u)"
                       " want=0x%02x(C=%u,CODE=%u)",
                       nb, i, bkind_name(ents[i].kind), ents[i].req,
                       res[i], res[i] & 1u, (res[i] >> 2) & 7u, exp[i],
                       exp[i] & 1u, (exp[i] >> 2) & 7u);
                fprintf(stderr,
                        "harness: burst %lu entry %u FIRST mismatch:"
                        " kind=%s req=%u got=0x%02x want=0x%02x"
                        " (done=%lu)\n",
                        nb, i, bkind_name(ents[i].kind), ents[i].req,
                        res[i], exp[i], done);
                tr_dump();
                return 1;
            }
            if (res[i] == 0x01u) {
                c_commit++;
            } else {
                unsigned code = (unsigned)((res[i] >> 2) & 7u);
                if (code < 6)
                    c_code[code]++;
            }
            tr_log("burst %lu entry %u %s req=%u res=0x%02x", nb, i,
                   bkind_name(ents[i].kind), ents[i].req, res[i]);
        }
        if (rsp_dur != oline) {
            fprintf(stderr,
                    "harness: burst %lu MISMATCH: RSP watermark %llu,"
                    " oracle %llu\n",
                    nb, (unsigned long long)rsp_dur,
                    (unsigned long long)oline);
            tr_dump();
            return 1;
        }
        /* Per-entry ERROR stickies are rw1c-cleared by the engine; only
         * pre-burst stickies (0 here) may survive. */
        if (u_read(R_ERROR, &err) != 0 || err != 0) {
            fprintf(stderr,
                    "harness: burst %lu MISMATCH: ERROR=0x%x after"
                    " burst, want 0x0\n",
                    nb, err);
            tr_dump();
            return 1;
        }
        if (read_durable(&d) != 0 || read_visible(&v) != 0 ||
            oracle_compare(oline, d, oline, v) != 0) {
            fprintf(stderr,
                    "harness: burst %lu MISMATCH: oracle vs d=%llu"
                    " v=%llu want %llu\n",
                    nb, (unsigned long long)d,
                    (unsigned long long)v,
                    (unsigned long long)oline);
            tr_dump();
            return 1;
        }
        if (durable_persist_frame(ents, res, n, epoch, oline) != 0) {
            fprintf(stderr, "harness: burst %lu: durable log persist"
                    " failed\n",
                    nb);
            return 1;
        }
        sw_next = oline;
        {
            unsigned long prev = done;
            done += n;
            nb++;
            if (done / 500 != prev / 500)
                printf("harness: burst diff %lu/%lu submits (%lu frames,"
                       " %.1f ops/s)\n",
                       done, total, nb,
                       (1000.0 * (double)done) /
                           (double)(now_ms() - t0 + 1));
        }
    }
    t1 = now_ms();
    if (read_durable(&d) != 0 || read_visible(&v) != 0)
        return 1;
    printf("harness: burst diff OK submits=%lu frames=%lu seed=%u"
           " commit=%lu crc=%lu dup=%lu gap=%lu d=%llu v=%llu"
           " %.1f ops/s\n",
           done, nb, seed, c_commit, c_code[1], c_code[2], c_code[3],
           (unsigned long long)d, (unsigned long long)v,
           (1000.0 * (double)done) / (double)(t1 - t0 + 1));
    durable_run_done("burst-diff");
    return (oracle_compare(sw_next, d, sw_next, v) == 0) ? 0 : 1;
}

/* ---- burstmax: one COUNT=64 all-good max frame (1029-byte CMD) ---- */
static int run_burst_max(void)
{
    static struct b_entry ents[BURST_MAX_N];
    static uint8_t res[BURST_MAX_N];
    uint64_t base = 0, d = 0, v = 0, rsp_dur = 0;
    uint32_t epoch = 0, err = 0;
    uint8_t i;
    int rc;
    if (u_write(R_EPOCH, g_epoch) != 0 || clear_errors() != 0 ||
        u_read(R_EPOCH, &epoch) != 0 || epoch != g_epoch ||
        read_durable(&base) != 0) {
        fprintf(stderr, "harness: burstmax setup failed\n");
        return 1;
    }
    if (durable_log_open() != 0)
        return 1;
    durable_run_start(base);
    for (i = 0; i < BURST_MAX_N; i++) {
        uint32_t req = (uint32_t)(base + i);
        ents[i].req = req;
        ents[i].d0 = 0xA0000000u | (req & 0x0FFFFFFFu);
        ents[i].d1 = 0xB0000000u | (req & 0x0FFFFFFFu);
        ents[i].crc = desc_crc(ents[i].d0, ents[i].d1, req, epoch);
        ents[i].kind = BK_GOOD;
    }
    rc = u_burst(BURST_MAX_N, ents, res, &rsp_dur);
    if (rc != 0) {
        fprintf(stderr, "harness: burstmax: u_burst rc=%d\n", rc);
        return 1;
    }
    for (i = 0; i < BURST_MAX_N; i++) {
        if (res[i] != 0x01u) {
            fprintf(stderr,
                    "harness: burstmax: entry %u res=0x%02x, want 0x01\n",
                    i, res[i]);
            return 1;
        }
    }
    if (rsp_dur != base + BURST_MAX_N) {
        fprintf(stderr,
                "harness: burstmax: RSP watermark %llu, want %llu\n",
                (unsigned long long)rsp_dur,
                (unsigned long long)(base + BURST_MAX_N));
        return 1;
    }
    if (u_read(R_ERROR, &err) != 0 || err != 0) {
        fprintf(stderr, "harness: burstmax: ERROR=0x%x, want 0x0\n",
                err);
        return 1;
    }
    if (read_durable(&d) != 0 || read_visible(&v) != 0 ||
        d != base + BURST_MAX_N || v != base + BURST_MAX_N) {
        fprintf(stderr,
                "harness: burstmax: d=%llu v=%llu, want %llu\n",
                (unsigned long long)d, (unsigned long long)v,
                (unsigned long long)(base + BURST_MAX_N));
        return 1;
    }
    if (durable_persist_frame(ents, res, BURST_MAX_N, epoch,
                              base + BURST_MAX_N) != 0) {
        fprintf(stderr, "harness: burstmax: durable log persist failed\n");
        return 1;
    }
    printf("harness: burstmax OK n=64 base=%llu d=%llu v=%llu\n",
           (unsigned long long)base, (unsigned long long)d,
           (unsigned long long)v);
    durable_run_done("burstmax");
    return 0;
}

/* ---- burstdrop: one bad-checksum burst commits nothing, link alive ---- */
static int run_burst_drop(void)
{
    static struct b_entry ents[3];
    static uint8_t tx[5 + 16 * 3], res[3];
    uint64_t base = 0, d = 0, rsp_dur = 0;
    uint32_t epoch = 0, pv = 0;
    uint8_t i;
    size_t len;
    int rc;
    if (u_write(R_EPOCH, g_epoch) != 0 || clear_errors() != 0 ||
        u_read(R_EPOCH, &epoch) != 0 || read_durable(&base) != 0) {
        fprintf(stderr, "harness: burstdrop setup failed\n");
        return 1;
    }
    for (i = 0; i < 3; i++) {
        uint32_t req = (uint32_t)(base + i);
        ents[i].req = req;
        ents[i].d0 = 0xA0000000u | (req & 0x0FFFFFFFu);
        ents[i].d1 = 0xB0000000u | (req & 0x0FFFFFFFu);
        ents[i].crc = desc_crc(ents[i].d0, ents[i].d1, req, epoch);
        ents[i].kind = BK_GOOD;
    }
    len = burst_build(3, ents, tx);
    tx[len - 1] = (uint8_t)(tx[len - 1] + 1u); /* corrupt CHK */
    tcflush(g_fd, TCIFLUSH);
    if (write_all(tx, len) != 0)
        return 1;
    rc = rsp_burst(3, res, &rsp_dur, SILENCE_MS);
    if (rc == 0) {
        fprintf(stderr,
                "harness: burstdrop: bad-checksum burst got a response\n");
        return 1;
    }
    printf("harness: bad-checksum burst silently dropped (rc=%d)\n", rc);
    if (read_durable(&d) != 0 || d != base) {
        fprintf(stderr,
                "harness: burstdrop: durable moved to %llu, want %llu\n",
                (unsigned long long)d, (unsigned long long)base);
        return 1;
    }
    if (u_ping(&pv) != 0) {
        fprintf(stderr, "harness: burstdrop: link dead after drop\n");
        return 1;
    }
    printf("harness: burstdrop OK d=%llu link alive\n",
           (unsigned long long)d);
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
    if (durable_log_open() != 0)
        return 1;
    durable_run_start(next);
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
           n, (unsigned long long)g_host_persisted,
           (unsigned long long)v,
           (1000.0 * (double)n) / (double)(t1 - t0 + 1));
    durable_run_done("smoke");
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
    if (durable_log_open() != 0)
        return 1;
    durable_run_start(base);
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
            rc = vec_invalid(next, (unsigned)i);
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
           (unsigned long long)g_host_persisted,
           (unsigned long long)v,
           (1000.0 * (double)n) / (double)(t1 - t0 + 1));
    durable_run_done("diff");
    return (oracle_compare(next, d, next, v) == 0) ? 0 : 1;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [-t tty] [-l log] <ping|magic|read|write|reset|smoke|"
            "diff|burst|burstmax|burstdrop>"
            " [args...]\n"
            "  ping                  PING round trip (PONG + VERSION 1)\n"
            "  magic                 read MAGIC + VERSION\n"
            "  read  <addr>          READ-REG one round trip\n"
            "  write <addr> <val>    WRITE-REG one round trip (echo-checked)\n"
            "  reset                 RESET round trip\n"
            "  smoke <N>             N good submits, oracle-checked\n"
            "  diff  <N> [seed]      seeded differential mix (good/dup/gap/\n"
            "                        invalid/reads); FIRST mismatch stops\n"
            "  burst <N> [seed]      seeded burst differential (N submits in\n"
            "                        randomized 1..64 frames, good/dup/gap/\n"
            "                        badcrc entries); FIRST mismatch stops\n"
            "  burstmax              one COUNT=64 all-good max frame\n"
            "  burstdrop             one bad-checksum burst: silent drop,\n"
            "                        watermark held, link alive\n"
            "  default tty: " UART_PATH " @115200-8-N-1\n"
            "  default log: ./durable.log (commit receipts, fsync per frame;\n"
            "                        durable=host_persisted, fabric count is\n"
            "                        ordered-only)\n",
            argv0);
}

int main(int argc, char **argv)
{
    const char *tty = UART_PATH;
    const char *cmd;
    int ai = 1;
    uint32_t val = 0;
    while (ai + 1 < argc) {
        if (strcmp(argv[ai], "-t") == 0) {
            tty = argv[ai + 1];
            ai += 2;
        } else if (strcmp(argv[ai], "-l") == 0) {
            g_logpath = argv[ai + 1];
            ai += 2;
        } else {
            break;
        }
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
        if (val != PROTOCOL_VERSION) {
            fprintf(stderr, "harness: PONG VERSION mismatch 0x%08x\n", val);
            return 1;
        }
        printf("harness: PONG version=%u\n", val);
    } else if (strcmp(cmd, "magic") == 0) {
        uint32_t m = 0, version = 0;
        if (u_read(R_MAGIC, &m) != 0 || u_read(R_VERSION, &version) != 0)
            return 1;
        printf("harness: MAGIC=0x%08x VERSION=0x%08x\n", m, version);
        if (m != 0x44555230u || version != PROTOCOL_VERSION)
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
    } else if (strcmp(cmd, "burst") == 0) {
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
        return run_burst_diff(n, seed);
    } else if (strcmp(cmd, "burstmax") == 0) {
        if (sanity() != 0)
            return 1;
        return run_burst_max();
    } else if (strcmp(cmd, "burstdrop") == 0) {
        if (sanity() != 0)
            return 1;
        return run_burst_drop();
    } else {
        usage(argv[0]);
        return 2;
    }
    return 0;
}
