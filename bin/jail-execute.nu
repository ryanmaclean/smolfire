#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/jail-execute.nu — execute commands inside an ephemeral FreeBSD jail (EXPERIMENTAL)
#
# Sibling of bin/vm-execute.nu with the same contract: task id + commands in,
# {verdict, boot_sec, outputs: [{cmd, stdout, stderr, exit_code}], error?} out.
# `boot_sec` here is jail setup time (create + limits), not a VM boot.
#
# This is the bounded experiment from docs/BOOT-TIME-ROADMAP.md §4
# ("NO-GO as the default isolation layer; conditional GO as a bounded
# experiment"). The coordinator default stays `vm`; see docs/JAIL-EXECUTOR.md.
#
# Backends (pick exactly one rootfs source):
#   --base <dir>            thin jail: <dir> nullfs-mounted READ-ONLY as /,
#                           tmpfs /tmp as the only writable workspace
#   --zfs-snapshot <ds@s>   ephemeral `zfs clone` of a base snapshot (writable),
#                           destroyed on exit
#   --image <ref>           OCI image via Podman with the ocijail runtime
#
# Guarantees, on FreeBSD:
#   - per-task jail/container name derived from task_id + random salt
#   - no network unless the caller passes --network (coord-tick sets it only
#     when the request's tools_required contains "Network")
#   - rctl(8) memory (RSS and virtual)/process/CPU limits when kern.racct.enable=1
#   - /etc/resolv.conf (a copy of the host's) only when --network is given
#   - wall-clock deadline for the whole task (timeout(1) per command)
#   - teardown (jail -r, rctl -r, zfs destroy / rmdir) always runs; a failed
#     teardown turns the verdict into "fail"
# On any other OS it refuses with a clear error and touches nothing.
#
# Privilege: jail(8)/zfs(8)/rctl(8)/podman need root. If not already root, the
# privileged steps are prefixed with mdo(1) (mac_do(4)), never sudo/doas.
#
# Usage:
#   use jail-execute.nu [run-jail-task]
#   run-jail-task "task-0042" ["uname -a"] --base /usr/local/smolfire/base-15.0
#   nu bin/jail-execute.nu run task-0042 "uname -a" --base /usr/local/smolfire/base-15.0
#   nu bin/jail-execute.nu dispatch --task-id T --dispatch-id D --request-id R --spool S

use ./mbox-parse.nu [parse-mbox, extract-toml, msg-id]

export const JAIL_EXECUTOR_SCHEMA = "v1"
# coord-tick.nu treats a task with no reply after 300 s as failed; keep the
# task deadline + teardown inside that window.
export const COORD_REPLY_WINDOW_SEC = 300
export const TEARDOWN_RESERVE_SEC   = 30
export const DEFAULT_TIMEOUT_SEC    = 240
export const TIMEOUT_EXIT_CODE      = 124      # timeout(1) exit status on expiry
export const KILLED_EXIT_CODE       = 137      # 128 + SIGKILL (timeout -k fired)
# The only tools_required entry that grants the jail a network stack.
export const NETWORK_CAPABILITY     = "Network"
export const DEFAULT_JAIL_ROOT      = "/var/smolfire/jails"

# ── Pure helpers (unit-tested on any OS) ──────────────────────────────────────

# Refuse on anything but FreeBSD. Returns {ok: bool, error: string}.
export def host-check [os: string] {
    if $os =~ '(?i)^freebsd$' {
        {ok: true, error: ""}
    } else {
        {ok: false, error: $"jail executor requires a FreeBSD host \(jail\(8\), rctl\(8\), mac_do\(4\)\); this host is ($os). Use SMOLFIRE_EXECUTOR=vm here."}
    }
}

# Per-task jail name: `sf_<sanitized task_id>_<salt>`. Only [A-Za-z0-9_] so it
# is safe as a jail(8) name (no '.' hierarchy separator, never all-digits), a
# jail.conf block name, a podman container name, and a path component.
export def derive-jail-name [task_id: string, --salt: string = ""] {
    let clean = $task_id | str replace --all --regex '[^A-Za-z0-9_]' '_' | str substring 0..39
    let base  = if ($clean | str length) == 0 { "task" } else { $clean }
    let s = if $salt == "" {
        random uuid | str replace --all "-" "" | str substring 0..5
    } else {
        $salt | str replace --all --regex '[^a-z0-9]' '' | str substring 0..11
    }
    $"sf_($base)_($s)"
}

