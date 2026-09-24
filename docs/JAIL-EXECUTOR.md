# Jail executor (experimental)

Status: **first slice, experimental, off by default.** Tracking: issue #39 item 3.

`docs/BOOT-TIME-ROADMAP.md` §4 decided: **NO-GO as the coordinator's default
isolation layer; conditional GO as a bounded experiment** (compare one task in
an ocijail/`mac_do(4)` jail against a SMOLFIRE-per-task dispatch on the FreeBSD
build VM). This slice builds the tool for that experiment. It does not change
the default: `vm` stays the executor unless you opt in.

| File | Role |
|---|---|
| `bin/jail-execute.nu` | Executor. Sibling of `bin/vm-execute.nu` with the same contract |
| `bin/coord-tick.nu` | Picks the executor per request (`resolve-executor`) and spawns `jail-execute.nu dispatch` for `jail` |
| `tests/jail-execute-test.nu` | 34 host-independent tests that stub the FreeBSD tools on `PATH`. `tests/run-all.sh` picks it up automatically |

## 1. Contract

```nu
use bin/jail-execute.nu [run-jail-task]
run-jail-task "task-0042" ["uname -a" "cc --version"] --base /usr/local/smolfire/base-15.0
# => {verdict: "pass"|"fail", boot_sec: int, outputs: [{cmd, stdout, stderr, exit_code}], error?: string, warnings?: list<string>}
```

The record has the same keys as `run-vm-task`, plus an optional `warnings`
key (present only when non-empty) for non-fatal preflight notices — today,
`--allow-unpatched` overriding the §3 patch-floor refusal, or a
`security.mac.do.rules` entry with no `gid=` clause. A test checks the
required keys against `vm-execute.nu` itself. `boot_sec` is the jail setup time: clone or mkdir,
`jail -c`, and the rctl limits.

CLI output is structured JSON on stdout. The exit code is 0 for pass, 1 for
fail, and 2 when the executor refuses to run: on a non-FreeBSD host, or on a
FreeBSD host below the minimum patch level in §3 (unless `--allow-unpatched`
is passed):

```sh
nu bin/jail-execute.nu run task-0042 "uname -a" --base /usr/local/smolfire/base-15.0
nu bin/jail-execute.nu run task-0042 "make -C /tmp/src" --zfs-snapshot zroot/smolfire/base@clean --timeout 200
nu bin/jail-execute.nu run task-0042 "uname -a" --image ghcr.io/freebsd/freebsd-runtime:15.0
```

Flags: `--network`, `--timeout` (seconds), `--memory 512m`,
`--vmemory <size>` (defaults to `--memory`), `--maxproc 256`,
`--pcpu 100`, `--tmpfs-size 1g`, `--jail-root /var/smolfire/jails`,
`--require-limits`, `--allow-unpatched` (skip the §3 patch-floor refusal;
not recommended — see FreeBSD-SA-26:59.mac_do / CVE-2026-58092).

### Backends (exactly one rootfs source)

| Flag | Rootfs | Writable | Destroyed by |
|---|---|---|---|
| `--base DIR` | Thin jail. `DIR` is mounted read-only with nullfs at `<jail-root>/<name>` | tmpfs `/tmp` only (size-capped) | `jail -r` unmounts it. `rmdir` removes the directory |
| `--zfs-snapshot DS@SNAP` | `zfs clone` into a sibling dataset `<parent>/<name>` for each task | whole clone, plus tmpfs `/tmp` | `zfs destroy -f` |
| `--image REF` | OCI image through `podman run --runtime ocijail --read-only` | tmpfs `/tmp` | `podman rm --force` |

### Per-task guarantees (enforced in code, tested with stubs)

- **Name:** `sf_<task_id with anything outside [A-Za-z0-9_] replaced by _>_<6 hex salt>`.
  The name contains no `.`, so it can't create a jail hierarchy, and it is
  never all digits, so jail(8) can't read it as a JID. The salt changes on
  every attempt, so a retry can't collide with a jail that leaked earlier.
