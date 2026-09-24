#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/shrink-image.nu — offline shrink of a built smolfire / FreeBSD VM image.
#
# Takes a finished qcow2, removes what a headless microVM never reads,
# and rebuilds the disk from scratch, so the output carries no stale blocks:
#
#   qcow2 ─convert─▶ raw copy ─mdconfig─▶ fsck + mount rw (the COPY)
#     ─trim─▶ makefs -Z (fresh UFS, used + headroom %) + ESP copy (free space zeroed)
#     ─mkimg─▶ GPT (same partition order, types and labels; swap resized)
#     ─verify─▶ fsck -n + read-only mount + protected-path check
#     ─qemu-img─▶ <out>.qcow2 and <out-stem>.compressed.qcow2 (+ .raw.xz/.raw.zst)
#
# The source image is never opened for writing. Everything happens under a
# work directory next to --out, removed at the end unless --keep-work.
#
# Two entry points:
#   nu bin/shrink-image.nu --image a64.qcow2 --out a64-trimmed.qcow2 \
#       [--profile coordinator] [--target-mib 512] [--swap-mib 256] [--extra-formats]
#       Full pipeline. FreeBSD host, run as root (mdconfig/mount/makefs/mkimg).
#   nu bin/shrink-image.nu trim --root <dir> [--profile coordinator] [--arch amd64] [--dry-run]
#       Only the tree trim, on an already-extracted or mounted root. Portable
#       (macOS/Linux/FreeBSD); tests/shrink-image-test.nu drives this.
#
# Output (AX-first): one JSON document on stdout, schema smolfire.shrink-image/v1:
#   {before, after_used, after_qcow2, after_qcow2_compressed, removed[], ...}
# Byte counts are integers. The image mode also writes <out>.report.json.
#
# Profiles (see docs/IMAGE-SIZE.md for the per-class rationale):
#   minimal      sshd + rc + shell. Drops ntpd, nvme, cryptodev, if_wg as well.
#   coordinator  (default) minimal + ntpd, nvme.ko, cryptodev.ko, if_wg.ko,
#                and tpm.ko on amd64 (the amd64 image is the TPM-attested build).
#   tpm          coordinator + tpm.ko on every arch + geom_eli/aesni/armv8crypto.
#
# Safety rails (all enforced before anything is deleted):
#   * PROTECTED paths are never removed, and neither is any directory that
#     contains one (sshd, sh, init, rtld, libc, loader, kernel, C.UTF-8, UTC, ...).
#   * Shared-library check: every surviving ELF is scanned with readelf -d.
#     A NEEDED library that exists before the trim and would be gone after
#     it aborts the run (exit 1) unless --allow-orphans. Skipped, and marked
#     as skipped in the report, when no readelf is available.
#   * Modules named in loader.conf (*_load="YES") or rc.conf kld_list are
#     always kept, whatever the allowlist says.
#   * /usr/local, /etc, /root, /home and /var (except var/cache/pkg) are
#     never touched.
#
# Exit: 0 ok, 1 safety check failed (orphans, protected path, verify, over
# --target-mib), 2 usage or environment error.

const SCHEMA = "smolfire.shrink-image/v1"
const PROFILES = [minimal coordinator tpm]

# Never removed. Checked after the trim, for every path that existed before it.
const PROTECTED = [
    bin/sh sbin/init libexec/ld-elf.so.1 lib/libc.so.7 lib/libthr.so.3
    sbin/mount sbin/umount sbin/fsck sbin/fsck_ufs sbin/swapon sbin/ifconfig
    sbin/dhclient sbin/devd sbin/kldload sbin/sysctl sbin/route sbin/growfs
    usr/sbin/sshd usr/libexec/sshd-session usr/libexec/sshd-auth usr/libexec/sftp-server
    usr/bin/ssh usr/bin/ssh-keygen usr/bin/login usr/bin/su usr/libexec/getty
    usr/sbin/pw usr/sbin/service usr/sbin/cron usr/sbin/syslogd usr/sbin/newsyslog
    usr/sbin/mailwrapper usr/libexec/dma
    boot/kernel/kernel boot/lua boot/defaults boot/loader.efi boot/loader boot/pmbr boot/gptboot
    boot/device.hints boot/loader.conf etc
    usr/share/locale/C.UTF-8 usr/share/zoneinfo/UTC usr/share/misc/termcap.db
    usr/share/certs usr/local var/db/pkg
]

# Kernel modules kept per profile (regexes on the file name). Everything else
# in /boot/kernel/*.ko goes. virtio, vtnet and the four filesystems are also
# compiled into SMOLFIRE-VM/SMOLBSD; the modules are kept as a fallback for
# stock-kernel builds. Why each one is (or is not) here: docs/IMAGE-SIZE.md.
def module-allow [profile: string, arch: string] {
    let base = [
        '^virtio(_[a-z0-9]+)?\.ko$'   # virtio, virtio_pci/_blk/_console/_random/_balloon/_scsi/_p9fs
        '^if_vtnet\.ko$'              # virtio-net NIC
        '^(tmpfs|nullfs|fdescfs|procfs)\.ko$'   # the four 0.3.0 ships
        '^efirt\.ko$'                 # EFI runtime services (EFI RTC on arm64 virt)
    ]
    let coord = [
        '^nvme\.ko$'                  # bhyve/cloud may present NVMe instead of virtio-blk
        '^cryptodev\.ko$'             # /dev/crypto for OpenSSL devcrypto / kernel offload
        '^if_wg\.ko$'                 # WireGuard, the fleet overlay
    ]
    let tpm = ['^tpm\.ko$' '^geom_eli\.ko$' '^(aesni|armv8crypto)\.ko$']
    match $profile {
        "minimal" => $base
        "coordinator" => ($base | append $coord | append (if $arch == "amd64" { ['^tpm\.ko$'] } else { [] }))
        "tpm" => ($base | append $coord | append $tpm)
        _ => (error make {msg: $"unknown profile ($profile)"})
    }
}

