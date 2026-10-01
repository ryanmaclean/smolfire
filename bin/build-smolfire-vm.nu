#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/build-smolfire-vm.nu — reproducible smolfire build pipeline
#
# Encodes all lessons from Phase I builds (2026-04-30 to 2026-05-07).
# Run as root (or with sudo) on a FreeBSD aarch64 or amd64 host.
#
# Hard-won fixes encoded here:
#   FIX-1: /etc/src.conf must exist before buildworld (WITHOUT_SENDMAIL etc.)
#           Without it: freebsd.cf install fails, cascades through 8 make levels.
#   FIX-2: the release image stage must run as root — release chroot requires it;
#           running as builder produces empty pkgbase silently.
#   FIX-3: VMSIZE=2g — sparse image works for smolfire; 4g needs ~4G disk free.
#   FIX-4: WITHOUT_DEPEND_FILES=yes — prevents bad substitution from bsd.dep.mk
#           in LLVM builds.
#   FIX-5: Disk check before starting — buildworld needs ~50GB in /usr/obj.
#   FIX-6: Pipeline gating — release must not start if buildworld failed.
#   FIX-7: git safe.directory — release make checks git; must be set before release.
#   FIX-8: Kernel obj cleanup after buildworld — DISABLED by FIX-9 (see Stage 3).
#   FIX-9: release image via cloudware-release + SMOLFIRECONF — the old
#           'vm-image ... CLOUDWARE_CONF=' invocation never sourced the conf
#           (see docs/UR-BSD-VERIFY.md Finding 3).
#   FIX-10: pkgbase filter replaced by an explicit leaf-package list in the
#           release confs (see docs/UR-BSD-VERIFY.md Finding 4).
#
# Usage:
#   sudo nu bin/build-smolfire-vm.nu                    # full pipeline
#   sudo nu bin/build-smolfire-vm.nu --skip-buildworld  # release only (obj already built)
#   sudo nu bin/build-smolfire-vm.nu --arch aarch64     # explicit arch
#   sudo nu bin/build-smolfire-vm.nu --check            # preflight checks only
#   sudo nu bin/build-smolfire-vm.nu --profile prod --authorized-keys ~/.ssh/id_ed25519.pub
#                                                       # key-only root SSH (docs/BUILDING.md)
#   sudo nu bin/build-smolfire-vm.nu --reassemble-from DIR  # image step only, reusing a
#                                                       # prior run's pkgbase repo (see
#                                                       # bin/reassemble-plan.nu, docs/BUILDING.md)

