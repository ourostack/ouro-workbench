# Doing: Boss-Owned Workspace — discover / propose / hand-off / forward-memory

**Status**: READY_FOR_EXECUTION
**Execution Mode**: direct
**Created**: 2026-06-19 11:09
**Planning**: ./boss-owned-workspace-planning.md
**Spec**: ./boss-owned-workspace.md
**Artifacts**: ./boss-owned-workspace-doing/
**Branch**: stay on / branch from `fix/onboarding-audit` (NOT main)

## Execution Mode
- **direct**: Execute units sequentially in the current session.
- Sub-agent reviewers/fixers resolve ordinary blockers under autopilot.

## Objective
Give the boss agent the primitives to OWN the workspace — discover agent sessions it didn't
create (recent + running), propose an editable plan to the operator (a capability, never a gate),
hand the onboarding "bring back my work" step to the boss, and record forward memory so future
discovery is native — all on GENERAL Core primitives with zero agency/MS knowledge.

## Completion Criteria
- [ ] General `AgentSessionScanner` (Core) discovers Claude recent + Copilot recent + running; emits general records; no command-building; no agency knowledge.
- [ ] Flat-YAML reader (Core) parses Copilot `workspace.yaml` keys.
- [ ] `workbench_discover_agent_sessions` MCP tool returns records as JSON.
- [ ] `workbench_propose` MCP tool + Core proposal model + native editable card; result returns to boss.
- [ ] Onboarding import step is boss-driven (hardcoded import replaced); wizard still works.
- [ ] Forward memory persisted on session create; surfaced by the scanner's native path.
- [ ] Boss-forward UI: session status list (running / waiting-on-you / done); terminals reachable.
- [ ] Health-probe path working (reuses transcript/status; Core helper only if a gap is found).
- [ ] `request_action` control-action audit complete (archive/group-create confirmed or added).
- [ ] 100% line+region coverage on all new Core code (`scripts/check-coverage.sh`).
- [ ] App + MCP compile under `-warnings-as-errors -strict-concurrency=complete`.
- [ ] All tests pass. No warnings. No `Co-Authored-By` / AI attribution anywhere.

## Code Coverage Requirements
**MANDATORY: 100% line+region coverage on all new OuroWorkbenchCore code.**
- No new `coverage-allowlist.txt` entries unless STRUCTURALLY unreachable (documented).
- All branches covered; all error/empty/missing-file paths tested.
- Edge cases: missing dirs, malformed JSONL/YAML lines, empty tails, partial first lines, non-file paths, zero-byte reads, dedup collisions, duplicate keys, no-match running scans.
- FS-touching code uses the injected `homeURL: URL` seam (per `SessionActivityReader`), tested against temp dirs.
- Running-process detection uses an injected runner closure (per `ProviderVerifyRunner` / `DaemonManager`).

## TDD Requirements
**Strict TDD — no exceptions:**
1. **Tests first** — write failing tests BEFORE implementation.
2. **Verify failure** — run, confirm RED.
3. **Minimal implementation** — just enough to pass.
4. **Verify pass** — run, confirm GREEN.
5. **Refactor** — clean up, keep green.
6. **No skipping** — never implement without a failing test first.

Per Core unit: write tests → confirm red → implement → `swift test` green → `scripts/check-coverage.sh` 100% on the new file → commit.

