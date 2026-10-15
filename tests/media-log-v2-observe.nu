#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Data, expected results and pass/fail logic stay in Nushell.
use ./media-log-v2-fixtures.nu regression-fixtures

def require [ok: bool, detail: string] {
    if not $ok { error make {msg: $detail} }
}

def decimal-u64 [value: string] {
    require (($value | str length) <= 20) "oversized decimal observation"
    require ($value =~ '^(0|[1-9][0-9]*)$') "noncanonical decimal observation"
    if ($value | str length) == 20 {
        require ($value <= "18446744073709551615") "overflowing decimal observation"
    }
}

def exact-hex [value: string, bytes: int] {
    require (($value | str length) == ($bytes * 2)) "wrong hex observation length"
    require ($value =~ '^[0-9a-f]+$') "noncanonical hex observation"
}

def record-zero [value: record] {
    ($value.store_id_hex == "00000000000000000000000000000000" and
     $value.stream_epoch == "0" and $value.request_tid == "0" and
     $value.descriptor_hex == "0000000000000000")
}

def parse-observation [raw: string, operation: string] {
    require (($raw | str length) <= 4096) "oversized observation"
    require (not ($raw | str contains '\')) "escaped JSON is outside adapter grammar"
    let found = ($raw | parse --regex '"(?<key>[a-z_]+)":' | get key)
    require (($found | length) == ($found | uniq | length)) "duplicate JSON observation key"
    let parsed = (try { $raw | from json } catch { error make {msg: "malformed native JSON observation"} })
    let top = (match $operation {
        "ml2_checked_slot_offset" => { [return_code out] }
        "ml2_decode_record" => { [status out_zero record] }
        "ml2_exact_retry" => { [return_code] }
        "ml2_scan" => { [calls indices classification fault fault_slot candidate_zero candidate] }
        _ => { error make {msg: "unknown observation operation"} }
    })
    require ((($parsed | columns) | sort) == ($top | sort)) "unknown or missing top-level observation key"
    if $operation == "ml2_decode_record" or $operation == "ml2_scan" {
        let nested = (if $operation == "ml2_decode_record" { $parsed.record } else { $parsed.candidate })
        if $nested != null {
            let fields = [store_id_hex stream_epoch request_tid descriptor_hex]
            require ((($nested | columns) | sort) == ($fields | sort)) "unknown or missing record field"
            for key in $fields { require ((($nested | get $key) | describe) == "string") $"wrong record field type: ($key)" }
            exact-hex $nested.store_id_hex 16
            decimal-u64 $nested.stream_epoch
            decimal-u64 $nested.request_tid
            exact-hex $nested.descriptor_hex 8
        }
    }
    if $operation == "ml2_checked_slot_offset" {
        require (($parsed.return_code | describe) == "int") "wrong return type"
        require ($parsed.return_code in [-1 0]) "unknown offset return code"
        require (($parsed.out | describe) == "string") "wrong offset type"
        decimal-u64 $parsed.out
    } else if $operation == "ml2_exact_retry" {
        require (($parsed.return_code | describe) == "int") "wrong retry return type"
        require ($parsed.return_code in [0 1]) "unknown retry return code"
    } else if $operation == "ml2_decode_record" {
        require (($parsed.status | describe) == "string") "wrong decode status type"
        require ($parsed.status in [ML2_DECODE_OK ML2_DECODE_SHORT ML2_DECODE_FORMAT ML2_DECODE_CRC ML2_DECODE_ARGUMENT]) "unknown decode status"
        if $parsed.record == null {
            require ($parsed.out_zero == null) "null record must have null zero-state"
            require ($parsed.status == "ML2_DECODE_ARGUMENT") "null output status"
        } else {
            require (($parsed.out_zero | describe) == "bool") "wrong decode zero-state type"
            if $parsed.status != "ML2_DECODE_OK" { require $parsed.out_zero "failed decode fields not cleared" }
            if $parsed.out_zero { require (record-zero $parsed.record) "decode record fields not zero" }
        }
    } else {
        require (($parsed.calls | describe) == "int") "wrong callback count type"
        require ($parsed.calls >= 0 and $parsed.calls <= 64) "callback count outside cap"
        require (($parsed.indices | describe | str starts-with "list") == true) "wrong callback indices type"
        for item in $parsed.indices { require (($item | describe) == "string") "wrong callback index type" }
        require (($parsed.indices | length) == $parsed.calls) "callback count/index mismatch"
        for item in $parsed.indices { decimal-u64 $item }
        if $parsed.candidate == null {
            require ($parsed.classification == null and $parsed.fault == null and $parsed.fault_slot == null and $parsed.candidate_zero == null) "null scan output relationship"
        } else {
            require (($parsed.classification | describe) == "string") "wrong scan class type"
            require (($parsed.fault | describe) == "string") "wrong scan fault type"
            require (($parsed.fault_slot | describe) == "string") "wrong scan slot type"
            require (($parsed.candidate_zero | describe) == "bool") "wrong candidate zero-state type"
            require ($parsed.classification in [ML2_SCAN_FAULT ML2_SCAN_PREFIX_EXACT ML2_SCAN_ONE_UNACKED_CANDIDATE]) "unknown scan class"
            require ($parsed.fault in [ML2_FAULT_NONE ML2_FAULT_ARGUMENT ML2_FAULT_EXTENT ML2_FAULT_IO ML2_FAULT_EOF ML2_FAULT_SHORT ML2_FAULT_FORMAT ML2_FAULT_CRC ML2_FAULT_IDENTITY ML2_FAULT_TID ML2_FAULT_EXTRA_SUFFIX]) "unknown scan fault"
            decimal-u64 $parsed.fault_slot
            require (($parsed.classification == "ML2_SCAN_FAULT") == ($parsed.fault != "ML2_FAULT_NONE")) "scan class/fault conflict"
            if $parsed.candidate_zero { require (record-zero $parsed.candidate) "candidate zero-state mismatch" }
            if $parsed.classification == "ML2_SCAN_FAULT" { require $parsed.candidate_zero "fault candidate not cleared" }
            if $parsed.classification == "ML2_SCAN_PREFIX_EXACT" { require $parsed.candidate_zero "prefix has candidate" }
        }
    }
    $parsed
}

def observed [binary: string, timeout_path: string, name: string, operation: string, arguments: list<string>] {
    let run = (do { ^$timeout_path -k 1s 5s $binary ...$arguments } | complete)
    print --stderr ({name: $name, arguments: $arguments, exit_code: $run.exit_code, stdout: $run.stdout, stderr: $run.stderr} | to json --raw)
    require ($run.exit_code != 124) $"($name): native child timed out"
    require (not ($run.exit_code in [125 126 127])) $"($name): timeout or child launch failed"
    require ($run.exit_code == 0) $"native child failed: ($run.exit_code) stderr=($run.stderr)"
    require ($run.stderr == "") $"native child wrote stderr: ($run.stderr)"
    let lines = ($run.stdout | lines)
    require (($lines | length) == 1) "native child must emit exactly one JSON line"
    parse-observation $lines.0 $operation
}

def expect-rejected [binary: string, timeout_path: string, name: string, arguments: list<string>] {
    let run = (do { ^$timeout_path -k 1s 5s $binary ...$arguments } | complete)
    print --stderr ({name: $name, arguments: $arguments, exit_code: $run.exit_code, stdout: $run.stdout, stderr: $run.stderr} | to json --raw)
    require ($run.exit_code != 124) $"($name): native child timed out"
    require (not ($run.exit_code in [125 126 127])) $"($name): timeout or child launch failed"
    require ($run.exit_code != 0) $"($name): malformed protocol was accepted"
    require ($run.stdout == "") $"($name): malformed protocol emitted observation"
    {name: $name, arguments: $arguments, exit_code: $run.exit_code, stderr: $run.stderr}
}

def expect-bad-output [name: string, raw: string] {
    let rejected = (try { parse-observation $raw "ml2_checked_slot_offset"; false } catch { true })
    print --stderr ({name: $name, raw: $raw, rejected: $rejected} | to json --raw)
    require $rejected $"($name): malformed observation accepted"
    $name
}

def arguments [case: record] {
    let i = $case.input
    match $case.operation {
        "ml2_checked_slot_offset" => {
            [offset $i.index $i.stride $i.maximum_offset ($i.initial_out? | default "123") $i.out_pointer]
        }
        "ml2_decode_record" => {
            [decode $i.hex ($i.available | into string) $i.expected_magic
              ($i.bytes_pointer? | default "valid") ($i.out_pointer? | default "valid")]
        }
        "ml2_exact_retry" => {
            [retry $i.record_hex $i.store_id_hex $i.stream_epoch $i.request_tid
              $i.descriptor_hex ($i.record_pointer? | default "valid")
              ($i.store_pointer? | default "valid") ($i.descriptor_pointer? | default "valid") "843861331"]
        }
        "ml2_scan" => {
            let c = $i.config
            let head = [scan $c.expected_magic $c.store_id_hex $c.stream_epoch
              $c.witness_next $c.slot_count $c.max_scan_slots
              ($i.config_pointer? | default "valid") ($i.reader_pointer? | default "valid")
              ($i.out_pointer? | default "valid")]
            let tail = ($i.slots | reduce --fold [] {|slot, acc|
                $acc | append [$slot.status ($slot.available | into string) $slot.hex] | flatten
            })
            $head | append $tail | flatten
        }
        _ => { error make {msg: $"unknown operation: ($case.operation)"} }
    }
}

def make-scan [name: string, config: record, slots: list<record>, expected: record] {
    {name: $name, operation: "ml2_scan", input: {config: $config, slots: $slots}, expected: $expected}
}

def added-cases [fixed: record] {
    let rows = $fixed.cases
    let base = ($rows | where name == "one-unacked" | first)
    let c = $base.input.config
    let slots = $base.input.slots
    let record0 = $fixed.fixed_vectors.records_hex.0
    let record1 = $fixed.fixed_vectors.records_hex.1
    let record2 = $fixed.fixed_vectors.records_hex.2
    let wrong_store = ($c | merge {store_id_hex: "00544f52450000000000000000000000"})
    let wrong_epoch = ($c | merge {stream_epoch: "8"})
    let tid0 = ($slots | update 0 {status: "ML2_SLOT_BYTES", available: 56, hex: $record1})
    let tid2 = ($slots | update 2 {status: "ML2_SLOT_BYTES", available: 56, hex: $record1})
    let invalid0 = ($slots | update 1 {status: "ML2_SLOT_BYTES", available: 0, hex: $record1})
    let invalid57 = ($slots | update 1 {status: "ML2_SLOT_BYTES", available: 57, hex: $record1})
    let invalid_status = ($slots | update 1 {status: "INVALID", available: 56, hex: $record1})
    let bad_later = ($slots | update 3 {status: "ML2_SLOT_IO_ERROR", available: 0, hex: $fixed.fixed_vectors.records_hex.3})
    let first_tid_later_io = ($tid0 | update 1 {status: "ML2_SLOT_IO_ERROR", available: 0, hex: $record1})
    let bad_magic = "004d4c320200380053544f5245000000000000000000000007000000000000000000000000000000010203040506070800000000a88ed149"
    let bad_version = ($record0 | str replace "534d4c3202003800" "534d4c3203003800")
    let bad_length = ($record0 | str replace "534d4c3202003800" "534d4c3202003900")
    let bad_reserved = ($record0 | str replace "010203040506070800000000a88ed149" "010203040506070801000000a88ed149")
    let bad_crc = ($record0 | str replace "a88ed149" "a88ed100")
    let high_record = "534d4c320200380053544f52450000000000000000000000ffffffffffffffffffffffffffffffff010203040506070800000000ea10078d"
    [
      (make-scan "wrong-store" $wrong_store $slots {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_IDENTITY", fault_slot: "0", calls: 3, candidate_zero: true})
      (make-scan "wrong-epoch" $wrong_epoch $slots {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_IDENTITY", fault_slot: "0", calls: 3, candidate_zero: true})
      (make-scan "wrong-tid-prefix" $c $tid0 {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_TID", fault_slot: "0", calls: 3, candidate_zero: true})
      (make-scan "wrong-tid-candidate" $c $tid2 {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_TID", fault_slot: "2", calls: 3, candidate_zero: true})
      (make-scan "available-zero" $c $invalid0 {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_ARGUMENT", fault_slot: "1", calls: 3, candidate_zero: true})
      (make-scan "available-over-record" $c $invalid57 {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_ARGUMENT", fault_slot: "1", calls: 3, candidate_zero: true})
      (make-scan "unknown-reader-status" $c $invalid_status {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_ARGUMENT", fault_slot: "1", calls: 3, candidate_zero: true})
      (make-scan "candidate-then-io-fault" ($c | merge {slot_count: "4"}) $bad_later {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_IO", fault_slot: "3", calls: 4, candidate_zero: true})
      (make-scan "first-tid-wins-later-io" $c $first_tid_later_io {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_TID", fault_slot: "0", calls: 3, candidate_zero: true})
      (make-scan "zero-policy" ($c | merge {max_scan_slots: "0"}) $slots {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_ARGUMENT", fault_slot: "0", calls: 0, candidate_zero: true})
      {name: "null-config", operation: "ml2_scan", input: {config: $c, slots: $slots, config_pointer: "null"}, expected: {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_ARGUMENT", fault_slot: "0", calls: 0, candidate_zero: true}}
      {name: "null-reader", operation: "ml2_scan", input: {config: $c, slots: $slots, reader_pointer: "null"}, expected: {classification: "ML2_SCAN_FAULT", fault: "ML2_FAULT_ARGUMENT", fault_slot: "0", calls: 0, candidate_zero: true}}
      {name: "null-scan-out", operation: "ml2_scan", input: {config: $c, slots: $slots, out_pointer: "null"}, expected: {classification: null, fault: null, fault_slot: null, calls: 0, candidate_zero: null}}
      {name: "decode-bad-magic", operation: "ml2_decode_record", input: {hex: $bad_magic, available: 56, expected_magic: "843861331"}, expected: {status: "ML2_DECODE_FORMAT", out_zero: true}}
      {name: "decode-bad-version", operation: "ml2_decode_record", input: {hex: $bad_version, available: 56, expected_magic: "843861331"}, expected: {status: "ML2_DECODE_FORMAT", out_zero: true}}
      {name: "decode-bad-length", operation: "ml2_decode_record", input: {hex: $bad_length, available: 56, expected_magic: "843861331"}, expected: {status: "ML2_DECODE_FORMAT", out_zero: true}}
      {name: "decode-bad-reserved", operation: "ml2_decode_record", input: {hex: $bad_reserved, available: 56, expected_magic: "843861331"}, expected: {status: "ML2_DECODE_FORMAT", out_zero: true}}
      {name: "decode-oversized", operation: "ml2_decode_record", input: {hex: ($record0 + "00"), available: 57, expected_magic: "843861331"}, expected: {status: "ML2_DECODE_FORMAT", out_zero: true}}
      {name: "decode-high-u64", operation: "ml2_decode_record", input: {hex: $high_record, available: 56, expected_magic: "843861331"}, expected: {status: "ML2_DECODE_OK", out_zero: false, store_id_hex: $c.store_id_hex, stream_epoch: "18446744073709551615", request_tid: "18446744073709551615", descriptor_hex: "0102030405060708"}}
      {name: "decode-bad-crc", operation: "ml2_decode_record", input: {hex: $bad_crc, available: 56, expected_magic: "843861331"}, expected: {status: "ML2_DECODE_CRC", out_zero: true}}
      {name: "decode-null-bytes", operation: "ml2_decode_record", input: {hex: $record0, available: 56, expected_magic: "843861331", bytes_pointer: "null"}, expected: {status: "ML2_DECODE_ARGUMENT", out_zero: true}}
      {name: "decode-null-out", operation: "ml2_decode_record", input: {hex: $record0, available: 56, expected_magic: "843861331", out_pointer: "null"}, expected: {status: "ML2_DECODE_ARGUMENT", out_zero: null}}
      {name: "retry-wrong-store", operation: "ml2_exact_retry", input: {record_hex: $record2, store_id_hex: "00544f52450000000000000000000000", stream_epoch: "7", request_tid: "2", descriptor_hex: "0102030405060708"}, expected: {return_code: 0}}
      {name: "retry-wrong-tid", operation: "ml2_exact_retry", input: {record_hex: $record2, store_id_hex: $c.store_id_hex, stream_epoch: "7", request_tid: "3", descriptor_hex: "0102030405060708"}, expected: {return_code: 0}}
      {name: "retry-u64-epoch", operation: "ml2_exact_retry", input: {record_hex: $record2, store_id_hex: $c.store_id_hex, stream_epoch: "18446744073709551615", request_tid: "2", descriptor_hex: "0102030405060708"}, expected: {return_code: 0}}
      {name: "retry-u64-tid", operation: "ml2_exact_retry", input: {record_hex: $record2, store_id_hex: $c.store_id_hex, stream_epoch: "7", request_tid: "18446744073709551615", descriptor_hex: "0102030405060708"}, expected: {return_code: 0}}
      {name: "retry-high-u64-positive", operation: "ml2_exact_retry", input: {record_hex: $high_record, store_id_hex: $c.store_id_hex, stream_epoch: "18446744073709551615", request_tid: "18446744073709551615", descriptor_hex: "0102030405060708"}, expected: {return_code: 1}}
      {name: "retry-high-epoch-32bit-alias", operation: "ml2_exact_retry", input: {record_hex: $high_record, store_id_hex: $c.store_id_hex, stream_epoch: "4294967295", request_tid: "18446744073709551615", descriptor_hex: "0102030405060708"}, expected: {return_code: 0}}
      {name: "retry-high-tid-32bit-alias", operation: "ml2_exact_retry", input: {record_hex: $high_record, store_id_hex: $c.store_id_hex, stream_epoch: "18446744073709551615", request_tid: "4294967295", descriptor_hex: "0102030405060708"}, expected: {return_code: 0}}
      {name: "retry-null-record", operation: "ml2_exact_retry", input: {record_hex: $record2, store_id_hex: $c.store_id_hex, stream_epoch: "7", request_tid: "2", descriptor_hex: "0102030405060708", record_pointer: "null"}, expected: {return_code: 0}}
      {name: "retry-null-store", operation: "ml2_exact_retry", input: {record_hex: $record2, store_id_hex: $c.store_id_hex, stream_epoch: "7", request_tid: "2", descriptor_hex: "0102030405060708", store_pointer: "null"}, expected: {return_code: 0}}
      {name: "retry-null-descriptor", operation: "ml2_exact_retry", input: {record_hex: $record2, store_id_hex: $c.store_id_hex, stream_epoch: "7", request_tid: "2", descriptor_hex: "0102030405060708", descriptor_pointer: "null"}, expected: {return_code: 0}}
    ]
}

def assert-case [case: record, got: record] {
    let name = $case.name
    let e = $case.expected
    if $case.operation == "ml2_decode_record" and $got.status == "ML2_DECODE_OK" {
        for field in [store_id_hex stream_epoch request_tid descriptor_hex] {
            require ($field in ($e | columns)) $"($name): missing decoded field expectation ($field)"
        }
    }
    for key in ($e | columns) {
        if $key == "candidate_tid" {
            require ($got.candidate.request_tid == $e.candidate_tid) $"($name): candidate TID"
        } else if $key == "out" {
            require ($got.out == $e.out) $"($name): offset output"
        } else if $case.operation == "ml2_decode_record" and $got.status == "ML2_DECODE_OK" and ($key in [store_id_hex stream_epoch request_tid descriptor_hex]) {
            require (($got.record | get $key) == ($e | get $key)) $"($name): ($key) mismatch"
        } else {
            require (($got | get $key) == ($e | get $key)) $"($name): ($key) mismatch"
        }
    }
    if $case.operation == "ml2_scan" {
        let known_slots = {
          "two-above-w": "3", "partial-second-candidate": "3",
          "missing-witnessed": "1", "io-error": "1", "short-witnessed": "1",
          "forged-length": "2", "bad-crc": "2", "witness-beyond-extent": "0",
          "extent-exceeds-policy": "0"
        }
        let expected_slot = ($e.fault_slot? | default ($known_slots | get -o $name))
        if $expected_slot != null {
            require ($got.fault_slot == $expected_slot) $"($name): first fault slot mismatch"
        }
        let n = $e.calls
        let sequence = (if $n == 0 { [] } else { 0..($n - 1) | each {|x| $x | into string} })
        require ($got.indices == $sequence) $"($name): callback order mismatch"
        if $got.classification == "ML2_SCAN_ONE_UNACKED_CANDIDATE" {
            require ($got.candidate.store_id_hex == "53544f52450000000000000000000000") $"($name): candidate store"
            require ($got.candidate.stream_epoch == "7") $"($name): candidate epoch"
            require ($got.candidate.request_tid == "2") $"($name): candidate TID"
            require ($got.candidate.descriptor_hex == "0102030405060708") $"($name): candidate descriptor"
        }
        if $got.classification == "ML2_SCAN_FAULT" {
            require $got.candidate_zero $"($name): candidate fields not cleared"
        }
    }
}

def main [binary: string, timeout_path: string] {
    let fixed = (regression-fixtures)
    require (($fixed.cases | length) == 28) "original fixture count changed"
    require ($fixed.fixed_vectors.crc32_ieee_123456789 == "cbf43926") "CRC vector changed"
    let added = (added-cases $fixed)
    require (($added | length) == 32) "added fixture count changed"
    let cases = ($added | reduce --fold $fixed.cases {|row, acc| $acc | append $row })
    require (($cases | length) == 60) "combined fixture count changed"
    for row in $cases {
        require ((($row | columns) | sort) == ([name operation input expected] | sort)) "case record shape changed"
        require (($row.input | describe -d | get type) == "record") "case input is not a record"
        require (($row.expected | describe -d | get type) == "record") "case expectation is not a record"
    }
    let names = ($cases | get name)
    require (($names | uniq | length) == ($cases | length)) "duplicate case name"
    mut receipts = []
    for case in $cases {
        let args = (arguments $case)
        let got = (observed $binary $timeout_path $case.name $case.operation $args)
        assert-case $case $got
        $receipts = ($receipts | append {name: $case.name, arguments: $args, observation: $got})
    }
    require (($receipts | length) == ($cases | length)) "skipped case"
    let malformed = [
      (expect-rejected $binary $timeout_path "negative-decimal-sign" [offset "-1" "1" "55" "123" valid])
      (expect-rejected $binary $timeout_path "negative-decimal-overflow" [offset "18446744073709551616" "1" "55" "123" valid])
      (expect-rejected $binary $timeout_path "negative-decimal-trailing" [offset "0x0" "1" "55" "123" valid])
      (expect-rejected $binary $timeout_path "negative-hex-odd" [decode "f" "1" "843861331" valid valid])
      (expect-rejected $binary $timeout_path "negative-unknown-operation" [unknown])
      (expect-rejected $binary $timeout_path "negative-missing-field" [offset "0" "1"])
      (expect-rejected $binary $timeout_path "negative-extra-field" [offset "0" "1" "55" "123" valid extra])
      (expect-rejected $binary $timeout_path "negative-decimal-whitespace" [offset " 0" "1" "55" "123" valid])
      (expect-rejected $binary $timeout_path "negative-hex-nonhex" [decode "gg" "1" "843861331" valid valid])
      (expect-rejected $binary $timeout_path "negative-hex-overlong" [decode "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" "57" "843861331" valid valid])
      (expect-rejected $binary $timeout_path "negative-pointer-mode" [offset "0" "1" "55" "123" bogus])
      (expect-rejected $binary $timeout_path "negative-status-mode" [scan "843861331" "53544f52450000000000000000000000" "7" "0" "1" "1" valid valid valid bogus "56" ""])
    ]
    let too_many_slots = (0..64 | reduce --fold [] {|_, acc| $acc | append ["ML2_SLOT_BYTES" "56" ""] | flatten })
    let over_cap_args = ([scan "843861331" "53544f52450000000000000000000000" "7" "0" "0" "64" valid valid valid] | append $too_many_slots | flatten)
    let over_cap = (expect-rejected $binary $timeout_path "negative-over-64-slots" $over_cap_args)
    let fake_output = [
      (expect-bad-output "duplicate-key" '{"return_code":0,"return_code":1,"out":"0"}')
      (expect-bad-output "escaped-duplicate-key" '{"return_code":0,"\u0072eturn_code":1,"out":"0"}')
      (expect-bad-output "unknown-key" '{"return_code":0,"out":"0","extra":1}')
      (expect-bad-output "wrong-type" '{"return_code":"0","out":"0"}')
      (expect-bad-output "trailing-json" '{"return_code":0,"out":"0"}{"return_code":0,"out":"0"}')
      (expect-bad-output "missing-field" '{"return_code":0}')
    ]
    {status: "PASSED_NATIVE_LOGICAL_CASES_ONLY", original: 28, added: (($cases | length) - 28), receipts: $receipts, malformed_protocol_controls: ($malformed | append $over_cap), fake_output_controls: $fake_output} | to json
}