export def main [
    --arch: string = ""              # aarch64 | amd64 | riscv64-experimental (auto-detect if empty)
    --src: string = "/usr/src"       # FreeBSD source tree
    --obj: string = "/usr/obj"       # obj directory
    --kernconf: string = "SMOLFIRE-VM"   # kernel config name
    --vmsize: string = "2g"          # qcow2 sparse size (FIX-3: 2g not 4g)
    --jobs: int = 0                  # parallelism (0 = nproc)
    --skip-buildworld                # skip to release (obj already populated)
    --skip-release                   # buildworld+kernel only, no release image
    --check                          # preflight only, no build
    --profile: string = "dev"        # dev (password root login, CI default) | prod (key-only, needs --authorized-keys)
    --authorized-keys: string = ""   # public-key file installed as /root/.ssh/authorized_keys (prod)
    --reassemble-from: string = ""   # dir with manifest.json + reassemble-products.tar from a prior green run; skips world+kernel
    --log: string = "/var/tmp/smolfire-build.log"
] {
    let t_start = (date now)

    # Validate the image profile up front — before hours of buildworld.
    let profile_args = (profile_make_args $profile $authorized_keys)
    # Reassemble mode (opt-in; default "" leaves every code path below unchanged).
    let reassemble = ($reassemble_from != "")
    if $reassemble and $skip_release {
        error make {msg: "--reassemble-from and --skip-release are mutually exclusive (reassemble exists to build the image)"}
    }
    if $reassemble and $skip_buildworld {
        error make {msg: "--reassemble-from already implies --skip-buildworld; pass only one"}
    }
    # world+kernel are not rebuilt in reassemble mode
    let skip_buildworld = ($skip_buildworld or $reassemble)

    # --- Resolve arch ---
    let resolved_arch = if $arch == "" {
        (^uname -m | str trim)
    } else {
        $arch
    }

    # Normalise: uname returns "aarch64" or "amd64" on FreeBSD
    let arch_target = match $resolved_arch {
        "aarch64" | "arm64" => "aarch64",
        "amd64" | "x86_64"  => "amd64",
        "riscv64" | "riscv" => "riscv64",   # EXPERIMENTAL — cross-build only, no boot gate
        _ => {
            error make {msg: $"Unknown arch: ($resolved_arch) — expected aarch64, amd64, or riscv64"}
        }
    }
    let arch_freebsd = match $arch_target {
        "aarch64" => "arm64",
        "riscv64" => "riscv",
        _         => "amd64",
    }

    # --- Resolve job count ---
    let nj = if $jobs == 0 {
        let ncpu = (^sysctl -n hw.ncpu | str trim | into int)
        # Leave one core free to keep the system responsive
        [($ncpu - 1) 1] | math max
    } else {
        $jobs
    }

    # --- Resolve conf paths ---
    let kernconf_path = $"($src)/sys/($arch_freebsd)/conf/($kernconf)"
    let conf_name = match $arch_target {
        "aarch64" => "smolfire-qemu-aarch64.conf",
        "riscv64" => "smolfire-qemu-riscv64.conf",
        _         => "smolfire-qemu.conf",
    }
    let release_conf = $"($src)/release/tools/($conf_name)"

    print $"smolfire build pipeline starting — arch: ($arch_target)  jobs: ($nj)"
    print $"  src:      ($src)"
    print $"  obj:      ($obj)"
    print $"  kernconf: ($kernconf)"
    print $"  vmsize:   ($vmsize)"
    print $"  log:      ($log)"
    print ""

    # =========================================================================
    # PREFLIGHT
    # =========================================================================
    preflight $src $obj $arch_freebsd $kernconf_path $release_conf $conf_name

    if $check {
        print "Preflight complete — --check mode, no build started."
        return
    }

    # =========================================================================
    # SETUP (always runs before build)
    # =========================================================================
    setup $src

    # REASSEMBLE: restore the prior run's pkgbase repo into the obj layout.
    # unpack validates arch/kernconf/src.conf/kernconf hashes + tar integrity
    # and refuses (=> do a full build) on any mismatch.
    if $reassemble {
        print "==> Reassemble: restoring pkgbase products from a prior run"
        let rp = ($env.FILE_PWD | path join "reassemble-plan.nu")
        ^nu $rp unpack --obj $obj --src $src --arch $arch_target --kernconf $kernconf --from-dir $reassemble_from
    }

    # =========================================================================
    # STAGE 1: buildworld
    # =========================================================================
    if not $skip_buildworld {
        build_world $src $obj $nj $log $arch_freebsd $arch_target
    } else {
        print "[skip] buildworld (--skip-buildworld)"
    }

    # =========================================================================
    # STAGE 2: buildkernel
    # =========================================================================
    if not $skip_buildworld {
        build_kernel $src $obj $nj $log $kernconf $arch_freebsd $arch_target
    } else {
        print "[skip] buildkernel (--skip-buildworld)"
    }

    # =========================================================================
    # STAGE 3: Kernel obj cleanup — DISABLED by FIX-9.
    # FIX-8 freed space by deleting ${obj}/.../sys/${kernconf} before the old
    # (no-op) vm-image stage. The cloudware-release stage depends on
    # pkgbase-repo -> `make -C /usr/src packages`, whose stagekernel step
    # reads exactly that objdir (distributekernel: cd ${KRNLOBJDIR}/SMOLFIRE-VM).
    # Deleting it here fails the release stage hours in. Clean up AFTER the
    # image is built if disk pressure demands it.
    # =========================================================================
    if not $skip_buildworld and not $skip_release {
        print "[skip] kernel obj cleanup (FIX-8) — kernel objs are needed by 'make packages' (FIX-9)"
    }

    # =========================================================================
    # STAGE 4: make cloudware-release
    # =========================================================================
    if not $skip_release {
        # A failed build must never be able to hand back an OLDER image
        # (e.g. a dev image with the public root password after a failed prod
        # build): remove every stale qcow2 before make runs, so any qcow2 that
        # exists afterwards was produced by THIS build.
        let purged = (purge_stale_images $obj)
        if ($purged | length) > 0 {
            print $"  Removed ($purged | length) stale qcow2 from ($obj) before the build"
        }
        build_vm_image $src $obj $nj $log $kernconf $vmsize $release_conf $arch_freebsd $arch_target $profile_args $reassemble_from
    } else {
        print "[skip] cloudware-release (--skip-release)"
    }

    # =========================================================================
    # DONE
    # =========================================================================
    let t_end = (date now)
    let elapsed_secs = ($t_end - $t_start) / 1sec | math round

    if not $skip_release {
        let qcow2 = find_qcow2 $obj $arch_freebsd $arch_target
        # The cw recipe ends in '|| true', so make exits 0 even when
        # mk-vmimage.sh failed. No artifact => the build FAILED. Dump the
        # make log tail so the failure is diagnosable from this stdout
        # alone (run #4 died here with the real error stranded in the VM).
        if ($qcow2 | str starts-with "<") {
            print $"==> NO ARTIFACT — last 120 lines of ($log):"
            ^tail -n 120 $log
            print "==> release objdir contents:"
            ^sh -c $"ls -la ($obj)/usr/src/*/release/ ($obj)/*/usr/src/release/ 2>/dev/null || true"
            error make {msg: $"cloudware-release produced no qcow2 under ($obj) — see log tail above."}
        }
        # prod fails closed HERE, independent of whether make / mk-vmimage.sh
        # honoured vm_extra_pre_umount's return code: inspect the produced image.
        if $profile == "prod" {
            verify_image_rootfs $qcow2 "prod"
            print "  prod image verified: marker, key-only sshd, locked root, authorized_keys."
        }
        print_summary $arch_target $kernconf $qcow2 $elapsed_secs $profile
    } else {
        let elapsed_fmt = format_elapsed $elapsed_secs
        print $"Build stages complete — elapsed: ($elapsed_fmt)"
    }
}