- **No network by default:** `ip4 = "disable"; ip6 = "disable"` for jails,
  `--network none` for podman. A request gets network only when its
  `tools_required` contains `"Network"`. That setting inherits the host
  network stack (`ip4 = inherit`, or `--network host` for podman).
  `"Network"` is a coordinator capability, not a Claude tool. §17 gates it
  like any other tool: only `general-purpose`, `ops` and `builder` have it.
  `WebFetch` and `WebSearch` do **not** open the jail's network.
- **DNS only with network:** a `"Network"` task gets a snapshot of the host's
  `/etc/resolv.conf`, copied into the private config directory when the task
  starts. For `--base` it is nullfs-mounted read-only over the base's
  `/etc/resolv.conf`, which must exist as an empty regular file (see §3,
  because base.txz ships none). For `--zfs-snapshot` it is written into the
  clone with `install(1)`. A task without `"Network"` gets no resolv.conf
  from the executor. If DNS can't be provided (no placeholder, or the host
  file is missing or empty), the task still runs with TCP only and the
  executor logs `jail_dns_unavailable` with the reason. Podman manages
  `/etc/resolv.conf` itself.
- **Hardening:** every jail.conf block sets `persist`, `enforce_statfs = 2`,
  `securelevel = 3`, `children.max = 0`, `devfs_ruleset = 4`,
  `allow.noraw_sockets`, `allow.nomount`, `allow.noset_hostname` and
  `allow.nochflags`. When `mac_do(4)` is loaded it also sets
  `mac.do = "disable"`, so the host's mdo rules don't carry into the jail.
- **Resource limits:** when `kern.racct.enable=1`, rctl(8) adds
  `jail:<name>:memoryuse`, `vmemoryuse`, `maxproc` and `pcpu` deny rules and
  removes them on exit. `memoryuse` is resident memory and the pager enforces
  it lazily, so on its own it is not a hard cap: on the FreeBSD 15.0 test
  host (no swap), a 200 MB `dd` buffer succeeded under `memoryuse:deny=64m`.
  `vmemoryuse` (address space) is refused at allocation time, so that is the
  rule that makes the memory cap real. It defaults to the `--memory` value.
  Raise it with `--vmemory` if a toolchain reserves much more address space
  than it touches. `pcpu` throttling is approximate: a busy loop at
  `pcpu=20` averaged about 36% of one CPU. Without racct the executor warns
  and runs unlimited. `--require-limits` refuses instead.
