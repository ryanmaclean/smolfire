/* SPDX-License-Identifier: Apache-2.0 */
#include "media_log_v2.h"

#include <string.h>

static uint16_t load_le16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t load_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t load_le64(const uint8_t *p)
{
    return (uint64_t)load_le32(p) | ((uint64_t)load_le32(p + 4) << 32);
}

static uint32_t crc32_ieee(const uint8_t *bytes, size_t length)
{
    uint32_t crc = UINT32_MAX;
    for (size_t i = 0; i < length; ++i) {
        crc ^= bytes[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1u) ? UINT32_C(0xedb88320) : 0u);
    }
    return ~crc;
}

enum ml2_decode_status ml2_decode_record(const uint8_t *bytes, size_t available,
                                           uint32_t expected_magic,
                                           struct ml2_record *out)
{
    if (out != NULL)
        memset(out, 0, sizeof *out);
    if (bytes == NULL || out == NULL)
        return ML2_DECODE_ARGUMENT;
    if (available < ML2_RECORD_BYTES)
        return ML2_DECODE_SHORT;
    if (available != ML2_RECORD_BYTES)
        return ML2_DECODE_FORMAT;

    /* Never derive a read or CRC span from the untrusted on-media length. */
    if (load_le32(bytes) != expected_magic || load_le16(bytes + 4) != 2u ||
        load_le16(bytes + 6) != ML2_RECORD_BYTES ||
        load_le32(bytes + 48) != 0u)
        return ML2_DECODE_FORMAT;
    if (crc32_ieee(bytes, 52u) != load_le32(bytes + 52))
        return ML2_DECODE_CRC;

    memcpy(out->store_id, bytes + 8, sizeof out->store_id);
    out->stream_epoch = load_le64(bytes + 24);
    out->request_tid = load_le64(bytes + 32);
    memcpy(out->descriptor, bytes + 40, sizeof out->descriptor);
    return ML2_DECODE_OK;
}

int ml2_exact_retry(const struct ml2_record *record,
                    const uint8_t store_id[16], uint64_t stream_epoch,
                    uint64_t request_tid,
                    const uint8_t descriptor[ML2_DESCRIPTOR_BYTES])
{
    return record != NULL && store_id != NULL && descriptor != NULL &&
           memcmp(record->store_id, store_id, 16u) == 0 &&
           record->stream_epoch == stream_epoch &&
           record->request_tid == request_tid &&
           memcmp(record->descriptor, descriptor, ML2_DESCRIPTOR_BYTES) == 0;
}

int ml2_checked_slot_offset(uint64_t index, uint64_t stride,
                            uint64_t maximum_offset, uint64_t *out)
{
    if (out == NULL || stride == 0 || index > maximum_offset / stride)
        return -1;
    *out = index * stride;
    return 0;
}

static void fault_once(struct ml2_scan_result *out, enum ml2_fault_reason why,
                       uint64_t slot)
{
    if (out->fault == ML2_FAULT_NONE) {
        out->fault = why;
        out->fault_slot = slot;
    }
}

static enum ml2_fault_reason decode_fault(enum ml2_decode_status status)
{
    switch (status) {
    case ML2_DECODE_SHORT: return ML2_FAULT_SHORT;
    case ML2_DECODE_CRC: return ML2_FAULT_CRC;
    case ML2_DECODE_FORMAT: return ML2_FAULT_FORMAT;
    default: return ML2_FAULT_ARGUMENT;
    }
}

void ml2_scan(const struct ml2_scan_config *config, ml2_read_slot_fn read_slot,
              void *context, struct ml2_scan_result *out)
{
    if (out == NULL)
        return;
    memset(out, 0, sizeof *out);
    out->classification = ML2_SCAN_FAULT;
    out->fault = ML2_FAULT_ARGUMENT;
    if (config == NULL || read_slot == NULL || config->max_scan_slots == 0)
        return;
    if (config->slot_count > config->max_scan_slots ||
        config->witness_next > config->slot_count) {
        out->fault = ML2_FAULT_EXTENT;
        return;
    }

    out->fault = ML2_FAULT_NONE;
    for (uint64_t slot = 0; slot < config->slot_count; ++slot) {
        uint8_t raw[ML2_RECORD_BYTES] = {0};
        size_t available = 0;
        enum ml2_slot_read_status io = read_slot(context, slot, raw, &available);
        if (io == ML2_SLOT_IO_ERROR) {
            fault_once(out, ML2_FAULT_IO, slot);
            continue;
        }
        if (io == ML2_SLOT_EOF) {
            fault_once(out, ML2_FAULT_EOF, slot);
            continue;
        }
        if (io != ML2_SLOT_BYTES || available == 0 ||
            available > ML2_RECORD_BYTES) {
            fault_once(out, ML2_FAULT_ARGUMENT, slot);
            continue;
        }
        if (available < ML2_RECORD_BYTES) {
            fault_once(out, ML2_FAULT_SHORT, slot);
            continue;
        }
        if (slot > config->witness_next) {
            fault_once(out, ML2_FAULT_EXTRA_SUFFIX, slot);
            continue;
        }

        struct ml2_record record;
        enum ml2_decode_status decoded = ml2_decode_record(
            raw, available, config->expected_magic, &record);
        if (decoded != ML2_DECODE_OK) {
            fault_once(out, decode_fault(decoded), slot);
            continue;
        }
        if (memcmp(record.store_id, config->store_id, 16u) != 0 ||
            record.stream_epoch != config->stream_epoch) {
            fault_once(out, ML2_FAULT_IDENTITY, slot);
            continue;
        }
        if (record.request_tid != slot) {
            fault_once(out, ML2_FAULT_TID, slot);
            continue;
        }
        if (slot == config->witness_next)
            out->candidate = record;
    }

    if (config->slot_count - config->witness_next > 1u)
        fault_once(out, ML2_FAULT_EXTRA_SUFFIX, config->witness_next + 1u);
    if (out->fault != ML2_FAULT_NONE) {
        memset(&out->candidate, 0, sizeof out->candidate);
        return;
    }
    out->classification = config->slot_count == config->witness_next
        ? ML2_SCAN_PREFIX_EXACT : ML2_SCAN_ONE_UNACKED_CANDIDATE;
}
