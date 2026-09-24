#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/boot-gap-experiments.nu — attribute the aarch64 HVF "Starting devd." →
# "Starting dhclient." gap (docs/BOOT-TIME-ROADMAP.md §1, 1.9–6.8 s) with
# one-change-at-a-time guest experiments.
#
# Subcommands (run from the repo root):
#   prepare  — for each variant: APFS clone (cp -c) of --base, boot it once
#              read-write over the serial console (expect), log in, apply the
#              variant's guest change, `shutdown -p now` (leaves the fs clean).
#   run      — boot every variant --runs times through bin/boot-phases.nu
#              (snapshot=on, `-boot menu=on,splash-time=0`), INTERLEAVED
#              (round 1 of every variant, then round 2, ...) so host-load drift
#              hits all variants alike. Raw logs: <out-dir>/<variant>-runN.log.
#   analyze  — derive the gap metrics from those raw logs; JSON on stdout
#              (schema smolfire.boot-gap/v1).
#
# Gap metrics (ms since QEMU exec, serial-timestamped by bin/boot-phases.nu):
#   devd            first "Starting devd."
#   devd_to_dhclient  "Starting devd." → "Starting dhclient." (the PR #55 gap)
#   devd_to_rc_resume "Starting devd." → first rc line after NETWORKING
#                     ("Clearing /tmp" — cleartmp), i.e. how long rc blocked
#   lease           first "bound to" (network usable)
#   login           "login:" (bin/boot-phases.nu marker)
#
# The guest root password comes from $env.SMOLFIRE_GUEST_PASSWORD (default:
# the Phase-1 image default set by bin/fix-freebsd-vm.py).

const SPLASH0 = "-boot menu=on,splash-time=0"

# One change per variant: guest shell lines (appended to rc.conf etc.) and/or
# extra QEMU argv. "baseline" has neither.
const VARIANTS = [
    [name                cmds                                                          qemu_extra];
    [baseline            []                                                            ""]
    [a-dad0              ["echo net.inet6.ip6.dad_count=0 >> /etc/sysctl.conf"]        ""]
    [b1-syncdhcp         ["echo 'ifconfig_vtnet0=\"SYNCDHCP\"' >> /etc/rc.conf"]       ""]
    [b2-bgdhclient       ["echo 'background_dhclient=\"YES\"' >> /etc/rc.conf"]        ""]
    [c-nodevd            ["echo 'devd_enable=\"NO\"' >> /etc/rc.conf"]                 ""]
    [d-rcdebug           ["echo 'rc_debug=\"YES\"' >> /etc/rc.conf"]                   ""]
    [e-nousb             []                                                            "-machine usb=off"]
    [f-devd-n            ["echo 'devd_flags=\"-n\"' >> /etc/rc.conf"]                  ""]
    [g-nodevmatch        ["echo 'devmatch_enable=\"NO\"' >> /etc/rc.conf"]             ""]
    [h-nomatch-mmio      ["printf 'nomatch 101 {\\n\\tmatch \"_HID\" \"LNRO0005\";\\n};\\n' > /etc/devd/smolfire-nomatch.conf"] ""]
    [i-nomatch-tunable   ["echo 'hw.bus.devctl_nomatch_enabled=\"0\"' >> /boot/loader.conf"] ""]
]

