# NetBSD 11 MICROVM sibling prototype

`bin/netbsd-microvm-prototype.nu` is a host-side prototype for the issue
"Prototype a NetBSD 11 MICROVM sibling for
SMOLFIRE". It does **not** vendor NetBSD, smolBSD, or third-party build logic.
Instead, it gives this repository a small, BSD/MIT/Apache-only way to launch a
caller-supplied NetBSD 11 `MICROVM` kernel under QEMU `microvm`, attach:

- one immutable rootfs, either as an initrd (`--rootfs`) or as a read-only
  virtio-blk disk (`--root-image`; the official NetBSD 11.0 MICROVM kernel has
  no md root, so real runs use this)
- one writable state disk (`--state-image`)

and then produce a JSON report from a tiny serial marker contract.
`bin/netbsd-microvm-rootfs.nu` builds the rootfs image and the state disk from
the official NetBSD 11.0 sets.

## Marker contract

The guest should emit these serial lines during boot:

```text
SMOLFIRE_NETBSD_READY
SMOLFIRE_NETBSD_STATE_OK dev=ld0a mount=/state fs=lfs mode=rw
SMOLFIRE_NETBSD_WORKLOAD verdict=pass fs=lfs ops=128 files=16 snapshots=2 fsync_p50_ms=1.7
SMOLFIRE_NETBSD_STATS t=30 pid=120 rss_kb=11420 vsz_kb=41544 cpu_pct=0.2 cputime=0:00.25   (optional, repeated)
```

The host-side report maps those markers to the issue acceptance criteria:

- `SMOLFIRE_NETBSD_READY` → booted under QEMU microvm/PVH and emitted a stable READY marker
- `SMOLFIRE_NETBSD_STATE_OK ... mode=rw` → mounted one writable state volume
- `SMOLFIRE_NETBSD_WORKLOAD verdict=pass ...` → ran the common filesystem-state workload
- host timing + file sizes + workload metrics → artifact size, boot time, RAM, and filesystem metrics
- `SMOLFIRE_NETBSD_STATS` samples → `result.stats` (RSS first/last/min/max,
  last VSZ, ps %CPU, and the average CPU over the window from the cputime delta)

## Example

```sh
nu bin/netbsd-microvm-prototype.nu \
  --kernel /path/to/netbsd-MICROVM \
  --rootfs /path/to/rootfs.fs \
  --state-image /path/to/state-lfs.img \
  --state-fs lfs \
  --append 'bootverbose=1' \
  --dry-run
```

For a real run, drop `--dry-run`. The script emits JSON on stdout and saves
the serial transcript with `--serial-log /tmp/netbsd-microvm.log`.

## Real NetBSD 11.0 artifacts (proven 2026-10-10)

The prototype runs real artifacts end to end. Everything comes from the
official NetBSD 11.0 amd64 release, checked against the release `SHA512`
lists and the PGP-signed `NetBSD-11.0_hashes.asc` (NetBSD Security Officer
2019 key, fingerprint `2711 3326 2BF3 5CB5 0D4F 5046 8926 1E17 F5EF 49FF`):

- kernel: `binary/kernel/netbsd-MICROVM.gz`, gunzipped (9.3 MB ELF; boots
  under QEMU `microvm` through PVH as is)
- rootfs: `base.tar.xz` + `etc.tar.xz`, trimmed and packed by
  `bin/netbsd-microvm-rootfs.nu` into a raw FFSv2 image
- state disk: an FFSv2 image from `bin/netbsd-microvm-rootfs.nu state`,
  mounted with `-o log` (WAPBL) at `/state`

The official MICROVM kernel decides the layout. It has `ffs`, `tmpfs`,
`msdos`, `ext2fs`, `procfs`, `kernfs`, `ptyfs` and `puffs`, but **no lfs,
hammer2, cd9660 or md root**. So the rootfs is a virtio-blk disk
(`--root-image`, attached read-only as `ld0`), not an `-initrd`, and the state
file system is `ffs-wapbl` on `ld1`. Devices are found from QEMU's
`virtio_mmio.device=` entries (`virtio0..2 at pv0`).

The guest init is `guest/netbsd-microvm/etc/rc` (POSIX sh; it replaces
rc.d): read-only root, tmpfs scratch, static SLIRP addressing (10.0.2.15/24,
gateway 10.0.2.2, DNS 10.0.2.3), the marker protocol on the console, an
optional sshd (host keys kept on the state disk), and the workload. When
`/state/agent.env` exists the workload is `/opt/datadog/bin/dd-agent-rs run`
with that environment, and the guest prints a `SMOLFIRE_NETBSD_STATS` line
every 30 s. Otherwise a small filesystem probe runs.

### Build (Linux or BSD build host; needs bsdtar, makefs, sudo)

