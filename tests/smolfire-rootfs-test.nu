#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/smolfire-rootfs-test.nu — tests for the rootfs-assembly section of
# bin/build-smolfire.sh (--rootfs-only mode).
#
# The assembly section is pure POSIX sh and runs on any host; the rest of
# the script (makefs, buildkernel) is FreeBSD-only. RESCUE_SRC/ROOT env
# overrides point the script at a temp dir with a fake rescue binary.
# Run from the repo root: nu tests/smolfire-rootfs-test.nu

def fail [msg: string] {
    print $"smolfire-rootfs-test: FAIL — ($msg)"
    exit 1
}

# inode of a path — GNU stat on Linux, BSD stat on macOS (CI runs both).
def inode [path: string] {
    if $nu.os-info.name == "macos" {
        ^stat -f %i $path | str trim
    } else {
        ^stat -c %i $path | str trim
    }
}

# ── Fixture: temp dir with a fake crunchgen rescue binary ────────────────────
let tmp = (^mktemp -d | str trim)
mkdir $"($tmp)/rescue"
"fake rescue crunchgen binary\n" | save $"($tmp)/rescue/rescue"
let rescue_src = $"($tmp)/rescue/rescue"
let root = $"($tmp)/root"

# ── Happy path: --rootfs-only assembles the rootfs and exits 0 ───────────────
let res = (with-env {RESCUE_SRC: $rescue_src, ROOT: $root} {
    ^sh bin/build-smolfire.sh --rootfs-only | complete
})
if $res.exit_code != 0 {
    fail $"--rootfs-only exited ($res.exit_code): ($res.stderr)"
}

# Layout: dirs and crunchgen name links must exist.
for p in [
    $"($root)/rescue/rescue"
    $"($root)/rescue/sh"
    $"($root)/rescue/init"
    $"($root)/sbin/init"
    $"($root)/bin/sh"
    $"($root)/etc/rc"
] {
    if not ($p | path exists) { fail $"missing ($p)" }
}
for d in [$"($root)/dev" $"($root)/tmp"] {
    if not ($d | path exists) { fail $"missing directory ($d)" }
    if ($d | path type) != "dir" { fail $"not a directory: ($d)" }
}

# init(8) hardcodes _PATH_BSHELL=/bin/sh — it must be a hard link to the
# rescue binary (same inode), not a copy or a dangling name.
if (inode $"($root)/bin/sh") != (inode $"($root)/rescue/rescue") {
    fail "/bin/sh is not a hard link to /rescue/rescue (inodes differ)"
}
if (inode $"($root)/sbin/init") != (inode $"($root)/rescue/rescue") {
    fail "/sbin/init is not a hard link to /rescue/rescue (inodes differ)"
}

# /etc/rc: executable, gate marker, and console-shell handoff.
let rc_x = (^test -x $"($root)/etc/rc" | complete)
if $rc_x.exit_code != 0 { fail "/etc/rc is not executable" }
let rc = (^cat $"($root)/etc/rc" | complete)
if $rc.exit_code != 0 { fail "could not read /etc/rc" }
if not ($rc.stdout | str contains "SMOLFIRE_READY") {
    fail "/etc/rc missing SMOLFIRE_READY gate marker"
}
if not ($rc.stdout | str contains "exec /rescue/sh") {
    fail "/etc/rc missing exec /rescue/sh handoff"
}

# Release rc must stay TSLOG-free (the release ELF is the measured path).
if ($rc.stdout | str contains "TSLOG") {
    fail "release /etc/rc contains TSLOG dump lines — only SMOLFIRE_TSLOG=1 may add them"
}

# ── TSLOG variant (SMOLFIRE_TSLOG=1): READY via external /rescue/echo so
# debug.tslog_user timestamps it, dump strictly AFTER READY, shell handoff
# kept, and sed linked for the tslog_user filter.
let troot = $"($tmp)/root-tslog"
let tres = (with-env {RESCUE_SRC: $rescue_src, ROOT: $troot, SMOLFIRE_TSLOG: "1"} {
    ^sh bin/build-smolfire.sh --rootfs-only | complete
})
if $tres.exit_code != 0 { fail $"SMOLFIRE_TSLOG=1 --rootfs-only exited ($tres.exit_code): ($tres.stderr)" }
let trc = (open --raw $"($troot)/etc/rc" | lines)
let idx = {|needle| $trc | enumerate | where {|r| $r.item | str contains $needle} | get index | first }
for needle in ["/rescue/echo \"SMOLFIRE_READY\"" "SMOLFIRE_TSLOG_BEGIN" "sysctl -b debug.tslog" "debug.tslog_user" "SMOLFIRE_TSLOG_DONE" "exec /rescue/sh"] {
    if ($trc | where {|l| $l | str contains $needle} | is-empty) { fail $"TSLOG rc missing: ($needle)" }
}
let i_ready = (do $idx "SMOLFIRE_READY")
let i_begin = (do $idx "SMOLFIRE_TSLOG_BEGIN")
let i_done  = (do $idx "SMOLFIRE_TSLOG_DONE")
let i_exec  = (do $idx "exec /rescue/sh")
if not ($i_ready < $i_begin and $i_begin < $i_done and $i_done < $i_exec) {
    fail "TSLOG rc order must be READY < TSLOG_BEGIN < TSLOG_DONE < exec sh"
}
if (inode $"($troot)/rescue/sed") != (inode $"($troot)/rescue/rescue") {
    fail "TSLOG rootfs: /rescue/sed is not a hard link to /rescue/rescue"
}
if ($"($root)/rescue/sed" | path exists) {
    fail "release rootfs gained /rescue/sed — only the TSLOG variant needs it"
}

# ── Negative: without --rootfs-only the script must FAIL on a non-FreeBSD
# host (sysctl hw.ncpu / makefs absent) — proves --rootfs-only is what
# protects CI, not luck.
let full = (with-env {RESCUE_SRC: $rescue_src, ROOT: $"($tmp)/root2"} {
    ^sh bin/build-smolfire.sh | complete
})
if $full.exit_code == 0 {
    fail "full build unexpectedly succeeded without FreeBSD tools"
}

^rm -rf $tmp
print "smolfire-rootfs-test: ok"
