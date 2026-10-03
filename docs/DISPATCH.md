# Workflow dispatcher

`.github/workflows/dispatch.yml` is the permanent replacement for the
"temporary self-triggering push workflow" pattern (a throwaway workflow added
only to get a `workflow_dispatch` fired, then retired in a follow-up commit).

## Why it exists

The session/MCP token cannot call `workflow_dispatch` (HTTP 403). A workflow's
own `GITHUB_TOKEN` with `actions: write` can; this is the documented exception
to the "GITHUB_TOKEN events do not trigger workflows" rule, and it is proven in
this repo (the release/refresh one-shots dispatched `build-image-hosted.yml`).
The dispatcher packages that exception once, with validation, so no more
one-off workflows are needed.

## Usage

1. Create a request (validates it locally with the same code CI uses):

   ```sh
   nu bin/dispatch-request.nu new --workflow build-image-hosted.yml \
       --ref claude/my-branch --watch --timeout 240 arch=aarch64 kernel_only=true
   ```

   Inputs are trailing `key=value` words. The file lands in
   `.github/dispatch/<timestamp>-<workflow>.json` (override with `--name`).
2. Commit it and push the branch (`claude/**` only). The push triggers
   "Dispatch request".
3. The run log and step summary print `Run URL: https://github.com/<repo>/actions/runs/<id>`.
   With `"watch": true` the job waits (up to `timeout_minutes`, max 360) and
   fails if the dispatched run does not conclude `success`.

Humans can also run "Dispatch request" via `workflow_dispatch` and paste the
request JSON. Validate any file offline with
`nu bin/dispatch-request.nu validate <file>`.

Request format:

| key | required | rule |
|---|---|---|
| `workflow` | yes | exactly one of `build-image-hosted.yml`, `smolfire.yml`, `tpm-hosted.yml` |
| `ref` | yes | branch name of this repo (`[A-Za-z0-9._/-]`, no `..`, no `refs/` prefix); must exist |
| `inputs` | no | every key declared under `on.workflow_dispatch.inputs` of the target at `ref`; `required` inputs without default must be present; `choice` must be an option; `boolean` true/false; `number` digits; strings `[A-Za-z0-9._:/@+=,-]{0,128}`; `environment` type unsupported; max 25 |
| `watch` | no | boolean, default false |
| `timeout_minutes` | no | 1..360, default 60 (only used with `watch`) |
| `requested_at` | no | timestamp string; `new` sets it so re-requests change the file |

Anything else (unknown keys, other workflows including `dispatch.yml` itself)
is rejected with a `dispatch-request: REJECTED — ...` error.

Notes:

* A push is processed only if its head commit adds/modifies **exactly one**
  `.github/dispatch/*.json`. Deleting a request does not trigger anything.
* Re-running the job re-dispatches. Change the file (new `requested_at`) to
  request again.
* The dispatch API returns no run id; the job snapshots the newest run id of
  the target workflow, dispatches, then polls (2 min) for a newer
  `workflow_dispatch` run on that ref. Two simultaneous dispatches of the same
  workflow on the same ref from elsewhere can in principle be confused; the
  per-branch `concurrency` group serializes requests from this workflow.
* Inputs are validated against the target's YAML **at the requested ref**, so
  an input added on a branch is dispatchable from that branch.

## How it is hardened

* Triggers: `push` on `claude/**` limited to `.github/dispatch/*.json`, plus
  `workflow_dispatch`.
* `permissions:` is exactly `actions: write` + `contents: read` (asserted by
  `tests/dispatch-request-test.nu`).
* The validator is checked out from the **default branch** (`trusted/`) and is
  the only code that touches request data. The pushed commit and the target ref
  are checked out with `persist-credentials: false` and read only as data.
* No `run:` block contains `${{ }}`; GitHub context values go through `env:` or
  `with:`. Request fields are parsed with `from json`, validated, then handed
  to `gh` as argv elements or as the JSON body of
  `gh api --method POST repos/<repo>/actions/workflows/<file>/dispatches --input -`.
  No shell ever sees them.
* Allowlisted workflows only, inputs checked against the parsed target YAML,
  restrictive value charset, ref must resolve to an existing branch
  (`git/ref/heads/<ref>`), per-branch concurrency.

## Threat model: what a malicious pushed request file can and cannot do

Can:

* Cause one of the three allowlisted workflows to run on any existing branch of
  this repo, with any input values those workflows declare and accept. That
  consumes runner minutes (a full image build is hours) and can overwrite
  artifacts of that run. Anyone with push access to a `claude/**` branch could
  already do this through the Actions UI.
* Make the dispatcher job wait up to 6 h (`watch`).

Cannot:

* Run arbitrary commands in the dispatcher: values are data and never reach a
  shell; the code that parses them comes from the default branch.
* Dispatch any other workflow (release publishing, `dispatch.yml` itself),
  pass undeclared inputs, or use odd characters in inputs or refs.
* Read secrets or write repo contents: the token is `actions: write` +
  `contents: read`, and the dispatcher job has no secrets.
* Chain itself: `dispatch.yml` is not in the allowlist, and workflows dispatched
  via `GITHUB_TOKEN` do not themselves trigger `push` events.

Residual risk (be explicit): GitHub runs a workflow file as it exists at the
pushed commit, so a writer can push a **modified `dispatch.yml`** that skips
validation and use the `actions: write` token directly. This is inherent to
Actions (any writer can also edit any other workflow) and is not stopped by
this design; the boundary is repo write access. Mitigations outside this file:
branch protection/rulesets on `main`, restricting who can push `claude/**`,
and not putting secrets in the target workflows that a rogue dispatch could
exfiltrate. The target workflows' own security (e.g. `tpm-hosted.yml` validates
`run_id`) still applies.

## Retiring this

Delete `dispatch.yml`, `bin/dispatch-request.nu`, `tests/dispatch-request-test.nu`
and `.github/dispatch/`. Nothing else depends on them.
