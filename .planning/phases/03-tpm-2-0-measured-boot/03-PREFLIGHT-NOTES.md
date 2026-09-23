# Phase 3 — Preflight Notes

## Nushell Install Verified

- nu 0.112.2 installed at /home/studio/.local/bin/nu on <kvm-host> (<kvm-host-ip>)
- curl to github.com/nushell releases succeeds from <kvm-host> (outbound internet available)
- Binary is x86_64-unknown-linux-musl (self-contained, no libc dependency)
- Verified: 2026-06-04
- Command: `$HOME/.local/bin/nu --version` outputs `0.112.2`
- File size: 57208392 bytes (~54 MB)

## Plan 01 Wave 1 Probe — 2026-06-04

### qemu-x86_64-static

Status: ABSENT

`/usr/bin/qemu-x86_64-static` does not exist on <kvm-host>.

FALLBACK: pkg chroot via QEMUSTATIC is not possible. Wave 2 must use the
native FreeBSD build approach (D-01): the build runs directly on <kvm-host>
(Linux x86_64 host with FreeBSD toolchain in chroot, or a FreeBSD VM/jail).
The VM image build should not require cross-architecture emulation since the
target architecture (amd64) matches the build host architecture (x86_64).
pkg install into the DESTDIR chroot will run natively without QEMUSTATIC.

### smolbsd-ci output directory

Status: CREATED

`/home/studio/smolbsd-ci` created and confirmed empty (ready for Wave 2 build output).

### freebsd-src tree

Base path: `/home/studio/bsd-build/src/freebsd-src`

#### SMOLBSD kernel config

Path: `/home/studio/bsd-build/src/freebsd-src/sys/amd64/conf/SMOLBSD`

Verification output:
```
device tpm              # TPM 2.0 (CRB + FIFO interfaces)
```

Status: PRESENT — contains "device tpm", KERNCONF=SMOLBSD will compile in TPM support.

#### smolfire-qemu.conf

Path: `/home/studio/bsd-build/src/freebsd-src/release/tools/smolfire-qemu.conf`

Verification output:
```
export VM_EXTRA_PACKAGES="tpm2-tools"
```

Status: PRESENT — contains VM_EXTRA_PACKAGES=tpm2-tools, pkg will install
tpm2-tools into chroot during image build.

### Summary for Wave 2 executor

| Check | Result |
|-------|--------|
| qemu-x86_64-static | ABSENT — native build only, no QEMUSTATIC needed for amd64 |
| /home/studio/smolbsd-ci | CREATED |
| freebsd-src/sys/amd64/conf/SMOLBSD | PRESENT (device tpm) |
| freebsd-src/release/tools/smolfire-qemu.conf | PRESENT (VM_EXTRA_PACKAGES=tpm2-tools) |

Wave 2 can proceed with native amd64 build. No cross-architecture emulation needed.
