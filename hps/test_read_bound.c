/* SPDX-License-Identifier: Apache-2.0
 * Off-board source-bound fixed-frame tests. A socket pair injects replies
 * after a request; it is not UART electrical or media durability proof. */
#include <sys/socket.h>
#include <sys/wait.h>
#include <errno.h>

#define main smolfire_harness_cli_main
#include "harness.c"
#undef main

#define CHECK(x) do { if (!(x)) { \
    fprintf(stderr, "read-bound fixture FAIL line %d: %s\n", __LINE__, #x); \
    exit(1); \
} } while (0)

enum reply_kind {
    VALID, LEGACY_ZERO, OLD_CHALLENGE, WRONG_ADDRESS,
    TRUNCATED, RESET_DURING_REPLY, LEGACY_TIMEOUT, BAD_CHECKSUM
};

static void all_read(int fd, uint8_t *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, buf + off, len - off);
        if (n < 0 && errno == EINTR)
            continue;
        CHECK(n > 0);
        off += (size_t)n;
    }
}

static void all_write(int fd, const uint8_t *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0 && errno == EINTR)
            continue;
        CHECK(n > 0);
        off += (size_t)n;
    }
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void emit_reply(int fd, uint8_t addr, uint32_t challenge,
                       uint32_t value, enum reply_kind kind)
{
    uint8_t f[13], sum = 0;
    size_t i;
    if (kind == LEGACY_TIMEOUT)
        return; /* old FPGA silently drops unknown 0x06 */
    if (kind == LEGACY_ZERO) {
        const uint8_t legacy[8] = {0x44, 0x55, 0x82, 0, 0, 0, 0, 0x82};
        usleep(5000); /* stale reply arrives after the new command */
        all_write(fd, legacy, sizeof legacy);
        return;
    }
    f[0] = M_MAGIC0;
    f[1] = M_MAGIC1;
    f[2] = RSP_READ_BOUND;
    f[3] = kind == WRONG_ADDRESS ? (uint8_t)(addr ^ 0x60u) : addr;
    put32(f + 4, kind == OLD_CHALLENGE ? challenge - 1u : challenge);
    put32(f + 8, value);
    for (i = 2; i < 12; i++)
        sum = (uint8_t)(sum + f[i]);
    f[12] = kind == BAD_CHECKSUM ? (uint8_t)(sum ^ 1u) : sum;
    if (kind == TRUNCATED) {
        all_write(fd, f, 7);
    } else if (kind == RESET_DURING_REPLY) {
        all_write(fd, f, 4); /* link disappears mid-frame on reset */
    } else {
        all_write(fd, f, sizeof f);
    }
}

static void run_one(const char *name, enum reply_kind kind, int expect_ok)
{
    int fd[2], status, rc;
    pid_t child;
    uint32_t value = 0xdeadbeefu;
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        uint8_t req[9];
        uint8_t sum;
        close(fd[0]);
        all_read(fd[1], req, sizeof req);
        sum = (uint8_t)(req[2] + req[3] + req[4] + req[5] +
                        req[6] + req[7]);
        CHECK(req[0] == M_MAGIC0 && req[1] == M_MAGIC1);
        CHECK(req[2] == CMD_READ_BOUND && req[3] == R_ID_CAPS);
        CHECK(req[8] == sum);
        emit_reply(fd[1], req[3], le32(req + 4), 0, kind);
        close(fd[1]);
        _exit(0);
    }
    close(fd[1]);
    g_fd = fd[0];
    rc = u_read_bound(R_ID_CAPS, &value);
    close(fd[0]);
    g_fd = -1;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    if (expect_ok) {
        CHECK(rc == 0 && value == 0);
    } else {
        CHECK(rc != 0 && value == 0xdeadbeefu);
    }
    fprintf(stderr, "[PASS] %s\n", name);
}

static void full_caps_still_closed(void)
{
    int fd[2], status;
    pid_t child;
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        uint8_t req[9];
        close(fd[0]);
        all_read(fd[1], req, sizeof req);
        CHECK(req[2] == CMD_READ_BOUND && req[3] == R_ID_PROBE);
        emit_reply(fd[1], req[3], le32(req + 4), ID_PROBE_SSP1, VALID);
        all_read(fd[1], req, sizeof req);
        CHECK(req[2] == CMD_READ_BOUND && req[3] == R_ID_CAPS);
        emit_reply(fd[1], req[3], le32(req + 4), CAP_DURABLE_REQUIRED,
                   VALID);
        close(fd[1]);
        _exit(0);
    }
    close(fd[1]);
    g_fd = fd[0];
    CHECK(durable_backend_ready() != 0);
    close(fd[0]);
    g_fd = -1;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    fputs("[PASS] bound full caps still refuses durable admission\n", stderr);
}

int main(int argc, char **argv)
{
    run_one("valid bound zero", VALID, 1);
    run_one("delayed legacy zero rejected", LEGACY_ZERO, 0);
    run_one("old same-address challenge rejected", OLD_CHALLENGE, 0);
    run_one("wrong address rejected", WRONG_ADDRESS, 0);
    run_one("truncated reply rejected", TRUNCATED, 0);
    run_one("reset during reply rejected", RESET_DURING_REPLY, 0);
    run_one("legacy silent drop times out", LEGACY_TIMEOUT, 0);
    run_one("bad checksum rejected", BAD_CHECKSUM, 0);
    full_caps_still_closed();
    g_bound_nonce_next = (uint64_t)UINT32_MAX + 1u;
    g_fd = -1;
    {
        uint32_t value = 0xdeadbeefu;
        CHECK(u_read_bound(R_ID_CAPS, &value) != 0);
        CHECK(value == 0xdeadbeefu);
    }
    fputs("[PASS] challenge counter refuses wrap\n", stderr);
    if (argc > 1 && strcmp(argv[1], "--negative-control") == 0)
        CHECK(0); /* verify a failing assertion returns nonzero */
    fputs("read-bound fixture PASS\n", stderr);
    return 0;
}
