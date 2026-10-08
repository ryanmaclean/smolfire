#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/dut-status.nu — host-side DUT status dashboard (READ-ONLY).
#
# Polls the Tang Console DUT over UART using hps/harness.c as the transport
# subprocess: PING (link check) + READ of the DURABLE/VISIBLE/STATUS/ERROR/
# RESET_CNT/VERSION/MAGIC registers. Never issues WRITE/RESET/smoke/diff, so
# a dashboard run cannot mutate DUT state or disturb an ongoing run.
#
# Each poll renders one timestamped status line with change detection:
#   * watermark advance rate (ops/s) vs the previous poll
#   * newly-appeared ERROR bits -> ALERT line
#   * link loss -> ALERT + non-zero exit after --retries consecutive failures
# --json emits one JSON record per poll for Datadog/log ingestion.
#
# Examples:
#   nu bin/dut-status.nu --once                  # single snapshot
#   nu bin/dut-status.nu --interval 5             # poll forever, 5 s cadence
#   nu bin/dut-status.nu --count 12 --interval 5 # twelve polls then exit 0
#   nu bin/dut-status.nu --once --json            # single JSON record

# DUT byte offsets (must match hps/harness.c + rtl/durable_tid_v0.v header).
const ADDR_DUR_LO = "0x0c"
const ADDR_DUR_HI = "0x48"
const ADDR_VIS_LO = "0x10"
const ADDR_VIS_HI = "0x4c"
const ADDR_ERROR = "0x18"
const ADDR_STATUS = "0x28"
const ADDR_RSTCNT = "0x20"
const ADDR_VERSION = "0x58"
const ADDR_MAGIC = "0x54"
const MAGIC_WANT = 0x44555230 # "DUR0"
const VERSION_WANT = 1

def ts-now []: nothing -> string {
    date now | format date "%Y-%m-%dT%H:%M:%S%z"
}

def hex8 [n: int]: nothing -> string {
    let r = (do { ^printf '0x%x' $n } | complete)
    if $r.exit_code == 0 and (($r.stdout | str trim | str length) > 0) {
        $r.stdout | str trim
    } else {
        $"($n)"
    }
}

def run-harness [bin: string, base: list<string>, args: list<string>]: nothing -> record {
    do { run-external $bin ...($base ++ $args) } | complete | {stdout: $in.stdout, stderr: $in.stderr, exit_code: $in.exit_code}
}

def parse-hex [out: string]: nothing -> any {
    let toks = ($out | str trim | split row " " | where {|t| ($t | str length) > 0 })
    if ($toks | is-empty) {
        return null
    }
    try {
        $toks | last | into int
    } catch {
        null
    }
}

def read-reg [bin: string, base: list<string>, addr: string]: nothing -> any {
    let r = run-harness $bin $base ["read", $addr]
    if $r.exit_code != 0 {
        return null
    }
    parse-hex $r.stdout
}

def elapsed-sec [a: any, b: any]: nothing -> any {
    if $a == null or $b == null {
        return null
    }
    ($a - $b) / 1sec
}

# One poll: PING, then the register set. Returns {link: true, ...regs} or
# {link: false, detail: <reason>}. Transport spawn errors are caught so a
# vanishing harness binary degrades to link-down, not a Nu crash.
def poll [bin: string, base: list<string>]: nothing -> record {
    try {
        let p = run-harness $bin $base ["ping"]
        if $p.exit_code != 0 {
            let d = ($p.stderr | str trim)
            return {link: false, detail: (if ($d | str length) > 0 { $d } else { "PING failed" })}
        }
        let fields = [
            [name, addr];
            [dur_lo, $ADDR_DUR_LO],
            [dur_hi, $ADDR_DUR_HI],
            [vis_lo, $ADDR_VIS_LO],
            [vis_hi, $ADDR_VIS_HI],
            [error, $ADDR_ERROR],
            [status, $ADDR_STATUS],
            [reset_cnt, $ADDR_RSTCNT],
            [version, $ADDR_VERSION],
            [magic, $ADDR_MAGIC],
        ]
        mut regs = {}
        for f in $fields {
            let v = read-reg $bin $base $f.addr
            if $v == null {
                return {link: false, detail: $"READ ($f.addr) failed"}
            }
            $regs = ($regs | insert $f.name $v)
        }
        {link: true} | merge $regs | insert durable (($regs.dur_hi * 4294967296) + $regs.dur_lo) | insert visible (($regs.vis_hi * 4294967296) + $regs.vis_lo)
    } catch {|e|
        {link: false, detail: $"transport error: ($e.msg)"}
    }
}

