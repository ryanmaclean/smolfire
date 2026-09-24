#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# netbsd-microvm-prototype.py — host-side prototype runner/reporter for a
# NetBSD 11 MICROVM sibling target.
#
# This script does not build NetBSD artifacts. It launches (or dry-runs) a
# QEMU microvm/PVH command for a caller-supplied MICROVM kernel, immutable
# rootfs/initrd, and one writable state disk, then watches serial output for a
# small marker protocol:
#
#   SMOLFIRE_NETBSD_READY
#   SMOLFIRE_NETBSD_STATE_OK dev=<dev> mount=<path> fs=<name> mode=rw
#   SMOLFIRE_NETBSD_WORKLOAD verdict=pass key=value ...
#
# The resulting JSON report captures artifact size, host-measured time to
# READY, configured RAM/CPUs, and any workload/filesystem metrics supplied by
# the guest.

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import selectors
import shlex
import subprocess
import sys
import time
from pathlib import Path


READY_MARKER = "SMOLFIRE_NETBSD_READY"
STATE_MARKER = "SMOLFIRE_NETBSD_STATE_OK"
WORKLOAD_MARKER = "SMOLFIRE_NETBSD_WORKLOAD"
SCHEMA = "smolfire.netbsd-microvm-prototype/v1"

READY_RE = re.compile(rf"\b{re.escape(READY_MARKER)}\b")
STATE_RE = re.compile(rf"\b{re.escape(STATE_MARKER)}\b(?P<tail>.*)")
WORKLOAD_RE = re.compile(rf"\b{re.escape(WORKLOAD_MARKER)}\b(?P<tail>.*)")
TIME_TO_READY_RE = re.compile(r"\bTIME_TO_READY=(?P<ms>\d+)ms\b")