# Serial-console config boot: log in as root, run each line, power off.
const EXPECT_TCL = '
set timeout 300
spawn /opt/homebrew/bin/qemu-system-aarch64 -machine virt,accel=hvf -cpu host -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd -m 256M -smp 2 -drive file=$env(GAP_IMAGE),format=qcow2,if=virtio -nic user,model=virtio-net-pci -display none -monitor none -serial stdio -boot menu=on,splash-time=0
expect {
  "login:" {}
  timeout { puts "GAP: no login prompt"; exit 2 }
}
send "root\r"
expect {
  "Password:" { send "$env(GAP_PW)\r"; exp_continue }
  "Login incorrect" { puts "GAP: login failed"; exit 3 }
  -re {# $} {}
  timeout { puts "GAP: no shell"; exit 4 }
}
foreach line [split $env(GAP_CMDS) "\n"] {
  if {$line eq ""} continue
  send -- "$line\r"
  expect -re {# $}
}
send "shutdown -p now\r"
expect {
  eof {}
  timeout { puts "GAP: no poweroff"; exit 5 }
}
'

def median [xs: list<int>] {
    let s = $xs | sort
    let n = $s | length
    if $n == 0 { return null }
    if ($n mod 2) == 1 { $s | get ($n // 2) } else { (($s | get ($n // 2 - 1)) + ($s | get ($n // 2))) // 2 }
}

def pick [names: string] {
    if ($names | str trim) == "" { $VARIANTS } else {
        let want = $names | split row ","
        $VARIANTS | where name in $want
    }
}

def img-path [dir: string, v: string] { $"($dir)/gap-($v).qcow2" }

# Clone + configure each variant image (one clean read-write boot).
def "main prepare" [
    --base: string                  # clean APFS clone of the Phase-1 image
    --img-dir: string = "build"
    --only: string = ""             # comma-separated variant names
] {
    let pw = $env.SMOLFIRE_GUEST_PASSWORD? | default "smolbsd"
    pick $only | each {|v|
        let img = img-path $img_dir $v.name
        rm -f $img
        ^cp -c $base $img
        # Always print the effective settings so the log proves the change.
        let cmds = $v.cmds | append ["tail -3 /etc/rc.conf" "tail -1 /boot/loader.conf" "cat /etc/sysctl.conf | grep -v '^#' | grep ." "ls /etc/devd"]
        let r = with-env {GAP_IMAGE: $img, GAP_PW: $pw, GAP_CMDS: ($cmds | str join "\n")} {
            ^expect -c $EXPECT_TCL | complete
        }
        {variant: $v.name, image: $img, exit: $r.exit_code,
         transcript: ($r.stdout | str replace -a "\r" "" | lines | skip until {|l| $l =~ '^root@.*# ' } | take until {|l| $l =~ '# shutdown -p now' })}
    } | to json
}

# Interleaved boots through bin/boot-phases.nu.
def "main run" [
    --img-dir: string = "build"
    --out-dir: string               # raw logs + per-boot boot-phases JSON
    --runs: int = 3
    --only: string = ""
    --prefix: string = "aarch64-hvf-gap"
] {
    mkdir $out_dir
    let tmp = (^mktemp -d | str trim)
    for round in 1..$runs {
        for v in (pick $only) {
            let img = if $v.name == "e-nousb" { img-path $img_dir "baseline" } else { img-path $img_dir $v.name }
            let extra = [$SPLASH0 $v.qemu_extra] | str join " " | str trim
            let label = $"($prefix)-($v.name)"
            let doc = (nu bin/boot-phases.nu --image $img --runs 1 --out-dir $tmp --label $label --qemu-extra $extra --timeout 150 | from json)
            mv -f $"($tmp)/($label)-run1.log" $"($out_dir)/($label)-run($round).log"
            let rec = {variant: $v.name, run: $round, env: $doc.env, markers_ms: ($doc.runs | first | get markers_ms), phases_ms: ($doc.runs | first | get phases_ms)}
            $rec | to json | save -f $"($out_dir)/($label)-run($round).json"
            print -e $"($v.name) run ($round): login ($rec.markers_ms.login) ms, load ($doc.env.loadavg_before)"
        }
    }
    rm -rf $tmp
}

def first-ms [lines: list<record>, re: string, after: int] {
    $lines | where {|r| $r.ms >= $after and $r.line =~ $re } | get 0?.ms
}

def gap-metrics [log: string] {
    let lines = open --raw $log | lines | parse -r '^\+(?<ms>\d+)ms (?<line>.*)$' | update ms {|r| $r.ms | into int }
    let devd = first-ms $lines '^Starting devd\.' 0
    let d0 = $devd | default 0
    let dhc = first-ms $lines '^Starting dhclient\.' 0
    let resume = first-ms $lines '^Clearing /tmp' $d0
    let lease = first-ms $lines 'bound to [0-9.]+' 0
    let login = first-ms $lines 'login:' 0
    {
        devd: $devd, dhclient: $dhc, lease: $lease, rc_resume: $resume, login: $login
        devd_to_dhclient: (if $devd != null and $dhc != null and $dhc > $devd { $dhc - $devd } else { null })
        devd_to_rc_resume: (if $devd != null and $resume != null { $resume - $devd } else { null })
        devmatch_spawns: ($lines | where {|r| $r.line =~ '/etc/rc\.d/devmatch.*DEBUG: run_rc_command: doit' } | length)
    }
}

# Summarize raw logs → JSON (schema smolfire.boot-gap/v1).
def "main analyze" [
    --out-dir: string
    --prefix: string = "aarch64-hvf-gap"
] {
    let files = glob $"($out_dir)/($prefix)-*-run*.log" | sort
    let runs = $files | each {|f|
        let re = ($"^($prefix)-" + '(?<variant>.+)-run(?<run>\d+)\.log$')
        let m = $f | path basename | parse -r $re | first
        let js = $f | str replace -r '\.log$' '.json'
        let load = if ($js | path exists) { open $js | get env.loadavg_before } else { null }
        {variant: $m.variant, run: ($m.run | into int), loadavg_before: $load} | merge (gap-metrics $f)
    }
    let keys = [devd_to_dhclient devd_to_rc_resume lease login]
    let summary = $runs | group-by variant | transpose variant rs | each {|g|
        $keys | reduce -f {variant: $g.variant, n: ($g.rs | length)} {|k, acc|
            let xs = $g.rs | get $k | compact
            $acc | insert $"($k)_median_ms" (median $xs) | insert $"($k)_range_ms" (if ($xs | is-empty) { null } else { $"($xs | math min)–($xs | math max)" })
        }
    }
    {schema: "smolfire.boot-gap/v1", method: "serial-timestamp via bin/boot-phases.nu, -boot menu=on,splash-time=0, snapshot=on, interleaved rounds",
     runs: $runs, summary: $summary} | to json
}

def main [] {
    print "usage: nu tests/boot-gap-experiments.nu (prepare|run|analyze) --help"
}
