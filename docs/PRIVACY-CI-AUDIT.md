# Privacy & CI Audit — 2026-05-16

## Privacy Backstop

### VERDICT: LEAKED

The `var/mail/spool` file was committed to the public GitHub remote (`origin`) before the gitignore entry was added. Public IPs, Tailscale IPs, and Vultr instance UUIDs are permanently in `origin/main` history.

---

**1. Is `var/mail/spool` gitignored?**

Yes — correctly and thoroughly. `.gitignore` lines 5–7 (with comment at line 5):

```
var/mail/spool
var/mail/spool.*
var/mail/*.lock
```

`git check-ignore -v var/mail/spool` confirms: `.gitignore:6:var/mail/spool`.

---

**2. Is `bin/pre-push-check.nu` wired into any hook?**

No. It is an unhooked script. `.git/hooks/` contains only `.sample` files — no active `pre-push` hook exists. `.githooks/` does not exist. There is a `.jj/` directory (colocated jj repo), but no hooks wired there either.

What `pre-push-check.nu` checks (3 bullets):
- Scans every line of `var/mail/spool` for public IPv4 addresses (excluding RFC1918 ranges) and reports `line N: possible public IP`.
- Scans for UUID patterns (`[0-9a-f]{8}-...-[0-9a-f]{12}`) and reports `line N: possible UUID/instance-id`.
- Scans for `api.key = <20+ char value>` patterns and reports `line N: possible API key`.

Since this script is never called automatically, it provides zero protection in practice.

---

**3. Has the live spool leaked to the public remote?**

Yes. The spool was committed to git before the gitignore entry was added (commit `1e5cee9` is titled `sec: gitignore spool, add pre-push-check.nu redaction linter` — the gitignore was added in that commit, but prior commits already had spool content). All spool-containing commits are reachable from `origin/main`.

Confirmed sensitive content in `origin/main` git history (`git log origin/main -p -- var/mail/spool`):

| Type | Value | Context |
|---|---|---|
| Public IP | `REDACTED-VULTR-PUBLIC-IP-1` | Vultr amd64 buildworld host, multiple SSH harvest commands |
| Public IP | `REDACTED-VULTR-PUBLIC-IP-2` | Vultr instance (connection refused attempts logged) |
| Tailscale IP | `REDACTED-TAILSCALE-IP-1` | SSH jump host in harvest commands |
| Tailscale IP | `REDACTED-TAILSCALE-IP-2` | `<internal-host>` jump host (matches CLAUDE.md fleet topology) |
| Vultr UUID | `REDACTED-VULTR-UUID-1` | Active Vultr instance; `terminate_cmd` also present |
| Vultr UUID | `REDACTED-VULTR-UUID-2` | Second Vultr instance ID |
| SSH key UUID | `REDACTED-VULTR-SSH-KEY-UUID` | `<ssh-key-name>` Vultr SSH key ID |

The current live spool (`var/mail/spool`, on disk but gitignored) contains 43 IP matches. The git history contains 189 occurrences of `10.0.x` addresses plus the public IPs above.

---

**Recommended fixes (ranked)**

1. **IMMEDIATE: Rotate/destroy the leaked Vultr instances and SSH keys.** Instance `REDACTED-VULTR-UUID-1` has a `terminate_cmd` in the spool. Verify both instance IDs are terminated and the SSH key `REDACTED-VULTR-SSH-KEY-UUID-PREFIX` is removed from Vultr.

2. **HIGH: Rewrite git history to remove `var/mail/spool` from all commits** (BFG Repo Cleaner or `git filter-repo --path var/mail/spool --invert-paths`), then force-push to `origin`. This is a public repo — the spool content is indexed by GitHub and potentially cached by crawlers.

3. **HIGH: Wire `pre-push-check.nu` as an actual git hook.** Add `.git/hooks/pre-push` containing `nu bin/pre-push-check.nu` (mode 0755). Document this setup step in CLAUDE.md or a `make install-hooks` target so it survives fresh clones.

4. **MEDIUM: Add `var/mail/` (the whole directory) to `.gitignore`**, not just individual spool patterns — defense-in-depth against new spool variants.