# Network is granted only by an explicit "Network" entry in tools_required.
export def network-wanted [tools_required: list<string>] {
    $NETWORK_CAPABILITY in $tools_required
}

# Clamp the requested task timeout into [1, COORD_REPLY_WINDOW - TEARDOWN_RESERVE].
export def clamp-timeout [timeout_sec: int] {
    let max = $COORD_REPLY_WINDOW_SEC - $TEARDOWN_RESERVE_SEC
    if $timeout_sec < 1 { 1 } else if $timeout_sec > $max { $max } else { $timeout_sec }
}

# Whole seconds left before `deadline_ns` (epoch ns), never negative.
export def remaining-sec [deadline_ns: int, now_ns: int] {
    let left = ($deadline_ns - $now_ns) // 1_000_000_000
    if $left < 0 { 0 } else { $left }
}

# True when an exit status means timeout(1) fired rather than the command failing.
export def timed-out? [exit_code: int] {
    $exit_code == $TIMEOUT_EXIT_CODE or $exit_code == $KILLED_EXIT_CODE
}

# Paths are interpolated into jail.conf and fstab(5) lines; refuse anything
# that could break quoting or field splitting.
export def safe-path? [p: string] {
    ($p | str length) > 0 and ($p =~ '^/[A-Za-z0-9_./-]+$') and not ($p | str contains "..")
}

# Validate an rctl/podman size like 512m, 2g, 1048576.
export def safe-size? [s: string] {
    $s =~ '^[0-9]+[kKmMgG]?$'
}

# Choose the backend from the mutually exclusive rootfs sources.
# Returns {backend: "nullfs"|"zfs"|"podman", error: string}.
export def resolve-backend [base: string, zfs_snapshot: string, image: string] {
    let given = [$base $zfs_snapshot $image] | where {|x| $x != ""} | length
    if $given == 0 {
        return {backend: "", error: "no rootfs source: pass exactly one of --base, --zfs-snapshot, --image (or set SMOLFIRE_JAIL_BASE / SMOLFIRE_JAIL_ZFS_SNAPSHOT / SMOLFIRE_JAIL_IMAGE)"}
    }
    if $given > 1 {
        return {backend: "", error: "ambiguous rootfs source: --base, --zfs-snapshot and --image are mutually exclusive"}
    }
    if $base != "" {
        if not (safe-path? $base) { return {backend: "", error: $"unsafe --base path: ($base)"} }
        return {backend: "nullfs", error: ""}
    }
    if $zfs_snapshot != "" {
        if not ($zfs_snapshot =~ '^[A-Za-z0-9_.:/-]+@[A-Za-z0-9_.:-]+$') {
            return {backend: "", error: $"unsafe --zfs-snapshot \(want pool/dataset@snap\): ($zfs_snapshot)"}
        }
        return {backend: "zfs", error: ""}
    }
    if not ($image =~ '^[A-Za-z0-9_.:/@-]+$') {
        return {backend: "", error: $"unsafe --image reference: ($image)"}
    }
    {backend: "podman", error: ""}
}

# Ephemeral ZFS dataset for a clone: sibling of the snapshot's dataset.
#   zroot/smolfire/base@clean + sf_t_ab12cd → zroot/smolfire/sf_t_ab12cd
export def zfs-clone-dataset [zfs_snapshot: string, name: string] {
    let ds = $zfs_snapshot | split row "@" | first
    let parent = $ds | path dirname
    if $parent == "" or $parent == "." { $"($ds)_($name)" } else { $"($parent)/($name)" }
}

