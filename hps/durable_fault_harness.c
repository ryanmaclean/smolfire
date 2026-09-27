/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * durable_fault_harness.c -- smolFire #88: software fault-injection controller
 * around the #86 durable-commit writer (hps/durable_commit_bench.c, model B:
 * seq = durable_seq+1, exactly one outstanding op).
 *
 * Subcommands
 *   crash  N iterations of: spawn writer -> SIGKILL it -> independent scan ->
 *          timed recovery (writer --recover-only --repair) -> post-scan ->
 *          invariant check. Kill points:
 *            stop:     writer raise(SIGSTOP)s at an exact phase boundary
 *                      (construct, construct-mid, append, append-mid[chunk],
 *                      durable, publish, ack, done); controller sends SIGKILL.
 *            external: controller sends SIGKILL after a random delay (lands
 *                      anywhere, mostly inside the pwrite() syscall on exFAT).
 *            errno:    writer is told its append/fdatasync failed (EIO/ENOSPC).
 *   fill   repeat: fresh small filesystem -> writer appends until the kernel
 *          returns ENOSPC or EIO -> remount -> recovery -> invariant check.
 *            tmpfs-enospc  tmpfs with size= limit
 *            vfat-enospc   FAT image file on the bench dir (real SD), loop, sync
 *            vfat-eio      sparse FAT image on a size-limited tmpfs, loop, sync;
 *                          when the tmpfs is full the loop driver fails the bio
 *                          and the filesystem above sees EIO
 *   mkfat IMAGE KB [sparse]   format a FAT12/16 image (no external mkfs)
 *
 * Invariants checked per injected fault (violations are counted, never hidden):
 *   acked_lost       a seq acknowledged on the ack pipe is not recovered
 *   phantom          recovered > last_acked+1 (more than the one in-flight op)
 *   oracle_mismatch  writer recovery != this file's independent scan
 *   torn_exposed     after repair the log is not exactly `recovered` valid
 *                    records (torn/partial bytes survive past the recovery point)
 *   resurrection     a CRC-valid record appears after the first bad one
 *   epoch_regress    epochs decrease along the recovered prefix
 *   ack_gap          acks not contiguous from the pre-run durable seq
 *   not_killed       a crash iteration did not die by SIGKILL
 * Reads use O_DIRECT where the filesystem supports it (exFAT, vfat) so the
 * scan sees what the device returns, not the page cache; tmpfs falls back.
 *
 * Output: one JSON object per iteration (the exact input trace + fault point +
 * oracle result + recovered state + divergence), then SMOLFIRE_METRIC summary
 * lines for bin/bench-record.nu and a JSON summary on stdout.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/loop.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAGIC 0x53464443u
struct hdr { uint32_t magic, epoch; uint64_t seq; uint32_t len, crc; };
struct phase_page { uint32_t phase, chunk; uint64_t seq, acked; };
enum { PH_START, PH_RECOVER, PH_CONSTRUCT, PH_CONSTRUCT_MID, PH_APPEND, PH_APPEND_MID,
       PH_DURABLE, PH_PUBLISH, PH_ACK, PH_DONE, PH_N };
static const char *const ph_name[PH_N] = { "start", "recover", "construct", "construct-mid", "append",
    "append-mid", "durable", "publish", "ack", "done" };
/* boundaries a stop-kill may target (start/recover are only hit externally) */
static const int stop_targets[] = { PH_CONSTRUCT, PH_CONSTRUCT_MID, PH_APPEND, PH_APPEND_MID,
    PH_DURABLE, PH_PUBLISH, PH_ACK, PH_DONE };
#define N_STOP ((int)(sizeof stop_targets / sizeof stop_targets[0]))

static int ph_lookup_idx(const char *s)
{
    for (int i = 0; s && i < PH_N; i++) if (!strcmp(ph_name[i], s)) return i;
    return PH_START;
}

static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }

