# SMOLFIRE aarch64 — feasibility spike (smolfire-a64)

Status: **GO for the QEMU `virt` direct-kernel path, with high confidence on
the boot mechanism. CONDITIONAL / UNPROVEN for Firecracker on aarch64.**
Nothing here was built from FreeBSD sources (no FreeBSD host, no KVM on the
spike machine); everything below is either read from releng/15.0 or Firecracker
sources, or **executed** against the shipped FreeBSD 15.0-RELEASE arm64
kernel. Each claim says which. Open risks and the exact CI run that closes
them are listed at the end.

The artifact is **one arm64 Image file**, not an ELF (see Q1/Q2): the amd64
SMOLFIRE is "one PVH ELF"; the aarch64 twin is "one Image". Wrapping is
already in the FreeBSD tree (`sys/conf/Makefile.arm64`, the `kernel.bin`
rule) and the kernel side (`options LINUX_BOOT_ABI`) is already in
`std.arm64`.

## Verdict table

| Question | Answer | Evidence |
|---|---|---|
| (1) Can the FreeBSD arm64 kernel **ELF** be booted directly (no loader/EFI)? | **No.** `-kernel <ELF>` is infeasible: ELF `p_paddr` equals the KERNBASE virtual address, and QEMU passes no DTB to ELF kernels. | executed + QEMU docs |
| (1b) Can it boot as a Linux-style **Image** with no loader/EFI? | **Yes — executed.** Real 15.0-RELEASE GENERIC kernel, wrapped with the upstream recipe, boots under QEMU TCG to `mountroot>` (no rootfs) and to `login:` (with a disk root). | executed (below) |
| (1c) Is the embedded MD_ROOT root honoured? | **Source-verified, not yet executed on arm64.** Code path is machine-independent and identical to amd64; arm64 locore maps everything after `etext` RW, so the writable MFS is not read-only-mapped. Needs one CI build. | source |
| (2) Firecracker aarch64 needs a raw arm64 Image — can the kernel be wrapped? | **Yes, same file as (1b).** Firecracker's loader only checks the `ARM\x64` magic at offset 56 and loads at DRAM+2 MiB (2 MiB aligned). Console is the open issue (ns16550a, no `stdout-path`). | Firecracker + linux-loader source; **not executed** |
| (3) Minimum kernconf / build target / rootfs changes | `include SMOLFIRE-VM` + `device uart_ns8250` + de-debug; `kernel-toolchain` + `buildkernel TARGET=arm64 TARGET_ARCH=aarch64`; arm64 static rescue as `RESCUE_SRC`; `bin/mk-arm64-image.sh`. All implemented behind `--arch aarch64`. | files + tests + `config(8)` run |
| (4) CI gate | `bin/ci/aarch64-boot-probe.sh` with `PROBE_KERNEL=1` on `ubuntu-24.04-arm`; pass marker `SMOLFIRE_READY`. Classifier proven with the real kernel on real QEMU. | executed |

## What was executed (reproducible)

Host: x86-64 Linux, QEMU 8.2.2 `qemu-system-aarch64`, cross-ISA TCG (the
worst case; the CI gate runs same-ISA on an arm64 runner).

1. **Real kernel.** Downloaded
   `https://download.freebsd.org/releases/arm64/aarch64/15.0-RELEASE/kernel.txz`
   (sha256 `0ebebac26aab846cef11c54b8221f4f4d8dd6234f9f8d75c37c4dfa10ce95f6d`,
   matches the release `MANIFEST`) and extracted `./boot/kernel/kernel`:
   ELF64 EXEC, AArch64, entry `0xffff000000000800`.
2. **ELF is not loadable.** `readelf -l` shows every PT_LOAD with
   `PhysAddr == VirtAddr` in the `0xffff0000_...` range. A synthetic probe
   kernel linked the same way (high VA == PA) printed nothing under
   `qemu -machine virt -kernel` (never executed), while the same probe as a
   non-ELF Image printed its `x0`. Independently, QEMU's own `virt` docs
   (v8.2.2 `docs/system/arm/virt.rst`): "Linux kernel boot protocol (any
   non-ELF file passed to `-kernel`): the address of the DTB is passed in x0;
   ... bare-metal (any other kind of boot): the DTB is at the start of RAM".
   A phys-linked probe ELF observed `x0 = 0`.
3. **Image wrapper = upstream recipe.** `llvm-objcopy --wildcard
   --strip-symbol='$[adtx]*' --output-target=binary`, then
   `nm | awk -f sys/tools/arm_kernel_boothdr.awk -v hdrtype=v8booti`, then
   `cat header payload` — exactly the `${KERNEL_KO}.bin` rule of
   `releng/15.0:sys/conf/Makefile.arm64`. Result: 15,063,520 bytes; header
   `b +0x800` (`14000200`), `image_size=0x1121000` (= `_end - kernbase`),
   `flags=8`, magic `644d5241` at offset 56. (`bin/mk-arm64-image.sh`
   reproduces it byte-identically.)
