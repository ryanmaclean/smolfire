# SPDX-License-Identifier: Apache-2.0
# run-vm-tests.nu — master VM test orchestrator for smolfire
#
# Launches a smolfire image under qemu or bhyve, runs the full acceptance test
# suite, and writes a structured TOML result file.
#
# Usage (QEMU — default, works on <hypervisor-host> with HVF today):
#   nu bin/run-vm-tests.nu --image smolfire.qcow2
#   nu bin/run-vm-tests.nu --image smolfire.qcow2 --tpm
#   nu bin/run-vm-tests.nu --image smolfire.qcow2 --arch arm64
#
# Usage (bhyve — production FreeBSD bare-metal amd64 host):
#   nu bin/run-vm-tests.nu --image smolfire.raw --backend bhyve
#   nu bin/run-vm-tests.nu --image smolfire.raw --backend bhyve --tpm
#
# Skipping individual steps:
#   nu bin/run-vm-tests.nu --image smolfire.qcow2 --skip ["tpm","crash-recovery"]
#
# Prerequisites (qemu backend):
#   qemu-system-aarch64 / qemu-system-x86_64  — emulators/qemu port
#   swtpm                                      — security/swtpm port (only if --tpm)
#   expect                                     — lang/expect port
#   qemu-img                                   — emulators/qemu-utils
#
# Prerequisites (bhyve backend):
#   bhyve(8), bhyvectl(8)  — base system
#   swtpm                  — security/swtpm port (only if --tpm)
#   expect                 — lang/expect port
#   qemu-img               — emulators/qemu-utils
#   nmdm(4)                — null-modem device (kldload nmdm)
#
# All test steps run in order.  A step failure marks the step "fail" and
# continues — no early abort.  Overall is "fail" if any step failed or errored.

# ── Logging ────────────────────────────────────────────────────────────────────

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── Timing helper ──────────────────────────────────────────────────────────────

# Return current time as a datetime value (used for duration arithmetic).
def now-dt [] { date now }

# Compute elapsed milliseconds between two datetime values.
def elapsed-ms [t0: datetime, t1: datetime] {
    let diff = $t1 - $t0
    # diff is a duration; convert to ms via seconds
    ($diff / 1ms) | into int
}

# ── Result builder ─────────────────────────────────────────────────────────────

# Build a single test result record.
def make-result [
    name: string
    result: string        # "pass" | "fail" | "skip" | "error"
    duration_ms: int
    detail: string
] {
    {name: $name, result: $result, duration_ms: $duration_ms, detail: $detail}
}

# ── Step runner ────────────────────────────────────────────────────────────────

# Run a closure as a test step.  Returns a result record.
# Never throws — catches errors and marks them as "error".
def run-step [
    name: string
    skip_list: list<string>
    closure: closure
] {
    if ($name in $skip_list) {
        log-step $name "skipped (in --skip list)" {result: "skip"}
        return (make-result $name "skip" 0 "skipped by --skip flag")
    }

    log-step $name "starting" {}
    let t0 = now-dt

    let outcome = try {
        let detail = do $closure
        {result: "pass", detail: ($detail | into string)}
    } catch {|err|
        {result: "fail", detail: ($err | get msg? | default "unknown error")}
    }

    let t1  = now-dt
    let dur = elapsed-ms $t0 $t1

    log-step $name $"done: ($outcome.result)" {
        result:      $outcome.result
        duration_ms: $dur
        detail:      $outcome.detail
    }

    make-result $name $outcome.result $dur $outcome.detail
}

# ── Individual test steps ──────────────────────────────────────────────────────