# =========================================================================
# PREFLIGHT — safe read-only checks (used by --check and before every build)
# =========================================================================
def preflight [
    src: string
    obj: string
    arch_freebsd: string
    kernconf_path: string
    release_conf: string
    conf_name: string
] {
    print "==> Preflight checks"
    mut errors = []
    mut warnings = []

    # CHECK: running as root (FIX-2)
    let euid = (^id -u | str trim | into int)
    if $euid != 0 {
        $errors = ($errors | append "Not running as root. release chroot requires root. Run: sudo nu bin/build-smolfire-vm.nu")
    } else {
        print "  [ok] running as root"
    }

    # CHECK: /usr/src/Makefile exists
    if not ($"($src)/Makefile" | path exists) {
        $errors = ($errors | append $"($src)/Makefile not found. Clone the source tree first:\n       git clone -b releng/15.0 https://git.freebsd.org/src.git ($src)")
    } else {
        print $"  [ok] ($src)/Makefile exists"
    }

    # CHECK: obj disk space (FIX-5)
    # df -k returns 1K blocks; we need ~50GB = 50_000_000 KiB free
    # Use the mount point if the dir doesn't exist yet (df the parent)
    let df_target = if ($obj | path exists) { $obj } else { "/" }
    let df_result = (do { ^df -k $df_target } | complete)
    let free_kb = if $df_result.exit_code == 0 {
        let df_out = ($df_result.stdout | lines | where { |l| ($l | str trim) != "" } | last | split row -r '\s+')
        try { $df_out | get 3 | into int } catch { 0 }
    } else {
        0
    }
    let free_gb_str = (($free_kb / 1_048_576.0) | math round --precision 1)
    if $free_kb == 0 {
        $warnings = ($warnings | append $"Could not check disk space for ($obj) — verify manually before building.")
        print $"  [warn] could not check disk space for ($obj)"
    } else if $free_kb < 20_000_000 {
        let msg = $"($obj) has only ($free_gb_str) GiB free. Minimum 20 GiB required for buildworld."
        $errors = ($errors | append $msg)
    } else if $free_kb < 50_000_000 {
        let msg = $"($obj) has ($free_gb_str) GiB free — under 50 GiB; build may fail late."
        $warnings = ($warnings | append $msg)
        print $"  [warn] ($obj): ($free_gb_str) GiB free"
    } else {
        print $"  [ok] ($obj): ($free_gb_str) GiB free"
    }

    # CHECK: kernel config exists
    if not ($kernconf_path | path exists) {
        $warnings = ($warnings | append $"Kernel config ($kernconf_path) not found in /usr/src — will install from repo before build.")
        print $"  [warn] kernel config not in src tree — will be installed by setup"
    } else {
        print $"  [ok] ($kernconf_path) present"
    }

    # CHECK: release conf exists
    if not ($release_conf | path exists) {
        $warnings = ($warnings | append $"Release conf ($release_conf) not found — will install from repo.")
        print $"  [warn] ($conf_name) not in src tree — will be installed by setup"
    } else {
        print $"  [ok] ($release_conf) present"
    }

    # CHECK: /etc/src.conf has required keys (FIX-1)
    let src_conf = "/etc/src.conf"
    if ($src_conf | path exists) {
        let content = (open --raw $src_conf)
        if not ($content | str contains "WITHOUT_SENDMAIL") {
            $warnings = ($warnings | append "/etc/src.conf exists but WITHOUT_SENDMAIL not set — setup will add required keys.")
            print "  [warn] /etc/src.conf missing WITHOUT_SENDMAIL — setup will patch"
        } else {
            print "  [ok] /etc/src.conf has required keys"
        }
    } else {
        $warnings = ($warnings | append "/etc/src.conf absent — setup will create it.")
        print "  [warn] /etc/src.conf absent — setup will create it"
    }

    print ""
    if ($warnings | length) > 0 {
        print $"Preflight warnings: ($warnings | length)"
        for w in $warnings { print $"  ! ($w)" }
        print ""
    }
    if ($errors | length) > 0 {
        print $"Preflight ERRORS: ($errors | length)"
        for e in $errors { print $"  ERROR: ($e)" }
        error make {msg: "Preflight failed — fix errors above before building."}
    }
    print "Preflight passed."
    print ""
}

