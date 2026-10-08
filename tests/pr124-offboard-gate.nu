#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Source/model gate only. Run in an isolated off-board checkout with caller-held
# resource lock. No result here establishes physical media durability.

def capture [name: string, result: record, out_dir: string] {
    $result.stdout | save -f ($out_dir | path join $"($name).stdout")
    $result.stderr | save -f ($out_dir | path join $"($name).stderr")
    {name: $name, exit_code: $result.exit_code} | to json --raw | save -f ($out_dir | path join $"($name).json")
    $result
}

def require_exit_zero [name: string, result: record] {
    if $result.exit_code != 0 {
        error make {msg: $"($name) exited ($result.exit_code); inspect the saved output"}
    }
}

def main [
    out_dir: string,
    --cc: string,
    --iverilog: string,
    --vvp: string,
    --ivl-base: string,
    --timeout-tool: string = "/usr/bin/timeout",
] {
    let root = $env.PWD
    if ($out_dir | path exists) {
        error make {msg: "output directory already exists; use a fresh path"}
    }
    mkdir $out_dir

    let c_impl = ($root | path join "hps/media_log_v2.c")
    let c_header = ($root | path join "hps/media_log_v2.h")
    let c_test = ($root | path join "hps/media_log_v2_test.c")
    let rtl_sv = ($root | path join "rtl/durable_tid_v0.sv")
    let rtl_v = ($root | path join "rtl/durable_tid_v0.v")
    let rtl_tb = ($root | path join "rtl/durable_tid_v0_tb.sv")
    let script = ($root | path join "tests/pr124-offboard-gate.nu")
    let hash_paths = [$c_impl $c_header $c_test $rtl_sv $rtl_v $rtl_tb $script $cc $iverilog $vvp $timeout_tool]
    let hashes = ($hash_paths | each {|path|
        let result = (do { ^sha256sum $path } | complete)
        require_exit_zero $"sha256sum ($path)" $result
        $result.stdout | str trim
    })
    $hashes | str join "\n" | save -f ($out_dir | path join "source-and-tool-sha256.txt")
    let cc_version = (capture "cc-version" (do { ^$cc --version } | complete) $out_dir)
    require_exit_zero "cc-version" $cc_version
    let iverilog_version = (capture "iverilog-version" (do { ^$iverilog -B $ivl_base -V } | complete) $out_dir)
    require_exit_zero "iverilog-version" $iverilog_version
    let vvp_version = (capture "vvp-version" (do { ^$vvp -V } | complete) $out_dir)
    require_exit_zero "vvp-version" $vvp_version

    let c_bin = ($out_dir | path join "media-log-v2-test")
    let c_compile = (capture "c-compile" (do { ^$timeout_tool 120s $cc -std=c99 -O2 -Wall -Wextra -Werror -o $c_bin $c_impl $c_test } | complete) $out_dir)
    require_exit_zero "c-compile" $c_compile
    let c_run = (capture "c-run" (do { ^$timeout_tool 120s $c_bin } | complete) $out_dir)
    require_exit_zero "c-run" $c_run
    if not ($c_run.stdout | str contains "media_log_v2 source vectors passed") {
        error make {msg: "C positive banner absent"}
    }

    let c_source = (open --raw $c_test)
    let c_needle = "puts(\"media_log_v2 source vectors passed\");"
    if (($c_source | split row $c_needle | length) != 2) {
        error make {msg: "C negative-control insertion point changed"}
    }
    let c_negative_source = ($out_dir | path join "media-log-v2-negative.c")
    ($c_source | str replace $c_needle ("CHECK(0 && \"gate deliberate fail\"); " + $c_needle)) | save -f $c_negative_source
    let c_negative_bin = ($out_dir | path join "media-log-v2-negative")
    let c_negative_compile = (capture "c-negative-compile" (do { ^$timeout_tool 120s $cc -std=c99 -O2 -Wall -Wextra -Werror -I ($root | path join "hps") -o $c_negative_bin $c_impl $c_negative_source } | complete) $out_dir)
    require_exit_zero "c-negative-compile" $c_negative_compile
    let c_negative_run = (capture "c-negative-run" (do { ^$timeout_tool 120s $c_negative_bin } | complete) $out_dir)
    if $c_negative_run.exit_code != 1 or not ($c_negative_run.stderr | str contains "gate deliberate fail") {
        error make {msg: "C deliberate failed assertion was not detected with exit 1"}
    }

    let rtl_source = (open --raw $rtl_tb)
    let rtl_needle = "$display(\"checks passed: %0d  failed: %0d\", checks_passed, checks_failed);"
    if (($rtl_source | split row $rtl_needle | length) != 2) {
        error make {msg: "RTL negative-control insertion point changed"}
    }
    let rtl_negative_source = ($out_dir | path join "durable-tid-negative-tb.sv")
    let rtl_fail = "check(\"gate deliberate fail\", 1'b0);\n    "
    ($rtl_source | str replace $rtl_needle ($rtl_fail + $rtl_needle)) | save -f $rtl_negative_source

    for variant in [sv v] {
        let dut = (if $variant == "sv" { $rtl_sv } else { $rtl_v })
        let binary = ($out_dir | path join $"durable-tid-($variant).vvp")
        let compile = (capture $"rtl-($variant)-compile" (do { ^$timeout_tool 120s $iverilog -B $ivl_base -g2012 -Wall -o $binary $dut $rtl_tb } | complete) $out_dir)
        require_exit_zero $"rtl-($variant)-compile" $compile
        let run = (capture $"rtl-($variant)-run" (do { ^$timeout_tool 120s $vvp $binary } | complete) $out_dir)
        require_exit_zero $"rtl-($variant)-run" $run
        if not ($run.stdout | str contains "checks passed: 119  failed: 0") or not ($run.stdout | str contains "PASS") {
            error make {msg: $"rtl-($variant) positive checks/banner absent"}
        }

        let negative_binary = ($out_dir | path join $"durable-tid-($variant)-negative.vvp")
        let negative_compile = (capture $"rtl-($variant)-negative-compile" (do { ^$timeout_tool 120s $iverilog -B $ivl_base -g2012 -Wall -o $negative_binary $dut $rtl_negative_source } | complete) $out_dir)
        require_exit_zero $"rtl-($variant)-negative-compile" $negative_compile
        let negative_run = (capture $"rtl-($variant)-negative-run" (do { ^$timeout_tool 120s $vvp $negative_binary } | complete) $out_dir)
        if $negative_run.exit_code == 0 or not ($negative_run.stdout | str contains "failed: 1") or not ($negative_run.stdout | str contains "FAIL") {
            error make {msg: $"rtl-($variant) deliberate failed assertion did not exit nonzero"}
        }
    }

    ["C positive vectors pass" "C deliberate assertion exits 1" "RTL .sv and .v positive 119/0" "RTL .sv and .v deliberate assertion exits nonzero"] | str join "\n" | save -f ($out_dir | path join "PASS.txt")
    print "PR124 off-board source/model gate PASS; physical media and board remain unproved"
}