- **Timeout:** one wall-clock deadline covers the whole task, setup included.
  The deadline is clamped to 1–270 s so a result can reach the coordinator
  before its 300 s no-reply timeout. Each command runs under
  `timeout -k 5 <remaining>`. Exit 124 or 137 counts as a timeout and stops
  the task. Once the budget runs out, the remaining commands are skipped.
  **A command that leaves a background process behind is reported as a
  timeout.** FreeBSD's `timeout(1)` acts as a reaper and waits for every
  descendant (unless `--foreground`, which the executor doesn't use). So
  `daemon -f sleep 600; echo spawned` prints `spawned` and then exits `124`
  at the deadline. This is bounded and safe, and `jail -r` kills the orphan,
  but the task fails. Commands must not leave background processes running.
- **Teardown always runs,** in this order: `jail -r`, `rctl -r`, then
  `zfs destroy` or `rmdir`, then removal of the private jail.conf directory.
  If `jail -r` fails, the executor force-unmounts `dev`, `tmp` and the base.
  It uses `rmdir`, **never `rm -rf`**, so a base that is still mounted makes
  the step fail loudly instead of being deleted through the mount. A failed
  teardown turns the verdict into `fail`.
- **Input validation:** paths, sizes, image references and ZFS names are
  checked against strict patterns before they reach jail.conf, fstab or argv.
  In coord-tick, spawned values are passed as argv and are never interpolated
  into a shell string.
- **Non-FreeBSD hosts:** the executor refuses before touching anything.
  Tests confirm that none of the stubbed binaries run.

## 2. Enabling it

Default is `vm`. Precedence: the request TOML field `executor`, then the
`SMOLFIRE_EXECUTOR` env var, then `"vm"`.

```sh
SMOLFIRE_EXECUTOR=jail SMOLFIRE_JAIL_BASE=/usr/local/smolfire/base-15.0 sh bin/coord-run.sh
```

```toml
# or per request (in the spool request body)
task_id        = "task-0042"
executor       = "jail"
tools_required = ["Bash"]           # add "Network" only if the commands need it
timeout_sec    = 200                # optional; clamped to 270
[commands]
run = ["uname -a", "cc --version"]  # or a single `command = "..."`
[context_pointers]
jail_base = "/usr/local/smolfire/base-15.0"   # or jail_zfs_snapshot / jail_image
```

Env fallbacks for the rootfs: `SMOLFIRE_JAIL_BASE`,
`SMOLFIRE_JAIL_ZFS_SNAPSHOT`, `SMOLFIRE_JAIL_IMAGE`. Other env settings are
`SMOLFIRE_JAIL_TIMEOUT` and `SMOLFIRE_JAIL_ROOT` (default `/var/smolfire/jails`).

What coord-tick does:

- It refuses dispatch and logs `dispatch_executor_refused` when the executor
  name is unknown, or when `jail` is requested on a non-FreeBSD host. Like
  the §17 capability check, this is a refusal and not a retry. It **never
  falls back to `vm` silently**, because a request that asked for isolation
  must not be downgraded.
- The dispatch envelope and the `dispatch_sent` event both carry
  `executor = "..."`. The state file keeps
  `task_executors.<task_id> = {executor, network, request_id}` so a retry
  uses the same executor and the original request.
- For `jail`, it starts `nu bin/jail-execute.nu dispatch ...` detached. The
  log goes to `var/run/spawned/<task>.jail.log`. The child reads the original
  request and appends a reply with `In-Reply-To` set to the dispatch
  Message-ID, which is what `state-waiting` matches on. The reply body uses
  the same layout as `coord-dispatch.nu dispatch-vm`: `[result] boot_sec`,
  `outputs` (plus `stderr`), and one `[[claims]]` block. It also carries
  `X-Executor: jail` and `X-Jail-Error`.
- For `vm`, the behaviour is unchanged. Note that "vm" means *today's path*:
  coord-tick starts a `claude` CLI subagent **on the host**. Only `vm-*` roles
  that go through `coord-dispatch.nu` boot a SMOLFIRE VM through
  `vm-execute.nu`.

## 3. Host prerequisites (FreeBSD 15.x)

**Minimum host patch level: `15.0-RELEASE-p13` or `15.1-RELEASE-p3`.**
Required for FreeBSD-SA-26:59.mac_do (CVE-2026-58092: a `mac_do(4)` rule with
no explicit target gid can leave the switched credential's primary gid at 0
when the caller's supplementary-group list is empty), FreeBSD-SA-26:25.thr
(`thr_kill2(2)` missing perm check breaks jail signal isolation) and
FreeBSD-SA-26:18.setcred (kernel stack overflow via `setcred(2)`, the syscall
underneath `mdo(1)`/`mac_do(4)`). `bin/jail-execute.nu` checks
`freebsd-version -k` at the start of every run and refuses (exit 2) below this
floor unless `--allow-unpatched` is passed; it also warns if any
`security.mac.do.rules` entry omits a `gid=` clause.

jail(8), jexec(8), rctl(8), mac_do(4), mdo(1), timeout(1), nullfs(5) and
tmpfs(5) are all FreeBSD base (BSD-2-Clause). **Licence caveat:** zfs(8) is
OpenZFS, which is **CDDL-1.0**, a weak copyleft licence that isn't on this
project's allow-list (MIT, BSD-2, BSD-3, Apache-2.0). The `--zfs-snapshot`
backend and Podman's recommended ZFS storage driver therefore need an explicit
licence decision before anyone depends on them. `--base` (nullfs + tmpfs) is
the backend without ZFS and is the one to use by default. For `--image`,
Podman's `vfs` storage driver avoids ZFS.

| Need | How |
|---|---|
| Nushell | `pkg install nushell` (MIT) |
| rctl | `kern.racct.enable=1` in `/boot/loader.conf`, then **reboot**. It's a tunable and can't be set at runtime |
| Root hop for a non-root coordinator | `mac_do_load="YES"` in loader.conf (or `kldload mac_do`), plus `security.mac.do.rules="uid=<coord-uid>>uid=0:gid=0"` in `/etc/sysctl.conf`. The rule pins an explicit target `gid=0` (root:wheel is genuinely intended here, since this row already grants the coordinator full root — see §4); a rule with no `gid=` clause is the exact shape FreeBSD-SA-26:59.mac_do (CVE-2026-58092) warns about, on hosts below the minimum patch level in §3. The executor runs `mdo -i`, which changes only the user IDs and keeps the caller's groups, so this rule is enough. Plain `mdo` (implied `-u root`, which also takes root's groups) is refused with `setcred(): Operation not permitted` under it. `mdo` must be at `/usr/bin/mdo`. Alternatively, run the coordinator as root on a dedicated VM |
| Base dir (`--base`) | A FreeBSD 15 userland, for example `bsdinstall jail /usr/local/smolfire/base-15.0` or an extracted `base.txz`. Keep it read-only and owned by root |
| DNS for `"Network"` tasks (`--base`) | `touch <base>/etc/resolv.conf`, which creates an **empty** regular file (not a symlink) for the per-task nullfs file mount. Keep it empty so tasks without network see no resolver config |
| ZFS base (`--zfs-snapshot`) | `zfs create -p zroot/smolfire/base`, populate it, then `zfs snapshot zroot/smolfire/base@clean` |
| Jail root | `mkdir -p /var/smolfire/jails` (root-owned) |
| OCI (`--image`) | `pkg install podman-suite` (Podman, Buildah and Skopeo are **Apache-2.0**; `ocijail` is **BSD-2-Clause**). Follow its pkg-message, which covers the ZFS storage driver and fdescfs. Check licences at install time with `pkg query '%n %L' podman buildah ocijail` |

The components the default `--base` backend needs are MIT, BSD-2-Clause or
Apache-2.0. The only copyleft piece is OpenZFS (CDDL-1.0), and it is used only
when you opt into `--zfs-snapshot` or Podman's ZFS storage driver.

## 4. Security boundaries vs the VM executor

| | `vm` (SMOLFIRE under QEMU) | `jail` (this executor) |
|---|---|---|
| Kernel | Separate guest kernel. Escaping means breaking the hypervisor (HVF/KVM/bhyve) plus virtio | **Shared host kernel.** Escaping means a FreeBSD kernel or jail bug, a larger attack surface |
| Host privilege needed | None beyond running QEMU | **Root.** A `mac_do` rule `uid=N>uid=0:gid=0` gives the coordinator user *full* root, because rules can't be scoped to commands. In practice the coordinator user is root-equivalent, so run it on a dedicated FreeBSD VM (the roadmap's "build VM"), not a shared host |
| Network | QEMU user-net always has SLIRP egress | None unless `tools_required` has `"Network"`, which then inherits the host stack. No VNET yet |
| Filesystem | qcow2 overlay, base image never written | Read-only nullfs base plus a size-capped tmpfs, or a throwaway ZFS clone. Neither the spool nor the repo is visible inside |
| Resources | `-m 256M -smp 2` | rctl memory, maxproc and pcpu (only when racct is enabled) |
| Cleanup on hang | VM shutdown, then kill the QEMU job | `timeout -k`, then `jail -r` (kills every process in the jail) |
| Privilege inside | root in the guest | root in the jail at `securelevel = 3`, with no raw sockets, no mounts and no nested jails. `run-jail-task --jail-user` can lower it |
| OCI path | n/a | **Rootful Podman.** Rootless Podman is the documented FreeBSD gap and the roadmap's trigger to revisit |

