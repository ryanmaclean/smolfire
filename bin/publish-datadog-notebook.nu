#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# publish-datadog-notebook.nu — idempotent upsert of the canonical lower-bound
# runtime notebook into Datadog (POST once to create, PUT by id thereafter),
# and record the published notebook id/url back into the markdown doc.
#
# Credentials come ONLY from environment variables — never CLI args, never
# printed (not even partially): $env.DD_API_KEY / $env.DD_APP_KEY.
#
# AX-first: prints exactly one JSON record per run:
#   {schema_version, action, method, endpoint, notebook_id, notebook_url, status}

use render-datadog-notebook.nu ["build-payload" "render-payload"]

const DEFAULT_API_SITE = "https://api.datadoghq.com"
const DEFAULT_APP_SITE = "https://app.datadoghq.com"

def repo-root [] {
    $env.FILE_PWD | path dirname
}

def default-doc-path [] {
    (repo-root) | path join "docs" "LOWER-BOUND-RUNTIME-2026-09-23.md"
}

def default-payload-path [] {
    (repo-root) | path join "docs" "datadog" "smolfire-lower-bound-runtime-notebook.json"
}

def normalize-site [url: string] {
    let trimmed = ($url | str trim --right --char '/')
    if ($trimmed | str starts-with "http://") or ($trimmed | str starts-with "https://") {
        $trimmed
    } else {
        $"https://($trimmed)"
    }
}

def notebook-url [app_site: string, notebook_id: string] {
    $"(normalize-site $app_site)/notebook/($notebook_id)"
}

def emit [action: string, method: any, endpoint: any, notebook_id: any, notebook_url: any, status: string] {
    {
        schema_version: "v1"
        action: $action
        method: $method
        endpoint: $endpoint
        notebook_id: $notebook_id
        notebook_url: $notebook_url
        status: $status
    } | to json --indent 0
}

def fail [action: string, msg: string] {
    print -e $"publish-datadog-notebook: FAIL — ($msg)"
    print (emit $action null null null null "error")
    exit 1
}

# Sync the checked-in payload from the markdown doc (delegates to the render script's logic).
def sync-payload [doc_path: path, payload_path: path] {
    let rendered = (render-payload $doc_path) | str trim
    $"($rendered)\n" | save --force $payload_path
}

# Rewrite the markdown doc's front-matter markers with the published id/url,
# then re-render the payload so it stays in sync with the updated doc.
def record-publication [doc_path: path, payload_path: path, published_url: string, published_id: string] {
    let doc_text = (open --raw $doc_path)
    let lines = ($doc_text | lines)

    let url_found = ($lines | any {|line| $line | str starts-with "> Datadog notebook URL:" })
    let id_found = ($lines | any {|line| $line | str starts-with "> Datadog notebook ID:" })
    if not $url_found {
        fail "record" $"could not find '> Datadog notebook URL:' marker in ($doc_path)"
    }
    if not $id_found {
        fail "record" $"could not find '> Datadog notebook ID:' marker in ($doc_path)"
    }

    let updated_lines = ($lines | each {|line|
        if ($line | str starts-with "> Datadog notebook URL:") {
            $"> Datadog notebook URL: ($published_url)"
        } else if ($line | str starts-with "> Datadog notebook ID:") {
            $"> Datadog notebook ID: `($published_id)`"
        } else {
            $line
        }
    })

    let joined = ($updated_lines | str join "\n")
    let final_text = if ($doc_text | str ends-with "\n") { $"($joined)\n" } else { $joined }
    $final_text | save --force $doc_path
    sync-payload $doc_path $payload_path
}

def send-request [method: string, url: string, payload_text: string, api_key: string, app_key: string] {
    let response = if $method == "PUT" {
        (http put $url $payload_text --content-type "application/json" --headers ["DD-API-KEY" $api_key "DD-APPLICATION-KEY" $app_key "Accept" "application/json"])
    } else {
        (http post $url $payload_text --content-type "application/json" --headers ["DD-API-KEY" $api_key "DD-APPLICATION-KEY" $app_key "Accept" "application/json"])
    }
    $response
}