# Regex-escape a literal path so it can go into one big alternation.
def re-escape [s: string] {
    $s | str replace -a -r '([\\.+*?()|\[\]{}^$])' '\$1'
}

# Every glob match under root (absolute paths), existing or dangling symlink.
def glob-all [root: string, pats: list<string>] {
    $pats | each {|p| glob ($root | path join $p) } | flatten | uniq
}

# Disk usage in bytes of a list of absolute paths (du counts hard links once).
def du-bytes [paths: list<string>] {
    if ($paths | is-empty) { return 0 }
    $paths | chunks 500 | each {|c|
        let r = (^du -sk ...$c | complete)
        $r.stdout | lines | parse -r '^(?<k>\d+)\s' | get k | each {|k| $k | into int } | math sum
    } | math sum | $in * 1024
}

# Parse `key="value"` / `key=value` lines from an rc-style file.
def rc-vars [file: string] {
    if not ($file | path exists) { return [] }
    open --raw $file | lines | parse -r '^\s*(?<k>[A-Za-z0-9_]+)\s*=\s*"?(?<v>[^"#]*)"?'
}

# Modules that configuration asks for: loader.conf(.d) *_load="YES" and rc.conf kld_list.
def modules-wanted [root: string] {
    let loader_files = [($root | path join boot/loader.conf)] | append (glob ($root | path join "boot/loader.conf.d/*.conf"))
    let from_loader = $loader_files | each {|f| rc-vars $f } | flatten
        | where {|r| ($r.k | str ends-with "_load") and ($r.v | str lowercase) == "yes" }
        | each {|r| $"($r.k | str replace -r '_load$' '').ko" }
    let from_rc = rc-vars ($root | path join etc/rc.conf) | where k == "kld_list" | get v
        | each {|v| $v | split row -r '\s+' | where $it != "" | each {|m| $"($m | path basename | str replace -r '\.ko$' '').ko" } } | flatten
    $from_loader | append $from_rc | uniq
}

# Top-level entries of dir that are not in keep; recurse into a dir when only
# some of its children are kept (keep = relative paths like "America/New_York").
def prune-except [dir: string, keep: list<string>] {
    if not ($dir | path exists) { return [] }
    ls -a $dir | each {|e|
        let name = $e.name | path basename
        if $name in $keep {
            []
        } else {
            let sub = $keep | where {|k| $k | str starts-with $"($name)/" } | each {|k| $k | str substring (($name | str length) + 1).. }
            if ($sub | is-empty) { [$e.name] } else if $e.type == "dir" { prune-except $e.name $sub } else { [$e.name] }
        }
    } | flatten
}