/* ---------------- utilities ---------------- */
static uint64_t now_ns(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static uint64_t rng;
static uint64_t rnd(void) { rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27; return rng * 0x2545F4914F6CDD1Dull; }
static uint64_t rnd_below(uint64_t n) { return n ? rnd() % n : 0; }

static uint32_t crc32_ieee(const uint8_t *b, size_t n, uint32_t c)
{
    c = ~c;
    for (size_t i = 0; i < n; i++) { c ^= b[i]; for (int k = 0; k < 8; k++) c = (c & 1u) ? (c >> 1) ^ 0xEDB88320u : c >> 1; }
    return ~c;
}
static int cmp_u64(const void *a, const void *b)
{ uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }

struct series { uint64_t *v; size_t n, cap; };
static void push(struct series *s, uint64_t x)
{
    if (s->n == s->cap) { s->cap = s->cap ? s->cap * 2 : 256; s->v = realloc(s->v, s->cap * sizeof *s->v); }
    s->v[s->n++] = x;
}
static uint64_t pct(struct series *s, int p)
{
    if (!s->n) return 0;
    qsort(s->v, s->n, sizeof *s->v, cmp_u64);
    size_t i = (s->n * (size_t)p) / 100; if (i >= s->n) i = s->n - 1;
    return s->v[i];
}

/* ---------------- independent log scan (the oracle) ---------------- */
enum { TAIL_CLEAN, TAIL_PARTIAL, TAIL_BAD_RECORD };
static const char *const tail_name[] = { "clean", "partial", "bad-record" };
struct scan { int direct, err; int64_t size; uint64_t prefix, resurrect, tail_bytes, ns; int tail, epoch_regress; uint32_t max_epoch; };

static int rec_ok(const uint8_t *r, size_t recsize, uint64_t want_seq, uint32_t *epoch)
{
    struct hdr h; memcpy(&h, r, sizeof h);
    if (h.magic != MAGIC || h.len != recsize - sizeof h) return 0;
    if (want_seq && h.seq != want_seq) return 0;
    uint8_t *t = malloc(recsize); memcpy(t, r, recsize);
    struct hdr z = h; z.crc = 0; memcpy(t, &z, sizeof z);
    int ok = crc32_ieee(t, recsize, 0) == h.crc;
    for (size_t k = 0; ok && k < h.len; k++) if (r[sizeof h + k] != (uint8_t)(h.seq + k)) ok = 0;
    free(t);
    if (ok && epoch) *epoch = h.epoch;
    return ok;
}

static void scan_log(const char *path, size_t recsize, int want_direct, struct scan *s)
{
    memset(s, 0, sizeof *s);
    uint64_t t0 = now_ns();
    int fd = -1;
    if (want_direct && (fd = open(path, O_RDONLY | O_DIRECT | O_CLOEXEC)) >= 0) s->direct = 1;
    if (fd < 0) fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { s->err = errno == ENOENT ? 0 : errno; s->ns = now_ns() - t0; return; }
    struct stat st; fstat(fd, &st); s->size = st.st_size;
    size_t cap = ((size_t)st.st_size + 8191) & ~(size_t)4095;
    uint8_t *buf; if (posix_memalign((void **)&buf, 4096, cap ? cap : 4096)) { s->err = ENOMEM; close(fd); return; }
    size_t got = 0;
    for (;;) {
        size_t want = cap - got; if (want > (1u << 20)) want = 1u << 20;
        if (!want) break;
        ssize_t r = pread(fd, buf + got, want, (off_t)got);
        if (r < 0 && errno == EINVAL && s->direct) { /* fs refused O_DIRECT reads */
            close(fd); fd = open(path, O_RDONLY | O_CLOEXEC); s->direct = 0; got = 0;
            if (fd < 0) { s->err = errno; free(buf); return; }
            continue;
        }
        if (r < 0) { s->err = errno; break; }
        got += (size_t)r;
        if ((size_t)r < want) break;
    }
    close(fd);
    if (got > (size_t)st.st_size) got = (size_t)st.st_size;
    uint64_t n = got / recsize, i; uint32_t ep = 0, prev = 0;
    for (i = 0; i < n; i++) {
        if (!rec_ok(buf + i * recsize, recsize, i + 1, &ep)) break;
        if (ep < prev) s->epoch_regress = 1;
        prev = ep; if (ep > s->max_epoch) s->max_epoch = ep;
    }
    s->prefix = i;
    for (uint64_t j = i + 1; j < n; j++) if (rec_ok(buf + j * recsize, recsize, 0, NULL)) s->resurrect++;
    s->tail_bytes = got - s->prefix * recsize;
    s->tail = !s->tail_bytes ? TAIL_CLEAN : s->tail_bytes < recsize ? TAIL_PARTIAL : TAIL_BAD_RECORD;
    free(buf);
    s->ns = now_ns() - t0;
}

/* ---------------- process control ---------------- */
static int devnull = -1;
static const char *g_mutant; /* --mutant: passed to the writer as --mutate (oracle self-test) */
/* fds: 3 = ack pipe write end, 4 = phase memfd, 1+2 = out (pipe or /dev/null) */
static pid_t spawn(char *const argv[], int ackw, int phasefd, int outfd)
{
    pid_t p = fork();
    if (p) return p;
    int a = ackw >= 0 ? fcntl(ackw, F_DUPFD, 10) : -1, f = phasefd >= 0 ? fcntl(phasefd, F_DUPFD, 10) : -1;
    int o = fcntl(outfd >= 0 ? outfd : devnull, F_DUPFD, 10);
    dup2(o, 1); dup2(o, 2);
    if (a >= 0) dup2(a, 3);
    if (f >= 0) dup2(f, 4);
    signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL); signal(SIGPIPE, SIG_DFL);
    execv(argv[0], argv);
    _exit(127);
}
static size_t drain(int fd, char *buf, size_t cap)
{
    size_t n = 0; ssize_t r;
    while (n + 1 < cap && (r = read(fd, buf + n, cap - 1 - n)) > 0) n += (size_t)r;
    buf[n] = 0; return n;
}
static uint64_t metric(const char *out, const char *key)
{
    char k[96]; snprintf(k, sizeof k, "SMOLFIRE_METRIC %s=", key);
    const char *p = strstr(out, k); return p ? strtoull(p + strlen(k), NULL, 10) : 0;
}

struct recov { uint64_t recovered, rec_ns, wall_ns, repaired; int status; };
static void run_recovery(const char *writer, const char *log, size_t recsize, struct recov *r)
{
    char rs[32]; snprintf(rs, sizeof rs, "%zu", recsize);
    char *argv[] = { (char *)writer, "--log", (char *)log, "--recsize", rs, "--ops", "0", "--recover-only", "--repair",
                     g_mutant ? "--mutate" : NULL, (char *)g_mutant, NULL };
    int pfd[2]; if (pipe2(pfd, O_CLOEXEC)) { perror("pipe"); exit(1); }
    uint64_t t0 = now_ns();
    pid_t p = spawn(argv, -1, -1, pfd[1]);
    close(pfd[1]);
    static char out[8192]; drain(pfd[0], out, sizeof out); close(pfd[0]);
    int st; waitpid(p, &st, 0);
    r->wall_ns = now_ns() - t0;
    r->status = st;
    r->recovered = metric(out, "recovery_records");
    r->rec_ns = metric(out, "recovery_ns");
    r->repaired = metric(out, "recovery_repaired_bytes");
}

/* ---------------- shared accounting ---------------- */
struct totals {
    uint64_t faults, crashes, crash_stop, crash_ext, errno_faults, completed, fill_faults, violations;
    uint64_t v_acked_lost, v_phantom, v_oracle, v_torn, v_resurrect, v_epoch, v_ackgap, v_notkilled, v_recovery_failed;
    uint64_t torn_detected, bad_record_detected, durable_unacked, direct_scans, acked_total, repaired_bytes;
    uint64_t kill_phase[PH_N], unacked_by_target[PH_N], stop_by_target[PH_N];
    uint64_t err_enospc, err_eio, err_other, fsync_retry_ok, fsync_retry_err;
    struct series rec_ns, restart_ns, kill_to_recovered_ns;
};
static struct totals T;
static FILE *jl;

