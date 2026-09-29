#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Exploratory same-ELF Firecracker comparison. Run only after the existing
# network/shell/size gates and TSLOG capture have released Firecracker.

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
    do -i {
        ^timeout --signal=TERM --kill-after=1s $limit $executable ...$args o+e>| ^tee $log
            | lines
            | each {|line| {ms: (elapsed-ms $start), line: ($line | str trim)} }
    }
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

def config [kernel: string, mute: string, panic_probe: bool] {
    let acpi = if $panic_probe { "1" } else { "0" }
    let mute_arg = if $mute == "" { "" } else { $"boot_mute=($mute) " }
    let args = $"hint.acpi.0.disabled=($acpi) machdep.disable_tsc_calibration=0 ($mute_arg)smolfire.ip=172.16.0.2/30 smolfire.gw=172.16.0.1 smolfire.fetch=http://172.16.0.1:8080/token.txt"
    {
        "boot-source": {kernel_image_path: $kernel, boot_args: $args}
        drives: []
        "network-interfaces": [{iface_id: eth0, guest_mac: "06:00:AC:10:00:02", host_dev_name: tap0}]
        "machine-config": {vcpu_count: 1, mem_size_mib: 512}
    }
}

def run-boot [work: string, kernel: string, firecracker: string, label: string, mute: string, panic_probe: bool] {
    let out = $"($work)/boot-mute-pair"
    let token = $"pair-(random chars --length 24)"
    let token_file = $"($work)/www/token.txt"
    $token | save -f $token_file
    let response = (do -i { ^curl --max-time 3 -fsS http://172.16.0.1:8080/token.txt | str trim })
    if $response != $token { fail $"token server preflight failed for ($label)" }

    let json_path = $"($out)/($label).fc.json"
    let log_path = $"($out)/($label).serial.log"
    let result_path = $"($out)/($label).json"
    config $kernel $mute $panic_probe | to json | save -f $json_path

    let rows = capture $firecracker [--no-api --config-file $json_path] $log_path 4
    let ready_ms = first-exact-ms $rows SMOLFIRE_READY
    let net_ms = first-exact-ms $rows $"SMOLFIRE_NET_OK ($token)"
    let panic_line = $rows | where {|row| ($row.line | str lowercase) =~ 'panic:'} | get 0?.line
    let net_fail = ($rows | where {|row| $row.line | str contains SMOLFIRE_NET_FAIL} | length) > 0
    let chatter = if $ready_ms == null { [] } else {
        $rows | where {|row|
            $row.ms < $ready_ms and (($row.line | str starts-with "Copyright") or ($row.line | str starts-with "FreeBSD"))
        } | get line
    }
    let verdict = if $panic_probe {
        if $panic_line != null and $ready_ms == null { "panic-visible" } else { "panic-inconclusive" }
    } else if $panic_line == null and $ready_ms != null and $ready_ms > 0 and $net_ms != null and $net_ms <= $ready_ms and not $net_fail {
        "pass"
    } else {
        "fail"
    }
    let result = {
        label: $label, mute: $mute, panic_probe: $panic_probe, verdict: $verdict
        ready_ms: $ready_ms, net_ms: $net_ms, panic_line: $panic_line
        boot_chatter_lines: ($chatter | length), boot_chatter_samples: ($chatter | first 5)
        config: $json_path, serial: $log_path, token: $token
    }
    $result | to json | save -f $result_path
    print $"($label): ($verdict), READY=($ready_ms), NET=($net_ms)"
    $result
}

def "main selftest" [] {
    let temp = (^mktemp -d | str trim)
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
    let unmuted = config /tmp/test-kernel NO false
    let muted = config /tmp/test-kernel YES false
    let default_boot = config /tmp/test-kernel "" false
    if ($unmuted | get "boot-source" | get kernel_image_path) != ($muted | get "boot-source" | get kernel_image_path) {
        fail "paired configurations changed the release ELF"
    }
    let changed = ($muted | get "boot-source" | get boot_args | str replace "boot_mute=YES" "boot_mute=NO")
    if $changed != ($unmuted | get "boot-source" | get boot_args) {
        fail "paired configurations changed more than boot_mute"
    }
    if (($default_boot | get "boot-source" | get boot_args) | str contains "boot_mute") {
        fail "default control retained a boot_mute argument"
    }
    if (median [1.0 2.0]) != 1.5 { fail "paired median arithmetic failed" }
    rm -rf $temp
    print $"boot-mute-pair selftest: streamed delay ($second - $first)ms"
}

def main [
    --work: string = "/mnt/smolfire-ci"
    --runs: int = 3
] {
    if $runs < 3 { fail "at least three ABBA rounds are required" }
    let kernel = $"($work)/smolfire-kernel"
    let firecracker = $"($work)/firecracker"
    let out = $"($work)/boot-mute-pair"
    if not ($kernel | path exists) or not ($firecracker | path exists) {
        fail "release ELF or Firecracker binary is missing"
    }
    if not ($"($work)/www/token.txt" | path exists) or not ($"($work)/fc-release.json" | path exists) {
        fail "network server or prior gate configuration is missing"
    }
    # The preceding TSLOG capture should have reaped its instance. Do not kill
    # another step's process if that cleanup failed.
    let existing = ((do -i { ^pgrep -f $"^($firecracker) --no-api" | str trim }) | default "")
    if $existing != "" { fail $"Firecracker already owns TAP: ($existing)" }
    mkdir $out

    let kernel_sha = (open --raw $kernel | hash sha256)
    let kernel_bytes = (ls $kernel | get 0.size | into int)
    {schema: "smolfire.boot-mute-pair/v1", kernel: $kernel, sha256: $kernel_sha, bytes: $kernel_bytes,
     method: "same ELF; boot_mute=NO/YES; ABBA interleaved; fresh bounded Firecracker per boot; host line-arrival timestamps",
     panic_method: "ACPI-off known MP-table panic on Firecracker v1.12.0; host-dependent"}
        | to json | save -f $"($out)/manifest.json"

    mut results = []
    for round in 1..$runs {
        for step in ([unmute mute mute unmute] | enumerate) {
            let mode = $step.item
            let mute = if $mode == "mute" { "YES" } else { "NO" }
            let label = $"r($round)-s($step.index + 1)-($mode)"
            let result = run-boot $work $kernel $firecracker $label $mute false
            $results = $results | append $result
        }
    }
    # An explicit NO must exhibit the same ordinary kernel header chatter as
    # a control boot with no boot_mute argument; otherwise the baseline is not
    # a demonstrated unmuted default.
    let default_result = run-boot $work $kernel $firecracker default-unmuted "" false
    let panic_result = run-boot $work $kernel $firecracker panic-acpi-off YES true
    let kernel_after = (open --raw $kernel | hash sha256)
    if $kernel_after != $kernel_sha { fail "release ELF changed during paired boots" }

    let final_results = $results
    let pairs = 1..$runs | each {|round|
        let group = $final_results | where {|r| $r.label | str starts-with $"r($round)-"}
        let baseline = $group | where mute == NO | get ready_ms | compact
        let candidate = $group | where mute == YES | get ready_ms | compact
        if ($baseline | length) != 2 or ($candidate | length) != 2 {
            {round: $round, valid: false, baseline_mean_ms: null, mute_mean_ms: null, delta_ms: null}
        } else {
            let base_mean = (($baseline | math sum) / 2)
            let mute_mean = (($candidate | math sum) / 2)
            {round: $round, valid: true, baseline_mean_ms: $base_mean, mute_mean_ms: $mute_mean, delta_ms: ($mute_mean - $base_mean)}
        }
    }
    let deltas = $pairs | get delta_ms | compact
    let baseline_chatter = ($results | where mute == NO | where boot_chatter_lines == 0 | length) == 0
    let default_chatter = $default_result.boot_chatter_lines > 0
    let valid = (($results | where verdict != pass | length) == 0) and (($pairs | where valid == false | length) == 0) and ($default_result.verdict == "pass") and $baseline_chatter and $default_chatter
    let within_100ms = $valid and (($results | where mute == YES | where ready_ms > 100 | length) == 0)
    let report = {
        schema: "smolfire.boot-mute-pair/v1", kernel_sha256: $kernel_sha,
        valid: $valid, mute_within_100ms: $within_100ms,
        panic_visibility: $panic_result.verdict, paired_delta_median_ms: (median $deltas),
        default_unmuted_control: $default_result,
        baseline_default_chatter_observed: ($baseline_chatter and $default_chatter),
        pairs: $pairs, runs: $results
    }
    $report | to json | save -f $"($out)/report.json"
    print ($report | to json)
    if not $valid or $panic_result.verdict != "panic-visible" {
        fail "paired boot evidence invalid or panic serial visibility inconclusive"
    }
    if not $within_100ms {
        fail "muted release ELF did not meet the <=100ms boot goal"
    }
}
