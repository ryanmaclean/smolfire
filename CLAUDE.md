# smolfire (formerly smolBSD) Coordinator — Claude Code Context

> **Rename note**: the project renamed smolBSD → **smolfire** ("smolBSD"
> belongs to the unaffiliated NetBSDfr/smolBSD NetBSD micro-VM project).
> The rename is complete (issue #41): repo name, `@smolfire.local` spool
> addressing, `bin/smolfire.nu` CLI (old `bin/smolbsd.nu` shim removed
> in #41), kernconfs (`SMOLFIRE` = microVM, `SMOLFIRE-VM` = full VM,
> `SMOLFIRE-PI5`/`-RK3588` = boards), `smolfire-*.conf` release confs,
> `CLOUDWARE=smolfire` (→ `SMOLFIRECONF`, `smolfire.ufs.qcow2`),
> `SMOLFIRE_*` env vars, and guest identity (hostname/password
> `smolfire`). Historical docs, `plans/`, `.planning/`, and self-hosted
> runner paths (`/home/studio/smolbsd-*`) intentionally keep old names.

## 1. What this is

**The smolfire coordinator** is a Nushell mbox+TOML multi-agent finite-state machine (FSM) for building and maintaining a minimal FreeBSD VM. The coordinator manages a set of agents that collaborate via a mailbox spool, advancing through FSM states (idle → dispatching → waiting → harvesting → halted) on each tick.

## 2. Key files

| Path | Purpose |
|---|---|
| `bin/coord-tick.nu` | One FSM tick — advances state through idle/dispatching/waiting/harvesting/halted |
| `bin/mbox-parse.nu` | mbox+TOML parser — reads and writes messages in the spool |
| `bin/coord-run.sh` | Loop runner — **run this to operate the coordinator** |
| `var/mail/spool` | The mbox spool (messages between coordinator and agents) |
| `var/run/coord-state.toml` | Persisted FSM state (survives restarts) |
| `tests/` | Nu unit and integration tests |
| `bin/build-smolfire-vm.nu` | Image build pipeline — see `docs/BUILDING.md`; release image goes via `cloudware-release` + `SMOLFIRECONF` (FIX-9), never `vm-image ... CLOUDWARE_CONF` |
| `docs/UR-BSD-VERIFY.md` | Verified findings + assumptions ledger for the build/image work — read before changing kernconfs, release confs, or build invocations |

## 3. How to run

Run the coordinator loop from the repo root:

```sh
sh bin/coord-run.sh
```

Optional environment variables:

| Variable | Default | Description |
|---|---|---|
| `ROOT` | `.` | Repo root |
| `INTERVAL` | `60` | Seconds between normal ticks |
| `HALT_INTERVAL` | `10` | Seconds to sleep while halted |
| `STATE_FILE` | `var/run/coord-state.toml` | FSM state file |
| `SPOOL` | `var/mail/spool` | mbox spool path |
| `SMOLFIRE_CLAUDE_MODEL` | `claude-sonnet-5` | Claude model for subagent dispatch |
| `SMOLFIRE_EXECUTOR` | `vm` | `vm` or `jail` (experimental, FreeBSD only — see `docs/JAIL-EXECUTOR.md`) |
| `SMOLFIRE_SPAWN_SUBAGENT` | unset (disabled) | Billed-subprocess guard: must be set to exactly `1` to allow `coord-tick.nu`/`coord-dispatch.nu` to actually launch a real `claude` CLI subagent (`--max-budget-usd 1.0`, real API spend). Unset (the default, and the required setting for every test and CI run) makes spawning a no-op that logs `subagent_spawn_skipped` instead. |
| `SMOLFIRE_SUBAGENT_CMD` | `claude` | Overrides the binary name/path resolved and launched as the subagent CLI. Tests use this to point at a harmless stub instead of relying solely on PATH ordering/stripping to keep a real `claude` from being resolved. |

Run a single tick manually:

```sh
nu bin/coord-tick.nu
```

## 4. How to test

```sh
nu tests/mbox-parse-test.nu
nu tests/coord-tick-test.nu
```

Or run all tests at once:

```sh
sh tests/run-all.sh
```

**Billed-subprocess guard:** `coord-tick.nu`/`coord-dispatch.nu` only ever
launch a real `claude` CLI subagent (real API spend, `--max-budget-usd 1.0`)
when `SMOLFIRE_SPAWN_SUBAGENT=1` is explicitly exported — see the env var
table above. Every test in this repo relies on that default-off behavior
and must NOT set it. If your shell profile happens to export
`SMOLFIRE_SPAWN_SUBAGENT=1` globally, unset it before running tests:
`hide-env SMOLFIRE_SPAWN_SUBAGENT` (nu) or `unset SMOLFIRE_SPAWN_SUBAGENT` (sh).

As defense-in-depth beyond that default, some integration tests also strip
PATH down to directories that don't contain a real `claude`/`codex`/
`opencode`/`ollama` binary. Do this by checking actual binary existence per
directory, never a `grep -v claude`-style string match on the directory
*name* — a real install directory such as `/opt/homebrew/bin` or
`~/.local/bin` doesn't contain the substring "claude" and survives that
filter untouched even though the binary lives inside it:

```sh
# WRONG — leaves /opt/homebrew/bin (and any other dir whose NAME doesn't
# contain "claude") on PATH even if a real claude binary lives there:
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v claude | paste -sd: -)

# RIGHT — drops any directory that actually resolves one of these binaries:
PATH=$(IFS=':'; safe=""; for d in $PATH; do
  skip=0
  for bin in claude codex opencode ollama; do
    [ -x "$d/$bin" ] && skip=1 && break
  done
  [ "$skip" = 0 ] && safe="${safe:+$safe:}$d"
done; echo "$safe")
```

## 5. Key spec

`docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md`

Critical sections:
- **§12** — FSM state machine definition
- **§13** — HALT/escalation protocol
- **§17** — Capability check logic
- **D2** — Retry policy

## 6. Spool protocol

- Messages are standard mbox format with TOML bodies.
- `verdict` field must be one of: `pass`, `fail`, `blocked`.
- When `attestation_required = true`, the message body must include one or more `[[claims]]` blocks.
- `tools_required` is checked against `AGENT_CAPABILITIES` defined in `bin/coord-tick.nu`.

## 7. HALT flow

- **Per-task halt**: `var/mail/HALT.<task_id>` — coordinator pauses that task only.
- **Resume**: send a message with `X-Resume-Action: retry | abort | edit` in the spool.
- **Global emergency stop**: create `var/mail/HALT` (no suffix) — `coord-run.sh` detects this and skips invoking `coord-tick.nu`, sleeping `HALT_INTERVAL` seconds instead.
- Remove `var/mail/HALT` to resume normal operation.

## 8. Branch

Development happens on short-lived `claude/*` feature branches merged to `main` via PR — check `git branch --show-current`; do not assume a fixed branch name.

## 9. Security — install hooks after clone

After cloning, install the pre-push guard that prevents `var/mail/spool` data from reaching public remotes:

```sh
nu bin/setup-hooks.nu
```

This installs `.git/hooks/pre-push` which scans the spool for public IPs and instance UUIDs before any push.

**Never commit `var/mail/spool`** — it contains live IPs, instance UUIDs, and credential references. It is gitignored, but force-adds (`git add -f`) are blocked by the hook.

**Never commit internal hostnames or private IPs** — use placeholders (`<kvm-host>`, `<internal-ip>`, …) in docs, and env vars (`JUMP_HOST`, `SMOLFIRE_SSH_JUMP`, `SMOLFIRE_IRC_HOST`, `AMD64_REMOTE`, …) for site-specific values in scripts.

## 10. License

Apache-2.0