struct fault_ctx {
    const char *kind, *target; long target_op, target_chunk; uint64_t delay_us; long ops; int split; size_t recsize;
    uint64_t base, last_acked, n_acks; int ack_gap; int status; const char *phase_at_kill; uint64_t seq_at_kill;
    int fault_errno; const char *fault_phase; int retry_rc, retry_errno; uint64_t kill_to_reap_ns;
};

/* check invariants, update totals, emit one JSON line; returns recovered seq */
static uint64_t verify_and_log(uint64_t iter, const char *mode, const char *fs, const char *log, int want_direct,
                               const char *writer, struct fault_ctx *c, int expect, int count_fault, uint64_t t_fault,
                               void (*remount)(void))
{
    struct scan cached, pre, post; struct recov rv;
    /* scan once as the crashed process left it (page cache), then, for loop
     * filesystems, unmount/remount so the oracle and recovery read the device */
    scan_log(log, c->recsize, want_direct, &cached);
    if (remount) remount();
    scan_log(log, c->recsize, want_direct, &pre);
    run_recovery(writer, log, c->recsize, &rv);
    uint64_t t_rec = now_ns();
    scan_log(log, c->recsize, want_direct, &post);

    char v[256] = ""; int nv = 0;
#define VIOL(cond, name, ctr) do { if (cond) { strcat(v, nv++ ? ",\"" name "\"" : "\"" name "\""); T.ctr++; } } while (0)
    int rec_fail = !WIFEXITED(rv.status) || WEXITSTATUS(rv.status) != 0;
    VIOL(rec_fail, "recovery_failed", v_recovery_failed);
    VIOL(rv.recovered < c->last_acked, "acked_lost", v_acked_lost);
    VIOL(rv.recovered > c->last_acked + 1, "phantom", v_phantom);
    VIOL(pre.prefix != rv.recovered, "oracle_mismatch", v_oracle);
    VIOL(post.tail != TAIL_CLEAN || post.prefix != rv.recovered || (uint64_t)post.size != rv.recovered * c->recsize, "torn_exposed", v_torn);
    VIOL(pre.resurrect > 0, "resurrection", v_resurrect);
    VIOL(pre.epoch_regress || post.epoch_regress, "epoch_regress", v_epoch);
    VIOL(c->ack_gap, "ack_gap", v_ackgap);
    /* expect: 1 = died by SIGKILL, 2 = clean fault exit (status 3, one SMOLFIRE_FAULT line) */
    VIOL(expect == 1 && !(WIFSIGNALED(c->status) && WTERMSIG(c->status) == SIGKILL), "not_killed", v_notkilled);
    VIOL(expect == 2 && !(WIFEXITED(c->status) && WEXITSTATUS(c->status) == 3 && c->fault_phase), "unexpected_exit", v_notkilled);
    T.violations += (uint64_t)nv;
    if (count_fault) T.faults++;
    if (pre.tail == TAIL_PARTIAL) T.torn_detected++;
    if (pre.tail == TAIL_BAD_RECORD) T.bad_record_detected++;
    int unacked = rv.recovered == c->last_acked + 1;
    if (unacked) T.durable_unacked++;
    T.direct_scans += (uint64_t)pre.direct;
    T.acked_total += c->n_acks;
    T.repaired_bytes += rv.repaired;
    push(&T.rec_ns, rv.rec_ns); push(&T.restart_ns, rv.wall_ns); push(&T.kill_to_recovered_ns, t_rec - t_fault);

    fprintf(jl, "{\"i\":%" PRIu64 ",\"mode\":\"%s\",\"fs\":\"%s\",\"log\":\"%s\",\"kind\":\"%s\",\"target\":\"%s\",\"target_op\":%ld,"
            "\"target_chunk\":%ld,\"delay_us\":%" PRIu64 ",\"ops\":%ld,\"split\":%d,\"recsize\":%zu,"
            "\"exit\":%d,\"signal\":%d,\"phase_at_fault\":\"%s\",\"seq_at_fault\":%" PRIu64 ",\"fault_errno\":%d,\"fault_phase\":\"%s\","
            "\"sync_retry_rc\":%d,\"sync_retry_errno\":%d,"
            "\"base_seq\":%" PRIu64 ",\"acks\":%" PRIu64 ",\"last_acked\":%" PRIu64 ","
            "\"cached_prefix\":%" PRIu64 "," "\"pre\":{\"direct\":%d,\"size\":%lld,\"prefix\":%" PRIu64 ",\"tail\":\"%s\",\"tail_bytes\":%" PRIu64 ",\"resurrect\":%" PRIu64 ",\"err\":%d},"
            "\"recovered\":%" PRIu64 ",\"durable_unacked\":%d,\"repaired_bytes\":%" PRIu64 ",\"recovery_ns\":%" PRIu64 ",\"restart_wall_ns\":%" PRIu64 ","
            "\"kill_to_reap_ns\":%" PRIu64 ",\"fault_to_recovered_ns\":%" PRIu64 ","
            "\"post\":{\"direct\":%d,\"size\":%lld,\"prefix\":%" PRIu64 ",\"tail\":\"%s\"},\"fpga\":null,\"violations\":[%s],\"ok\":%s}\n",
            iter, mode, fs, log, c->kind, c->target ? c->target : "", c->target_op, c->target_chunk, c->delay_us, c->ops, c->split, c->recsize,
            WIFEXITED(c->status) ? WEXITSTATUS(c->status) : -1, WIFSIGNALED(c->status) ? WTERMSIG(c->status) : 0,
            c->phase_at_kill ? c->phase_at_kill : "", c->seq_at_kill, c->fault_errno, c->fault_phase ? c->fault_phase : "",
            c->retry_rc, c->retry_errno, c->base, c->n_acks, c->last_acked,
            cached.prefix,
            pre.direct, (long long)pre.size, pre.prefix, tail_name[pre.tail], pre.tail_bytes, pre.resurrect, pre.err,
            rv.recovered, unacked, rv.repaired, rv.rec_ns, rv.wall_ns, c->kill_to_reap_ns, t_rec - t_fault,
            post.direct, (long long)post.size, post.prefix, tail_name[post.tail], v, nv ? "false" : "true");
    fflush(jl);
    return rv.recovered;
}

