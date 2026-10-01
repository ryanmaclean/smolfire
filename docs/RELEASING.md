# Releasing smolfire

Releases are cut by the manual **Release smolfire Image** workflow
(`.github/workflows/release-image.yml`) from *already validated* build runs.
Nothing is rebuilt at release time: you publish the exact bytes whose size and
boot gates you trusted.

Pure logic (run validation, notes templating, checksums, digest assertion)
lives in `bin/release-plan.nu` and is tested offline against fixture GitHub
API JSON: `nu tests/release-plan-test.nu`.

## Prerequisites

1. The change is merged to `main`. GITHUB_TOKEN cannot create a tag on a
   commit whose workflow files differ from main (see
   `docs/UR-BSD-VERIFY.md`, "Release publishing"), so the workflow refuses
   runs built from non-main commits.
2. A green "Build smolfire Image (hosted runner)" run per architecture
   (artifacts `smolfire-amd64`, `smolfire-aarch64`) built from a commit on
   main, and optionally a green kernel run producing the one-ELF `smolfire-kernel`
   artifact. Artifacts expire; release soon after the runs.

## Cut a release

Dispatch **Release smolfire Image** with `mode = release`:

| Input | Meaning |
|---|---|
| `tag` | e.g. `v0.6.0` (must be a version tag) |
| `amd64_run` | run ID of the amd64 build (`run_id` still works as an alias) |
| `aarch64_run` | optional, run ID of the aarch64 build |
| `kernel_run`, `kernel_artifact` | optional, run ID and artifact name (`smolfire-kernel` default) of the one-ELF kernel |
| `target_sha` | optional commit to tag (must be on main); default is the first run's head SHA |
| `notes` / `notes_file` | release-notes body, prepended to the generated asset table |
| `prerelease` | default true |

The workflow refuses, before downloading anything, if any supplied run has
`status != completed`, `conclusion != success`, a missing/expired artifact,
or a `head_sha` that is not an ancestor of (or equal to) `main`. It then:
downloads the artifacts, runs `qemu-img check` on each qcow2 (and an ELF magic
check on the kernel), writes `SHA256SUMS` plus per-file `.sha256`, creates the
release with `--target <main commit>`, and attests every asset.

## Replace one asset

`mode = replace-asset` with the existing `tag` and **exactly one** of
`amd64_run` / `aarch64_run` / `kernel_run`. The same run validation applies.
The workflow re-uploads that asset with `--clobber`, regenerates `SHA256SUMS`
over the whole release, and asserts that the asset's GitHub digest (a) changed
and (b) equals the sha256 of the validated local file. An unchanged digest
fails the job. Replaced assets are re-attested.

## Verify a release (consumers)

```sh
# checksums
sha256sum -c SHA256SUMS
# build provenance (needs the GitHub CLI >= 2.49, no login required for public repos)
gh attestation verify smolfire-amd64-v0.6.0.qcow2 --repo <owner>/<repo>
```

`gh attestation verify` checks that the file's digest matches a signed
SLSA provenance statement issued by this repository's `release-image.yml`
workflow. Note the attestation covers the bytes the release workflow
published, i.e. it proves *which workflow published them*, while the
build-run IDs in the release notes tie them back to the validated build.

## Operational notes

- Attestations need the workflow's `id-token: write` and
  `attestations: write` permissions (declared in the workflow); the repository
  must be public or on a plan that supports attestations.
- The `actions/attest-build-provenance` action is pinned by full commit SHA;
  the SHA was read from the action repo's tags with `git ls-remote` and must be
  re-verified when bumped.
- The workflow itself can only be exercised on GitHub; run it first with
  `prerelease = true` and a throwaway tag.
