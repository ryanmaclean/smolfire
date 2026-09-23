# smolfire CI/CD — TPM VM Test Pipeline

This document describes the CI/CD infrastructure for reproducible TPM integration
tests on a self-hosted runner.

---

## Overview

The pipeline boots the smolfire amd64 TPM image under QEMU+KVM with a software
TPM (swtpm), waits for the SSH boot gate, runs the T1–T6 TPM acceptance suite
over SSH, and asserts PCR0 matches the known-good value established during
manual validation.

| Component | Value |
|-----------|-------|
| Workflow  | `.github/workflows/tpm-vm-test.yml` |
| Test driver | `tests/bhyve-tpm-pcr-verify.nu` (T1–T6 suite) via `bin/swtpm-setup.nu` and `bin/qemu-smolfire.nu` |
| Runner setup | `bin/setup-runner.sh` |
| Runner host | <kvm-host> (<kvm-host-ip>) |
| Image under test | `/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2` (built by `build-image.yml`; the historical `smolbsd-ci` directory name is kept on the runner) |
| Expected PCR0 | `B6A903D197F7F1DFDAD0C3D74244009C9AA407F55AE5F753D7F8B3F0C10F5727` |

---

## Registering <kvm-host> as a runner

### 1. Get a registration token

Go to:
**GitHub → ryanmaclean/smolfire → Settings → Actions → Runners → New self-hosted runner**

Copy the token shown in the "Configure" step (it is valid for ~1 hour).

### 2. SSH into <kvm-host>

```sh
ssh studio@<kvm-host-ip>
```

### 3. Run the setup script

```sh
cd ~/smolfire   # or wherever the repo is cloned
GITHUB_RUNNER_TOKEN=<token> sh bin/setup-runner.sh
```

Optional overrides:

```sh
GITHUB_RUNNER_TOKEN=<token> \
RUNNER_NAME=<kvm-host>-amd64 \
RUNNER_LABELS=self-hosted,linux,amd64,kvm \
sh bin/setup-runner.sh
```

The script will:
1. Download `actions-runner-linux-x64-2.321.0.tar.gz` and verify its SHA-256.
2. Extract to `~/actions-runner/`.
3. Run `./config.sh` with `--unattended`.
4. Install and start the runner as a systemd service under the `studio` user.

### 4. Verify registration

```sh
systemctl status 'actions.runner.ryanmaclean-smolBSD.*'
```

The runner should appear as **Idle** at:
https://github.com/ryanmaclean/smolfire/settings/actions/runners

---

## What the TPM workflow tests