# step-preflight: verify all required binaries and paths exist.
# Checks differ by backend: qemu needs qemu-system-*, bhyve needs bhyve/bhyvectl.
# qemu-img and expect are required by both.
def step-preflight [
    image:   string
    use_tpm: bool
    backend: string   # "qemu" | "bhyve"
    arch:    string   # "amd64" | "arm64"
] {
    if not ($image | path exists) {
        error make {msg: $"image not found: ($image)"}
    }

    # Shared requirements regardless of backend.
    for bin in ["expect", "qemu-img"] {
        let found = (^which $bin | complete)
        if $found.exit_code != 0 {
            error make {msg: $"required binary not found: ($bin)"}
        }
    }

    if $backend == "qemu" {
        # Select the right qemu binary for the target arch.
        let qemu_bin = if $arch == "arm64" { "qemu-system-aarch64" } else { "qemu-system-x86_64" }
        let found = (^which $qemu_bin | complete)
        if $found.exit_code != 0 {
            error make {msg: $"required binary not found: ($qemu_bin) — install emulators/qemu"}
        }
    } else {
        # bhyve backend
        for bin in ["bhyve", "bhyvectl"] {
            let found = (^which $bin | complete)
            if $found.exit_code != 0 {
                error make {msg: $"required binary not found: ($bin)"}
            }
        }
        # nmdm is bhyve-specific; warn if module not loaded (bhyve will fail later).
        let kldstat_out = (^kldstat | complete)
        if $kldstat_out.exit_code == 0 {
            if not ($kldstat_out.stdout | str contains "nmdm") {
                log-step "preflight" "WARNING: nmdm kernel module not loaded — run: kldload nmdm" {}
            }
        }
    }

    if $use_tpm {
        let found = (^which swtpm | complete)
        if $found.exit_code != 0 {
            error make {msg: "swtpm binary not found; install security/swtpm"}
        }
    }

    $"all preflight checks passed (backend: ($backend), arch: ($arch))"
}

# step-swtpm-start: start swtpm via swtpm-setup.nu and verify socket.
def step-swtpm-start [tpm_state: string] {
    let result = (^nu bin/swtpm-setup.nu --action start --state-dir $tpm_state | complete)
    if $result.exit_code != 0 {
        error make {msg: $"swtpm start failed: ($result.stderr | str trim)"}
    }

    # Verify socket appeared (swtpm-setup.nu already polls, but confirm here)
    let sock = $"($tpm_state)/swtpm.sock"
    if not ($sock | path exists) {
        error make {msg: $"swtpm socket not present at ($sock) after start"}
    }

    $"swtpm running; socket: ($sock)"
}

# step-launch: launch the VM (qemu or bhyve) in a background job.
# Returns a detail string including the job id.
# Teardown uses the job tag "vm-<vm_name>" to find and kill the job.
def step-launch [
    image:       string
    vm_name:     string
    hostfwd_ssh: int
    console:     string
    use_tpm:     bool
    tpm_state:   string
    arch:        string
    backend:     string   # "qemu" | "bhyve"
] {
    # Build the final immutable args list before spawning.
    # (Closures cannot capture mutable variables.)
    let args = if $backend == "qemu" {
        # qemu-smolfire-vm.nu flags
        let base = [
            "--image"       $image
            "--arch"        $arch
            "--hostfwd-ssh" ($hostfwd_ssh | into string)
            "--console"     $console
        ]
        if $use_tpm {
            $base | append ["--tpm" "--tpm-state" $tpm_state]
        } else {
            $base
        }
    } else {
        # bhyve-smolfire-vm.nu flags — destroy any stale VM first (synchronous)
        ^bhyvectl --destroy $"--vm=($vm_name)" out+err> /dev/null
        let base = [
            "--image"       $image
            "--arch"        $arch
            "--name"        $vm_name
            "--console"     $console
            "--hostfwd-ssh" ($hostfwd_ssh | into string)
        ]
        if $use_tpm {
            $base | append ["--tpm" "--tpm-state" $tpm_state]
        } else {
            $base
        }
    }

    let script = if $backend == "qemu" { "bin/qemu-smolfire-vm.nu" } else { "bin/bhyve-smolfire-vm.nu" }

    let job_id = job spawn --tag $"vm-($vm_name)" {
        ^nu $script ...$args
    }

    log-step "vm-launch" $"($backend) background job started" {
        backend: $backend
        job_id:  $job_id
        vm:      $vm_name
        arch:    $arch
    }

    # Brief pause to let the VM initialise before we start probing.
    ^sleep 2

    $"($backend) launched; job_id=($job_id)"
}

