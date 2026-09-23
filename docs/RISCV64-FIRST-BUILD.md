# riscv64 first build attempt — signal record (issue #39 item 2)

Status: **run 1 failed, root-caused, fix applied, run 2 dispatched.**

## Run 1 (failed)

- Run: <https://github.com/ryanmaclean/smolfire/actions/runs/35828913448>
- Workflow: `build-image-hosted.yml` (workflow_dispatch), branch `main`
- Job: "Build smolfire riscv64 qcow2"
- Started: 2026-09-23T06:53:40Z · Completed: 2026-09-23T09:29:18Z
- Total run duration: **2h 35m 38s** (billed job duration ~9338s)
- Conclusion: **failure**

### Per-step status

| # | Step | Status | Duration |
|---|------|--------|----------|
| 1 | Set up job | success | 1s |
| 2 | Run actions/checkout@v4 | success | 1s |
| 3 | Preflight — KVM, disk, packages | success | 21s |
| 4 | Fetch FreeBSD 15.0 base image | success | 52s |
| 5 | Create cloud-init NoCloud seed (root SSH key) | success | 0s |
| 6 | Boot FreeBSD build VM (KVM) | success | 4m38s |
| 7 | Prepare VM — packages, src tree, repo | success | 2m25s |
| 8 | **Build (world + kernel + cloudware-release) inside VM** | **failure** | **2h27m9s** |
| 9 | Compress qcow2 (in place) | skipped | — |
| 10 | Size gate (<= 512 MiB) | skipped | — |
| 11 | Boot gate (KVM, amd64 only) | skipped | — |
| 12 | Enforce size gate | skipped | — |
| 13 | Upload artifacts | success | 2s |
| 14 | Teardown VM | success | 0s |