# =========================================================================
# SETUP — writes that must happen before any build stage
# =========================================================================
def setup [src: string] {
    print "==> Setup"

    # FIX-1: Write /etc/src.conf if missing or incomplete
    #
    # size-lever proposal (docs/IMAGE-SIZE.md; not build-verified — this
    # commit adds no new build run): WITHOUT_DEBUG_LIBRARIES and
    # WITHOUT_DEPEND_FILES do not appear in src.conf(5) for 15.1 (the
    # closest documented knob is WITHOUT_DEPEND_CLEANUP) and are likely
    # no-ops; kept below for now rather than removed sight-unseen — verify
    # with `make -C /usr/src showconfig` before dropping them. The knobs
    # added here (WITHOUT_TOOLCHAIN, WITHOUT_LIB32, WITHOUT_INCLUDES,
    # WITHOUT_INSTALLLIB, WITHOUT_MAN, WITHOUT_RESCUE, WITHOUT_ZFS,
    # WITHOUT_BHYVE, and the hardware-absent set) are all documented in
    # src.conf(5) 15.1-RELEASE and match content this repo's own
    # bin/shrink-image.nu already removes post-build (toolchain, tests,
    # debug-symbols, static-libs, rescue, zfs, hw-tools classes —
    # docs/IMAGE-SIZE.md) — building without them in the first place skips
    # that build work entirely instead of trimming it afterward.
    # WITHOUT_KERNEL_SYMBOLS=yes is passed to the release `make` invocation
    # itself (vmimage.subr reads it directly), not written to src.conf.
    let src_conf = "/etc/src.conf"
    let required_keys = [
        "WITHOUT_SENDMAIL=yes"
        "WITHOUT_TESTS=yes"
        "WITHOUT_DEBUG_FILES=yes"
        "WITHOUT_DEBUG_LIBRARIES=yes"
        "WITHOUT_GAMES=yes"
        "WITHOUT_EXAMPLES=yes"
        "WITHOUT_DEPEND_FILES=yes"   # FIX-4: prevents bad substitution in LLVM builds
        "WITHOUT_TOOLCHAIN=yes"      # implies WITHOUT_CLANG/CLANG_EXTRAS/CLANG_FORMAT/CLANG_FULL/LLD/LLDB/LLVM_COV
        "WITHOUT_LIB32=yes"
        "WITHOUT_INCLUDES=yes"
        # WITHOUT_INSTALLLIB removed (run 35945692124): it leaks into buildworld's
        # stage-1.1 legacy bootstrap — Makefile.inc1 overrides MK_INCLUDES=yes there
        # but NOT MK_INSTALLLIB, so libegacy.a is built yet never installed, and
        # cross-only bootstrap tools (rpcgen/certctl, built when TARGET != host)
        # fail to link -legacy. Native amd64 skips those tools, which is why the
        # knob looked survivable. Its image-size effect is already covered by the
        # release confs' recursive /usr/lib *.a trim + FIX-10 excluding -dev pkgs.
        "WITHOUT_MAN=yes"            # implies WITHOUT_MAN_UTILS
        "WITHOUT_RESCUE=yes"
        "WITHOUT_ZFS=yes"            # image root is UFS; smolfire kernels don't ship zfs.ko
        "WITHOUT_BHYVE=yes"          # guest runs under QEMU/Firecracker, not as a bhyve host
        "WITHOUT_OFED=yes"
        "WITHOUT_UNBOUND=yes"        # resolv.conf comes from DHCP
        "WITHOUT_LOCALES=yes"
        "WITHOUT_NLS=yes"
        # hardware absent in a virtio guest (Makefile.firecracker WITHOUT_VM_ENOENT)
        "WITHOUT_APM=yes"
        "WITHOUT_BLUETOOTH=yes"
        "WITHOUT_CXGBETOOL=yes"
        "WITHOUT_FLOPPY=yes"
        "WITHOUT_GPIO=yes"
        "WITHOUT_MLX5TOOL=yes"
        "WITHOUT_USB=yes"
        "WITHOUT_USB_GADGET_EXAMPLES=yes"
        "WITHOUT_WIRELESS=yes"
    ]

    if not ($src_conf | path exists) {
        print $"  Writing ($src_conf)"
        ($required_keys | str join "\n") + "\n" | save $src_conf
    } else {
        let existing = (open --raw $src_conf)
        let missing = ($required_keys | where { |k| not ($existing | str contains ($k | split row "=" | first)) })
        if ($missing | length) > 0 {
            print $"  Appending ($missing | length) missing key(s) to ($src_conf)"
            "\n# Added by build-smolfire-vm.nu\n" + ($missing | str join "\n") + "\n" | save --append $src_conf
        } else {
            print $"  ($src_conf) already complete"
        }
    }

    # FIX-7: git safe.directory — release make checks git
    print $"  Setting git safe.directory for ($src)"
    run_or_fail "git config" [
        "git" "--no-pager" "config" "--global" "--add" "safe.directory" $src
    ] ""

    # Install kernel configs and release conf from repo if missing.
    # (NB: '2>/dev/null' is bash, not nu — a literal arg to the external
    # command. It made git exit 128 here on every scripted run; see run #2
    # of the hosted pipeline. Dead repo_root binding removed with it.)
    # We're in the smolfire repo — kernel configs are checked in here
    let script_dir = ($env.CURRENT_FILE? | default "" | path dirname)
    # Resolve relative to the script location
    let repo_dir = if ($script_dir | str length) > 0 {
        $script_dir | path join ".."
    } else {
        "."
    }

    for arch_pair in [["arm64" "aarch64"] ["amd64" "amd64"] ["riscv" "riscv64"]] {
        let af = ($arch_pair | get 0)
        let at = ($arch_pair | get 1)
        let kconf_src = $"($repo_dir)/sys/($af)/conf/SMOLFIRE-VM"
        let kconf_dst = $"($src)/sys/($af)/conf/SMOLFIRE-VM"
        if ($kconf_src | path exists) and not ($kconf_dst | path exists) {
            print $"  Installing sys/($af)/conf/SMOLFIRE-VM into src tree"
            ^cp $kconf_src $kconf_dst
        }
    }

    for conf_pair in [["smolfire-qemu.conf" ""] ["smolfire-qemu-aarch64.conf" ""] ["smolfire-qemu-riscv64.conf" ""]] {
        let cname = ($conf_pair | get 0)
        let csrc = $"($repo_dir)/release/tools/($cname)"
        let cdst = $"($src)/release/tools/($cname)"
        if ($csrc | path exists) and not ($cdst | path exists) {
            print $"  Installing ($cname) into src tree"
            ^cp $csrc $cdst
        }
    }

    print "  Setup complete."
    print ""
}