# step-boot-gate: run the appropriate boot-gate expect script.
# Backend "qemu" spawns QEMU directly via time-to-ready-qemu.exp (stdio).
# Backend "bhyve" attaches to nmdm console via time-to-ready-bhyve.exp.
# Returns elapsed seconds as a string; fails if > threshold or script absent.
def step-boot-gate [console: string, timeout_sec: int, backend: string, qemu_cmd: string, arch: string] {
    if $backend == "qemu" {
        # ── QEMU path: spawn the VM inside the expect script ──────────────────
        let script = "tests/time-to-ready-qemu.exp"
        if not ($script | path exists) {
            error make {msg: $"($script) not found"}
        }

        # Threshold: 30s for arm64 HVF, 120s for amd64 TCG.
        let time_limit = if $arch == "arm64" { "30" } else { "120" }

        let result = (with-env {
            SMOLFIRE_QEMU_CMD: $qemu_cmd
            SMOLFIRE_TIME_LIMIT: $time_limit
            SMOLFIRE_ARCH: $arch
        } {
            ^expect $script | complete
        })

        # exit 2 = hard failure (panic/mountroot/UEFI shell) — surface as error
        if $result.exit_code == 2 {
            let reason = ($result.stdout | lines | where {|l| $l | str contains "FAILURE_REASON"} | first | default "unknown")
            error make {msg: $"boot-gate hard failure: ($reason)"}
        }
        if $result.exit_code != 0 {
            error make {msg: $"boot-gate expect script failed (exit ($result.exit_code)): ($result.stdout | str trim)"}
        }

        let ttl_lines = $result.stdout | lines | where {|l| $l | str contains "TIME_TO_LOGIN"}
        let ttl_secs = if ($ttl_lines | length) > 0 {
            let parsed = $ttl_lines | first | parse "TIME_TO_LOGIN={n}s"
            if ($parsed | length) > 0 { $parsed | get n | first | into int } else { 999 }
        } else { 999 }

        let threshold = $time_limit | into int
        if $ttl_secs > $threshold {
            error make {msg: $"boot gate failed: TIME_TO_LOGIN=($ttl_secs)s > ($threshold)s threshold"}
        }

        $"TIME_TO_LOGIN=($ttl_secs)s (threshold ($threshold)s, arch ($arch))"

    } else {
        # ── bhyve path: attach to nmdm console via cu ─────────────────────────
        let script = "tests/time-to-ready-bhyve.exp"
        if not ($script | path exists) {
            error make {msg: $"($script) not found — create this expect script (see tests/time-to-ready.exp for reference)"}
        }

        let b_side = $console | str replace --regex "A$" "B"
        let result = (with-env {SMOLFIRE_CONSOLE: $b_side} {
            ^expect $script | complete
        })

        if $result.exit_code != 0 {
            error make {msg: $"boot-gate expect script failed (exit ($result.exit_code)): ($result.stderr | str trim)"}
        }

        let ttl_lines = $result.stdout | lines | where {|l| $l | str contains "TIME_TO_LOGIN"}
        let ttl_secs = if ($ttl_lines | length) > 0 {
            let parsed = $ttl_lines | first | parse "TIME_TO_LOGIN={n}s"
            if ($parsed | length) > 0 { $parsed | get n | first | into int } else { 999 }
        } else { 999 }

        if $ttl_secs > 60 {
            error make {msg: $"boot gate failed: TIME_TO_LOGIN=($ttl_secs)s > 60s threshold"}
        }

        $"TIME_TO_LOGIN=($ttl_secs)s (threshold 60s)"
    }
}

# step-memory: SSH into guest, compute free MiB from sysctl output.
def step-memory [hostfwd_ssh: int] {
    let result = (^ssh
        "-o" "StrictHostKeyChecking=no"
        "-o" "UserKnownHostsFile=/dev/null"
        "-o" $"ConnectTimeout=10"
        "-p" ($hostfwd_ssh | into string)
        "root@127.0.0.1"
        "sysctl -n vm.stats.vm.v_free_count vm.stats.vm.v_page_size"
        | complete)

    if $result.exit_code != 0 {
        error make {msg: $"SSH memory check failed: ($result.stderr | str trim)"}
    }

    let lines = $result.stdout | lines | where {|l| ($l | str trim | str length) > 0}
    if ($lines | length) < 2 {
        error make {msg: $"unexpected sysctl output: ($result.stdout)"}
    }

    let free_pages = $lines | get 0 | str trim | into int
    let page_size  = $lines | get 1 | str trim | into int
    let free_mib   = ($free_pages * $page_size) / 1048576

    if $free_mib < 150 {
        error make {msg: $"memory check failed: free=($free_mib) MiB < 150 MiB threshold"}
    }

    $"free=($free_mib) MiB (threshold 150 MiB)"
}

