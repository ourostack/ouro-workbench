# Planning-coverage checklist — U4 doing doc vs the brief

Every brief requirement → ✅ has a doing unit/section, or ❌ MISSING.

## Scope of the plan
- ✅ Snapshot the 66 logic-bearing uncovered views (~215 states) → Objective + all clusters C0–C11; `view-classification.md` enumerates the 66.
- ✅ Sequenced high-value/high-fan-out first → "Cluster decomposition" header + C0-first + C1/C2/C3/C4 high-value early; the 5 high-fan-out sheets own a PR.
- ✅ Decompose into PR-scoped clusters by area/file-locality → C0–C11, each a file-local area cluster, each "one coherent reviewable batch."
- ✅ The 5 high-fan-out sheets likely each their own PR (`BossDashboardView`, `ReportBugSheet`, `DecisionLogRow`, `ProviderConfigSheet`, `HarnessStatusSheet`) → C2 (BossDashboard), C5 (ReportBug), C6 (ProviderConfig), C11 (HarnessStatus), and **`DecisionLogRow` gets its OWN sub-unit/commit within C4 (splits to C4a-solo if oversized — Q4)**. All 5 named targets honored: the 4 sheets solo their PR; the 1 row (`DecisionLogRow`, the deepest state-set) solos its commit (and its PR if it overflows), batched with the file-local decision-log family.
- ✅ Each view: enumerated state-set, snapshotted via LIVE `assertViewSnapshot`, provenance through the REAL seam, ≥1 mutation-verified negative control per surface → Completion Criteria + per-unit Acceptance + TDD Requirements.

## The provenance/determinism edge-cases (CRITICAL — C1/AN-006 risks)
- ✅ `SessionChip`/`GitBranchChip` look-covered-but-aren't real targets; build activity/git-status fixtures → Edge-case playbook #1 + C1 + Q5.
- ✅ AN-001 seam (`OuroAgentManagerView`, `OuroAgentRowView`, `BossWorkbenchMCPSetupView`, `AgentStatusCard`): temp `agentBundlesURL` + fixed `OuroAgentRecord` (E3 mitigation) → playbook #2 + C7/C8 + C3.
- ✅ Path-leak (hard) — `AgentInspectorPanel` renders `bundlePath`/`configPath` → fixed/relative paths (P3) → playbook #3 + C7 (verified first-hand).
- ✅ Clock — `BossWatchStatusView`, `DecisionInboxSheet` formatted timestamps → fixed-timestamp / U2 injectable `now:` → playbook #4 + C4/C10/C11 + the validation pass confirmed `now:` already wired.
- ✅ `.contextMenu{}`/`.popover{}` content NOT descended → standalone snapshots of `TerminalRowContextMenu`/`AutonomyStatusPopover`/`BossAgentNamePopover` etc. → playbook #5 + C1/C3 (confirmed all are top-level structs).
- ✅ Non-injectable/shell → allowlist-candidate list, do NOT force-snapshot:
  - ✅ `MachineRuntimeView` login-item rows (`@StateObject LoginItemController()`, only `supportDiagnostics` buildable) → allowlist dossier (verified first-hand).
  - ✅ `WorkbenchRootView` (NavigationSplitView/window/scenePhase/dockTile shell — spike host; else allowlist) → allowlist dossier + Q1 spike (C0).
  - ✅ Live-terminal arms of `SessionDetailView`/`DetailSplitContainer` (embed `TerminalPane` → allowlist that arm; snapshot inactive/empty/inspector states) → allowlist dossier (PARTIAL) + C9 (verified first-hand).
  - ✅ Each recorded as an honest-allowlist candidate with a verified justification → allowlist-candidate table + `allowlist-candidates.md` (dossiers land per cluster).

