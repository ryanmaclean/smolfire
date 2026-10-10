# Fleet dispatch executor (gastown-style, opt-in)

Status: **prototype, opt-in, off by default.** Branch `feat/coord-fleet-dispatch`.

| File | Role |
|---|---|
| `bin/coord-fleet-dispatch.nu` | Executor. Shares the result shape with `bin/vm-execute.nu` and the agent-jail executor; smolfire's jail path is `bin/coord-jail-dispatch.nu` |
| `bin/coord-dispatch.nu` | Minimal hook: `fleet-*` roles route to `dispatch-fleet`, gated by `SMOLFIRE_FLEET_ENABLE=1` |
| `tests/coord-fleet-dispatch-test.nu` | 26 stub-ssh tests (no live hosts) + 1 guarded live test |

## 1. Why a third backend

`vm` boots a whole guest per task (tens of seconds); `jail` is fast but
FreeBSD-only and root-equivalent. The fleet backend reuses long-lived remote
workers the project already has key access to: no boot, no image build, no
privilege escalation — just `ssh` a command at a box and harvest the result.
It is the smolfire analogue of gastown's fleet dispatch: the coordinator
stays the single ordering source, workers are dumb executors.

## 2. Targets and exclusions (verified 2026-09-28)

| Target | Fingerprint | Role |
|---|---|---|
| `studio@10.0.2.42` | `7950x4090pop`, Linux x86_64, 32 CPU, GNU `timeout(1)` present | **compute worker** — live-tested end to end (`uname -a`, `hostname; nproc` → pass) |
| `root@10.0.2.61` | `MiSTer`, Linux armv7l | **EXCLUDED from compute** — a gaming box, not a worker. `resolve-target` refuses it with a pointer here, even though key auth succeeds |

Key-based SSH **only** (repo AUTH policy): every invocation carries
`-o BatchMode=yes` (a rejected key fails fast instead of prompting) and
`-o ConnectTimeout=5`. No passwords are ever guessed, passed, or configured
— there is no password knob anywhere in the executor, and a test asserts the
stub-ssh argv log contains `BatchMode=yes` and no `sshpass` /
`PasswordAuthentication`.

Probing rule: only the two hosts above may be probed. Any other host runs
solely with owner-provided access (`SMOLFIRE_FLEET_HOST`); without it the
executor records the target as unreachable-today (preflight failure, exit 2)
and never guesses credentials.

## 3. Contract

```nu
use bin/coord-fleet-dispatch.nu [run-fleet-task]
run-fleet-task "task-0042" ["uname -a"] --target studio@10.0.2.42
# => {verdict: "pass"|"fail", boot_sec: int, outputs: [{cmd, stdout, stderr, exit_code}], target: string, error?: string, warnings?: list<string>}
```

Same keys as `run-vm-task` / `run-jail-task`, plus `target` (which
`user@host` ran it) and the jail-style optional `warnings`. `boot_sec` is
preflight (key-auth probe) time. CLI exits 0 pass / 1 fail / 2 refused
(halted, bad target, capability refusal, preflight failure).

Per-command semantics, all real (no shims):

- **exec**: `timeout -k 5 <remaining> ssh -o BatchMode=yes
  -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -- <user@host> sh -c
  <single-quoted payload>`. The payload is POSIX single-quote escaped
  (`sh-quote`, unit-tested) so ssh's argv-joining cannot split it.
- **capture**: real stdout/stderr via `complete`, real remote exit codes
  (`ssh` propagates them); exit 255 means ssh itself failed and stops the task.
