#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/datadog-notebook-test.nu — notebook render/publish guard for lower-bound runtime research.


def fail [msg: string] {
    print $"datadog-notebook-test: FAIL — ($msg)"
    exit 1
}

let render_check = (^python3 bin/render-datadog-notebook.py --check | complete)
if $render_check.exit_code != 0 { fail $"render check exited ($render_check.exit_code): ($render_check.stderr)($render_check.stdout)" }
if not ($render_check.stdout =~ 'render-datadog-notebook: ok') { fail "render --check did not report success" }

let payload_json = (^python3 bin/render-datadog-notebook.py --stdout | complete)
if $payload_json.exit_code != 0 { fail $"render --stdout exited ($payload_json.exit_code): ($payload_json.stderr)" }
let payload = ($payload_json.stdout | from json)
let text = $payload.data.attributes.cells.0.attributes.definition.text

if $payload.data.attributes.name != 'smolfire — Lower-bound Runtime, Temporal Storage & Lineage' { fail "unexpected notebook title" }
if not ($text =~ 'Canonical Datadog notebook payload: `docs/datadog/smolfire-lower-bound-runtime-notebook.json`') { fail "missing canonical payload marker" }
if not ($text =~ 'https://github.com/ryanmaclean/smolfire/issues/76') { fail "missing tracking issue link" }
if not ($text =~ 'https://github.com/ryanmaclean/smolfire/issues/63') { fail "missing storage-matrix issue link" }
if not ($text =~ 'https://github.com/ryanmaclean/bop/issues/5') { fail "missing BOP issue link" }
if not ($text =~ '## Hardware lower bound') { fail "missing hardware lower-bound section" }
if not ($text =~ '## BOP -> filesystem -> OpenLineage') { fail "missing OpenLineage mapping section" }
if not ($text =~ '### NetBSD rump / rumprun') { fail "missing runtime layer section" }

let dry_run = (^python3 bin/publish-datadog-notebook.py --dry-run --notebook-id 12345 | complete)
if $dry_run.exit_code != 0 { fail $"publish dry-run exited ($dry_run.exit_code): ($dry_run.stderr)($dry_run.stdout)" }
if not ($dry_run.stdout =~ 'PUT https://api.datadoghq.com/api/v1/notebooks/12345') { fail "dry-run did not target the Datadog notebook update endpoint" }
if not ($dry_run.stdout =~ 'https://app.datadoghq.com/notebook/12345') { fail "dry-run did not print the Datadog notebook URL" }

let tmpdir = (^python3 -c 'import tempfile; print(tempfile.mkdtemp())' | str trim)
let tmpdoc = ($tmpdir | path join 'LOWER-BOUND-RUNTIME-2026-09-23.md')
let tmppayload = ($tmpdir | path join 'smolfire-lower-bound-runtime-notebook.json')
cp /home/runner/work/smolfire/smolfire/docs/LOWER-BOUND-RUNTIME-2026-09-23.md $tmpdoc
^python3 bin/render-datadog-notebook.py --doc-path $tmpdoc --payload-path $tmppayload
let record = (^python3 bin/publish-datadog-notebook.py --record-publication --doc-path $tmpdoc --payload-path $tmppayload --notebook-id abc123 --app-site https://app.datadoghq.eu | complete)
if $record.exit_code != 0 { fail $"record-publication exited ($record.exit_code): ($record.stderr)($record.stdout)" }
let updated_doc = (open $tmpdoc)
if not ($updated_doc =~ '> Datadog notebook URL: https://app.datadoghq.eu/notebook/abc123') { fail "record-publication did not update notebook URL" }
if not ($updated_doc =~ '> Datadog notebook ID: `abc123`') { fail "record-publication did not update notebook ID" }
let updated_payload = (open $tmppayload | from json)
if not (($updated_payload.data.attributes.cells.0.attributes.definition.text) =~ 'https://app.datadoghq.eu/notebook/abc123') { fail "record-publication did not regenerate the payload" }

print 'datadog-notebook-test: ok'
