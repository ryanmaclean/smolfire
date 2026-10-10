/* SPDX-License-Identifier: Apache-2.0 */
#ifndef SMOLFIRE_MEDIA_LOG_V2_H
#define SMOLFIRE_MEDIA_LOG_V2_H

#include <stddef.h>
#include <stdint.h>

/* Proposed logical v2 record. Physical slot stride and magic are backend-owned. */
#define ML2_RECORD_BYTES 56u
#define ML2_DESCRIPTOR_BYTES 8u

struct ml2_record {
    uint8_t store_id[16];
    uint64_t stream_epoch;
    uint64_t request_tid;
    uint8_t descriptor[ML2_DESCRIPTOR_BYTES];
};

enum ml2_decode_status {
    ML2_DECODE_OK,
    ML2_DECODE_SHORT,
    ML2_DECODE_FORMAT,
    ML2_DECODE_CRC,
    ML2_DECODE_ARGUMENT
};

/* Validates declared length and all fixed fields before CRC or output use. */
enum ml2_decode_status ml2_decode_record(const uint8_t *bytes, size_t available,
                                           uint32_t expected_magic,
                                           struct ml2_record *out);

/* Compare every persistent operation-key and descriptor byte, never CRC alone. */
int ml2_exact_retry(const struct ml2_record *record,
                    const uint8_t store_id[16], uint64_t stream_epoch,
                    uint64_t request_tid,
                    const uint8_t descriptor[ML2_DESCRIPTOR_BYTES]);

enum ml2_slot_read_status {
    ML2_SLOT_BYTES,     /* *available is 1..56; reader writes at most 56 bytes */
    ML2_SLOT_EOF,       /* *available is zero before trusted slot_count: fault */
    ML2_SLOT_IO_ERROR   /* read failure, distinct from EOF and short record */
};

typedef enum ml2_slot_read_status (*ml2_read_slot_fn)(
    void *context, uint64_t slot_index, uint8_t out[ML2_RECORD_BYTES],
    size_t *available);

struct ml2_scan_config {
    uint32_t expected_magic;
    uint8_t store_id[16];
    uint64_t stream_epoch;
    uint64_t witness_next;  /* W: exact acknowledged prefix [0,W) */
    uint64_t slot_count;    /* trusted complete logical extent, not guessed EOF */
    uint64_t max_scan_slots;/* finite caller policy bound; no scan above it */
};

enum ml2_scan_class {
    ML2_SCAN_FAULT,
    ML2_SCAN_PREFIX_EXACT,
    ML2_SCAN_ONE_UNACKED_CANDIDATE
};

enum ml2_fault_reason {
    ML2_FAULT_NONE,
    ML2_FAULT_ARGUMENT,
    ML2_FAULT_EXTENT,
    ML2_FAULT_IO,
    ML2_FAULT_EOF,
    ML2_FAULT_SHORT,
    ML2_FAULT_FORMAT,
    ML2_FAULT_CRC,
    ML2_FAULT_IDENTITY,
    ML2_FAULT_TID,
    ML2_FAULT_EXTRA_SUFFIX
};

struct ml2_scan_result {
    enum ml2_scan_class classification;
    enum ml2_fault_reason fault;
    uint64_t fault_slot;
    /* Diagnostic only. Never a READY session or a media receipt. */
    struct ml2_record candidate;
};

/*
 * Read every slot in [0,slot_count) before returning a non-FAULT class.
 * The backend must prove slot_count covers the full physical/logical suffix;
 * an untrusted file length cannot create READY from this classifier. A single
 * candidate still requires recovery data/W barriers and a durable G fence.
 */
void ml2_scan(const struct ml2_scan_config *config, ml2_read_slot_fn read_slot,
              void *context, struct ml2_scan_result *out);

/* Helper for a backend reader: check index*stride against its off_t ceiling. */
int ml2_checked_slot_offset(uint64_t index, uint64_t stride,
                            uint64_t maximum_offset, uint64_t *out);

#endif
