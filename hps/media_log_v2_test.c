/* SPDX-License-Identifier: Apache-2.0 */
/* Source-only vectors: execute only with a cleared off-laptop C toolchain. */
#include "media_log_v2.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define TEST_MAGIC UINT32_C(0x324c4d53) /* Test value; production magic unfrozen. */
#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "media_log_v2_test:%d: %s\n", __LINE__, #condition); \
        return 1; \
    } \
} while (0)

struct test_slot {
    enum ml2_slot_read_status status;
    size_t available;
    uint8_t bytes[ML2_RECORD_BYTES];
};

struct test_reader {
    struct test_slot slots[4];
    uint64_t calls;
    uint64_t next_index;
};

static void put_le16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static void put_le32(uint8_t *p, uint32_t value)
{
    for (unsigned i = 0; i < 4; ++i)
        p[i] = (uint8_t)(value >> (8u * i));
}

static void put_le64(uint8_t *p, uint64_t value)
{
    for (unsigned i = 0; i < 8; ++i)
        p[i] = (uint8_t)(value >> (8u * i));
}

static uint32_t test_crc(const uint8_t *p, size_t length)
{
    uint32_t crc = UINT32_MAX;
    for (size_t i = 0; i < length; ++i) {
        crc ^= p[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1u) ? UINT32_C(0xedb88320) : 0u);
    }
    return ~crc;
}

static void make_record(struct test_slot *slot, uint64_t tid,
                        const uint8_t store_id[16], uint64_t epoch,
                        const uint8_t descriptor[ML2_DESCRIPTOR_BYTES])
{
    memset(slot, 0, sizeof *slot);
    slot->status = ML2_SLOT_BYTES;
    slot->available = ML2_RECORD_BYTES;
    put_le32(slot->bytes, TEST_MAGIC);
    put_le16(slot->bytes + 4, 2u);
    put_le16(slot->bytes + 6, ML2_RECORD_BYTES);
    memcpy(slot->bytes + 8, store_id, 16u);
    put_le64(slot->bytes + 24, epoch);
    put_le64(slot->bytes + 32, tid);
    memcpy(slot->bytes + 40, descriptor, ML2_DESCRIPTOR_BYTES);
    put_le32(slot->bytes + 48, 0u);
    put_le32(slot->bytes + 52, test_crc(slot->bytes, 52u));
}

static enum ml2_slot_read_status read_slot(void *context, uint64_t index,
                                            uint8_t out[ML2_RECORD_BYTES],
                                            size_t *available)
{
    struct test_reader *reader = context;
    if (index >= 4u || index != reader->next_index)
        return ML2_SLOT_IO_ERROR;
    ++reader->calls;
    ++reader->next_index;
    struct test_slot *slot = &reader->slots[index];
    *available = slot->available;
    if (slot->status == ML2_SLOT_BYTES)
        memcpy(out, slot->bytes,
               slot->available < ML2_RECORD_BYTES
                   ? slot->available : ML2_RECORD_BYTES);
    return slot->status;
}

static void reset_calls(struct test_reader *reader)
{
    reader->calls = 0;
    reader->next_index = 0;
}

