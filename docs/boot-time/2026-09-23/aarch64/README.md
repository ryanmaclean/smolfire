# aarch64 TSLOG boot data — 2026-09-23

Issue #39 (item 4 continuation). Method: TSLOG (kernel `debug.tslog` +
`debug.tslog_user`) against the aarch64 **disk image** leg (QEMU 10.2.1,
`accel=hvf`, M1 Max, macOS 26.6.2) — not the amd64 Firecracker microVM that
`docs/boot-time/2026-09-22/` covers. Companion to `docs/BOOT-TIME-ROADMAP.md`
§1.1.

## Provenance

- Kernel: `smolfire-aarch64-kernel-SMOLFIRE-VM-TSLOG` artifact from
  <https://github.com/ryanmaclean/smolfire/actions/runs/35835055263>
  (`SMOLFIRE-VM-TSLOG` kernconf: `SMOLFIRE-VM` + `options TSLOG`).
- Base image: an APFS clone (`cp -c`, copy-on-write, original untouched) of
  `build/FreeBSD-15-aarch64-smolbsd.qcow2` (Phase-1 aarch64 image). SHA-256
  of the original, truncated per policy: `6d2a8...da3b` — full digest
  intentionally not recorded here.
- Loader config added to the clone: `kernel="kernel.tslog"` (installed at
  `/boot/kernel.tslog/` with its 4 modules) and
  `hw.bus.devctl_nomatch_enabled="0"` (PR #82's aarch64 devd→dhclient fix,
  applied here so the rc phase reflects it even though #82 was still open
  at measurement time).
- Boot command: QEMU `virt,accel=hvf` / `-cpu host` / EDK2 aarch64 firmware,
  `-m 256M -smp 2`, `-boot menu=on,splash-time=0` (PR #82's BDS-menu fix),
  per `bin/boot-phases.nu`'s launch line plus a `hostfwd=tcp::2240-:22` NIC
  for SSH.
- Login: `root` / the image's actual dev password (not the `smolfire`
  password `README.md` documents for other images — that image ships with
  `pw usermod root -h 0` already applied at a different value; not repeated
  here since it's a credential, see `bin/fix-freebsd-vm.py`).

## Files

- `tslog-runN.log` — this leg's TSLOG dump, wrapped in the
  `SMOLFIRE_TSLOG_META` / `_BEGIN` / `_END` / `_USER_BEGIN` / `_USER_END`
  markers `bin/tslog-phases.nu` expects, plus a `TIME_TO_READY=<ms>ms` line.
  The dump itself is exactly `sysctl -b debug.tslog` /
  `sysctl -b debug.tslog_user`, captured over SSH after the serial console
  reached `login:`. `TIME_TO_READY` is the host wall-clock offset (ms since
  QEMU exec) at which `login:` appeared on serial — this image's rc script
  has no built-in `SMOLFIRE_READY` gate (that's specific to the crunched
  SMOLFIRE microVM MFS root), so `login:` is the closest equivalent event.
  The READY anchor inside `debug.tslog_user` is a `/bin/echo SMOLFIRE_READY`
  run as the first SSH command (forces a real exec, not the shell builtin).
- `serial-runN.raw` — the parallel raw serial capture for each boot (boot
  messages up to `login:`), same method as `bin/boot-phases.nu`.
- `login-ms-run*.txt` — the host-side wall-clock ms-to-login value baked
  into each `tslog-runN.log`'s `TIME_TO_READY` line.
- `tslog-phases.json` — `nu bin/tslog-phases.nu --dir .` output (read-only
  use of the existing PR #55 tool, unmodified).

Each `tslog-runN.log`'s `debug.tslog_user` section has its all-zero,
never-used pid slots (`^[0-9]+ 0 0 0 "" ""$`, ~98,800 of the ring buffer's
100,000 lines) stripped before committing — confirmed byte-identical
`tslog-phases.nu` output before/after, since those lines fail the `fork > 0`
filter the tool already applies. The 1,142–1,220 real per-run records are
untouched.

## Caveats (read before citing these numbers)

- **`TIME_TO_READY` imprecision.** Unlike the Firecracker microVM's
  in-guest `SMOLFIRE_READY` print (captured on the same serial stream the
  wall clock is timed against), this leg's READY anchor is stitched
  together from two different observation points: serial `login:` for the
  host-side wall clock, and a separately-invoked SSH `/bin/echo` for the
  TSC-side anchor. The two are seconds apart under load (SSH connect+auth
  is not instantaneous), which is visible in the aggregate: the tool's
  `vmm_to_vcpu` phase (derived from the gap between these two clocks) has a
  **min of -53.6 ms** across the 3 runs — a small negative value from clock
  misalignment, not a real firmware duration. Treat `vmm_to_vcpu` and
  `vcpu_to_kernel` as noisy; `init_rc_to_ready` and `wall_to_ready` (which
  don't depend on the cross-clock stitch) are the trustworthy numbers here.
- **Host load.** Run 1 reached login in 2.2 s; runs 2–3 took 7.8–8.6 s on
  the same otherwise-idle-looking host. `docs/BOOT-TIME-ROADMAP.md`'s
  existing aarch64 section flags the same host-load noise. Median/min/max
  over n=3 is reported as-is; re-running on a quieter host would tighten
  the spread, not change the ranking.
- Not a hosted-runner measurement — local HVF only, single host, single
  session, no repeated-day averaging.
