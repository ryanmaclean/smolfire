# pkgbase custom-kernel watch (issue #39, item 5)

**Question:** can a custom (non-GENERIC) kernel such as `SMOLFIRE-VM` be
shipped as a first-class pkgbase package, so we can stop treating it as a
special case?

**Current answer (checked 2026-09-22):** **no change. Verdict:
`keep-source-built`, status `knob`.** A `KERNCONF` passed to `make packages`
already produces a `FreeBSD-kernel-<conf>` package, and our release pipeline
already depends on that. Upstream still has no documented, standalone way
to package a custom kernel, and the official repos ship only GENERIC-family
kernels. There is nothing new to adopt.

This file is the current answer plus the reference for `bin/pkgbase-watch.nu`,
which re-derives the answer from upstream sources every quarter.

## 1. Current state, with sources

The claims fall into three tiers: **documented and supported**, **possible
with knobs** (it works from the source tree but nothing documents it as a
supported workflow), and **not possible**.

| Capability | Tier | Evidence |
|---|---|---|
| Install base (world + GENERIC kernel) from packages | **Documented and supported** | pkgbase is the bsdinstall default in 15.1. VM/cloud images use a packaged base and get `pkg(7)` preinstalled ([15.1 relnotes](https://www.freebsd.org/releases/15.1R/relnotes/)). Covered by [Handbook 27.8](https://docs.freebsd.org/en/books/handbook/cutting-edge/#pkgbase) and freebsd-base(7). |
| Build your own base package repo from source (`make packages` / `update-packages`) | **Documented and supported** | [build(7)](https://man.freebsd.org/cgi/man.cgi?query=build&sektion=7&manpath=FreeBSD+15.1-RELEASE) and [Handbook 27.8.3](https://docs.freebsd.org/en/books/handbook/cutting-edge/#build-pkgbase-packages-locally) (`buildworld && buildkernel && packages`). Neither mentions custom `KERNCONF`. |
| `make packages KERNCONF=SMOLFIRE-VM` → `FreeBSD-kernel-smolfire-vm` package | **Knob** | [`Makefile.inc1`](https://cgit.freebsd.org/src/plain/Makefile.inc1) `create-kernel-packages` names the package `kernel-${INSTALLKERNEL:tl}`, where `INSTALLKERNEL` is the first `KERNCONF`. Extra `KERNCONF`s become `kernel-<conf>` packages installed to `/boot/kernel.<conf>`. This naming dates back to the [2016 pkgbase CFT](https://lists.freebsd.org/pipermail/freebsd-pkgbase/2016-March/000032.html) (`FreeBSD-kernel-mylocalkernel`). A user built and installed `FreeBSD-kernel-tst01d` this way in Feb 2026 ([forum](https://forums.freebsd.org/threads/fbsd-15-pkgbase.101822/)). |
| Package *only* a custom kernel, without a full world build | **Not possible** (no target) | `Makefile.inc1` has no public kernel-only package target. `PKG_ABI` comes from the staged world's `/usr/bin/uname` (`PKG_ABI_FILE?= ${WSTAGEDIR}/usr/bin/uname`). A Feb 2026 forum answer says a standalone custom pkgbase kernel package is "unsupported, currently" and that support is planned ([forum](https://forums.freebsd.org/threads/freebsd-15-now-kernel-is-a-package-how-to-install-my-compiled-kernel-as-a-package.101585/)). |
| Custom kernels from the official `FreeBSD-base` repo | **Not possible** | Official package builds use `PKG_KERNCONF` = GENERIC, MINIMAL and GENERIC-MMCCAM (plus -DEBUG/-NODEBUG variants), all in `Makefile.inc1`. |
| `installkernel` over a pkg-owned kernel | **Knob** (blocked by default) | Since 15.1, `installworld`/`installkernel` refuse to run on package-installed systems ([15.1 relnotes](https://www.freebsd.org/releases/15.1R/relnotes/)). The escape hatches are `ALLOW_PKGBASE_INSTALLKERNEL`, `INSTKERNNAME`, or `pkg unregister` of the kernel package. |
| Convert existing systems (pkgbasify) with pkg ≥ 2.7 | **Documented and supported** | The [2026Q1 status report](https://www.freebsd.org/status/report-2026-01-2026-03/#_more_robust_pkgbase_conversion) says the pkgbasify improvements ship with pkg 2.7. [pkg 2.7.0](https://github.com/freebsd/pkg/releases) was released 2026-04-13, and [ports-mgmt/pkg](https://cgit.freebsd.org/ports/plain/ports-mgmt/pkg/Makefile) is now at **2.8.4**. This affects conversion only, not custom kernels. |

### Status reports

- **2026Q1:** had two entries. "More robust pkgbase conversion" covers pkgbasify and pkg 2.7. "Kernel Benchmark, MAINTAINERS, and pkgdist" covers a pkgbase → distribution-set converter ([report](https://www.freebsd.org/status/report-2026-01-2026-03/)).
- **2026Q2:** has no dedicated pkgbase entry. pkgbase comes up only in passing, in the CRA/SBOM entry (SBOMs expected to ship inside base packages) ([report](https://www.freebsd.org/status/report-2026-04-2026-06/)).
- **2026Q3:** not published yet. The quarter ends on 2026-09-30, and reports usually appear 4–6 weeks later. The 2026-10-01 scheduled run will still see Q2 as the latest report. Dispatch the workflow by hand once the Q3 report appears.
- No 2026 report mentions custom kernels or kernel packages.

### What this means for smolfire

- **We already use the knob.** `bin/build-smolfire-vm.nu` runs
  `make -C release cloudware-release KERNCONF=SMOLFIRE-VM …`. That target
  depends on `pkgbase-repo`, which runs `make packages` from
  [`release/Makefile`](https://cgit.freebsd.org/src/plain/release/Makefile),
  so the local repo contains `FreeBSD-kernel-smolfire-vm`, and
  `FreeBSD-set-kernels` depends on it. The image's kernel is therefore a
  pkgbase package that we built from source. See
  [UR-BSD-VERIFY Finding 4](UR-BSD-VERIFY.md).
- **"Source-built" means we build the package, not that we skip pkgbase.**
  No upstream repo will ever carry `SMOLFIRE-VM`, and a kernel-only rebuild
  still needs a staged world. So kernel changes keep costing a buildworld
  (or `--skip-buildworld` over an existing objdir).
- **Guard against GENERIC replacing our kernel.** Any `pkg upgrade -r
  FreeBSD-base` inside a guest resolves against the official repo. This
  includes the 15.1 firstboot auto-updater, which our release confs already
  disable (see UR-BSD-VERIFY Finding 5). In the official repo,
  `FreeBSD-set-kernels` depends on the GENERIC-family kernel packages, which
  install to the same `/boot/kernel` path, so expect a file conflict or a
  swapped kernel. This is inferred from the package layout and has not been
  tested. Keep images immutable and rebuild them instead of upgrading base
  in place.
- The `pkg ≥ 2.7` trigger in the original watch has fired (2.7.0 on
  2026-04-13; ports are at 2.8.4) and changes nothing for us. It only
  improves converting systems that were not installed from packages.

## 2. How the watch works

`bin/pkgbase-watch.nu` reads public sources only. It uses no credentials
and never contacts fleet hosts.

| Source | Check |
|---|---|
| `https://www.freebsd.org/status/` | Newest `--reports N` quarterly reports (default 2). Each `<h3>` entry whose title or body mentions `pkgbase`, `pkgbasify` or `pkgdist` is a hit. In-page cross-reference links (`<a href="#…">`, e.g. the FreeBSD Foundation entry's list of sponsored projects) are ignored, so each project is reported once, by its own entry. A hit that also mentions custom kernels, `KERNCONF`, kernel packages or `FreeBSD-kernel-` is marked `kernel_related`. |
| `ports/…/ports-mgmt/pkg/Makefile` | `DISTVERSION` → `pkg_version` and `pkg_ge_2_7`. |
| `src/…/Makefile.inc1` | A `KERNCONF`-named kernel package, extra-kernel packages, a standalone kernel-package target, `PKG_ABI` tied to the staged world, the pkgbase `installkernel` guard, and the default `PKG_KERNCONF`. |
| `src/…/release/Makefile` | Whether release builds a local pkgbase repo via `make packages`. |
| Handbook `cutting-edge` (27.8 only) | Whether the pkgbase chapter mentions `KERNCONF`. |

**Classification rule** (also emitted as `custom_kernel_pkgbase.rule`):

- `supported`: a `KERNCONF`-named kernel package exists **and** either
  there is a standalone kernel-package target or Handbook 27.8 documents
  `KERNCONF`.
- `knob`: a `KERNCONF`-named kernel package exists, but only through a
  full `make packages` (today's state).
- `unsupported`: `Makefile.inc1` has no `KERNCONF`-named kernel package.
- `unknown`: `Makefile.inc1` could not be read.

**Verdict:** `reevaluate` when the status is `supported` **or** any
status-report hit is `kernel_related`. Otherwise `keep-source-built`.
`unknown` never triggers `reevaluate`. Instead the script exits with
code 2 and fills in `errors`.

### Output (schema v1)

```json
{
  "schema_version": "v1",
  "checked_at": "2026-09-23T06:58:29Z",
  "pkg_version": "2.8.4",
  "pkg_ge_2_7": true,
  "custom_kernel_pkgbase": {
    "status": "knob",
    "rule": "supported = … ; knob = … ; unsupported = …",
    "evidence": [
      {"source": "https://cgit.freebsd.org/src/plain/Makefile.inc1",
       "check": "kernconf_named_kernel_package", "found": true, "detail": "…"},
      {"source": "…", "check": "standalone_kernel_package_target", "found": false, "detail": "…"}
    ]
  },
  "status_report_hits": [
    {"report": "2026-01-2026-03", "quarter": "2026Q1",
     "title": "More robust pkgbase conversion",
     "url": "https://www.freebsd.org/status/report-2026-01-2026-03/#_more_robust_pkgbase_conversion",
     "terms": ["pkgbase", "pkgbasify"], "kernel_related": false, "excerpt": "…"}
  ],
  "latest_report": "2026Q2",
  "reports_checked": ["2026Q2", "2026Q1"],
  "verdict": "keep-source-built",
  "verdict_reasons": ["custom_kernel_pkgbase.status == knob; no status-report entry mentions custom/kernel packages"],
  "provenance": {"tool": "bin/pkgbase-watch.nu", "tool_version": "1.0.1", "mode": "network",
                 "sources": [{"url": "…", "ok": true, "sha256": "…", "bytes": 29805, "fixture": null}]},
  "errors": []
}
```

The evidence `check` names are stable API. `found` is `true`, `false`, or
`null` when the source was unreadable.

### Running it

```sh
nu bin/pkgbase-watch.nu                  # JSON (default; --json is explicit)
nu bin/pkgbase-watch.nu --markdown       # human summary
nu bin/pkgbase-watch.nu --reports 4      # scan more history
nu bin/pkgbase-watch.nu --fixtures tests/fixtures/pkgbase   # offline
nu bin/pkgbase-watch.nu --from result.json --markdown       # re-render, no fetch
```

Exit codes: `0` means every source was read. `2` means at least one source
failed; the JSON is still printed.

### Automation

`.github/workflows/pkgbase-watch.yml` runs at 09:17 UTC on 1 Jan, 1 Apr,
1 Jul and 1 Oct, and can also be started with `workflow_dispatch`. Each run:

1. Runs the offline parser tests.
2. Runs the live watch.
3. Writes the Markdown and JSON to the job summary and uploads both as an
   artifact.

Only if the verdict is `reevaluate` does it create one comment on #39,
tagged `<!-- pkgbase-watch:v1 -->`, or update that comment in place, using
`GITHUB_TOKEN` (`issues: write`). If any source failed, the job fails after
the summary is written.

### Tests and fixtures

`tests/pkgbase-watch-test.nu` runs through `tests/run-all.sh` and CI, and
never touches the network. It runs the watch against
`tests/fixtures/pkgbase/*.txt`. These are verbatim excerpts of the sources
as fetched on 2026-09-22: the status index, the 2026Q1 and 2026Q2 report
sections, the pkg Makefile, the relevant `Makefile.inc1` regions,
`release/Makefile`, and the Handbook 27.8 chapter. It then edits copies of
the fixtures to exercise every path:

- a standalone target or Handbook documentation → `supported` / `reevaluate`
- a kernel-related report entry → `reevaluate`
- the named kernel package removed → `unsupported`
- pkg version edge cases
- a missing source → exit 2 / `unknown`

To refresh the fixtures after an upstream format change, re-fetch the same
URLs and keep the same excerpt boundaries: `<h3>` sections for reports,
`<h2 id=pkgbase>` through `<h2 id=small-lan>` for the Handbook.
