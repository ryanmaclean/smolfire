/* SPDX-License-Identifier: Apache-2.0
 * Issue #90: measure existing BSD publication/observation primitives.
 * One producer, one consumer, one outstanding request. No ring or queue.
 * Release/acquire publishes 64-byte payloads; kqueue only wakes the waiter.
 * A successful result requires every request and response to match its seq.
 */
#include <sys/types.h>
#include <sys/event.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <stdatomic.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PAYLOAD 64
#define LIMIT 10000000
#define TIMEOUT_NS UINT64_C(5000000000)
struct channel {
    _Alignas(64) _Atomic uint64_t request;
    _Alignas(64) _Atomic uint64_t response;
    _Alignas(64) _Atomic unsigned error;
    _Alignas(64) unsigned char input[PAYLOAD];
    _Alignas(64) unsigned char output[PAYLOAD];
};

static uint64_t ns(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock_gettime"); exit(2); }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static uint64_t number(const char *s, uint64_t max)
{
    char *end;
    errno = 0;
    unsigned long long n = strtoull(s, &end, 10);
    if (!*s || *s == '-' || *end || errno || n > max) {
        fprintf(stderr, "invalid bounded integer: %s\n", s); exit(2);
    }
    return (uint64_t)n;
}
static unsigned char byte(uint64_t seq, uint64_t seed, size_t i)
{
    return (unsigned char)((seq >> ((i % 8) * 8)) ^
        (seed >> (((i + 3) % 8) * 8)) ^ (i * 37));
}
static int notify(int fd)
{
    unsigned char b = 1;
    ssize_t r;
    do { r = write(fd, &b, 1); } while (r < 0 && errno == EINTR);
    return r == 1 ? 0 : -1;
}
static int queue(int fd)
{
    int q = kqueue();
    struct kevent change;
    if (q < 0) return -1;
    EV_SET(&change, (uintptr_t)fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (kevent(q, &change, 1, NULL, 0, NULL) < 0) { close(q); return -1; }
    return q;
}
static int wait_event(int q, int fd)
{
    const uint64_t deadline = ns() + TIMEOUT_NS;
    for (;;) {
        uint64_t now = ns();
        if (now >= deadline) { errno = ETIMEDOUT; return -1; }
        uint64_t left = deadline - now;
        struct timespec timeout = { (time_t)(left / 1000000000), (long)(left % 1000000000) };
        struct kevent event;
        int r = kevent(q, NULL, 0, &event, 1, &timeout);
        if (r < 0 && errno == EINTR) continue;
        if (r == 0) { errno = ETIMEDOUT; return -1; }
        if (r < 0 || (event.flags & EV_ERROR)) return -1;
        unsigned char b;
        ssize_t got;
        do { got = read(fd, &b, 1); } while (got < 0 && errno == EINTR);
        if (got != 1 || b != 1) { errno = EIO; return -1; }
        return 0;
    }
}
static int observe(struct channel *s, _Atomic uint64_t *word, uint64_t seq,
    int q, int fd)
{
    if (q >= 0 && wait_event(q, fd)) return -1;
    uint64_t deadline = ns() + TIMEOUT_NS;
    unsigned spins = 0;
    for (;;) {
        if (atomic_load_explicit(&s->error, memory_order_acquire)) return -1;
        uint64_t got = atomic_load_explicit(word, memory_order_acquire);
        if (got == seq) return 0;
        if (got > seq || (q >= 0)) { errno = EPROTO; return -1; }
        if ((++spins & 1023) == 0 && ns() >= deadline) { errno = ETIMEDOUT; return -1; }
    }
}
static int consumer(struct channel *s, uint64_t count, uint64_t seed, int event,
    int request_fd, int response_fd)
{
    int q = event ? queue(request_fd) : -1;
    if (event && q < 0) return 3;
    for (uint64_t seq = 1; seq <= count; seq++) {
        if (observe(s, &s->request, seq, q, request_fd)) {
            atomic_store_explicit(&s->error, 2, memory_order_release);
            if (event) (void)notify(response_fd);
            if (q >= 0) close(q);
            return 3;
        }
        for (size_t i = 0; i < PAYLOAD; i++) {
            if (s->input[i] != byte(seq, seed, i)) {
                atomic_store_explicit(&s->error, 1, memory_order_release);
                if (event) (void)notify(response_fd);
                if (q >= 0) close(q);
                return 3;
            }
            s->output[i] = (unsigned char)~s->input[i];
        }
        atomic_store_explicit(&s->response, seq, memory_order_release);
        if (event && notify(response_fd)) return 3;
    }
    if (q >= 0) close(q);
    return 0;
}
static int cmp(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}
static uint64_t percentile(const uint64_t *v, uint64_t n, unsigned p)
{
    /* Nearest-rank percentile, including p100 == maximum. */
    uint64_t rank = (n * p + 99) / 100;
    return v[rank ? rank - 1 : 0];
}
static void json_string(const char *s)
{
    putchar('"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 32) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}
int main(int argc, char **argv)
{
    if (argc < 6 || argc > 8 ||
        (strcmp(argv[1], "poll") && strcmp(argv[1], "kqueue")) ||
        (strcmp(argv[2], "anon") && strcmp(argv[2], "file")) ||
        (argc == 8 && strcmp(argv[7], "payload") && strcmp(argv[7], "future"))) {
        fprintf(stderr, "usage: %s poll|kqueue anon|file iterations warmup seed [fault_seq [payload|future]]\n", argv[0]);
        return 2;
    }
    uint64_t n = number(argv[3], LIMIT), warmup = number(argv[4], LIMIT);
    uint64_t seed = number(argv[5], UINT64_MAX);
    uint64_t corrupt = argc >= 7 ? number(argv[6], n + warmup) : 0;
    int future = argc == 8 && !strcmp(argv[7], "future");
    if (!n) { fprintf(stderr, "iterations must be positive\n"); return 2; }
    int event = !strcmp(argv[1], "kqueue"), file = !strcmp(argv[2], "file");
    int fd = -1;
    if (file) {
        char path[] = "/tmp/smolfire-primitives.XXXXXX";
        fd = mkstemp(path);
        if (fd < 0) { perror("mkstemp"); return 2; }
        if (unlink(path) || ftruncate(fd, sizeof(struct channel))) { perror("backing file"); close(fd); return 2; }
    }
    struct channel *s = mmap(NULL, sizeof *s, PROT_READ | PROT_WRITE,
        MAP_SHARED | (file ? 0 : MAP_ANON), fd, 0);
    if (fd >= 0) close(fd);
    if (s == MAP_FAILED) { perror("mmap"); return 2; }
    memset(s, 0, sizeof *s);
    atomic_init(&s->request, 0); atomic_init(&s->response, 0); atomic_init(&s->error, 0);
    if (!atomic_is_lock_free(&s->request) || !atomic_is_lock_free(&s->response) || !atomic_is_lock_free(&s->error)) {
        fprintf(stderr, "shared atomics are not lock-free on this target\n"); munmap(s, sizeof *s); return 2;
    }
    uint64_t *latency = calloc((size_t)n, sizeof *latency);
    int requests[2], responses[2];
    if (!latency || pipe(requests) || pipe(responses)) { perror("allocate/pipe"); return 2; }
    signal(SIGPIPE, SIG_IGN);
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 2; }
    if (!child) {
        close(requests[1]); close(responses[0]);
        int rc = consumer(s, n + warmup, seed, event, requests[0], responses[1]);
        close(requests[0]); close(responses[1]); _exit(rc);
    }
    close(requests[0]); close(responses[1]);
    int q = event ? queue(responses[0]) : -1;
    int failed = event && q < 0;
    uint64_t start = 0, end = 0, completed = 0;
    for (uint64_t seq = 1; !failed && seq <= n + warmup; seq++) {
        uint64_t before = ns();
        if (seq == warmup + 1) start = before;
        for (size_t i = 0; i < PAYLOAD; i++) s->input[i] = byte(seq, seed, i);
        if (seq == corrupt && !future) s->input[PAYLOAD - 1] ^= 1;
        atomic_store_explicit(&s->request, seq + (seq == corrupt && future), memory_order_release);
        if ((event && notify(requests[1])) || observe(s, &s->response, seq, q, responses[0])) { failed = 1; break; }
        for (size_t i = 0; i < PAYLOAD; i++)
            if (s->output[i] != (unsigned char)~byte(seq, seed, i)) failed = 1;
        if (failed) break;
        end = ns();
        if (seq > warmup) { latency[completed++] = end - before; }
    }
    if (failed) {
        fprintf(stderr, "handshake failed: completed=%" PRIu64 " integrity_error=%u errno=%d\n",
            completed, atomic_load_explicit(&s->error, memory_order_acquire), errno);
        kill(child, SIGTERM);
    }
    close(requests[1]); close(responses[0]); if (q >= 0) close(q);
    int status;
    pid_t waited;
    struct rusage child_usage, parent_usage;
    do { waited = wait4(child, &status, 0, &child_usage); } while (waited < 0 && errno == EINTR);
    if (waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status) || completed != n) failed = 1;
    munmap(s, sizeof *s);
    if (failed) { free(latency); return 3; }
    if (end <= start) { fprintf(stderr, "clock did not advance over measurement\n"); free(latency); return 2; }
    if (getrusage(RUSAGE_SELF, &parent_usage)) { perror("getrusage"); free(latency); return 2; }
    qsort(latency, (size_t)n, sizeof *latency, cmp);
    struct utsname u;
    struct timespec resolution;
    if (uname(&u) || clock_getres(CLOCK_MONOTONIC, &resolution)) {
        perror("environment"); free(latency); return 2;
    }
    printf("{\"schema\":\"smolfire.bsd-primitives/v1\",\"mode\":\"%s\",\"backing\":\"%s\",", argv[1], argv[2]);
    printf("\"iterations\":%" PRIu64 ",\"warmup\":%" PRIu64 ",\"seed\":%" PRIu64 ",\"payload_bytes\":%d,", n, warmup, seed, PAYLOAD);
    printf("\"processes\":2,\"outstanding\":1,\"affinity\":\"unbound\",\"lock_free\":true,\"validated\":%" PRIu64 ",", n);
    uint64_t cpu_us = (uint64_t)(parent_usage.ru_utime.tv_sec + parent_usage.ru_stime.tv_sec +
        child_usage.ru_utime.tv_sec + child_usage.ru_stime.tv_sec) * 1000000 +
        (uint64_t)(parent_usage.ru_utime.tv_usec + parent_usage.ru_stime.tv_usec +
        child_usage.ru_utime.tv_usec + child_usage.ru_stime.tv_usec);
    printf("\"cpu_time_us\":%" PRIu64 ",\"cpu_includes_setup_and_warmup\":true,", cpu_us);
    printf("\"voluntary_context_switches\":%ld,\"involuntary_context_switches\":%ld,",
        parent_usage.ru_nvcsw + child_usage.ru_nvcsw, parent_usage.ru_nivcsw + child_usage.ru_nivcsw);
    printf("\"elapsed_ns\":%" PRIu64 ",\"roundtrips_per_second\":%.3f,", end - start, (double)n * 1e9 / (double)(end - start));
    printf("\"latency_ns\":{\"min\":%" PRIu64 ",\"p50\":%" PRIu64 ",\"p95\":%" PRIu64 ",\"p99\":%" PRIu64 ",\"max\":%" PRIu64 "},",
        latency[0], percentile(latency, n, 50), percentile(latency, n, 95), percentile(latency, n, 99), latency[n - 1]);
    printf("\"clock_resolution_ns\":%" PRIu64 ",\"os\":", (uint64_t)resolution.tv_sec * 1000000000 + (uint64_t)resolution.tv_nsec);
    json_string(u.sysname); printf(",\"release\":"); json_string(u.release); printf(",\"machine\":"); json_string(u.machine);
    printf(",\"scope\":\"software shared-memory roundtrip; no device mapping, DMA, FPGA, or durability claim\"}\n");
    free(latency);
    return 0;
}