## Grounding (verified against HEAD)
- MCP tools + apply queue: `Sources/OuroWorkbenchMCP/main.swift` (`callTool` ~111, `toolDefinitions` ~571).
- Action model: `Sources/OuroWorkbenchCore/BossWorkbenchAction.swift` — `BossWorkbenchActionKind` ALREADY has `createGroup`/`createTerminal`/`createSession`/`moveSession`/`archive`/`restore`; `validateForQueueing`.
- App apply path: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` — `applyBossAction` ~14695, `createCustomSession(_:in:launchAfterCreate:owner:)` ~14481, `createGroup` ~11411, `archiveCustomSession` ~14587, `applyExternalActionRequests` ~14066.
- FS-injection template: `Sources/OuroWorkbenchCore/SessionActivityReader.swift` (`homeURL`, pure parse fns, bounded tail, `claudeProjectDirName`) + `Tests/.../SessionActivityReaderTests.swift`.
- Runner-injection template: `Sources/OuroWorkbenchCore/ProviderVerify.swift` (`ProviderVerifyRunner`) + `Tests/.../DaemonManagerTests.swift` (closure injection, `Counter`).
- Forward-memory seam: `Sources/OuroWorkbenchCore/CustomTerminalSession.swift` (`CustomTerminalSessionDraft`/`Factory.makeEntry`); `Sources/OuroWorkbenchCore/WorkspaceModels.swift` (`ProcessEntry` decode-if-present; `agentKind: TerminalAgentKind?` already present).
- Session listing: `Sources/OuroWorkbenchCore/SessionSnapshot.swift` (`SessionSnapshot`, `WorkbenchSessionsRenderer.snapshots`).
- Existing REJECTED scanner: `Sources/OuroWorkbenchCore/Onboarding.swift` (`RecentSessionScanner` 496–1379) — do NOT reuse/extend.
- Onboarding wizard: `OuroWorkbenchApp.swift` `OnboardingPage` ~5002, `scanForOnboardingSessions` ~12856, `applyOnboardingProposal` ~12909, `OnboardingBootstrapView` ~5900; flow `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift`.
- Coverage gate: `scripts/check-coverage.sh`, `scripts/coverage-allowlist.txt`. Strict flags: `scripts/package-app.sh` line 18.
- **Validated schemas (real files on this box):**
  - Claude JSONL top-level per-line keys: `type, sessionId, cwd, gitBranch, timestamp, version, aiTitle`. Discovery reads TOP-LEVEL keys, not `message.*`.
  - Copilot `workspace.yaml` (flat key:value): `id, cwd, git_root, repository, host_type, branch, client_name, name, user_named, summary_count, created_at, updated_at, ...`. ISO8601 timestamps; `repository` like `owner_org/repo`.
  - Onboarding phases (`WorkbenchOnboardingNarrative.swift`): `bossSetupWizard, bossReadyWelcome, scanProposal, arrangeApprovedImports, duplicateCleanup` — extend, don't rename.
  - `WorkbenchPaths` has `actionRequestsURL`/`transcriptsURL`; `proposalsURL` is NEW (Unit 5d adds + covers it).
  - `WorkbenchActionRequestQueue` is the proven template for `AgentProposalQueue` (paths init, atomic writes, drain/confirm, quarantine, sortedKeys/iso8601 encoder).

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**Status emoji required on every unit header.**

---

### Slice 0 — Audit & foundations

### ✅ Unit 0a: Control-action audit (no code)
**Tag**: Audit
**What**: Confirm `BossWorkbenchActionKind` + `applyBossAction` already cover archive / restore / createGroup / createTerminal / moveSession. Read `BossWorkbenchAction.swift` and `applyBossAction` (~14695). Record findings in `boss-owned-workspace-doing/control-action-audit.md`.
**Output**: Audit note: "all present, no new action kind needed" OR a precise gap list.
**Acceptance**: Audit file written; if a real gap exists it becomes a new TDD unit appended to Slice 7. (Expectation from grounding: no gap.)

### ✅ Unit 0b: General agent-session record type (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Write failing tests for a new `AgentSessionRecord` value type in a new file `Sources/OuroWorkbenchCore/AgentSessionScanner.swift`. Fields exactly: `harness: AgentHarness`, `sessionId: String`, `cwd: String`, `repository: String?`, `branch: String?`, `title: String?`, `lastActive: Date?`, `running: Bool`. Add `enum AgentHarness: String, Codable, Sendable { case claudeCode, githubCopilotCLI, openAICodex, custom }` (mirror `TerminalAgentKind`, with unknown→`.custom` decode). `Codable` + `Equatable` round-trip; stable `id`.
**Acceptance**: Tests exist and FAIL (type absent).

### ✅ Unit 0c: General agent-session record type (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement `AgentSessionRecord` + `AgentHarness`. Decode-if-present for optional fields; unknown harness raw → `.custom`.
**Acceptance**: Tests GREEN; `scripts/check-coverage.sh` 100% on the new file; commit.

---

### Slice 1 — Flat-YAML reader (Core), needed by Copilot scan

### ⬜ Unit 1a: Flat-YAML reader (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for `FlatYAMLReader` (new file `Sources/OuroWorkbenchCore/FlatYAMLReader.swift`): pure `static func parse(_ text: String) -> [String: String]` for flat `key: value` lines. Cover: quoted (`"a"`, `'b'`) + unquoted values, `#` comments, blank lines, leading/trailing whitespace, `:` in value, duplicate key (last wins), missing colon (skipped), empty input, CRLF. Zero dependency, JSON-style tolerant parsing (mirror `SessionActivity.parse` posture).
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 1b: Flat-YAML reader (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement `FlatYAMLReader.parse`. Line-based; no nesting (Copilot `workspace.yaml` is flat key:value). Strip surrounding quotes; trim; drop comment-only/blank/malformed lines.
**Acceptance**: Tests GREEN; 100% coverage on the new file; commit.

---

### Slice 2 — Recent-session discovery (Core)

### ⬜ Unit 2a: Claude recent discovery (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for `AgentSessionScanner(homeURL:)` method `discoverClaudeRecent() -> [AgentSessionRecord]`. Enumerates `~/.claude/projects/<dir>/*.jsonl`; reads each session file (bounded/tail-safe, seek-to-end like `SessionActivityReader.tailText`) and extracts from the **TOP-LEVEL** per-line keys (grounded against real files — these are NOT under `message`): `cwd`, `gitBranch`→`branch`, `sessionId` (prefer the in-record value; fall back to file basename sans extension), latest `timestamp`→`lastActive` (ISO8601), and `aiTitle`/`summary`→`title`. `harness = .claudeCode`, `running = false`. Tests use temp `homeURL` + `writeClaudeTranscript`-style fixtures; cover missing dir, malformed lines, multiple files, missing optional fields, in-record sessionId vs filename fallback, bad/missing timestamp.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 2b: Claude recent discovery (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement `discoverClaudeRecent`. Reuse `homeURL` seam; pure record-extraction split from FS-touching enumeration so both are testable. Do NOT build any resume command.
**Acceptance**: Tests GREEN; 100% coverage; commit.

### ⬜ Unit 2c: Copilot recent discovery (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for `discoverCopilotRecent() -> [AgentSessionRecord]`. Enumerates `~/.copilot/session-state/<id>/workspace.yaml`; parses with `FlatYAMLReader` (grounded against a real file: flat keys `id, cwd, git_root, repository, host_type, branch, client_name, name, created_at, updated_at, ...`) → `cwd`, `repository`, `branch`, `name`→`title`, `updated_at` (fallback `created_at`)→`lastActive` (ISO8601). `sessionId` = the in-file `id` (fallback `<id>` dir name). `harness = .githubCopilotCLI`, `running = false`. Cover missing dir, missing/empty yaml, partial keys, bad timestamps, dir name vs in-file id.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 2d: Copilot recent discovery (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement `discoverCopilotRecent` using `FlatYAMLReader` + an injected date parser (ISO8601) with safe fallback.
**Acceptance**: Tests GREEN; 100% coverage; commit.

---

### Slice 3 — Running-session discovery (Core)

### ⬜ Unit 3a: Command→harness matcher (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for a PURE, GENERAL matcher `AgentHarness.classify(command:) -> AgentHarness?` (or a free func in `AgentSessionScanner.swift`): `claude`→claudeCode, `copilot`→githubCopilotCLI, `codex`→openAICodex, non-agent commands → `nil`. Match on harness binary names only — ZERO agency/repo/agent-map knowledge. Cover each harness, path-prefixed binaries (`/usr/local/bin/claude`), args after the binary, non-agent commands, empty string, case sensitivity decision.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 3b: Command→harness matcher (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement the pure matcher. Keep it deliberately dumb and general; the boss owns all context-specific intelligence.
**Acceptance**: Tests GREEN; 100% coverage; commit.

### ⬜ Unit 3c: Running discovery (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for `discoverRunning(processLister:) -> [AgentSessionRecord]` where `processLister: @Sendable () -> [RunningProcessLine]` is INJECTED (closure, per `ProviderVerifyRunner`/`DaemonManager`). `RunningProcessLine { pid, command, cwd? }`. Uses the Unit 3b matcher to classify each line; non-agent lines skipped. Emits records with `running = true`, `sessionId` from a stable derivation (pid-based fallback), `cwd` from the line. Tests inject fake lines; cover each harness, non-agent lines (skipped), empty list, missing cwd.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 3d: Running discovery (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement `discoverRunning` using the matcher. No FS, no `Process` in Core: the App supplies the real lister.
**Acceptance**: Tests GREEN; 100% coverage; commit.

### ⬜ Unit 3e: Unified scan + dedup (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for `scan(processLister:) -> [AgentSessionRecord]` that merges recent (Claude+Copilot) + running, dedups (running beats recent when same `sessionId`/`cwd+harness`), and sorts by `lastActive` desc then running-first. Cover dedup collisions, running-overrides-recent, stable ordering, empty.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 3f: Unified scan + dedup (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement `scan(...)`. Deterministic dedup + sort.
**Acceptance**: Tests GREEN; 100% coverage; commit.

---

### Slice 4 — `workbench_discover_agent_sessions` MCP tool

### ⬜ Unit 4a: Discover tool — App-side real process lister (App)
**Tag**: App
**What**: Provide a concrete `processLister` for the App/MCP side (a `ps`-style enumeration via `Process`) that returns `[RunningProcessLine]`. Lives in the executable target (NOT Core; uses `Process`). Keep narrow; no agency knowledge.
**Acceptance**: Compiles under strict-concurrency; smoke-runs locally (manual). No Core coverage impact.

### ⬜ Unit 4b: Discover tool wiring (MCP)
**Tag**: MCP
**What**: Add `workbench_discover_agent_sessions` to `callTool` + `toolDefinitions` in `Sources/OuroWorkbenchMCP/main.swift`. Construct `AgentSessionScanner` (default `homeURL`), call `scan(processLister:)` with the real lister, encode `{ "sessions": [AgentSessionRecord...] }` via the existing `jsonEncoder` (sortedKeys/iso8601). Synchronous (matches the readLine loop). Tool description: GENERAL records, no command-building, boss builds resume itself.
**Acceptance**: `swift build` (MCP) under strict flags clean; `tools/list` includes the new tool; a manual `tools/call` returns the JSON shape. Encoding is deterministic.

---

### Slice 5 — Propose-for-approval capability (CAPABILITY, never a gate)

### ⬜ Unit 5a: Proposal model (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for a NEW general proposal model in `Sources/OuroWorkbenchCore/AgentProposal.swift` (distinct from the rejected `WorkbenchImportProposal`): `AgentProposal { id, title, items: [AgentProposalItem] }`; `AgentProposalItem { id, label, detail?, command?, cwd?, harness?, selected: Bool, editableFields }`; mutation helpers `toggle(itemID)`, `setSelected(itemID:_)`, `edit(itemID, field, value)`; a `result()` projection returning only selected/edited items for the boss. `Codable`/`Equatable`. Cover toggle, edit unknown field (no-op/typed), select-all/none, empty proposal, result projection.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 5b: Proposal model (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement the proposal model + mutations + `result()` projection. Pure value type.
**Acceptance**: Tests GREEN; 100% coverage; commit.

### ⬜ Unit 5c: Proposal queue/transport (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for a Core encode/decode + a pending-proposal store path mirroring `WorkbenchActionRequestQueue` (write a proposal request the App picks up; write the operator's result back for the boss to read). New `Sources/OuroWorkbenchCore/AgentProposalQueue.swift` with injected `WorkbenchPaths` (temp dir in tests). Cover enqueue, list pending, write/read result, malformed file skipped, empty.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 5d: Proposal queue/transport (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement the queue using `WorkbenchPaths` (add `proposalsURL` to `WorkbenchPaths.swift` — that file is Core and gated, so cover the new accessor).
**Acceptance**: Tests GREEN; 100% coverage on `AgentProposalQueue.swift` + `WorkbenchPaths.swift`; commit.

### ⬜ Unit 5e: `workbench_propose` MCP tool (MCP)
**Tag**: MCP
**What**: Add `workbench_propose` to `callTool` + `toolDefinitions`. Boss passes `{title, items:[...]}`; tool enqueues an `AgentProposal` via `AgentProposalQueue` and returns a `proposalId` (JSON). Add a companion read path — either a `workbench_proposal_result` tool or a documented `format:json` poll — so the boss reads the operator's approved/edited result. Synchronous; deterministic encoding. Description states clearly: this is a CAPABILITY; the boss may also just act.
**Acceptance**: MCP builds clean under strict flags; `tools/list` includes it; manual round-trip (enqueue → write a fake result file → read) works.

### ⬜ Unit 5f: Native editable proposal card (App)
**Tag**: App
**What**: SwiftUI card view that renders a pending `AgentProposal` (from `AgentProposalQueue`), lets the operator tick/edit/approve per item (reuse the selection/edit patterns near `OnboardingGroupProposalView` ~5992), and writes the `result()` back via the queue for the boss. Surfaced where the operator already looks (boss pane / a sheet). NEVER blocks other flows — purely opt-in.
**Acceptance**: Compiles under strict-concurrency; card renders a seeded proposal; ticking/editing/approving writes a result file the queue can read. Manual verification.

---

### Slice 6 — Forward memory

### ⬜ Unit 6a: Forward-memory fields (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for additive optional fields on `ProcessEntry` (`WorkspaceModels.swift`) and `CustomTerminalSessionDraft` (`CustomTerminalSession.swift`): `discoveredHarness: AgentHarness?`, `discoveredSessionId: String?`. Cover: decode-if-present (old JSON without the fields loads with nils), encode round-trip with values, `Factory.makeEntry` propagates draft→entry, defaults nil when absent. Add to `WorkspaceModelsTests` / `CustomTerminalSessionTests`.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 6b: Forward-memory fields (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Add the fields with `decodeIfPresent` (match the `owner`/`isPinned`/`friend` pattern). Thread through `CustomTerminalSessionDraft` → `Factory.makeEntry`. Also carry over in `updatedEntry`/`duplicateEntry` (the same way `owner`/`isPinned`/`friend` are preserved) so edits don't wipe them.
**Acceptance**: Tests GREEN; 100% coverage on `WorkspaceModels.swift` + `CustomTerminalSession.swift`; commit.

### ⬜ Unit 6c: Record forward memory at create (App)
**Tag**: App
**What**: When the App creates a session (`createCustomSession`/`applyBossAction` createSession/createTerminal), populate the draft's `discoveredHarness`/`discoveredSessionId` from the originating discovery record (when the create stems from a discovered session). Stamp them onto the entry so the next `scan()` native path sees them.
**Acceptance**: Compiles under strict flags; a created-from-discovery session persists the harness/sessionId in `workspace-state.json`. Manual verification.

### ⬜ Unit 6d: Native forward-memory discovery (Core) — Tests + Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Extend `AgentSessionScanner` with `discoverFromWorkbench(state:) -> [AgentSessionRecord]` that reads `ProcessEntry.discoveredHarness/discoveredSessionId` (+ `owner`, `workingDirectory`) so previously-launched sessions are discovered NATIVELY (never inferred). TDD: tests first (entries with/without forward memory, archived excluded), then impl, then 100% coverage. Fold into unified `scan` (add an optional `state` param).
**Acceptance**: Tests GREEN; 100% coverage; commit.

---

### Slice 7 — Onboarding hand-off

### ⬜ Unit 7a: Onboarding flow policy update (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for adding a boss-driven phase to `WorkbenchOnboardingNarrative.swift` (`WorkbenchOnboardingFlowPolicy`/`...Phase`): a `.bossReconstruct` phase that replaces the hardcoded scan/arrange decision once the boss is ready. Keep existing phases working (the `fix/onboarding-audit` repairs must not regress). Cover the new precedence + that boss-not-ready still routes to `.bossSetupWizard`.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 7b: Onboarding flow policy update (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement the `.bossReconstruct` phase + decision. Pure.
**Acceptance**: Tests GREEN; 100% coverage on the file; existing onboarding tests still green; commit.

### ⬜ Unit 7c: Onboarding import step replacement (App)
**Tag**: App
**What**: In the `importWork` page (`OnboardingBootstrapView` ~5900, `scanForOnboardingSessions` ~12856, `applyOnboardingProposal` ~12909), replace the hardcoded `RecentSessionScanner`-driven import with the boss-driven hand-off: the boss runs `see → propose → act` (discovers via `workbench_discover_agent_sessions`, optionally proposes via the card, relaunches as terminals). Workbench provides the primitives; the boss does which-agent / relaunch-command intelligence. Do NOT delete `RecentSessionScanner` (other call paths may remain) — just stop the wizard from using it as the import path. Preserve a graceful state when the boss isn't engaged.
**Acceptance**: Wizard still completes end-to-end; the import step is boss-driven; no regression to the repaired wizard. Manual verification + existing onboarding tests green.

---

### Slice 8 — Boss-forward UI + health-probe

### ⬜ Unit 8a: Session status classification (Core) — Tests
**Tag**: Core (coverage-gated)
**What**: Failing tests for a pure `SessionStatusList` projection in a new `Sources/OuroWorkbenchCore/SessionStatusList.swift`: from `WorkspaceState` (+ latest runs/attention) produce three buckets — `running`, `waitingOnYou` (`AttentionState.needsHuman`), `done` (exited). Reuse `SessionSnapshot`/`ProcessRun.isMoreRecent`. Cover each bucket, archived excluded, no-run entries, ordering.
**Acceptance**: Tests exist and FAIL.

### ⬜ Unit 8b: Session status classification (Core) — Impl + coverage
**Tag**: Core (coverage-gated)
**What**: Implement the projection. Pure.
**Acceptance**: Tests GREEN; 100% coverage; commit.

### ⬜ Unit 8c: Boss-forward UI surface (App)
**Tag**: App
**What**: Make the boss the primary surface and add a session STATUS list (running / waiting-on-you / done) driven by `SessionStatusList`. Terminals stay reachable in the sidebar (ADDITIVE — do not remove terminal UI). Wire to existing state/published properties.
**Acceptance**: Compiles under strict flags; the status list renders the three buckets; terminals still reachable. Manual verification.

### ⬜ Unit 8d: Health-probe path (Core if needed) — Tests + Impl + coverage
**Tag**: Core (coverage-gated) if a helper is added; else Audit
**What**: Confirm the boss can verify a resumed session is healthy via existing `workbench_transcript_tail` + `workbench_status`/`workbench_sessions`. If sufficient, write an audit note (`boss-owned-workspace-doing/health-probe-audit.md`) — no code. If a gap exists, add a pure Core `SessionHealthProbe` (TDD: tests first → impl → 100% coverage) classifying a transcript tail + run status into `healthy / starting / stalled / failed`.
**Acceptance**: Audit note OR a 100%-covered Core helper. If helper added, expose via MCP only if needed.

---

### Slice 9 — Integration gate

### ⬜ Unit 9a: Full coverage + strict build + suite
**Tag**: Gate
**What**: Run `scripts/check-coverage.sh` (must PASS — 100% line+region on all new Core, allowlist unchanged or only structurally justified). Run `swift build -c release -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` for App + MCP (clean). Run full `swift test`. Grep the diff for `Co-Authored-By` / AI-attribution strings (must be absent).
**Acceptance**: Coverage PASS; strict build clean; all tests green; no attribution strings; commit.

### ⬜ Unit 9b: Spec + planning checklist reconciliation
**Tag**: Docs
**What**: Tick this doc's Completion Criteria against reality; update `boss-owned-workspace.md` "Gaps to build" to reflect what shipped; ensure `planning-coverage-checklist.md` is all ✅.
**Acceptance**: Docs reconciled; committed.

## Execution
- **TDD strictly enforced**: tests → red → implement → green → refactor; coverage gate per Core unit.
- Commit after each unit (red+green folded where the unit pairs them); push after each slice.
- `scripts/check-coverage.sh` before marking any Core unit done.
- App/MCP units: build under strict flags; manual smoke where UI/Process-bound.
- All artifacts → `./boss-owned-workspace-doing/`.
- Fixes/blockers: spawn a sub-agent immediately.
- Decisions: update docs + commit immediately.
- Stay on / branch from `fix/onboarding-audit`. Never branch from main.

## Progress Log
- 2026-06-19 11:09 Created from planning doc (Pass 1 draft).
- 2026-06-19 11:09 Pass 2 granularity: split running-discovery matcher (3a/3b) from lister-driven discovery (3c/3d); renumbered unified scan to 3e/3f.
- 2026-06-19 11:09 Pass 3 validation: grounded Claude JSONL top-level keys + Copilot workspace.yaml flat schema against real files on this box; confirmed onboarding phase names, WorkbenchPaths accessors, TerminalAgentKind cases; refined Units 2a/2c.
- 2026-06-19 11:09 Pass 4 quality: 36 units, all emoji-tagged, all with Acceptance, no TBD, no attribution — no changes needed.
- 2026-06-19 11:09 Pass 5 planning coverage check: full coverage confirmed (planning-coverage-checklist.md) — all 8 areas + every In/Out-of-Scope guardrail mapped to units, no gaps.
- 2026-06-19 11:18 Unit 0a complete: control-action audit — all kinds (archive/restore/createGroup/createTerminal/createSession/moveSession) present at model+validation+apply layers; no gap, no new unit appended. Note in control-action-audit.md.
