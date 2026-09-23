# SPDX-License-Identifier: Apache-2.0
# spawn-subagent-test.nu — verifies that bin/coord-tick.nu auto-spawns the
# `claude` CLI on a dispatch transition. A stub `claude` script on PATH
# captures invocation args to a file so the test can assert on them.
#
# Flake history (ci/flaky-spawn-subagent, 2026-09): test 1 polls for a marker
# file written by a detached `sh -c "claude ... &"` stub. Under host
# contention (e.g. the immediately-preceding coord-tick-test.nu forking its
# own subprocesses in tests/run-all.sh's alphabetical roster), first exec of
# the freshly-written stub script can take several seconds longer than idle,
# so a short fixed poll window flakes intermittently under load without any
# actual content race. Fixes applied: (1) `assert` now takes an optional
# message so a failure names the specific assertion instead of always
# pointing at this file's shared `error make` call site; (2) the marker poll
# deadline is longer and tunable via SMOLFIRE_TEST_POLL_TIMEOUT_S so slow
# hosts/CI can raise it without touching the code; (3) each test's temp dir
# is cleaned up via try/catch even when an assertion fails, so a failing run
# doesn't leak tmp dirs. (PATH hermeticity for the claude stub itself is
# unchanged from the original prepend-based approach: prepending stub_dir
# already guarantees the stub shadows any real `claude` on PATH regardless
# of ordering, and was never implicated in the flake — see verification
# notes below.)
# Billed-subprocess guard: spawn-subagent is opt-in (SMOLFIRE_SPAWN_SUBAGENT
# must be "1") and OFF by default — see bin/coord-tick.nu. Tests 1 and 2
# below deliberately opt in with a harmless stub `claude` on PATH so they can
# still exercise the real spawn code path. Test 3 is the tripwire: it proves
# that with the guard left at its default (unset), coord-tick never resolves
# or executes a real `claude`/`codex` binary even when one is first on PATH.

# Drop every PATH directory that contains an executable named after a known
# billed-agent CLI. A naive `str contains "claude"` match on the directory
# NAME (the bug this guard replaces) leaves real install dirs such as
# /opt/homebrew/bin or ~/.local/bin untouched, since their names don't
# contain "claude" even though the binary lives inside them.
def strip-agent-bins [path: list<string>] {
    let agent_bins = [claude codex opencode ollama]
    $path | where {|dir| $agent_bins | all {|bin| not ($dir | path join $bin | path exists) } }
}