# Removal classes: {class, why, profiles, enabled, paths} (absolute paths).
def plan-classes [root: string, profile: string, arch: string, keep_tz: list<string>] {
    let rc = rc-vars ($root | path join "etc/rc.conf")
    let rc_yes = {|k| $rc | where k == $k | get v | any {|v| ($v | str lowercase) == "yes" } }
    let mailer = if (($root | path join "etc/mail/mailer.conf") | path exists) { open --raw ($root | path join "etc/mail/mailer.conf") } else { "" }

    # locales: C.UTF-8 + login.conf default lang, plus the targets of any
    # symlinks inside kept locale dirs (FreeBSD shares LC_* files that way).
    let lang = if (($root | path join "etc/login.conf") | path exists) {
        open --raw ($root | path join "etc/login.conf") | parse -r ':lang=(?<l>[^:\\\s]+)' | get -o 0.l
    } else { null }
    let keep_loc0 = ["C.UTF-8"] | append (if $lang != null { [$lang] } else { [] }) | uniq
    let locdir = $root | path join "usr/share/locale"
    let keep_loc = $keep_loc0 | append ($keep_loc0 | each {|l|
        let d = $locdir | path join $l
        if ($d | path exists) {
            ls -a $d | where type == symlink | each {|s|
                let t = (^readlink $s.name | str trim)
                try {
                    $d | path join $t | path expand --no-symlink | path relative-to ($locdir | path expand --no-symlink) | path split | first
                } catch { null }
            } | compact
        } else { [] }
    } | flatten) | uniq

    # zoneinfo: the keep list, plus whatever /etc/localtime points at.
    let lt = $root | path join "etc/localtime"
    let lt_target = if ($lt | path type) == "symlink" {
        let t = (^readlink $lt | str trim)
        if ($t | str contains "zoneinfo/") { [($t | split row "zoneinfo/" | last)] } else { [] }
    } else { [] }

    # modules
    let allow = module-allow $profile $arch
    let wanted = modules-wanted $root
    let kos = glob ($root | path join "boot/kernel/*.ko")
    let ko_drop = $kos | where {|f|
        let n = $f | path basename
        not ($n in $wanted) and not ($allow | any {|re| $n =~ $re })
    }

    # 4th-loader bits go only when the installed loader is the lua one.
    let lua_loader = (($root | path join "boot/lua") | path exists) and (
        not (($root | path join "boot/loader.efi") | path exists) or not (($root | path join "boot/loader_lua.efi") | path exists)
        or ((^cmp -s ($root | path join "boot/loader.efi") ($root | path join "boot/loader_lua.efi") | complete).exit_code == 0))

    let all = $PROFILES
    [
        {class: "debug-symbols", profiles: $all, enabled: true,
         why: "Detached debug info and kernel symbol files; nothing reads them at runtime",
         globs: [usr/lib/debug "boot/kernel/*.debug" "boot/kernel/*.symbols" boot/kernel.old]}
        {class: "static-libs", profiles: $all, enabled: true,
         why: "Static archives, crt objects and pkg-config data: link-time only; the guest links nothing",
         globs: ["usr/lib/*.a" "usr/lib/*.o" usr/libdata/pkgconfig "usr/lib32"]}
        {class: "toolchain", profiles: $all, enabled: true,
         why: "Compiler, linker, debugger, binutils and their private libs; no in-guest compile",
         globs: [usr/bin/cc usr/bin/c++ usr/bin/cpp usr/bin/CC usr/bin/c89 usr/bin/c99
                 usr/bin/clang usr/bin/clang++ usr/bin/clang-cpp usr/bin/clang-format usr/bin/clang-tblgen
                 usr/bin/ld usr/bin/ld.lld usr/bin/lld usr/bin/lldb usr/bin/lldb-server "usr/bin/llvm-*"
                 usr/bin/ar usr/bin/ranlib usr/bin/nm usr/bin/objdump usr/bin/objcopy usr/bin/size
                 usr/bin/strings usr/bin/strip usr/bin/addr2line usr/bin/c++filt usr/bin/readelf
                 usr/bin/gcov usr/bin/gprof usr/bin/ctfconvert usr/bin/ctfdump usr/bin/ctfmerge
                 usr/bin/yacc usr/bin/byacc usr/bin/lex usr/bin/lex++ usr/bin/flex usr/bin/flex++
                 usr/bin/rpcgen usr/bin/crunchgen usr/bin/crunchide
                 "usr/lib/libprivatellvm.so*" "usr/lib/libprivateclang.so*" "usr/lib/libprivatelldb.so*"
                 "usr/lib/libprivateopencsd.so*" "usr/lib/libprivategtest*.so*" "usr/lib/libprivategmock*.so*"
                 "usr/lib/libomp.so*" usr/lib/clang usr/include usr/share/mk
                 libexec/ld-elf32.so.1 usr/libexec/ld-elf32.so.1]}
        {class: "tests", profiles: $all, enabled: true,
         why: "ATF/kyua test suites and their runners",
         globs: [usr/tests usr/bin/kyua "usr/bin/atf-*" "usr/libexec/atf-*" usr/share/atf usr/share/kyua
                 "usr/lib/libatf-c*.so*" "usr/lib/libprivateatf*.so*"]}
        {class: "docs", profiles: $all, enabled: true,
         why: "Manual pages, docs, examples, dictionaries, games data, OpenSSL html, sendmail cf, file(1) magic, PCI/USB id tables",
         globs: [usr/share/man usr/share/doc usr/share/examples usr/share/dict usr/share/games
                 usr/share/openssl usr/share/sendmail usr/share/info usr/share/me usr/share/tmac
                 usr/share/misc/magic usr/share/misc/magic.mgc usr/share/misc/pci_vendors
                 usr/share/misc/usb_vendors usr/share/misc/usbdevs usr/share/misc/bsd-family-tree
                 "usr/share/misc/committers-*.dot" usr/share/misc/organization.dot usr/share/misc/flowers
                 usr/share/misc/birthtoken usr/share/misc/operator usr/share/misc/iso3166
                 usr/share/misc/iso639 usr/share/misc/latin1 usr/share/misc/ascii
                 usr/share/misc/gprof.callg usr/share/misc/gprof.flat usr/share/misc/mdoc.template
                 usr/share/misc/definitions.units usr/share/misc/scsi_modes]}
        {class: "locale", profiles: $all, enabled: true,
         why: $"Locale data except ($keep_loc | str join ', '); i18n charmap/iconv tables and NLS catalogs",
         paths: ((prune-except $locdir $keep_loc) | append (glob-all $root [usr/share/i18n usr/share/nls]))}
        {class: "zoneinfo", profiles: $all, enabled: true,
         why: $"Time zones except ($keep_tz | append $lt_target | uniq | str join ', ')",
         paths: (prune-except ($root | path join "usr/share/zoneinfo") ($keep_tz | append $lt_target | uniq))}
        {class: "console-data", profiles: $all, enabled: true,
         why: "syscons/vt keymaps and fonts; the guest console is a serial UART",
         globs: [usr/share/syscons usr/share/vt]}
        {class: "rescue", profiles: $all, enabled: true,
         why: "Static crunched rescue tools; a disposable microVM is rebuilt, not repaired",
         globs: [rescue]}
        {class: "firmware", profiles: $all, enabled: true,
         why: "NIC/WiFi/HBA firmware blobs; the hypervisor exposes virtio only",
         globs: [boot/firmware]}
        {class: "kernel-modules", profiles: $all, enabled: true,
         why: $"Modules outside the ($profile)/($arch) allowlist and not named in loader.conf or kld_list",
         paths: $ko_drop}
        {class: "loader-extras", profiles: $all, enabled: $lua_loader,
         why: "Forth/simp/kboot/u-boot loader variants, splash images and CD/PXE/ZFS boot blocks; the installed loader is the lua one",
         globs: ["boot/*.4th" boot/menu.rc boot/loader.rc boot/loader_4th.efi boot/loader_4th boot/loader_simp.efi
                 boot/loader_simp boot/loader.kboot boot/loader.help.kboot boot/uboot boot/images boot/boot1.efi
                 boot/pxeboot boot/cdboot boot/isoboot boot/gptzfsboot boot/zfsboot boot/zfsloader boot/zfs]}
        {class: "hw-tools", profiles: $all, enabled: true,
         why: "Tools for hardware a virtio guest does not have: Chelsio/Mellanox, WiFi, Bluetooth, bhyve host, APM, RAID HBAs",
         globs: [usr/sbin/cxgbetool usr/sbin/mlx5tool usr/sbin/mlxcontrol usr/sbin/wpa_supplicant usr/sbin/wpa_cli
                 usr/sbin/wpa_passphrase usr/sbin/hostapd usr/sbin/hostapd_cli usr/sbin/bhyve usr/sbin/bhyvectl
                 usr/sbin/bhyveload usr/sbin/iwmbtfw usr/sbin/ath3kfw usr/sbin/bcmfw usr/sbin/bthidcontrol
                 usr/sbin/bthidd usr/sbin/btpand usr/sbin/hccontrol usr/sbin/hcsecd usr/sbin/l2control
                 usr/sbin/l2ping usr/sbin/rfcomm_pppd usr/sbin/sdpcontrol usr/sbin/sdpd usr/sbin/bluetooth-config
                 usr/bin/bthost usr/bin/btsockstat usr/bin/rfcomm_sppd usr/sbin/fwcontrol usr/sbin/apm
                 usr/sbin/apmd usr/sbin/zzz usr/sbin/mpsutil usr/sbin/mprutil usr/sbin/mptutil usr/sbin/mfiutil
                 usr/sbin/mrsasutil usr/sbin/wlandebug usr/sbin/iwmbtfw]}
        {class: "zfs", profiles: $all,
         enabled: (not ((rc-vars ($root | path join "boot/loader.conf")) | any {|v| $v.k == "zfs_load" and ($v.v | str lowercase) == "yes" }) and not (do $rc_yes "zfs_enable")),
         why: "ZFS userland and boot environments; the image root is UFS and zfs.ko is not shipped",
         globs: [sbin/zfs sbin/zpool sbin/zfsbootcfg usr/sbin/zdb usr/sbin/zhack usr/sbin/zinject
                 usr/sbin/zstream usr/sbin/zstreamdump usr/sbin/ztest usr/sbin/zfsd usr/sbin/bectl
                 usr/bin/zinject usr/bin/zstream usr/bin/zstreamdump usr/bin/ztest
                 "lib/libzfs.so*" "lib/libzfs_core.so*" "lib/libzpool.so*" "lib/libzutil.so*" "lib/libbe.so*"
                 "lib/libzfsbootenv.so*" "usr/lib/libzfs.so*" "usr/lib/libzfs_core.so*" "usr/lib/libzpool.so*"
                 "usr/lib/libzutil.so*" "usr/lib/libbe.so*" "usr/lib/libzfsbootenv.so*"]}
        {class: "sendmail", profiles: $all, enabled: (not ($mailer | str contains "libexec/sendmail")),
         why: "Sendmail MTA binaries; mailer.conf routes to dma(8)",
         globs: [usr/libexec/sendmail usr/sbin/editmap usr/sbin/mailstats usr/sbin/makemap usr/sbin/praliases]}
        {class: "unbound", profiles: $all, enabled: (not (do $rc_yes "local_unbound_enable")),
         why: "local-unbound resolver; not enabled, resolv.conf comes from DHCP",
         globs: ["usr/sbin/local-unbound*" "usr/lib/libprivateunbound.so*"]}
        {class: "net-debug", profiles: [minimal coordinator], enabled: true,
         why: "tcpdump; diagnostic only, install on demand",
         globs: [usr/sbin/tcpdump]}
        {class: "ntp", profiles: [minimal], enabled: (not (do $rc_yes "ntpd_enable")),
         why: "ntpd suite; the minimal profile takes its clock from the host (kvmclock/virtual RTC)",
         globs: [usr/sbin/ntpd usr/sbin/ntpdate usr/sbin/ntpdc usr/sbin/ntpq usr/sbin/ntp-keygen usr/sbin/ntptime usr/sbin/sntp]}
        {class: "pkg-cache", profiles: $all, enabled: true,
         why: "Cached package files (the effect of pkg clean -a); the package database is kept",
         globs: ["var/cache/pkg/*"]}
    ] | where {|c| $profile in $c.profiles } | each {|c|
        let paths = if "paths" in ($c | columns) { $c.paths } else if $c.enabled { glob-all $root $c.globs } else { [] }
        {class: $c.class, why: $c.why, enabled: $c.enabled, paths: (if $c.enabled { $paths } else { [] })}
    }
}

