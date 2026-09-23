#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/shrink-image-test.nu — unit tests for bin/shrink-image.nu (trim mode).
#
# Builds a fake FreeBSD root in a temp dir (no image, no root, no FreeBSD
# tools) and checks what `shrink-image.nu trim` removes and keeps per
# profile: removal classes, module allowlist + loader.conf override, locale
# and zoneinfo keep lists (including symlink targets), protected paths,
# /usr/local untouched, dry-run, and the shared-library orphan check (via a
# stub readelf). Also checks that image mode refuses to run off FreeBSD.
# Run from the repo root: nu tests/shrink-image-test.nu

const SCRIPT = "bin/shrink-image.nu"

def fail [msg: string] {
    print $"shrink-image-test: FAIL — ($msg)"
    exit 1
}

def touch-all [root: string, files: list<string>] {
    for f in $files {
        let p = $root | path join $f
        mkdir ($p | path dirname)
        "x" | save -f $p
    }
}

# A small FreeBSD-shaped tree. Text files stand in for binaries; a file whose
# lines start with "NEEDED:" is what the stub readelf reports as its DT_NEEDED.
def make-root [root: string] {
    touch-all $root [
        bin/sh sbin/init libexec/ld-elf.so.1 lib/libc.so.7 lib/libedit.so.8
        usr/sbin/sshd usr/libexec/sshd-session usr/bin/ssh usr/bin/login
        boot/kernel/kernel boot/lua/loader.lua boot/defaults/loader.conf boot/device.hints
        boot/loader.efi boot/loader_lua.efi boot/loader_4th.efi boot/menu.4th boot/images/logo.png
        boot/firmware/iwlwifi.bin
        boot/kernel/virtio.ko boot/kernel/virtio_blk.ko boot/kernel/virtio_pci.ko boot/kernel/if_vtnet.ko
        boot/kernel/tmpfs.ko boot/kernel/nullfs.ko boot/kernel/efirt.ko
        boot/kernel/nvme.ko boot/kernel/cryptodev.ko boot/kernel/if_wg.ko boot/kernel/tpm.ko
        boot/kernel/geom_eli.ko boot/kernel/zfs.ko boot/kernel/if_rtw89.ko boot/kernel/umodem.ko
        boot/kernel/mymod.ko boot/kernel/kernel.debug boot/kernel/linker.hints
        usr/lib/debug/lib/libc.so.7.debug usr/lib/libc.a usr/lib/crt1.o usr/include/stdio.h
        usr/lib/clang/19/include/stddef.h usr/bin/clang usr/bin/llvm-ar usr/lib/libprivatellvm.so.19
        usr/share/man/man1/ls.1.gz usr/share/doc/README usr/share/examples/ex usr/share/dict/words
        usr/share/misc/magic.mgc usr/share/misc/termcap.db usr/share/misc/pci_vendors
        usr/share/locale/C.UTF-8/LC_CTYPE usr/share/locale/en_US.UTF-8/LC_COLLATE
        usr/share/locale/fr_FR.UTF-8/LC_CTYPE usr/share/locale/ja_JP.UTF-8/LC_CTYPE
        usr/share/i18n/csmapper/x usr/share/nls/C/libc.cat
        usr/share/zoneinfo/UTC usr/share/zoneinfo/Etc/UTC usr/share/zoneinfo/America/Los_Angeles
        usr/share/zoneinfo/America/Chicago usr/share/zoneinfo/Asia/Tokyo usr/share/zoneinfo/Europe/Berlin
        usr/share/zoneinfo/zone.tab usr/share/vt/keymaps/us.kbd
        rescue/rescue usr/tests/Kyuafile usr/lib32/libc.so.7 usr/bin/kyua
        usr/sbin/cxgbetool usr/sbin/ntpd usr/sbin/tcpdump usr/sbin/bhyve sbin/zfs lib/libzfs.so.4
        usr/libexec/sendmail/sendmail usr/libexec/dma usr/sbin/local-unbound
        var/cache/pkg/foo-1.0.pkg var/db/pkg/local.sqlite usr/local/bin/keepme usr/local/share/man/man1/k.1
        etc/rc.conf etc/login.conf etc/mail/mailer.conf root/.profile
    ]
    # C.UTF-8 shares a file with en_US.UTF-8, as FreeBSD's locale tree does.
    ^ln -s ../en_US.UTF-8/LC_COLLATE ($root | path join usr/share/locale/C.UTF-8/LC_COLLATE)
    # cc is a link to clang.
    ^ln -s clang ($root | path join usr/bin/cc)
    "hostname=\"t\"\nsshd_enable=\"YES\"\nkld_list=\"umodem\"\n" | save -f ($root | path join etc/rc.conf)
    "mymod_load=\"YES\"\nzfs_load=\"NO\"\n" | save -f ($root | path join boot/loader.conf)
    "default:\\\n\t:lang=C.UTF-8:\\\n\t:umask=022:\n" | save -f ($root | path join etc/login.conf)
    "sendmail\t/usr/libexec/dma\nmailq\t/usr/libexec/dma\n" | save -f ($root | path join etc/mail/mailer.conf)
    # loader.efi is the lua loader: identical bytes.
    cp ($root | path join boot/loader_lua.efi) ($root | path join boot/loader.efi)
    "NEEDED:libedit.so.8\nNEEDED:libc.so.7\n" | save -f ($root | path join bin/sh)
    "NEEDED:libc.so.7\n" | save -f ($root | path join usr/sbin/sshd)
}