/* read acks: contiguous seq values, base+1.. */
static void read_acks(int ackr, struct fault_ctx *c)
{
    uint64_t s; c->last_acked = c->base; c->n_acks = 0; c->ack_gap = 0;
    while (read(ackr, &s, sizeof s) == (ssize_t)sizeof s) {
        if (s != c->last_acked + 1) c->ack_gap = 1;
        c->last_acked = s; c->n_acks++;
    }
}
static void parse_fault(const char *out, struct fault_ctx *c)
{
    const char *p = strstr(out, "SMOLFIRE_FAULT ");
    static char ph[32]; c->fault_phase = NULL;
    if (!p) return;
    if (sscanf(p, "SMOLFIRE_FAULT phase=%31s errno=%d", ph, &c->fault_errno) == 2) c->fault_phase = ph;
    const char *q = strstr(p, "retry_rc="); if (q) c->retry_rc = atoi(q + 9);
    q = strstr(p, "retry_errno="); if (q) c->retry_errno = atoi(q + 12);
}

static void summary(const char *mode, const char *fs, uint64_t seed)
{
    printf("SMOLFIRE_METRIC faults_injected=%" PRIu64 "\n", T.faults);
    printf("SMOLFIRE_METRIC crashes_sigkill=%" PRIu64 "\n", T.crashes);
    printf("SMOLFIRE_METRIC crashes_stop_boundary=%" PRIu64 "\n", T.crash_stop);
    printf("SMOLFIRE_METRIC crashes_external_random=%" PRIu64 "\n", T.crash_ext);
    printf("SMOLFIRE_METRIC errno_faults=%" PRIu64 "\n", T.errno_faults);
    printf("SMOLFIRE_METRIC fill_faults=%" PRIu64 "\n", T.fill_faults);
    printf("SMOLFIRE_METRIC runs_completed_before_kill=%" PRIu64 "\n", T.completed);
    printf("SMOLFIRE_METRIC violations=%" PRIu64 "\n", T.violations);
    printf("SMOLFIRE_METRIC violation_acked_lost=%" PRIu64 "\n", T.v_acked_lost);
    printf("SMOLFIRE_METRIC violation_phantom=%" PRIu64 "\n", T.v_phantom);
    printf("SMOLFIRE_METRIC violation_oracle_mismatch=%" PRIu64 "\n", T.v_oracle);
    printf("SMOLFIRE_METRIC violation_torn_exposed=%" PRIu64 "\n", T.v_torn);
    printf("SMOLFIRE_METRIC violation_resurrection=%" PRIu64 "\n", T.v_resurrect);
    printf("SMOLFIRE_METRIC violation_epoch_regress=%" PRIu64 "\n", T.v_epoch);
    printf("SMOLFIRE_METRIC violation_ack_gap=%" PRIu64 "\n", T.v_ackgap);
    printf("SMOLFIRE_METRIC violation_not_killed=%" PRIu64 "\n", T.v_notkilled);
    printf("SMOLFIRE_METRIC violation_recovery_failed=%" PRIu64 "\n", T.v_recovery_failed);
    printf("SMOLFIRE_METRIC torn_partial_detected=%" PRIu64 "\n", T.torn_detected);
    printf("SMOLFIRE_METRIC bad_record_detected=%" PRIu64 "\n", T.bad_record_detected);
    printf("SMOLFIRE_METRIC durable_unacked=%" PRIu64 "\n", T.durable_unacked);
    printf("SMOLFIRE_METRIC acked_records=%" PRIu64 "\n", T.acked_total);
    printf("SMOLFIRE_METRIC repaired_bytes=%" PRIu64 "\n", T.repaired_bytes);
    printf("SMOLFIRE_METRIC direct_io_scans=%" PRIu64 "\n", T.direct_scans);
    for (int p = 0; p < PH_N; p++) if (T.kill_phase[p]) printf("SMOLFIRE_METRIC kill_phase_%s=%" PRIu64 "\n", ph_name[p], T.kill_phase[p]);
    for (int p = 0; p < PH_N; p++) if (T.stop_by_target[p]) {
        printf("SMOLFIRE_METRIC stop_%s=%" PRIu64 "\n", ph_name[p], T.stop_by_target[p]);
        printf("SMOLFIRE_METRIC stop_%s_durable_unacked=%" PRIu64 "\n", ph_name[p], T.unacked_by_target[p]);
    }
    printf("SMOLFIRE_METRIC fault_enospc=%" PRIu64 "\nSMOLFIRE_METRIC fault_eio=%" PRIu64 "\nSMOLFIRE_METRIC fault_other_errno=%" PRIu64 "\n",
           T.err_enospc, T.err_eio, T.err_other);
    printf("SMOLFIRE_METRIC sync_retry_returned_ok=%" PRIu64 "\nSMOLFIRE_METRIC sync_retry_returned_err=%" PRIu64 "\n",
           T.fsync_retry_ok, T.fsync_retry_err);
    struct series *S[3] = { &T.rec_ns, &T.restart_ns, &T.kill_to_recovered_ns };
    const char *nm[3] = { "recovery_scan", "recovery_restart", "fault_to_recovered" };
    for (int k = 0; k < 3; k++) {
        printf("SMOLFIRE_METRIC %s_p50_ns=%" PRIu64 "\n", nm[k], pct(S[k], 50));
        printf("SMOLFIRE_METRIC %s_p95_ns=%" PRIu64 "\n", nm[k], pct(S[k], 95));
        printf("SMOLFIRE_METRIC %s_p99_ns=%" PRIu64 "\n", nm[k], pct(S[k], 99));
        printf("SMOLFIRE_METRIC %s_max_ns=%" PRIu64 "\n", nm[k], pct(S[k], 100));
    }
    printf("{\"schema\":\"smolfire.fault-harness/v1\",\"mode\":\"%s\",\"fs\":\"%s\",\"mutant\":\"%s\",\"seed\":%" PRIu64 ",\"faults\":%" PRIu64
           ",\"crashes\":%" PRIu64 ",\"violations\":%" PRIu64 ",\"acked_lost\":%" PRIu64 ",\"torn_exposed\":%" PRIu64
           ",\"torn_detected\":%" PRIu64 ",\"durable_unacked\":%" PRIu64 ",\"restart_p50_ns\":%" PRIu64 ",\"restart_p99_ns\":%" PRIu64 ",\"ok\":%s}\n",
           mode, fs, g_mutant ? g_mutant : "", seed, T.faults, T.crashes, T.violations, T.v_acked_lost, T.v_torn, T.torn_detected, T.durable_unacked,
           pct(&T.restart_ns, 50), pct(&T.restart_ns, 99), T.violations ? "false" : "true");
}