Bottom line, same as the roadmap: the jail runs code closer to the host than
the VM does, and it needs root. It is worth measuring, but it is not a
replacement for the microVM boundary.

## 5. Not covered yet

- **Partly verified on a real host.** §6 items 1–5, 8 and 9 passed on
  FreeBSD 15.0-RELEASE-p5 (amd64, 2026-09-23). The ZFS clone backend (item 6)
  and podman/ocijail (item 7) have still only been checked against logging
  stubs.
- **No LLM inside the jail.** The `jail` executor runs the request's shell
  `command` or `commands.run` directly. The roadmap experiment, "run one
  build *subagent* in a jail", would also need Claude Code (Node) in the base
  and a way to deliver credentials. That is not built.
- **Podman resource limits under ocijail** (`--memory`, `--pids-limit`,
  `--cpus`) are passed but unverified. The OCI path has no rctl fallback,
  because the jail name belongs to ocijail.
- **No VNET.** "Network" means `inherit`. Per-task VNET with an epair and pf
  NAT is future work.
- **No crash reaper.** If the executor process itself is SIGKILLed, the jail
  leaks. Clean up by prefix:
  `jls name | grep '^sf_'`, then `jail -r <name>`, then
  `rctl -r jail:<name>`, then `rmdir` or `zfs destroy`.