# Stub readelf: prints elftoolchain-style `readelf -d` NEEDED lines ("File:"
# headers as llvm-readelf prints them for several files) from NEEDED: lines.
def make-stub [dir: string] {
    let stub = $dir | path join readelf-stub
    let body = [
        $"#!($nu.current-exe)"
        "def --wrapped main [...args] {"
        "    for f in ($args | where $it != '-d') {"
        "        print $'File: ($f)'"
        "        for l in (open --raw $f | decode utf-8 | lines | where ($it | str starts-with 'NEEDED:')) {"
        "            print $'  0x0000000000000001 NEEDED               Shared library: [($l | str substring 7..)]'"
        "        }"
        "    }"
        "}"
    ] | str join "\n"
    $body | save -f $stub
    ^chmod +x $stub
    $stub
}

def --wrapped trim [root: string, ...args: string] {
    ^$nu.current-exe $SCRIPT trim --root $root ...$args | complete
}

def exists [root: string, p: string] { ($root | path join $p) | path exists }
def gone [root: string, p: string] { not (exists $root $p) and (($root | path join $p) | path type) != "symlink" }

let tmp = (^mktemp -d | str trim | path expand)
let stub = make-stub $tmp

# ---- image mode refuses off FreeBSD (this test runs on macOS/Linux CI)
if $nu.os-info.name != "freebsd" {
    let r = (^$nu.current-exe $SCRIPT --image /nonexistent.qcow2 --out ($tmp | path join o.qcow2) | complete)
    if $r.exit_code != 2 { fail $"image mode off FreeBSD should exit 2, got ($r.exit_code)" }
}

# ---- usage errors
let bad = trim ($tmp | path join nope)
if $bad.exit_code != 2 { fail "missing --root should exit 2" }
let r0 = $tmp | path join r0
make-root $r0
let badp = trim $r0 --profile huge
if $badp.exit_code != 2 { fail "unknown profile should exit 2" }