4. **Boot, no root device.**
   `qemu-system-aarch64 -machine virt -cpu max,pauth-impdef=on -m 1024M
   -smp 2 -kernel Image -append "FreeBSD: -v" -serial file:...`:
   `Excluded memory regions: 0x40200000 - 0x41653fff` (kernel image placed at
   RAM base + 2 MiB), memory from the FDT (`Physical memory chunk(s)`),
   `Found 2 CPUs in the device tree`, `EFI systbl not available`, PSCI, GIC,
   `uart0: <PrimeCell UART (PL011)> ... console (115200,n,8,1)`,
   `Starting CPU 1`, "Release APs...done", then `mountroot>` in ~24 s wall.
5. **Boot with a disk root, through userland.** Same Image plus the stock
   15.0-RELEASE arm64 UFS VM image as a virtio disk and
   `-append "FreeBSD: vfs.root.mountfrom=ufs:/dev/gpt/rootfs"`:
   `Trying to mount root from ufs:/dev/gpt/rootfs`, rc, DHCP on `vtnet0`,
   `login:` — i.e. kernel → init → rc → getty with **no loader and no EFI**.
   (`TIME_TO_LOGIN=173s` cross-ISA, dominated by stock firstboot.)
6. **cmdline guard is real.** The same command line **without** the
   `FreeBSD:` prefix is ignored (kernel drops to `mountroot>`):
   `machdep_boot.c` `CMDLINE_GUARD "FreeBSD:"`. Everything that rides the
   cmdline (`smolfire.ip=`, `smolfire.gw=`, `vfs.root.mountfrom=`,
   `hw.uart.console=`) needs that prefix. arm64 splits the cmdline on
   whitespace only (`boot_parse_cmdline` → `" \t\n"`), unlike amd64 PVH, so
   commas in values are fine.
7. **Probe classifier with the real kernel.** `PROBE_KERNEL=1
   sh bin/ci/aarch64-boot-probe.sh Image 240 max,pauth-impdef=on` on the
   real qemu: `MARKER=kernel T=0s`, `VERDICT=fail-definitive (mountroot)`,
   exit 2. With `PROBE_PASS='login:'`, the disk root and
   `PROBE_QEMU_EXTRA=-drive ...`: `TIME_TO_LOGIN=173s`, `VERDICT=pass`,
   exit 0.
8. **Stock arm64 `/rescue/rescue` has what the SMOLFIRE rc needs.** The
   `./rescue/rescue` member of the 15.0-RELEASE arm64 `base.txz` (sha256
   `d63d5c5b...f1343`, matches `MANIFEST`) is a 17,238,648-byte static EXEC
   (no INTERP/DYNAMIC) with every name `bin/build-smolfire.sh` links
   (init sh ifconfig route ping fetch nc sysctl mount umount mount_nullfs
   devfs mdconfig ls cat echo ps sleep hostname kenv dmesg df date reboot).
9. **Kernel config parses.** `usr.sbin/config` from releng/15.0 (C++; built
   on Linux with a small shim) run over `sys/arm64/conf/SMOLFIRE` and
   `SMOLFIRE-VM` against releng/15.0 `sys/conf/{files,options}*` and
   `std.{arm64,dev,virt}`: both configure with no warnings;
   `LINUX_BOOT_ABI`, `MD_ROOT`, `FDT` set; `uart_dev_ns8250.o` present in
   SMOLFIRE and absent in SMOLFIRE-VM (see "Findings").

## Q1 — direct boot, x0, FDT, MD_ROOT (releng/15.0 sources)

* `sys/arm64/conf/std.arm64` has `options LINUX_BOOT_ABI  # Boot using booti
  command from U-Boot`. `locore.S` (`#if defined(LINUX_BOOT_ABI)`): if `x0`
  is non-zero and below KERNBASE it is treated as the physical address of an
  FDT ("Booted by U-Boot booti with FDT data"), mapped in a 2 MiB window
  and copied (`booti_fdt`). `machdep_boot.c` `linux_parse_boot_param()`
  validates it with `fdt_check_header`, builds fake preload metadata, and
  `parse_fdt_bootargs()` feeds `/chosen/bootargs` to kenv (guarded, above).
* `machdep.c` `initarm()`: with no EFI map it takes RAM from the FDT
  (`fdt_foreach_mem_region`), reserved regions from the FDT, then
  `cninit()` — console from `/chosen/stdout-path` (QEMU `virt` provides it:
  PL011 at 0x09000000, which `std.virt` compiles in via `device pl011`).
