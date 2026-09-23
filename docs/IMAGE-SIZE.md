# Image size: offline shrink

`bin/shrink-image.nu` takes a finished FreeBSD/smolfire qcow2 and rebuilds
its filesystem from scratch after removing content a headless coordinator
guest never reads at runtime — detached debug symbols, static libraries,
the compiler/linker/debugger toolchain, docs/man/locale/zoneinfo data, and
kernel modules outside a small virtio-only allowlist. The source image is
never opened for writing; everything happens on a raw copy under a work
directory, and the result is verified (`fsck -n`, a read-only mount, a
protected-path check, and a shared-library orphan scan) before it is
written out. See the script's header comment for the full pipeline and
safety rails, and `tests/shrink-image-test.nu` for the removal-class tests.

## Run: Phase‑1 aarch64 image, `coordinator` profile

Executed on the FreeBSD 15.0-RELEASE-p5 amd64 build host
(`root@108.61.206.203`, 2 vCPU / 4 GiB RAM), against the Phase‑1 aarch64
image copied there as `/root/shrink/a64.qcow2`:

```
nu bin/shrink-image.nu --image /root/shrink/a64.qcow2 \
    --out /root/shrink/out/a64-trimmed --profile coordinator --extra-formats
```

Elapsed: 192s. Verify block from the run's JSON report: `fsck_n: clean`,
`mount_ro: ok`, `protected_missing: []`, `needed_check.orphans: []`,
`within_target: true` (413 MiB virtual vs. the 512 MiB `--target-mib`
ceiling). Re-checked independently after transfer: `fsck_ffs -n -f` on the
rebuilt UFS partition reports clean, 0 errors.

### Before / after

| | before | after (qcow2) | after (qcow2, zstd/zlib compressed) | after (raw, xz -9) | after (raw, zstd -19) |
|---|---:|---:|---:|---:|---:|
| size | 1.41 GiB (1,509,949,440 B) | 91.4 MiB (95,879,168 B) | 35.7 MiB (37,467,136 B) | 21.0 MiB (22,057,688 B) | 24.5 MiB (25,692,580 B) |
| virtual size | 4 GiB (4,294,508,544 B) | 413 MiB (432,649,728 B) | 413 MiB | 413 MiB | 413 MiB |

`after_used` (bytes actually referenced, before the fresh `makefs -Z`
rebuild): 89.7 MiB (94,089,216 B). `removed_bytes` (sum of every removal
class below): 1.31 GiB (1,409,130,496 B). The qcow2 shrink is driven by the
1.31 GiB removed plus rebuilding the UFS from an allocated 4 GiB/2 GiB(root)
filesystem down to a freshly-sized one at used+15% headroom (124 MiB root +
33 MiB ESP + 256 MiB swap, vs. the original 2 GiB(root)+128 MiB(ESP,
in-sector terms)+512 MiB(swap)); qcow2's own sparse/zero-run compression
handles the rest.

### Removed, by class (coordinator profile, aarch64)

| class | bytes | why |
|---|---:|---|
| debug-symbols | 691,425,280 | detached debug info + kernel symbol files; nothing reads them at runtime |
| toolchain | 273,915,904 | compiler, linker, debugger, binutils, private LLVM/clang/lldb libs; no in-guest compile |
| static-libs | 192,974,848 | 203 `.a` archives + crt objects + pkg-config data; the guest links nothing |
| kernel-modules | 70,041,600 | 703 `.ko` outside the coordinator/aarch64 allowlist, and not named in loader.conf/kld_list |
| locale | 60,764,160 | every non-`C.UTF-8` locale; i18n charmap/iconv tables; NLS catalogs |
| docs | 53,329,920 | man pages, docs, examples, dictionaries, games data, OpenSSL html, sendmail cf, file(1) magic, PCI/USB id tables |
| rescue | 17,317,888 | static crunched rescue tree; a disposable microVM is rebuilt, not repaired |
| firmware | 14,979,072 | NIC/WiFi/HBA firmware blobs; the hypervisor exposes virtio only |
| hw-tools | 10,735,616 | Chelsio/Mellanox/WiFi/Bluetooth/bhyve-host/APM/RAID-HBA tools — no such hardware in a virtio guest |
| tests | 6,230,016 | ATF/kyua test suites and runners |
| console-data | 3,555,328 | syscons/vt keymaps and fonts; the guest console is a serial UART |
| zfs | 4,677,632 | ZFS userland/boot-environment tools; the root is UFS and `zfs.ko` isn't shipped |
| loader-extras | 2,646,016 | Forth/simp/kboot/u-boot loader variants, splash images, CD/PXE/ZFS boot blocks; the installed loader is the lua one |
| zoneinfo | 2,330,624 | time zones outside the keep list (UTC, Etc, GMT, Universal, Zulu, Factory, posixrules, zone.tab/zone1970.tab, tzdata.zi, LA/NYC/London/Paris/Tokyo) |
| unbound | 1,691,648 | local-unbound resolver; not enabled, resolv.conf comes from DHCP |
| sendmail | 1,171,456 | sendmail MTA binaries; mailer.conf routes to dma(8) |
| net-debug | 1,343,488 | tcpdump; diagnostic only, install on demand |
| pkg-cache | 0 | `pkg clean -a` effect; the package database itself is kept |

**Kernel modules kept** (coordinator/aarch64 allowlist): `virtio.ko`,
`virtio_blk.ko`, `virtio_pci.ko`, `virtio_console.ko`, `virtio_scsi.ko`,
`virtio_balloon.ko`, `virtio_p9fs.ko`, `virtio_random.ko`, `if_vtnet.ko`,
`nvme.ko`, `cryptodev.ko`, `if_wg.ko`, `tmpfs.ko`, `nullfs.ko`, `procfs.ko`,
`fdescfs.ko`, `efirt.ko`. (`tpm.ko` is coordinator-profile-and-amd64-only —
see "amd64 TPM image" below.)