/* ---------------- crash mode ---------------- */
static int cmd_crash(int argc, char **argv)
{
    const char *writer = NULL, *dir = NULL, *fs = "unknown", *out = NULL;
    long iters = 1000, max_ops = 16, rotate = 100; uint64_t seed = 88, max_delay_us = 40000;
    size_t recsize = 64; int split = 4, ext_pct = 35, errno_pct = 5, direct = 1;
    for (int i = 2; i + 1 < argc; i += 2) {
        const char *k = argv[i], *v = argv[i + 1];
        if (!strcmp(k, "--writer")) writer = v; else if (!strcmp(k, "--dir")) dir = v;
        else if (!strcmp(k, "--fs")) fs = v; else if (!strcmp(k, "--jsonl")) out = v;
        else if (!strcmp(k, "--iterations")) iters = atol(v); else if (!strcmp(k, "--max-ops")) max_ops = atol(v);
        else if (!strcmp(k, "--rotate")) rotate = atol(v); else if (!strcmp(k, "--seed")) seed = strtoull(v, NULL, 0);
        else if (!strcmp(k, "--max-delay-us")) max_delay_us = strtoull(v, NULL, 0);
        else if (!strcmp(k, "--recsize")) recsize = (size_t)atol(v); else if (!strcmp(k, "--split")) split = atoi(v);
        else if (!strcmp(k, "--external-pct")) ext_pct = atoi(v); else if (!strcmp(k, "--errno-pct")) errno_pct = atoi(v);
        else if (!strcmp(k, "--direct")) direct = atoi(v);
        else if (!strcmp(k, "--mutant")) g_mutant = v;
        else { fprintf(stderr, "crash: unknown option %s\n", k); return 2; }
    }
    if (!writer || !dir || !out || max_ops < 1 || rotate < 1) {
        fprintf(stderr, "usage: crash --writer W --dir D --jsonl OUT [--fs TAG] [--iterations N] [--seed S] [--recsize B] [--split K]\n"
                        "             [--max-ops M] [--rotate R] [--external-pct P] [--errno-pct P] [--max-delay-us U] [--direct 0|1] [--mutant ack-early|no-repair]\n");
        return 2;
    }
    rng = seed ? seed : 88;
    if (!(jl = fopen(out, "a"))) { perror(out); return 1; }
    int memfd = (int)syscall(SYS_memfd_create, "sf-phase", 0);
    if (memfd < 0 || ftruncate(memfd, 4096)) { perror("memfd"); return 1; }
    struct phase_page *pp = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0);
    if (pp == MAP_FAILED) { perror("mmap"); return 1; }
    fcntl(memfd, F_SETFD, FD_CLOEXEC);

    char log[512]; uint64_t base = 0; long gen = -1;
    for (long it = 0; it < iters && !g_stop; it++) {
        if (it / rotate != gen) {
            gen = it / rotate;
            snprintf(log, sizeof log, "%s/crash-%s-%ld.log", dir, fs, gen);
            struct scan s0; scan_log(log, recsize, direct, &s0); base = s0.prefix; /* resume-safe */
        }
        struct fault_ctx c = { 0 }; c.recsize = recsize; c.base = base; c.split = split; c.target_chunk = 0;
        uint64_t roll = rnd_below(100);
        char a_ops[24], a_rs[24], a_sp[24], a_stop[64] = "", a_fail[64] = "";
        int is_stop = 0, is_ext = 0, is_errno = 0;
        if (roll < (uint64_t)errno_pct) {
            is_errno = 1; c.kind = "errno";
            int ph = rnd_below(2) ? PH_APPEND : PH_DURABLE; int e = rnd_below(2) ? EIO : ENOSPC;
            c.target = ph_name[ph]; c.target_op = (long)rnd_below((uint64_t)max_ops); c.ops = c.target_op + 1;
            snprintf(a_fail, sizeof a_fail, "%s:%ld:%d", ph_name[ph], c.target_op, e);
        } else if (roll < (uint64_t)(errno_pct + ext_pct)) {
            is_ext = 1; c.kind = "external";
            c.delay_us = rnd_below(max_delay_us + 1);
        } else {
            is_stop = 1; c.kind = "stop";
            int ph = stop_targets[rnd_below(N_STOP)];
            c.target = ph_name[ph]; c.target_op = (long)rnd_below((uint64_t)max_ops); c.ops = c.target_op + 1;
            if (ph == PH_APPEND_MID) c.target_chunk = 1 + (long)rnd_below((uint64_t)(split > 1 ? split - 1 : 1));
            snprintf(a_stop, sizeof a_stop, "%s:%ld:%ld", ph_name[ph], c.target_op, c.target_chunk);
            T.stop_by_target[ph]++;
        }
        /* external: enough ops to outlast the delay window at >=10 us/op, capped so
         * <=7000 8-byte acks fit the 64 KiB pipe (the writer must never block on ack) */
        if (is_ext) c.ops = (long)(max_delay_us / 10 + 64) < 7000 ? (long)(max_delay_us / 10 + 64) : 7000;
        snprintf(a_ops, sizeof a_ops, "%ld", c.ops); snprintf(a_rs, sizeof a_rs, "%zu", recsize); snprintf(a_sp, sizeof a_sp, "%d", split);
        char *av[24]; int n = 0;
        av[n++] = (char *)writer; av[n++] = "--log"; av[n++] = log; av[n++] = "--ops"; av[n++] = a_ops;
        av[n++] = "--recsize"; av[n++] = a_rs; av[n++] = "--split"; av[n++] = a_sp;
        av[n++] = "--ack-fd"; av[n++] = "3"; av[n++] = "--phase-fd"; av[n++] = "4";
        if (is_stop) { av[n++] = "--stop-at"; av[n++] = a_stop; }
        if (is_errno) { av[n++] = "--fail"; av[n++] = a_fail; }
        if (g_mutant) { av[n++] = "--mutate"; av[n++] = (char *)g_mutant; }
        av[n] = NULL;

        memset(pp, 0, sizeof *pp);
        int ap[2], op[2];
        if (pipe2(ap, O_CLOEXEC) || pipe2(op, O_CLOEXEC)) { perror("pipe"); return 1; }
        pid_t p = spawn(av, ap[1], memfd, op[1]);
        close(ap[1]); close(op[1]);
        int st = 0; uint64_t t_kill = 0;
        if (is_stop) {
            waitpid(p, &st, WUNTRACED);
            if (WIFSTOPPED(st)) { t_kill = now_ns(); kill(p, SIGKILL); waitpid(p, &st, 0); }
        } else if (is_ext) {
            struct timespec ts = { (time_t)(c.delay_us / 1000000), (long)(c.delay_us % 1000000) * 1000 };
            nanosleep(&ts, NULL);
            t_kill = now_ns(); kill(p, SIGKILL); waitpid(p, &st, 0);
        } else {
            waitpid(p, &st, 0); t_kill = now_ns();
        }
        c.kill_to_reap_ns = now_ns() - t_kill;
        c.status = st;
        uint32_t ph = __atomic_load_n(&pp->phase, __ATOMIC_ACQUIRE);
        c.phase_at_kill = ph < PH_N ? ph_name[ph] : "?"; c.seq_at_kill = pp->seq;
        read_acks(ap[0], &c); close(ap[0]);
        static char outbuf[16384]; drain(op[0], outbuf, sizeof outbuf); close(op[0]);
        parse_fault(outbuf, &c);

        int killed = WIFSIGNALED(st) && WTERMSIG(st) == SIGKILL;
        if (is_ext && !killed) { T.completed++; c.kind = "external-completed"; }
        if (killed) { T.crashes++; if (is_stop) T.crash_stop++; else T.crash_ext++; if (ph < PH_N) T.kill_phase[ph]++; }
        if (is_errno) {
            T.errno_faults++;
            if (c.fault_errno == ENOSPC) T.err_enospc++; else if (c.fault_errno == EIO) T.err_eio++; else T.err_other++;
        }
        uint64_t rec = verify_and_log((uint64_t)it, "crash", fs, log, direct, writer, &c,
                                      is_errno ? 2 : (is_stop || killed) ? 1 : 0, !(is_ext && !killed), t_kill, NULL);
        if (is_stop && rec == c.last_acked + 1) T.unacked_by_target[ph_lookup_idx(c.target)]++;
        base = rec;
    }
    fclose(jl);
    summary("crash", fs, seed);
    return T.violations ? 3 : 0;
}

