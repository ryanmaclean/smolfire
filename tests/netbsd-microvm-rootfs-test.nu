# SPDX-License-Identifier: Apache-2.0
# netbsd-microvm-rootfs-test.nu — host-side checks for
# bin/netbsd-microvm-rootfs.nu that need no NetBSD sets and no sudo:
#   - a set whose SHA512 does not match the release list is refused before
#     anything is extracted
#   - the state subcommand reports env key names only, never values
# Cases that need a missing tool (sha512sum, makefs) are skipped, not failed.

const SCRIPT_REL = "../bin/netbsd-microvm-rootfs.nu"

def assert [cond: bool, label: string] {
    if not $cond { error make {msg: $"assert failed: ($label)"} }
}

def script-path []: nothing -> string {
    $env.FILE_PWD | path join $SCRIPT_REL | path expand
}

print "test: SHA512 mismatch is refused before extraction"
if (which sha512sum | is-empty) {
    print "  skip: sha512sum not on PATH"
} else {
    let tmp = (mktemp -d)
    "not really a set" | save --force ($tmp | path join "base.tar.xz")
    "not really a set" | save --force ($tmp | path join "etc.tar.xz")
    let zero = (0..<128 | each {|_| "0" } | str join)
    [$"SHA512 \(base.tar.xz\) = ($zero)", $"SHA512 \(etc.tar.xz\) = ($zero)"] | str join "\n" | save --force ($tmp | path join "SHA512")
    let r = (^nu (script-path) --sets-dir $tmp --out ($tmp | path join "root.img") | complete)
    assert ($r.exit_code != 0) "mismatched set must fail"
    assert ($r.stderr | str contains "SHA512 mismatch for base.tar.xz") $"unexpected error: ($r.stderr)"
    assert (not (($tmp | path join "root.img") | path exists)) "no image may be written on a mismatch"
    rm -rf $tmp
}

print "test: state disk reports env key names only"
if (which makefs | is-empty) {
    print "  skip: makefs not on PATH"
} else {
    let tmp = (mktemp -d)
    let img = ($tmp | path join "state.img")
    let secret = "not-a-real-key-0123456789abcdef"
    let r = ($"DD_API_KEY=($secret)\nDD_SITE=datadoghq.com\n" | ^nu (script-path) state --out $img --size-mb 4 --env-stdin | complete)
    assert ($r.exit_code == 0) $"state build failed: ($r.stderr)"
    assert (not ($r.stdout | str contains $secret)) "a value from stdin leaked into the report"
    let rep = ($r.stdout | from json)
    assert ($rep.env_keys == ["DD_API_KEY", "DD_SITE"]) "env key names"
    assert ($rep.image.bytes == 4194304) "state image size"
    rm -rf $tmp
}

print "netbsd-microvm-rootfs-test: ok"
