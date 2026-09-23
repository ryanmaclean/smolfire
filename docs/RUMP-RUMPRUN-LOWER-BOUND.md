# rump/rumprun lower-bound prototype

This issue is the repository-side prototype contract for
[issue #72](https://github.com/ryanmaclean/smolfire/issues/72): define the
smallest BSD-derived substrate that can run the shared storage/BOP workload
without carrying a conventional BSD userspace in the guest.

## Decision

Start with **rumprun `hw_virtio` + NetBSD FFS**.

Why FFS first:

- stock rumprun `hw_virtio` already carries virtio block support plus
  `rumpfs_ffs`, so the first prototype does not need a custom platform port;
- NetBSD rump also has `librumpfs_lfs`, but wiring that into the bake config is
  a second step after the smallest FFS path is proven;
- this keeps the lower-bound experiment focused on the real question from #72:
  how much substrate is required once the full BSD userspace is removed.

## Checked-in artifact

The machine-readable comparison lives at:

- `docs/lower-bound-rump-rumprun.json`

Render it as JSON or Markdown:

```sh
nu bin/lower-bound-report.nu
nu bin/lower-bound-report.nu --markdown
```

The record compares three shapes:

1. the existing **SMOLFIRE one-ELF microVM** baseline;
2. the planned **NetBSD 11 MICROVM sibling** from #64;
3. the selected **rumprun `hw_virtio` + FFS** lower-bound prototype.

It also pins the shared READY/workload contract used across #63/#64/#72:

- one writable state disk;
- `create/write/append/rename/fsync`;
- crash + recovery;
- filesystem-native identity where available;
- `SMOLFIRE_READY` as the stable serial READY marker.

## Reproduction outline

The JSON file intentionally stores host-side reproduction commands rather than a
repo-local wrapper because the build depends on upstream rumprun/NetBSD tools:

1. build rumprun for `hw_virtio`;
2. compile a tiny worker into a rumprun image with `rumprun-bake hw_virtio`;
3. provision one writable FFS state image;
4. boot the unikernel under a virtio-capable VMM;
5. mount the state disk read-write, run the common BOP workload, and print
   `SMOLFIRE_READY` only after the disk and worker are ready.

## Licensing guard

Issue #72 explicitly rejects GPL/LGPL/AGPL project dependencies. The checked-in
record therefore carries the licensing verdict and the disallowed license
families next to the prototype definition so that later measurement work can
reuse the same gate.
