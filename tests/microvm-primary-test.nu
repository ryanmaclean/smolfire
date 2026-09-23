#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/microvm-primary-test.nu — regression checks for the one-ELF SMOLFIRE
# microVM being the documented and gated primary path.

def fail [msg: string] {
    print $"microvm-primary-test: FAIL — ($msg)"
    exit 1
}

let readme = (open --raw README.md)
let building = (open --raw docs/BUILDING.md)
let workflow = (open --raw .github/workflows/smolfire.yml)

for needle in [
    "Default path: build or download the one-ELF SMOLFIRE microVM."
    "[SMOLFIRE microVM kernel workflow](.github/workflows/smolfire.yml)"
    "bin/build-smolfire.sh"
    "`cloudware-release`"
    "[hosted qcow2 compatibility pipeline](.github/workflows/build-image-hosted.yml)"
] {
    if not ($readme | str contains $needle) {
        fail $"README.md missing: ($needle)"
    }
}

for needle in [
    "## Primary path — one-ELF SMOLFIRE microVM"
    "Firecracker and QEMU `microvm` gates"
    "## Compatibility path — full qcow2 image"
    "| `.github/workflows/smolfire.yml` | **Primary microVM CI** |"
] {
    if not ($building | str contains $needle) {
        fail $"docs/BUILDING.md missing: ($needle)"
    }
}

for needle in [
    "pull_request:"
    "push:"
    "tests/microvm-primary-test.nu"
    "- name: Artifact size gate"
    "- name: Firecracker network gate"
    "- name: Firecracker boot-time gate"
    "- name: Firecracker shell gate"
    "- name: QEMU microvm gate"
    "- name: Enforce microVM gates"
] {
    if not ($workflow | str contains $needle) {
        fail $".github/workflows/smolfire.yml missing: ($needle)"
    }
}

print "microvm-primary-test: ok"