5. **LOW: Add a CI step that asserts `var/mail/spool` is absent from the git tree** (`git ls-tree -r HEAD --name-only | grep -c var/mail/spool` should be 0).

---

## CI Status

### VERDICT: QUEUED (not yet confirmed green/red; all runs currently queued)

---

**Workflows found**

| Path | Triggers |
|---|---|
| `.github/workflows/ci.yml` | `push` (all branches), `pull_request`, `workflow_dispatch` |

No `.gitea/workflows/`, no `.circleci/`, no `.gitlab-ci.yml`.

There is also a separate "TPM VM Smoke Test" workflow visible in `gh run list` output — but only `ci.yml` exists on disk. This workflow may be defined on a branch not checked out locally, or may be defined elsewhere. All five recent runs shown by `gh run list --limit 5` are in `queued` state (two `in_progress`), so no confirmed green or red result is available at audit time.

---

**Jobs in `ci.yml`**

`nu-tests` (matrix: `ubuntu-latest`, `macos-latest`):
- `mbox-parse-test.nu` — unit tests for mbox parser (run from `tests/`)
- `coord-tick-test.nu` — integration tests, spawns `nu bin/coord-tick.nu`
- `spawn-subagent-test.nu`
- `spool-archive-test.nu`
- `spool-tail-test.nu`
- `spool-compact-test.nu`
- `nu tests/run-tests.nu --suite unit` — orchestrator that includes `coord-fsm-tests.nu` and `coord-escalate-test.nu` via `use` imports (confirmed at `run-tests.nu:12-13, 203-204`)
- `tpm-seal-test.nu --dry-run` — skips if `tpm2-tools` absent
- `bhyve-tpm-pcr-verify.nu --dry-run`

`shellcheck` (`ubuntu-latest`):
- Lints `bin/coord-run.sh`, `tests/run-all.sh`, `bin/analyze-image.sh`, `bin/harvest.sh`, plus two `release/tools/` conf files.

`conf-hook-test` (`ubuntu-latest`):
- Smoke-tests `vm_extra_pre_umount` trim logic from `release/tools/smolfire-qemu.conf`, including the empty-`DESTDIR` guard.

---

**Test coverage: CI vs local `tests/`**

Tests in `tests/` not explicitly run by CI (not covered by `run-tests.nu --suite unit` or direct invocation):

| File | Status |
|---|---|
| `coord-vm-e2e-tests.nu` | Intentionally excluded (requires qcow2) — no stale ref risk |
| `run-all-vm-tests.nu` | VM-only, excluded |
| `smolfire-test-report.nu` | Reporting helper, not a test runner |
| `sd-write.nu` | Hardware (SD card write), excluded |
| `*.exp` (8 Expect scripts) | Hardware/VM timing tests, excluded |

`coord-escalate-test.nu` is covered — it is imported by `run-tests.nu` at line 13 and executed at line 204. No stale references found.

---

**Where results land**

- GitHub Checks (via `origin` at `https://github.com/ryanmaclean/smolBSD.git`) — triggered on `push` and `pull_request`.
- Gitea (`http://localhost:3001/studio/smolBSD.git`) has no `.gitea/workflows/` directory; no Gitea Actions runner is configured for this repo.

---

**Has CI ever been green?**

Unknown from this audit. All five runs visible via `gh run list` at audit time are `queued` or `in_progress`. No completed (success/failure) run was available to inspect.

---

**Recommended fixes (ranked)**

1. **HIGH: Confirm CI actually passes.** Current runs are all queued. Once the queue clears, check `gh run list --limit 5` again and resolve any failures before merging to `main`.

2. **MEDIUM: Add a `coord-escalate-test.nu` direct step** in addition to the `run-tests.nu --suite unit` invocation, to make coverage explicit and catch any future exclusion from the suite runner.

3. **LOW: Add a Gitea Actions runner** if local CI is desired (the `gitea` remote is wired). See the `gitea-runner` skill.

4. **LOW: Add a `tests-exist` step** that asserts every `tests/*.nu` file (excluding `run-*.nu` and `*-report.nu`) is either invoked directly or covered by a suite, to prevent silent coverage drift.