# step-artifact-size: use qemu-img info to get the actual on-disk image size.
def step-artifact-size [image: string] {
    let result = (^qemu-img info "--output=json" $image | complete)
    if $result.exit_code != 0 {
        error make {msg: $"qemu-img info failed: ($result.stderr | str trim)"}
    }

    let info = $result.stdout | from json
    # qemu-img JSON output uses "actual-size" for bytes actually used.
    let actual = $info | get "actual-size"? | default ($info | get "virtual-size"? | default 0)
    let limit  = 536870912  # 512 MiB

    if $actual >= $limit {
        error make {msg: $"artifact-size check failed: ($actual) bytes >= ($limit) bytes limit"}
    }

    let mib = ($actual / 1048576 | into string) + " MiB"
    $"actual-size=($actual) bytes, ($mib), limit 512 MiB"
}

# step-tpm-device: run tpm-attest.exp; pass if exit 0.
def step-tpm-device [console: string] {
    let script = "tests/tpm-attest.exp"
    if not ($script | path exists) {
        error make {msg: $"($script) not found"}
    }

    let b_side = $console | str replace --regex "A$" "B"
    let result = (with-env {SMOLFIRE_CONSOLE: $b_side} {
        ^expect $script | complete
    })

    if $result.exit_code != 0 {
        error make {msg: $"tpm-attest.exp failed (exit ($result.exit_code))"}
    }

    "TPM device present and responsive (tpm-attest.exp passed)"
}

# step-tpm-seal: run tpm-seal-test.nu --dry-run; pass if exit 0.
def step-tpm-seal [] {
    let script = "tests/tpm-seal-test.nu"
    if not ($script | path exists) {
        error make {msg: $"($script) not found"}
    }

    let result = (^nu $script --dry-run | complete)
    if $result.exit_code != 0 {
        error make {msg: $"tpm-seal-test.nu --dry-run failed (exit ($result.exit_code))"}
    }

    "TPM seal/unseal dry-run passed"
}

