/* SPDX-License-Identifier: Apache-2.0 */
/* Observation-only CLI. All expected values and assertions live in Nushell. */
#include "media_log_v2.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_SLOTS 64u

struct injected_slot {
    enum ml2_slot_read_status status;
    size_t available;
    uint8_t bytes[ML2_RECORD_BYTES];
};
struct reader_state {
    struct injected_slot slots[MAX_SLOTS];
    uint64_t indices[MAX_SLOTS];
    size_t count;
    size_t calls;
    int overflow;
};

static void die(void) { fputs("invalid observation protocol\n", stderr); exit(2); }
static uint64_t u64(const char *s) {
    uint64_t n = 0;
    if (!s || !*s) die();
    for (; *s; ++s) {
        if (*s < '0' || *s > '9') die();
        unsigned d = (unsigned)(*s - '0');
        if (n > (UINT64_MAX - d) / 10u) die();
        n = n * 10u + d;
    }
    return n;
}
static uint32_t u32(const char *s) {
    uint64_t n = u64(s);
    if (n > UINT32_MAX) die();
    return (uint32_t)n;
}
static size_t length(const char *s) {
    size_t n = 0;
    while (s[n]) { if (n >= (ML2_RECORD_BYTES + 1u) * 2u) die(); ++n; }
    return n;
}
static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    die(); return 0;
}
static size_t hex(const char *s, uint8_t *out, size_t cap) {
    size_t n = length(s);
    if (n > cap * 2u || n % 2u) die();
    for (size_t i = 0; i < n / 2u; ++i)
        out[i] = (uint8_t)((nibble(s[2u*i]) << 4) | nibble(s[2u*i+1u]));
    return n / 2u;
}
static void exact_hex(const char *s, uint8_t *out, size_t n) {
    if (hex(s, out, n) != n) die();
}
static void print_hex(const uint8_t *p, size_t n) {
    static const char chars[] = "0123456789abcdef";
    putchar('"');
    for (size_t i = 0; i < n; ++i) {
        putchar(chars[p[i] >> 4]); putchar(chars[p[i] & 15u]);
    }
    putchar('"');
}
static const char *decode_name(enum ml2_decode_status s) {
    switch (s) {
    case ML2_DECODE_OK: return "ML2_DECODE_OK";
    case ML2_DECODE_SHORT: return "ML2_DECODE_SHORT";
    case ML2_DECODE_FORMAT: return "ML2_DECODE_FORMAT";
    case ML2_DECODE_CRC: return "ML2_DECODE_CRC";
    case ML2_DECODE_ARGUMENT: return "ML2_DECODE_ARGUMENT";
    } die(); return "";
}
static const char *class_name(enum ml2_scan_class s) {
    switch (s) {
    case ML2_SCAN_FAULT: return "ML2_SCAN_FAULT";
    case ML2_SCAN_PREFIX_EXACT: return "ML2_SCAN_PREFIX_EXACT";
    case ML2_SCAN_ONE_UNACKED_CANDIDATE: return "ML2_SCAN_ONE_UNACKED_CANDIDATE";
    } die(); return "";
}
static const char *fault_name(enum ml2_fault_reason s) {
    switch (s) {
    case ML2_FAULT_NONE: return "ML2_FAULT_NONE";
    case ML2_FAULT_ARGUMENT: return "ML2_FAULT_ARGUMENT";
    case ML2_FAULT_EXTENT: return "ML2_FAULT_EXTENT";
    case ML2_FAULT_IO: return "ML2_FAULT_IO";
    case ML2_FAULT_EOF: return "ML2_FAULT_EOF";
    case ML2_FAULT_SHORT: return "ML2_FAULT_SHORT";
    case ML2_FAULT_FORMAT: return "ML2_FAULT_FORMAT";
    case ML2_FAULT_CRC: return "ML2_FAULT_CRC";
    case ML2_FAULT_IDENTITY: return "ML2_FAULT_IDENTITY";
    case ML2_FAULT_TID: return "ML2_FAULT_TID";
    case ML2_FAULT_EXTRA_SUFFIX: return "ML2_FAULT_EXTRA_SUFFIX";
    } die(); return "";
}
static void record_json(const struct ml2_record *r) {
    fputs("{\"store_id_hex\":", stdout); print_hex(r->store_id, 16u);
    printf(",\"stream_epoch\":\"%" PRIu64 "\",\"request_tid\":\"%" PRIu64 "\",\"descriptor_hex\":",
           r->stream_epoch, r->request_tid);
    print_hex(r->descriptor, ML2_DESCRIPTOR_BYTES);
    putchar('}');
}
static int record_zero(const struct ml2_record *r) {
    uint8_t zero_store[16] = {0}, zero_desc[ML2_DESCRIPTOR_BYTES] = {0};
    return !memcmp(r->store_id, zero_store, 16u) &&
           r->stream_epoch == 0 && r->request_tid == 0 &&
           !memcmp(r->descriptor, zero_desc, ML2_DESCRIPTOR_BYTES);
}
static int null_mode(const char *s) {
    if (!strcmp(s, "valid")) return 0;
    if (!strcmp(s, "null")) return 1;
    die(); return 0;
}
static enum ml2_slot_read_status slot_status(const char *s) {
    if (!strcmp(s, "ML2_SLOT_BYTES")) return ML2_SLOT_BYTES;
    if (!strcmp(s, "ML2_SLOT_EOF")) return ML2_SLOT_EOF;
    if (!strcmp(s, "ML2_SLOT_IO_ERROR")) return ML2_SLOT_IO_ERROR;
    if (!strcmp(s, "INVALID")) return (enum ml2_slot_read_status)3;
    die(); return ML2_SLOT_IO_ERROR;
}
static enum ml2_slot_read_status read_slot(void *ctx, uint64_t index,
                                            uint8_t out[ML2_RECORD_BYTES],
                                            size_t *available) {
    struct reader_state *state = ctx;
    if (state->calls >= MAX_SLOTS || index >= state->count || index != state->calls) {
        state->overflow = 1;
        *available = 0;
        return ML2_SLOT_IO_ERROR;
    }
    state->indices[state->calls++] = index;
    const struct injected_slot *slot = &state->slots[index];
    *available = slot->available;
    /* Never write past the native callback buffer, even for invalid available. */
    memcpy(out, slot->bytes, ML2_RECORD_BYTES);
    return slot->status;
}
int main(int argc, char **argv) {
    if (argc < 2) die();
    if (!strcmp(argv[1], "offset")) {
        if (argc != 7) die();
        uint64_t index = u64(argv[2]), stride = u64(argv[3]);
        uint64_t ceiling = u64(argv[4]), out = u64(argv[5]);
        int is_null = null_mode(argv[6]);
        int rc = ml2_checked_slot_offset(index, stride, ceiling, is_null ? NULL : &out);
        printf("{\"return_code\":%d,\"out\":\"%" PRIu64 "\"}\n", rc, out);
    } else if (!strcmp(argv[1], "decode")) {
        if (argc != 7) die();
        uint8_t bytes[ML2_RECORD_BYTES + 1u] = {0};
        size_t n = hex(argv[2], bytes, ML2_RECORD_BYTES + 1u);
        uint64_t avail = u64(argv[3]);
        if (avail > SIZE_MAX) die();
        uint32_t magic = u32(argv[4]);
        int null_bytes = null_mode(argv[5]), null_out = null_mode(argv[6]);
        if (!null_bytes && avail > n) die();
        struct ml2_record out;
        memset(&out, 0xa5, sizeof out);
        enum ml2_decode_status status = ml2_decode_record(
            null_bytes ? NULL : bytes, (size_t)avail, magic, null_out ? NULL : &out);
        printf("{\"status\":\"%s\",\"out_zero\":%s,\"record\":",
               decode_name(status), null_out ? "null" : record_zero(&out) ? "true" : "false");
        if (null_out) fputs("null", stdout); else record_json(&out);
        fputs("}\n", stdout);
    } else if (!strcmp(argv[1], "retry")) {
        if (argc != 11) die();
        uint8_t bytes[ML2_RECORD_BYTES], store[16], desc[ML2_DESCRIPTOR_BYTES];
        exact_hex(argv[2], bytes, ML2_RECORD_BYTES);
        exact_hex(argv[3], store, 16u);
        uint64_t epoch = u64(argv[4]), tid = u64(argv[5]);
        exact_hex(argv[6], desc, ML2_DESCRIPTOR_BYTES);
        int nr = null_mode(argv[7]), ns = null_mode(argv[8]), nd = null_mode(argv[9]);
        uint32_t magic = u32(argv[10]);
        struct ml2_record record;
        if (ml2_decode_record(bytes, ML2_RECORD_BYTES, magic, &record) != ML2_DECODE_OK) die();
        int rc = ml2_exact_retry(nr ? NULL : &record, ns ? NULL : store, epoch,
                                 tid, nd ? NULL : desc);
        printf("{\"return_code\":%d}\n", rc);
    } else if (!strcmp(argv[1], "scan")) {
        if (argc < 11) die();
        struct ml2_scan_config cfg;
        cfg.expected_magic = u32(argv[2]);
        exact_hex(argv[3], cfg.store_id, 16u);
        cfg.stream_epoch = u64(argv[4]);
        cfg.witness_next = u64(argv[5]);
        cfg.slot_count = u64(argv[6]);
        cfg.max_scan_slots = u64(argv[7]);
        int null_cfg = null_mode(argv[8]), null_reader = null_mode(argv[9]);
        int null_out = null_mode(argv[10]);
        if ((argc - 11) % 3) die();
        size_t count = (size_t)(argc - 11) / 3u;
        if (count > MAX_SLOTS || (uint64_t)count < cfg.slot_count) die();
        struct reader_state state = {0};
        state.count = count;
        for (size_t i = 0; i < count; ++i) {
            state.slots[i].status = slot_status(argv[11 + 3*i]);
            uint64_t avail = u64(argv[12 + 3*i]);
            if (avail > SIZE_MAX) die();
            state.slots[i].available = (size_t)avail;
            hex(argv[13 + 3*i], state.slots[i].bytes, ML2_RECORD_BYTES);
        }
        struct ml2_scan_result result;
        memset(&result, 0xa5, sizeof result);
        ml2_scan(null_cfg ? NULL : &cfg, null_reader ? NULL : read_slot,
                 &state, null_out ? NULL : &result);
        if (state.overflow) die();
        fputs("{\"calls\":", stdout); printf("%zu,\"indices\":[", state.calls);
        for (size_t i = 0; i < state.calls; ++i) {
            if (i) putchar(',');
            printf("\"%" PRIu64 "\"", state.indices[i]);
        }
        fputs("],\"classification\":", stdout);
        if (null_out) fputs("null,\"fault\":null,\"fault_slot\":null,\"candidate_zero\":null,\"candidate\":null", stdout);
        else {
            printf("\"%s\",\"fault\":\"%s\",\"fault_slot\":\"%" PRIu64 "\",\"candidate_zero\":%s,\"candidate\":",
                   class_name(result.classification), fault_name(result.fault),
                   result.fault_slot, record_zero(&result.candidate) ? "true" : "false");
            record_json(&result.candidate);
        }
        fputs("}\n", stdout);
    } else die();
    return 0;
}