# readelf -d over files -> [{file, needed}] (chunks of >= 2 files so
# llvm-readelf prints "File:" headers).
def scan-needed [readelf: string, files: list<string>] {
    $files | chunks 200 | each {|c|
        let c2 = if ($c | length) == 1 { $c | append $c } else { $c }
        let out = (^$readelf -d ...$c2 | complete).stdout
        $out | split row -r '(?m)^File: ' | skip 1 | each {|blk|
            let ls = $blk | lines
            let f = $ls | first | str trim
            $ls | skip 1 | parse -r 'NEEDED\)?\s+Shared library: \[(?<lib>[^\]]+)\]' | each {|m| {file: $f, needed: $m.lib} }
        } | flatten
    } | flatten | uniq
}

# Library names visible in the standard search dirs.
def lib-names [root: string] {
    [lib usr/lib usr/lib/compat usr/local/lib] | each {|d| $root | path join $d }
        | where {|d| $d | path exists }
        | each {|d| ls -a $d | where type != dir | get name }
        | flatten
}

# The trim itself. Returns the report fragment; deletes nothing when dry_run.
def trim-tree [root: string, profile: string, arch: string, readelf: string,
               dry_run: bool, allow_orphans: bool, keep_tz: list<string>] {
    if not ($profile in $PROFILES) { error make {msg: $"--profile must be one of ($PROFILES | str join '|'), got ($profile)"} }
    let root = $root | path expand
    let protected_before = $PROTECTED | where {|p| ($root | path join $p) | path exists }
    let prot_abs = $protected_before | each {|p| $root | path join $p }

    let plan = plan-classes $root $profile $arch $keep_tz | each {|c|
        # Drop any candidate that is, or contains, a protected path.
        let ok = $c.paths | where {|p| not ($prot_abs | any {|q| $q == $p or ($q | str starts-with $"($p)/") }) }
        let skipped = $c.paths | where {|p| not ($p in $ok) }
        $c | merge {paths: $ok, skipped_protected: ($skipped | each {|p| $p | path relative-to $root })}
    }
    let planned = $plan | get paths | flatten | uniq

    # Shared-library regression check, computed on the plan before deleting.
    let has_readelf = (which $readelf | is-not-empty) or ($readelf | path exists)
    let needed_check = if not $has_readelf {
        {status: "skipped", reason: $"($readelf) not found", orphans: []}
    } else {
        let gone_re = if ($planned | is-empty) { '^$^' } else {
            '^(' + ($planned | each {|p| re-escape $p } | str join '|') + ')(/|$)'
        }
        let dirs = [bin sbin lib libexec usr/bin usr/sbin usr/lib usr/libexec usr/local/bin usr/local/sbin usr/local/lib usr/local/libexec]
            | each {|d| $root | path join $d } | where {|d| $d | path exists }
        let files = (^find ...$dirs -path "*/usr/lib/debug" -prune -o -type f -print | complete).stdout | lines
            | where {|f| not ($f =~ '\.(a|o|h|debug|symbols|la|pc)$') and not ($f =~ $gone_re) }
        let before = lib-names $root
        let after = $before | where {|p| not ($p =~ $gone_re) } | each {|p| $p | path basename } | uniq
        let before_n = $before | each {|p| $p | path basename } | uniq
        let deps = scan-needed $readelf $files
        let orphans = $deps | where {|d| ($d.needed in $before_n) and not ($d.needed in $after) }
            | each {|d| {file: ($d.file | path relative-to $root), needed: $d.needed} }
        let unresolved_pre = $deps | where {|d| not ($d.needed in $before_n) } | get needed | uniq
        {status: (if ($orphans | is-empty) { "ok" } else { "orphans" }), scanned: ($files | length), needed_edges: ($deps | length),
         orphans: $orphans, unresolved_before_trim: $unresolved_pre}
    }
    if $needed_check.status == "orphans" and not $allow_orphans {
        error make {msg: $"shared-library check: ($needed_check.orphans | length) surviving binaries would lose a NEEDED library: ($needed_check.orphans | first 10 | to json -r)"}
    }

    let removed = $plan | each {|c|
        let bytes = du-bytes $c.paths
        if not $dry_run and ($c.paths | is-not-empty) {
            for chunk in ($c.paths | chunks 500) {
                let r = (^rm -rf ...$chunk | complete)
                if $r.exit_code != 0 {
                    # schg/uchg flags (FreeBSD) block rm; clear them and retry.
                    ^chflags -R -h noschg,nouchg ...$chunk
                    ^rm -rf ...$chunk
                }
            }
        }
        {class: $c.class, why: $c.why, enabled: $c.enabled, count: ($c.paths | length), bytes: $bytes,
         sample: ($c.paths | first 5 | each {|p| $p | path relative-to $root }),
         skipped_protected: $c.skipped_protected}
    }

    let missing = if $dry_run { [] } else { $protected_before | where {|p| not (($root | path join $p) | path exists) } }
    if ($missing | is-not-empty) { error make {msg: $"protected paths missing after trim: ($missing | str join ', ')"} }

    let kept_modules = glob ($root | path join "boot/kernel/*.ko") | where {|f| not ($f in $planned) } | each {|f| $f | path basename } | sort
    {
        profile: $profile, arch: $arch, dry_run: $dry_run
        removed: $removed
        removed_bytes: ($removed | get bytes | math sum)
        kept_modules: $kept_modules
        modules_wanted_by_config: (modules-wanted $root)
        protected: $protected_before
        needed_check: $needed_check
    }
}

