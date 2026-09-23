#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/smolfire-current-lane-test.nu — smoke-test the 16-CURRENT workflow wiring.

let lane = (open --raw .github/workflows/smolfire-current.yml)
let lane_yaml = (open .github/workflows/smolfire-current.yml)
let stable = (open --raw .github/workflows/smolfire.yml)
let build = (open --raw bin/build-smolfire.sh)
let current_job = ($lane_yaml.jobs | get "smolfire-current")
let step_names = ($current_job.steps | each {|step| $step.name? | default "" })

let require = {|text: string, needle: string, label: string|
    if not ($text | str contains $needle) {
        print $"smolfire-current-lane-test: FAIL — missing ($label): ($needle)"
        exit 1
    }
}

let forbid = {|text: string, needle: string, label: string|
    if ($text | str contains $needle) {
        print $"smolfire-current-lane-test: FAIL — unexpected ($label): ($needle)"
        exit 1
    }
}

do $require $lane "name: SMOLFIRE FreeBSD 16-CURRENT compatibility" "workflow name"
do $require $lane "schedule:" "scheduled trigger"
do $require $lane "workflow_dispatch:" "manual trigger"
do $require ($lane_yaml | get name) "SMOLFIRE FreeBSD 16-CURRENT compatibility" "parsed workflow name"
do $require ($current_job | get name) "Build + dual-VMM boot gate (FreeBSD main)" "parsed job name"
do $require ($lane_yaml.permissions | get contents) "read" "parsed workflow permissions"
do $require $lane "SRC_BRANCH: main" "FreeBSD main source branch"
do $require $lane "snapshots/VM-IMAGES/main/amd64/Latest" "main snapshot base image"
do $require $lane "env SMOLFIRE_TSLOG=1 sh /root/smolfire/bin/build-smolfire.sh" "always-on TSLOG build"
do $require $lane "### Size report" "size report summary"
do $require $lane "SMOLFIRE_NET_OK '" "token gate"
do $require $lane "-device virtio-net-device,netdev=n0" "QEMU microvm virtio-mmio network"
do $require $lane "QEMU_MICROVM=pass" "required QEMU gate"
do $require $lane "FIRECRACKER=pass" "required Firecracker gate"
do $require $lane "Fail on gate regressions" "explicit gate failure step"
do $require $lane "http://127.0.0.1:8080/" "host-side token-server preflight"
for expected in [
    "Build SMOLFIRE + TSLOG kernels inside VM"
    "Boot gate — Firecracker (required)"
    "Boot gate — QEMU microvm (required)"
    "Compatibility summary"
    "Fail on gate regressions"
] {
    if ($step_names | where {|name| $name == $expected } | is-empty) {
        print $"smolfire-current-lane-test: FAIL — missing parsed step: ($expected)"
        exit 1
    }
}

do $require $stable "SRC_BRANCH: releng/15.0" "unchanged FreeBSD 15 lane"
do $require $build "pv.c already carries non-Xen early hooks; skipping local patch" "superseded upstream classification"
do $require $build "pv.c only partially moved away from Xen early hooks" "ambiguous upstream classification"

print "smolfire-current-lane-test: ok"