- **timeout kill**: one wall-clock budget per task (default 240 s, clamped to
  1–270 s so the reply lands inside the coordinator's 300 s no-reply window),
  enforced per command by `timeout -k 5`. If no `timeout(1)` is on PATH the
  run still proceeds (ssh `ConnectTimeout` bounds setup) but records a
  `warnings` entry — loud, not silent. Override/disable for tests via
  `SMOLFIRE_FLEET_TIMEOUT_BIN` ("" disables).
- **teardown**: no-op *by construction* — each command is its own `ssh`
  invocation, so there is no keep-alive container, jail, or overlay to leak.
  A killed ssh leaves no remote process behind because there is no remote
  supervisor holding one.

## 4. Semantics carried over (not bypassed)

- **S-004 capability gates, twice.** The coordinator's §17 check
  (`tools_required` vs `AGENT_CAPABILITIES`) still runs before dispatch, and
  the executor re-checks against *per-host declared capabilities*
  (`capabilities-for`): the known worker declares the full general-purpose
  set including `Network`; owner-provided unknown hosts get a conservative
  default **without** `Network`. A `Network` task on such a host is refused
  (exit 2), never silently downgraded.
- **S-001 attestation.** `reply-envelope` emits one `[[claims]]` block with
  `kind = "command_executed"`, `task_id`, and exit-code evidence — the same
  shape as the jail executor — so the coordinator's request-linked
  attestation check treats fleet replies exactly like jail/vm replies.
- **Halt/resume.** `run-fleet-task` checks `var/mail/HALT.<task_id>` under the
  coordinator root (derived from the spool path via `root-for-spool`) *before*
  the preflight probe and refuses (exit 2) when present — a halted task never
  touches the network. A test asserts the stub ssh log is not even created.
  Resume is the existing mechanism: `rm` the marker + post a resume message.
- **Harvest compatibility.** Replies carry `In-Reply-To` = the coordinator's
  dispatch Message-ID (what `state-waiting` matches on), `X-Executor: fleet`,
  `[result] boot_sec` / `outputs`, and strict-mbox append separation
  (`mbox-append-prefix`).

## 5. Enabling it

Default is unchanged (`vm`). Fleet is a `coord-dispatch.nu` role route, not a
`coord-tick.nu` executor — `coord-tick.nu` is untouched.

```sh
SMOLFIRE_FLEET_ENABLE=1 SMOLFIRE_FLEET_HOST=studio@10.0.2.42 ...
```

```toml
# request body for a fleet-* role
task_id        = "task-0042"
tools_required = ["Bash"]            # add "Network" only if the worker declares it
timeout_sec    = 200                 # optional; clamped to 270
[commands]
run = ["uname -a", "make -C /tmp/src"]
[context_pointers]
fleet_target = "studio@10.0.2.42"   # or fleet_user + SMOLFIRE_FLEET_HOST
```

Env: `SMOLFIRE_FLEET_ENABLE` (gate), `SMOLFIRE_FLEET_HOST` (default target),
`SMOLFIRE_FLEET_USER` (for bare-host targets), `SMOLFIRE_FLEET_TIMEOUT`,
`SMOLFIRE_FLEET_SSH` / `SMOLFIRE_FLEET_TIMEOUT_BIN` (binary overrides,
mainly for tests). Refusals (disabled gate, halted, bad/excluded target,
capability, preflight) return `{launched: false, ...}` and append nothing —
the same posture as `dispatch-claude`'s disabled-by-default refusal.

## 6. Tests

`nu tests/coord-fleet-dispatch-test.nu` — 26 cases, all with stub `ssh` /
`timeout` via a PATH shim (spawn-subagent-test pattern); zero live hosts.
Covers target resolution incl. MiSTer refusal, per-host capabilities,
clamp/quoting/argv shape, record parity, envelope parse round-trip,
halt-before-probe, pass/fail/timeout exit codes, the default-OFF gate, and
the enabled dispatch→reply spool append. One live case runs only under
`SMOLFIRE_FLEET_LIVE=1` (preflight + `uname -a` on 7950x4090pop); otherwise it
prints `(skipped: …)` so `run-all.sh` still counts the file as passed.

## 7. Not covered yet

- **Concurrency.** One task at a time per invocation, same as the other
  backends; no worker-side locking if two coordinators share a host.
- **Unknown-host Network.** Conservative refusal is deliberate; per-host
  capability registration (e.g. a `fleet-hosts.toml`) is future work.
- **Stdin.** Commands run via `sh -c` with no stdin forwarding; interactive
  commands fail.
- **`coord-tick.nu` executor selection.** Fleet lives in `coord-dispatch.nu`
  (`fleet-*` roles) only; `SMOLFIRE_EXECUTOR=fleet` is not a thing yet.
- **Host key rotation.** `StrictHostKeyChecking=accept-new` auto-adds first-
  seen keys; rotation surfaces as a preflight failure (exit 2), which is the
  safe direction.
