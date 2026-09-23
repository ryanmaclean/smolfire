#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import json
import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "bin" / "netbsd-microvm-prototype.py"
FIXTURE = REPO / "tests" / "fixtures" / "netbsd-microvm-sample.log"


def fail(message: str) -> None:
    print(f"netbsd-microvm-prototype-test: FAIL — {message}")
    raise SystemExit(1)


def run_json(args: list[str]) -> dict:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"script exited {result.returncode}: {result.stderr}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        fail(f"stdout was not valid JSON: {exc}")


def test_dry_run_and_parse_log() -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        kernel = tmp / "netbsd-MICROVM"
        rootfs = tmp / "rootfs.fs"
        state = tmp / "state.img"
        kernel.write_bytes(b"K" * 4096)
        rootfs.write_bytes(b"R" * 2048)
        state.write_bytes(b"S" * 8192)

        dry = run_json(
            [
                "--kernel",
                str(kernel),
                "--rootfs",
                str(rootfs),
                "--state-image",
                str(state),
                "--state-fs",
                "lfs",
                "--accel",
                "tcg",
                "--append",
                "bootverbose=1",
                "--dry-run",
            ]
        )
        cmd = dry["qemu_command"]
        joined = " ".join(cmd)
        if "qemu-system-x86_64" not in cmd[0]:
            fail("dry-run command did not default to qemu-system-x86_64")
        for needle in [
            "-M microvm,rtc=on,acpi=off,pic=off",
            "-initrd",
            "virtio-blk-device,drive=state0",
            "virtio-mmio.force-legacy=false",
            "console=com",
            "root=md0a",
            "smolfire.state_dev=ld0a",
            "smolfire.state_fs=lfs",
            "bootverbose=1",
        ]:
            if needle not in joined:
                fail(f"dry-run command missing {needle!r}")
        if dry["artifacts"]["total_bytes"] != 14336:
            fail("artifact byte accounting was wrong")
        if dry["config"]["memory_mib"] != 256:
            fail("default memory_mib should be 256")

        parsed = run_json(
            [
                "--kernel",
                str(kernel),
                "--rootfs",
                str(rootfs),
                "--state-image",
                str(state),
                "--state-fs",
                "lfs",
                "--accel",
                "tcg",
                "--parse-log",
                str(FIXTURE),
            ]
        )
        result = parsed["result"]
        if result["time_to_ready_ms"] != 73:
            fail("TIME_TO_READY parser did not recover 73ms")
        state_info = result["state"]
        if state_info["dev"] != "ld0a" or state_info["mount"] != "/state":
            fail("state marker fields were not parsed correctly")
        workload = result["workload"]
        if workload["verdict"] != "pass" or workload["fs"] != "lfs":
            fail("workload marker fields were not parsed correctly")
        if workload["ops"] != 128 or workload["fsync_p50_ms"] != 1.7:
            fail("numeric workload metrics were not typed correctly")
        acceptance = result["acceptance"]
        for key in [
            "boots_under_qemu_microvm_pvh",
            "stable_ready_marker",
            "mounts_one_writable_state_volume",
            "runs_common_filesystem_state_workload",
            "reports_artifact_size_boot_time_ram_and_fs_metrics",
        ]:
            if acceptance[key] is not True:
                fail(f"acceptance flag {key} was not satisfied")


if __name__ == "__main__":
    test_dry_run_and_parse_log()
    print("netbsd-microvm-prototype-test: ok")
