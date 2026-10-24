# imports/vibecode

Moved from ryanmaclean/vibecode-webgui@129302a73be9719d213561116319d13ed679fd71 on 2026-10-24
(history not carried; `git log` in vibecode-webgui keeps it).

This is the VM / microVM part of vibecode-webgui. It was split out because smolfire owns
microVM boot/runtime and VM benchmarks (AGENTS.md "Owns"). The files are copied byte-for-byte
under the same relative paths they had in vibecode-webgui. They are reference material and are
not built or run by smolfire CI.

## Licence

vibecode-webgui is MIT. These files keep that licence: see `LICENSES/vibecode-webgui-MIT.txt`
at the smolfire repo root. MIT is compatible with smolfire's Apache-2.0.

## What is here

| Path (relative to this dir) | What it was in vibecode-webgui |
|---|---|
| `scripts/vfkit/` | vfkit (Apple Virtualization.framework CLI) scripts that build and launch Alpine, Node and VS Code server VMs, with docs |
| `scripts/benchmarks/` | VM benches, launchers and comparisons (boot latency, applevf fastboot, firecracker, vim/qemu, musl vs glibc, noisy neighbour, openvscode microVM). The kernel/initramfs/rootfs **builders** went to ryanmaclean/genoa instead; `benchmark_utils.py` is in both |
| `scripts/release/package-fast-openvscode-vm.sh` | tarball packager for the fast OpenVSCode microVM |
| `platforms/docker/fast-openvscode-vm/` | README and rootfs inputs for that microVM |
| `docs/virtualization/openvscode-microvm.md` | its design doc |
| `experiments/microvm/` | microVM experiment notes |
| `tools/nodejs-vm/` | Node.js VM helper |
| `infrastructure/qemu/`, `infrastructure/postgresql-9p-persistence/` | QEMU Alpine images and a PostgreSQL-on-9p persistence prototype |
| `tests/vm/`, `tests/vm-integration/`, `tests/acceptance/` | VM test suites (shell). `tests/acceptance/run_acceptance_suite.sh` still names vibecode-webgui paths such as `scripts/ralph_loop.py` and `scripts/vz/` |
| `tests/unit/scripts/` | the pytest tests for the moved Python scripts |
| `ci-reference/vm-integration-tests.yml` | the vibecode GitHub workflow that ran `tests/vm-integration`. It does nothing here because it is not under `.github/` |

The Apple VZ / Containerization Swift experiments are in `experiments/apple-vz/`. They were
added in a separate commit, so they can be dropped on their own.

## Notes for anyone reusing this

- Python: these `.py` files predate smolfire's Nushell-only rule. Each one is listed in
  `PYTHON-MANIFEST.txt`, which `tests/no-new-python-test.nu` reads. Ports to Nushell are
  welcome. Any new `.py` still fails the guard.
- Hard-coded paths: several docs and scripts still contain the original author's checkout
  paths (`/Users/.../vibecode-webgui`). They were left as they were, because this is a pure move.
- Passwords such as `vibecode`, `alpine`, `vibecode123` and `testpass` are throwaway defaults
  for local VMs in the original scripts. They are not live credentials.
- Not moved: `config/vfkit/` stays in vibecode-webgui (owner decision, vibecode #2126).
  `platforms/macos/{vm,vm-assets,swift/lima-launcher,AppleContainerRuntime}` also stay there,
  because live vibecode code (Tauri commands, `src/lib/vm`, `src/lib/container`) points at them.