# =========================================================================
# STAGE 1: buildworld
# =========================================================================
def build_world [
    src: string
    obj: string
    nj: int
    log: string
    arch_freebsd: string
    arch_target: string
] {
    print "==> Stage 1: buildworld"

    let make_args = (base_make_args $arch_freebsd $arch_target)
    let cmd_args = ["make" "-j" ($nj | into string) "-C" $src "buildworld"] ++ $make_args

    print $"  Command: ($cmd_args | str join ' ')"
    print $"  Log: ($log)"

    run_logged $cmd_args $log "buildworld"
    print "  buildworld complete."
    print ""
}

# =========================================================================
# STAGE 2: buildkernel
# =========================================================================
def build_kernel [
    src: string
    obj: string
    nj: int
    log: string
    kernconf: string
    arch_freebsd: string
    arch_target: string
] {
    print $"==> Stage 2: buildkernel KERNCONF=($kernconf)"

    let make_args = (base_make_args $arch_freebsd $arch_target) ++ [$"KERNCONF=($kernconf)"]
    let cmd_args = ["make" "-j" ($nj | into string) "-C" $src "buildkernel"] ++ $make_args

    print $"  Command: ($cmd_args | str join ' ')"

    run_logged $cmd_args $log "buildkernel"
    print "  buildkernel complete."
    print ""
}

# =========================================================================
# STAGE 3: Kernel obj cleanup (FIX-8)
# =========================================================================
def cleanup_kernel_obj [
    obj: string
    arch_freebsd: string
    arch_target: string
    kernconf: string
] {
    print "==> Stage 3: Kernel obj cleanup (FIX-8 — disabled by FIX-9)"

    # Path pattern: /usr/obj/usr/src/<arch>.<arch_target>/sys/KERNCONF
    # e.g. /usr/obj/usr/src/arm64.aarch64/sys/SMOLFIRE-VM
    let obj_path = $"($obj)/usr/src/($arch_freebsd).($arch_target)/sys/($kernconf)"
    if ($obj_path | path exists) {
        print $"  Removing ($obj_path)"
        ^rm -rf $obj_path
        print "  Kernel obj cleaned — ~4–6 GiB freed."
    } else {
        # Try alternate path layout (older FreeBSD obj layout)
        let alt_path = $"($obj)/($arch_target).($arch_freebsd)/usr/src/sys/($kernconf)"
        if ($alt_path | path exists) {
            print $"  Removing ($alt_path)"
            ^rm -rf $alt_path
            print "  Kernel obj cleaned."
        } else {
            print $"  [warn] kernel obj path not found at ($obj_path) — skipping cleanup"
        }
    }
    print ""
}

# =========================================================================
# STAGE 4: make cloudware-release
# =========================================================================
# Image profile -> make variables read by release/tools/smolfire-qemu*.conf.
# dev (default): password root login, what every CI gate logs into.
# prod: key-only sshd + locked root password; requires a public-key file.
export def profile_make_args [profile: string, authorized_keys: string] {
    match $profile {
        "dev" => {
            if $authorized_keys != "" {
                error make {msg: "--authorized-keys is only meaningful with --profile prod"}
            }
            ["SMOLFIRE_PROFILE=dev"]
        }
        "prod" => {
            if $authorized_keys == "" {
                error make {msg: "--profile prod requires --authorized-keys <public key file>"}
            }
            let abs = ($authorized_keys | path expand)
            if not ($abs | path exists) {
                error make {msg: $"authorized keys file not found: ($abs)"}
            }
            if (open --raw $abs | lines | where {|l| $l =~ '^(ssh-|ecdsa-|sk-)' } | is-empty) {
                error make {msg: $"no public key line in ($abs)"}
            }
            ["SMOLFIRE_PROFILE=prod" $"SMOLFIRE_AUTHORIZED_KEYS=($abs)"]
        }
        _ => { error make {msg: $"unknown --profile ($profile) — expected dev or prod"} }
    }
}

