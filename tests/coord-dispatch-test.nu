# SPDX-License-Identifier: Apache-2.0
# coord-dispatch-test.nu — billed-subprocess guard coverage for
# bin/coord-dispatch.nu's dispatch-claude / find-claude.
#
# Before this fix, dispatch-claude had NO test coverage at all: only
# dispatch-vm was exercised (tests/coord-vm-e2e-tests.nu). find-claude
# resolves a claude binary via three hard-coded absolute paths
# (/opt/homebrew/bin/claude, /usr/local/bin/claude, ~/.local/bin/claude),
# so stripping PATH in a test cannot intercept it — any future test that
# reached dispatch-claude on a host with a real claude CLI installed at one
# of those paths would launch and bill a real subagent via `job spawn`.
#
# These tests never touch the real absolute install paths (that would risk
# clobbering a real binary); instead they exercise the two independent
# guards added to dispatch-claude/find-claude:
#   1. SMOLFIRE_SPAWN_SUBAGENT=1 is required to launch anything at all
#      (default off).
#   2. SMOLFIRE_SUBAGENT_CMD overrides resolution so tests never need the
#      absolute-path probe to succeed.

use ../bin/coord-dispatch.nu [dispatch-subagent]

def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool] {
    if not $cond { error make {msg: "assert failed"} }
}

def make-temp-dir [] { ^mktemp -d | str trim }

print "test: dispatch-subagent (non-vm role) is a no-op by default — no billed subprocess"
do {
    let tmp = make-temp-dir
    let spool = [$tmp, "spool"] | path join
    "" | save --force $spool
    let jobs_before = (job list | length)

    # Deliberately do NOT set SMOLFIRE_SPAWN_SUBAGENT or SMOLFIRE_SUBAGENT_CMD.
    let result = with-env {} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        hide-env -i SMOLFIRE_SUBAGENT_CMD
        dispatch-subagent "t-builder" "builder" "task_id = \"t-builder\"" $spool
    }

    assert equal $result.launched false
    assert ($result.error | str contains "disabled by default")
    # No `job spawn` should ever have run — dispatch-claude must return
    # before calling find-claude / job spawn at all.
    assert equal (job list | length) $jobs_before

    ^rm -rf $tmp
}

print "test: SMOLFIRE_SUBAGENT_CMD lets dispatch-subagent launch a stub without touching the real absolute install-path probe"
do {
    let tmp = make-temp-dir
    let spool = [$tmp, "spool"] | path join
    "" | save --force $spool

    let stub = [$tmp, "fake-claude"] | path join
    let marker = [$tmp, "invoked.txt"] | path join
    $"#!/bin/sh\necho invoked >> ($marker)\nexit 0\n" | save --force $stub
    ^chmod +x $stub

    let result = with-env {SMOLFIRE_SPAWN_SUBAGENT: "1", SMOLFIRE_SUBAGENT_CMD: $stub} {
        dispatch-subagent "t-builder2" "builder" "task_id = \"t-builder2\"" $spool
    }

    assert equal $result.launched true

    # Poll briefly for the detached job to run the stub.
    mut found = false
    for _ in 1..20 {
        if ($marker | path exists) { $found = true; break }
        sleep 200ms
    }
    assert $found

    ^rm -rf $tmp
}

print "test: SMOLFIRE_SUBAGENT_CMD pointing at a nonexistent path is treated as CLI-not-found, not silently ignored"
do {
    let tmp = make-temp-dir
    let spool = [$tmp, "spool"] | path join
    "" | save --force $spool
    let missing = [$tmp, "does-not-exist"] | path join

    let result = with-env {SMOLFIRE_SPAWN_SUBAGENT: "1", SMOLFIRE_SUBAGENT_CMD: $missing} {
        dispatch-subagent "t-builder3" "builder" "task_id = \"t-builder3\"" $spool
    }

    assert equal $result.launched false
    assert ($result.error | str contains "claude CLI not found")

    ^rm -rf $tmp
}

print "all tests passed"
