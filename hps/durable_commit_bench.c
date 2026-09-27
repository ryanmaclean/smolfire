/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * durable_commit_bench.c -- smolFire #86: ARM-only (CPU) durable-commit
 * baseline, single outstanding operation, model B from
 * docs/DURABLE-TID-SEQ-VS-ALLOC.md (caller-supplied seq == durable_seq+1).
 *
 * Phases timed per operation (CLOCK_MONOTONIC, ns):
 *   construct  build the record (seq, epoch, payload, CRC-32/IEEE)
 *   append     pwrite() of the record at seq*recsize
 *   durable    fdatasync() (falls back to fsync() if EINVAL)
 *   publish    store-release of visible_seq into a shared word
 *   total      construct+append+durable+publish
 * Recovery: scan the log, verify CRC, durable_seq = last contiguous good
 * record. Timed separately (--recover-only).
 *
 * No queue, no batching, no ring, no FPGA. Plain POSIX. Static build for the
 * MiSTer armv7l (glibc 2.31) target.
 *
 * Output: SMOLFIRE_METRIC key=value lines (integers) for bin/bench-record.nu,
 * then a JSON object with the same numbers on stdout.
 *
 * Fault-injection hooks (#88, driven by hps/durable_fault_harness.c). All are
 * off by default; with none given the timed loop is the #86 loop.
 *   --ack-fd N        after publish, write the 8-byte seq to fd N (the
 *                     "acknowledged as durable" channel the controller trusts)
 *   --phase-fd N      mmap fd N (memfd) and store {phase, chunk, seq} at every
 *                     phase boundary (plain stores, async-signal-safe) so the
 *                     controller can attribute an external SIGKILL to a phase
 *   --stop-at P:OP[:C] raise(SIGSTOP) at boundary P of op OP (0-based, this run),
 *                     after chunk C for P=append-mid; the controller then
 *                     sends SIGKILL, i.e. kill -9 at an exact boundary
 *   --split K         write each record in K pwrite() chunks (torn-write window)
 *   --fail P:OP:ERRNO pretend the append (after writing half the record) or
 *                     durable syscall of op OP failed with ERRNO
 *   --sync-retry      after an append/durable error, call fdatasync() again and
 *                     report its result (fsyncgate probe), then exit 3
 *   --repair          after recovery, truncate the log to durable_seq*recsize
 *                     and fsync, so no torn/partial bytes remain past it
 *   --mutate M        deliberately broken writer, used only to prove the #88
 *                     oracle catches bugs: ack-early (ack before the append),
 *                     no-repair (--repair becomes a no-op)
 * On an I/O error the writer prints one SMOLFIRE_FAULT line to stderr, never
 * acks the failed seq, and exits 3.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/perf_event.h>
#endif

#define MAGIC 0x53464443u /* 'SFDC' */

struct hdr {
    uint32_t magic;
    uint32_t epoch;
    uint64_t seq;
    uint32_t len;   /* payload bytes */
    uint32_t crc;   /* over magic..len + payload, with crc field = 0 */
};

static uint32_t crc32_ieee(const uint8_t *buf, size_t len, uint32_t crc)
{
    crc = ~crc;
    for (size_t i = 0; i < len; i++) {
        crc ^= buf[i];
        for (int b = 0; b < 8; b++)
            crc = (crc & 1u) ? (crc >> 1) ^ 0xEDB88320u : (crc >> 1);
    }
    return ~crc;
}

static inline uint64_t now_ns(clockid_t c)
{
    struct timespec ts;
    clock_gettime(c, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* --- fault-injection hooks (#88); inert unless enabled on the command line --- */
enum { PH_START, PH_RECOVER, PH_CONSTRUCT, PH_CONSTRUCT_MID, PH_APPEND, PH_APPEND_MID,
       PH_DURABLE, PH_PUBLISH, PH_ACK, PH_DONE, PH_N };
static const char *const ph_name[PH_N] = { "start", "recover", "construct", "construct-mid", "append",
    "append-mid", "durable", "publish", "ack", "done" };
struct phase_page { uint32_t phase, chunk; uint64_t seq, acked; };
static struct phase_page *pp;            /* NULL unless --phase-fd */
static int stop_ph = -1, fail_ph = -1, fail_errno = 0;
static long stop_op = -1, stop_chunk = 1, fail_op = -1, cur_op = -1;

static inline void at(int ph, uint32_t chunk, uint64_t seq)
{
    if (pp) {
        __atomic_store_n(&pp->seq, seq, __ATOMIC_RELAXED);
        __atomic_store_n(&pp->chunk, chunk, __ATOMIC_RELAXED);
        __atomic_store_n(&pp->phase, (uint32_t)ph, __ATOMIC_RELEASE);
    }
    if (ph == stop_ph && cur_op == stop_op && (ph != PH_APPEND_MID || (long)chunk == stop_chunk))
        raise(SIGSTOP); /* async-signal-safe; controller SIGKILLs us while stopped */
}

static int ph_lookup(const char *s, size_t n)
{
    for (int i = 0; i < PH_N; i++)
        if (strlen(ph_name[i]) == n && !strncmp(ph_name[i], s, n)) return i;
    return -1;
}

static void fault_exit(const char *phase, int err, uint64_t seq, size_t written, int fd, int sync_retry)
{
    int rr = 0, re = 0;
    if (sync_retry) { rr = fdatasync(fd); re = rr ? errno : 0; }
    fprintf(stderr, "SMOLFIRE_FAULT phase=%s errno=%d seq=%" PRIu64 " written=%zu sync_retry=%d retry_rc=%d retry_errno=%d\n",
            phase, err, seq, written, sync_retry, rr, re);
    exit(3);
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

struct stats { uint64_t min, p50, p95, p99, max, mean, sum; };

static struct stats stats_of(uint64_t *v, size_t n)
{
    struct stats s = {0};
    if (!n) return s;
    qsort(v, n, sizeof *v, cmp_u64);
    for (size_t i = 0; i < n; i++) s.sum += v[i];
    s.min = v[0]; s.max = v[n - 1];
    s.p50 = v[(n * 50) / 100 < n ? (n * 50) / 100 : n - 1];
    s.p95 = v[(n * 95) / 100 < n ? (n * 95) / 100 : n - 1];
    s.p99 = v[(n * 99) / 100 < n ? (n * 99) / 100 : n - 1];
    s.mean = s.sum / n;
    return s;
}

/* --- optional HW cycle counter via perf_event_open --- */
static int perf_fd = -1;
static void perf_open(void)
{
#ifdef __linux__
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof pe);
    pe.type = PERF_TYPE_HARDWARE;
    pe.size = sizeof pe;
    pe.config = PERF_COUNT_HW_CPU_CYCLES;
    pe.disabled = 1;
    pe.exclude_kernel = 0; /* we want kernel cycles of write/fsync too */
    pe.exclude_hv = 1;
    perf_fd = (int)syscall(__NR_perf_event_open, &pe, 0, -1, -1, 0);
    if (perf_fd >= 0) ioctl(perf_fd, PERF_EVENT_IOC_ENABLE, 0);
#endif
}
static uint64_t perf_read(void)
{
    uint64_t v = 0;
    if (perf_fd >= 0 && read(perf_fd, &v, sizeof v) != (ssize_t)sizeof v) v = 0;
    return v;
}

static long rss_kb(void)
{
    FILE *f = fopen("/proc/self/status", "r");
    long kb = -1;
    char line[256];
    if (!f) return -1;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "VmRSS: %ld", &kb) == 1) break;
    fclose(f);
    return kb;
}

static uint64_t proc_io_write_bytes(void)
{
    FILE *f = fopen("/proc/self/io", "r");
    uint64_t v = 0; char line[256];
    if (!f) return 0;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "write_bytes: %" SCNu64, &v) == 1) break;
    fclose(f);
    return v;
}