# step-crash-recovery: run the appropriate crash-recovery expect script.
# Backend "qemu" uses crash-recovery-qemu.exp (spawns QEMU, graceful shutdown,
#   relaunches, measures recovery time).
# Backend "bhyve" uses bhyve-crash-recovery.exp (SIGKILL + nmdm reattach).
# Acceptance: RECOVERY_TIME (qemu) or CRASH_RECOVERY_TIME (bhyve) <= 90s.
def step-crash-recovery [console: string, timeout_sec: int, backend: string, qemu_cmd: string, arch: string] {
    if $backend == "qemu" {
        # ── QEMU path: graceful shutdown then recovery boot ────────────────────
        let script = "tests/crash-recovery-qemu.exp"
        if not ($script | path exists) {
            error make {msg: $"($script) not found"}
        }

        let boot_limit    = if $arch == "arm64" { "30" } else { "120" }
        let recovery_limit = "90"

        let result = (with-env {
            SMOLFIRE_QEMU_CMD: $qemu_cmd
            SMOLFIRE_TIME_LIMIT: $boot_limit
            SMOLFIRE_RECOVERY_LIMIT: $recovery_limit
            SMOLFIRE_ARCH: $arch
        } {
            ^expect $script | complete
        })

        # exit 2 = hard failure, exit 3 = initial boot failed
        if $result.exit_code == 2 {
            let reason = ($result.stdout | lines | where {|l| $l | str contains "FAILURE_REASON"} | first | default "unknown")
            error make {msg: $"crash-recovery hard failure: ($reason)"}
        }
        if $result.exit_code == 3 {
            error make {msg: "crash-recovery: initial boot failed — recovery not attempted"}
        }
        if $result.exit_code != 0 {
            error make {msg: $"crash-recovery-qemu.exp failed (exit ($result.exit_code)): ($result.stdout | str trim)"}
        }

        let crt_lines = $result.stdout | lines | where {|l| $l | str contains "RECOVERY_TIME"}
        let crt_secs = if ($crt_lines | length) > 0 {
            let parsed = $crt_lines | first | parse "RECOVERY_TIME={n}s"
            if ($parsed | length) > 0 { $parsed | get n | first | into int } else { 999 }
        } else { 999 }

        if $crt_secs > 90 {
            error make {msg: $"crash-recovery failed: RECOVERY_TIME=($crt_secs)s > 90s threshold"}
        }

        $"RECOVERY_TIME=($crt_secs)s (threshold 90s, arch ($arch))"

    } else {
        # ── bhyve path: SIGKILL VM, relaunch, measure via nmdm ────────────────
        let script = "tests/bhyve-crash-recovery.exp"
        if not ($script | path exists) {
            error make {msg: $"($script) not found — create this expect script for crash-recovery gate"}
        }

        let b_side = $console | str replace --regex "A$" "B"
        let result = (with-env {SMOLFIRE_CONSOLE: $b_side, TIMEOUT: ($timeout_sec | into string)} {
            ^expect $script | complete
        })

        if $result.exit_code != 0 {
            error make {msg: $"crash-recovery expect script failed (exit ($result.exit_code))"}
        }

        let crt_lines = $result.stdout | lines | where {|l| $l | str contains "CRASH_RECOVERY_TIME"}
        let crt_secs = if ($crt_lines | length) > 0 {
            let parsed = $crt_lines | first | parse "CRASH_RECOVERY_TIME={n}s"
            if ($parsed | length) > 0 { $parsed | get n | first | into int } else { 999 }
        } else { 999 }

        if $crt_secs > 90 {
            error make {msg: $"crash-recovery failed: CRASH_RECOVERY_TIME=($crt_secs)s > 90s threshold"}
        }

        $"CRASH_RECOVERY_TIME=($crt_secs)s (threshold 90s)"
    }
}

# step-teardown: stop the VM and optionally stop swtpm; best-effort.
# Returns a joined detail string regardless of partial failures.
def step-teardown [vm_name: string, use_tpm: bool, tpm_state: string, backend: string] {
    mut notes: list<string> = []

    if $backend == "bhyve" {
        # bhyve: destroy by VM name via bhyvectl.
        let destroy = (^bhyvectl --destroy $"--vm=($vm_name)" | complete)
        if $destroy.exit_code == 0 {
            $notes = $notes | append "bhyve VM destroyed"
        } else {
            $notes = $notes | append $"bhyvectl destroy: ($destroy.stderr | str trim)"
        }
    } else {
        # qemu: kill by process name pattern; qemu-smolfire-vm.nu sets -name $vm_name.
        let pkill_r = (^pkill -f $"qemu-system.*($vm_name)" | complete)
        if $pkill_r.exit_code == 0 {
            $notes = $notes | append $"qemu process killed (name: ($vm_name))"
        } else {
            # exit 1 from pkill means no matching process — not an error.
            $notes = $notes | append "qemu: no matching process found (already exited?)"
        }
    }

    # Kill the background Nu job by tag "vm-<vm_name>" (best-effort, both backends).
    let vm_jobs = job list | where {|j| ($j.tag | default "") | str contains $"vm-($vm_name)"}
    for j in $vm_jobs {
        job kill ($j.id)
        $notes = $notes | append $"killed background job id=($j.id)"
    }

    # Stop swtpm if it was started (both backends).
    if $use_tpm {
        let stop = (^nu bin/swtpm-setup.nu --action stop --state-dir $tpm_state | complete)
        if $stop.exit_code == 0 {
            $notes = $notes | append "swtpm stopped"
        } else {
            $notes = $notes | append $"swtpm stop: ($stop.stderr | str trim)"
        }
    }

    $notes | str join "; "
}