```sh
# DL holds netbsd-MICROVM.gz, base.tar.xz, etc.tar.xz and the sets SHA512 list
gunzip -kc DL/netbsd-MICROVM.gz > out/netbsd-MICROVM
nu bin/netbsd-microvm-rootfs.nu --sets-dir DL --out out/root.img \
  --add out/dd-agent-rs:/opt/datadog/bin/dd-agent-rs:0755 \
  --authorized-keys ~/.ssh/id_ed25519.pub --hostname smolfire-netbsd
# secrets go to the state disk only, over stdin; the report lists key names only
printf 'DD_API_KEY=%s\nDD_SITE=datadoghq.com\nDD_TAGS=lab:1010\n' "$KEY" |
  nu bin/netbsd-microvm-rootfs.nu state --out out/state.img --size-mb 64 --env-stdin
```

Debian/Ubuntu ship NetBSD's makefs as the `makefs` package. The rootfs report
(`smolfire.netbsd-microvm-rootfs/v1`) records each set's SHA512, the tree
size, the CA bundle count and the image SHA256. The CA bundle is built at
image time from `/usr/share/certs/mozilla/server` into `/etc/openssl/cert.pem`
and `/etc/openssl/certs/ca-certificates.crt`, because certctl(8) needs a
writable `/etc` and the root is read-only.

### Run

```sh
nu bin/netbsd-microvm-prototype.nu --kernel out/netbsd-MICROVM \
  --root-image out/root.img --root-device ld0a \
  --state-image out/state.img --state-device ld1a --state-fs ffs-wapbl \
  --net slirp --hostfwd tcp:127.0.0.1:2252-:22 \
  --memory-mib 256 --cpus 1 --timeout 90 --hold-seconds 600 \
  --serial-log out/serial.log
```

`--net slirp` is QEMU user networking on virtio-net: no TAP, bridge or
promiscuous mode. `--hostfwd` takes comma- or space-separated QEMU hostfwd
rules. `--hold-seconds` keeps the VM up after the WORKLOAD marker so STATS
samples accumulate; QEMU is then stopped through its pidfile.

### Cross-building dd-agent-rs for x86_64-unknown-netbsd

The rustup target `x86_64-unknown-netbsd` (tier 2) links with clang and lld
against a sysroot made from the same release: `./lib`, `./usr/lib` and
`./usr/include` from `base.tar.xz` (base carries the
`usr/include/machine -> amd64` symlink) plus `./usr/include` and `./usr/lib`
from `comp.tar.xz`. A two-line wrapper is both the C compiler and the linker:

```sh
#!/bin/sh
exec clang --target=x86_64-unknown-netbsd11.0 --sysroot="$SYSROOT" -fuse-ld=lld "$@"
```

Point `CC_x86_64_unknown_netbsd` and `CARGO_TARGET_X86_64_UNKNOWN_NETBSD_LINKER`
at it and set `AR_x86_64_unknown_netbsd=llvm-ar`; ring and zstd-sys build
their C through it.

### Measured (pop, Ryzen 9 7950X, KVM, QEMU 8.2.2; 1 vCPU, 256 MiB)

| What | Value |
|---|---|
| kernel `netbsd-MICROVM` | 9,327,648 B (1,672,726 B gzipped) |
| rootfs image (trimmed base + etc + agent) | 230,793,216 B FFSv2; tree 204 MiB |
| state disk | 64 MiB FFSv2 (WAPBL) |
| dd-agent-rs, x86_64-unknown-netbsd, release | 13,165,704 B; 10,809,672 B stripped |
| kernel boot time (guest dmesg) | 382-474 ms |
| QEMU start to READY (host measured) | 1,023 ms |
| dd-agent-rs RSS, 40 samples over 1,170 s | 6.0 MiB at start, 11.3 MiB steady, 13.0 MiB max; VSZ 40 MiB |
| dd-agent-rs CPU over the same window | 1.27 s, 0.109 % of one vCPU |

The agent reported to Datadog from inside the guest over SLIRP (series,
check runs, host and inventory metadata all accepted with HTTP 202).

### Kernel command line limit

NetBSD/x86 truncates the boot command line at 255 bytes. The default
`smolfire.*` marker arguments plus QEMU's per-device `virtio_mmio.device=`
entries exceed that. The devices still attach, but trailing `-append`
arguments are lost. The report flags this as
`config.append_truncated_by_netbsd` with `config.cmdline_estimate_bytes`. The
shipped guest rc does not read the `smolfire.*` arguments.

## Notes

- The QEMU shape follows the same microvm/PVH ideas already discussed in
  `docs/BOOT-TIME-ROADMAP.md`, but keeps the implementation entirely host-side.
- The runner defaults to the repository's existing accelerator convention:
  HVF on macOS when available, KVM on Linux when `/dev/kvm` is present, TCG
  otherwise.
- The default kernel arguments include `console=com`, `root=md0a`,
  `smolfire.state_dev=ld0a`, and `smolfire.state_fs=<variant>`. Adjust with
  `--root-device`, `--state-device`, and `--append` if the guest artifact uses
  a different layout.
