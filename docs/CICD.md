# smolfire CI/CD — TPM VM Test Pipeline

This document describes the CI/CD infrastructure for reproducible TPM integration
tests on a self-hosted runner.

---

## Overview

The pipeline boots a FreeBSD 15.1-STABLE VM under QEMU+KVM with a software TPM
(swtpm), reads PCR0 via `tpm2_pcrread` over SSH, and asserts it matches the
known-good value established during manual validation.

| Component | Value |
|-----------|-------|
| Workflow  | `.github/workflows/tpm-vm-test.yml` |
| Test driver | `tests/tpm-smoke-test.py` |
| Runner setup | `bin/setup-runner.sh` |
| Runner host | <kvm-host> (<kvm-host-ip>) |
| FreeBSD image | `FreeBSD-15.1-STABLE-amd64-ufs.qcow2.xz` (UFS, amd64) |
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

`.github/workflows/tpm-vm-test.yml` runs the following sequence:

1. **Cache restore** — looks up the FreeBSD qcow2 image by a SHA-256 of the
   download URL.  On a hit the ~1 GB download is skipped.

2. **Image download** (cache miss only) — fetches the `.qcow2.xz` from
   `download.freebsd.org` and decompresses it into `/tmp/smolbsd-ci/`.

3. **Working copy** — `cp`s the cached image to `/tmp/` so the cached original
   is never mutated.

4. **swtpm start** — launches `swtpm socket --tpm2` as a daemon writing state to
   `/tmp/smolbsd-tpm/`; polls for the Unix socket (max 3s).

5. **QEMU boot** — starts `qemu-system-x86_64` with:
   - `-accel kvm -cpu host` for near-native speed
   - OVMF UEFI firmware
   - virtio disk + NIC with SSH forwarded to `127.0.0.1:2241`
   - `tpm-tis` device backed by the swtpm socket
   - A Unix serial console socket at `/tmp/smolbsd-console.sock`

6. **Console fix** (`tests/tpm-smoke-test.py`) —
   - Connects to the QEMU console socket and waits for the FreeBSD login prompt.
   - Logs in as root.
   - **Removes XMSS SSH host keys** (`/etc/ssh/ssh_host_xmss_*`).  The standard
     UFS image regenerates these on first boot; XMSS key generation can take
     several hours and blocks sshd from starting.  Removing the keys causes sshd
     to start immediately using only RSA/ECDSA/Ed25519 keys.
   - Sets a CI root password and starts sshd.

7. **PCR0 read** — SSHes in (via `sshpass`), installs `tpm2-tools` from pkg if
   absent, runs `tpm2_pcrread sha256:0`, parses the output, and compares to the
   expected value.

8. **Summary** — writes PCR0 / expected / pass-fail to the job summary page.

9. **Cleanup** — kills QEMU and swtpm, removes ephemeral files.  Always runs,
   even on failure.

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

## Image cache

| Detail | Value |
|--------|-------|
| Cache action | `actions/cache@v4` |
| Cache path | `/tmp/smolbsd-ci/FreeBSD-15.1-STABLE-amd64-ufs.qcow2` |
| Cache key | `freebsd-image-<sha256(IMAGE_URL)>` |
| Typical image size | ~900 MB uncompressed |
| Cache lives on | the runner host filesystem (self-hosted runner cache) |

### Invalidating the cache

Change `IMAGE_URL` in the workflow `env:` block.  The SHA-256 of the URL changes,
producing a new cache key and forcing a fresh download.

To manually clear it on the runner:

```sh
ssh studio@<kvm-host-ip>
rm -rf /tmp/smolbsd-ci
```

The next run will re-download and re-populate the cache.

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
| `Login prompt not seen within 240s` | QEMU too slow / image corrupt | Check QEMU output; re-download image by clearing `/tmp/smolbsd-ci` |
| SSH timeout | XMSS fix did not apply | Check console log for errors; XMSS removal step may have failed |
| PCR0 mismatch | Firmware or image changed | Re-run manual validation, update `EXPECTED_PCR0` in workflow |
| Runner shows offline | systemd service stopped | `ssh studio@<kvm-host-ip> 'sudo systemctl start actions.runner.*'` |

To view runner logs on <kvm-host>:

```sh
journalctl -u 'actions.runner.ryanmaclean-smolBSD.*' -f
```
