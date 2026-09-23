# AGENTS.md

## Role

Smallest boot/runtime substrate and storage research harness.

## Owns

- microVM boot/runtime
- filesystem/runtime benchmarks
- FreeBSD/NetBSD/rump lower-bound experiments

## Do not duplicate

- agent orchestration DB
- provider routing logic
- image deployment receipts

## Sibling repos to consult first

- ryanmaclean/bop
- ryanmaclean/genoa
- ryanmaclean/moth
- ryanmaclean/agent-jail
- ryanmaclean/skills

## Cross-project context

Read `docs/CROSS-PROJECT-LESSONS-2026-09.md` before making architectural changes.

## Agent delegation

- Primary GitHub coding agent: Copilot when assignable/available.
- Fallback: delegate the issue or PR to Codex with `@codex`.
- Do not treat Copilot/Codex state as canonical project state; keep canonical work in repo issues/BOP/filesystem state.
