# SPDX-License-Identifier: Apache-2.0
# Fixture proposal only. No native callable seam is admitted or supplied.
# Exported data neither executes the C implementation nor proves it correct.
# Decimal strings preserve the full unsigned 64-bit range in future bindings.
export def regression-fixtures [] {
    {
      "status": "UNCONNECTED_FIXTURE_PROPOSAL_NOT_NATIVE_TEST",
      "record_bytes": 56,
      "uint64_encoding": "decimal strings; never route through floating point",
      "fixed_vectors": {
        "crc32_ieee_123456789": "cbf43926",
        "record0_crc_le": "a88ed149",
        "records_hex": [
          "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149",
          "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c",
          "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83",
          "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
        ]
      },
      "reader_contract": "one sequential callback per slot in declared extent, including slots after first fault; obey at-most-56 write bound",
      "cases": [
        {
          "name": "exact-first",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "0",
            "stride": "1",
            "maximum_offset": "55",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": 0,
            "out": "0"
          }
        },
        {
          "name": "ceiling-too-small",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "0",
            "stride": "1",
            "maximum_offset": "54",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": -1,
            "out": "123"
          }
        },
        {
          "name": "exact-last-byte",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "1",
            "stride": "56",
            "maximum_offset": "111",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": 0,
            "out": "56"
          }
        },
        {
          "name": "one-byte-over",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "1",
            "stride": "56",
            "maximum_offset": "110",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": -1,
            "out": "123"
          }
        },
        {
          "name": "zero-stride",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "0",
            "stride": "0",
            "maximum_offset": "100",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": -1,
            "out": "123"
          }
        },
        {
          "name": "nonunit-valid",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "3",
            "stride": "4096",
            "maximum_offset": "9223372036854775807",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": 0,
            "out": "12288"
          }
        },
        {
          "name": "multiplication-overflow",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "18446744073709551615",
            "stride": "4096",
            "maximum_offset": "9223372036854775807",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": -1,
            "out": "123"
          }
        },
        {
          "name": "signed-start-only-bug",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "9223372036854775807",
            "stride": "1",
            "maximum_offset": "9223372036854775807",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": -1,
            "out": "123"
          }
        },
        {
          "name": "signed-exact",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "9223372036854775752",
            "stride": "1",
            "maximum_offset": "9223372036854775807",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": 0,
            "out": "9223372036854775752"
          }
        },
        {
          "name": "unsigned-exact",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "18446744073709551560",
            "stride": "1",
            "maximum_offset": "18446744073709551615",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": 0,
            "out": "18446744073709551560"
          }
        },
        {
          "name": "unsigned-over",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "18446744073709551561",
            "stride": "1",
            "maximum_offset": "18446744073709551615",
            "initial_out": "123",
            "out_pointer": "valid"
          },
          "expected": {
            "return_code": -1,
            "out": "123"
          }
        },
        {
          "name": "null-offset-out",
          "operation": "ml2_checked_slot_offset",
          "input": {
            "index": "0",
            "stride": "1",
            "maximum_offset": "55",
            "out_pointer": "null"
          },
          "expected": {
            "return_code": -1
          }
        },
        {
          "name": "prefix-exact",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "2",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_PREFIX_EXACT",
            "fault": "ML2_FAULT_NONE",
            "calls": 2
          }
        },
        {
          "name": "one-unacked",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "3",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_ONE_UNACKED_CANDIDATE",
            "fault": "ML2_FAULT_NONE",
            "candidate_tid": "2",
            "calls": 3
          }
        },
        {
          "name": "two-above-w",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "4",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_EXTRA_SUFFIX",
            "calls": 4,
            "candidate_zero": true
          }
        },
        {
          "name": "partial-second-candidate",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "4",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 1,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_SHORT",
            "calls": 4,
            "candidate_zero": true
          }
        },
        {
          "name": "missing-witnessed",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "3",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_EOF",
                "available": 0,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_EOF",
            "calls": 3,
            "candidate_zero": true
          }
        },
        {
          "name": "io-error",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "3",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_IO_ERROR",
                "available": 0,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_IO",
            "calls": 3,
            "candidate_zero": true
          }
        },
        {
          "name": "short-witnessed",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "3",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 17,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_SHORT",
            "calls": 3,
            "candidate_zero": true
          }
        },
        {
          "name": "forged-length",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "3",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200ffff53544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_FORMAT",
            "calls": 3,
            "candidate_zero": true
          }
        },
        {
          "name": "bad-crc",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "3",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000000020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_CRC",
            "calls": 3,
            "candidate_zero": true
          }
        },
        {
          "name": "witness-beyond-extent",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "4",
              "slot_count": "3",
              "max_scan_slots": "4"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_EXTENT",
            "calls": 0
          }
        },
        {
          "name": "extent-exceeds-policy",
          "operation": "ml2_scan",
          "input": {
            "config": {
              "expected_magic": "843861331",
              "store_id_hex": "53544f52450000000000000000000000",
              "stream_epoch": "7",
              "witness_next": "2",
              "slot_count": "4",
              "max_scan_slots": "3"
            },
            "slots": [
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000100000000000000010203040506070800000000eeb5b62c"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83"
              },
              {
                "status": "ML2_SLOT_BYTES",
                "available": 56,
                "hex": "534d4c320200380053544f524500000000000000000000000700000000000000030000000000000001020304050607080000000062c378e6"
              }
            ]
          },
          "expected": {
            "classification": "ML2_SCAN_FAULT",
            "fault": "ML2_FAULT_EXTENT",
            "calls": 0
          }
        },
        {
          "name": "decode-short",
          "operation": "ml2_decode_record",
          "input": {
            "hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83",
            "available": 55,
            "expected_magic": "843861331"
          },
          "expected": {
            "status": "ML2_DECODE_SHORT",
            "out_zero": true
          }
        },
        {
          "name": "decode-fixed-record",
          "operation": "ml2_decode_record",
          "input": {
            "hex": "534d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149",
            "available": 56,
            "expected_magic": "843861331"
          },
          "expected": {
            "status": "ML2_DECODE_OK",
            "store_id_hex": "53544f52450000000000000000000000",
            "stream_epoch": "7",
            "request_tid": "0",
            "descriptor_hex": "0102030405060708"
          }
        },
        {
          "name": "exact-retry",
          "operation": "ml2_exact_retry",
          "input": {
            "record_hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83",
            "store_id_hex": "53544f52450000000000000000000000",
            "stream_epoch": "7",
            "request_tid": "2",
            "descriptor_hex": "0102030405060708"
          },
          "expected": {
            "return_code": 1
          }
        },
        {
          "name": "changed-descriptor",
          "operation": "ml2_exact_retry",
          "input": {
            "record_hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83",
            "store_id_hex": "53544f52450000000000000000000000",
            "stream_epoch": "7",
            "request_tid": "2",
            "descriptor_hex": "0102030405060709"
          },
          "expected": {
            "return_code": 0
          }
        },
        {
          "name": "changed-epoch",
          "operation": "ml2_exact_retry",
          "input": {
            "record_hex": "534d4c320200380053544f524500000000000000000000000700000000000000020000000000000001020304050607080000000024f81f83",
            "store_id_hex": "53544f52450000000000000000000000",
            "stream_epoch": "8",
            "request_tid": "2",
            "descriptor_hex": "0102030405060708"
          },
          "expected": {
            "return_code": 0
          }
        }
      ]
    }
}
