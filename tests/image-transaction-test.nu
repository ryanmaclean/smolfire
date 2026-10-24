#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
use std/assert
use ../bin/netbsd-microvm-rootfs.nu [build-image image-request image-sha512 image-effect]
use ./image-transaction-model.nu [model-effect]

def main [--scratch: string] {
    if $scratch == null or ($scratch | path exists) { error make {msg: 'fresh --scratch path required'} }
    mkdir $scratch
    # RFC 6234 section 8.5 SHA512 tests 1 and 6: independent literal
    # expected digests, including a non-UTF8 byte. No digest implementation copied.
    let vectors = [
        {name: 'rfc6234-abc', bytes: 0x[61 62 63], expected: 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f'}
        {name: 'rfc6234-binary-d0', bytes: 0x[d0], expected: '9992202938e882e73e20f6b69e68a0a7149090423d93c81bab3f21678d4aceeee50e4e8cafada4c85a54ea8306826c4ad6e74cece9631bfa8a549b4ab3fbba15'}
    ]
    for vector in $vectors {
        let path = ($scratch | path join $vector.name)
        $vector.bytes | save $path
        let actual = (image-sha512 $path)
        {name: $vector.name, expected: $vector.expected, actual: $actual} | to json | save ($scratch | path join $'($vector.name).json')
        assert equal $actual $vector.expected
        print $'PASS SHA512 ($vector.name)'
    }
    mut completed = []
    for kind in [state root] {
        let failures = if $kind == state {
            ['none' 'write' 'private workspace chmod failed' 'environment chmod failed' 'image chmod failed' 'makefs failed' 'partial-makefs' 'short-image' 'hash' 'inspect-permissions' 'cleanup' 'publish-before' 'publish-after' 'readback']
        } else {
            ['none' 'set-snapshot-mismatch' 'base extraction failed' 'etc extraction failed' 'file installation failed' 'tree size command failed' 'makefs failed' 'partial-makefs' 'image chown failed' 'image chmod failed' 'hash' 'inspect-permissions' 'staging cleanup failed' 'publish-before' 'publish-after' 'readback']
        }
        for failure in $failures {
            let name = $'($kind)-($failure | str replace --all " " "-")'
            let dir = ($scratch | path join $name)
            mkdir $dir
            let output = ($dir | path join image.img)
            'OLD-IMAGE' | save $output
            let sets = ($dir | path join sets)
            mkdir $sets
            'base-data' | save ($sets | path join base.tar.xz)
            'etc-data' | save ($sets | path join etc.tar.xz)
            [ $'SHA512 (char lparen)base.tar.xz(char rparen) = (image-sha512 ($sets | path join base.tar.xz))' $'SHA512 (char lparen)etc.tar.xz(char rparen) = (image-sha512 ($sets | path join etc.tar.xz))' ] | str join "\n" | save ($sets | path join SHA512)
            let log = ($dir | path join effects.jsonl)
            let req = (image-request $kind $output | merge {sets_dir: $sets, size_mb: 1, env_stdin: true, text: "DUMMY_SECRET=not-a-real-secret\n"})
            let result = (build-image $req --effect {|r| model-effect $r $failure $log})
            $result | to json | save ($dir | path join result.json)
            # Save actual result before asserting. Paths/effects remain in this
            # caller-owned tree even when the process exits on an assertion.
            assert (not (($result | to json) | str contains 'not-a-real-secret')) 'no environment value in result'
            assert (not (($result | to json) | str contains 'PRIVATE-')) 'no child stderr in public result'
            if $failure == 'none' {
                assert (not ('error' in $result)) ($result | to json)
                assert equal $result.transaction.published true
                assert equal (open --raw $output | hash sha256) $result.image.sha256
                assert equal ((ls --long $output | first).mode) 'rw-------'
                assert equal (open --raw $output | str length) (if $kind == state { 1048576 } else { 4096 })
                assert equal $result.transaction.cleanup tree_removed
                if $kind == root { assert equal $result.ca_certs 1 }
            } else {
                assert ('error' in $result) ($result | to json)
                # Prove the requested fault was reached, not merely an earlier failure.
                let expected_stage = match $failure {
                    'write' | 'environment chmod failed' => 'state-environment'
                    'private workspace chmod failed' => 'workspace'
                    'set-snapshot-mismatch' => 'snapshot-sets'
                    'base extraction failed' | 'etc extraction failed' => 'extract'
                    'file installation failed' | 'tree size command failed' => 'configure'
                    'makefs failed' | 'partial-makefs' => 'makefs'
                    'short-image' | 'hash' | 'inspect-permissions' | 'image chown failed' | 'image chmod failed' => 'verify-candidate'
                    'cleanup' | 'staging cleanup failed' => 'cleanup'
                    'publish-before' | 'publish-after' => 'publish'
                    'readback' => 'readback'
                    _ => { error make {msg: 'missing fault stage oracle'} }
                }
                assert equal $result.failed_stage $expected_stage ($result | to json)
                let events = (open --raw $log | lines | each {|l| $l | from json})
                let last = ($events | last)
                let workspace = $result.transaction.workspace
                if ($failure | str ends-with ' failed') or $failure == 'partial-makefs' {
                    let child_stage = if $failure == 'partial-makefs' { 'makefs failed' } else { $failure }
                    let code = if $failure == 'partial-makefs' { 9 } else { 7 }
                    assert equal $last.op 'command'
                    assert equal $last.stage $child_stage
                    assert equal $result.detail $'image child failed: ($child_stage); exit=($code)'
                } else {
                    let expected_op = match $failure {
                        'write' => 'write'
                        'set-snapshot-mismatch' => 'hash512'
                        'short-image' | 'inspect-permissions' => 'inspect'
                        'hash' | 'readback' => 'hash'
                        'cleanup' => 'remove'
                        'publish-before' | 'publish-after' => 'publish'
                        _ => { error make {msg: 'missing fault effect oracle'} }
                    }
                    assert equal $last.op $expected_op ($last | to json)
                    if $expected_op == 'publish' {
                        assert equal $last.source ($workspace | path join candidate.img)
                        assert equal $last.target $output
                    } else {
                        let expected_path = match $failure {
                            'write' => ($workspace | path join tree/agent.env)
                            'set-snapshot-mismatch' => ($workspace | path join sets/base.tar.xz)
                            'cleanup' => ($workspace | path join tree)
                            'readback' => $output
                            _ => ($workspace | path join candidate.img)
                        }
                        assert equal $last.path $expected_path
                    }
                    if $failure == 'short-image' { assert equal ((ls --long ($workspace | path join candidate.img) | first).size | into int) 3 }
                    if $failure == 'set-snapshot-mismatch' { assert equal (open --raw $last.path) 'CHANGED-SET' }
                }
                assert ($result.transaction.workspace | path exists) 'failed workspace retained'
                if $failure in [publish-after readback] {
                    assert ((open --raw $output) != 'OLD-IMAGE') 'post-commit outcome is explicit'
                    assert equal $result.transaction.published (if $failure == readback { true } else { null })
                } else {
                    assert equal (open --raw $output) 'OLD-IMAGE' 'all pre-commit failures preserve previous bytes'
                    assert equal $result.transaction.published (if $failure == publish-before { null } else { false })
                }
                if $failure in ['partial-makefs' 'makefs failed'] { assert equal $result.failed_stage makefs }
                if $failure == partial-makefs { assert (($result.transaction.workspace | path join candidate.img) | path exists) 'partial candidate retained' }
                if $failure == set-snapshot-mismatch { assert equal $result.failed_stage snapshot-sets }
                if $failure == inspect-permissions { assert equal $result.failed_stage verify-candidate }
            }
            $completed = ($completed | append $name)
            print $'PASS ($name)'
        }
    }
    # Actual validation path: no modeled external request may occur.
    for destination in ['/../escape' '/opt/../../escape' '/opt//bad' '/opt/./bad' '/'] {
        let dir = ($scratch | path join $'invalid-add-($completed | length)')
        mkdir $dir
        let output = ($dir | path join image.img)
        'OLD-IMAGE' | save $output
        let input = ($dir | path join source)
        'dummy' | save $input
        let log = ($dir | path join effects.jsonl)
        let result = (build-image (image-request root $output | update add $'($input):($destination)') --effect {|r| model-effect $r '' $log})
        $result | to json | save ($dir | path join result.json)
        assert equal $result.failed_stage validate
        assert equal $result.detail 'image policy: add destination must be a confined guest path'
        assert equal $result.transaction.workspace null
        assert equal (open --raw $output) 'OLD-IMAGE'
        let events = (open --raw $log | lines | each {|l| $l | from json})
        assert equal ($events | where op == command | length) 0
        $completed = ($completed | append $'invalid-add-($destination)')
    }

    for failure in ['none' 'ancestor-link'] {
        let dir = ($scratch | path join $'root-add-($failure)')
        mkdir $dir
        let output = ($dir | path join image.img)
        'OLD-IMAGE' | save $output
        let input = ($dir | path join input)
        'PAYLOAD' | save $input
        let sets = ($dir | path join sets)
        mkdir $sets
        'base' | save ($sets | path join base.tar.xz)
        'etc' | save ($sets | path join etc.tar.xz)
        [$'SHA512 (char lparen)base.tar.xz(char rparen) = (image-sha512 ($sets | path join base.tar.xz))' $'SHA512 (char lparen)etc.tar.xz(char rparen) = (image-sha512 ($sets | path join etc.tar.xz))'] | str join "\n" | save ($sets | path join SHA512)
        let log = ($dir | path join effects.jsonl)
        let req = (image-request root $output | merge {sets_dir: $sets, add: $'($input):/opt/test/payload:0755', keep_staging: true})
        let result = (build-image $req --effect {|r| model-effect $r $failure $log})
        $result | to json | save ($dir | path join result.json)
        if $failure == none {
            assert (not ('error' in $result)) ($result | to json)
            let installed = ($result.staging | path join opt/test/payload)
            assert equal (open --raw $installed) 'PAYLOAD'
            assert equal ((ls --long $installed | first).mode) 'rwxr-xr-x'
            assert equal $result.transaction.cleanup tree_retained_by_request
            assert equal (open --raw ($result.staging | path join etc/openssl/cert.pem)) "DUMMY-CERTIFICATE\n"
            assert equal $result.ca_certs 1
        } else {
            assert equal $result.failed_stage configure
            assert equal $result.detail 'image policy: stage destination traverses a non-directory'
            assert equal (open --raw $output) 'OLD-IMAGE'
            assert equal ($result.transaction.workspace | path join outside | path exists) false
        }
        $completed = ($completed | append $'root-add-($failure)')
    }

    # Existing output symlink is refused without changing its target.
    let dir = ($scratch | path join output-link)
    mkdir $dir
    let victim = ($dir | path join victim)
    'VICTIM' | save $victim
    let output = ($dir | path join image.img)
    let link = (^ln -s $victim $output | complete)
    assert equal $link.exit_code 0
    let log = ($dir | path join effects.jsonl)
    let result = (build-image (image-request state $output) --effect {|r| model-effect $r '' $log})
    $result | to json | save ($dir | path join result.json)
    assert equal $result.failed_stage validate
    assert equal (open --raw $victim) 'VICTIM'
    assert equal $result.transaction.workspace null
    $completed = ($completed | append output-link)
    # Real no-follow metadata boundary: absence is missing, a dangling link
    # remains a link and must never become an admissible output target.
    let boundary = ($scratch | path join missing-boundary)
    mkdir $boundary
    let absent = ($boundary | path join absent.img)
    let missing = (image-effect {op: inspect, path: $absent})
    $missing | to json | save ($boundary | path join missing.json)
    assert equal $missing {type: missing}
    let dangling = ($boundary | path join dangling.img)
    let linked = (^ln -s $absent $dangling | complete)
    assert equal $linked.exit_code 0
    let meta = (image-effect {op: inspect, path: $dangling})
    $meta | to json | save ($boundary | path join dangling.json)
    assert equal $meta.type symlink
    let log = ($boundary | path join effects.jsonl)
    let denied = (build-image (image-request state $dangling) --effect {|r| model-effect $r '' $log})
    $denied | to json | save ($boundary | path join result.json)
    assert equal $denied.failed_stage validate
    assert equal $denied.transaction.workspace null
    assert equal $denied.transaction.published false
    assert equal (image-effect {op: inspect, path: $absent}) {type: missing}
    assert equal (image-effect {op: inspect, path: $dangling}).type symlink
    let effects = (open --raw $log | lines | each {|line| $line | from json})
    assert ($effects | all {|event| $event.op == inspect}) 'dangling output refused before any mutation or child'
    $completed = ($completed | append dangling-output)
    {schema: 'smolfire.image-transaction-controls.v1', completed: $completed, count: ($completed | length), modeled_native_effects: true, native_image_verified: false} | to json | save ($scratch | path join summary.json)
    print $'image-transaction: ($completed | length) controls passed; native image acceptance false'
}
