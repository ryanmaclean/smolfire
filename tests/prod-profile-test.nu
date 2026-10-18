#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/prod-profile-test.nu — SMOLFIRE_PROFILE=dev|prod for the release confs.
#
# Sources each release/tools/smolfire-qemu*.conf with a fake DESTDIR (same idea
# as the ci.yml conf-hook-test job) and stub pw/chown/chmod/chflags/ssh-keygen,
# then checks the sshd_config and root-credential result per profile:
#   dev (default, unset) : PermitRootLogin yes + PasswordAuthentication yes,
#                          password 'smolfire' set via `pw ... -h 0`
#   prod                 : key-only sshd, root password locked (`pw ... -h -`),
#                          /root/.ssh/authorized_keys == the supplied file
#   prod w/o keys, bad profile : hook fails closed, no permissive sshd_config
# Also checks bin/build-smolfire-vm.nu `profile_make_args` validation.
# The hook is run only up to the profile-dependent lines' effects; the later
# SHARED-TRIM stage is covered by ci.yml conf-hook-test and is not asserted here.
# Run from the repo root: nu tests/prod-profile-test.nu

const stock_sshd = "# stock\n#PermitRootLogin no\n#PasswordAuthentication yes\n#KbdInteractiveAuthentication yes\nPasswordAuthentication yes\nSubsystem sftp /usr/libexec/sftp-server\nMatch User nobody\n    PasswordAuthentication yes\n"

use ../bin/build-smolfire-vm.nu [check_prod_rootfs purge_stale_images profile_env effective_sshd]

def fail [msg: string] {
    print $"prod-profile-test: FAIL — ($msg)"
    exit 1
}

def ok [msg: string] { print $"prod-profile-test: PASS — ($msg)" }

# Build the fake DESTDIR + stub bin dir; returns {dest, bin, keys}
def fixture [] {
    let base = (mktemp -d)
    let dest = $base | path join "dest"
    let bin = $base | path join "bin"
    for d in ["etc/ssh" "etc/pam.d" "boot" "lib" "usr/lib" "var/empty"] {
        mkdir ($dest | path join $d)
    }
    mkdir $bin
    # Stock-like sshd_config: commented defaults plus an UNcommented hostile
    # PasswordAuthentication yes (and one inside a Match block), to prove prod
    # wins by being FIRST (sshd is first-value-wins), not by the stock file
    # happening to be all comments.
    $stock_sshd | save -f ($dest | path join "etc/ssh/sshd_config")
    let stubs = {
        pw: "printf '%s\\n' \"$*\" >> \"$STUBLOG\"; cat >> \"$STUBLOG\" 2>/dev/null || true",
        chown: "printf 'chown %s\\n' \"$*\" >> \"$STUBLOG\"",
        chmod: "printf 'chmod %s\\n' \"$*\" >> \"$STUBLOG\"",
        chflags: "exit 0",
        "ssh-keygen": "f=; while [ $# -gt 0 ]; do [ \"$1\" = -f ] && { f=$2; shift; }; shift; done; [ -n \"$f\" ] && : > \"$f\" && : > \"$f.pub\"; exit 0"
    }
    for s in ($stubs | transpose name body) {
        let p = $bin | path join $s.name
        $"#!/bin/sh\n($s.body)\n" | save -f $p
        ^chmod 755 $p
    }
    let keys = $base | path join "keys.pub"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeytestkeytestkeytestkeytestkey ci@test\n" | save -f $keys
    {base: $base, dest: $dest, bin: $bin, keys: $keys, log: ($base | path join "stub.log")}
}

# Run the hook; extra is a record of env overrides. Returns {code, sshd, log, ak}
def run-hook [conf: string, extra: record] {
    let fx = (fixture)
    let env_rec = ({
        DESTDIR: $fx.dest
        STUBLOG: $fx.log
        PATH: ($env.PATH | prepend $fx.bin)
    } | merge $extra)
    let r = (with-env $env_rec {
        "" | ^bash -c $". ($conf); vm_extra_pre_umount" | complete
    })
    let sshd = ($fx.dest | path join "etc/ssh/sshd_config")
    let akp = ($fx.dest | path join "root/.ssh/authorized_keys")
    {
        code: $r.exit_code
        sshd: (if ($sshd | path exists) { open --raw $sshd } else { "" })
        log: (if ($fx.log | path exists) { open --raw $fx.log } else { "" })
        ak: (if ($akp | path exists) { open --raw $akp } else { null })
    }
}