## Constraints
- ✅ Provenance (P2), mutation-verified negative controls, determinism (P3 — TZ pin + `.help` drop; fixtures fix paths/clocks/UUIDs/agent-names), non-redundant (P4e), agent-legible → Completion Criteria + Code Coverage + D-U4-2.
- ✅ Inject temp `agentBundlesURL` (AN-001) in EVERY VM fixture → Completion Criteria + playbook #2.
- ✅ Do NOT coverage-GATE the views lib yet → Out of Scope + D-U4-3 (the FINAL step after logic-bearing + branchless/allowlist land).
- ✅ Record running coverage % targets per cluster → each unit's Output (`views-coverage-after-Cx.txt`) + Completion Criteria.
- ✅ Gates per PR: strict build/test 0 warn/fail; `--uisurfacetest` green; `check-coverage.sh` green + allowlist/`COVERAGE_DIRS` unchanged; guards green → Completion Criteria + Execution.
- ✅ One commit per sub-unit → Execution + Completion Criteria.
- ✅ NO AI attribution; `SerpentGuide.ouro/` unstaged → Completion Criteria + Execution.
- ✅ Flag any view needing `private`→`internal` access-widening like SU-E → D-U4-4 + every cluster lists its widenings + `view-classification.md` tags `[private→internal]`.

## Git / deliverables
- ✅ Fresh branch `feat/anneal-coverage-logic-bearing-plan` off current `origin/main` (`git fetch && git checkout -b … origin/main`) → done (`3b0359f` off `7a65601`).
- ✅ Write the doing doc under `worker/tasks/2026-06-24-anneal-visual-testing/` (e.g. `U4-logic-bearing-coverage.md`) → done.
- ✅ + a terse campaign-journal U3-COMPLETE entry (59 refs, surfaces F/A/B/C/D/E, #296/#298 merged, ~16% region; the 127-view classification; the deferred branchless-29/untestable allowlist decision) → pending (this Pass 5 then writes it before READY).
- ✅ Commit (`docs(doing):`) → all 4 passes committed with `docs(doing):`.
- ✅ No PR → branch carries plan+journal only; clusters land as their own PRs at execution.

## Autonomy
- ✅ Fully autonomous (operator intermittently present — no signoff; fresh unbiased sub-agent review gate before READY) → D-U4-6 + Completion Criteria; the gate runs after this checklist.
- ✅ For ambiguity, pick the reversible default and record it → Q1–Q5 each carry a reversible default; the `DecisionLogRow`-in-C4 batching call recorded above.

## Return-to-operator deliverables (the brief's "Return to me")
- ✅ Doing-doc path + cluster/PR decomposition (count/sequence/views per batch) → the final summary.
- ✅ Provenance-fixture approach for the flagged edge-cases → Edge-case playbook (6 recipes).
- ✅ Honest-allowlist candidate list with justifications → the allowlist-candidate table.
- ✅ Realistic PR-count + any genuine fork → 12–16 PRs; Q3 (`NSFullUserName()`) is the genuine new fork; Q1 (`WorkbenchRootView` host viability) is the spike-gated fork.

## Verdict
**FULL COVERAGE.** Every brief requirement maps to a doing unit/section. No ❌. The DecisionLogRow judgment call is resolved (own sub-unit/commit in C4, solo-PR if oversized — all 5 named high-fan-out targets honored).

**Post-review-gate update:** the fresh unbiased gate (1 HIGH + 4 MEDIUM + 1 LOW, all resolved) ADDED 3 coverage items the first draft had dropped/mis-binned — `SessionTranscriptSheet`+`RunningSessionHeaderControls` (unassigned LOGIC → C9) and `TranscriptHistoryView` (branchless→LOGIC/C9) — sharpening the count to ~69 first-hand. It also caught 2 missed determinism leaks (the `NewTerminalSessionSheet` home-path; the `TranscriptHistoryView` `Text(tail.path)`) and 3 missed access-widenings, all now in the doc. The coverage is now MORE complete than the first draft; no brief requirement is uncovered. **Status: READY_FOR_EXECUTION.**