# ---- dry run: plans, measures, deletes nothing
let dry = trim $r0 --profile coordinator --arch amd64 --readelf $stub --dry-run
if $dry.exit_code != 0 { fail $"dry run exited ($dry.exit_code): ($dry.stderr)" }
let dj = $dry.stdout | from json
if $dj.schema_version != "smolfire.shrink-image/v1" { fail "schema_version missing" }
if not $dj.dry_run { fail "dry_run flag not reported" }
if not (exists $r0 usr/lib/debug) { fail "dry run deleted usr/lib/debug" }
if not (exists $r0 boot/kernel/zfs.ko) { fail "dry run deleted zfs.ko" }
if ($dj.removed | where class == "debug-symbols" | get 0.count) < 1 { fail "dry run planned no debug-symbols" }
if $dj.removed_bytes <= 0 { fail "dry run measured 0 bytes" }
if "zfs.ko" in $dj.kept_modules { fail "dry run kept_modules lists zfs.ko" }
if $dj.needed_check.status != "ok" { fail $"needed check should pass on the fake tree: ($dj.needed_check | to json -r)" }

# ---- coordinator (amd64): the real trim
let r1 = $tmp | path join r1
make-root $r1
let res = trim $r1 --profile coordinator --arch amd64 --readelf $stub
if $res.exit_code != 0 { fail $"coordinator trim exited ($res.exit_code): ($res.stderr)" }
let j = $res.stdout | from json
for c in [debug-symbols static-libs toolchain tests docs locale zoneinfo rescue firmware kernel-modules loader-extras hw-tools zfs sendmail unbound net-debug pkg-cache] {
    if not ($c in ($j.removed | get class)) { fail $"class ($c) missing from report" }
}
for p in [usr/lib/debug usr/lib/libc.a usr/lib/crt1.o usr/include usr/lib/clang usr/bin/clang usr/bin/cc
          usr/bin/llvm-ar usr/lib/libprivatellvm.so.19 usr/share/man usr/share/doc usr/share/examples
          usr/share/dict usr/share/misc/magic.mgc usr/share/misc/pci_vendors usr/share/i18n usr/share/nls
          usr/share/locale/fr_FR.UTF-8 usr/share/locale/ja_JP.UTF-8 usr/share/zoneinfo/America/Chicago
          usr/share/zoneinfo/Europe/Berlin usr/share/vt rescue usr/tests usr/lib32 usr/bin/kyua boot/firmware
          boot/kernel/zfs.ko boot/kernel/if_rtw89.ko boot/kernel/geom_eli.ko boot/kernel/kernel.debug
          boot/loader_4th.efi boot/menu.4th boot/images usr/sbin/cxgbetool usr/sbin/bhyve usr/sbin/tcpdump
          sbin/zfs lib/libzfs.so.4 usr/libexec/sendmail usr/sbin/local-unbound var/cache/pkg/foo-1.0.pkg] {
    if not (gone $r1 $p) { fail $"coordinator: ($p) should be removed" }
}
for p in [bin/sh sbin/init lib/libc.so.7 usr/sbin/sshd usr/libexec/sshd-session usr/bin/ssh usr/bin/login
          boot/kernel/kernel boot/lua/loader.lua boot/loader.efi boot/kernel/linker.hints
          boot/kernel/virtio.ko boot/kernel/virtio_blk.ko boot/kernel/virtio_pci.ko boot/kernel/if_vtnet.ko
          boot/kernel/tmpfs.ko boot/kernel/nullfs.ko boot/kernel/efirt.ko boot/kernel/nvme.ko
          boot/kernel/cryptodev.ko boot/kernel/if_wg.ko boot/kernel/tpm.ko
          boot/kernel/mymod.ko boot/kernel/umodem.ko
          usr/share/locale/C.UTF-8/LC_CTYPE usr/share/locale/en_US.UTF-8/LC_COLLATE
          usr/share/zoneinfo/UTC usr/share/zoneinfo/Etc/UTC usr/share/zoneinfo/America/Los_Angeles
          usr/share/zoneinfo/Asia/Tokyo usr/share/zoneinfo/zone.tab usr/share/misc/termcap.db
          usr/sbin/ntpd usr/libexec/dma var/db/pkg/local.sqlite var/cache/pkg
          usr/local/bin/keepme usr/local/share/man/man1/k.1 etc/rc.conf root/.profile] {
    if not (exists $r1 $p) { fail $"coordinator: ($p) should be kept" }
}
# C.UTF-8/LC_COLLATE -> ../en_US.UTF-8/LC_COLLATE must still resolve.
if not ((open --raw ($r1 | path join usr/share/locale/C.UTF-8/LC_COLLATE) | decode utf-8) == "x") { fail "C.UTF-8 symlink target was removed" }
if not ("mymod.ko" in $j.modules_wanted_by_config and "umodem.ko" in $j.modules_wanted_by_config) { fail "loader.conf/kld_list modules not detected" }
if ($j.removed | where class == "kernel-modules" | get 0.count) != 3 { fail $"expected 3 modules removed (zfs, if_rtw89, geom_eli): ($j.removed | where class == 'kernel-modules' | to json -r)" }

