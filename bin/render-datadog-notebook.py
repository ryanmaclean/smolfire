#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Render the canonical lower-bound runtime Markdown into a Datadog notebook payload."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DOC_PATH = REPO_ROOT / "docs/LOWER-BOUND-RUNTIME-2026-09-23.md"
DEFAULT_PAYLOAD_PATH = REPO_ROOT / "docs/datadog/smolfire-lower-bound-runtime-notebook.json"
NOTEBOOK_NAME = "smolfire — Lower-bound Runtime, Temporal Storage & Lineage"


def build_payload(doc_text: str) -> dict:
    return {
        "data": {
            "type": "notebooks",
            "attributes": {
                "name": NOTEBOOK_NAME,
                "status": "published",
                "time": {"live_span": "1w"},
                "cells": [
                    {
                        "type": "notebook_cells",
                        "attributes": {
                            "definition": {
                                "type": "markdown",
                                "text": doc_text,
                            }
                        },
                    }
                ],
            },
        }
    }


def render_payload(doc_path: Path) -> str:
    doc_text = doc_path.read_text(encoding="utf-8")
    payload = build_payload(doc_text)
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--doc-path", type=Path, default=DEFAULT_DOC_PATH)
    parser.add_argument("--payload-path", type=Path, default=DEFAULT_PAYLOAD_PATH)
    parser.add_argument("--stdout", action="store_true", help="write the rendered payload to stdout")
    parser.add_argument("--check", action="store_true", help="exit non-zero when the checked-in payload is stale")
    args = parser.parse_args()

    rendered = render_payload(args.doc_path)

    if args.check:
        current = args.payload_path.read_text(encoding="utf-8")
        if current != rendered:
            print(
                f"render-datadog-notebook: FAIL — {args.payload_path} is out of sync with {args.doc_path}",
                file=sys.stderr,
            )
            return 1
        print("render-datadog-notebook: ok")
        return 0

    if args.stdout:
        sys.stdout.write(rendered)
        return 0

    args.payload_path.write_text(rendered, encoding="utf-8")
    print(f"render-datadog-notebook: wrote {args.payload_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