/* Recovery: returns durable_seq, sets *epoch to max epoch seen. */
static uint64_t recover(int fd, size_t recsize, uint32_t *epoch, uint64_t *bad)
{
    uint8_t *buf = malloc(recsize);
    uint64_t seq = 0; off_t off = 0; *bad = 0;
    for (;;) {
        ssize_t r = pread(fd, buf, recsize, off);
        if (r < (ssize_t)recsize) break;
        struct hdr h; memcpy(&h, buf, sizeof h);
        uint32_t want = h.crc; h.crc = 0; memcpy(buf, &h, sizeof h);
        uint32_t got = crc32_ieee(buf, sizeof h + h.len, 0);
        if (h.magic != MAGIC || h.len != recsize - sizeof h || got != want || h.seq != seq + 1) { (*bad)++; break; }
        seq = h.seq; if (h.epoch > *epoch) *epoch = h.epoch;
        off += (off_t)recsize;
    }
    free(buf);
    return seq;
}

static void usage(const char *p)
{
    fprintf(stderr, "usage: %s --log PATH --ops N --recsize B [--mode append|prealloc] [--epoch E] [--recover-only] [--no-sync]\n"
            "       [--mutate ack-early|no-repair] [--ack-fd N] [--phase-fd N] [--stop-at PHASE:OP[:CHUNK]] [--split K] [--fail PHASE:OP:ERRNO] [--sync-retry] [--repair]\n", p);
    exit(2);
}