/* ---------------- FAT12/16 formatter (no external mkfs dependency) ---------------- */
static void put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, v); put16(p + 2, v >> 16); }

/* 512-byte sectors, 1 sector/cluster, 2 FATs, 512 root entries. sparse=1:
 * write only the metadata (image may live on a size-limited tmpfs). */
static int mkfat(const char *path, uint32_t kb, int sparse)
{
    const uint32_t rsv = 1, nfats = 2, root_secs = 32, sectors = kb * 2;
    uint32_t fatsz = 1, clusters = 0; int fat16 = 0;
    for (;;) {
        clusters = sectors - rsv - nfats * fatsz - root_secs;
        fat16 = clusters >= 4085;
        uint32_t need = fat16 ? (clusters + 2) * 2 : ((clusters + 2) * 3 + 1) / 2;
        uint32_t nf = (need + 511) / 512;
        if (nf <= fatsz) break;
        fatsz = nf;
    }
    if (clusters >= 65525 || kb < 64) { fprintf(stderr, "mkfat: %u KiB out of range\n", kb); return -1; }
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) { perror(path); return -1; }
    struct stat st; fstat(fd, &st);
    if (st.st_size != (off_t)sectors * 512) {
        if (ftruncate(fd, 0) || ftruncate(fd, (off_t)sectors * 512)) { perror("mkfat truncate"); close(fd); return -1; }
        if (!sparse) { /* allocate every block now so the loop fs never extends the host file */
            uint8_t *z = calloc(1, 65536);
            for (off_t o = 0; o < (off_t)sectors * 512; o += 65536)
                if (pwrite(fd, z, 65536, o) != 65536) { perror("mkfat fill"); free(z); close(fd); return -1; }
            free(z);
        }
    }
    size_t meta = (size_t)(rsv + nfats * fatsz + root_secs) * 512;
    uint8_t *m = calloc(1, meta), *b = m;
    b[0] = 0xEB; b[1] = 0x3C; b[2] = 0x90; memcpy(b + 3, "SMOLFIRE", 8);
    put16(b + 11, 512); b[13] = 1; put16(b + 14, rsv); b[16] = (uint8_t)nfats; put16(b + 17, 512);
    if (sectors < 65536) put16(b + 19, sectors); else put32(b + 32, sectors);
    b[21] = 0xF8; put16(b + 22, fatsz); put16(b + 24, 32); put16(b + 26, 64);
    b[36] = 0x80; b[38] = 0x29; put32(b + 39, 0x88088088u); memcpy(b + 43, "SMOLFIRE88 ", 11);
    memcpy(b + 54, fat16 ? "FAT16   " : "FAT12   ", 8); b[510] = 0x55; b[511] = 0xAA;
    for (uint32_t f = 0; f < nfats; f++) {
        uint8_t *fat = m + (rsv + f * fatsz) * 512;
        fat[0] = 0xF8; fat[1] = 0xFF; fat[2] = 0xFF; if (fat16) fat[3] = 0xFF;
    }
    int rc = pwrite(fd, m, meta, 0) == (ssize_t)meta && fsync(fd) == 0 ? 0 : -1;
    if (rc) perror("mkfat write");
    free(m); close(fd);
    return rc;
}