# ---------------------------------------------------------------- image mode

def --wrapped sh-run [cmd: string, ...args: string] {
    let r = (^$cmd ...$args | complete)
    if $r.exit_code != 0 { error make {msg: $"($cmd) ($args | str join ' ') failed \(($r.exit_code)\): ($r.stderr | str trim)"} }
    $r.stdout
}

def file-bytes [p: string] { ls -l $p | get 0.size | into int }

def qimg-info [p: string] {
    let j = sh-run qemu-img info --output=json $p | from json
    {file_bytes: (file-bytes $p), virtual_bytes: $j."virtual-size", allocated_bytes: $j."actual-size", format: $j.format}
}

# Unmount everything under work and detach md devices backed by files in it.
def cleanup [work: string] {
    let w = $work | path expand
    ^mount -p | lines | each {|l| $l | split row -r '\s+' | get 1 } | where {|m| $m | str starts-with $w } | reverse
        | each {|m| ^umount -f $m | complete } | ignore
    ^mdconfig -lv | lines | parse -r '^(?<md>md\d+)\s+\S+\s+\S+\s+(?<file>/.*)$'
        | where {|r| $r.file | str starts-with $w } | each {|r| ^mdconfig -d -u $r.md | complete } | ignore
}

def md-attach [file: string, --ro] {
    let args = if $ro { [-a -t vnode -o readonly -f $file] } else { [-a -t vnode -f $file] }
    sh-run mdconfig ...$args | str trim
}

