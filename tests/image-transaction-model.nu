#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Test boundary only: real builder, ordinary private files; no native image,
# extraction, sudo, install, jail, mount or VM command is ever invoked here.
use ../bin/netbsd-microvm-rootfs.nu [image-effect]

export def model-effect [r: record, failure: string, log: string] {
    let safe = ($r | reject -o text)
    (($safe | to json --raw) + "\n") | save --append $log
    if $failure == 'write' and $r.op == 'write' { error make {msg: 'injected write failure'} }
    if $failure == 'hash' and $r.op == 'hash' and ($r.path | str ends-with 'candidate.img') { return 'invalid-digest' }
    if $failure == 'inspect-permissions' and $r.op == 'inspect' and ($r.path | str ends-with 'candidate.img') {
        return ((image-effect $r) | update mode 'rw-r--r--')
    }
    if $failure == 'readback' and $r.op == 'hash' and not ($r.path | str ends-with 'candidate.img') and (open --raw $r.path) != 'OLD-IMAGE' { return ('0' | fill -w 64 -c '0') }
    if $failure == 'cleanup' and $r.op == 'remove' { error make {msg: 'injected cleanup failure'} }
    if $r.op == 'publish' {
        if $failure == 'publish-before' { error make {msg: 'injected commit failure'} }
        image-effect $r
        if $failure == 'publish-after' { error make {msg: 'injected post-commit failure'} }
        return
    }
    if $failure == 'set-snapshot-mismatch' and $r.op == 'copy' { image-effect $r; 'CHANGED-SET' | save --force $r.target; return }
    if $r.op != 'command' { return (image-effect $r) }
    let args = if $r.argv.0 == 'sudo' { $r.argv | skip 1 } else { $r.argv }
    if $failure == $r.stage { return {exit_code: 7, stdout: '', stderr: 'PRIVATE-CHILD-DIAGNOSTIC'} }
    match $args.0 {
        chmod => { image-effect {op: command, argv: $args} }
        chown => { {exit_code: 0, stdout: '', stderr: ''} }
        id => { {exit_code: 0, stdout: "1001\n", stderr: ''} }
        du => { {exit_code: 0, stdout: "12\towned-tree\n", stderr: ''} }
        mkdir => { mkdir ($args | last); {exit_code: 0, stdout: '', stderr: ''} }
        rm => { rm -rf ($args | last); {exit_code: 0, stdout: '', stderr: ''} }
        ln => { ^ln -s ($args | get 2) ($args | get 3) | complete }
        install => {
            let dst = ($args | last)
            let src = ($args | get (($args | length) - 2))
            cp --force $src $dst
            let mode = ($args | get 6)
            image-effect {op: command, argv: [chmod $mode $dst]}
        }
        bsdtar => {
            let pos = ($args | enumerate | where item == '-C' | first | get index)
            let staging = ($args | get ($pos + 1))
            mkdir ($staging | path join etc)
            mkdir ($staging | path join root)
            let certdir = ($staging | path join usr/share/certs/mozilla/server)
            mkdir $certdir
            'DUMMY-CERTIFICATE' | save --force ($certdir | path join fixture.pem)
            if $failure == 'ancestor-link' {
                ^ln -s ($staging | path dirname | path join outside) ($staging | path join opt) | complete | ignore
            }
            {exit_code: 0, stdout: '', stderr: ''}
        }
        makefs => {
            let candidate = ($args | get (($args | length) - 2))
            let size = if '-s' in $args {
                let i = ($args | enumerate | where item == '-s' | first | get index)
                ($args | get ($i + 1) | str replace 'm' '' | into int) * 1048576
            } else { 4096 }
            let bytes = if $failure == 'short-image' { 3 } else { $size }
            ('x' | fill -w $bytes -c 'x') | save $candidate
            if $failure == 'partial-makefs' { return {exit_code: 9, stdout: '', stderr: 'PRIVATE-MAKEFS-DIAGNOSTIC'} }
            {exit_code: 0, stdout: '', stderr: ''}
        }
        _ => { error make {msg: 'unmodeled command: refusing native fallback'} }
    }
}
