# External programs executed by the offline CI suites

Facts only. This lists which external programs five `nu-tests` suites execute
and where they run in `.github/workflows/ci.yml`. Several listed programs
(GNU binutils, GNU coreutils and awk variants, bash, expect, QEMU, qemu-img)
carry licenses outside a literal MIT/BSD/Apache-2.0-only list. **Whether any of
them is acceptable under the repository's tool-license policy is an open
question that belongs to the repo owner. This document takes no position on it
and does not claim any tool is cleared.** No step added with these suites
installs anything: each tool is used only if the runner image already provides
it.

How the list was derived: each suite was run with
`strace -f -e execve` on Linux (the executed-program set is the union of what
that run launched), then re-run with a restricted `PATH` (a symlink farm with
`as ld objcopy nm size readelf expect qemu-system-aarch64 qemu-system-riscv64
qemu-img` removed) to confirm which absences degrade to SKIP. macOS behaviour
was NOT executed here; the macOS column is by reading the suites, and is why
the heavier suites are Linux-only in CI.

`nu` itself (pinned by `.github/nu-version`) is required by every suite and is
not repeated below. "Required" means the suite fails or cannot run without it;
"optional" means the suite prints a SKIP line for that portion and still
passes.

| Suite | CI OS | External programs it executes | Required / optional |
|---|---|---|---|
| `release-plan-test.nu` | ubuntu-latest, macos-latest | none required. `sha256sum` (Linux) or else `shasum -a 256` (macOS) for one cross-check of `SHA256SUMS` / per-file `.sha256` | all optional: with neither present only that cross-check is skipped; the digest check done by nu's own `hash sha256` always runs. Confirmed with `PATH=/usr/local/bin` |
| `reassemble-plan-test.nu` | ubuntu-latest, macos-latest | `tar` (`-cf`, `-xpf`, `-tf`), `touch` | required (POSIX base utilities) |
| `smolfire-a64-test.nu` | ubuntu-latest only | `sh` (runs `bin/build-smolfire.sh`, `bin/mk-arm64-image.sh`, `bin/ci/aarch64-boot-probe.sh`), `mktemp`, `rm`, `cp`, `chmod`, `stat`, `ln`, `mkdir`, `cat`, `grep`, `head`, `tr`, `cut`, `wc`, `dirname`, `dd`, `du`, `ls`, `sleep` (the build scripts and the test); stub `make`/`makefs`/`sysctl`/`fake-qemu.sh`/`nm-n.sh` are created by the test itself. Binutils-dependent sections: `as`, `ld`, `objcopy`, `nm`, `size`, `od`, `cmp`, and each of `mawk`, `gawk`, `original-awk`, `awk` that exists. Probe section: `expect` (+ `stty`, via expect) | POSIX base utilities and `sh`: required. `as`/`ld`/`objcopy`/`nm`/`od`/`awk` (section 1) and `as`/`ld`/`objcopy`/`nm`/`size`/`od`/`awk`/`cmp` (section 2): optional, each section SKIPs (prints `SKIP: ...`) if any is missing or if host `as`/`ld` cannot build the synthetic ELF. `expect`: optional, SKIP. Confirmed by running with those tools removed from `PATH` |
| `boot-time-cuts-test.nu` | ubuntu-latest only | `bash` (executes the release conf `vm_extra_pre_umount` under stubs), and what that hook runs: `find`, `sed`, `sort`, `du`, `awk`, `grep`, `head`, `tr`, `wc`, `cat`, `touch`, `rm`, `mktemp`; `readelf` | `bash` and the POSIX utilities: required (the suite SKIPs only the hook-execution part if `bash` is absent). `readelf`: optional (the conf calls it with `\|\| true`; confirmed passing with it removed) |
| `boot-gates-test.nu` | ubuntu-latest only | `bash` (`bash -n` and executing the gate step text from `build-image-hosted.yml`), `sh`, `mktemp`, `chmod`, `rm`, `cat`, `grep`, `sed`, `head`, `tail`, `tee`, `sleep`; `expect` (+ `stty`) for the riscv64 probe cases; `qemu-system-riscv64` and `qemu-img` only for the real-firmware case b5, which also needs `/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin` | `bash`, `sh`, POSIX utilities: required. `expect`: optional (prints `SKIP riscv64: expect(1) not installed` and ends green, the precedence/gate cases a1-a7 have already run by then). `qemu-system-riscv64`, `qemu-img`, u-boot image: optional (case b5 SKIPs). Confirmed with them removed from `PATH` |

## Separation of the QEMU-dependent portion

In `boot-gates-test.nu` the only portion that launches real QEMU or qemu-img is
case b5 (the real OpenSBI + U-Boot firmware chain). It is already separate from
the license-neutral logic (SOFTGATE precedence a1-a2c, gate step a3-a7, and the
riscv64 verdict classifier b1-b4, which use a fake QEMU script), and it runs
only when the tools are already present. The CI step installs no QEMU. Whether
b5 should become explicitly opt-in, or be dropped from CI, is left to the owner
together with the policy question above; no coverage was removed.

## Other facts relevant to the open policy question

- None of the five suites executes `git`, `curl` or ShellCheck. (ShellCheck
  runs in the separate `shellcheck` job of `ci.yml`, outside these suites.)
- `sha256sum` (release-plan, Linux) and `bash`, `awk` variants, `sed`, `find`,
  `du`, `readelf` and the binutils are the programs from this list that are not
  POSIX-baseline-only; each is resolved from `PATH` as provided by the runner
  image.
- The macOS runner is not exercised for `smolfire-a64`, `boot-time-cuts` and
  `boot-gates`; if the owner wants them there, run them once on macOS first
  (needs_ci).
