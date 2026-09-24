# smolfire

[![CI](https://github.com/ryanmaclean/smolfire/actions/workflows/ci.yml/badge.svg)](https://github.com/ryanmaclean/smolfire/actions/workflows/ci.yml)

## What it is

smolfire has two build products:

- the **SMOLFIRE microVM**: one PVH-bootable ELF with an embedded static
  `/rescue` MFS root, optimized for Firecracker and QEMU `microvm`
- a **full qcow2 compatibility image**: the older cloud/release-image path,
  retained for broader VM compatibility and package/image experiments

The one-ELF microVM is the primary path. The repository also carries a
Nushell coordinator finite-state machine that dispatches build, review, and
ops tasks to agents over an mbox+TOML mail spool.

## Status

As of 2026-07-24:

| Product | Boot gate              | Artifact size         | Notes                                  |
|---------|------------------------|-----------------------|----------------------------------------|
| **SMOLFIRE** (microVM) | **511 ms to shell under Firecracker** (569 ms QEMU microvm), TCP net gate + host ping PASS | **37 MiB — one PVH ELF is the whole OS** (kernel + static /rescue MFS root) | Primary product path: no bootloader, no disk, no pkgbase; `sys/amd64/conf/SMOLFIRE` + `bin/build-smolfire.sh` |
| amd64 qcow2 (compatibility) | 9s to login on KVM — PASS | **66.6 MiB raw, 26.6 MiB compressed download** (≤ 512 MiB gate PASS) | Built end-to-end by the hosted pipeline; [releases](https://github.com/ryanmaclean/smolfire/releases) (0.1.0: 223 MiB, 0.2.0: 91/33 MiB, diet round 2: 66.6/26.6 MiB) |
| aarch64 qcow2 (compatibility) | needs ARM hardware (see `docs/BHYVE-GATE-AMD64.md`) | cross-built by the same pipeline, size gate only | Earlier native-build baseline: 11s on HVF, 1.41 GiB pre-diet |

See `docs/UR-BSD-VERIFY.md` for the verified findings and the image-diet
plan, `docs/PHASE-1-RESULTS.md` for the original baseline report.

## Quickstart

**Prerequisite everywhere:** [Nushell](https://www.nushell.sh) **0.115.1**, the
version CI pins in [`.github/nu-version`](.github/nu-version)
(`pkg install nushell` / `brew install nushell` / a GitHub release binary —
0.112.2 fails on `str lowercase` in `bin/coord-tick.nu`; 0.111 and older fail on `get -o`).

Default path: build or download the one-ELF SMOLFIRE microVM.

1. **No FreeBSD host?** Dispatch the
   [SMOLFIRE microVM kernel workflow](.github/workflows/smolfire.yml) from the
   Actions tab. It builds `/root/smolfire-kernel` on a stock GitHub runner and
   gates the artifact separately on **size**, **boot time**, **network**, and
   **interactive shell**, with a QEMU `microvm` cross-check.
2. **Have a FreeBSD 15 amd64 host with `/usr/src`?** Install the kernconfs into
   the source tree and build the one-ELF artifact locally:

   ```sh
   sudo cp sys/amd64/conf/SMOLFIRE* /usr/src/sys/amd64/conf/
   sudo sh bin/build-smolfire.sh
   ```

   The result is `/root/smolfire-kernel` — one ELF containing the kernel and
   rootfs. This path does **not** run `buildworld`, `pkgbase`, or
   `cloudware-release`.
3. **Already have `smolfire-kernel`?** Boot it directly under QEMU `microvm`:

   ```sh
   qemu-system-x86_64 -M microvm -accel kvm -cpu host -m 512M \
     -kernel smolfire-kernel \
     -append "hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0" \
     -display none -serial mon:stdio
   # (-accel hvf on macOS; drop -accel/-cpu for slow TCG anywhere else)
   ```

   Wait for `SMOLFIRE_READY`, then use the interactive root shell on the serial
   console.

4. **Need a full qcow2 anyway?** Use the
   [hosted qcow2 compatibility pipeline](.github/workflows/build-image-hosted.yml)
   or the local `bin/build-smolfire-vm.nu` flow in **Build** below. Gate-passing
   builds can still be published via the manual `Release smolfire Image`
   workflow — check
   [Releases](https://github.com/ryanmaclean/smolfire/releases) for prebuilt
   images.

   Log in as `root` / password `smolfire` for qcow2 dev images only. Change the
   password on first login and never expose one beyond QEMU user-mode
   networking.

## Repo map

| Path | What lives there |
|---|---|
| `bin/` | Coordinator FSM (`coord-*.nu`, run via `sh bin/coord-run.sh`), primary microVM build (`build-smolfire.sh`), qcow2 compatibility build (`build-smolfire-vm.nu`), ops (`harvest.sh`, `qemu-smolfire-vm.nu`, bhyve tooling) |
| `sys/`, `release/tools/` | SMOLFIRE kernel configs and release image confs |
| `tests/` | Nu unit/integration suites + `expect` boot gates (`sh tests/run-all.sh`) |
| `docs/` | `BUILDING.md` (start here), `UR-BSD.md`/`UR-BSD-VERIFY.md` (size work), `BHYVE-GATE-AMD64.md`, `NETBSD-MICROVM-PROTOTYPE.md` |
| `plans/`, `.planning/` | Phase planning records (historical) |
| `var/` | Runtime spool/state — never committed (see `CLAUDE.md` §9) |

## Build

Primary path: the one-ELF microVM.

```sh
sudo cp sys/amd64/conf/SMOLFIRE* /usr/src/sys/amd64/conf/
sudo sh bin/build-smolfire.sh
```

This produces `/root/smolfire-kernel` and does **not** invoke `buildworld`,
`pkgbase`, or `cloudware-release`.

Need the full compatibility image instead? Use the qcow2 pipeline:

```sh
sudo nu bin/build-smolfire-vm.nu
```

That compatibility path runs setup, `buildworld`,
`buildkernel KERNCONF=SMOLFIRE-VM`, and `make cloudware-release`. Full details
for both paths live in `docs/BUILDING.md`.

## Harvest and acceptance gates

`bin/harvest.sh` fetches qcow2 artifacts from the remote build hosts (<aarch64-builder>
via jump host for aarch64, Vultr for amd64) into `var/artifacts/`, then runs
the size and boot gates and writes `var/artifacts/harvest-report.txt`:

```sh
sh bin/harvest.sh
```

Gates:
- size <= 512 MiB (`wc -c` on the qcow2)
- boot via `expect tests/time-to-ready-arm64.exp` / `tests/time-to-ready.exp`

For diagnosing image bloat, mount the rootfs and dump the top directories,
files, and pkgbase packages by size:

```sh
bin/analyze-image.sh path/to/FreeBSD-15-aarch64-smolfire.qcow2
```

Works on Linux (qemu-nbd) and FreeBSD (mdconfig). Writes a `.size-report.txt`
beside the image and exits non-zero if usage exceeds 512 MiB.

## Coordinator

The Nushell coordinator is documented in `CLAUDE.md`. To run the loop:

```sh
sh bin/coord-run.sh
```

To advance one tick by hand:

```sh
nu bin/coord-tick.nu
```

Environment overrides (all optional):

| Var             | Default                       | Purpose                          |
|-----------------|-------------------------------|----------------------------------|
| `ROOT`          | `.`                           | Repo root                        |
| `INTERVAL`      | `60`                          | Seconds between normal ticks     |
| `HALT_INTERVAL` | `10`                          | Seconds to sleep while halted    |
| `STATE_FILE`    | `var/run/coord-state.toml`    | Persisted FSM state              |
| `SPOOL`         | `var/mail/spool`              | mbox spool path                  |
| `SMOLFIRE_CLAUDE_MODEL` | `claude-sonnet-5`     | Claude model for subagent dispatch |
| `SMOLFIRE_EXECUTOR` | `vm`                      | `vm` or `jail` executor selection |

FSM states are `idle -> dispatching -> waiting -> harvesting -> halted`. On
`dispatching`, the coordinator auto-spawns the `claude` CLI for the target
agent if it is on `PATH` (Phase II wiring); otherwise it queues the request
and waits for an external agent to reply into the spool. Global emergency
stop: `touch var/mail/HALT` — `coord-run.sh` then skips `coord-tick.nu` and
sleeps for `HALT_INTERVAL` seconds until the file is removed. Per-task halt:
`var/mail/HALT.<task_id>`. To resume a halted task, send a spool message with
`X-Resume-Action: retry | abort | edit`.

## Tests

```sh
sh tests/run-all.sh
```

Runs every `tests/*-test.nu` suite. Hardware-dependent suites (TPM) report
`SKIP` instead of failing when the hardware or image is absent, so a fresh
clone is green out of the box. Individual suites can be invoked directly
with `nu tests/<file>.nu`.

## License

Apache-2.0 for project code (see [LICENSE](LICENSE)). FreeBSD base components retain their original
BSD-2-Clause / BSD-3-Clause licenses. No GPL/LGPL/AGPL dependencies.
