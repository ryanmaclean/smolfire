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
 */
#define _GNU_SOURCE
#include <errno.h>
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
    fprintf(stderr, "usage: %s --log PATH --ops N --recsize B [--mode append|prealloc] [--epoch E] [--recover-only] [--no-sync]\n", p);
    exit(2);
}

int main(int argc, char **argv)
{
    const char *log = NULL, *mode = "append";
    long ops = 0; size_t recsize = 64; uint32_t epoch = 1; int recover_only = 0, do_sync = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--log") && i + 1 < argc) log = argv[++i];
        else if (!strcmp(argv[i], "--ops") && i + 1 < argc) ops = atol(argv[++i]);
        else if (!strcmp(argv[i], "--recsize") && i + 1 < argc) recsize = (size_t)atol(argv[++i]);
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = argv[++i];
        else if (!strcmp(argv[i], "--epoch") && i + 1 < argc) epoch = (uint32_t)atol(argv[++i]);
        else if (!strcmp(argv[i], "--recover-only")) recover_only = 1;
        else if (!strcmp(argv[i], "--no-sync")) do_sync = 0;
        else usage(argv[0]);
    }
    if (!log || recsize < sizeof(struct hdr) + 8) usage(argv[0]);

    uint64_t t_start = now_ns(CLOCK_MONOTONIC);
    int fd = open(log, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror("open"); return 1; }

    /* --- recovery --- */
    uint64_t rec0 = now_ns(CLOCK_MONOTONIC), bad = 0; uint32_t seen_epoch = 0;
    uint64_t durable_seq = recover(fd, recsize, &seen_epoch, &bad);
    uint64_t rec_ns = now_ns(CLOCK_MONOTONIC) - rec0;
    struct stat st; fstat(fd, &st);
    printf("SMOLFIRE_METRIC recovery_ns=%" PRIu64 "\n", rec_ns);
    printf("SMOLFIRE_METRIC recovery_records=%" PRIu64 "\n", durable_seq);
    printf("SMOLFIRE_METRIC recovery_bad_tail=%" PRIu64 "\n", bad);
    printf("SMOLFIRE_METRIC recovery_bytes_scanned=%lld\n", (long long)st.st_size);
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
        uint64_t a = now_ns(CLOCK_MONOTONIC);
        /* construct */
        struct hdr h = { MAGIC, epoch, seq, (uint32_t)plen, 0 };
        memcpy(rec, &h, sizeof h);
        for (size_t k = 0; k < plen; k++) rec[sizeof h + k] = (uint8_t)(seq + k);
        h.crc = crc32_ieee(rec, recsize, 0);
        memcpy(rec, &h, sizeof h);
        uint64_t b = now_ns(CLOCK_MONOTONIC);
        /* append */
        off_t off = (off_t)(seq - 1) * (off_t)recsize;
        if (pwrite(fd, rec, recsize, off) != (ssize_t)recsize) { perror("pwrite"); return 1; }
        uint64_t c = now_ns(CLOCK_MONOTONIC);
        /* durable */
        if (do_sync) {
            if (fdatasync(fd) != 0) {
                if (errno == EINVAL) { sync_fallback = 1; if (fsync(fd) != 0) { perror("fsync"); return 1; } }
                else { perror("fdatasync"); return 1; }
            }
        }
        uint64_t d = now_ns(CLOCK_MONOTONIC);
        /* publish */
        durable_seq = seq;
        __atomic_store_n(visible, seq, __ATOMIC_RELEASE);
        uint64_t e = now_ns(CLOCK_MONOTONIC);
        t_con[i] = b - a; t_app[i] = c - b; t_dur[i] = d - c; t_pub[i] = e - d; t_tot[i] = e - a;
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
