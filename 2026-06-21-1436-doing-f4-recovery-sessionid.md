# Doing: F4 — native session-id resume is dead code (recovery collapses multi-session repos)

- **Status:** done
- **Branch:** `fix/f4-recovery-sessionid` (off `main` @ `04d199b`)
- **Execution Mode:** direct
- **Identity:** ari@mendelow.me
- **Artifacts:** `./2026-06-21-1436-doing-f4-recovery-sessionid/`
- **Constraints:** strict TDD; commit only F4 files via `git add <paths>` (NEVER `git add -A`); no push/PR/merge; no attribution. Ignore untracked leftovers (`docs/f9-*.md`, `SerpentGuide.ouro/`, deleted `.claude/scheduled_tasks.lock`).

## The bug

`ProcessRun.terminalSessionId` has READERS (`CommandPlanner.nativeResumePlan`, `RecoveryPlanner`) but NO production WRITER. `markStarted` builds `ProcessRun` without it → always nil → the planner's id branch is dead → recovery always uses `--continue` / `resume --last`, collapsing two same-cwd sessions onto one.

The id is NOT available at `markStarted` (the PTY child pid lands before the agent writes its native session file). So a **back-fill** is required: when the `AgentSessionScanner` first observes the native id, match it to the still-id-less RUNNING run and populate `terminalSessionId`.

## Units

### Unit 0 — Pure back-fill seam (test-first) ✅
- **0a (test, red):** ✅ `SessionIdBackfillTests` (19 cases) — match (a), fallback (b), same-cwd disambiguation (c), no-clobber + skip guards (d). Red = `cannot find 'SessionIdBackfill' in scope`.
- **0b (impl, green):** ✅ `Sources/OuroWorkbenchCore/SessionIdBackfill.swift` — pure `sessionIdBackfills(runs:entries:records:) -> [UUID: String]`. Green.
- **0c (verify):** ✅ `SessionIdBackfill.swift` 100% line+region (no allowlist); full `swift test` green; strict build clean.

### Unit 1 — Planner end-to-end pin (test-first) ✅
- **1a (test):** ✅ Extended `CommandPlannerTests` with 4 F4 cases: back-filled id → `claude --resume sess-abc`; no record → `claude --continue` / `codex resume --last`; two same-cwd runs both fall back WITHOUT sharing an id. 35 CommandPlannerTests green.

### Unit 2 — App wiring (source-pin test) ✅
- **2a (test, red):** ✅ `SessionIdBackfillWiringTests` (5 cases) — pins the back-fill method calls `sessionIdBackfills`, runs `AgentSessionScanner().scan(state:processLister:)`, assigns `.terminalSessionId` guarded by `== nil`, calls `save()`, is wired at the output-settle point, and that `markStarted` stays as-is. Red before impl.
- **2b (impl, green):** ✅ Added `backfillSessionIdsForFlushedRuns` + `applySessionIdBackfills` + off-main `scanAgentSessions` + App-target `psBackedProcessLines` lister; triggered from `reclassifyAttentionForFlushedRuns`. `markStarted` unchanged.
- **2c (verify):** ✅ strict clean build (0 warnings/errors); full `swift test` green (2018 tests, 0 failures).

## Completion Criteria
- [x] `SessionIdBackfill.swift` exists, pure, 100% line+region (no allowlist).
- [x] Two distinct runs NEVER receive the same id (same-cwd pid disambiguation).
- [x] No-clobber: non-empty id absent from map; non-`.running` run skipped; cwd with no record skipped; `.custom` harness skipped.
- [x] Planner renders `--resume <id>` when the id is back-filled; honest fallback otherwise.
- [x] App back-fills at the output-settle point, guarded by `== nil`, then `save()`; `markStarted` unchanged.
- [x] `swift test` strict green; strict build clean.

## Outcome
- **Production writer now exists:** `grep '\.terminalSessionId =' Sources/` → `OuroWorkbenchApp.swift:18252` (the back-fill, guarded by `== nil`) in addition to the struct initializer. The planner's id branch + `RecoveryPlanner.autoResume` reason are no longer dead.
- **Same-cwd pid disambiguation:** the running record's cwd is `""` with the `ps` lister, so the seam never reads it for running records — it pins each run to its own live process by `pid-<pid>`, counts candidate RUNS per `(harness, entry.workingDirectory)`, and back-fills only when exactly one candidate competes for a `(harness, cwd)`. Two same-cwd live runs → both nil (honest fallback). Two distinct runs can never share an id.
- **Lister cwd:** the App's `psBackedProcessLines` (mirroring the MCP `RunningProcessLister`) leaves cwd nil on every line — by design and harmless, because the seam disambiguates by pid, not by the running record's cwd.

## Progress log
- 2026-06-21 14:36 Branch created off main @ 04d199b; baseline build clean; doing doc + artifacts dir created.
- 2026-06-21 14:56 All units complete. SessionIdBackfill seam 100% covered; planner + app wiring green; full suite 2018 tests 0 failures; strict clean build 0 warnings. Production writer for terminalSessionId confirmed. All gates passed.
