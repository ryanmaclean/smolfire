#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Publish the canonical lower-bound runtime notebook to Datadog."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DOC_PATH = REPO_ROOT / "docs/LOWER-BOUND-RUNTIME-2026-09-23.md"
DEFAULT_PAYLOAD_PATH = REPO_ROOT / "docs/datadog/smolfire-lower-bound-runtime-notebook.json"
DEFAULT_API_SITE = "https://api.datadoghq.com"
DEFAULT_APP_SITE = "https://app.datadoghq.com"


def normalize_site(url: str) -> str:
    url = url.rstrip("/")
    if url.startswith("http://") or url.startswith("https://"):
        return url
    return f"https://{url}"


def notebook_url(app_site: str, notebook_id: str) -> str:
    return f"{normalize_site(app_site)}/notebook/{notebook_id}"


def sync_payload(doc_path: Path, payload_path: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "bin/render-datadog-notebook.py"),
            "--doc-path",
            str(doc_path),
            "--payload-path",
            str(payload_path),
        ],
        check=True,
    )


def record_publication(doc_path: Path, payload_path: Path, published_url: str, published_id: str) -> None:
    doc_text = doc_path.read_text(encoding="utf-8")
    replacements = {
        r"(?m)^> Datadog notebook URL: .*$": f"> Datadog notebook URL: {published_url}",
        r"(?m)^> Datadog notebook ID: .*$": f"> Datadog notebook ID: `{published_id}`",
    }
    updated = doc_text
    for pattern, replacement in replacements.items():
        updated, count = re.subn(pattern, replacement, updated, count=1)
        if count != 1:
            raise RuntimeError(f"could not find publication marker matching {pattern!r} in {doc_path}")

    if updated != doc_text:
        doc_path.write_text(updated, encoding="utf-8")
    sync_payload(doc_path, payload_path)


def send_request(method: str, url: str, payload_text: str, api_key: str, app_key: str) -> dict:
    request = urllib.request.Request(
        url,
        data=payload_text.encode("utf-8"),
        method=method,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "DD-API-KEY": api_key,
            "DD-APPLICATION-KEY": app_key,
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Datadog API {method} {url} failed with HTTP {exc.code}: {body}") from exc


def published_id(response: dict) -> str:
    notebook_id = response.get("data", {}).get("id")
    if not notebook_id:
        raise RuntimeError(f"Datadog API response did not contain data.id: {json.dumps(response, ensure_ascii=False)}")
    return notebook_id


def payload_text(payload_path: Path) -> str:
    return payload_path.read_text(encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--doc-path", type=Path, default=DEFAULT_DOC_PATH)
    parser.add_argument("--payload-path", type=Path, default=DEFAULT_PAYLOAD_PATH)
    parser.add_argument("--api-site", default=os.environ.get("DATADOG_API_SITE", DEFAULT_API_SITE))
    parser.add_argument("--app-site", default=os.environ.get("DATADOG_APP_SITE", DEFAULT_APP_SITE))
    parser.add_argument("--notebook-id", default=os.environ.get("DATADOG_NOTEBOOK_ID"))
    parser.add_argument("--notebook-url", help="override the notebook URL recorded back into the markdown document")
    parser.add_argument("--dry-run", action="store_true", help="validate the payload and print the request without calling Datadog")
    parser.add_argument("--record-publication", action="store_true", help="update the markdown + payload with the provided notebook id/url without calling Datadog")
    parser.add_argument("--no-record", action="store_true", help="do not rewrite the markdown document with the published notebook id/url")
    args = parser.parse_args()

    api_site = normalize_site(args.api_site)
    app_site = normalize_site(args.app_site)

    if args.record_publication:
        if not args.notebook_id:
            parser.error("--record-publication requires --notebook-id or DATADOG_NOTEBOOK_ID")
        published_url = args.notebook_url or notebook_url(app_site, args.notebook_id)
        record_publication(args.doc_path, args.payload_path, published_url, args.notebook_id)
        print(f"publish-datadog-notebook: recorded {published_url} in {args.doc_path}")
        return 0

    sync_payload(args.doc_path, args.payload_path)
    method = "PUT" if args.notebook_id else "POST"
    endpoint = f"{api_site}/api/v1/notebooks"
    if args.notebook_id:
        endpoint = f"{endpoint}/{args.notebook_id}"

    if args.dry_run:
        target = args.notebook_url or (notebook_url(app_site, args.notebook_id) if args.notebook_id else "(new notebook)")
        print(f"publish-datadog-notebook: dry-run {method} {endpoint}")
        print(f"publish-datadog-notebook: target {target}")
        return 0

    api_key = os.environ.get("DD_API_KEY")
    app_key = os.environ.get("DD_APP_KEY")
    if not api_key or not app_key:
        print("publish-datadog-notebook: FAIL — DD_API_KEY and DD_APP_KEY must be set", file=sys.stderr)
        return 1

    response = send_request(method, endpoint, payload_text(args.payload_path), api_key, app_key)
    new_notebook_id = published_id(response)
    published_url = args.notebook_url or notebook_url(app_site, new_notebook_id)
    print(f"publish-datadog-notebook: published {published_url}")

    if args.no_record:
        return 0

    record_publication(args.doc_path, args.payload_path, published_url, new_notebook_id)
    if args.notebook_id != new_notebook_id or method == "POST":
        update_endpoint = f"{api_site}/api/v1/notebooks/{new_notebook_id}"
        send_request("PUT", update_endpoint, payload_text(args.payload_path), api_key, app_key)
        print(f"publish-datadog-notebook: refreshed recorded metadata in {published_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
