# Inspecting Datadog Notebooks with `pup` (read-only)

`bin/dd-notebooks.nu` wraps the Datadog CLI [`pup`](https://github.com/DataDog/pup)
(pinned **v1.24.0**, released 2026-10-02) so the smolfire lower-bound notebook
payload in this repo can be compared with whatever exists in a Datadog org.
It is **read-only by construction** and writes nothing to Datadog.

> **Validation status: offline only.** The session that wrote this had no
> Datadog credentials. Everything below was exercised against stub `pup`
> executables (`tests/dd-notebooks-test.nu`) and against the real v1.24.0
> binary only for `--version`, `auth status` and the no-credentials failure
> path. Nothing was ever run against a live org. See "What is not confirmed".

## Facts established so far

- The notebook **was never published.** Issue ryanmaclean/smolfire #76 was
  closed `not_planned` on 2026-09-24, pending an org decision and a
  `notebooks_write` credential. The expected first `audit` result is therefore
  `absent`.
- The committed payload `docs/datadog/smolfire-lower-bound-runtime-notebook.json`
  has **stale cell text**: it lacks the 0.5.0 image facts, and does not carry
  the boot-time result after the guest-side TSC-from-pvclock patch (release
  wall-clock median 476 ms -> 240 ms, run 35956015747, 2026-09-24; see
  `docs/BOOT-TIME-ROADMAP.md`, which also notes part of that drop is a faster
  host).
- `docs/datadog/smolfire-lower-bound-runtime-notebook.proposed.json` is the
  refreshed payload (240 ms median, 0.5.0 image figures, updated open-work
  list). It carries one wording correction against the first draft: the 511 ms
  Firecracker / 569 ms QEMU-microvm figures are attributed to the 2026-07-29
  validation run 30409991192 (as recorded in `docs/UR-BSD-VERIFY.md`), not to
  "release 0.4.0". Its issue-state line says states were not verified. Review
  it before anyone publishes it; publishing is out of scope here.

## Supplying credentials safely

pup accepts, in precedence order: `DD_ACCESS_TOKEN`, a stored OAuth session
(`pup auth login` is browser-only; there is no headless flow, so it is not
usable in cloud sessions), or `DD_API_KEY` + `DD_APP_KEY` (+ `DD_SITE`, default
`datadoghq.com`).

For this repo use the API/app key pair:

1. In Datadog, create an **application key restricted to read scopes**
   (notebooks read) and an API key, ideally on a dedicated service account.
   Never use write-capable keys for this tool.
2. Store them as environment variables **in the cloud environment settings**
   (the secrets/environment-variables panel of the Claude Code environment):
   `DD_API_KEY`, `DD_APP_KEY`, and `DD_SITE` (for example `datadoghq.eu` if
   the org is not on the US1 site).
3. **Never** paste keys in chat, issues, PRs, commit messages or any file in
   the repo. The script never prints a `DD_*` value; `status` reports only
   booleans, and all pup error output is redacted (values of every `DD_*`
   variable plus bearer/JWT/32-/40-hex/`api_key=...` shapes).

## Installing pup (the script never installs it)

```sh
v=1.24.0
base=https://github.com/DataDog/pup/releases/download/v$v
curl -fsSLO $base/pup_${v}_Linux_x86_64.tar.gz
curl -fsSLO $base/pup_${v}_checksums.txt
grep " pup_${v}_Linux_x86_64.tar.gz\$" pup_${v}_checksums.txt | sha256sum -c -   # must print OK
tar -xzf pup_${v}_Linux_x86_64.tar.gz pup && install -m 0755 pup ~/.local/bin/pup
```

For v1.24.0 the checksums file lists
`bf6387ce33deee3bf2b8fbb72ec32387cd6a52ac9ce19f4fdaadc85c2c4b3b18` for the
`Linux_x86_64` tarball; the copy used while writing this verified `OK`. Other
platforms: `Linux_arm64`, `Darwin_arm64`, `Darwin_x86_64`.

The binary is resolved from `PUP_BIN` (a file path) or `PATH`; if neither
yields one the script exits 2 with the above instructions.

## Commands

```sh
nu bin/dd-notebooks.nu status                    # pup version, which credentials exist (booleans), usable?
nu bin/dd-notebooks.nu list [--filter smolfire] [--limit 100]
nu bin/dd-notebooks.nu get 12345                 # numeric notebook id
nu bin/dd-notebooks.nu audit [--strict] [--committed F] [--proposed F] [--filter S]
nu bin/dd-notebooks.nu pup notebooks search --query smolfire   # allowlisted passthrough
```

Exit codes: `0` ok; `1` `audit --strict` and overall is not `in-sync`; `2`
usage error, refusal, or pup missing; `3` credentials unusable or a pup call
failed (output is still a JSON report where one exists).

### Read-only allowlist

The single place pup is executed (`run-pup`) first passes the argument vector
through `validate-argv`. Permitted, with a fixed flag set each:

| pup invocation | flags allowed |
|---|---|
| `--version` | none |
| `auth status` | none |
| `notebooks search` (alias `list`) | `--query --limit(1..1000) --filter --sort` |
| `notebooks get <numeric id>` | none |

Everything else (`create`, `update`, `edit`, `delete`, `diff`, `images`,
`annotations`, `auth login/logout/token`, `--file`, `--yes`, `--markdown`,
other domains) is refused with exit 2 **before any process is spawned**.
`tests/dd-notebooks-test.nu` proves this by checking a stub is never invoked,
and a mutation test proves that removing the gate makes the same call reach
the stub. pup is always run with `--no-agent --output json` so output is the
raw payload, as pup's own scripting guidance recommends.

## What `audit` checks

1. Loads the committed payload and, if present, the proposed one (name,
   status, `time.live_span`, cell types and text; sha256 of each file).
2. Always reports `committed_vs_proposed` (offline).
3. With usable credentials, searches the org (`notebooks search --query
   smolfire`) and finds live notebooks whose **name** equals each payload's
   name (case/whitespace-insensitive), then `get`s each match and diffs name,
   status, live span, cell count, per-cell type and per-cell text (line sets,
   `only_in_local` / `only_in_live`, capped).
4. Per file the state is `absent`, `in-sync`, `drift` or `ambiguous` (several
   live notebooks share the name). `overall` is derived from the **committed**
   payload; the proposed file is informational. If any search items cannot be
   parsed and nothing matched, `overall` is `unverifiable` rather than `absent`.
5. Other notebooks matching the filter are listed (`same_filter_other_names`).

Expected today: `absent`. After someone publishes the proposed payload with
write credentials (not this tool): committed `drift`, proposed `in-sync`.

## What is not confirmed

- **Search response shape.** pup's own help says the shape is "not published".
  From `src/commands/notebooks.rs` it prints `{"data": [...], "meta": {...}}`
  from `GET /api/v2/notebooks/search`. The script reads `id`/`name` under
  `.attributes` or top level and **counts** items it cannot read instead of
  dropping them. Stub fixtures use the JSON:API-like guess.
- **`get` shape.** Taken as the v1 `NotebookResponse`
  (`data.id`, `data.attributes.{name,status,time,cells[]}`), matching the
  committed create payload. Not seen live.
- Whether API-key auth (without OAuth scopes) can call the search endpoint for
  a given org/key, and whether a notebook's cell text round-trips byte for byte
  (the audit normalises CRLF and trailing whitespace only).
- `--no-agent` removes the agent-mode `{status,data,metadata}` envelope; the
  script also unwraps it defensively if it appears.
- `auth status` behaviour with a stored OAuth session was read from pup's source,
  not exercised.

## Tests

```sh
nu tests/dd-notebooks-test.nu </dev/null
```

Runs offline in CI (stub `pup` on `PUP_BIN`; no network, no Datadog).

## What the tool redacts (and what it does not)

Error output (pup's stderr and every failure message) passes through a redactor:
the literal value of every `DD_*` environment variable, bearer tokens, JWTs,
32/40-hex strings, Datadog-prefixed token shapes (`ddo_...`) and any
`key|token|secret|password = value` assignment. **pup's normal stdout (`get`,
the `pup` passthrough) is printed as received**: it is notebook content, which is
user data and can itself contain sensitive text. Do not pipe it into places you
would not put the notebook itself.