# Render the jail.conf(5) block for one ephemeral jail.
#   backend nullfs: base mounted read-only at `path`; zfs: `path` is the clone.
#   Both get a size-capped tmpfs /tmp as the writable workspace.
# `mac_do_disable` adds `mac.do = "disable"` so host mac_do rules are not
# inherited into the jail (only valid when mac_do(4) is loaded).
export def render-jail-conf [
    name: string
    path: string
    --backend: string = "nullfs"
    --base: string = ""
    --network
    --tmpfs-size: string = "1g"
    --mac-do-disable
    --resolv-conf: string = ""   # file nullfs-mounted read-only at /etc/resolv.conf (nullfs backend)
] {
    let hostname = $name | str replace --all "_" "-"
    let ip = if $network { "inherit" } else { "disable" }
    let net_comment = if $network {
        "# network: inherit host stack (tools_required contains \"Network\")"
    } else {
        "# network: none (no \"Network\" in tools_required)"
    }
    let base_mount = if $backend == "nullfs" {
        [$"    mount += \"($base) ($path) nullfs ro 0 0\";"]
    } else { [] }
    let mac_do = if $mac_do_disable { ["    mac.do = \"disable\";"] } else { [] }
    # Single-file nullfs mount (FreeBSD 14+): source and target must both be
    # regular files, so the base needs an /etc/resolv.conf placeholder.
    let resolv_mount = if $resolv_conf != "" and $backend == "nullfs" {
        [$"    mount += \"($resolv_conf) ($path)/etc/resolv.conf nullfs ro 0 0\";"]
    } else { [] }

    [
        $"# generated by bin/jail-execute.nu \(schema ($JAIL_EXECUTOR_SCHEMA)\) — ephemeral, removed on exit"
        $"($name) {"
        $"    path = \"($path)\";"
        $"    host.hostname = \"($hostname)\";"
        "    persist;"
        "    exec.clean;"
        "    mount.devfs;"
        "    devfs_ruleset = 4;"
        "    enforce_statfs = 2;"
        "    securelevel = 3;"
        "    children.max = 0;"
        "    allow.noraw_sockets;"
        "    allow.nomount;"
        "    allow.noset_hostname;"
        "    allow.nochflags;"
        $"    ($net_comment)"
        $"    ip4 = \"($ip)\";"
        $"    ip6 = \"($ip)\";"
        ...$base_mount
        ...$resolv_mount
        $"    mount += \"tmpfs ($path)/tmp tmpfs rw,mode=1777,size=($tmpfs_size) 0 0\";"
        ...$mac_do
        "}"
    ] | str join "\n" | $in + "\n"
}

# Can a "Network" task get DNS? Returns {error: string} ("" = yes).
# The source must be a non-empty host file. The nullfs backend mounts it over
# <base>/etc/resolv.conf, which must already exist as a regular file (a
# single-file nullfs mount needs a file target, and the base is read-only);
# base.txz ships none, so the operator adds an empty placeholder once.
# The zfs clone is writable, so it needs no placeholder. Podman manages
# /etc/resolv.conf itself, so it is never handled here.
export def resolv-plan [backend: string, base: string, src: string] {
    if $backend == "podman" { return {error: "podman manages /etc/resolv.conf itself"} }
    if not (safe-path? $src) { return {error: $"unsafe resolv.conf source: ($src)"} }
    # the host file may be a symlink (e.g. managed by resolvconf); follow it
    if not ($src | path exists) or (($src | path expand | path type) != "file") {
        return {error: $"($src) not found on the host; the task gets network but no DNS"}
    }
    if (ls ($src | path expand) | get 0.size | into int) == 0 {
        return {error: $"($src) is empty; the task gets network but no DNS"}
    }
    if $backend == "nullfs" {
        let target = [$base "etc" "resolv.conf"] | path join
        # `path type` does not follow symlinks: a symlinked placeholder would
        # make the mount resolve on the host, so only a regular file counts
        if (($target | path type) != "file") {
            return {error: $"($target) missing: create an empty placeholder \(touch ($target)\) so it can be nullfs-mounted; the task gets network but no DNS"}
        }
    }
    {error: ""}
}

# rctl(8) rules for the jail. pcpu is a percentage of one CPU.
# memoryuse is RSS and is enforced lazily by the pager, so on its own it is not
# a hard cap (a 200m allocation succeeded under memoryuse:deny=64m on a
# swapless FreeBSD 15.0 host). vmemoryuse (address space) is denied at
# allocation time and makes the cap real; it defaults to the same size.
export def rctl-rules [name: string, memory: string, maxproc: int, pcpu: int, --vmemory: string = ""] {
    let vmem = if $vmemory == "" { $memory } else { $vmemory }
    [
        $"jail:($name):memoryuse:deny=($memory)"
        $"jail:($name):vmemoryuse:deny=($vmem)"
        $"jail:($name):maxproc:deny=($maxproc)"
        $"jail:($name):pcpu:deny=($pcpu)"
    ]
}