def detect_accel() -> str:
    system = platform.system()
    if system == "Darwin":
        result = subprocess.run(
            ["sysctl", "kern.hv_support"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip().endswith(": 1"):
            return "hvf"
    if system == "Linux" and os.path.exists("/dev/kvm"):
        return "kvm"
    return "tcg"


def cpu_model(accel: str) -> str:
    return "host" if accel in {"hvf", "kvm"} else "qemu64"


def file_size(path: str | None) -> int | None:
    if not path:
        return None
    return Path(path).stat().st_size


def typed_value(value: str):
    lowered = value.lower()
    if lowered in {"true", "false"}:
        return lowered == "true"
    try:
        if value.startswith("0") and value != "0" and not value.startswith("0."):
            raise ValueError
        return int(value)
    except ValueError:
        try:
            return float(value)
        except ValueError:
            return value


def parse_kv_tail(tail: str) -> dict[str, object]:
    parsed: dict[str, object] = {}
    for token in shlex.split(tail.strip()):
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        parsed[key] = typed_value(value)
    return parsed


def build_append(args: argparse.Namespace) -> str:
    fields = [
        "console=com",
        f"root={args.root_device}",
        f"smolfire.state_dev={args.state_device}",
        f"smolfire.state_fs={args.state_fs}",
        f"smolfire.ready_marker={READY_MARKER}",
        f"smolfire.state_marker={STATE_MARKER}",
        f"smolfire.workload_marker={WORKLOAD_MARKER}",
    ]
    if args.append:
        fields.extend(shlex.split(args.append))
    return " ".join(fields)


def build_qemu_cmd(args: argparse.Namespace) -> list[str]:
    accel = detect_accel() if args.accel == "auto" else args.accel
    args._resolved_accel = accel
    cmd = [
        args.qemu,
        "-accel",
        accel,
        "-M",
        "microvm,rtc=on,acpi=off,pic=off",
        "-cpu",
        cpu_model(accel),
        "-m",
        str(args.memory_mib),
        "-smp",
        str(args.cpus),
        "-kernel",
        args.kernel,
    ]
    if args.rootfs:
        cmd.extend(["-initrd", args.rootfs])
    cmd.extend(
        [
            "-drive",
            f"if=none,file={args.state_image},format={args.state_format},id=state0",
            "-device",
            "virtio-blk-device,drive=state0",
            "-global",
            "virtio-mmio.force-legacy=false",
            "-display",
            "none",
            "-serial",
            "stdio",
            "-append",
            build_append(args),
        ]
    )
    return cmd


def empty_report(args: argparse.Namespace, cmd: list[str]) -> dict[str, object]:
    kernel_bytes = file_size(args.kernel)
    rootfs_bytes = file_size(args.rootfs)
    state_bytes = file_size(args.state_image)
    sizes = [n for n in [kernel_bytes, rootfs_bytes, state_bytes] if n is not None]
    return {
        "schema": SCHEMA,
        "expected_markers": {
            "ready": READY_MARKER,
            "state": STATE_MARKER,
            "workload": WORKLOAD_MARKER,
        },
        "artifacts": {
            "kernel": {"path": args.kernel, "bytes": kernel_bytes},
            "rootfs": {"path": args.rootfs, "bytes": rootfs_bytes},
            "state": {"path": args.state_image, "bytes": state_bytes, "format": args.state_format},
            "total_bytes": sum(sizes),
        },
        "config": {
            "memory_mib": args.memory_mib,
            "cpus": args.cpus,
            "state_fs": args.state_fs,
            "root_device": args.root_device,
            "state_device": args.state_device,
            "timeout_s": args.timeout,
            "append": build_append(args),
            "accel": getattr(args, "_resolved_accel", args.accel),
        },
        "qemu_command": cmd,
    }


def parse_transcript(lines: list[str], report: dict[str, object], measured_ready_ms: int | None = None) -> dict[str, object]:
    ready_seen = False
    state_info: dict[str, object] | None = None
    workload_info: dict[str, object] | None = None
    time_to_ready_ms = measured_ready_ms

    for line in lines:
        if time_to_ready_ms is None:
            m = TIME_TO_READY_RE.search(line)
            if m:
                time_to_ready_ms = int(m.group("ms"))

        if not ready_seen and READY_RE.search(line):
            ready_seen = True

        m = STATE_RE.search(line)
        if m:
            state_info = parse_kv_tail(m.group("tail"))

        m = WORKLOAD_RE.search(line)
        if m:
            workload_info = parse_kv_tail(m.group("tail"))

    report["transcript"] = {
        "lines": len(lines),
        "ready_seen": ready_seen,
        "state_seen": state_info is not None,
        "workload_seen": workload_info is not None,
    }
    report["result"] = {
        "time_to_ready_ms": time_to_ready_ms,
        "state": state_info,
        "workload": workload_info,
        "acceptance": {
            "boots_under_qemu_microvm_pvh": ready_seen,
            "stable_ready_marker": ready_seen,
            "mounts_one_writable_state_volume": bool(state_info and state_info.get("mode") == "rw"),
            "runs_common_filesystem_state_workload": bool(workload_info and workload_info.get("verdict") == "pass"),
            "reports_artifact_size_boot_time_ram_and_fs_metrics": (
                time_to_ready_ms is not None and workload_info is not None
            ),
        },
    }
    return report


def run_qemu(args: argparse.Namespace, cmd: list[str]) -> dict[str, object]:
    report = empty_report(args, cmd)
    started = time.monotonic()
    deadline = started + args.timeout
    lines: list[str] = []
    ready_ms: int | None = None
    log_handle = open(args.serial_log, "w", encoding="utf-8") if args.serial_log else None
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    try:
        assert proc.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            wait_s = max(0, min(0.25, deadline - time.monotonic()))
            events = selector.select(wait_s)
            if not events:
                if proc.poll() is not None:
                    break
                continue
            line = proc.stdout.readline()
            if line == "":
                if proc.poll() is not None:
                    break
                continue
            line = line.rstrip("\r\n")
            lines.append(line)
            if log_handle:
                log_handle.write(line + "\n")
                log_handle.flush()
            if ready_ms is None and READY_RE.search(line):
                ready_ms = round((time.monotonic() - started) * 1000)
            if WORKLOAD_RE.search(line):
                break
        else:
            report["timeout"] = True
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        if log_handle:
            log_handle.close()
    report["process"] = {"returncode": proc.returncode}
    return parse_transcript(lines, report, measured_ready_ms=ready_ms)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prototype NetBSD 11 MICROVM sibling runner/reporter")
    parser.add_argument("--kernel", required=True, help="NetBSD MICROVM kernel path")
    parser.add_argument("--rootfs", help="Immutable rootfs/initrd path")
    parser.add_argument("--state-image", required=True, help="Writable state disk path")
    parser.add_argument("--state-format", default="raw", help="State disk format (default: raw)")
    parser.add_argument("--state-fs", required=True, choices=["lfs", "ffs-wapbl", "hammer2"])
    parser.add_argument("--root-device", default="md0a", help="Kernel root= device (default: md0a)")
    parser.add_argument("--state-device", default="ld0a", help="Guest state device hint (default: ld0a)")
    parser.add_argument("--memory-mib", type=int, default=256)
    parser.add_argument("--cpus", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--qemu", default="qemu-system-x86_64")
    parser.add_argument("--accel", default="auto", choices=["auto", "hvf", "kvm", "tcg"])
    parser.add_argument("--append", default="", help="Extra kernel arguments appended after the prototype defaults")
    parser.add_argument("--serial-log", help="Save combined serial transcript to this path")
    parser.add_argument("--parse-log", help="Parse an existing serial log instead of running QEMU")
    parser.add_argument("--dry-run", action="store_true", help="Print JSON report with the generated QEMU command only")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    cmd = build_qemu_cmd(args)
    if args.dry_run:
        report = empty_report(args, cmd)
    elif args.parse_log:
        report = empty_report(args, cmd)
        lines = Path(args.parse_log).read_text(encoding="utf-8").splitlines()
        report = parse_transcript(lines, report)
        report["parse_log"] = args.parse_log
    else:
        report = run_qemu(args, cmd)
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