def main [
    --doc-path: path                    # path to the canonical markdown doc
    --payload-path: path                # path to the checked-in JSON payload
    --api-site: string                  # Datadog API site (default: $env.DATADOG_API_SITE or api.datadoghq.com)
    --app-site: string                  # Datadog app site (default: $env.DATADOG_APP_SITE or app.datadoghq.com)
    --notebook-id: string                # existing notebook id -> PUT; omitted -> POST to create
    --notebook-url: string               # override the URL recorded back into the markdown doc
    --dry-run                            # validate + print the request without calling Datadog
    --record-publication (-r)            # rewrite doc + payload with the given --notebook-id/--notebook-url, no API call
    --no-record                          # do not rewrite the markdown doc with the published notebook id/url
] {
    let doc = if $doc_path == null { default-doc-path } else { $doc_path }
    let payload = if $payload_path == null { default-payload-path } else { $payload_path }

    let api_site = normalize-site (if $api_site != null { $api_site } else if "DATADOG_API_SITE" in $env and $env.DATADOG_API_SITE != "" { $env.DATADOG_API_SITE } else { $DEFAULT_API_SITE })
    let app_site = normalize-site (if $app_site != null { $app_site } else if "DATADOG_APP_SITE" in $env and $env.DATADOG_APP_SITE != "" { $env.DATADOG_APP_SITE } else { $DEFAULT_APP_SITE })

    if $record_publication {
        if $notebook_id == null {
            fail "record" "--record-publication requires --notebook-id"
        }
        let published_url = if $notebook_url != null { $notebook_url } else { notebook-url $app_site $notebook_id }
        record-publication $doc $payload $published_url $notebook_id
        print (emit "record" null null $notebook_id $published_url "ok")
        return
    }

    sync-payload $doc $payload

    let method = if $notebook_id != null { "PUT" } else { "POST" }
    let endpoint = if $notebook_id != null {
        $"($api_site)/api/v1/notebooks/($notebook_id)"
    } else {
        $"($api_site)/api/v1/notebooks"
    }

    if $dry_run {
        let target = if $notebook_url != null {
            $notebook_url
        } else if $notebook_id != null {
            notebook-url $app_site $notebook_id
        } else {
            "(new notebook)"
        }
        print $"publish-datadog-notebook: dry-run ($method) ($endpoint)"
        print $"publish-datadog-notebook: target ($target)"
        print (emit "publish" $method $endpoint $notebook_id $target "dry-run")
        return
    }

    let api_key = ($env.DD_API_KEY? | default "")
    let app_key = ($env.DD_APP_KEY? | default "")
    if $api_key == "" or $app_key == "" {
        fail "publish" "DD_API_KEY and DD_APP_KEY must be set (env vars only — never pass as CLI args)"
    }

    let payload_text = (open --raw $payload)
    let response = (send-request $method $endpoint $payload_text $api_key $app_key)
    let new_notebook_id = ($response | get -o data.id)
    if $new_notebook_id == null {
        fail "publish" "Datadog API response did not contain data.id"
    }

    let published_url = if $notebook_url != null { $notebook_url } else { notebook-url $app_site $new_notebook_id }
    print $"publish-datadog-notebook: published ($published_url)"

    if $no_record {
        print (emit "publish" $method $endpoint $new_notebook_id $published_url "ok")
        return
    }

    record-publication $doc $payload $published_url $new_notebook_id
    if $notebook_id != $new_notebook_id or $method == "POST" {
        let update_endpoint = $"($api_site)/api/v1/notebooks/($new_notebook_id)"
        let refreshed_payload_text = (open --raw $payload)
        send-request "PUT" $update_endpoint $refreshed_payload_text $api_key $app_key
        print $"publish-datadog-notebook: refreshed recorded metadata in ($published_url)"
    }

    print (emit "publish" $method $endpoint $new_notebook_id $published_url "ok")
}
