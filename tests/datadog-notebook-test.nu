#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/datadog-notebook-test.nu — notebook render/publish guard for lower-bound runtime research.
#
# Resolves the repo root relative to this test file (not a hardcoded CI
# runner path) so it passes locally from any cwd and on any runner.

def repo-root [] {
    $env.FILE_PWD | path dirname
}

def fail [msg: string] {
    print $"datadog-notebook-test: FAIL — ($msg)"
    exit 1
}

let root = (repo-root)
let render_bin = ($root | path join "bin" "render-datadog-notebook.nu")
let publish_bin = ($root | path join "bin" "publish-datadog-notebook.nu")
let doc_path = ($root | path join "docs" "LOWER-BOUND-RUNTIME-2026-09-23.md")

let render_check = (^nu $render_bin --check | complete)
if $render_check.exit_code != 0 { fail $"render --check exited ($render_check.exit_code): ($render_check.stderr)($render_check.stdout)" }
if not ($render_check.stdout =~ '"status": "ok"') { fail "render --check did not report ok status" }

let payload_out = (^nu $render_bin --stdout | complete)
if $payload_out.exit_code != 0 { fail $"render --stdout exited ($payload_out.exit_code): ($payload_out.stderr)" }
let payload = ($payload_out.stdout | from json)
let text = $payload.data.attributes.cells.0.attributes.definition.text

if $payload.data.attributes.name != 'smolFire — Lower-bound Runtime, Temporal Storage & Lineage' { fail "unexpected notebook title" }
if not ($text =~ 'Canonical Datadog notebook payload: `docs/datadog/smolfire-lower-bound-runtime-notebook.json`') { fail "missing canonical payload marker" }
if not ($text =~ 'https://github.com/ryanmaclean/smolfire/issues/76') { fail "missing tracking issue link" }
if not ($text =~ '## Hardware lower bound') { fail "missing hardware lower-bound section" }
if not ($text =~ '## BOP -> filesystem -> OpenLineage') { fail "missing OpenLineage mapping section" }
if not ($text =~ '### NetBSD rump / rumprun') { fail "missing runtime layer section" }

let dry_run = (^nu $publish_bin --dry-run --notebook-id 12345 | complete)
if $dry_run.exit_code != 0 { fail $"publish dry-run exited ($dry_run.exit_code): ($dry_run.stderr)($dry_run.stdout)" }
if not ($dry_run.stdout =~ 'PUT https://api.datadoghq.com/api/v1/notebooks/12345') { fail "dry-run did not target the Datadog notebook update endpoint" }
if not ($dry_run.stdout =~ 'https://app.datadoghq.com/notebook/12345') { fail "dry-run did not print the Datadog notebook URL" }
if not ($dry_run.stdout =~ '"status": "dry-run"') { fail "dry-run did not emit the machine-readable status record" }

# publish without credentials must fail closed and never touch the network
with-env {DD_API_KEY: "", DD_APP_KEY: ""} {
    let no_creds = (^nu $publish_bin --notebook-id 12345 | complete)
    if $no_creds.exit_code == 0 { fail "publish without DD_API_KEY/DD_APP_KEY unexpectedly succeeded" }
    if not ($no_creds.stderr =~ 'DD_API_KEY and DD_APP_KEY must be set') { fail "missing credential-guard error message" }
}

let tmpdir = (mktemp -d)
let tmpdoc = ($tmpdir | path join 'LOWER-BOUND-RUNTIME-2026-09-23.md')
let tmppayload = ($tmpdir | path join 'smolfire-lower-bound-runtime-notebook.json')
cp $doc_path $tmpdoc
^nu $render_bin --doc-path $tmpdoc --payload-path $tmppayload
let record = (^nu $publish_bin --record-publication --doc-path $tmpdoc --payload-path $tmppayload --notebook-id abc123 --app-site https://app.datadoghq.eu | complete)
if $record.exit_code != 0 { fail $"record-publication exited ($record.exit_code): ($record.stderr)($record.stdout)" }
let updated_doc = (open --raw $tmpdoc)
if not ($updated_doc =~ '> Datadog notebook URL: https://app.datadoghq.eu/notebook/abc123') { fail "record-publication did not update notebook URL" }
if not ($updated_doc =~ '> Datadog notebook ID: `abc123`') { fail "record-publication did not update notebook ID" }
let updated_payload = (open $tmppayload)
if not (($updated_payload.data.attributes.cells.0.attributes.definition.text) =~ 'https://app.datadoghq.eu/notebook/abc123') { fail "record-publication did not regenerate the payload" }
rm -rf $tmpdir

print 'datadog-notebook-test: ok'
