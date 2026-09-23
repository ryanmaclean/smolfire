#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# render-datadog-notebook.nu — render the canonical lower-bound runtime
# Markdown doc into a Datadog Notebooks API create/update payload.
#
# AX-first: prints exactly one `{schema_version, action, method, endpoint,
# notebook_id, notebook_url, status}` JSON record on every run (unless
# --stdout is used to emit the raw payload for piping).

const NOTEBOOK_NAME = "smolFire — Lower-bound Runtime, Temporal Storage & Lineage"

def repo-root [] {
    $env.FILE_PWD | path dirname
}

def default-doc-path [] {
    (repo-root) | path join "docs" "LOWER-BOUND-RUNTIME-2026-09-23.md"
}

def default-payload-path [] {
    (repo-root) | path join "docs" "datadog" "smolfire-lower-bound-runtime-notebook.json"
}

# Build the Datadog notebook payload record from the markdown doc text.
export def build-payload [doc_text: string] {
    {
        data: {
            type: "notebooks"
            attributes: {
                name: $NOTEBOOK_NAME
                status: "published"
                time: { live_span: "1w" }
                cells: [
                    {
                        type: "notebook_cells"
                        attributes: {
                            definition: {
                                type: "markdown"
                                text: $doc_text
                            }
                        }
                    }
                ]
            }
        }
    }
}

# Render the payload for a given doc path, returned as a JSON string
# (2-space indent, trailing newline) matching the checked-in file format.
export def render-payload [doc_path: path] {
    let doc_text = (open --raw $doc_path)
    (build-payload $doc_text) | to json --indent 2
}

def emit-status [action: string, method: any, endpoint: any, status: string] {
    {
        schema_version: "v1"
        action: $action
        method: $method
        endpoint: $endpoint
        notebook_id: null
        notebook_url: null
        status: $status
    } | to json --indent 0
}

def main [
    --doc-path: path                # path to the canonical markdown doc
    --payload-path: path            # path to the checked-in JSON payload
    --stdout (-s)                   # write the rendered payload JSON to stdout instead of a status record
    --check (-c)                    # exit non-zero when the checked-in payload is stale
] {
    let doc = if $doc_path == null { default-doc-path } else { $doc_path }
    let payload_path_resolved = if $payload_path == null { default-payload-path } else { $payload_path }

    let rendered = (render-payload $doc) | str trim
    let rendered_with_newline = $"($rendered)\n"

    if $check {
        if not ($payload_path_resolved | path exists) {
            print -e $"render-datadog-notebook: FAIL — ($payload_path_resolved) does not exist"
            print (emit-status "render" null null "error")
            exit 1
        }
        let current = (open --raw $payload_path_resolved)
        if ($current | str trim) != $rendered {
            print -e $"render-datadog-notebook: FAIL — ($payload_path_resolved) is out of sync with ($doc)"
            print (emit-status "render" null null "drift")
            exit 1
        }
        print (emit-status "render" null null "ok")
        return
    }

    if $stdout {
        print -n $rendered_with_newline
        return
    }

    $rendered_with_newline | save --force $payload_path_resolved
    print (emit-status "render" null null "ok")
}