* `locore.S`: "We are loaded at a 2MiB aligned address; MMU on with identity
  map or off". QEMU placed the Image at 0x40200000, Firecracker places it at
  0x80200000; both 2 MiB aligned, and the kernel derives its load address
  with `get_load_phys_addr` (position independent).
* MD_ROOT: `std.arm64` has `options MD_ROOT`, `std.dev` has `device md`.
  `kern.post.mk` links `embedfs_<img>.o` (`sys/dev/md/embedfs.S`, which has
  an explicit `__aarch64__` BTI-note branch) when `MD_ROOT_SIZE` is unset;
  `md.c` `md_preloaded()` sets `rootdevnames[0] = "ufs:/dev/md0"`.
  `locore.S` maps text (up to `etext`) RO+X and everything after it RW+XN,
  so the orphan `mfs` section is a writable root (`pmap.c` has no later
  `.rodata` remapping; checked by grep, not by a boot).

## Q2 — Firecracker on aarch64 (Firecracker `main`, 2026-10-01; not executed)

* Docs (`docs/rootfs-and-kernel-setup.md`): "on aarch64 it supports PE
  formatted (`Image`) images". The FreeBSD guide there covers FIRECRACKER
  on x86 only.
* `src/vmm/src/arch/aarch64/mod.rs`: kernel loaded at
  `SYSTEM_MEM_START + SYSTEM_MEM_SIZE` = `0x8000_0000 + 0x20_0000`;
  `linux-loader` `PE::load` checks only magic `0x644d5241`, uses
  `text_offset` from the header only when `image_size != 0` (FreeBSD's is
  0), rejects non-2 MiB-aligned bases, and copies the **file** (BSS beyond
  the file is zero RAM; locore zeroes BSS anyway).
* `vcpu.rs`: PC = kernel start, **x0 = FDT address** at the last 2 MiB of
  DRAM — the same contract as QEMU's Linux protocol, so the same Image.
* Open: the FDT has `uart@... compatible="ns16550a"` and **no
  `/chosen/stdout-path`**. `std.virt` has only PL011, so
  `sys/arm64/conf/SMOLFIRE` adds `device uart_ns8250`, and the console must
  be selected from the cmdline: `uart_cpu_arm64.c` calls `uart_getenv()`
  first, i.e. `hw.uart.console="mm:0x40002000,rs:0,rw:1,br:115200"` in
  `boot_args` (serial MMIO is `1 GiB + 2 * MMIO_LEN` per `layout.rs`, i.e. 0x40002000 if
  `MMIO_LEN` is 0x1000 — not checked; register shift/width are **unverified
  guesses** — validate on hardware).
  The virtio-mmio devices are FDT nodes (`virtio,mmio`), which FreeBSD's
  `virtio_mmio` + simplebus already attach.
* No hosted runner can run Firecracker/aarch64: `ubuntu-24.04-arm` has no
  `/dev/kvm` (ledger, runner capability map). It needs self-hosted ARM
  hardware, so Firecracker stays an unverified follow-up and is **not** in
  the workflow.

## Q3 — kernconf, build, rootfs

* `sys/arm64/conf/SMOLFIRE`: `include SMOLFIRE-VM` (the CI-proven arm64
  base: `std.arm64` + `std.dev` + `std.virt`, hardware drivers stripped,
  WITNESS/INVARIANTS off, `MODULES_OVERRIDE` trimmed), `ident SMOLFIRE`,
  `device uart_ns8250`, and the same `nooptions` de-debug items as amd64.
  `MD_ROOT`/`md`/`TMPFS`/`FFS`/`FDT`/`LINUX_BOOT_ABI` already come from
  `std.arm64`/`std.dev`/`std.virt`.
* Build (same `kernel-toolchain` + `buildkernel` as amd64, no buildworld):
  `TARGET=arm64 TARGET_ARCH=aarch64`, `KERNCONF=SMOLFIRE MFS_IMAGE=...`,
  objdir `/usr/obj/usr/src/arm64.aarch64/sys/SMOLFIRE/`; then
  `bin/mk-arm64-image.sh <objdir>/kernel.full /root/smolfire-kernel-aarch64`
  (the ELF is kept beside it as `.elf` for symbols). Works as a cross-build
  from the existing amd64 build VM or natively on aarch64.