# gpart show -p + -l -> [{index, start, sectors, type, label, dev}]
def partitions [md: string] {
    let types = sh-run gpart show -p $md | lines | parse -r '^\s*(?<start>\d+)\s+(?<sectors>\d+)\s+(?<dev>md\d+p(?<index>\d+))\s+(?<type>\S+)'
    let labels = sh-run gpart show -l $md | lines | parse -r '^\s*\d+\s+\d+\s+(?<index>\d+)\s+(?<label>\S+)'
    $types | each {|t|
        let l = $labels | where index == $t.index | get -o 0.label
        {index: ($t.index | into int), start: ($t.start | into int), sectors: ($t.sectors | into int),
         type: $t.type, label: (if $l == null or $l == "(null)" { null } else { $l }), dev: $t.dev}
    } | sort-by index
}

def detect-arch [kernel: string] {
    let m = (^readelf -h $kernel | complete).stdout | parse -r 'Machine:\s+(?<m>.+)' | get -o 0.m | default "" | str trim
    if ($m =~ 'AArch64') { "aarch64" } else if ($m =~ 'X86-64') { "amd64" } else if ($m =~ 'RISC-V') { "riscv64" } else { "unknown" }
}

def zero-esp [img: string, mnt: string] {
    let md = md-attach $img
    mkdir $mnt
    let ok = (^mount -t msdosfs $"/dev/($md)" $mnt | complete).exit_code == 0
    if $ok {
        ^dd if=/dev/zero of=($mnt | path join .zero) bs=64k | complete | ignore
        rm -f ($mnt | path join .zero)
        ^sync
        sh-run umount $mnt | ignore
    }
    sh-run mdconfig -d -u $md | ignore
    $ok
}

def short-sha [p: string] { (^sha256 -q $p | str trim | str substring 0..4) }

