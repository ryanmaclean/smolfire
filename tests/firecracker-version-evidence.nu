#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Firecracker v1.12.0 writes a stable banner and may also write its own
# timestamped successful-exit log. The executable SHA is checked separately.
export def stable_firecracker_version [raw: string] {
    let expected = 'Firecracker v1.12.0'
    let exit_line = '20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][.][0-9]{9} \[anonymous-instance:main\] Firecracker exiting successfully[.] exit_code=0'
    let pattern = ('\AFirecracker v1[.]12[.]0(\n\n' + $exit_line + ')?\n?\z')
    if not ($raw =~ $pattern) {
        error make {msg: 'malformed or unexpected Firecracker --version stdout'}
    }
    $expected
}