`.github/workflows/tpm-vm-test.yml` runs the following sequence (paths are the
workflow's `env:` values):

1. **Install Nushell** — fetches the pinned `nu` release into `~/.local/bin`.

2. **Verify smolfire image exists** — requires the pre-built image at
   `SMOLFIRE_IMAGE=/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2`. It is
   produced by `build-image.yml`; the job fails fast if it is missing. There is
   no download or cache step in this workflow.

3. **Ensure UEFI fallback bootloader in ESP** — uses `guestfish` to inject
   `EFI/BOOT/BOOTX64.EFI` into the image's ESP if it is absent, so OVMF boots
   without a stored boot entry.

4. **Reset swtpm state** — `nu bin/swtpm-setup.nu --action reset --state-dir
   /tmp/smolfire-tpm-ci` gives every run a fresh PCR baseline.

5. **Boot smolfire with QEMU+swtpm** — `nu bin/qemu-smolfire.nu` starts
   `qemu-system-x86_64` in the background with `-accel kvm -cpu host`, OVMF
   firmware, a `tpm-tis` device backed by the swtpm socket, and SSH forwarded
   to `127.0.0.1:2241`. QEMU output goes to `/tmp/smolfire-qemu-ci.log`.

6. **Wait for SSH boot-gate** — polls SSH for up to 120 s; on timeout it prints
   the tail of `/tmp/smolfire-qemu-ci.log` and fails.

7. **Run T1–T6 TPM acceptance suite** — `tests/bhyve-tpm-pcr-verify.nu` over
   SSH; results are written to `/tmp/smolfire-t1t6-ci.toml`.

8. **Report T1–T6 results** — appends the TOML results to the job summary.

9. **Cleanup** — shuts the guest down, stops swtpm via
   `bin/swtpm-setup.nu --action stop`, and removes ephemeral files. Always
   runs, even on failure.

---

## Triggering a manual run

In the GitHub UI:

1. Go to **Actions → TPM VM Smoke Test**.
2. Click **Run workflow**.
3. Select branch `main` (or your branch).
4. Click **Run workflow**.

Via CLI (`gh`):

```sh
gh workflow run tpm-vm-test.yml --repo ryanmaclean/smolfire
```

Watch live:

```sh
gh run watch --repo ryanmaclean/smolfire
```

---

## Image and state paths on the runner

| Detail | Value |
|--------|-------|
| Image under test | `/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2` (+ `.sha256`) |
| Produced by | `.github/workflows/build-image.yml` (`OUTPUT_DIR=/home/studio/smolbsd-ci`) |
| swtpm state | `/tmp/smolfire-tpm-ci` (reset at the start of every run) |
| QEMU log | `/tmp/smolfire-qemu-ci.log` |
| T1–T6 results | `/tmp/smolfire-t1t6-ci.toml` |

The `smolbsd-ci` directory name on the runner predates the rename and is kept
so existing runner setups keep working; the workflow's `env:` block is the
source of truth.

### Rebuilding the image

The TPM workflow never downloads or caches an image. To refresh the image under
test, run `build-image.yml` (which stages a FreeBSD builder VM from
`/home/studio/smolbsd-tpm-test/` and writes the new qcow2 into
`/home/studio/smolbsd-ci/`), or copy a locally built image to that path.

To clear swtpm state or logs by hand on the runner:

```sh
ssh studio@<kvm-host-ip>
rm -rf /tmp/smolfire-tpm-ci /tmp/smolfire-qemu-ci.log /tmp/smolfire-t1t6-ci.toml
```

---

## Adding more amd64 runners

Each additional runner must have:
- `/dev/kvm` accessible to the runner user
- `qemu-system-x86_64`, `swtpm`, `sshpass`, `python3` in `PATH`
- `/usr/share/qemu/OVMF.fd` (Ubuntu: `apt install ovmf`)

Steps for each new host:

```sh
# On the new host
GITHUB_RUNNER_TOKEN=<new-token> \
RUNNER_NAME=<unique-name> \
RUNNER_LABELS=self-hosted,linux,amd64,kvm \
sh bin/setup-runner.sh
```

Each runner needs its own registration token (tokens are one-time-use).

To allow parallel runs across multiple runners, the workflow's `runs-on` label
(`[self-hosted, linux, amd64, kvm]`) will automatically distribute jobs to any
available matching runner — no workflow changes needed.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `swtpm socket did not appear` | swtpm not installed or permission issue | `sudo apt install swtpm` on <kvm-host>; ensure runner user can `sudo swtpm` |
| QEMU exits immediately | `/dev/kvm` not accessible | `sudo chmod 666 /dev/kvm` or add runner user to `kvm` group |
| SSH boot-gate timeout (120s) | QEMU too slow / image corrupt / missing ESP fallback | Check `/tmp/smolfire-qemu-ci.log`; rebuild the image with `build-image.yml` |
| `smolfire image not found` | `build-image.yml` has not produced `/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2` | Run `build-image.yml` first or copy an image to that path |
| PCR0 mismatch | Firmware or image changed | Re-run manual validation, update `EXPECTED_PCR0` in workflow |
| Runner shows offline | systemd service stopped | `ssh studio@<kvm-host-ip> 'sudo systemctl start actions.runner.*'` |

To view runner logs on <kvm-host>:

```sh
journalctl -u 'actions.runner.ryanmaclean-smolBSD.*' -f
```
