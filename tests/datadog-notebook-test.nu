#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/datadog-notebook-test.nu — notebook render guard for lower-bound runtime research.
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

print 'datadog-notebook-test: ok'