def build_vm_image [
    src: string
    obj: string
    nj: int
    log: string
    kernconf: string
    vmsize: string
    release_conf: string
    arch_freebsd: string
    arch_target: string
    profile_args: list<string>
    reassemble_from: string = ""
] {
    print "==> Stage 4: make cloudware-release"
    let reassemble = ($reassemble_from != "")

    # FIX-2: verify still root
    let euid = (^id -u | str trim | into int)
    if $euid != 0 {
        error make {msg: "cloudware-release must run as root (release chroot requires root). Re-run with sudo."}
    }

    # Disk check before release (FIX-5). cloudware-release also builds the
    # full pkgbase repo under ${obj} ('make packages'), so ~10 GiB is needed,
    # not the 3 GiB the old vm-image stage assumed.
    let df_out = (^df -k $obj | lines | last | split row -r '\s+')
    let free_kb = try { $df_out | get 3 | into int } catch { 0 }
    let free_gb = ($free_kb / 1_048_576.0 | math round --precision 1)
    if $free_kb < 10_000_000 {
        error make {msg: $"Insufficient disk space: ($free_gb) GiB free in ($obj). Need at least 10 GiB for cloudware-release (pkgbase repo + image)."}
    }
    print $"  Disk: ($free_gb) GiB free in ($obj)"

    # FIX-9: CLOUDWARE_CONF is not a variable the release Makefiles read, and
    # the plain vm-image target never sources a conf (it is also gated behind
    # WITH_VMIMAGES — without it the recipe is a no-op touch). The only path
    # that sources smolfire-qemu*.conf — and thus runs the pkgbase filter, the
    # size-trim, and sshd enablement — is the cloudware machinery with the
    # real per-type variable ${TYPE}CONF (SMOLFIRECONF for CLOUDWARE=smolfire).
    # Proven by prior self-hosted CI builds (.planning/phases/03-*, build-image.yml):
    # cloudware-release generates the cw-smolfire-ufs-qcow2 target.
    # NOTE: pkgbase is the DEFAULT on releng/15.0 (NOPKGBASE=yes opts out into
    # installworld); WITH_PKGBASE was never a release Makefile variable. The
    # cw target depends on pkgbase-repo, which runs `make -C /usr/src packages`
    # — so buildworld must have completed before this stage.
    let make_args = (base_make_args $arch_freebsd $arch_target) ++ [
        $"KERNCONF=($kernconf)"
        "WITH_CLOUDWARE=yes"
        "CLOUDWARE=smolfire"
        $"SMOLFIRECONF=($release_conf)"
        "SMOLFIRE_FORMAT=qcow2"
        "SMOLFIRE_FSLIST=ufs"
        ...$profile_args
        $"VMSIZE=($vmsize)"          # FIX-3: 2g not 4g (conf respects caller)
        "SWAPSIZE=128m"              # Makefile.vm defaults to 1g and always sets
                                     # the env, so the conf's fallback never fires
    ]
    let cmd_args = ["make" "-C" $"($src)/release" "cloudware-release"] ++ $make_args

    print $"  Command: ($cmd_args | str join ' ')"
    print $"  Release conf: ($release_conf)"

    # Record the make variables of this build (the emit side of reassemble mode
    # reads them in `reassemble-plan.nu pack`; harmless otherwise).
    let vars_file = "/var/tmp/smolfire-pkg-make-vars.json"
    $make_args | to json | save -f $vars_file

    # REASSEMBLE guards (all fail closed).
    if $reassemble {
        let rp = ($env.FILE_PWD | path join "reassemble-plan.nu")
        # 1. package-affecting make variables must equal the source run's.
        ^nu $rp check-make-vars --from-dir $reassemble_from --vars-file $vars_file
        # 2. a dry run must show pure image assembly. If make would re-run
        # `make packages` (pkgbase-repo not seen as up to date), or the dry run
        # failed / printed nothing, abort now instead of silently rebuilding
        # world inside a "5 minute" job. stderr is kept in the file too.
        let dry_out = $"($log).dryrun"
        let dry = (do { ^make "-n" ...($cmd_args | skip 1) } | complete)
        $"($dry.stdout)\n($dry.stderr)\n" | save -f $dry_out
        ^nu $rp check-dryrun $dry_out --exit-code $dry.exit_code
    }

    # Export the profile variables into the environment too (not only as make
    # command-line vars) so the conf hook sees them regardless of how make
    # propagates command-line variables to the release scripts.
    let env_rec = (profile_env $profile_args)
    with-env $env_rec {
        run_logged $cmd_args $log "cloudware-release"
    }
    print "  cloudware-release complete."
    print ""
}

# =========================================================================
# HELPERS
# =========================================================================

# Return TARGET/TARGET_ARCH make flags when cross-compiling; empty for native
def base_make_args [arch_freebsd: string arch_target: string] {
    let host_arch = (^uname -m | str trim)
    # If the host and target arch match, native build — no cross flags needed
    # FreeBSD uname -m returns "amd64" or "aarch64"
    let is_native = (
        ($host_arch == "aarch64" and $arch_target == "aarch64") or
        ($host_arch == "amd64"   and $arch_target == "amd64")
    )
    if $is_native {
        []
    } else {
        [$"TARGET=($arch_freebsd)" $"TARGET_ARCH=($arch_target)"]
    }
}