# ---- minimal (aarch64): ntpd, nvme, cryptodev, if_wg, tpm go too
let r2 = $tmp | path join r2
make-root $r2
let m = trim $r2 --profile minimal --arch aarch64 --readelf $stub
if $m.exit_code != 0 { fail $"minimal trim exited ($m.exit_code): ($m.stderr)" }
for p in [usr/sbin/ntpd boot/kernel/nvme.ko boot/kernel/cryptodev.ko boot/kernel/if_wg.ko boot/kernel/tpm.ko] {
    if not (gone $r2 $p) { fail $"minimal: ($p) should be removed" }
}
for p in [boot/kernel/virtio_blk.ko boot/kernel/if_vtnet.ko usr/sbin/sshd boot/kernel/mymod.ko] {
    if not (exists $r2 $p) { fail $"minimal: ($p) should be kept" }
}

# ---- coordinator on aarch64 drops tpm.ko; tpm profile keeps it and geom_eli
let r3 = $tmp | path join r3
make-root $r3
let c64 = trim $r3 --profile coordinator --arch aarch64 --readelf $stub
if $c64.exit_code != 0 { fail $"coordinator/aarch64 exited ($c64.exit_code)" }
if not (gone $r3 boot/kernel/tpm.ko) { fail "coordinator/aarch64 should drop tpm.ko" }
let r4 = $tmp | path join r4
make-root $r4
let t = trim $r4 --profile tpm --arch aarch64 --readelf $stub
if $t.exit_code != 0 { fail $"tpm profile exited ($t.exit_code)" }
for p in [boot/kernel/tpm.ko boot/kernel/geom_eli.ko usr/sbin/ntpd] {
    if not (exists $r4 $p) { fail $"tpm: ($p) should be kept" }
}

# ---- orphan check: a surviving binary that needs a removed library aborts
# the run before anything is deleted; --allow-orphans lets it through.
let r5 = $tmp | path join r5
make-root $r5
"NEEDED:libprivatellvm.so.19\nNEEDED:libc.so.7\n" | save -f ($r5 | path join usr/sbin/needs-llvm)
let o = trim $r5 --profile coordinator --arch amd64 --readelf $stub
if $o.exit_code != 1 { fail $"orphaned NEEDED should exit 1, got ($o.exit_code)" }
if not ($o.stderr =~ 'needs-llvm') { fail "orphan error does not name the consumer" }
if not (exists $r5 usr/lib/debug) { fail "orphan failure still deleted files" }
let o2 = trim $r5 --profile coordinator --arch amd64 --readelf $stub --allow-orphans
if $o2.exit_code != 0 { fail "--allow-orphans should pass" }
let oj = $o2.stdout | from json
if not ($oj.needed_check.orphans | any {|x| $x.needed == "libprivatellvm.so.19" }) { fail "orphan not listed in report" }

# ---- no readelf: check is skipped, not failed
let r6 = $tmp | path join r6
make-root $r6
let s = trim $r6 --profile coordinator --arch amd64 --readelf /nonexistent/readelf
if $s.exit_code != 0 { fail "missing readelf should not fail the trim" }
if ($s.stdout | from json | get needed_check.status) != "skipped" { fail "missing readelf not reported as skipped" }

rm -rf $tmp
print "shrink-image-test: ok"