# Argument vector for the keep-alive container of the podman/ocijail backend.
# The container sleeps until the deadline; commands run via `podman exec`.
export def podman-run-args [
    name: string
    image: string
    timeout_sec: int
    --network
    --memory: string = "512m"
    --maxproc: int = 256
    --pcpu: int = 100
    --tmpfs-size: string = "1g"
] {
    let cpus = ($pcpu / 100.0) | into string
    let net = if $network { "host" } else { "none" }
    [
        "podman" "run" "--detach"
        "--name" $name
        "--runtime" "ocijail"
        "--network" $net
        "--read-only"
        "--tmpfs" $"/tmp:rw,mode=1777,size=($tmpfs_size)"
        "--memory" $memory
        "--pids-limit" ($maxproc | into string)
        "--cpus" $cpus
        $image
        "/bin/sleep" (($timeout_sec + $TEARDOWN_RESERVE_SEC) | into string)
    ]
}

# Argument vector (without privilege prefix) that runs one command in the
# jail/container under timeout(1). -k 5: SIGKILL 5 s after SIGTERM.
export def exec-argv [backend: string, name: string, cmd: string, remaining: int, --jail-user: string = "root"] {
    let t = ["timeout" "-k" "5" ($remaining | into string)]
    if $backend == "podman" {
        $t | append ["podman" "exec" $name "/bin/sh" "-c" $cmd]
    } else {
        $t | append ["jexec" "-l" "-U" $jail_user $name "/bin/sh" "-c" $cmd]
    }
}

# Privilege prefix for root-only steps. uid 0 → none; else `mdo -i` if present.
# `-i` switches only the user IDs to root and keeps the caller's groups, so the
# minimal mac_do(4) rule `uid=N>uid=0` authorizes it. Plain `mdo` implies
# `-u root`, which also switches to root's login groups (wheel, operator) and
# is refused with EPERM under that rule (verified on FreeBSD 15.0-RELEASE-p5).
# Returns {prefix: list<string>, error: string}.
export def priv-prefix [uid: int, has_mdo: bool] {
    if $uid == 0 {
        {prefix: [], error: ""}
    } else if $has_mdo {
        {prefix: ["mdo" "-i"], error: ""}
    } else {
        {prefix: [], error: $"jail executor needs root: run as root, or load mac_do\(4\) and allow this uid \(($uid)\) to reach root, e.g. security.mac.do.rules=\"uid=($uid)>uid=0\", with mdo\(1\) at /usr/bin/mdo"}
    }
}

# The result record — identical keys to vm-execute.nu's run-vm-task.
export def result-record [verdict: string, boot_sec: int, outputs: list, error: string = ""] {
    let r = {verdict: $verdict, boot_sec: $boot_sec, outputs: $outputs}
    if $error == "" { $r } else { $r | insert error $error }
}

# mbox reply envelope for a jail run. Mirrors coord-dispatch.nu dispatch-vm's
# body ([result] boot_sec/outputs + one [[claims]] block) so harvesting is
# executor-agnostic; In-Reply-To is the coordinator's dispatch Message-ID
# (what state-waiting matches on).
export def reply-envelope [task_id: string, dispatch_id: string, result: record, --now: string = ""] {
    let stamp  = if $now == "" { date now | format date "%Y%m%d%H%M%S" } else { $now }
    let dstamp = date now | format date "%a %b %e %H:%M:%S %Y"
    let outputs_toml = $result.outputs | each {|o|
        $"  {cmd = ($o.cmd | to json), stdout = ($o.stdout | to json), stderr = ($o.stderr | to json), exit_code = ($o.exit_code)}"
    } | str join ",\n"
    let err = $result | get -o error | default ""
    let error_line = if $err != "" { $"\nX-Jail-Error: ($err | str replace --all "\n" " ")" } else { "" }
    let exit_codes = $result.outputs | get -o exit_code | default [] | each {|c| $c | into string} | str join ","
    $"From jail-agent@smolfire.local ($dstamp)
From: jail-agent@smolfire.local
To: coordinator@smolfire.local
Subject: Re: [($task_id)] jail execution result
Message-ID: <($task_id).jail-agent.($stamp)@smolfire.local>
In-Reply-To: ($dispatch_id)
X-Project: smolfire
X-Executor: jail
X-Verdict: ($result.verdict)($error_line)
Content-Type: text/toml; charset=utf-8

task_id = ($task_id | to json)
verdict = ($result.verdict | to json)

[result]
boot_sec = ($result.boot_sec)
outputs = [
($outputs_toml)
]

[[claims]]
kind      = \"command_executed\"
task_id   = ($task_id | to json)
subject   = \"jail executed all commands\"
expected  = \"all commands exit 0\"
evidence  = ($"($result.outputs | length) commands run; exit codes [($exit_codes)]" | to json)
verdict   = ($result.verdict | to json)

"
}

