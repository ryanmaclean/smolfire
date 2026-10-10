#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
#
# netbsd-microvm-rootfs.nu — build the immutable rootfs image and the
# writable state disk for bin/netbsd-microvm-prototype.nu from official
# NetBSD 11.0 amd64 sets. Runs on a Linux or BSD build host that has
# bsdtar, makefs (NetBSD makefs; Debian/Ubuntu package "makefs") and sudo
# (sudo keeps the sets' root ownership without an mtree spec).
#
#   nu bin/netbsd-microvm-rootfs.nu --sets-dir DL --out root.img \
#       [--add /path/dd-agent-rs:/opt/datadog/bin/dd-agent-rs:0755] \
#       [--authorized-keys ~/.ssh/id_ed25519.pub] [--hostname smolfire-netbsd]
#   printf 'DD_SITE=datadoghq.com\n...' | nu bin/netbsd-microvm-rootfs.nu state --out state.img --env-stdin
#
# DL must hold base.tar.xz and etc.tar.xz plus the release's sets SHA512
# list (saved as SHA512 or sets-SHA512); every set is checked against it
# before extraction. Secrets never go into the rootfs: the state subcommand
# writes the environment it reads on stdin to /agent.env (mode 0600) on the
# state disk only, and nothing it reads is printed.
#
# Output: one JSON report (schema smolfire.netbsd-microvm-rootfs/v1) on
# stdout.

const SCHEMA = "smolfire.netbsd-microvm-rootfs/v1"
const STATE_SCHEMA = "smolfire.netbsd-microvm-state/v1"

# Paths dropped from base.tar.xz for the minimal image (bsdtar --exclude
# patterns). Pass --full to keep the whole set.
const TRIM = [
    "./stand", "./usr/mdec", "./usr/games",
    "./usr/share/man", "./usr/share/info", "./usr/share/doc",
    "./usr/share/examples", "./usr/share/locale", "./usr/share/i18n",
    "./usr/share/nls", "./usr/share/dict", "./usr/share/games",
    "./usr/share/zoneinfo", "./usr/share/calendar", "./usr/share/me",
    "./usr/share/mi", "./usr/share/tmac", "./usr/share/groff_font",
    "./usr/share/xml", "./usr/share/wscons", "./usr/share/keymaps",
    "./usr/libexec/postfix", "./usr/share/examples/postfix",
    "./usr/lib/*.a", "./usr/lib/*_p.a", "./usr/lib/*_pic.a",
    "./usr/libdata/lint", "./usr/libdata/ldscripts",
]

def guest-dir []: nothing -> string {
    $env.FILE_PWD | path join ".." "guest" "netbsd-microvm" | path expand
}

def sha512-list [sets_dir: string]: nothing -> any {
    for name in ["SHA512", "sets-SHA512"] {
        let p = ($sets_dir | path join $name)
        if ($p | path exists) { return $p }
    }
    error make {msg: $"no SHA512 list in ($sets_dir) \(expected SHA512 or sets-SHA512\)"}
}

# Check one file against a BSD-style "SHA512 (name) = hex" list.
def verify-set [sets_dir: string, name: string]: nothing -> record {
    let file = ($sets_dir | path join $name)
    if not ($file | path exists) {
        error make {msg: $"missing set ($file)"}
    }
    let list = (open --raw (sha512-list $sets_dir) | lines)
    let want = ($list | parse "SHA512 ({name}) = {hex}" | where name == $name)
    if ($want | is-empty) {
        error make {msg: $"($name) is not in the SHA512 list"}
    }
    let got = (^sha512sum $file | split row " " | first)
    if $got != ($want.0.hex | str trim) {
        error make {msg: $"SHA512 mismatch for ($name)"}
    }
    {set: $name, sha512: $got, bytes: ((ls $file).0.size | into int)}
}

def need [tool: string] {
    if (which $tool | is-empty) {
        error make {msg: $"($tool) not found on PATH"}
    }
}

def image-report [img: string]: nothing -> record {
    {
        path: $img,
        bytes: ((ls $img).0.size | into int),
        sha256: (^sha256sum $img | split row " " | first),
    }
}

