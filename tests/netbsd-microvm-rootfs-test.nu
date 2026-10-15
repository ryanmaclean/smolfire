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
    assert ($r.exit_code == 0) $"state build failed: ($r | to json)"
    assert (not ($r.stdout | str contains $secret)) "a value from stdin leaked into the report"
    let rep = ($r.stdout | from json)
    assert ($rep.env_keys == ["DD_API_KEY", "DD_SITE"]) "env key names"
    assert ($rep.image.bytes == 4194304) "state image size"
    rm -rf $tmp
}


print "test: invalid environment is rejected before image replacement"
for bad in ["export DD_API_KEY=dummy", "1BAD=dummy", "SMOLFIRE_ENV_LINE=dummy", "DD_API_KEY=dummy\nnot-an-assignment", ("DD_API_KEY=dummy" + (char --unicode '0000'))] {
    let tmp = (mktemp -d)
    let img = ($tmp | path join "state.img")
    "preserve-existing-image" | save $img
    let r = ($bad | ^nu (script-path) state --out $img --env-stdin | complete)
    assert ($r.exit_code != 0) "invalid environment must fail"
    assert ((open --raw $img) == "preserve-existing-image") "validation must precede image replacement"
    assert (not ($r.stdout | str contains "dummy")) "invalid value leaked to stdout"
    assert (not ($r.stderr | str contains "dummy")) "invalid value leaked to stderr"
    rm -rf $tmp
}

print "test: guest parser keeps values literal and fails startup on invalid data"
let guest = ($env.FILE_PWD | path join ".." "guest" "netbsd-microvm" "etc" "rc")
let rc = (open --raw $guest)
let body = ($rc | split row "load_agent_env() {" | get 1 | split row "\n}\n" | first)
let parser = ("load_agent_env() {" + $body + "\n}\n")
let tmp = (mktemp -d)
let envfile = ($tmp | path join "agent.env")
# Dummy values only; printf would change the value if the file were sourced.
'DD_API_KEY=$(printf injected)
DD_TAGS=alpha beta=gamma
IFS=x
PATH=/nonexistent
LC_ALL=C
DD_EMPTY=
' | save $envfile
let program = ($parser + "\nload_agent_env \"$1\" || exit 8\n[ \"$DD_API_KEY\" = '$(printf injected)' ] || exit 9\n[ \"$DD_TAGS\" = \"alpha beta=gamma\" ] || exit 10\n[ \"$DD_EMPTY\" = \"\" ] || exit 11\n")
let r = (^/bin/sh -c $program fixture $envfile | complete)
assert ($r.exit_code == 0) "guest must preserve literal values despite PATH/IFS changes"
# Model the rc caller's abort-before-exec branch after its earlier -r check.
# This tests the parser/caller contract, not the VM workload marker protocol.
let missing = ($tmp | path join "missing-agent.env")
let failure_program = ($parser + "\nif ! load_agent_env \"$1\" >/dev/null 2>&1; then exit 8; fi\nprintf 'AGENT_START_REACHED\\n'\n")
let missing_result = (^/bin/sh -c $failure_program fixture $missing | complete)
assert ($missing_result.exit_code != 0) "missing environment must fail startup"
assert (not ($missing_result.stdout | str contains "AGENT_START_REACHED")) "startup must not continue after open failure"
for bad in ["DD_API_KEY=dummy\nnot-an-assignment", "SMOLFIRE_ENV_KEY=dummy", "1BAD=dummy", "LC_ALL=C\nÉKEY=dummy"] {
    $bad | save --force $envfile
    let r = (^/bin/sh -c ($parser + "\nload_agent_env \"$1\" || exit 8\nexit 0\n") fixture $envfile | complete)
    assert ($r.exit_code != 0) "guest must reject invalid environment"
    assert (not ($r.stderr | str contains "dummy")) "guest parser leaked a value"
}
rm -rf $tmp

print "netbsd-microvm-rootfs-test: ok"
