#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Exploratory same-ELF Firecracker APIC/PIC comparison. The separate
# candidate functional gate must prove guest TCP, host ping, and shell.

def fail [message: string] {
    error make {msg: $message}
}

def elapsed-ms [start: datetime] {
    (((date now) - $start) / 1ms) | into int
}

# Keep byte-for-byte serial in `log` while stamping each line *as it arrives*.
# timeout owns the exact child and sends TERM, then KILL; no broad pkill.
def capture [executable: string, args: list<string>, log: string, seconds: int] {
    let start = date now
    let limit = $"($seconds)s"
    with-env {LC_ALL: C} {
        ^timeout --verbose --signal=TERM --kill-after=1s $limit $executable ...$args o+e>| ^tee $log
            | lines
            | each {|line| {ms: (elapsed-ms $start), line: ($line | str trim)} }
    }
}

def signaled-at-limit [rows: list<record>] {
    ($rows | where {|row| $row.line | str starts-with "timeout: sending signal TERM to command"} | length) == 1
}

def first-exact-ms [rows: list<record>, needle: string] {
    $rows | where {|row| $row.line == $needle} | get 0?.ms
}

def median [numbers: list<number>] {
    let sorted = $numbers | sort
    let count = $sorted | length
    if $count == 0 { return null }
    if ($count mod 2) == 1 {
        $sorted | get ($count // 2)
    } else {
        ((($sorted | get ($count // 2 - 1)) + ($sorted | get ($count // 2))) / 2)
    }
}

def config [kernel: string, mode: string, panic_probe: bool] {
    if $mode not-in [apic pic] { fail $"unknown interrupt mode: ($mode)" }
    let apic_arg = if $mode == "pic" { "hint.apic.0.disabled=1 " } else { "" }
    let panic_arg = if $panic_probe { " smolfire.test.panic=1" } else { "" }
    let args = $"hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0 boot_mute=YES ($apic_arg)smolfire.ip=172.16.0.2/30 smolfire.gw=172.16.0.1 smolfire.fetch=http://172.16.0.1:8080/token.txt($panic_arg)"
    {
        "boot-source": {kernel_image_path: $kernel, boot_args: $args}
        drives: []
        "network-interfaces": [{iface_id: eth0, guest_mac: "06:00:AC:10:00:02", host_dev_name: tap0}]
        "machine-config": {vcpu_count: 1, mem_size_mib: 512}
    }
}

def run-boot [work: string, kernel: string, firecracker: string, label: string, mode: string, panic_probe: bool] {
    let out = $"($work)/apic-pic-pair"
    let token = $"pair-(random chars --length 24)"
    let token_file = $"($work)/www/token.txt"
    $token | save -f $token_file
    let response = (do -i { ^curl --max-time 3 -fsS http://172.16.0.1:8080/token.txt | str trim })
    if $response != $token { fail $"token server preflight failed for ($label)" }

    let json_path = $"($out)/($label).fc.json"
    let log_path = $"($out)/($label).serial.log"
    let result_path = $"($out)/($label).json"
    config $kernel $mode $panic_probe | to json | save -f $json_path

    let rows = capture $firecracker [--no-api --config-file $json_path] $log_path 4
    let ready_ms = first-exact-ms $rows SMOLFIRE_READY
    let net_ms = first-exact-ms $rows $"SMOLFIRE_NET_OK ($token)"
    let panic_line = $rows | where {|row| ($row.line | str lowercase) =~ 'panic:'} | get 0?.line
    let bounded_exit = signaled-at-limit $rows
    let net_fail = ($rows | where {|row| $row.line | str contains SMOLFIRE_NET_FAIL} | length) > 0
    let ready_value = ($ready_ms | default (-1))
    let net_value = ($net_ms | default (-1))
    let ready_and_net = $ready_value > 0 and $net_value >= 0 and $net_value <= $ready_value and not $net_fail
    let expected_panic = (($panic_line | default "") | str contains "smolfire-pic-panic-probe")
    let chatter = if $ready_ms == null { [] } else {
        $rows | where {|row|
            $row.ms < $ready_ms and (($row.line | str starts-with "Copyright") or ($row.line | str starts-with "FreeBSD"))
        } | get line
    }
    let verdict = if $panic_probe {
        if $bounded_exit and $expected_panic and $ready_and_net { "panic-visible" } else { "panic-inconclusive" }
    } else if $bounded_exit and $panic_line == null and $ready_and_net {
        "pass"
    } else {
        "fail"
    }
    let result = {
        label: $label, mode: $mode, panic_probe: $panic_probe, verdict: $verdict
        ready_ms: $ready_ms, net_ms: $net_ms, panic_line: $panic_line, bounded_exit: $bounded_exit
        boot_chatter_lines: ($chatter | length), boot_chatter_samples: ($chatter | first 5)
        config: $json_path, serial: $log_path, token: $token
    }
    $result | to json | save -f $result_path
    print $"($label): ($verdict), READY=($ready_ms), NET=($net_ms)"
    $result
}

def "main selftest" [] {
    let created = (^mktemp -d | complete)
    let temp = ($created.stdout | str trim)
    if $created.exit_code != 0 or not ($temp | str starts-with "/") or not ($temp | path exists) {
        fail "private selftest directory creation failed"
    }
    let log = $"($temp)/delayed-lines.log"
    let rows = capture nu [-c "print FIRST; sleep 500ms; print SECOND"] $log 3
    let first = first-exact-ms $rows FIRST
    let second = first-exact-ms $rows SECOND
    if $first == null or $second == null or ($second - $first) < 400 or ($second - $first) > 2000 {
        fail $"stream timestamp fixture failed: ($rows | to json)"
    }
    if (open --raw $log | decode utf-8) != "FIRST\nSECOND\n" {
        fail "raw serial fixture did not retain both lines"
    }
    let apic = config /tmp/test-kernel apic false
    let pic = config /tmp/test-kernel pic false
    if ($apic | get "boot-source" | get kernel_image_path) != ($pic | get "boot-source" | get kernel_image_path) {
        fail "paired configurations changed the release ELF"
    }
    let changed = ($pic | get "boot-source" | get boot_args | str replace "hint.apic.0.disabled=1 " "")
    if $changed != ($apic | get "boot-source" | get boot_args) {
        fail "paired configurations changed more than the APIC-disable hint"
    }
    if not (($apic | get "boot-source" | get boot_args) | str contains "boot_mute=YES") {
        fail "paired controls did not keep boot_mute fixed"
    }
    if (median [1.0 2.0]) != 1.5 { fail "paired median arithmetic failed" }
    let early_log = $"($temp)/early-exit.log"
    let early = capture nu [-c "print EARLY"] $early_log 1
    if (signaled-at-limit $early) { fail "early child exit appeared to reach the timeout boundary" }
    let held_log = $"($temp)/held.log"
    let held = capture nu [-c "print HELD; sleep 2sec"] $held_log 1
    if not (signaled-at-limit $held) { fail "timeout child boundary was not recorded" }
    let removed_log = (^rm -- $log | complete)
    let removed_early = (^rm -- $early_log | complete)
    let removed_held = (^rm -- $held_log | complete)
    let removed_dir = (^rmdir -- $temp | complete)
    if $removed_log.exit_code != 0 or $removed_early.exit_code != 0 or $removed_held.exit_code != 0 or $removed_dir.exit_code != 0 or ($temp | path exists) {
        fail "private selftest cleanup failed"
    }
    print $"apic-pic-pair selftest: streamed delay ($second - $first)ms"
}

def main [
    --work: string = "/mnt/smolfire-ci"
    --runs: int = 3
] {
    if $runs < 3 { fail "at least three ABBA rounds are required" }
    let kernel = $"($work)/smolfire-kernel"
    let firecracker = $"($work)/firecracker"
    let out = $"($work)/apic-pic-pair"
    if not ($kernel | path exists) or not ($firecracker | path exists) {
        fail "release ELF or Firecracker binary is missing"
    }
    if not ($"($work)/www/token.txt" | path exists) or not ($"($work)/fc.json" | path exists) or not ($"($work)/firecracker-gate.log" | path exists) or not ($"($work)/firecracker-gate.rc" | path exists) {
        fail "network server or candidate functional gate evidence is missing"
    }
    # Do not kill another step's instance if its cleanup failed.
    let existing = ((do -i { ^pgrep -f $"^($firecracker) --no-api" | str trim }) | default "")
    if $existing != "" { fail $"Firecracker already owns TAP: ($existing)" }
    mkdir $out

    let kernel_sha = (open --raw $kernel | hash sha256)
    let kernel_bytes = (ls $kernel | get 0.size | into int)
    {schema: "smolfire.apic-pic-pair/v1", kernel: $kernel, sha256: $kernel_sha, bytes: $kernel_bytes,
     method: "same ELF with atpic; APIC/default vs PIC hint; boot_mute=YES fixed; ABBA interleaved; fresh bounded Firecracker per boot; host line-arrival timestamps",
     panic_method: "guest-only debug.kdb.panic_str after READY under smolfire.test.panic=1; separate PIC boot"}
        | to json | save -f $"($out)/manifest.json"

    mut results = []
    for round in 1..$runs {
        for step in ([apic pic pic apic] | enumerate) {
            let mode = $step.item
            let label = $"r($round)-s($step.index + 1)-($mode)"
            let result = run-boot $work $kernel $firecracker $label $mode false
            $results = $results | append $result
        }
    }
    # A separate PIC guest deliberately panics after READY and network proof.
    let panic_result = run-boot $work $kernel $firecracker panic-after-ready pic true
    let kernel_after = (open --raw $kernel | hash sha256)
    if $kernel_after != $kernel_sha { fail "release ELF changed during paired boots" }

    let final_results = $results
    let pairs = 1..$runs | each {|round|
        let group = $final_results | where {|r| $r.label | str starts-with $"r($round)-"}
        let baseline = $group | where mode == apic | get ready_ms | compact
        let candidate = $group | where mode == pic | get ready_ms | compact
        if ($baseline | length) != 2 or ($candidate | length) != 2 {
            {round: $round, valid: false, apic_mean_ms: null, pic_mean_ms: null, delta_ms: null}
        } else {
            let base_mean = (($baseline | math sum) / 2)
            let pic_mean = (($candidate | math sum) / 2)
            {round: $round, valid: true, apic_mean_ms: $base_mean, pic_mean_ms: $pic_mean, delta_ms: ($pic_mean - $base_mean)}
        }
    }
    let deltas = $pairs | get delta_ms | compact
    let gate_config = open $"($work)/fc.json"
    let gate_serial = open --raw $"($work)/firecracker-gate.log"
    let gate_pic = (($gate_config | get "boot-source" | get boot_args) | str contains "hint.apic.0.disabled=1")
    let gate_elf = (($gate_config | get "boot-source" | get kernel_image_path) == $kernel)
    let gate_mute = (($gate_config | get "boot-source" | get boot_args) | str contains "boot_mute=YES")
    let gate_rc = (open --raw $"($work)/firecracker-gate.rc" | str trim)
    let gate_functional = $gate_pic and $gate_elf and $gate_mute and $gate_rc == "0" and ($gate_serial | str contains "NET_GATE=pass") and ($gate_serial | str contains "HOST_PING=pass") and ($gate_serial | str contains "SHELL_GATE=pass") and ($gate_serial | str contains "BOOT_TRACE=pass")
    let valid = (($results | where verdict != pass | length) == 0) and (($pairs | where valid == false | length) == 0) and $gate_functional
    let within_100ms = $valid and (($results | where mode == pic | where ready_ms > 100 | length) == 0)
    let report = {
        schema: "smolfire.apic-pic-pair/v1", kernel_sha256: $kernel_sha,
        valid: $valid, pic_within_100ms: $within_100ms,
        candidate_functional_gate: $gate_functional, candidate_functional_rc: $gate_rc,
        panic_visibility: $panic_result.verdict, paired_delta_median_ms: (median $deltas),
        pairs: $pairs, runs: $results
    }
    $report | to json | save -f $"($out)/report.json"
    print ($report | to json)
    if not $valid or $panic_result.verdict != "panic-visible" {
        fail "paired boot evidence invalid or panic serial visibility inconclusive"
    }
    if not $within_100ms {
        fail "PIC candidate release ELF did not meet the <=100ms boot goal"
    }
}
