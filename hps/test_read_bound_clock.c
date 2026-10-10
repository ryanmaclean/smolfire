/* SPDX-License-Identifier: Apache-2.0
 * Deterministic READ_BOUND deadline regression. The injected wall clock moves
 * backward while an unanswered read uses an advancing monotonic clock. */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static unsigned wall_calls, mono_calls, read_calls, sleep_calls;
static int mono_failure;

static int injected_gettimeofday(struct timeval *tv, void *zone)
{
    (void)zone;
    tv->tv_sec = wall_calls++ == 0 ? 100 : 0;
    tv->tv_usec = 0;
    return 0;
}

static int injected_clock_gettime(clockid_t id, struct timespec *ts)
{
    if (id != CLOCK_MONOTONIC || mono_failure) {
        errno = EIO;
        return -1;
    }
    ts->tv_sec = 1;
    ts->tv_nsec = (long)(mono_calls++ * 5000000u); /* +5 ms/call */
    return 0;
}

static ssize_t injected_read(int fd, void *buf, size_t len)
{
    (void)fd; (void)buf; (void)len;
    read_calls++;
    errno = EAGAIN;
    return -1;
}

static int injected_usleep(useconds_t usec)
{
    (void)usec;
    if (++sleep_calls > 4) {
        fputs("clock fixture FAIL: timeout failed to terminate\n", stderr);
        _Exit(2); /* old gettimeofday deadline must fail promptly */
    }
    return 0;
}

#define gettimeofday injected_gettimeofday
#define clock_gettime injected_clock_gettime
#define read injected_read
#define usleep injected_usleep
#define main smolfire_harness_cli_main
#include "harness.c"
#undef main
#undef gettimeofday
#undef clock_gettime
#undef read
#undef usleep

#define CHECK(x) do { if (!(x)) { \
    fprintf(stderr, "clock fixture FAIL line %d: %s\n", __LINE__, #x); \
    return 1; \
} } while (0)

int main(void)
{
    struct timeval before, after;
    uint32_t value = 0xdeadbeefu;
    int rc;
    CHECK(injected_gettimeofday(&before, NULL) == 0);
    g_fd = 99; /* injected_read never touches this descriptor */
    rc = rsp_bound_frame(R_ID_CAPS, 0x12345678u, &value, 10);
    CHECK(injected_gettimeofday(&after, NULL) == 0);
    CHECK(before.tv_sec == 100 && after.tv_sec == 0);
    CHECK(rc == -1 && value == 0xdeadbeefu);
    CHECK(wall_calls == 2); /* parser never used the backward wall clock */
    CHECK(mono_calls == 3 && read_calls == 1 && sleep_calls == 1);
    fputs("[PASS] backward wall clock cannot extend bound timeout\n", stderr);

    mono_failure = 1;
    value = 0xdeadbeefu;
    CHECK(rsp_bound_frame(R_ID_CAPS, 0x12345678u, &value, 10) == -1);
    CHECK(value == 0xdeadbeefu && read_calls == 1);
    fputs("[PASS] monotonic clock failure is fail-closed\n", stderr);
    return 0;
}