* `bin/build-smolfire.sh --arch aarch64` changes, all behind the flag
  (amd64 default is byte-for-byte the same path):
  * `RESCUE_SRC` must be an **aarch64** ELF (`e_machine == 0xb7` check,
    fail loud) — a cross-building amd64 VM's own `/rescue` is the wrong ISA.
    The workflow takes it from the sha256-pinned arm64 `base.txz`.
  * the `pv.c` (Xen PVH) and `tsc.c` (x86 TSC) patch blocks are skipped;
    they do not exist on arm64 (boot is the Image protocol, timer is the
    generic counter).
  * `SMOLFIRE_TSLOG=1` is rejected (amd64-only variant).
  * rc/rootfs are shared: `kenv smolfire.ip` is fed from `/chosen/bootargs`
    instead of the PVH cmdline (same `kenv` interface, `FreeBSD:` prefix).
* Size estimate (unverified): stock arm64 `/rescue/rescue` is 17.2 MB; the
  Image should land in the same order as the amd64 37 MiB ELF.

## Q4 — CI gate

`bin/ci/aarch64-boot-probe.sh` gained a kernel mode (default behaviour and
`tests/aarch64-boot-probe-test.nu` untouched):
`PROBE_KERNEL=1 PROBE_APPEND='FreeBSD: ...' PROBE_PASS=SMOLFIRE_READY
PROBE_QEMU_EXTRA='-netdev ... -device virtio-net-pci,...'`; no AAVMF, no
disk, same exit-code/VERDICT contract (pass 0, fail-definitive on
`panic`/`mountroot>` 2, timeout 3, eof 4).
`.github/workflows/smolfire-a64.yml` is `workflow_dispatch`-only and both
jobs are gated on `inputs.enable` (default false): `build` cross-builds on
`ubuntu-latest` (nested KVM build VM, as `smolfire.yml`), `gate` boots the
Image on `ubuntu-24.04-arm` (same-ISA TCG). It is not wired into `ci.yml`
or any push/PR trigger.

## Findings worth recording (for the ledger)

1. **arm64 has no `MINIMAL` conf in releng/15.0** (`sys/arm64/conf/MINIMAL`
   is a 404). Comments in `sys/arm64/conf/SMOLFIRE-VM` that say devices are
   "kept via MINIMAL" are wrong; those come from `std.arm64`/`std.dev`.
2. **`uart_ns8250` link risk in SMOLFIRE-VM (unresolved).** In releng/15.0,
   `dev/uart/uart_cpu_arm64.c` references `uart_ns8250_class`
   unconditionally, and `dev/uart/uart_dev_ns8250.c` is only compiled for
   `device uart_ns8250` (or `uart_snps`). `config(8)` over `std.arm64 +
   std.dev + std.virt` (SMOLFIRE-VM) shows no `uart_dev_ns8250.o`, while
   GENERIC gets it from SoC `std.*` files. The ledger records SMOLFIRE-VM as
   building green on 2026-09-24, so either that tree differed or this reading
   is incomplete; SMOLFIRE (arm64) adds the device explicitly, which is right
   either way. If a future SMOLFIRE-VM kernel build fails to link, this is
   the first place to look.
3. **`arm_kernel_boothdr.awk` uses awk doubles** on 64-bit kernel addresses
   (`addr % kernbase`). At `0xffff000000000000` doubles are 2 KiB-granular,
   so a `_start`/`_end` that is not 2 KiB-aligned is silently rounded (an
   unaligned `_start` yields a wrong `b _start`). Checked identical on
   mawk, gawk and one-true-awk 20231127 (the awk FreeBSD ships; all are
   IEEE doubles). `bin/mk-arm64-image.sh` therefore feeds the awk rebased
   offsets (synthetic small kernbase, offsets computed in sh), exact on
   every awk; `tests/smolfire-a64-test.nu` section 2b asserts byte-identical
   Images across awks for an unaligned layout. Header fields were also
   inspected on the real 15.0 kernel and that Image booted.
4. QEMU `virt` with an ELF `-kernel` leaves `x0 = 0` (bare-metal protocol),
   so even a phys-linked FreeBSD ELF would lack the FDT pointer.

## Not proven here — what CI must show

* `make buildkernel KERNCONF=SMOLFIRE` (arm64 cross) configures, compiles and
  links; in particular the `uart_ns8250_class` reference above.
* The embedded MFS mounts as root on arm64 (`md0: Embedded image ...`,
  `Trying to mount root from ufs:/dev/md0`) and rc reaches `SMOLFIRE_READY`.
  The mechanism is MI and the amd64 twin is green, but arm64 has never run it.
* `SMOLFIRE_NET_*`: the workflow does not gate networking yet.
* Firecracker aarch64 (console selection, FDT nodes) — needs ARM KVM
  hardware; out of scope for hosted runners.

Trigger: dispatch **SMOLFIRE aarch64 microVM (experimental)** with
`enable=true` (≈ 1–2 h; the build job is the long pole, the gate ≈ 1–5 min).