# Full pipeline (FreeBSD, root).
def main [
    --image: string                   # source qcow2 (or raw); never written to
    --out: string                     # output qcow2 path; <stem>.compressed.qcow2 goes next to it
    --target-mib: int = 512           # ceiling on the output's virtual size (exit 1 if above)
    --profile: string = "coordinator" # minimal | coordinator | tpm
    --swap-mib: int = 256             # size of the rebuilt swap partition (0 drops it)
    --headroom-pct: int = 15          # free blocks and inodes in the new UFS, % of its size
    --keep-tz: list<string> = [UTC Etc GMT Universal Zulu Factory posixrules zone.tab zone1970.tab leapseconds tzdata.zi America/Los_Angeles America/New_York Europe/London Europe/Paris Asia/Tokyo]
    --work: string = ""               # work dir (default: <out dir>/.shrink-<stem>)
    --keep-work                       # leave the raw intermediates behind
    --extra-formats                   # also write <stem>.raw.xz and <stem>.raw.zst and report their sizes
    --no-strip                        # skip strip --strip-debug of kernel and modules
    --allow-orphans                   # do not fail the shared-library check
] {
    if $image == null or $out == null { print -e "usage: shrink-image.nu --image <in.qcow2> --out <out.qcow2> [--profile coordinator]"; exit 2 }
    if $nu.os-info.name != "freebsd" { print -e $"shrink-image: image mode needs FreeBSD \(mdconfig, makefs, mkimg\); this is ($nu.os-info.name). Use the 'trim' subcommand on a tree."; exit 2 }
    if (^id -u | str trim) != "0" { print -e "shrink-image: image mode must run as root"; exit 2 }
    if not ($profile in $PROFILES) { print -e $"shrink-image: --profile must be one of ($PROFILES | str join '|')"; exit 2 }
    if not ($image | path exists) { print -e $"shrink-image: --image not found: ($image)"; exit 2 }

    let out = $out | path expand
    let stem = $out | path parse | get stem
    let outdir = $out | path dirname
    let work = if $work == "" { $outdir | path join $".shrink-($stem)" } else { $work } | path expand
    let out_c = $outdir | path join $"($stem).compressed.qcow2"
    mkdir $work
    cleanup $work
    let t0 = date now

    let result = try {
        let before_info = qimg-info $image
        let src = $work | path join src.raw
        sh-run qemu-img convert -O raw $image $src | ignore
        let md = md-attach $src
        let parts = partitions $md
        let ufs = $parts | where type == "freebsd-ufs"
        if ($ufs | length) != 1 { error make {msg: $"expected exactly one freebsd-ufs partition, found ($ufs | length)"} }
        let ufs = $ufs | first
        let ufsdev = $"/dev/($ufs.dev)"
        ^fsck_ufs -y $ufsdev | complete | ignore
        let tp = (^tunefs -p $ufsdev | complete)
        let label = $"($tp.stdout)\n($tp.stderr)" | parse -r 'volume label: \(-L\)\s+(?<l>\S+)' | get -o 0.l
        let mnt = $work | path join mnt
        mkdir $mnt
        sh-run mount -t ufs $ufsdev $mnt | ignore
        let df0 = sh-run df -k $mnt | lines | last | split row -r '\s+'
        let before_used = ($df0 | get 2 | into int) * 1024
        let arch = detect-arch ($mnt | path join boot/kernel/kernel)

        # Copy the non-UFS, non-swap partitions (ESP, freebsd-boot) verbatim.
        let copies = $parts | where {|p| $p.type != "freebsd-ufs" and $p.type != "freebsd-swap" } | each {|p|
            let f = $work | path join $"p($p.index).img"
            sh-run dd $"if=/dev/($p.dev)" $"of=($f)" bs=1m conv=sparse | ignore
            $p | insert file $f
        }
        let pmbr = if ($parts | any {|p| $p.type == "freebsd-boot" }) and (($mnt | path join boot/pmbr) | path exists) {
            let f = $work | path join pmbr
            cp ($mnt | path join boot/pmbr) $f
            $f
        } else { null }

        let trim = trim-tree $mnt $profile $arch "readelf" false $allow_orphans $keep_tz

        # strip --strip-debug kernel + surviving modules (symbol tables stay:
        # the kernel linker resolves module symbols against them).
        let strip = if $no_strip { {status: "skipped"} } else {
            let ks = [($mnt | path join boot/kernel/kernel)] | append (glob ($mnt | path join "boot/kernel/*.ko"))
            let b0 = $ks | each {|f| file-bytes $f } | math sum
            $ks | each {|f| ^strip --strip-debug $f | complete } | ignore
            let b1 = $ks | each {|f| file-bytes $f } | math sum
            {status: "ok", files: ($ks | length), bytes_before: $b0, bytes_after: $b1, saved: ($b0 - $b1)}
        }
        let kldxref = (^kldxref ($mnt | path join boot/kernel) | complete).exit_code == 0

        let tree_used = ((sh-run du -skx $mnt | split row -r '\s+' | first | into int) * 1024)
        let ufsimg = $work | path join root.ufs
        let mk = [-t ffs -Z -o version=2 -b $"($headroom_pct)%" -f $"($headroom_pct)%"]
            | append (if $label != null { [-o $"label=($label)"] } else { [] })
        sh-run makefs ...$mk $ufsimg $mnt | ignore
        sh-run umount $mnt | ignore
        sh-run mdconfig -d -u $md | ignore
        rm -f $src

        let esp_zeroed = $copies | where type == "efi" | each {|p| zero-esp $p.file ($work | path join $"esp($p.index)") } | all {|x| $x }

        # Same partition order, types and labels; swap resized; UFS rebuilt.
        let spec = $parts | each {|p|
            let tl = if $p.label != null { $"($p.type)/($p.label)" } else { $p.type }
            match $p.type {
                "freebsd-ufs" => [-p $"($tl):=($ufsimg)"]
                "freebsd-swap" => (if $swap_mib > 0 { [-p $"($tl)::($swap_mib)M"] } else { [] })
                _ => [-p $"($tl):=($copies | where index == $p.index | get 0.file)"]
            }
        } | flatten
        let raw = $work | path join out.raw
        let mkimg_args = [-s gpt -f raw] | append (if $pmbr != null { [-b $pmbr] } else { [] }) | append $spec | append [-o $raw]
        sh-run mkimg ...$mkimg_args | ignore

        # Verify: partition table, fsck -n, read-only mount, protected paths.
        let md2 = md-attach --ro $raw
        let parts2 = partitions $md2
        let ufs2 = $parts2 | where type == "freebsd-ufs" | first
        let fsck = (^fsck_ufs -n $"/dev/($ufs2.dev)" | complete)
        let vm = $work | path join verify
        mkdir $vm
        sh-run mount -t ufs -o ro $"/dev/($ufs2.dev)" $vm | ignore
        let df1 = sh-run df -k $vm | lines | last | split row -r '\s+'
        let after_used = ($df1 | get 2 | into int) * 1024
        let fs_size = ($df1 | get 1 | into int) * 1024
        let missing = $trim.protected | where {|p| not (($vm | path join $p) | path exists) }
        let fstab_labels = open --raw ($vm | path join etc/fstab) | parse -r '/dev/gpt/(?<l>\S+)' | get l
        let labels2 = $parts2 | get label | compact
        let fstab_ok = $fstab_labels | all {|l| $l in $labels2 or ($swap_mib == 0 and $l == "swapfs") }
        sh-run umount $vm | ignore
        sh-run mdconfig -d -u $md2 | ignore

        sh-run qemu-img convert -O qcow2 $raw $out | ignore
        sh-run qemu-img convert -c -O qcow2 $raw $out_c | ignore
        let extra = if $extra_formats {
            let xz = $outdir | path join $"($stem).raw.xz"
            let zst = $outdir | path join $"($stem).raw.zst"
            ^sh -c $"xz -T0 -9 -c '($raw)' > '($xz)'"
            ^zstd -q -f -19 --long=27 -T0 $raw -o $zst
            {raw_xz: (file-bytes $xz), raw_zst: (file-bytes $zst)}
        } else { {} }
        let raw_bytes = file-bytes $raw
        let after_info = qimg-info $out
        let fsck_clean = $fsck.exit_code == 0
        let verify = {fsck_n: (if $fsck_clean { "clean" } else { $fsck.stdout | lines | last 3 | str join " | " }),
                      mount_ro: "ok", protected_missing: $missing, ufs_rebuilt_from_tree: true, fstab_labels_present: $fstab_ok, esp_free_space_zeroed: $esp_zeroed,
                      partitions: ($parts2 | select index type label sectors)}
        {
            schema_version: $SCHEMA
            image: {path: $image, sha256_prefix: (short-sha $image)}
            out: {qcow2: $out, qcow2_compressed: $out_c, sha256_prefix: (short-sha $out)}
            profile: $profile, arch: $arch
            before: {qcow2: $before_info.file_bytes, virtual: $before_info.virtual_bytes, used: $before_used,
                     partitions: ($parts | select index type label sectors)}
            after_used: $after_used
            after_fs_size: $fs_size
            after_tree_du: $tree_used
            after_raw_virtual: $raw_bytes
            after_qcow2: $after_info.file_bytes
            after_qcow2_compressed: (file-bytes $out_c)
            after_extra: $extra
            target_mib: $target_mib
            within_target: ($raw_bytes <= $target_mib * 1048576)
            removed: $trim.removed
            removed_bytes: $trim.removed_bytes
            kept_modules: $trim.kept_modules
            needed_check: $trim.needed_check
            kernel_strip: $strip
            kldxref: $kldxref
            verify: $verify
            elapsed_s: (((date now) - $t0) / 1sec | math round)
        }
    } catch {|e|
        cleanup $work
        print -e $"shrink-image: FAILED: ($e.msg)"
        exit 1
    }
    if not $keep_work { rm -rf $work }
    $result | to json | save -f $"($out).report.json"
    print ($result | to json)
    if not ($result.verify.fsck_n == "clean" and $result.verify.fstab_labels_present and ($result.verify.protected_missing | is-empty)) { exit 1 }
    if not $result.within_target { print -e $"shrink-image: virtual size ($result.after_raw_virtual) B exceeds --target-mib ($target_mib)"; exit 1 }
}

