# Building smolfire

One command builds the complete smolfire qcow2 image from a clean FreeBSD source tree.

## Prerequisites

- FreeBSD 15 aarch64 host (the `<aarch64-builder>` VM on `<hypervisor-host>`, or any FreeBSD aarch64 box)
- At least 50 GiB free in `/usr/obj` (buildworld fills ~18–40 GiB; allow headroom)
- At least 10 GiB free after buildworld completes (cloudware-release also builds the full pkgbase repo under /usr/obj)
- Root access — `make release` and `make cloudware-release` both require a chroot
- `/usr/src` checked out at `releng/15.0`:
  ```sh
  git clone -b releng/15.0 https://git.freebsd.org/src.git /usr/src
  ```
- Nushell **0.115.1**: `pkg install nushell` (CI pins this version in
  `.github/nu-version`; 0.112.2 fails on `str lowercase` in `bin/coord-tick.nu`,
  and 0.111 fails on `get -o`)

## Step 0 — Preflight check (no writes, no builds)

Run this first. It checks root, disk space, source tree, kernel config, and
`/etc/src.conf` without making any changes:

```sh
sudo nu bin/build-smolfire-vm.nu --check
```

Fix any reported ERRORs before proceeding. WARNINGs about missing kernel configs
or `/etc/src.conf` are auto-resolved by the setup phase.

## Step 1 — Full build

```sh
sudo nu bin/build-smolfire-vm.nu
```

This runs the complete pipeline in order:

1. Setup — writes `/etc/src.conf`, sets git `safe.directory`, installs kernel
   configs and release conf into `/usr/src` if missing
2. `buildworld` (the long step — 1–3 h depending on hardware)
3. `buildkernel KERNCONF=SMOLFIRE-VM`
4. Kernel obj cleanup — **disabled** (FIX-9): `make packages` stages the kernel
   from the objdir the old FIX-8 cleanup used to delete
5. `make cloudware-release` (CLOUDWARE=smolfire, SMOLFIRECONF=<conf>) — produces
   the qcow2 artifact. FIX-9: the old `make vm-image ... CLOUDWARE_CONF=` form
   never sourced the release conf (CLOUDWARE_CONF is not a real Makefile
   variable and vm-image is WITH_VMIMAGES-gated), so the pkgbase filter,
   size-trim, and sshd enablement were silently skipped.

Build output streams to `/var/tmp/smolfire-build.log`. Watch progress with:

```sh
tail -f /var/tmp/smolfire-build.log
```

## Step 2 — Where the qcow2 ends up

```
# cloudware-release writes to the release objdir root, e.g.:
/usr/obj/usr/src/arm64.aarch64/release/*.ufs.qcow2
# (legacy vm-image path was .../release/vm/FreeBSD-15*SMOLFIRE-VM*.qcow2)
```

The script prints the exact path, size, sha256, and elapsed time on completion.

## Building in a pipeline (no build host required)

Two CI paths exist; neither needs a human at an SSH prompt:

| Workflow | Runner | What it does |
|---|---|---|
| `.github/workflows/build-image-hosted.yml` | **GitHub-hosted** `ubuntu-latest` (x64 runners expose `/dev/kvm`) | Boots a stock FreeBSD 15.0 BASIC-CLOUDINIT VM under KVM, shallow-clones `releng/15.0`, runs `bin/build-smolfire-vm.nu` inside, then runs the **size gate** and (amd64) the **KVM boot gate** on the runner and uploads the qcow2 as a workflow artifact. Dispatch with `arch: amd64` or `arch: aarch64` (aarch64 is cross-built; its boot gate needs ARM hardware — see `docs/BHYVE-GATE-AMD64.md`). |
| `.github/workflows/build-image.yml` | self-hosted Linux/KVM runner | The original PATH-B TPM-image pipeline with a pre-staged src tree. |

Hosted-runner caveats: buildworld at `-j4` inside the nested VM takes ~2.5–4 h
(job timeout is set just under the 6 h ceiling); first runs of the cloud-init
SSH bootstrap should be debugged from the uploaded `serial.log`. If the time
budget doesn't fit, use a larger runner or the self-hosted path.

The uploaded qcow2 is **compressed** (`qemu-img convert -c`, zlib — readable
by any qemu; the size and boot gates run against the compressed file). The
raw size is printed in the "Compress qcow2" step and the run summary so the
size trend stays visible.

## Size tuning

The release configs in `release/tools/` filter packages and strip non-essential
rootfs content in `vm_extra_pre_umount()`. To diagnose size after a build:

```sh
bin/analyze-image.sh path/to/FreeBSD-15-aarch64-smolfire.qcow2
```

This mounts the image read-only and reports top directories, top files, and
installed packages, then exits non-zero if total exceeds 512 MiB.

CI builds need no mount at all: the release confs print a `SIZEREPORT` block
(rootfs total, directories, largest files, packages by size) into the in-VM
make log, which the hosted workflow uploads as `smolfire-build-vm.log`. Parse
it with:

```sh
nu bin/sizereport.nu smolfire-build-vm.log        # tables, largest first
nu bin/sizereport.nu smolfire-build-vm.log --top 30
```

