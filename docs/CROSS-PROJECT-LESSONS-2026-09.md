# Cross-project lessons — 2026-09

smolFire owns the **smallest boot/runtime substrate**, not orchestration.

## Reuse from sibling projects

- **BOP**: use its filesystem-as-state-machine semantics and run identity; do not invent another task database.
- **Moth**: reuse/borrow the tiny Rust actor, subagent, persistence, runlog, virtual-shell, and DogStatsD ideas instead of writing a second harness inside smolFire.
- **Genoa**: let Genoa own reproducible image/build/deploy receipts and direct-kernel/state-disk manifests.
- **agent-jail**: keep jail/OCI isolation experiments there; smolFire remains the microVM branch of the comparison.
- **skills**: treat quota-gate and other policy skills as baselines for routing/gating experiments.
- **Gas Town / Tundra**: use as orchestration controls, not implementation dependencies.

## Storage research

The common state matrix remains HAMMER1, HAMMER2, NetBSD LFS, and NetBSD FFS/WAPBL+fss. BOP state is canonical; OpenLineage is derived.

## Lower bound

Compare:
1. FreeBSD one-ELF smolFire
2. NetBSD 11 MICROVM
3. NetBSD rump/rumprun
4. software transaction ring
5. FPGA/SmartNIC/NVMe transaction sequencer

Umbrella: #78.

## Agent assignment

- Primary coding assignee: GitHub Copilot when credits are available.
- Fallback: delegate issues/PRs to Codex with `@codex` through the GitHub integration; Codex is not treated as a normal issue assignee.