def main [
    --harness: string = ""  # harness binary (default $env.DUT_HARNESS, else "harness" on PATH)
    --tty: string = ""      # UART tty, passed through as `harness -t <tty>`
    --interval: float = 5.0 # seconds between polls
    --count: int = 0        # polls to run (0 = forever; ignored with --once)
    --once                  # single snapshot, then exit 0
    --json                  # one JSON record per poll (Datadog/log ingestion)
    --retries: int = 3      # consecutive link failures before ALERT + exit 1
] {
    let bin = if $harness != "" {
        $harness
    } else if "DUT_HARNESS" in $env {
        $env.DUT_HARNESS
    } else {
        "harness"
    }
    let base = if $tty != "" { ["-t", $tty] } else { [] }
    if not ($bin | str contains "/") {
        if (which $bin | is-empty) {
            let msg = $"ALERT harness binary not found: ($bin)"
            if $json {
                {ts: (ts-now), link: false, alerts: [$msg]} | to json --raw | print
            } else {
                print $msg
            }
            exit 1
        }
    }

    mut prev: any = null
    mut prev_at: any = null
    mut fails = 0
    mut done = 0
    loop {
        let now = date now
        let ts = ($now | format date "%Y-%m-%dT%H:%M:%S%z")
        let s = poll $bin $base
        if not $s.link {
            $fails += 1
            if $json {
                {ts: $ts, link: false, attempt: $fails, retries: $retries, detail: $s.detail, alerts: [$"link down \(attempt ($fails)/($retries)\)"]} | to json --raw | print
            } else {
                print $"($ts) ALERT link down \(attempt ($fails)/($retries)\): ($s.detail)"
            }
            if $fails >= $retries {
                exit 1
            }
        } else {
            let recovered = $fails
            if $recovered > 0 and not $json {
                print $"($ts) INFO link recovered after ($recovered) failed poll\(s\)"
            }
            $fails = 0
            let dt = elapsed-sec $now $prev_at
            let rate = if $prev == null or $dt == null or $dt <= 0 {
                null
            } else {
                ((($s.durable - $prev.durable) | into float) / $dt)
            }
            let newbits = if $prev == null { 0 } else { $s.error | bits and ($prev.error | bits not) }
            if $json {
                mut alerts = []
                if $s.magic != $MAGIC_WANT or $s.version != $VERSION_WANT {
                    $alerts ++= [$"identity mismatch magic=(hex8 $s.magic) version=($s.version) \(want magic=0x44555230 version=1\)"]
                }
                if $newbits != 0 and $prev != null {
                    $alerts ++= [$"new ERROR bits (hex8 $newbits) \(prev (hex8 $prev.error) cur (hex8 $s.error)\)"]
                }
                {ts: $ts, link: true, durable: $s.durable, visible: $s.visible, error: $s.error, error_hex: (hex8 $s.error), status: $s.status, reset_cnt: $s.reset_cnt, version: $s.version, magic: $s.magic, rate_ops: $rate, new_error_bits: $newbits, recovered_after: (if $recovered > 0 { $recovered } else { null }), alerts: $alerts} | to json --raw | print
            } else {
                mut line = $"($ts) durable=($s.durable) visible=($s.visible) err=(hex8 $s.error) rst=($s.reset_cnt) ver=($s.version) status=(hex8 $s.status) magic=(hex8 $s.magic) link=ok"
                if $rate != null {
                    $line = $"($line) rate=($rate | math round --precision 1) ops/s"
                }
                print $line
            }
            if not $json {
                if $s.magic != $MAGIC_WANT or $s.version != $VERSION_WANT {
                    print $"($ts) ALERT identity mismatch magic=(hex8 $s.magic) version=($s.version) \(want magic=0x44555230 version=1\)"
                }
                if $newbits != 0 and $prev != null {
                    print $"($ts) ALERT new ERROR bits (hex8 $newbits) \(prev (hex8 $prev.error) cur (hex8 $s.error)\)"
                }
            }
            if $prev != null and $s.reset_cnt != $prev.reset_cnt {
                if not $json {
                    print $"($ts) INFO reset_cnt changed ($prev.reset_cnt) -> ($s.reset_cnt)"
                }
            }
            $prev = $s
            $prev_at = $now
            $done += 1
            if $once or ($count > 0 and $done >= $count) {
                break
            }
        }
        sleep ($interval * 1sec)
    }
}