The microVM path emits `SMOLFIRE_METRIC` / `SMOLFIRE_SECTION` lines into the
build and gate logs (embedded MFS size, `/rescue/rescue`, kernel text/data/bss,
ELF section sizes, post-READY memory). Parse them with:

```sh
nu bin/smolfire-metrics.nu smolfire-build-vm.log smolfire-gate.log
```

## Partial runs

If buildworld already completed and the obj tree is intact:

```sh
sudo nu bin/build-smolfire-vm.nu --skip-buildworld
```

If you only want buildworld + buildkernel and not the image yet:

```sh
sudo nu bin/build-smolfire-vm.nu --skip-release
```

## amd64 cross-compile

On an aarch64 host, build the amd64 image with:

```sh
sudo nu bin/build-smolfire-vm.nu --arch amd64
```

This sets `TARGET=amd64 TARGET_ARCH=amd64` for all make invocations.

## riscv64 (experimental)

> **EXPERIMENTAL — untested.** FreeBSD riscv64 is a **Tier 2** platform;
> QEMU `virt` (plain rv64gc baseline) is the only supported-in-spirit
> target. There is **no CI boot gate** for this arch yet (the hosted
> workflow size-gates it only), it has never been built or booted here,
> and **no real-hardware claims are made** — real-board support
> (VisionFive 2, Star64, …) is partial/flaky upstream. Background:
> `docs/RESEARCH-2026-07.md` §3.

The pieces are `sys/riscv/conf/SMOLFIRE-VM` (standalone kernconf — the
riscv tree has no MINIMAL/std.virt layer to include) and
`release/tools/smolfire-qemu-riscv64.conf`. `bin/build-smolfire-vm.nu`
accepts `--arch riscv64` (cross-build; it maps to `TARGET=riscv
TARGET_ARCH=riscv64` and picks the riscv64 conf), and the hosted
workflow's `arch=riscv64` dispatch choice goes through it — size gate
only, no boot gate, and the whole leg is unexercised. The equivalent
direct make invocation from a FreeBSD 15 host (kernconf and release
conf installed into `/usr/src` as usual):

```sh
make -C /usr/src -j"$(sysctl -n hw.ncpu)" TARGET=riscv TARGET_ARCH=riscv64 buildworld
make -C /usr/src TARGET=riscv TARGET_ARCH=riscv64 KERNCONF=SMOLFIRE-VM buildkernel
make -C /usr/src/release cloudware-release \
     TARGET=riscv TARGET_ARCH=riscv64 KERNCONF=SMOLFIRE-VM \
     WITH_CLOUDWARE=yes CLOUDWARE=smolfire \
     SMOLFIRECONF=/usr/src/release/tools/smolfire-qemu-riscv64.conf \
     SMOLFIRE_FORMAT=qcow2 SMOLFIRE_FSLIST=ufs VMSIZE=2g
```

Boot under QEMU (`-machine virt` boots OpenSBI firmware, then an EFI
loader — install the `u-boot-qemu-riscv64` port/package for `u-boot.bin`,
or use an EDK2 riscv64 firmware build):

```sh
qemu-system-riscv64 -machine virt -cpu rv64 -smp 2 -m 512M \
  -bios /usr/local/share/opensbi/lp64/generic/firmware/fw_jump.elf \
  -kernel /usr/local/share/u-boot/u-boot-qemu-riscv64/u-boot.bin \
  -drive file=smolfire.ufs.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci -display none -serial mon:stdio
```

Expect breakage on first run: the FIX-10 package list assumes the
riscv64 pkgbase catalog carries the same names as amd64/aarch64
(unverified), and the loader-console settings mirror arm64 (unverified).
Record first-build findings in `docs/UR-BSD-VERIFY.md`.

## Testing the image

After a successful build, run the acceptance suite:

```sh
# Boot timing gate (aarch64 — expects HVF on Apple Silicon)
expect tests/time-to-ready-arm64.exp

# Full test runner
nu tests/run-tests.nu --suite e2e
```

## Hard-won fixes encoded in the pipeline

These are the Phase I lessons that silently break a naive build:

| Fix | What breaks without it |
|-----|------------------------|
| `/etc/src.conf` with `WITHOUT_SENDMAIL=yes` | `freebsd.cf` install fails, cascades through 8 make levels |
| `WITHOUT_DEPEND_FILES=yes` | Bad substitution from `bsd.dep.mk` in LLVM builds |
| Run the release image step as root | Empty pkgbase produced silently |
| `VMSIZE=2g` | 4g default needs 4+ GiB of free disk |
| Kernel obj KEPT until after the image step (FIX-9 reverses FIX-8) | `make packages` fails staging the kernel from the deleted objdir |
| `cloudware-release` + `SMOLFIRECONF=` (FIX-9) | `vm-image ... CLOUDWARE_CONF=` never sources the conf — filter/trim/sshd silently skipped |
| `git config safe.directory /usr/src` | Release make fails on git version check |
| Disk check before starting | Late failure after hours of build time |
| Gated pipeline (abort on any stage failure) | Release starts after failed buildworld |