/* ---------------- mounts + loop (fill mode) ---------------- */
enum { K_TMPFS_ENOSPC, K_VFAT_ENOSPC, K_VFAT_EIO };
static const char *const kind_name[] = { "tmpfs-enospc", "vfat-enospc", "vfat-eio" };
static struct { int kind; const char *mnt, *backing; char image[512], loopdev[64]; int loopfd; uint32_t fs_kb, backing_kb; } F = { .loopfd = -1 };

static int is_mounted(const char *path)
{
    FILE *f = fopen("/proc/self/mounts", "r"); char line[1024], pat[600]; int hit = 0;
    if (!f) return 0;
    snprintf(pat, sizeof pat, " %s ", path);
    while (fgets(line, sizeof line, f)) if (strstr(line, pat)) { hit = 1; break; }
    fclose(f); return hit;
}
static int loop_attach(const char *img)
{
    int ctl = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
    if (ctl < 0) { perror("/dev/loop-control"); return -1; }
    for (int tries = 0; tries < 4; tries++) {
        int n = ioctl(ctl, LOOP_CTL_GET_FREE);
        if (n < 0) { perror("LOOP_CTL_GET_FREE"); break; }
        snprintf(F.loopdev, sizeof F.loopdev, "/dev/loop%d", n);
        int dfd = open(F.loopdev, O_RDWR | O_CLOEXEC), ffd = open(img, O_RDWR | O_CLOEXEC);
        if (dfd < 0 || ffd < 0) { perror("open loop/image"); if (dfd >= 0) close(dfd); if (ffd >= 0) close(ffd); break; }
        if (ioctl(dfd, LOOP_SET_FD, ffd) == 0) {
            struct loop_info64 li; memset(&li, 0, sizeof li);
            strncpy((char *)li.lo_file_name, img, LO_NAME_SIZE - 1);
            ioctl(dfd, LOOP_SET_STATUS64, &li);
            close(ffd); close(ctl); F.loopfd = dfd; return 0;
        }
        int e = errno; close(ffd); close(dfd);
        if (e != EBUSY) { errno = e; perror("LOOP_SET_FD"); break; }
    }
    close(ctl); return -1;
}
static void loop_detach(void)
{
    if (F.loopfd >= 0) { ioctl(F.loopfd, LOOP_CLR_FD, 0); close(F.loopfd); F.loopfd = -1; }
}
static int mount_vfat(void)
{
    if (loop_attach(F.image)) return -1;
    if (mount(F.loopdev, F.mnt, "vfat", MS_SYNCHRONOUS | MS_DIRSYNC | MS_NOATIME | MS_NOSUID | MS_NODEV | MS_NOEXEC, "")) {
        perror("mount vfat"); loop_detach(); return -1;
    }
    return 0;
}
static void unmount_upper(void)
{
    if (is_mounted(F.mnt) && umount2(F.mnt, 0)) perror("umount");
    loop_detach();
}
static void remount_vfat(void) { unmount_upper(); if (mount_vfat()) fprintf(stderr, "remount failed\n"); }
static void fill_teardown(void)
{
    if (!F.mnt) return;
    unmount_upper();
    if (F.backing && is_mounted(F.backing) && umount2(F.backing, 0)) perror("umount backing");
}
static int fill_setup(void)
{
    char opt[64];
    switch (F.kind) {
    case K_TMPFS_ENOSPC:
        snprintf(opt, sizeof opt, "size=%uk,mode=0700", F.fs_kb);
        if (mount("sf88-tmpfs", F.mnt, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, opt)) { perror("mount tmpfs"); return -1; }
        return 0;
    case K_VFAT_ENOSPC:
        if (mkfat(F.image, F.fs_kb, 0)) return -1;
        return mount_vfat();
    case K_VFAT_EIO:
        snprintf(opt, sizeof opt, "size=%uk,mode=0700", F.backing_kb);
        if (mount("sf88-backing", F.backing, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, opt)) { perror("mount backing tmpfs"); return -1; }
        if (mkfat(F.image, F.fs_kb, 1)) return -1;
        return mount_vfat();
    }
    return -1;
}
static int under(const char *path, const char *root)
{
    size_t n = strlen(root);
    return path && !strncmp(path, root, n) && (path[n] == '/' || path[n] == 0) && !strstr(path, "..");
}