int main(int argc, char **argv)
{
    const char *log = NULL, *mode = "append";
    long ops = 0; size_t recsize = 64; uint32_t epoch = 1; int recover_only = 0, do_sync = 1;
    int ack_fd = -1, phase_fd = -1, split = 1, sync_retry = 0, repair = 0;
    int mut_ack_early = 0, mut_no_repair = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--log") && i + 1 < argc) log = argv[++i];
        else if (!strcmp(argv[i], "--ops") && i + 1 < argc) ops = atol(argv[++i]);
        else if (!strcmp(argv[i], "--recsize") && i + 1 < argc) recsize = (size_t)atol(argv[++i]);
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = argv[++i];
        else if (!strcmp(argv[i], "--epoch") && i + 1 < argc) epoch = (uint32_t)atol(argv[++i]);
        else if (!strcmp(argv[i], "--recover-only")) recover_only = 1;
        else if (!strcmp(argv[i], "--no-sync")) do_sync = 0;
        else if (!strcmp(argv[i], "--ack-fd") && i + 1 < argc) ack_fd = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--phase-fd") && i + 1 < argc) phase_fd = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--split") && i + 1 < argc) split = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--sync-retry")) sync_retry = 1;
        else if (!strcmp(argv[i], "--repair")) repair = 1;
        else if (!strcmp(argv[i], "--mutate") && i + 1 < argc) {
            const char *m = argv[++i];
            if (!strcmp(m, "ack-early")) mut_ack_early = 1; else if (!strcmp(m, "no-repair")) mut_no_repair = 1; else usage(argv[0]);
        }
        else if (!strcmp(argv[i], "--stop-at") && i + 1 < argc) {
            const char *s = argv[++i], *c = strchr(s, ':');
            if (!c || (stop_ph = ph_lookup(s, (size_t)(c - s))) < 0) usage(argv[0]);
            char *e; stop_op = strtol(c + 1, &e, 10);
            if (*e == ':') stop_chunk = strtol(e + 1, NULL, 10);
        } else if (!strcmp(argv[i], "--fail") && i + 1 < argc) {
            const char *s = argv[++i], *c = strchr(s, ':');
            if (!c || (fail_ph = ph_lookup(s, (size_t)(c - s))) < 0) usage(argv[0]);
            char *e; fail_op = strtol(c + 1, &e, 10);
            if (*e != ':') usage(argv[0]);
            fail_errno = atoi(e + 1);
        }
        else usage(argv[0]);
    }
    if (!log || recsize < sizeof(struct hdr) + 8) usage(argv[0]);
    if (split < 1 || (size_t)split > recsize) usage(argv[0]);
    if (phase_fd >= 0) {
        pp = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, phase_fd, 0);
        if (pp == MAP_FAILED) { perror("mmap phase-fd"); return 1; }
    }
    at(PH_START, 0, 0);

    uint64_t t_start = now_ns(CLOCK_MONOTONIC);
    int fd = open(log, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror("open"); return 1; }

    /* --- recovery --- */
    at(PH_RECOVER, 0, 0);
    uint64_t rec0 = now_ns(CLOCK_MONOTONIC), bad = 0; uint32_t seen_epoch = 0;
    uint64_t durable_seq = recover(fd, recsize, &seen_epoch, &bad);
    uint64_t rec_ns = now_ns(CLOCK_MONOTONIC) - rec0;
    struct stat st; fstat(fd, &st);
    printf("SMOLFIRE_METRIC recovery_ns=%" PRIu64 "\n", rec_ns);
    printf("SMOLFIRE_METRIC recovery_records=%" PRIu64 "\n", durable_seq);
    printf("SMOLFIRE_METRIC recovery_bad_tail=%" PRIu64 "\n", bad);
    printf("SMOLFIRE_METRIC recovery_bytes_scanned=%lld\n", (long long)st.st_size);
    uint64_t repaired = 0;
    if (repair && !mut_no_repair && (uint64_t)st.st_size > durable_seq * recsize) {
        repaired = (uint64_t)st.st_size - durable_seq * recsize;
        if (ftruncate(fd, (off_t)(durable_seq * recsize)) != 0 || fsync(fd) != 0) { perror("repair"); return 1; }
        st.st_size = (off_t)(durable_seq * recsize);
    }
    printf("SMOLFIRE_METRIC recovery_repaired_bytes=%" PRIu64 "\n", repaired);
    printf("SMOLFIRE_METRIC recovery_epoch=%u\n", seen_epoch);
    printf("SMOLFIRE_METRIC recovery_wall_from_main_ns=%" PRIu64 "\n", now_ns(CLOCK_MONOTONIC) - t_start);
    if (recover_only) {
        printf("{\"recovery_ns\":%" PRIu64 ",\"durable_seq\":%" PRIu64 ",\"epoch_seen\":%u,\"bad_tail\":%" PRIu64 ",\"bytes\":%lld}\n",
               rec_ns, durable_seq, seen_epoch, bad, (long long)st.st_size);
        close(fd); return 0;
    }
    if (epoch <= seen_epoch) epoch = seen_epoch + 1;

    if (!strcmp(mode, "prealloc")) {
        off_t need = (off_t)(durable_seq + (uint64_t)ops) * (off_t)recsize;
        if (st.st_size < need) {
            if (ftruncate(fd, need) != 0) { perror("ftruncate"); return 1; }
            /* Force block allocation so pwrite is in-place: write zeros then fsync. */
            uint8_t *z = calloc(1, 1 << 16);
            for (off_t o = st.st_size; o < need; o += (1 << 16)) {
                size_t n = (size_t)((need - o) < (1 << 16) ? (need - o) : (1 << 16));
                if (pwrite(fd, z, n, o) != (ssize_t)n) { perror("prealloc pwrite"); return 1; }
            }
            free(z); fsync(fd);
        }
    }

    /* visible_seq publication target: a shared word (stand-in for the
     * completion register the FPGA would expose). */
    volatile uint64_t *visible = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (visible == MAP_FAILED) { perror("mmap"); return 1; }
    *visible = durable_seq;

    uint64_t *t_con = malloc(ops * sizeof(uint64_t)), *t_app = malloc(ops * sizeof(uint64_t));
    uint64_t *t_dur = malloc(ops * sizeof(uint64_t)), *t_pub = malloc(ops * sizeof(uint64_t));
    uint64_t *t_tot = malloc(ops * sizeof(uint64_t));
    uint8_t *rec = malloc(recsize);
    size_t plen = recsize - sizeof(struct hdr);

    perf_open();
    uint64_t cpu0 = now_ns(CLOCK_PROCESS_CPUTIME_ID), cyc0 = perf_read();
    uint64_t io0 = proc_io_write_bytes();
    uint64_t wall0 = now_ns(CLOCK_MONOTONIC);
    int sync_fallback = 0;

    for (long i = 0; i < ops; i++) {
        uint64_t seq = durable_seq + 1; /* model B: exactly durable_seq+1 */
        cur_op = i;
        at(PH_CONSTRUCT, 0, seq);
        uint64_t a = now_ns(CLOCK_MONOTONIC);
        /* construct */
        struct hdr h = { MAGIC, epoch, seq, (uint32_t)plen, 0 };
        memcpy(rec, &h, sizeof h);
        for (size_t k = 0; k < plen; k++) rec[sizeof h + k] = (uint8_t)(seq + k);
        at(PH_CONSTRUCT_MID, 0, seq);
        h.crc = crc32_ieee(rec, recsize, 0);
        memcpy(rec, &h, sizeof h);
        if (mut_ack_early && ack_fd >= 0 && write(ack_fd, &seq, sizeof seq) != (ssize_t)sizeof seq) return 1; /* BUG on purpose */
        at(PH_APPEND, 0, seq);
        uint64_t b = now_ns(CLOCK_MONOTONIC);
        /* append: K chunks (K=1 is the #86 single pwrite). Short writes are
         * continued; a failed write is a fault and that seq is never acked. */
        off_t off = (off_t)(seq - 1) * (off_t)recsize;
        size_t done = 0;
        for (int k = 0; k < split; k++) {
            size_t end = (k == split - 1) ? recsize : (recsize * (size_t)(k + 1)) / (size_t)split;
            if (fail_ph == PH_APPEND && cur_op == fail_op) {
                size_t half = recsize / 2;
                if (pwrite(fd, rec, half, off) != (ssize_t)half) fault_exit("append", errno, seq, 0, fd, sync_retry);
                fault_exit("append", fail_errno, seq, half, fd, sync_retry);
            }
            while (done < end) {
                ssize_t w = pwrite(fd, rec + done, end - done, off + (off_t)done);
                if (w < 0) { if (errno == EINTR) continue; fault_exit("append", errno, seq, done, fd, sync_retry); }
                if (w == 0) fault_exit("append", EIO, seq, done, fd, sync_retry);
                done += (size_t)w;
            }
            if (k < split - 1) at(PH_APPEND_MID, (uint32_t)(k + 1), seq);
        }
        at(PH_DURABLE, 0, seq);
        uint64_t c = now_ns(CLOCK_MONOTONIC);
        /* durable */
        if (fail_ph == PH_DURABLE && cur_op == fail_op) fault_exit("durable", fail_errno, seq, recsize, fd, sync_retry);
        if (do_sync) {
            if (fdatasync(fd) != 0) {
                if (errno == EINVAL) { sync_fallback = 1; if (fsync(fd) != 0) fault_exit("durable", errno, seq, recsize, fd, sync_retry); }
                else fault_exit("durable", errno, seq, recsize, fd, sync_retry);
            }
        }
        at(PH_PUBLISH, 0, seq);
        uint64_t d = now_ns(CLOCK_MONOTONIC);
        /* publish */
        durable_seq = seq;
        __atomic_store_n(visible, seq, __ATOMIC_RELEASE);
        uint64_t e = now_ns(CLOCK_MONOTONIC);
        t_con[i] = b - a; t_app[i] = c - b; t_dur[i] = d - c; t_pub[i] = e - d; t_tot[i] = e - a;
        /* acknowledge (untimed): only from here may a client rely on seq */
        at(PH_ACK, 0, seq);
        if (!mut_ack_early && ack_fd >= 0 && write(ack_fd, &seq, sizeof seq) != (ssize_t)sizeof seq) { perror("ack"); return 1; }
        if (pp) __atomic_store_n(&pp->acked, seq, __ATOMIC_RELEASE);
        at(PH_DONE, 0, seq);
    }
    uint64_t wall = now_ns(CLOCK_MONOTONIC) - wall0;
    uint64_t cpu = now_ns(CLOCK_PROCESS_CPUTIME_ID) - cpu0;
    uint64_t cyc = perf_read() - cyc0;
    uint64_t io = proc_io_write_bytes() - io0;
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    long rss = rss_kb();

    struct stats S[5]; const char *names[5] = {"construct", "append", "durable", "publish", "total"};
    uint64_t *arr[5] = {t_con, t_app, t_dur, t_pub, t_tot};
    for (int k = 0; k < 5; k++) S[k] = stats_of(arr[k], (size_t)ops);

    printf("SMOLFIRE_METRIC ops=%ld\n", ops);
    printf("SMOLFIRE_METRIC recsize_bytes=%zu\n", recsize);
    printf("SMOLFIRE_METRIC bytes_written_payload=%" PRIu64 "\n", (uint64_t)ops * recsize);
    printf("SMOLFIRE_METRIC bytes_written_block=%" PRIu64 "\n", io);
    printf("SMOLFIRE_METRIC wall_ns=%" PRIu64 "\n", wall);
    printf("SMOLFIRE_METRIC cpu_ns=%" PRIu64 "\n", cpu);
    printf("SMOLFIRE_METRIC cpu_ns_per_op=%" PRIu64 "\n", cpu / (uint64_t)ops);
    printf("SMOLFIRE_METRIC cycles=%" PRIu64 "\n", cyc);
    printf("SMOLFIRE_METRIC cycles_per_op=%" PRIu64 "\n", cyc / (uint64_t)ops);
    printf("SMOLFIRE_METRIC cycles_available=%d\n", perf_fd >= 0);
    printf("SMOLFIRE_METRIC ops_per_s_one_outstanding=%" PRIu64 "\n", wall ? (uint64_t)ops * 1000000000ull / wall : 0);
    printf("SMOLFIRE_METRIC rss_kb=%ld\n", rss);
    printf("SMOLFIRE_METRIC maxrss_kb=%ld\n", ru.ru_maxrss);
    printf("SMOLFIRE_METRIC fsync_fallback=%d\n", sync_fallback);
    printf("SMOLFIRE_METRIC sync_enabled=%d\n", do_sync);
    for (int k = 0; k < 5; k++) {
        printf("SMOLFIRE_METRIC %s_p50_ns=%" PRIu64 "\n", names[k], S[k].p50);
        printf("SMOLFIRE_METRIC %s_p95_ns=%" PRIu64 "\n", names[k], S[k].p95);
        printf("SMOLFIRE_METRIC %s_p99_ns=%" PRIu64 "\n", names[k], S[k].p99);
        printf("SMOLFIRE_METRIC %s_min_ns=%" PRIu64 "\n", names[k], S[k].min);
        printf("SMOLFIRE_METRIC %s_max_ns=%" PRIu64 "\n", names[k], S[k].max);
        printf("SMOLFIRE_METRIC %s_mean_ns=%" PRIu64 "\n", names[k], S[k].mean);
    }
    printf("{\"schema\":\"smolfire.durable-commit-bench/v1\",\"mode\":\"%s\",\"ops\":%ld,\"recsize\":%zu,\"epoch\":%u,"
           "\"durable_seq\":%" PRIu64 ",\"visible_seq\":%" PRIu64 ",\"wall_ns\":%" PRIu64 ",\"cpu_ns\":%" PRIu64 ",\"cycles\":%" PRIu64
           ",\"cycles_available\":%s,\"bytes_payload\":%" PRIu64 ",\"bytes_block\":%" PRIu64 ",\"rss_kb\":%ld,\"maxrss_kb\":%ld,\"sync\":%d,\"fsync_fallback\":%d,\"phases\":{",
           mode, ops, recsize, epoch, durable_seq, *visible, wall, cpu, cyc, perf_fd >= 0 ? "true" : "false",
           (uint64_t)ops * recsize, io, rss, ru.ru_maxrss, do_sync, sync_fallback);
    for (int k = 0; k < 5; k++)
        printf("%s\"%s\":{\"min\":%" PRIu64 ",\"p50\":%" PRIu64 ",\"p95\":%" PRIu64 ",\"p99\":%" PRIu64 ",\"max\":%" PRIu64 ",\"mean\":%" PRIu64 "}",
               k ? "," : "", names[k], S[k].min, S[k].p50, S[k].p95, S[k].p99, S[k].max, S[k].mean);
    printf("}}\n");
    close(fd);
    return 0;
}