Shared-library check: 1,404 ELF files scanned, 369 `NEEDED` edges, 0
orphans — every surviving binary's dependencies survived the trim.
Kernel `strip --strip-debug`: no-op here (`boot/kernel/kernel` was already
stripped in this image; `bytes_before == bytes_after`).

### amd64 TPM image

`/root/shrink/amd64-030.qcow2` (27.9 MiB compressed, from an earlier
release-0.3.0 build) was present on the build host but is **not** the
amd64 TPM-attested build referenced by the task; it was not run through
`shrink-image.nu` this pass. Re-run when the real amd64 TPM image lands in
`/root/shrink/`: `nu bin/shrink-image.nu --image <that qcow2> --out
/root/shrink/out/amd64-trimmed --profile tpm`.

## Boot time: before vs. after

Measured locally (Apple Silicon, QEMU 10.2.1, HVF) with
`smolBSD-tslog/bin/boot-phases.nu`, 3 runs each, `-boot
menu=on,splash-time=0`, `snapshot=on` (source images untouched). "Before"
is a `cp -c` APFS clone of the untouched Phase‑1 image at
`/Users/studio/smolBSD/build/FreeBSD-15-aarch64-smolbsd.qcow2`; "after" is
the trimmed qcow2 scp'd back from the build host.

| phase | before (median ms, n=3) | after (median ms, n=3) |
|---|---:|---:|
| firmware (exec→loader) | 2,126 | 2,975 |
| loader→kernel | 852 | 936 |
| kernel→root_mount | 868 | 810 |
| mount→rc | 1,377 | 1,270 |
| rc→login | 23,712 | 15,452 |
| **total (exec→login)** | **28,943** | **21,099** |

Per-run totals: before = 30,511 / 28,943 / 22,381 ms; after = 20,594 /
22,297 / 21,099 ms. The gain is almost entirely in `rc→login` — fewer
kernel modules to `kldxref`/probe and a smaller UFS to fsck/mount at boot.
`tests/time-to-ready-aarch64.exp`'s 30s acceptance gate: the untrimmed
image's slowest run (30.511s) is right at that ceiling; the trimmed
image's slowest run (22.297s) has ~8s of headroom.

SSH: booted the trimmed image with `hostfwd=tcp::NNNN-:22`, waited for the
`login:` marker, then `ssh root@localhost -p NNNN`. **Note**: the
repo-wide documented dev credential is `root`/`smolfire` (README.md), but
this Phase‑1 image was built per
`plans/tinyos/PHASE-1-AARCH64-TINY-BASELINE.md`, which sets the root
password to `smolbsd` — `root`/`smolfire` gets "Login incorrect" on this
image, `root`/`smolbsd` is accepted (confirmed both on the serial console
and over SSH; `uname -a` returned `FreeBSD smolbsd-arm64 15.0-RELEASE-p5
... SMOLBSD arm64`). Filed as a docs inconsistency between README.md and
the Phase‑1 plan — worth reconciling separately; not a shrink-related
regression, since password data lives in `/etc/master.passwd`, which the
trim never touches.

## Gates run

| gate | result |
|---|---|
| `tests/shrink-image-test.nu` (nu 0.115.1, macOS) | ok |
| `tests/sizereport-test.nu` (pre-existing, unrelated to this change) | ok |
| `tests/time-to-ready-aarch64.exp` (30s ceiling) | verified via the boot-phases + console-login runs above; after ≤ 22.3s |
| `fsck -n` on the rebuilt UFS (independent re-check, not just the script's own verify block) | clean |
| SSH accept, documented dev credentials | accepted (`root`/`smolbsd` for this image — see note above) |

## Reproducing

```
# On the FreeBSD build host, as root, under /root/shrink/:
nu bin/shrink-image.nu --image /root/shrink/a64.qcow2 \
    --out /root/shrink/out/a64-trimmed --profile coordinator --extra-formats

# Tree-only trim, portable, no root/FreeBSD required (what the unit tests drive):
nu bin/shrink-image.nu trim --root <extracted-or-mounted-root> --profile coordinator --dry-run
```

## Where the next round of savings should come from

Not applied in this pass (documentation only — see the companion "release
config size-lever proposals" commit for the concrete conf diffs, applied
to no build):

- **Distribution compression**: publish the `.raw.xz` (21.0 MiB here) or
  `.raw.zst` (24.5 MiB) next to the qcow2 for distribution — 37-45%
  smaller than qcow2's own zlib/zstd cluster compression, matching
  upstream FreeBSD's own `.xz` VM images.
- **Kernel-module allowlist at build time** (`MODULES_OVERRIDE` in
  `SMOLFIRE-VM`) instead of trimming 703 modules after the fact — same
  end state, no wasted `newfs`/copy work during the release build.
- **`WITHOUT_TOOLCHAIN`/`WITHOUT_TESTS`/`WITHOUT_DEBUG_FILES`/`WITHOUT_LIB32`/
  `WITHOUT_INCLUDES`** in `/etc/src.conf` for the release build — this
  pass's toolchain/tests/debug-symbols/static-libs classes (1.15 GiB
  combined) never get built in the first place.
- **Lower `VMSIZE`** (currently `2g`) toward the ~124 MiB root this trim
  actually needs, with `growfs` on first boot, matching stock cloud
  images' pattern.
