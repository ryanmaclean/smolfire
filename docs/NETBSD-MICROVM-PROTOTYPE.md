# NetBSD 11 MICROVM sibling prototype

`/home/runner/work/smolfire/smolfire/bin/netbsd-microvm-prototype.py` is a
host-side prototype for the issue "Prototype a NetBSD 11 MICROVM sibling for
SMOLFIRE". It does **not** vendor NetBSD, smolBSD, or third-party build logic.
Instead, it gives this repository a small, BSD/MIT/Apache-only way to launch a
caller-supplied NetBSD 11 `MICROVM` kernel under QEMU `microvm`, attach:

- one immutable rootfs/initrd (`--rootfs`)
- one writable state disk (`--state-image`)

and then produce a JSON report from a tiny serial marker contract.

## Marker contract

The guest should emit these serial lines during boot:

```text
SMOLFIRE_NETBSD_READY
SMOLFIRE_NETBSD_STATE_OK dev=ld0a mount=/state fs=lfs mode=rw
SMOLFIRE_NETBSD_WORKLOAD verdict=pass fs=lfs ops=128 files=16 snapshots=2 fsync_p50_ms=1.7
```

The host-side report maps those markers to the issue acceptance criteria:

- `SMOLFIRE_NETBSD_READY` → booted under QEMU microvm/PVH and emitted a stable READY marker
- `SMOLFIRE_NETBSD_STATE_OK ... mode=rw` → mounted one writable state volume
- `SMOLFIRE_NETBSD_WORKLOAD verdict=pass ...` → ran the common filesystem-state workload
- host timing + file sizes + workload metrics → artifact size, boot time, RAM, and filesystem metrics

## Example

```sh
python3 /home/runner/work/smolfire/smolfire/bin/netbsd-microvm-prototype.py \
  --kernel /path/to/netbsd-MICROVM \
  --rootfs /path/to/rootfs.fs \
  --state-image /path/to/state-lfs.img \
  --state-fs lfs \
  --append 'bootverbose=1' \
  --dry-run
```

For a real run, drop `--dry-run`. The script emits JSON on stdout and can save
the serial transcript with `--serial-log /tmp/netbsd-microvm.log`.

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