def "assert equal" [left: any, right: any, msg: string = ""] {
    if $left != $right {
        let detail = if ($msg | str length) > 0 { $" \(($msg)\)" } else { "" }
        error make {msg: $"assert equal failed($detail)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, msg: string = "assert failed"] {
    if not $cond { error make {msg: $msg} }
}

# Run a test body, guaranteeing $tmp is removed whether it passes or fails,
# and tagging any failure with the test name (helps `run-all.sh`'s
# one-line-per-file output point at the right test).
def run-test [name: string, tmp: string, body: closure] {
    try {
        do $body
    } catch {|err|
        ^rm -rf $tmp
        error make {msg: $"($name) failed: ($err.msg)"}
    }
    ^rm -rf $tmp
}

def make-temp-dir [] { ^mktemp -d | str trim }

def write-spool [path: string, content: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $content | save --force $path
}

def make-msg [from_addr: string, to_addr: string, message_id: string, body: string] {
    ([
        $"From ($from_addr) Wed Jan  1 00:00:00 2026"
        $"From: ($from_addr)"
        $"To: ($to_addr)"
        $"Message-ID: ($message_id)"
        "Content-Type: text/toml; charset=utf-8"
    ] | str join "\n") + "\n\n" + $body + "\n"
}

print "test: dispatch tick auto-spawns the claude CLI"
do {
    let tmp = make-temp-dir
    run-test "test 1 (dispatch tick auto-spawns the claude CLI)" $tmp {
        let state_rel = "var/run/coord-state.toml"
        let spool_rel = "var/mail/spool"
        let spool_abs = [$tmp, $spool_rel] | path join

        # Build a stub `claude` on PATH that records argv to a marker file.
        let stub_dir   = [$tmp, "stub-bin"] | path join
        let marker     = [$tmp, "claude-invoked.txt"] | path join
        mkdir $stub_dir
        let stub_path = [$stub_dir, "claude"] | path join
        let stub_body = $"#!/bin/sh
echo \"INVOKED $#\" >> ($marker)
for a in \"$@\"; do echo \"ARG: $a\" >> ($marker); done
exit 0
"
        $stub_body | save --force $stub_path
        ^chmod +x $stub_path

        # Seed an outbound request — this triggers idle → harvesting → dispatching.
        # Recipient local-part `builder` so derived agent_type = "builder".
        let body = "task_id = \"t-spawn\"\ncommand = \"echo hello\""
        let msg = make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<req.spawn.001@host>" $body
        write-spool $spool_abs $msg

        # Run tick with the stub dir prepended to PATH. SMOLFIRE_SPAWN_SUBAGENT=1
        # is required to opt into the (stubbed, harmless) spawn.
        with-env { PATH: ($env.PATH | prepend $stub_dir), SMOLFIRE_SPAWN_SUBAGENT: "1" } {
            ^nu bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $tmp | ignore
        }

        # Poll for the marker file (replaces fixed sleep 500ms). Default
        # window is 20s, well above the 9-13s worst case observed under a
        # loadavg ~250 spike (baseline: 6/30 standalone runs failed against a
        # 5s window). Tunable via SMOLFIRE_TEST_POLL_TIMEOUT_S for hosts that
        # need more headroom, e.g. in a saturated CI runner.
        let timeout_s = ($env | get SMOLFIRE_TEST_POLL_TIMEOUT_S? | default "20" | into int)
        let poll_ms   = 500
        let deadline  = ($timeout_s * 1000 / $poll_ms)
        mut found = false
        for _ in 1..$deadline {
            if ($marker | path exists) { $found = true; break }
            sleep 500ms
        }
        assert $found $"marker file not created within ($timeout_s)s \(SMOLFIRE_TEST_POLL_TIMEOUT_S\)"

        # Assertions.
        assert ($marker | path exists) "marker file vanished after being found"
        let recorded = open --raw $marker
        # Stub must have been invoked.
        assert ($recorded | str contains "INVOKED ") "stub claude was not invoked (no INVOKED line in marker)"
        # Assert model flag behavior: extract default from coord-tick.nu at runtime
        # rather than hard-coding "claude-sonnet-4-6" (breaks when default model bumps).
        let default_model = (
            open --raw "bin/coord-tick.nu"
            | lines
            | where {|l| ($l | str contains "default") and ($l | str contains "SMOLFIRE_CLAUDE_MODEL")}
            | first
            | parse --regex '\"([^"]+)\"$'
            | get capture0
            | first
        )
        assert ($recorded | str contains "--model") "recorded argv missing --model"
        assert ($recorded | str contains $default_model) $"recorded argv missing default model ($default_model)"
        assert ($recorded | str contains "--print") "recorded argv missing --print"
        assert ($recorded | str contains "--bare") "recorded argv missing --bare"
        assert ($recorded | str contains "--allowedTools") "recorded argv missing --allowedTools"
        assert ($recorded | str contains "--max-budget-usd") "recorded argv missing --max-budget-usd"
        # Prompt is now passed via stdin redirect, not as a CLI arg; task_id is
        # verified in the prompt file content checks below.

        # Spawn artifacts must have been written.
        let prompt_file = [$tmp, "var", "run", "spawned", "t-spawn.prompt.txt"] | path join
        assert ($prompt_file | path exists) "prompt file was not written"
        let prompt_text = open --raw $prompt_file
        assert ($prompt_text | str contains "builder") "prompt file missing agent_type 'builder'"
        assert ($prompt_text | str contains "t-spawn") "prompt file missing task_id 't-spawn'"
    }
}

print "test: missing claude CLI logs subagent_spawn_skipped, does not fail"
do {
    let tmp = make-temp-dir
    run-test "test 2 (missing claude CLI logs subagent_spawn_skipped)" $tmp {
        let state_rel = "var/run/coord-state.toml"
        let spool_rel = "var/mail/spool"
        let spool_abs = [$tmp, $spool_rel] | path join

        # PATH must keep `nu` reachable (for the spawned coord-tick.nu interpreter)
        # but must NOT resolve a `claude` binary. Filtering by directory-NAME
        # substring (the previous, buggy approach: `not ($p | str contains
        # "claude")`) leaves real install dirs like /opt/homebrew/bin untouched
        # since their PATH entry doesn't contain the string "claude" even though
        # a claude binary lives inside — so on any host with claude installed
        # this precondition always failed and the test silently skipped itself
        # without ever exercising the "missing CLI" code path. strip-agent-bins
        # checks actual binary existence per directory instead.
        let empty_dir = [$tmp, "no-claude-bin"] | path join
        mkdir $empty_dir
        # `nu` itself must stay reachable: strip-agent-bins can remove the
        # directory containing `nu` (e.g. /opt/homebrew/bin also holds
        # claude/codex/ollama on macOS dev hosts). Shadow it back via symlink.
        let nu_dir = [$tmp, "nu-bin"] | path join
        mkdir $nu_dir
        ^ln -sf (which nu | first | get path) ([$nu_dir, "nu"] | path join)
        let safe_path = (strip-agent-bins $env.PATH | prepend $empty_dir | prepend $nu_dir)

        let body = "task_id = \"t-no-claude\""
        let msg = make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<req.no-claude.001@host>" $body
        write-spool $spool_abs $msg

        # Confirm precondition: claude is NOT on the safe_path. If it is, skip this test.
        let claude_present_on_safe_path = (
            $safe_path | any {|d| ([$d, "claude"] | path join | path exists) }
        )
        if $claude_present_on_safe_path {
            print "  (skipped: claude binary still present after filtering)"
            # Explicit cleanup here too: `return` may unwind past run-test's
            # own trailing cleanup depending on closure scoping, so don't
            # rely on it alone.
            ^rm -rf $tmp
            return
        }

        # Opt in to spawning so we reach the CLI-resolution check rather than the
        # (also correct, but different) disabled-by-default short-circuit.
        let log_file = [$tmp, "tick.log"] | path join
        let exit_code = try {
            with-env { PATH: $safe_path, SMOLFIRE_SPAWN_SUBAGENT: "1" } {
                ^nu bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $tmp out> $log_file
            }
            0
        } catch { 1 }

        assert equal $exit_code 0 "coord-tick.nu exited non-zero when claude CLI is absent"
        let log_text = open --raw $log_file
        assert ($log_text | str contains "subagent_spawn_skipped") "missing subagent_spawn_skipped event in log"
        assert ($log_text | str contains "claude CLI not installed") "missing 'claude CLI not installed' reason in log"
    }
}

print "test: spawn disabled by default is a billed-subprocess tripwire — a real claude/codex binary is never executed even when first on PATH"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Stub `claude` AND `codex` that would prove they ran by writing a marker
    # and exiting 99 — a distinctive, never-legitimate exit code. If the
    # billed-subprocess guard regresses (e.g. the SMOLFIRE_SPAWN_SUBAGENT
    # check is removed or bypassed), one of these gets exec'd and this test
    # catches it even though nothing here strips PATH.
    let stub_dir = [$tmp, "stub-bin"] | path join
    let marker   = [$tmp, "billed-subprocess-marker.txt"] | path join
    mkdir $stub_dir
    for bin in [claude codex] {
        let stub_path = [$stub_dir, $bin] | path join
        $"#!/bin/sh\necho \"($bin) EXECUTED\" >> ($marker)\nexit 99\n" | save --force $stub_path
        ^chmod +x $stub_path
    }

    let body = "task_id = \"t-tripwire\"\ncommand = \"echo hello\""
    let msg = make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<req.tripwire.001@host>" $body
    write-spool $spool_abs $msg

    # Deliberately do NOT set SMOLFIRE_SPAWN_SUBAGENT — the default-off gate
    # is the thing under test. The stub dir is prepended so it would be the
    # FIRST match if coord-tick ever fell back to resolving off PATH.
    let log_file = [$tmp, "tick.log"] | path join
    with-env { PATH: ($env.PATH | prepend $stub_dir) } {
        ^nu bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $tmp out> $log_file
    }

    if ($marker | path exists) {
        error make {msg: $"billed-subprocess guard regressed: ($marker) was created — a stub CLI was executed with spawning left at its default \(disabled\) setting"}
    }
    let log_text = open --raw $log_file
    assert ($log_text | str contains "subagent_spawn_skipped")
    assert ($log_text | str contains "disabled by default")

    ^rm -rf $tmp
}

print "all tests passed"