# Build the rootfs image.
def main [
    --sets-dir: string           # directory with base.tar.xz, etc.tar.xz and the sets SHA512 list (required)
    --out: string                # output FFSv2 image path (required)
    --add: string = ""           # extra files "src:dst[:mode]", comma separated, e.g. the agent binary
    --authorized-keys: string    # public key file installed as /root/.ssh/authorized_keys
    --hostname: string = "smolfire-netbsd"
    --free-pct: int = 10         # free blocks/inodes left in the image (makefs -b/-f)
    --full                       # keep the whole base set (no TRIM)
    --keep-staging               # leave the staging directory for inspection
] {
    if $sets_dir == null { error make {msg: "--sets-dir is required"} }
    if $out == null { error make {msg: "--out is required"} }
    need sha512sum
    # verify before anything is extracted (and before needing sudo/makefs)
    let sets = (["base.tar.xz", "etc.tar.xz"] | each {|s| verify-set $sets_dir $s })
    for t in [bsdtar makefs sudo sha256sum] { need $t }
    let out_abs = ($out | path expand)
    let staging = (mktemp -d -p ($out_abs | path dirname) "nbmicrovm-root.XXXXXX")

    let excludes = (if $full { [] } else { $TRIM | each {|p| ["--exclude", $p] } | flatten })
    ^sudo bsdtar -xpf ($sets_dir | path join "base.tar.xz") -C $staging ...$excludes
    ^sudo bsdtar -xpf ($sets_dir | path join "etc.tar.xz") -C $staging

    # guest init (replaces rc.d), shutdown hook, no getty
    let g = (guest-dir)
    ^sudo install -o 0 -g 0 -m 0555 ($g | path join "etc" "rc") ($staging | path join "etc" "rc")
    ^sudo install -o 0 -g 0 -m 0555 ($g | path join "etc" "rc.shutdown") ($staging | path join "etc" "rc.shutdown")
    ^sudo install -o 0 -g 0 -m 0644 ($g | path join "etc" "ttys") ($staging | path join "etc" "ttys")
    $hostname | ^sudo tee ($staging | path join "etc" "myname") | ignore
    "" | ^sudo tee ($staging | path join "etc" "fstab") | ignore
    # mount points the read-only root needs (not all are in base.tar.xz)
    ^sudo mkdir -p ($staging | path join "state") ($staging | path join "kern") ($staging | path join "proc") ($staging | path join "opt" "datadog" "bin")
    # resolv.conf is written to tmpfs at boot; the root stays read-only
    ^sudo rm -f ($staging | path join "etc" "resolv.conf")
    ^sudo ln -s /var/run/resolv.conf ($staging | path join "etc" "resolv.conf")

    # CA bundle for rustls-native-certs / openssl-probe: certctl(8) needs a
    # writable /etc, so build the bundle here from the set's Mozilla certs.
    let certdir = ($staging | path join "usr" "share" "certs" "mozilla" "server")
    let ca_count = if ($certdir | path exists) {
        let pems = (ls ($certdir | path join "*.pem" | into glob) | get name)
        let bundle = ($pems | each {|p| open --raw $p } | str join "\n")
        ^sudo mkdir -p ($staging | path join "etc" "openssl" "certs")
        $bundle | ^sudo tee ($staging | path join "etc" "openssl" "cert.pem") | ignore
        $bundle | ^sudo tee ($staging | path join "etc" "openssl" "certs" "ca-certificates.crt") | ignore
        $pems | length
    } else { 0 }

    if $authorized_keys != null {
        let ssh = ($staging | path join "root" ".ssh")
        ^sudo install -d -o 0 -g 0 -m 0700 $ssh
        ^sudo install -o 0 -g 0 -m 0600 ($authorized_keys | path expand) ($ssh | path join "authorized_keys")
    }

    mut added = []
    for spec in ($add | split row "," | where {|s| ($s | str trim | str length) > 0 }) {
        let parts = ($spec | split row ":")
        if ($parts | length) < 2 { error make {msg: $"--add wants src:dst[:mode], got ($spec)"} }
        let src = ($parts.0 | path expand)
        let dst = ($staging | path join ($parts.1 | str trim --left --char "/"))
        let mode = ($parts | get -o 2 | default "0644")
        ^sudo install -D -o 0 -g 0 -m $mode $src $dst
        $added = ($added | append {src: $src, dst: $parts.1, mode: $mode, bytes: ((ls $src).0.size | into int)})
    }

    let tree_kb = (^sudo du -sk $staging | split row "\t" | first | into int)
    rm -f $out_abs
    (^sudo makefs -t ffs -B le -o version=2 -o minfree=0
        -b $"($free_pct)%" -f $"($free_pct)%" $out_abs $staging) | ignore
    ^sudo chown $"(^id -u | str trim):(^id -g | str trim)" $out_abs
    if not $keep_staging { ^sudo rm -rf $staging }

    {
        schema: $SCHEMA,
        netbsd_sets: $sets,
        trimmed: (not $full),
        tree_kb: $tree_kb,
        ca_certs: $ca_count,
        hostname: $hostname,
        added: $added,
        staging: (if $keep_staging { $staging } else { null }),
        image: (image-report $out_abs),
        fs: "ffs-v2",
        root_device_hint: "ld0a",
    } | to json --indent 2 | print
}

# Build the writable state disk (FFSv2, mounted with -o log = WAPBL).
def "main state" [
    --out: string                # output image path (required)
    --size-mb: int = 64
    --env-stdin                  # read KEY=VALUE lines from stdin into /agent.env (0600)
] {
    if $out == null { error make {msg: "--out is required"} }
    for t in [makefs sha256sum] { need $t }
    let out_abs = ($out | path expand)
    let staging = (mktemp -d -p ($out_abs | path dirname) "nbmicrovm-state.XXXXXX")
    ^chmod 0700 $staging
    mut env_keys = []
    if $env_stdin {
        # nu does not hand a script's stdin to main as $in; read it explicitly
        let text = (^cat | into string)
        let envf = ($staging | path join "agent.env")
        $text | save --force $envf
        ^chmod 0600 $envf
        # report key names only, never values
        $env_keys = ($text | lines | where {|l| $l =~ '^[A-Za-z_][A-Za-z0-9_]*=' } | each {|l| $l | split row "=" | first })
    }
    rm -f $out_abs
    (^makefs -t ffs -B le -o version=2 -o minfree=0 -s $"($size_mb)m" $out_abs $staging) | ignore
    ^chmod 0600 $out_abs
    rm -rf $staging
    {
        schema: $STATE_SCHEMA,
        image: (image-report $out_abs),
        size_mb: $size_mb,
        fs: "ffs-wapbl",
        env_keys: $env_keys,
        state_device_hint: "ld1a",
    } | to json --indent 2 | print
}