# What to write before appending a message to an mbox whose current contents
# are `existing`, so the new "From " line follows a blank line (strict mbox).
export def mbox-append-prefix [existing: string] {
    if $existing == "" or ($existing | str ends-with "\n\n") {
        ""
    } else if ($existing | str ends-with "\n") {
        "\n"
    } else {
        "\n\n"
    }
}

# ── Side-effecting helpers ────────────────────────────────────────────────────

# Run argv with an optional privilege prefix; never throws.
def priv-run [prefix: list<string>, argv: list<string>] {
    let full = $prefix | append $argv
    let exe  = $full | first
    let rest = $full | skip 1
    try {
        ^$exe ...$rest | complete
    } catch {|e|
        {stdout: "", stderr: ($e | get -o msg | default "spawn failed"), exit_code: 127}
    }
}

def now-ns [] { date now | into int }

def diag [event: string, payload: record] {
    let row = {ts: (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"), event: $event} | merge $payload
    print -e ($row | to toml)
    print -e "---"
}

# Is rctl usable? (kern.racct.enable=1 — a loader tunable; needs reboot to change)
def racct-enabled [] {
    let r = try { ^sysctl -n kern.racct.enable | complete } catch { {exit_code: 1, stdout: ""} }
    $r.exit_code == 0 and ($r.stdout | str trim) == "1"
}

def mac-do-loaded [] {
    let r = try { ^sysctl -n security.mac.do.enabled | complete } catch { {exit_code: 1, stdout: ""} }
    $r.exit_code == 0 and ($r.stdout | str trim) == "1"
}

# Tear everything down. Returns a list of error strings (empty = clean).
def teardown [ctx: record] {
    mut errs = []
    if $ctx.backend == "podman" {
        if $ctx.created {
            let r = priv-run $ctx.prefix ["podman" "rm" "--force" "--time" "0" $ctx.name]
            if $r.exit_code != 0 { $errs = $errs | append $"podman rm failed: ($r.stderr | str trim)" }
        }
        return $errs
    }

    if $ctx.created {
        let r = priv-run $ctx.prefix ["jail" "-r" "-f" $ctx.conf $ctx.name]
        if $r.exit_code != 0 {
            $errs = $errs | append $"jail -r failed: ($r.stderr | str trim)"
            # jail(8) unmounts its `mount` entries on removal; if removal failed,
            # force-unmount so the base is never left mounted under the jail dir.
            let resolv_mp = if $ctx.resolv_mounted { [$"($ctx.path)/etc/resolv.conf"] } else { [] }
            for mp in [...$resolv_mp $"($ctx.path)/dev" $"($ctx.path)/tmp" $ctx.path] {
                let _ = priv-run $ctx.prefix ["umount" "-f" $mp]
            }
        }
    }
    if $ctx.rctl_added {
        let r = priv-run $ctx.prefix ["rctl" "-r" $"jail:($ctx.name)"]
        if $r.exit_code != 0 { $errs = $errs | append $"rctl -r failed: ($r.stderr | str trim)" }
    }
    if $ctx.backend == "zfs" and $ctx.cloned {
        let r = priv-run $ctx.prefix ["zfs" "destroy" "-f" $ctx.dataset]
        if $r.exit_code != 0 { $errs = $errs | append $"zfs destroy failed: ($r.stderr | str trim)" }
    }
    if $ctx.backend == "nullfs" and $ctx.dir_made {
        # rmdir, never rm -rf: if the read-only base is somehow still
        # nullfs-mounted here, rmdir fails loudly instead of recursing into it.
        let r = priv-run $ctx.prefix ["rmdir" $ctx.path]
        if $r.exit_code != 0 { $errs = $errs | append $"rmdir ($ctx.path) failed: ($r.stderr | str trim)" }
    }
    if $ctx.conf_dir != "" { rm -rf $ctx.conf_dir }
    $errs
}

# ── Public: run a task in an ephemeral jail ───────────────────────────────────

# Run a list of commands inside an ephemeral FreeBSD jail and return the same
# record shape as run-vm-task: {verdict, boot_sec, outputs, error?}.
export def run-jail-task [
    task_id:  string
    commands: list<string>
    --base:          string = ""       # thin-jail base dir (read-only nullfs)
    --zfs-snapshot:  string = ""       # pool/ds@snap to clone per task
    --image:         string = ""       # OCI image (podman + ocijail)
    --network                          # grant network (only for tools_required "Network")
    --timeout:       int    = 240      # whole-task wall clock, seconds (clamped)
    --memory:        string = "512m"   # rctl memoryuse / podman --memory
    --vmemory:       string = ""       # rctl vmemoryuse; empty = same as --memory
    --maxproc:       int    = 256      # rctl maxproc / podman --pids-limit
    --pcpu:          int    = 100      # rctl pcpu (% of one CPU) / podman --cpus
    --tmpfs-size:    string = "1g"     # writable /tmp size
    --jail-root:     string = "/var/smolfire/jails"
    --jail-user:     string = "root"   # user inside the jail for jexec -U
    --resolv-conf:   string = "/etc/resolv.conf"  # copied into the jail only with --network
    --require-limits                   # fail instead of warn when rctl is unavailable
    --salt:          string = ""       # name salt (tests); random when empty
    --os:            string = ""       # host OS override (tests); default $nu.os-info.name
] {
    let host_os = if $os == "" { $nu.os-info.name } else { $os }
    let hc = host-check $host_os
    if not $hc.ok { return (result-record "fail" 0 [] $hc.error) }

    if ($commands | length) == 0 { return (result-record "fail" 0 [] "no commands to run") }
    let be = resolve-backend $base $zfs_snapshot $image
    if $be.error != "" { return (result-record "fail" 0 [] $be.error) }
    if not (safe-path? $jail_root) { return (result-record "fail" 0 [] $"unsafe --jail-root: ($jail_root)") }
    if not (safe-size? $memory) { return (result-record "fail" 0 [] $"bad --memory: ($memory)") }
    if $vmemory != "" and not (safe-size? $vmemory) { return (result-record "fail" 0 [] $"bad --vmemory: ($vmemory)") }
    if not (safe-size? $tmpfs_size) { return (result-record "fail" 0 [] $"bad --tmpfs-size: ($tmpfs_size)") }
    if not ($jail_user =~ '^[a-z_][a-z0-9_-]*$') { return (result-record "fail" 0 [] $"bad --jail-user: ($jail_user)") }

    let uid = try { ^id -u | str trim | into int } catch { -1 }
    let pp = priv-prefix $uid ((which mdo | length) > 0)
    if $pp.error != "" { return (result-record "fail" 0 [] $pp.error) }
    let prefix = $pp.prefix

    let name = derive-jail-name $task_id --salt $salt
    let budget = clamp-timeout $timeout
    let t0 = now-ns
    let deadline = $t0 + ($budget * 1_000_000_000)
    let path = [$jail_root $name] | path join

    mut ctx = {
        backend: $be.backend, name: $name, prefix: $prefix, path: $path,
        conf: "", conf_dir: "", dataset: "",
        created: false, rctl_added: false, cloned: false, dir_made: false,
        resolv_mounted: false
    }
    mut setup_error = ""

    # ── setup ────────────────────────────────────────────────────────────────
    if $be.backend == "podman" {
        let argv = podman-run-args $name $image $budget --network=$network --memory $memory --maxproc $maxproc --pcpu $pcpu --tmpfs-size $tmpfs_size
        let r = priv-run $prefix $argv
        if $r.exit_code == 0 {
            $ctx = $ctx | update created true
        } else {
            $setup_error = $"podman run failed: ($r.stderr | str trim)"
        }
    } else {
        # explicit XXXXXX template: portable across BSD and GNU mktemp
        let conf_dir = ^mktemp -d (($env.TMPDIR? | default "/tmp") | path join "smolfire-jail.XXXXXXXX") | str trim
        ^chmod 700 $conf_dir
        let conf = [$conf_dir $"($name).conf"] | path join
        $ctx = $ctx | update conf $conf | update conf_dir $conf_dir

        if $be.backend == "zfs" {
            let ds = zfs-clone-dataset $zfs_snapshot $name
            $ctx = $ctx | update dataset $ds
            let r = priv-run $prefix ["zfs" "clone" "-o" $"mountpoint=($path)" "-o" "setuid=off" $zfs_snapshot $ds]
            if $r.exit_code == 0 {
                $ctx = $ctx | update cloned true
            } else {
                $setup_error = $"zfs clone failed: ($r.stderr | str trim)"
            }
        } else {
            let r = priv-run $prefix ["mkdir" "-p" "-m" "0755" $path]
            if $r.exit_code == 0 {
                $ctx = $ctx | update dir_made true
            } else {
                $setup_error = $"mkdir ($path) failed: ($r.stderr | str trim)"
            }
        }

        # DNS for "Network" tasks only: a snapshot of the host's resolv.conf.
        # zfs clone: copied into the writable clone. nullfs: mounted read-only
        # over the base's /etc/resolv.conf placeholder (see docs §3).
        mut resolv_mount = ""
        if $setup_error == "" and $network {
            let dns = resolv-plan $be.backend $base $resolv_conf
            if $dns.error != "" {
                diag "jail_dns_unavailable" {task_id: $task_id, jail: $name, reason: $dns.error}
            } else {
                let snap = [$conf_dir "resolv.conf"] | path join
                open --raw ($resolv_conf | path expand) | save --force $snap
                ^chmod 644 $snap
                if $be.backend == "zfs" {
                    # install(1) writes a temp file and renames it, so it never
                    # follows a symlink at the target
                    let r = priv-run $prefix ["install" "-m" "0644" $snap $"($path)/etc/resolv.conf"]
                    if $r.exit_code != 0 { $setup_error = $"install resolv.conf into clone failed: ($r.stderr | str trim)" }
                } else if not (safe-path? $snap) {
                    diag "jail_dns_unavailable" {task_id: $task_id, jail: $name, reason: $"unsafe resolv.conf snapshot path: ($snap)"}
                } else {
                    $resolv_mount = $snap
                    $ctx = $ctx | update resolv_mounted true
                }
            }
        }

        if $setup_error == "" {
            let use_mdo = ($prefix | length) > 0
            let mac_do_off = $use_mdo or (mac-do-loaded)
            let rendered = render-jail-conf $name $path --backend $be.backend --base $base --network=$network --tmpfs-size $tmpfs_size --mac-do-disable=$mac_do_off --resolv-conf $resolv_mount
            $rendered | save --force $conf
            let r = priv-run $prefix ["jail" "-c" "-f" $conf $name]
            if $r.exit_code == 0 {
                $ctx = $ctx | update created true
            } else {
                $ctx = $ctx | update resolv_mounted false
                $setup_error = $"jail -c failed: ($r.stderr | str trim)"
            }
        }

        if $setup_error == "" {
            if (racct-enabled) {
                mut rctl_err = ""
                for rule in (rctl-rules $name $memory $maxproc $pcpu --vmemory $vmemory) {
                    let r = priv-run $prefix ["rctl" "-a" $rule]
                    $ctx = $ctx | update rctl_added true
                    if $r.exit_code != 0 { $rctl_err = $"rctl -a ($rule) failed: ($r.stderr | str trim)"; break }
                }
                if $rctl_err != "" { $setup_error = $rctl_err }
            } else if $require_limits {
                $setup_error = "rctl unavailable (kern.racct.enable=0; set kern.racct.enable=1 in /boot/loader.conf and reboot) and --require-limits was given"
            } else {
                diag "jail_limits_unavailable" {task_id: $task_id, jail: $name, reason: "kern.racct.enable != 1; running without rctl limits"}
            }
        }
    }

    let boot_sec = ((now-ns) - $t0) // 1_000_000_000

    if $setup_error != "" {
        let errs = teardown $ctx
        let msg = [$setup_error ...$errs] | str join "; "
        return (result-record "fail" $boot_sec [] $msg)
    }

    # ── run ──────────────────────────────────────────────────────────────────
    mut outputs = []
    mut all_ok = true
    mut run_error = ""
    for cmd in $commands {
        let rem = remaining-sec $deadline (now-ns)
        if $rem <= 0 {
            $all_ok = false
            $run_error = $"task timeout: ($budget)s budget exhausted before `($cmd)`"
            break
        }
        let r = priv-run $prefix (exec-argv $be.backend $name $cmd $rem --jail-user $jail_user)
        $outputs = $outputs | append {
            cmd:       $cmd
            stdout:    ($r.stdout | str trim)
            stderr:    ($r.stderr | str trim)
            exit_code: $r.exit_code
        }
        if $r.exit_code != 0 { $all_ok = false }
        if (timed-out? $r.exit_code) {
            $run_error = $"task timeout: `($cmd)` killed by timeout\(1\) after ($rem)s"
            break
        }
    }

    # ── teardown (always) ────────────────────────────────────────────────────
    let errs = teardown $ctx
    let all_errors = [$run_error ...$errs] | where {|e| $e != ""}
    let verdict = if $all_ok and ($errs | is-empty) { "pass" } else { "fail" }
    result-record $verdict $boot_sec $outputs ($all_errors | str join "; ")
}

# ── CLI ───────────────────────────────────────────────────────────────────────

# Exit status for a result: 0 pass, 2 refused (non-FreeBSD host), 1 otherwise.
def result-exit [result: record] {
    if $result.verdict == "pass" { 0 } else if (($result | get -o error | default "") | str starts-with "jail executor requires a FreeBSD host") { 2 } else { 1 }
}

# Run commands in an ephemeral jail and print the result record as JSON.
def "main run" [
    task_id: string
    ...commands: any    # any: nu's script-arg parser turns bare `true`/`42` into non-strings
    --base: string = ""
    --zfs-snapshot: string = ""
    --image: string = ""
    --network
    --timeout: int = 240
    --memory: string = "512m"
    --vmemory: string = ""
    --maxproc: int = 256
    --pcpu: int = 100
    --tmpfs-size: string = "1g"
    --jail-root: string = "/var/smolfire/jails"
    --require-limits
] {
    let cmds = $commands | each {|c| $c | into string }
    let result = run-jail-task $task_id $cmds --base $base --zfs-snapshot $zfs_snapshot --image $image --network=$network --timeout $timeout --memory $memory --vmemory $vmemory --maxproc $maxproc --pcpu $pcpu --tmpfs-size $tmpfs_size --jail-root $jail_root --require-limits=$require_limits
    print ($result | to json)
    exit (result-exit $result)
}

# Coordinator entry point (spawned detached by coord-tick.nu when
# SMOLFIRE_EXECUTOR=jail). Reads the ORIGINAL request (--request-id) from the
# spool for commands / rootfs / tools_required, runs it, and appends a reply
# whose In-Reply-To is the coordinator's dispatch Message-ID (--dispatch-id).
def "main dispatch" [
    --task-id: string
    --dispatch-id: string
    --request-id: string
    --spool: string
] {
    let msgs = parse-mbox (open --raw $spool)
    let req = $msgs | where {|m| (msg-id $m) == $request_id } | first 1
    let payload = if ($req | is-empty) { {} } else { extract-toml ($req | first) }

    let commands = if ($payload | get -o commands.run | default [] | is-not-empty) {
        $payload | get commands.run
    } else if ($payload | get -o command | default "") != "" {
        [$payload.command]
    } else { [] }
    let cp = $payload | get -o context_pointers | default {}
    let base  = $cp | get -o jail_base         | default ($env.SMOLFIRE_JAIL_BASE? | default "")
    let zsnap = $cp | get -o jail_zfs_snapshot | default ($env.SMOLFIRE_JAIL_ZFS_SNAPSHOT? | default "")
    let image = $cp | get -o jail_image        | default ($env.SMOLFIRE_JAIL_IMAGE? | default "")
    let tools = $payload | get -o tools_required | default []
    let timeout = $payload | get -o timeout_sec | default ($env.SMOLFIRE_JAIL_TIMEOUT? | default $DEFAULT_TIMEOUT_SEC | into int)
    let jail_root = $env.SMOLFIRE_JAIL_ROOT? | default $DEFAULT_JAIL_ROOT

    let result = if ($req | is-empty) {
        result-record "fail" 0 [] $"request ($request_id) not found in spool"
    } else {
        run-jail-task $task_id $commands --base $base --zfs-snapshot $zsnap --image $image --network=(network-wanted $tools) --timeout $timeout --jail-root $jail_root
    }
    # Strict mbox: the reply's "From " line must follow a blank line.
    let existing = if ($spool | path exists) { open --raw $spool } else { "" }
    (mbox-append-prefix $existing) + (reply-envelope $task_id $dispatch_id $result) | save --append $spool
    diag "jail_dispatch_done" {task_id: $task_id, verdict: $result.verdict, boot_sec: $result.boot_sec, error: ($result | get -o error | default "")}
    exit (result-exit $result)
}

def main [] {
    print "jail-execute.nu — ephemeral FreeBSD jail executor (experimental; see docs/JAIL-EXECUTOR.md)"
    print "  nu bin/jail-execute.nu run <task_id> <cmd>... (--base DIR | --zfs-snapshot DS@SNAP | --image REF) [--network] [--timeout N]"
    print "  nu bin/jail-execute.nu dispatch --task-id T --dispatch-id D --request-id R --spool PATH"
}