# Run a command, stream to stdout and append to log, error on non-zero exit (FIX-6)
# Strategy: redirect both stdout+stderr to the log file, then tail -f the log so the
# user sees live output. The make commands are long-running; streaming matters.
def run_logged [cmd_args: list<string> log: string stage: string] {
    let cmd = ($cmd_args | first)
    let args = ($cmd_args | skip 1)

    # Append a stage header to the log
    let ts = (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    $"\n=== ($stage) started at ($ts) ===\n" | save --append $log

    print $"  Streaming output to ($log) — run 'tail -f ($log)' in another terminal"

    # Use sh -c to get both stdout+stderr into the log while preserving exit code
    # We use /usr/bin/env sh (POSIX; available on all FreeBSD/macOS)
    let shell_cmd = ($cmd_args | str join ' ')
    let result = (do {
        ^/usr/bin/env sh -c $"($shell_cmd) >> ($log) 2>&1"
    } | complete)

    if $result.exit_code != 0 {
        error make {
            msg: $"Stage '($stage)' failed (exit ($result.exit_code)). See log: ($log)"
        }
    }
}

# Run a command and fail on non-zero exit; used for quick setup commands
def run_or_fail [label: string cmd_args: list<string> _log: string] {
    let cmd = ($cmd_args | first)
    let args = ($cmd_args | skip 1)
    let result = (do { run-external $cmd ...$args } | complete)
    if $result.exit_code != 0 {
        error make {msg: $"($label) failed (exit ($result.exit_code))"}
    }
}

# "K=V" make args -> env record
export def profile_env [args: list<string>] {
    $args | reduce -f {} {|a, acc|
        let kv = ($a | split row -n 2 '=')
        $acc | merge {($kv | get 0): ($kv | get 1)}
    }
}

# Delete every *.qcow2 under the objdir; returns the removed paths.
export def purge_stale_images [obj: string] {
    if not ($obj | path exists) { return [] }
    let found = (do { ^find $obj -name '*.qcow2' -type f } | complete | get stdout
        | lines | where { |l| ($l | str trim) != "" })
    for f in $found { rm -f $f }
    $found
}

# sshd keyword -> FIRST value outside Match blocks (sshd keeps the first
# value it sees; keywords are case-insensitive). Comments/blank lines ignored.
export def effective_sshd [text: string] {
    mut out = {}
    for raw in ($text | lines) {
        let l = ($raw | str trim)
        if $l == "" or ($l | str starts-with "#") { continue }
        let parts = ($l | split row -r '\s+')
        let kw = ($parts | first | str lowercase)
        if $kw == "match" { break }
        if ($parts | length) < 2 { continue }
        if not ($out | columns | any {|c| $c == $kw }) {
            $out = ($out | insert $kw ($parts | get 1 | str lowercase))
        }
    }
    $out
}

# Pure check of a mounted/staged prod rootfs; returns a list of problems
# (empty == good). Needs no FreeBSD, so tests run it on a fixture dir.
export def check_prod_rootfs [root: string] {
    mut bad = []
    let marker = ($root | path join "etc/smolfire-profile")
    if not ($marker | path exists) {
        $bad = ($bad | append "etc/smolfire-profile marker missing (prod hook did not complete)")
    } else {
        let m = (open --raw $marker | str trim)
        if $m != "prod" { $bad = ($bad | append $"etc/smolfire-profile is '($m)', expected 'prod'") }
    }
    let sshd = ($root | path join "etc/ssh/sshd_config")
    if not ($sshd | path exists) {
        $bad = ($bad | append "etc/ssh/sshd_config missing")
    } else {
        let e = (effective_sshd (open --raw $sshd))
        for want in [
            {k: "passwordauthentication", v: "no"}
            {k: "permitrootlogin", v: "prohibit-password"}
            {k: "kbdinteractiveauthentication", v: "no"}
            {k: "permitemptypasswords", v: "no"}
        ] {
            let got = ($e | get -o $want.k | default "<unset>")
            if $got != $want.v { $bad = ($bad | append $"sshd effective ($want.k) = ($got), expected ($want.v)") }
        }
    }
    let mp = ($root | path join "etc/master.passwd")
    if not ($mp | path exists) {
        $bad = ($bad | append "etc/master.passwd missing")
    } else {
        let rootline = (open --raw $mp | lines | where {|l| $l | str starts-with "root:" } | get -o 0)
        if $rootline == null {
            $bad = ($bad | append "no root entry in master.passwd")
        } else {
            let hash = ($rootline | split row ':' | get -o 1 | default "")
            if not ($hash | str starts-with "*") {
                $bad = ($bad | append "root password is not locked (master.passwd root hash does not start with '*')")
            }
        }
    }
    let ak = ($root | path join "root/.ssh/authorized_keys")
    if not ($ak | path exists) {
        $bad = ($bad | append "root/.ssh/authorized_keys missing")
    } else if (open --raw $ak | lines | where {|l| $l =~ '^(ssh-|ecdsa-|sk-)' } | is-empty) {
        $bad = ($bad | append "root/.ssh/authorized_keys has no public key")
    }
    $bad
}

# Mount the produced qcow2 read-only (FreeBSD + root: qemu-img, mdconfig,
# gpart) and run check_prod_rootfs; errors (the build FAILS) on any problem.
export def verify_image_rootfs [qcow2: string, profile: string] {
    if $profile != "prod" { return }
    let work = (^mktemp -d /var/tmp/smolfire-verify.XXXXXX | str trim)
    let raw = ($work | path join "img.raw")
    let mnt = ($work | path join "mnt")
    mkdir $mnt
    let conv = (^qemu-img convert -O raw $qcow2 $raw | complete)
    if $conv.exit_code != 0 { rm -rf $work; error make {msg: $"verify-image: qemu-img convert failed: ($conv.stderr)"} }
    let md = (^mdconfig -a -t vnode -f $raw | complete)
    if $md.exit_code != 0 { rm -rf $work; error make {msg: $"verify-image: mdconfig failed: ($md.stderr)"} }
    let mdname = ($md.stdout | str trim)
    let res = (try {
        let parts = (^gpart show -p $mdname | lines | where {|l| $l =~ 'freebsd-ufs' }
            | each {|l| $l | split row -r '\s+' | where {|x| $x != "" } | get 2 })
        if ($parts | is-empty) { error make {msg: "no freebsd-ufs partition found in image"} }
        let m = (^mount -o ro $"/dev/($parts | first)" $mnt | complete)
        if $m.exit_code != 0 { error make {msg: $"mount failed: ($m.stderr)"} }
        let problems = (check_prod_rootfs $mnt)
        ^umount $mnt | complete | ignore
        {problems: $problems}
    } catch {|e|
        ^umount $mnt | complete | ignore
        {problems: [$"verify-image could not inspect the image: ($e.msg)"]}
    })
    ^mdconfig -d -u $mdname | complete | ignore
    rm -rf $work
    if ($res.problems | length) > 0 {
        error make {msg: $"prod image FAILED verification ($qcow2): ($res.problems | str join '; ')"}
    }
}

# Standalone check: sudo nu bin/build-smolfire-vm.nu verify-image <qcow2> [--profile prod]
export def "main verify-image" [qcow2: string, --profile: string = "prod"] {
    verify_image_rootfs $qcow2 $profile
    print $"verify-image: ($qcow2) OK for profile ($profile)"
}

# Find the built qcow2 image
def find_qcow2 [obj: string arch_freebsd: string arch_target: string] {
    # Standard FreeBSD release output paths.
    # cloudware-release (FIX-9) writes to the release objdir root (e.g.
    # vm.ufs.qcow2 / smolfire.ufs.qcow2); legacy vm-image wrote under release/vm/.
    let candidates = [
        $"($obj)/($arch_freebsd).($arch_target)/usr/src/release"
        $"($obj)/usr/src/($arch_freebsd).($arch_target)/release"
        $"($obj)/usr/src/($arch_freebsd).($arch_target)/release/vm"
        $"($obj)/($arch_target).($arch_freebsd)/usr/src/release/vm"
        $"($obj)/usr/src/release/vm"
    ]

    for dir in $candidates {
        if ($dir | path exists) {
            let found = (ls $dir | where name =~ '\.qcow2$' | get name | get -o 0)
            if $found != null {
                return $found
            }
        }
    }

    # Broader fallback search
    let fallback = (
        do { ^find $obj -name '*.qcow2' -type f } |
        complete | get stdout | lines | where { |l| ($l | str trim) != "" } | get -o 0
    )
    $fallback | default "<qcow2 not found — check /usr/obj manually>"
}

def format_elapsed [secs: int] {
    let h = ($secs / 3600 | math floor)
    let m = (($secs mod 3600) / 60 | math floor)
    let s = ($secs mod 60)
    if $h > 0 {
        $"($h)h ($m)m"
    } else if $m > 0 {
        $"($m)m ($s)s"
    } else {
        $"($s)s"
    }
}

def print_summary [arch: string kernconf: string qcow2: string elapsed_secs: int profile: string] {
    let elapsed = (format_elapsed $elapsed_secs)
    let size_str = if ($qcow2 | path exists) {
        let sz = (ls $qcow2 | get size | first)
        $sz | into string
    } else {
        "unknown"
    }
    let sha_str = if ($qcow2 | path exists) {
        (^sha256 -q $qcow2 | str trim | str substring 0..16) + "..."
    } else {
        "n/a"
    }
    let qcow2_name = ($qcow2 | path basename)

    print ""
    print "╔══════════════════════════════════════════╗"
    print "║  smolfire Build Complete                  ║"
    print "╠══════════════════════════════════════════╣"
    print $"║  arch:    ($arch | fill -w 32)║"
    print $"║  kernel:  ($kernconf | fill -w 32)║"
    print $"║  profile: ($profile | fill -w 32)║"
    print $"║  qcow2:   ($qcow2_name | str substring 0..32 | fill -w 32)║"
    print $"║  size:    ($size_str | fill -w 32)║"
    print $"║  sha256:  ($sha_str | fill -w 32)║"
    print $"║  elapsed: ($elapsed | fill -w 32)║"
    print "╚══════════════════════════════════════════╝"
    print ""
    print $"Full path: ($qcow2)"
}
