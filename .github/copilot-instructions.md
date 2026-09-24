# Copilot instructions for smolfire

## Language policy

New scripts and tests must be Nushell (.nu). Do not add Python, shell beyond
POSIX sh glue, or other languages without owner approval.

This is enforced by `tests/no-new-python-test.nu`, run via `tests/run-all.sh`
and in CI (`.github/workflows/ci.yml`): any tracked `*.py` file outside its
explicit, reasoned allow-list fails the build. If you believe a new Python
file is genuinely required, ask the owner (Ryan MacLean) first — do not add
one speculatively.

See `AGENTS.md` for the rest of this repository's ownership boundaries and
cross-project constraints.