No qcow2 artifact was produced (`BUILD_RC=2`, "no qcow2 artifact found in
/usr/obj"), so the size gate never ran — no size-gate numbers to record.

### Last 60 lines of the failing step

```
--- sha1.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/crypto/sha1.c
--- sha256c.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/crypto/sha2/sha256c.c
--- siphash.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/crypto/siphash/siphash.c
--- siphash_test.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/crypto/siphash/siphash_test.c
--- card_if.o ---
awk -f /usr/src/sys/tools/makeobjops.awk /usr/src/sys/dev/cardbus/card_if.m -c ; cc ... card_if.c
--- power_if.o ---
awk -f /usr/src/sys/tools/makeobjops.awk /usr/src/sys/dev/cardbus/power_if.m -c ; cc ... power_if.c
--- fb_if.o ---
awk -f /usr/src/sys/tools/makeobjops.awk /usr/src/sys/dev/fb/fb_if.m -c ; cc ... fb_if.c
--- fdt_common.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/fdt/fdt_common.c
--- simplebus.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/fdt/simplebus.c
--- led.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/led/led.c
--- md.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/md/md.c
--- memdev.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/mem/memdev.c
--- memutil.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/mem/memutil.c
--- mmcbr_if.o ---
awk -f /usr/src/sys/tools/makeobjops.awk /usr/src/sys/dev/mmc/mmcbr_if.m -c ; cc ... mmcbr_if.c
--- mmcbus_if.o ---
awk -f /usr/src/sys/tools/makeobjops.awk /usr/src/sys/dev/mmc/mmcbus_if.m -c ; cc ... mmcbus_if.c
--- null.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/null/null.c
--- ofw_bus_if.o ---
awk -f /usr/src/sys/tools/makeobjops.awk /usr/src/sys/dev/ofw/ofw_bus_if.m -c ; cc ... ofw_bus_if.c
--- ofw_bus_subr.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/ofw/ofw_bus_subr.c
--- ofw_cpu.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/ofw/ofw_cpu.c
--- ofw_fdt.o ---
--- ofw_cpu.o ---
In file included from /usr/src/sys/dev/ofw/ofw_cpu.c:46:
/usr/src/sys/dev/clk/clk.h:36:10: fatal error: 'clknode_if.h' file not found
   36 | #include "clknode_if.h"
      |          ^~~~~~~~~~~~~~
--- ofw_fdt.o ---
cc -target riscv64-unknown-freebsd15.0 ... /usr/src/sys/dev/ofw/ofw_fdt.c
--- ofw_cpu.o ---
1 error generated.
*** [ofw_cpu.o] Error code 1

make[2]: stopped making "all" in /usr/obj/usr/src/riscv.riscv64/sys/SMOLFIRE-VM
make[2]: 1 error

make[2]: stopped making "all" in /usr/obj/usr/src/riscv.riscv64/sys/SMOLFIRE-VM
        6.96 real        14.40 user         1.15 sys

make[1]: stopped making "buildkernel" in /usr/src

make: stopped making "buildkernel" in /usr/src
##[error]Process completed with exit code 1.
```

(cc invocations elided to their target file for readability; full command
lines are unabridged in `gh run view 35828913448 --log-failed`.)

### Triage: **kernconf option missing on riscv** (not toolchain / release-conf / runner limits)

- Preflight, image fetch, VM boot, and package/src prep (steps 3–7, ~7m
  total) all succeeded — the hosted-runner KVM path for riscv64
  cross-building works fine. Not a runner-limits issue.
- The cross-toolchain itself works: it got ~2h27m into `buildworld` +
  `buildkernel` and successfully compiled hundreds of riscv64 objects
  (crypto, cardbus, fb, fdt, mmc, ofw_bus*, etc.) with
  `-target riscv64-unknown-freebsd15.0` before failing. Not a toolchain
  issue.
- Root cause is a **kernel config omission** specific to riscv64,
  confirmed against `freebsd/freebsd-src` (`main` branch, fetched
  2026-09-23):
  - `sys/conf/files`: `dev/ofw/ofw_cpu.c   optional fdt` — this file is
    compiled unconditionally whenever `options FDT` is set (which
    `sys/riscv/conf/SMOLFIRE-VM` sets, correctly, for QEMU virt's
    device-tree enumeration).
  - `dev/ofw/ofw_cpu.c` `#include`s `dev/clk/clk.h`, which in turn
    `#include`s the *generated* `clknode_if.h`.
  - `sys/conf/files`: `dev/clk/clknode_if.m   optional clk` — the
    `.m` interface file that config(8)/make generates `clknode_if.h`
    from is itself gated on `device clk`, which `SMOLFIRE-VM` did not
    have.
  - `sys/riscv/conf/GENERIC` (upstream) carries `device clk` in its
    pseudo-devices block for exactly this reason. The smolfire riscv
    kernconf was hand-assembled as a QEMU-relevant subset of GENERIC
    (see the file's own header comment — riscv has no MINIMAL/std.virt
    layer to `include` and trim, unlike amd64/arm64) and `device clk`
    was the one line dropped that turned out to be a hard, if
    non-obvious, dependency of `options FDT` rather than of any
    particular clock-consuming peripheral.
  - amd64/arm64 SMOLFIRE-VM don't hit this: arm64 `include`s
    `std.arm64/std.virt`, which already pulls in `device clk`
    transitively; amd64 has no FDT/`ofw_cpu.c` path at all.

### Fix applied

`sys/riscv/conf/SMOLFIRE-VM`: added `device clk` immediately after
`options FDT`, with an inline comment recording the root-cause chain
above so a future editor doesn't strip it back out as looking unused.
This adds the clk framework glue only — no clock driver/peripheral
support, no size/attack-surface increase beyond `dev/clk/clk.c` and its
`.m`-generated interface stubs.

## Run 2 (dispatched)

Dispatched via `gh workflow run build-image-hosted.yml --ref
exp/riscv64-first-build -f arch=riscv64` after the fix landed on this
branch. See PR for the run link and outcome; if it also fails, the next
step per the task's stop condition is to leave it for follow-up rather
than iterate further in this pass.