int main(void)
{
    /* Fixed CRC-32/IEEE check value; independent of the record encoder. */
    const uint8_t check_text[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
    CHECK(test_crc(check_text, sizeof check_text) == UINT32_C(0xcbf43926));

    const uint8_t store_id[16] = {0x53, 0x54, 0x4f, 0x52, 0x45};
    const uint8_t descriptor[ML2_DESCRIPTOR_BYTES] = {1, 2, 3, 4, 5, 6, 7, 8};
    uint8_t changed[ML2_DESCRIPTOR_BYTES];
    memcpy(changed, descriptor, sizeof changed);
    changed[7] ^= 1u;

    struct test_reader reader = {0};
    for (uint64_t i = 0; i < 4; ++i)
        make_record(&reader.slots[i], i, store_id, 7u, descriptor);
    /* Fixed independent v2 test-record fixture (52-byte prefix -> CRC). */
    CHECK(test_crc(reader.slots[0].bytes, 52u) == UINT32_C(0x49d18ea8));
    CHECK(reader.slots[0].bytes[52] == 0xa8u &&
          reader.slots[0].bytes[53] == 0x8eu &&
          reader.slots[0].bytes[54] == 0xd1u &&
          reader.slots[0].bytes[55] == 0x49u);
    struct ml2_scan_config cfg = {0};
    cfg.expected_magic = TEST_MAGIC;
    memcpy(cfg.store_id, store_id, sizeof store_id);
    cfg.stream_epoch = 7u;
    cfg.witness_next = 2u;
    cfg.slot_count = 2u;
    cfg.max_scan_slots = 4u;
    struct ml2_scan_result result;

    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.classification == ML2_SCAN_PREFIX_EXACT);
    CHECK(result.fault == ML2_FAULT_NONE && reader.calls == 2u);

    reset_calls(&reader);
    cfg.slot_count = 3u;
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.classification == ML2_SCAN_ONE_UNACKED_CANDIDATE);
    CHECK(result.candidate.request_tid == 2u && reader.calls == 3u);
    CHECK(ml2_exact_retry(&result.candidate, store_id, 7u, 2u, descriptor));
    CHECK(!ml2_exact_retry(&result.candidate, store_id, 7u, 2u, changed));
    CHECK(!ml2_exact_retry(&result.candidate, store_id, 8u, 2u, descriptor));

    /* A second complete above-W record faults even though both CRCs pass. */
    reset_calls(&reader);
    cfg.slot_count = 4u;
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.classification == ML2_SCAN_FAULT);
    CHECK(result.fault == ML2_FAULT_EXTRA_SUFFIX && reader.calls == 4u);

    /* A partial attempted n+1 also faults; no adoption of valid n. */
    reader.slots[3].available = 1u;
    reset_calls(&reader);
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.classification == ML2_SCAN_FAULT);
    CHECK(result.fault == ML2_FAULT_SHORT && reader.calls == 4u);
    CHECK(result.candidate.request_tid == 0u);
    reader.slots[3].available = ML2_RECORD_BYTES;

    /* A missing witnessed slot, short read, and read error are distinct. */
    cfg.slot_count = 3u;
    reader.slots[1].status = ML2_SLOT_EOF;
    reset_calls(&reader);
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.fault == ML2_FAULT_EOF && reader.calls == 3u);
    reader.slots[1].status = ML2_SLOT_IO_ERROR;
    reset_calls(&reader);
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.fault == ML2_FAULT_IO && reader.calls == 3u);
    reader.slots[1].status = ML2_SLOT_BYTES;
    reader.slots[1].available = 17u;
    reset_calls(&reader);
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.fault == ML2_FAULT_SHORT && reader.calls == 3u);
    reader.slots[1].available = ML2_RECORD_BYTES;

    /* A forged on-media length is rejected before any length-derived CRC. */
    struct ml2_record decoded;
    CHECK(ml2_decode_record(reader.slots[2].bytes, 55u, TEST_MAGIC, &decoded)
          == ML2_DECODE_SHORT);
    put_le16(reader.slots[2].bytes + 6, UINT16_MAX);
    reset_calls(&reader);
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.fault == ML2_FAULT_FORMAT && reader.calls == 3u);
    make_record(&reader.slots[2], 2u, store_id, 7u, descriptor);
    reader.slots[2].bytes[40] ^= 1u;
    reset_calls(&reader);
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.fault == ML2_FAULT_CRC && reader.calls == 3u);
    make_record(&reader.slots[2], 2u, store_id, 7u, descriptor);

    /* Extent and multiplication guards run before touching a slot. */
    reset_calls(&reader);
    cfg.witness_next = 4u;
    cfg.slot_count = 3u;
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.fault == ML2_FAULT_EXTENT && reader.calls == 0u);
    cfg.witness_next = 2u;
    cfg.slot_count = 4u;
    cfg.max_scan_slots = 3u;
    ml2_scan(&cfg, read_slot, &reader, &result);
    CHECK(result.fault == ML2_FAULT_EXTENT && reader.calls == 0u);
    uint64_t offset = 0;
    CHECK(ml2_checked_slot_offset(3u, 4096u, INT64_MAX, &offset) == 0);
    CHECK(offset == 12288u);
    CHECK(ml2_checked_slot_offset(UINT64_MAX, 4096u, INT64_MAX, &offset) != 0);

    puts("media_log_v2 source vectors passed");
    return 0;
}