def main [] {
    # SMOLFIRE_SPAWN_SUBAGENT must stay unset (billed-subprocess guard)
    hide-env --ignore-errors SMOLFIRE_SPAWN_SUBAGENT

    for conf in (glob release/tools/smolfire-qemu*.conf) {
        let name = ($conf | path basename)

        # --- default (unset) == dev
        let d = (run-hook $conf {})
        if not ($d.sshd | str contains "PermitRootLogin yes") { fail $"($name): default profile lost PermitRootLogin yes" }
        if not ($d.sshd | str contains "PasswordAuthentication yes") { fail $"($name): default profile lost PasswordAuthentication yes" }
        if not ($d.log | str contains "usermod root -h 0") { fail $"($name): dev must set the smolfire password via -h 0" }
        if not ($d.log | str contains "smolfire") { fail $"($name): dev password not fed to pw" }
        if $d.ak != null { fail $"($name): dev must not install authorized_keys" }
        ok $"($name): default == dev, password login kept"

        # --- explicit dev identical to default
        let d2 = (run-hook $conf {SMOLFIRE_PROFILE: "dev"})
        if $d2.sshd != $d.sshd { fail $"($name): explicit dev differs from default sshd_config" }
    }

    for conf in (glob release/tools/smolfire-qemu*.conf) {
        let name = ($conf | path basename)
        let fx = (fixture)
        let env_rec = {
            DESTDIR: $fx.dest, STUBLOG: $fx.log, PATH: ($env.PATH | prepend $fx.bin)
            SMOLFIRE_PROFILE: "prod", SMOLFIRE_AUTHORIZED_KEYS: $fx.keys
        }
        let r = (with-env $env_rec { "" | ^bash -c $". ($conf); vm_extra_pre_umount" | complete })
        let sshd = (open --raw ($fx.dest | path join "etc/ssh/sshd_config"))
        for must in ["PermitRootLogin prohibit-password" "PasswordAuthentication no" "KbdInteractiveAuthentication no"] {
            if not ($sshd | str contains $must) { fail $"($name): prod sshd_config missing '($must)'" }
        }
        # sshd is first-value-wins: assert the EFFECTIVE values, with a hostile
        # uncommented stock line and a Match block present in the fixture.
        let eff = (effective_sshd $sshd)
        if $eff.passwordauthentication != "no" { fail $"($name): effective PasswordAuthentication is ($eff.passwordauthentication) with hostile stock line" }
        if $eff.permitrootlogin != "prohibit-password" { fail $"($name): effective PermitRootLogin is ($eff.permitrootlogin)" }
        if not ($sshd | str contains "Subsystem sftp") { fail $"($name): prod dropped the stock sshd_config content" }
        let marker = (open --raw ($fx.dest | path join "etc/smolfire-profile") | str trim)
        if $marker != "prod" { fail $"($name): prod marker is '($marker)'" }
        # simulate what the real `pw -h -` does to master.passwd, then the
        # post-build verifier must accept the staged rootfs
        "root:*:0:0::0:0:Charlie &:/root:/bin/sh\n" | save -f ($fx.dest | path join "etc/master.passwd")
        let probs = (check_prod_rootfs $fx.dest)
        if ($probs | length) > 0 { fail $"($name): check_prod_rootfs rejected a good prod rootfs: ($probs | str join '; ')" }
        # ...and must reject it when root is not locked (rc-ignored/failed pw)
        "root:$6$abc$def:0:0::0:0:Charlie &:/root:/bin/sh\n" | save -f ($fx.dest | path join "etc/master.passwd")
        if (check_prod_rootfs $fx.dest | is-empty) { fail $"($name): check_prod_rootfs accepted an unlocked root" }
        let log = (open --raw $fx.log)
        if not ($log | str contains "usermod root -h -") { fail $"($name): prod must lock root password via -h -" }
        if ($log | str contains "smolfire") { fail $"($name): prod must not feed the dev password to pw" }
        let ak = ($fx.dest | path join "root/.ssh/authorized_keys")
        if not ($ak | path exists) { fail $"($name): prod did not install authorized_keys \(exit ($r.exit_code)\)" }
        if (open --raw $ak) != (open --raw $fx.keys) { fail $"($name): authorized_keys content differs from supplied file" }
        if not ($log | str contains "chmod 600") { fail $"($name): authorized_keys not chmod 600" }
        ok $"($name): prod is key-only, root locked, key installed"

        # --- prod without keys: fail closed
        for bad in [
            {SMOLFIRE_PROFILE: "prod"}
            {SMOLFIRE_PROFILE: "prod", SMOLFIRE_AUTHORIZED_KEYS: "/nonexistent/keys"}
            {SMOLFIRE_PROFILE: "staging"}
        ] {
            let fx2 = (fixture)
            let e = ({DESTDIR: $fx2.dest, STUBLOG: $fx2.log, PATH: ($env.PATH | prepend $fx2.bin)} | merge $bad)
            let r2 = (with-env $e { "" | ^bash -c $". ($conf); vm_extra_pre_umount" | complete })
            if $r2.exit_code == 0 { fail $"($name): ($bad | to nuon) should fail closed" }
            let s2 = ($fx2.dest | path join "etc/ssh/sshd_config")
            if (open --raw $s2) != $stock_sshd and ((open --raw $s2) | str contains "PermitRootLogin yes") {
                fail $"($name): ($bad | to nuon) left a permissive sshd_config"
            }
            # Fail closed WITHOUT relying on the caller honouring the return
            # code: no marker is written, so the image verifier rejects it.
            if ($fx2.dest | path join "etc/smolfire-profile" | path exists) { fail $"($name): ($bad | to nuon) wrote a profile marker despite failing" }
            if (check_prod_rootfs $fx2.dest | is-empty) { fail $"($name): ($bad | to nuon) rootfs passed check_prod_rootfs although the hook failed" }
        }
        ok $"($name): prod without keys / unknown profile fails closed"
    }

    # --- dev writes marker "dev"; check_prod_rootfs rejects a dev rootfs
    let dv = (fixture)
    with-env {DESTDIR: $dv.dest, STUBLOG: $dv.log, PATH: ($env.PATH | prepend $dv.bin)} {
        ^bash -c ". release/tools/smolfire-qemu.conf; vm_extra_pre_umount" | complete | ignore
    }
    if (open --raw ($dv.dest | path join "etc/smolfire-profile") | str trim) != "dev" { fail "dev marker not 'dev'" }
    if (check_prod_rootfs $dv.dest | is-empty) { fail "check_prod_rootfs accepted a dev rootfs as prod" }
    ok "dev marker + stale-dev-image rootfs rejected by the prod verifier"

    # --- the SHARED-TRIM region must stay byte-identical across the confs
    let region = {|f| open --raw $f | lines | skip until {|l| $l | str contains ">>> SHARED-TRIM >>>" } | take until {|l| $l | str contains "<<< SHARED-TRIM <<<" } | str join "\n" }
    let base = (do $region release/tools/smolfire-qemu.conf)
    for c in ["release/tools/smolfire-qemu-aarch64.conf"] {
        if (do $region $c) != $base { fail $"SHARED-TRIM differs in ($c)" }
    }
    ok "SHARED-TRIM byte-identical"

    # --- stale images are purged so a failed build cannot deliver an older one
    let od = (mktemp -d)
    mkdir ($od | path join "usr/src/release")
    "old dev image" | save -f ($od | path join "usr/src/release/smolfire.ufs.qcow2")
    "keep" | save -f ($od | path join "usr/src/release/notes.txt")
    let gone = (purge_stale_images $od)
    if ($gone | length) != 1 or (glob $"($od)/**/*.qcow2" | length) != 0 { fail "purge_stale_images left a qcow2 behind" }
    if not ($od | path join "usr/src/release/notes.txt" | path exists) { fail "purge_stale_images removed a non-qcow2" }
    ok "purge_stale_images removes every qcow2 and nothing else"

    # --- env export of profile vars
    let pe = (profile_env ["SMOLFIRE_PROFILE=prod" "SMOLFIRE_AUTHORIZED_KEYS=/a=b/k.pub"])
    if $pe.SMOLFIRE_PROFILE != "prod" or $pe.SMOLFIRE_AUTHORIZED_KEYS != "/a=b/k.pub" { fail $"profile_env -> ($pe | to nuon)" }

    # --- the script still parses with the verify-image subcommand
    let h = (^nu bin/build-smolfire-vm.nu verify-image --help | complete)
    if $h.exit_code != 0 { fail "build-smolfire-vm.nu verify-image --help failed" }
    let h2 = (^nu bin/build-smolfire-vm.nu --help | complete)
    if $h2.exit_code != 0 or not ($h2.stdout | str contains "--profile") { fail "build-smolfire-vm.nu --help broken" }
    ok "verify-image subcommand wired"

    # --- build script plumbing
    let b = (nu -c "use bin/build-smolfire-vm.nu profile_make_args; profile_make_args dev '' | to nuon" | str trim)
    if $b != '["SMOLFIRE_PROFILE=dev"]' { fail $"profile_make_args dev -> ($b)" }
    let keys = (mktemp)
    "ssh-ed25519 AAAAtest ci@test\n" | save -f $keys
    let pr = (nu -c $"use bin/build-smolfire-vm.nu profile_make_args; profile_make_args prod '($keys)' | to nuon" | str trim)
    if not ($pr | str contains "SMOLFIRE_PROFILE=prod") or not ($pr | str contains $"SMOLFIRE_AUTHORIZED_KEYS=($keys)") { fail $"profile_make_args prod -> ($pr)" }
    for bad in ["profile_make_args prod ''" "profile_make_args dev /x" "profile_make_args nope ''" "profile_make_args prod /nonexistent"] {
        let r = (^nu -c $"use bin/build-smolfire-vm.nu profile_make_args; ($bad)" | complete)
        if $r.exit_code == 0 { fail $"($bad) should error" }
    }
    ok "build-smolfire-vm.nu profile_make_args validates dev/prod"
    print "prod-profile-test: all passed"
}
