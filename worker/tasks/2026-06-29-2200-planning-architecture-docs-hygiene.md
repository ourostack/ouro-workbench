# Planning: Workbench Architecture / Docs Hygiene

**Status**: approved
**Created**: 2026-06-29 22:00

## Goal
Reduce Workbench app-layer bulk around shell-adjacent UI and make current architecture/docs sources easy for future agents to find without rereading historical planning artifacts.

## Upstream Work Items
- A-006: Continue Workbench View/ViewModel Decomposition
- A-010: Refresh Workbench Architecture Docs For The Shell Split
- A-027: Clean Up Or Archive Stale Workbench Planning/Doing Docs
- A-038: Add A Cross-Repo "Normative Docs" Index

## Scope

### In Scope
- Create or refresh Workbench task docs for this lane under `worker/tasks/`.
- Extract a narrow shell-adjacent SwiftUI view module out of `Sources/OuroWorkbenchAppViews/WorkbenchViews.swift`.
- Update Workbench architecture docs to describe `ouro-native-apple-app-shell`, `OuroWorkbenchShellAdapter`, allowed dependency direction, and shell control scripts.
- Add a Workbench docs index that separates normative docs, product docs, runbooks, coverage/control docs, and historical planning artifacts.
- Fix Workbench stale setup/shortcut naming found while touching the indexed docs.
- Add minimal cross-repo docs indexes in shared shell and Ouro MD only if they are low-risk documentation-only changes.
- Run Swift validation and shell boundary validation where practical.

### Out of Scope
- Release/update lifecycle implementation.
- Shared boundary analyzer implementation.
- Large-scale Workbench view-model rewrites beyond one evidence-backed extraction bite.
- Moving or deleting historical docs; historical files remain addressable unless a dedicated archive policy already exists.

## Completion Criteria
- [ ] A-006 has at least one narrow shell-adjacent view/view-model decomposition committed.
- [ ] A-010 architecture docs describe shell ownership and dependency direction.
- [ ] A-027 Workbench docs index distinguishes current normative docs from historical planning artifacts.
- [ ] A-038 has Workbench index coverage and minimal cross-repo index updates where safe.
- [ ] Stale `Set Up Workbench` and `⌘?` drift in touched Workbench docs/comments is corrected.
- [ ] 100% test coverage on all new code.
- [ ] All tests pass.
- [ ] No warnings.

## Code Coverage Requirements
**MANDATORY: 100% coverage on all new code.**
- No `[ExcludeFromCodeCoverage]` or equivalent on new code
- All branches covered (if/else, switch, try/catch)
- All error paths tested
- Edge cases: null, empty, boundary values

## Open Questions
- [x] Should A-010 wait for A-003/A-005? The operator explicitly assigned this lane now; docs will encode current boundary language from existing `AGENTS.md` and scripts, avoiding release/update implementation claims.
- [x] Should historical Workbench docs be physically archived? No. Indexing is safer in this lane because `docs/` history may still be linked by tests, guides, or active tasks.

## Decisions Made
- Use branch/worktree `worker/architecture-docs-hygiene` because repo instructions derive `worker` as the agent name and task docs live under `worker/tasks/`.
- Treat reviewer gates as cold top-level review passes because this runtime does not expose a separate sub-agent dispatch tool.
- Use `docs/INDEX.md` as the normative/historical routing surface; this matches A-038's suggested minimal shape and avoids breaking inbound links.

## Context / References
- Audit backlog source: `/tmp/ouro-audit-backlog.md`, rows A-006, A-010, A-027, A-038 from Ouro MD `origin/worker/shared-shell-systems-audit`.
- Workbench rules: `AGENTS.md`.
- Architecture docs: `docs/architecture.md`.
- Shared shell adapter: `Sources/OuroWorkbenchShellAdapter/`.
- App bulk targets: `Sources/OuroWorkbenchAppViews/WorkbenchViews.swift`, `Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift`.

## Notes
Prioritize a small, safe extraction over a sweeping rewrite. The lane's durable win is lowering future audit noise and making the next decomposition bite obvious.

## Progress Log
- 2026-06-29 22:00 Created and reviewer-gated under autopilot.