- **`coord-dispatch.nu`** (the `vm-*` role path) is not switched. Only
  `coord-tick.nu` selects executors.
- **No automated experiment metrics.** `boot_sec` is recorded, but the
  wall-time, escape-surface and spool-ergonomics comparison from the roadmap
  isn't automated.
- The coordinator still dispatches one task at a time, so jails don't run
  concurrently yet.

## 6. Needs a real FreeBSD host to verify

Run these on the FreeBSD build VM, once, before trusting the executor:

1. `jail -c -f <rendered conf>` accepts every parameter on 15.x:
   `securelevel`, `allow.no*`, `mac.do`, `mount += nullfs/tmpfs`, and the
   ordering of `mount.devfs` over a read-only nullfs base.
2. `rctl -a jail:<name>:...` applies to the named jail. `rctl -u jail:<name>`
   shows usage (`-h` only makes the numbers human-readable, as in
   `rctl -hu`), and `rctl -r` clears it.
3. `mdo` with the `uid=N>uid=0:gid=0` rule works, and `mac.do = "disable"`
   stops mdo inside the jail. The explicit `gid=` clause avoids
   FreeBSD-SA-26:59.mac_do (CVE-2026-58092) regardless of host patch level.
4. `timeout -k 5 N` through `mdo` kills a hung `jexec`, and `jail -r` reaps
   what's left.
5. After a run, `mount -p | grep /var/smolfire/jails` and `jls` are both
   empty, and so is the directory or the ZFS dataset.
6. `zfs clone -o mountpoint=...` and `zfs destroy -f` work for each task.
7. `podman run --runtime ocijail --read-only --tmpfs /tmp --network none`
   works with a FreeBSD runtime image, and the limits take effect.
8. End to end: a request with `executor = "jail"` produces a harvested
   `pass` reply through `coord-tick.nu`.
9. The roadmap comparison: wall time of a jail run against a SMOLFIRE boot
   for the same command list.

Results on FreeBSD 15.0-RELEASE-p5 (amd64 KVM guest, 2 vCPU, 4 GiB, no swap,
nu 0.115.1, 2026-09-23):

| # | Result | Notes |
|---|---|---|
| 1 | PARTIAL | Read-only base, tmpfs cap enforced, `securelevel=3`, network gated; the new resolv.conf path has not been rerun on the host |
| 2 | PARTIAL | maxproc enforced and prior memoryuse checks passed; the new `vmemoryuse` rule has not been rerun on the host |
| 3 | PASS after fix | The executor now uses `mdo -i`. `mac.do=disable` blocks mdo inside the jail |
| 4 | PASS | Hung and TERM-ignoring commands are killed. A leftover background process causes exit 124 (see §1) |
| 5 | PASS | No jails, mounts, directories or rctl rules are left behind |
| 6 | SKIP | No ZFS pool (and OpenZFS is CDDL) |
| 7 | SKIP | podman's package closure pulls GPL/LGPL packages |
| 8 | PASS | coord-tick → jail → reply harvested, `verdict pass` |
| 9 | PASS (jail) | About 0.19 s per jail task end to end, against 51 s for a QEMU TCG boot to `login:` (no VMX on the host) |

The host-independent part is covered by `nu tests/jail-execute-test.nu`:
argument parsing, jail.conf and podman rendering, name derivation, timeout
math, record parity with `vm-execute.nu`, reply-envelope parsing and
strict-mbox appending, resolv.conf handling for `"Network"` tasks, refusal
on non-FreeBSD hosts, teardown on every failure path, and executor selection
in coord-tick.
