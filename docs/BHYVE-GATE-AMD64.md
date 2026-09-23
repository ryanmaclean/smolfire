# amd64 boot gate — bhyve runbook (bare-metal FreeBSD host)

Target: any bare-metal FreeBSD 15 amd64 host with many cores. The amd64 boot
gate was stuck "pending KVM host" (PHASE-1) because QEMU/TCG was too slow —
a FreeBSD host runs bhyve natively, which is the right gate vehicle. Run
everything as root. Phase 1 already confirmed `kldload vmm` works on the
designated host (`/dev/vmmctl` present), but the test image was deleted
post-test and must be re-transferred.

## 0. Host prep (once)

Do this manually rather than via `bin/bhyve-host-setup.nu` — that script is
Vultr-oriented (see "Known script bugs" below).

```sh
# Packages (note: the pkg is qemu-tools, not the "qemu-utils" the docs mention)
pkg install -y nushell bhyve-firmware qemu-tools expect git
# swtpm only needed later for --tpm runs:  pkg install -y swtpm

# Kernel modules (idempotent)
kldload vmm    || true
kldload nmdm   || true
kldload if_tap || true
sysrc kld_list+="vmm nmdm if_tap"

# Verify — do NOT trust the scripts' /dev/vmm check; on FreeBSD 15 the node is
# /dev/vmmctl and /dev/vmm/ only appears after the first VM is created:
kldstat | grep -E 'vmm|nmdm'
ls -l /dev/vmmctl
ls /usr/local/share/uefi-firmware/BHYVE_UEFI.fd

# tap0 is MANDATORY — bhyve-smolfire-vm.nu hardcodes "-s 3,virtio-net,tap0".
ifconfig tap0 create 2>/dev/null; ifconfig tap0 up
# Do NOT build bridge0 for the boot gate — it would touch the NIC your SSH
# session rides on, and the gate needs no guest networking. (Later, for guest
# DHCP: ifconfig bridge0 create && ifconfig bridge0 addm tap0 addm <phys-nic> up)

git clone <repo-url> ~/smolfire && cd ~/smolfire
git checkout <branch-or-tag-under-test>   # e.g. main, or the PR branch being validated
nu bin/setup-hooks.nu        # pre-push spool guard (CLAUDE.md §9)
```

## 1. Transfer the image

```sh
scp FreeBSD-15-amd64-smolfire.qcow2 root@<bhyve-host>:/root/   # host address is internal — see private inventory
```

## 2. Convert qcow2 → raw (bhyve needs raw)

```sh
cd ~/smolfire
nu bin/prep-bhyve-image.nu --input /root/FreeBSD-15-amd64-smolfire.qcow2 --verify
# Output: /root/FreeBSD-15-amd64-smolfire.raw
```

## 3. Sanity dry-run

```sh
nu bin/bhyve-smolfire-vm.nu --image /root/FreeBSD-15-amd64-smolfire.raw --dry-run
# Expect a bhyve command with: virtio-blk,<img>  virtio-net,tap0
#   com1,/dev/nmdm0A  bootrom,BHYVE_UEFI.fd  -m 512M -c 2
```

## 4. Boot gate (orchestrator, recommended)

```sh
cd ~/smolfire && mkdir -p /tmp/smolfire-results
nu bin/run-vm-tests.nu \
  --image /root/FreeBSD-15-amd64-smolfire.raw \
  --backend bhyve --arch amd64 \
  --vm-name smolfire-test \
  --skip '["memory", "artifact-size", "crash-recovery"]' \
  --results-file /tmp/smolfire-results/run-$(date -u +%Y%m%dT%H%M%SZ).toml
```

Why the skips:
- `memory` SSHes `root@127.0.0.1 -p 2240`; bhyve has no user-mode NAT, so the
  `--hostfwd-ssh` flag is a no-op and this step can never pass on bhyve.
- `artifact-size` enforces < 512 MiB; the current amd64 image is ~2.4 GiB —
  that's the size-budget work, not the boot gate.
- `crash-recovery` can be attempted after the boot gate is green.

Expected pass output from the expect script:

```
CONSOLE=/dev/nmdm0B
THRESHOLD=60s
TIME_TO_LOGIN=<N>s
VERDICT=pass
```

then `OVERALL: PASS ✓`, exit 0, and the results TOML with `overall = "pass"`.
Expect exit codes: 0 pass, 1 timeout, 2 hard failure (kernel panic /
`mountroot>` / UEFI shell — a `mountroot>` here on the NEW image would mean the
MODULES_OVERRIDE/FFS change is wrong; see docs/UR-BSD-VERIFY.md Finding 2).

Timing: on a modern many-core host with native vmm expect login in ~10–25 s. NOTE: the bhyve
expect script's built-in threshold is 60 s, not the documented 30 s gate — for
a strict ≤30 s claim, read the printed `TIME_TO_LOGIN` yourself.

## 4'. Manual variant (two terminals)

```sh
# Terminal B FIRST (nmdm does not buffer — attach before or within ~2 s of launch):
cd ~/smolfire && SMOLFIRE_CONSOLE=/dev/nmdm0B expect tests/time-to-ready-bhyve.exp

# Terminal A:
cd ~/smolfire && nu bin/bhyve-smolfire-vm.nu --image /root/FreeBSD-15-amd64-smolfire.raw --name smolfire

# Cleanup if wedged:
bhyvectl --destroy --vm=smolfire 2>/dev/null
```

## 5. Gate policy — 3 consecutive clean runs

Do NOT use `ci-gate.nu --run` for bhyve (it doesn't forward `--backend`, so it
would launch the qemu backend). Repeat step 4 three times with fresh
timestamped `--results-file` values, then evaluate:

```sh
nu bin/ci-gate.nu --results-dir /tmp/smolfire-results
# exit 0 = gate open (3 consecutive passes), 2 = closed
```

## Known script bugs / assumptions (found in review, not yet fixed)

1. `bhyve-host-setup.nu` and `prep-bhyve-image.nu` test `/dev/vmm` for
   readiness; on FreeBSD 14/15 the node is `/dev/vmmctl` (`/dev/vmm/` appears
   only after the first VM exists). The hard-error in setup aborts wrongly on
   a fresh host.
2. `bhyve-smolfire-vm.nu --hostfwd-ssh` is a dead flag (bhyve has no user NAT) —
   which is why the `memory` test step must be skipped on this backend.
3. `tap0` is hardcoded in the bhyve command builders; no flag to change/drop.
4. `time-to-ready-bhyve.exp` hardcodes a 60 s threshold vs the documented 30 s
   gate — a 31–60 s boot would be reported "pass".
5. `ci-gate.nu --run` never forwards `--backend`/`--arch`/`--vm-name`.
6. `bhyve-host-setup.nu` is Vultr-specific: may rewrite resolv.conf, pins a
   quarterly pkg repo, auto-bridges the first physical NIC (dangerous on a box
   you're SSH'd into), installs swtpm unconditionally.
7. `bin/setup-runner.sh` and docs/CICD.md are the Linux/KVM self-hosted path —
   not applicable to this host.
8. Docs and prep-bhyve-image.nu error text say "qemu-utils"; the FreeBSD pkg
   is `qemu-tools`.
9. `run-vm-tests.nu`/`ci-gate.nu` must run from the repo root (relative paths);
   `run-vm-tests.nu` uses `job spawn` (needs nushell 0.104+ — current pkg ok).