# ── Summary printer ────────────────────────────────────────────────────────────

def print-summary [tests: list<record>, overall: string] {
    print ""
    print "┌─────────────────────────────────────────────────────────────────┐"
    print "│  smolfire VM Test Results                                        │"
    print "├──────────────────────┬──────────┬──────────────┬────────────────┤"
    print "│ Test                 │ Result   │ Duration     │ Detail         │"
    print "├──────────────────────┼──────────┼──────────────┼────────────────┤"

    for t in $tests {
        let sym = match $t.result {
            "pass"  => "✓ pass"
            "fail"  => "✗ fail"
            "error" => "! error"
            "skip"  => "- skip"
            _       => "? unknown"
        }
        let dur  = if $t.duration_ms > 0 { $"($t.duration_ms)ms" } else { "—" }
        let det  = $t.detail | str substring 0..30
        print $"│ ($t.name | fill -w 20) │ ($sym | fill -w 8) │ ($dur | fill -w 12) │ ($det | fill -w 14) │"
    }

    print "├──────────────────────┴──────────┴──────────────┴────────────────┤"
    let overall_display = if $overall == "pass" { "OVERALL: PASS ✓" } else { "OVERALL: FAIL ✗" }
    print $"│  ($overall_display | fill -w 63)│"
    print "└─────────────────────────────────────────────────────────────────┘"
    print ""
}

# ── Entry point ────────────────────────────────────────────────────────────────

