# Doing: All-agents bundle-cleanup sweep

Status: done
Execution Mode: direct
Branch: first-run-agent-drives-ui
Planning: (none — spec is the task prompt)
Artifacts: ./2026-06-08-2010-doing-all-agents-bundle-cleanup/

## Goal
Make sure NO agent on the machine carries a stale `ouro_workbench` MCP entry or
`senses.workbench`. Under the runtime-injection model the boss gets the Workbench MCP at
runtime (`--workbench-mcp <path>`); nothing belongs in any agent's git-synced bundle. The
existing cleanup (`BossWorkbenchMCPRegistrar.install(for: boss)`) only cleans the BOSS's
bundle, so a non-boss agent can still carry a stale entry (confirmed on this machine:
`ouroboros.ouro/agent.json` has `mcpServers.ouro_workbench` + `senses.workbench` while the
boss is `slugger`). That pollutes git-sync to other machines and is over-permissive. The
cleanup must sweep ALL agents.

## Why this is safe
The per-agent cleanup logic already exists and is battle-tested in `install(for:)`: load
`agent.json`, remove `mcpServers.ouro_workbench` + `senses.workbench`, preserve every other
key, write back ONLY if changed, atomic write, valid JSON. The sweep just runs that same safe
cleanup over every `*.ouro` bundle, skipping unreadable/missing/garbage bundles gracefully.

## Units

### Unit 1a (test): Core sweep over all agent bundles ✅
Add `BossAgentBridgeTests` cases (temp-dir fixture, mirrors existing registrar tests):
- sweep cleans a dirty bundle (removes `ouro_workbench` + `senses.workbench`)
- sweep is a no-op write on a clean bundle (mtime/content unchanged — no spurious write)
- sweep preserves unrelated keys (`browser` server, other senses, top-level keys)
- sweep cleans MULTIPLE dirty bundles in one pass (the all-agents point)
- sweep handles a missing bundle dir + a garbage (non-JSON) `agent.json` without throwing
- sweep reports which agents it changed (so launch wiring can log/verify)
Run → must FAIL (red), method doesn't exist yet.

### Unit 1b (impl): `cleanupAllAgents()` on the registrar ✅
Add `cleanupAllAgents()` to `BossWorkbenchMCPRegistrar`: enumerate `*.ouro` bundles under
`agentBundlesURL`, run the SAME safe cleanup per bundle (refactor `install`'s removal into a
shared private helper `removeStaleWorkbenchEntries(at:)` so there's one cleanup truth), write
only if changed, never throw on a single bad bundle, return the list of changed agent names.
Run → must PASS (green). `swift build` clean, no warnings.

### Unit 2a (test): launch wiring (once, idempotent, off-main) — covered by Core test
The trigger is a thin App-side call. Behavior under test lives in Core (Unit 1a). App wiring
verified by build + manual confirmation that the sweep runs before boss selection.

### Unit 2b (impl): trigger the sweep once on launch ✅
In `WorkbenchViewModel.init` (where `refreshOuroAgents` / `refreshWorkbenchMCPRegistration`
already run on launch), call the sweep once, off the main actor (file IO), BEFORE/independent
of boss selection. Idempotent: a clean machine produces no writes. Re-snapshot afterward so
the UI reflects the now-clean bundles.

### Unit 3: full suite + build green, commit, report ✅

## Completion Criteria
- [x] `cleanupAllAgents()` sweeps EVERY `*.ouro` bundle, not just the boss
- [x] removes `mcpServers.ouro_workbench` + `senses.workbench`, preserves all other keys
- [x] writes back ONLY if changed (no spurious write on clean bundles)
- [x] handles missing/garbage bundles without throwing
- [x] one shared cleanup helper (`removeStaleWorkbenchEntries(at:)`; no duplicated removal logic vs `install`)
- [x] triggered once on launch, off-main, before/independent of boss selection
- [x] `swift build` + `swift test` green; no warnings (839 tests, 1 pre-existing live-only skip)
- [x] recovery-truth + R2 livePrompt floor untouched; no drive-by edits

## Progress Log
- 2026-06-08 20:10 doing doc created; premise confirmed (ouroboros carries stale entries; boss is slugger).
- 2026-06-08 20:06 Unit 1a/1b: cleanupAllAgents() sweeps all *.ouro bundles via shared removeStaleWorkbenchEntries() helper; 5 tests red→green.
- 2026-06-08 20:08 Unit 2b: sweepStaleWorkbenchBundlesOnLaunch() wired into init off-main, before boss selection, re-snapshots when changed.
- 2026-06-08 20:12 Gates: impl-coverage ✅ | swift build clean + 839 tests green, no warnings ✅ |
  PR-review vs spec ✅ (single cleanup truth shared with install; sweeps every agent; preserves
  unrelated keys; idempotent no-op write on clean; skips garbage/missing; diff scope = 3 files,
  no livePrompt/recovery/drive-by edits).
