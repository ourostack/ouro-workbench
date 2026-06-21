# Doing: F4 — native session-id resume is dead code (recovery collapses multi-session repos)

- **Status:** in-progress
- **Branch:** `fix/f4-recovery-sessionid` (off `main` @ `04d199b`)
- **Execution Mode:** direct
- **Identity:** ari@mendelow.me
- **Artifacts:** `./2026-06-21-1436-doing-f4-recovery-sessionid/`
- **Constraints:** strict TDD; commit only F4 files via `git add <paths>` (NEVER `git add -A`); no push/PR/merge; no attribution. Ignore untracked leftovers (`docs/f9-*.md`, `SerpentGuide.ouro/`, deleted `.claude/scheduled_tasks.lock`).

## The bug

`ProcessRun.terminalSessionId` has READERS (`CommandPlanner.nativeResumePlan`, `RecoveryPlanner`) but NO production WRITER. `markStarted` builds `ProcessRun` without it → always nil → the planner's id branch is dead → recovery always uses `--continue` / `resume --last`, collapsing two same-cwd sessions onto one.

The id is NOT available at `markStarted` (the PTY child pid lands before the agent writes its native session file). So a **back-fill** is required: when the `AgentSessionScanner` first observes the native id, match it to the still-id-less RUNNING run and populate `terminalSessionId`.

## Units

### Unit 0 — Pure back-fill seam (test-first) ✅ planned
- **0a (test, red):** Write `SessionIdBackfillTests` covering match (a end-to-end-ready), fallback (b), same-cwd disambiguation (c), no-clobber (d). Tests fail because `SessionIdBackfill` doesn't exist.
- **0b (impl, green):** Add `Sources/OuroWorkbenchCore/SessionIdBackfill.swift` — pure `sessionIdBackfills(runs:entries:records:) -> [UUID: String]`. 100% line+region.
- **0c (verify):** Coverage gate green on the new file; full `swift test` green; strict build clean.

### Unit 1 — Planner end-to-end pin (test-first) ✅ planned
- **1a (test, red):** Extend `CommandPlannerTests`: a `.needsRecovery` run with a back-filled id → `--resume <id>` (claude) / `resume <id>` (codex); id nil + no record → `--continue` / `resume --last`. (Mostly proves the seam output flows through the existing reader; confirms wiring contract.)
- These assertions confirm the planner consumes a back-filled id; the reader already exists.

### Unit 2 — App wiring (source-pin test) ✅ planned
- **2a (test, red):** Source-pin test asserting the App's back-fill pass references `sessionIdBackfills`, assigns `.terminalSessionId` guarded by `== nil`, and calls `save()`.
- **2b (impl, green):** Add a sibling detached pass at `reclassifyAttentionForFlushedRuns` that scans, computes back-fills, applies on the main actor guarded by `== nil`, saves. `markStarted` stays as-is. Add an App-target `ps`-backed lister.
- **2c (verify):** strict build clean; full `swift test` green.

## Completion Criteria
- [ ] `SessionIdBackfill.swift` exists, pure, 100% line+region (no allowlist).
- [ ] Two distinct runs NEVER receive the same id (same-cwd pid disambiguation).
- [ ] No-clobber: non-empty id absent from map; non-`.running` run skipped; cwd with no record skipped; `.custom` harness skipped.
- [ ] Planner renders `--resume <id>` when the id is back-filled; honest fallback otherwise.
- [ ] App back-fills at the output-settle point, guarded by `== nil`, then `save()`; `markStarted` unchanged.
- [ ] `swift test` strict green; strict build clean.

## Progress log
- 2026-06-21 14:36 Branch created off main @ 04d199b; baseline build clean; doing doc + artifacts dir created.