# Run the full smolfire VM test suite against a qemu or bhyve hosted image.
#
# --image          path to smolfire qcow2 or raw image (required)
# --backend        qemu (default) | bhyve
# --arch           amd64 (default) | arm64
# --tpm            enable swtpm TPM attachment (amd64 only)
# --tpm-state      swtpm state directory
# --vm-name        VM instance name
# --hostfwd-ssh    host port forwarded to guest SSH
# --console        serial console device (nmdm for bhyve/amd64; stdio or nmdm for qemu)
# --skip           list of test names to skip, e.g. ["tpm","crash-recovery"]
# --timeout        global timeout in seconds (currently advisory)
# --results-file   path to write TOML results
export def main [
    --image:        string                                  # path to smolfire qcow2 or raw image
    --backend:      string = "qemu"                         # qemu | bhyve
    --arch:         string = "amd64"                        # amd64 | arm64
    --tpm                                                   # enable swtpm TPM attachment (amd64 only)
    --tpm-state:    string = "/var/run/smolfire-tpm-test"
    --vm-name:      string = "smolfire-test"
    --hostfwd-ssh:  int    = 2240
    --console:      string = "/dev/nmdm0A"
    --skip:         list<string> = []
    --timeout:      int    = 300
    --results-file: string = "/tmp/smolfire-vm-test-results.toml"
] {
    if $image == null or $image == "" {
        error make {msg: "--image is required (path to smolfire qcow2 or raw image)"}
    }

    if $backend != "qemu" and $backend != "bhyve" {
        error make {msg: $"--backend must be qemu or bhyve, got: ($backend)"}
    }

    let arch = if $arch == "aarch64" { "arm64" } else { $arch }

    let started_at = date now | format date "%Y-%m-%dT%H:%M:%SZ"

    # ── Pre-compute the QEMU command string for expect scripts ────────────────
    # When backend=qemu the boot-gate and crash-recovery expect scripts spawn
    # QEMU directly.  We reconstruct the command string here so it is available
    # before step-launch runs (the expect scripts start their own QEMU process
    # independently — they don't attach to the one started by step-launch).
    #
    # The string is passed to expect scripts via SMOLFIRE_QEMU_CMD env var.
    # It must include -serial stdio and -nographic so the expect script can
    # read boot output from stdin/stdout.
    let qemu_cmd_str = if $backend == "qemu" {
        let norm_arch = if $arch == "arm64" { "aarch64" } else { $arch }
        let qemu_bin  = if $norm_arch == "aarch64" { "qemu-system-aarch64" } else { "qemu-system-x86_64" }
        # Resolve BIOS path — same candidate list as qemu-smolfire-vm.nu find-bios.
        let bios_candidates = if $norm_arch == "aarch64" {
            ["/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
             "/usr/local/share/qemu/edk2-aarch64-code.fd"
             "/usr/share/qemu/QEMU_EFI.fd"
             "/usr/share/qemu/edk2-aarch64-code.fd"
             "/usr/share/AAVMF/AAVMF_CODE.fd"]
        } else {
            ["/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
             "/usr/local/share/qemu/edk2-x86_64-code.fd"
             "/usr/share/qemu/OVMF.fd"
             "/usr/share/qemu/edk2-x86_64-code.fd"
             "/usr/share/OVMF/OVMF_CODE.fd"]
        }
        let bios = ($bios_candidates | where {|p| $p | path exists} | first | default "")
        # Detect accelerator the same way qemu-smolfire-vm.nu detect-accel does.
        let accel = do {
            let hv_r = (^sysctl kern.hv_support | complete)
            if $hv_r.exit_code == 0 {
                let val = $hv_r.stdout | str trim | split row ":" | last | str trim
                if $val == "1" { "hvf" } else if ("/dev/kvm" | path exists) { "kvm" } else { "tcg" }
            } else if ("/dev/kvm" | path exists) {
                "kvm"
            } else {
                "tcg"
            }
        }
        let img_fmt = if ($image | str ends-with ".qcow2") { "qcow2" } else { "raw" }
        let cpu = if $accel == "hvf" or $accel == "kvm" {
            "host"
        } else if $norm_arch == "aarch64" {
            "cortex-a72"
        } else {
            "qemu64"
        }
        # aarch64: -machine virt,accel=<accel>  (accel embedded in machine flag)
        # amd64:   -M q35 -accel <accel>         (matches qemu-smolfire-vm.nu build-cmd-amd64)
        mut parts = if $norm_arch == "aarch64" {
            [$qemu_bin "-machine" $"virt,accel=($accel)" "-cpu" $cpu]
        } else {
            [$qemu_bin "-M" "q35" "-accel" $accel "-cpu" $cpu]
        }
        if ($bios | str length) > 0 {
            $parts = $parts | append ["-bios" $bios]
        }
        $parts = $parts | append [
            "-m" "256M" "-smp" "2"
            "-drive" $"file=($image),format=($img_fmt),if=virtio"
            "-nic"   $"user,model=virtio-net-pci,hostfwd=tcp::($hostfwd_ssh)-:22"
            "-serial" "stdio" "-nographic"
        ]
        # aarch64 + HVF: skip EDK2's ~5 s boot-menu wait — same rule as
        # qemu-smolfire-vm.nu fw-boot-menu-args (docs/BOOT-TIME-ROADMAP.md §1).
        if $norm_arch == "aarch64" and $accel == "hvf" {
            $parts = $parts | append ["-boot" "menu=on,splash-time=0"]
        }
        $parts | str join " "
    } else {
        ""   # bhyve path does not use SMOLFIRE_QEMU_CMD
    }

    log-step "orchestrator" "run-vm-tests starting" {
        image:        $image
        backend:      $backend
        arch:         $arch
        vm_name:      $vm_name
        tpm:          $tpm
        hostfwd_ssh:  $hostfwd_ssh
        console:      $console
        skip:         ($skip | str join ",")
        timeout:      $timeout
        results_file: $results_file
        qemu_cmd_str: $qemu_cmd_str
    }

    mut results: list<record> = []

    # ── 1. preflight ──────────────────────────────────────────────────────────
    $results = $results | append (run-step "preflight" $skip {
        step-preflight $image $tpm $backend $arch
    })

    # Abort only on preflight failure — nothing useful can run without it.
    let pf = $results | last
    if $pf.result == "fail" or $pf.result == "error" {
        log-step "orchestrator" "preflight failed — aborting run" {detail: $pf.detail}
        let overall = "fail"
        let report  = {
            vm_name:    $vm_name
            image:      $image
            timestamp:  $started_at
            tests:      $results
            overall:    $overall
        }
        $report | to toml | save --force $results_file
        print-summary $results $overall
        exit 1
    }

    # ── 2. swtpm-start (conditional) ──────────────────────────────────────────
    if $tpm {
        $results = $results | append (run-step "swtpm-start" $skip {
            step-swtpm-start $tpm_state
        })
    } else {
        $results = $results | append (make-result "swtpm-start" "skip" 0 "--tpm not set")
    }

    # ── 3. vm-launch ─────────────────────────────────────────────────────────
    $results = $results | append (run-step "vm-launch" $skip {
        step-launch $image $vm_name $hostfwd_ssh $console $tpm $tpm_state $arch $backend
    })

    # ── 4. boot-gate ─────────────────────────────────────────────────────────
    # qemu backend: spawns QEMU via time-to-ready-qemu.exp (stdio, all arches).
    # bhyve backend: attaches to nmdm via time-to-ready-bhyve.exp.
    #   Skip only for arm64 bhyve (bhyve arm64 uses stdio, not nmdm).
    if $arch == "arm64" and $backend == "bhyve" {
        $results = $results | append (make-result "boot-gate" "skip" 0 "arm64 bhyve uses stdio, not nmdm")
    } else {
        $results = $results | append (run-step "boot-gate" $skip {
            step-boot-gate $console $timeout $backend $qemu_cmd_str $arch
        })
    }

    # ── 5. memory ─────────────────────────────────────────────────────────────
    $results = $results | append (run-step "memory" $skip {
        step-memory $hostfwd_ssh
    })

    # ── 6. artifact-size ──────────────────────────────────────────────────────
    $results = $results | append (run-step "artifact-size" $skip {
        step-artifact-size $image
    })

    # ── 7. tpm-device (conditional) ───────────────────────────────────────────
    if $tpm {
        $results = $results | append (run-step "tpm-device" $skip {
            step-tpm-device $console
        })
    } else {
        $results = $results | append (make-result "tpm-device" "skip" 0 "--tpm not set")
    }

    # ── 8. tpm-seal (conditional) ─────────────────────────────────────────────
    if $tpm {
        $results = $results | append (run-step "tpm-seal" $skip {
            step-tpm-seal
        })
    } else {
        $results = $results | append (make-result "tpm-seal" "skip" 0 "--tpm not set")
    }

    # ── 9. crash-recovery ─────────────────────────────────────────────────────
    # qemu backend: graceful shutdown + recovery via crash-recovery-qemu.exp.
    # bhyve backend: SIGKILL + nmdm reattach via bhyve-crash-recovery.exp.
    #   Skip only for arm64 bhyve (same stdio-vs-nmdm reason as boot-gate).
    if $arch == "arm64" and $backend == "bhyve" {
        $results = $results | append (make-result "crash-recovery" "skip" 0 "arm64 bhyve uses stdio, not nmdm")
    } else {
        $results = $results | append (run-step "crash-recovery" $skip {
            step-crash-recovery $console $timeout $backend $qemu_cmd_str $arch
        })
    }

    # ── 10. teardown (always runs) ────────────────────────────────────────────
    $results = $results | append (run-step "teardown" [] {
        step-teardown $vm_name $tpm $tpm_state $backend
    })

    # ── Compute overall ───────────────────────────────────────────────────────
    let non_skip = $results | where {|r| $r.result != "skip"}
    let failed   = $non_skip | where {|r| $r.result == "fail" or $r.result == "error"}
    let overall  = if ($failed | length) == 0 { "pass" } else { "fail" }

    # ── Write results file ────────────────────────────────────────────────────
    let report = {
        vm_name:   $vm_name
        image:     $image
        timestamp: $started_at
        tests:     $results
        overall:   $overall
    }

    let results_dir = $results_file | path dirname
    if not ($results_dir | path exists) {
        mkdir $results_dir
    }
    $report | to toml | save --force $results_file

    log-step "orchestrator" "results written" {
        results_file: $results_file
        overall:      $overall
        passed:       ($non_skip | where {|r| $r.result == "pass"} | length)
        failed:       ($failed | length)
        skipped:      ($results | where {|r| $r.result == "skip"} | length)
    }

    # ── Human summary table ───────────────────────────────────────────────────
    print-summary $results $overall

    if $overall == "fail" {
        exit 1
    }
}
