/* SPDX-License-Identifier: Apache-2.0
 * Offline crash-stage fixture for hps/harness.c. Compile and run only on
 * an admitted off-i9 build host with an admitted native C compiler.
 * It simulates process death by closing the log at each write boundary;
 * it is not a power-loss/fsync guarantee or an FPGA payload-replay test. */
#define main harness_cli_main
#include "harness.c"
#undef main

#define CHECK(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "durable-log fixture failed at line %d: %s\n", \
                __LINE__, #expr); \
        return 1; \
    } \
} while (0)

static void simulate_restart(void)
{
    if (g_logfd >= 0)
        close(g_logfd);
    g_logfd = -1;
    g_fpga_ordered = 0;
    g_host_persisted = 0;
    g_log_receipts = 0;
    g_recovered_history = 0;
}

int main(void)
{
    char path[] = "/tmp/smolfire-durable-XXXXXX";
    char line[192];
    const char *data = "DATA2 req=1 d0=0x00000003 d1=0x00000004 epoch=1\n";
    const char *dup0 = "DATA2 req=0 d0=0x00000001 d1=0x00000002 epoch=1\n";
    const char *dup1 = "DATA2 req=0 d0=0x00000003 d1=0x00000004 epoch=1\n";
    uint32_t hash;
    int fd = mkstemp(path);
    CHECK(fd >= 0);
    CHECK(close(fd) == 0);
    g_logpath = path;

    /* An actually empty log has no visible prior transaction. This
     * exercises the parser's first-run path, not durable-mode admission. */
    CHECK(durable_log_open() == 0);
    CHECK(durable_run_start(0) == 0);
    CHECK(durable_run_start(1) != 0); /* empty log cannot bless fabric 1 */

    /* First ACKed frame, then crash before seal; fabric resets to zero.
     * A visible unsealed tail must not be erased and called a fresh log. */
    CHECK(durable_log_write("FRAME2 start=0 end=1 count=1 epoch=1\n") == 0);
    CHECK(durable_log_write(dup0) == 0);
    simulate_restart();
    CHECK(durable_log_open() != 0 && g_logfd == -1);
    CHECK(durable_run_start(0) != 0);
    CHECK(unlink(path) == 0);

    /* Explicitly new empty log remains available to the parser fixture. */
    CHECK(durable_log_open() == 0);
    CHECK(durable_run_start(0) == 0);
    CHECK(durable_persist_one(0, 1, 2, 1, 1) == 0);
    CHECK(g_host_persisted == 1);
    simulate_restart();
    CHECK(durable_log_open() == 0);
    CHECK(g_host_persisted == 1 && g_log_receipts == 1);
    CHECK(durable_run_start(1) != 0); /* equal stale count has no identity */
    CHECK(durable_run_start(2) != 0); /* fabric ahead: no silent jump */
    CHECK(durable_run_start(0) != 0); /* fabric behind: no reused req */

    /* ACK then complete write but crash before data fsync or seal:
     * page-cache-visible DATA2 must be discarded, not credited. */
    CHECK(durable_log_write("FRAME2 start=1 end=2 count=1 epoch=1\n") == 0);
    CHECK(durable_log_write(data) == 0);
    simulate_restart();
    CHECK(durable_log_open() != 0 && g_logfd == -1);
    CHECK(durable_run_start(1) != 0); /* visible tail cannot be erased */

    /* Once DATA2 fsync returns, a visible SEAL2 is safe to parse even
     * if a crash precedes the seal's own fsync. It still cannot authorize
     * a resumed run without fabric payload/epoch identity. */
    CHECK(unlink(path) == 0);
    CHECK(durable_log_open() == 0);
    CHECK(durable_log_write("FRAME2 start=0 end=1 count=1 epoch=1\n") == 0);
    CHECK(durable_log_write(dup0) == 0);
    CHECK(fsync(g_logfd) == 0);
    hash = durable_hash_line(2166136261u, dup0);
    CHECK(snprintf(line, sizeof line,
                   "SEAL2 end=1 count=1 hash=%08x\n", hash) > 0);
    CHECK(durable_log_write(line) == 0);
    simulate_restart();
    CHECK(durable_log_open() == 0);
    CHECK(g_host_persisted == 1 && g_log_receipts == 1);
    CHECK(durable_run_start(1) != 0); /* equal count still unbound */

    /* A wrong seal hash and a legacy COMMIT must fail closed. */
    simulate_restart();
    CHECK(unlink(path) == 0);
    CHECK(durable_log_open() == 0);
    CHECK(durable_log_write("FRAME2 start=0 end=1 count=1 epoch=1\n") == 0);
    CHECK(durable_log_write(
          "DATA2 req=0 d0=0x00000001 d1=0x00000002 epoch=1\n") == 0);
    CHECK(durable_log_write("SEAL2 end=1 count=1 hash=00000000\n") == 0);
    simulate_restart();
    CHECK(durable_log_open() != 0 && g_logfd == -1);
    CHECK(durable_log_open() != 0 && g_logfd == -1); /* retry is not success */

    simulate_restart();
    CHECK(unlink(path) == 0);
    CHECK(durable_log_open() == 0);
    CHECK(durable_log_write(
          "COMMIT req=0 d0=0x00000001 d1=0x00000002 epoch=1"
          " ordered=1 persisted=1\n") == 0);
    simulate_restart();
    CHECK(durable_log_open() != 0 && g_logfd == -1);

    /* A partial seal line is not a committed transaction. */
    CHECK(unlink(path) == 0);
    CHECK(durable_log_open() == 0); /* clean retry after failed recovery */
    CHECK(durable_log_write("FRAME2 start=0 end=1 count=1 epoch=1\n") == 0);
    CHECK(durable_log_write(
          "DATA2 req=0 d0=0x00000001 d1=0x00000002 epoch=1\n") == 0);
    CHECK(fsync(g_logfd) == 0);
    CHECK(durable_log_write("SEAL2 end=1 count=1 hash=") == 0);
    simulate_restart();
    CHECK(durable_log_open() != 0 && g_logfd == -1);

    /* A duplicate request cannot form a valid count-two frame even with
     * a matching checksum and a complete seal. */
    CHECK(unlink(path) == 0);
    CHECK(durable_log_open() == 0);
    CHECK(durable_log_write("FRAME2 start=0 end=2 count=2 epoch=1\n") == 0);
    CHECK(durable_log_write(dup0) == 0);
    CHECK(durable_log_write(dup1) == 0);
    hash = durable_hash_line(durable_hash_line(2166136261u, dup0), dup1);
    CHECK(snprintf(line, sizeof line,
                   "SEAL2 end=2 count=2 hash=%08x\n", hash) > 0);
    CHECK(durable_log_write(line) == 0);
    simulate_restart();
    CHECK(durable_log_open() != 0 && g_logfd == -1);

    /* A reordered frame start is rejected before its payload is read. */
    CHECK(unlink(path) == 0);
    CHECK(durable_log_open() == 0);
    CHECK(durable_log_write("FRAME2 start=1 end=2 count=1 epoch=1\n") == 0);
    simulate_restart();
    CHECK(durable_log_open() != 0 && g_logfd == -1);

    CHECK(unlink(path) == 0);
    puts("durable-log fixture PASS: sealed recovery and refusal paths");
    return 0;
}