static int cmd_fill(int argc, char **argv)
{
    const char *writer = NULL, *out = NULL, *root = "/media/fat/smolfire-bench", *kind = NULL, *rs_list = "64,1000,3000";
    long iters = 10; uint64_t seed = 88; int direct = 1;
    F.fs_kb = 1024; F.backing_kb = 192;
    for (int i = 2; i + 1 < argc; i += 2) {
        const char *k = argv[i], *v = argv[i + 1];
        if (!strcmp(k, "--writer")) writer = v; else if (!strcmp(k, "--jsonl")) out = v;
        else if (!strcmp(k, "--root")) root = v; else if (!strcmp(k, "--kind")) kind = v;
        else if (!strcmp(k, "--mnt")) F.mnt = v; else if (!strcmp(k, "--backing")) F.backing = v;
        else if (!strcmp(k, "--image")) snprintf(F.image, sizeof F.image, "%s", v);
        else if (!strcmp(k, "--fs-kb")) F.fs_kb = (uint32_t)atol(v); else if (!strcmp(k, "--backing-kb")) F.backing_kb = (uint32_t)atol(v);
        else if (!strcmp(k, "--iterations")) iters = atol(v); else if (!strcmp(k, "--seed")) seed = strtoull(v, NULL, 0);
        else if (!strcmp(k, "--recsizes")) rs_list = v; else if (!strcmp(k, "--direct")) direct = atoi(v);
        else { fprintf(stderr, "fill: unknown option %s\n", k); return 2; }
    }
    F.kind = -1;
    for (int k = 0; kind && k < 3; k++) if (!strcmp(kind, kind_name[k])) F.kind = k;
    if (!writer || !out || !F.mnt || F.kind < 0 || (F.kind != K_TMPFS_ENOSPC && !F.image[0]) || (F.kind == K_VFAT_EIO && !F.backing)) {
        fprintf(stderr, "usage: fill --kind tmpfs-enospc|vfat-enospc|vfat-eio --writer W --jsonl OUT --mnt DIR [--image IMG] [--backing DIR]\n"
                        "            [--fs-kb N] [--backing-kb N] [--iterations N] [--recsizes 64,1000] [--seed S] [--root /media/fat/smolfire-bench]\n");
        return 2;
    }
    /* guard: every path we mount on or format lives under --root */
    if (!under(F.mnt, root) || (F.image[0] && F.kind == K_VFAT_ENOSPC && !under(F.image, root)) ||
        (F.backing && !under(F.backing, root)) || (F.kind == K_VFAT_EIO && !under(F.image, F.backing))) {
        fprintf(stderr, "fill: refusing paths outside %s (vfat-eio image must be inside --backing)\n", root);
        return 2;
    }
    if (is_mounted(F.mnt) || (F.backing && is_mounted(F.backing))) {
        fprintf(stderr, "fill: %s already mounted (stale run?) - unmount it first\n", F.mnt); return 2;
    }
    size_t rs[16]; int nrs = 0;
    for (const char *p = rs_list; *p && nrs < 16; ) { rs[nrs++] = (size_t)strtoul(p, (char **)&p, 10); if (*p == ',') p++; else break; }
    rng = seed ? seed : 88;
    if (!(jl = fopen(out, "a"))) { perror(out); return 1; }
    atexit(fill_teardown);
    int memfd = (int)syscall(SYS_memfd_create, "sf-phase", 0);
    if (memfd < 0 || ftruncate(memfd, 4096)) { perror("memfd"); return 1; }
    struct phase_page *pp = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0);
    fcntl(memfd, F_SETFD, FD_CLOEXEC);
    char log[600]; snprintf(log, sizeof log, "%s/fill.log", F.mnt);

    for (long it = 0; it < iters && !g_stop; it++) {
        if (fill_setup()) { fill_teardown(); fclose(jl); return 1; }
        struct fault_ctx c = { 0 }; c.kind = kind_name[F.kind]; c.split = 1;
        c.recsize = rs[rnd_below((uint64_t)nrs)];
        uint64_t cap_bytes = (uint64_t)(F.kind == K_VFAT_EIO ? F.backing_kb : F.fs_kb) * 1024;
        c.ops = (long)(cap_bytes / c.recsize) * 2 + 64;
        char a_ops[24], a_rs[24];
        snprintf(a_ops, sizeof a_ops, "%ld", c.ops); snprintf(a_rs, sizeof a_rs, "%zu", c.recsize);
        char *av[] = { (char *)writer, "--log", log, "--ops", a_ops, "--recsize", a_rs, "--ack-fd", "3", "--phase-fd", "4",
                       "--sync-retry", NULL };
        memset(pp, 0, sizeof *pp);
        int ap[2], op[2];
        if (pipe2(ap, O_CLOEXEC) || pipe2(op, O_CLOEXEC)) { perror("pipe"); return 1; }
        /* acks can exceed the 64 KiB pipe buffer here: read them while the writer runs */
        pid_t p = spawn(av, ap[1], memfd, op[1]);
        close(ap[1]); close(op[1]);
        c.last_acked = 0; c.n_acks = 0;
        uint64_t s;
        while (read(ap[0], &s, sizeof s) == (ssize_t)sizeof s) { if (s != c.last_acked + 1) c.ack_gap = 1; c.last_acked = s; c.n_acks++; }
        close(ap[0]);
        static char outbuf[16384]; drain(op[0], outbuf, sizeof outbuf); close(op[0]);
        int st; waitpid(p, &st, 0);
        uint64_t t_fault = now_ns();
        c.status = st;
        uint32_t ph = pp->phase; c.phase_at_kill = ph < PH_N ? ph_name[ph] : "?"; c.seq_at_kill = pp->seq;
        parse_fault(outbuf, &c);
        T.fill_faults++;
        if (c.fault_errno == ENOSPC) T.err_enospc++; else if (c.fault_errno == EIO) T.err_eio++; else T.err_other++;
        if (c.retry_rc == 0 && c.fault_phase) T.fsync_retry_ok++; else if (c.fault_phase) T.fsync_retry_err++;
        verify_and_log((uint64_t)it, "fill", kind_name[F.kind], log, direct, writer, &c, 2, 1, t_fault,
                       F.kind == K_TMPFS_ENOSPC ? NULL : remount_vfat);
        fill_teardown();
    }
    fclose(jl);
    summary("fill", kind_name[F.kind], seed);
    return T.violations ? 3 : 0;
}

int main(int argc, char **argv)
{
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;
    sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    devnull = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (argc >= 2 && !strcmp(argv[1], "crash")) return cmd_crash(argc, argv);
    if (argc >= 2 && !strcmp(argv[1], "fill")) return cmd_fill(argc, argv);
    if (argc >= 4 && !strcmp(argv[1], "mkfat")) return mkfat(argv[2], (uint32_t)atol(argv[3]), argc > 4 && !strcmp(argv[4], "sparse")) ? 1 : 0;
    fprintf(stderr, "usage: %s crash|fill|mkfat ... (run a subcommand without args for its usage)\n", argv[0]);
    return 2;
}