# Tree-only trim (portable). Prints the JSON fragment; exit 1 on a safety failure.
def "main trim" [
    --root: string                    # extracted or mounted image root
    --profile: string = "coordinator" # minimal | coordinator | tpm
    --arch: string = "auto"           # aarch64 | amd64 | riscv64 | auto (readelf -h on boot/kernel/kernel)
    --readelf: string = "readelf"     # readelf used for the shared-library check
    --dry-run                         # plan and measure only; delete nothing
    --allow-orphans                   # do not fail the shared-library check
    --keep-tz: list<string> = [UTC Etc GMT Universal Zulu Factory posixrules zone.tab zone1970.tab leapseconds tzdata.zi America/Los_Angeles America/New_York Europe/London Europe/Paris Asia/Tokyo]
] {
    if $root == null or not ($root | path exists) { print -e $"shrink-image trim: --root not found: ($root)"; exit 2 }
    if not ($profile in $PROFILES) { print -e $"shrink-image trim: --profile must be one of ($PROFILES | str join '|')"; exit 2 }
    let arch = if $arch == "auto" {
        let k = $root | path join boot/kernel/kernel
        if (which readelf | is-not-empty) and ($k | path exists) { detect-arch $k } else { "unknown" }
    } else { $arch }
    let r = try {
        trim-tree $root $profile $arch $readelf $dry_run $allow_orphans $keep_tz
    } catch {|e|
        print -e $"shrink-image trim: FAILED: ($e.msg)"
        exit 1
    }
    print ({schema_version: $SCHEMA, root: ($root | path expand)} | merge $r | to json)
}
