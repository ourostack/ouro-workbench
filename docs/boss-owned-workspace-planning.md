# Planning: Boss-Owned Workspace — discover / propose / hand-off / forward-memory

**Status**: approved (autopilot mandate — see Decisions Made)
**Created**: 2026-06-19 11:09

## Goal
Give the boss agent the primitives to *own* the workspace: discover agent sessions
(recent + running) it didn't create, propose an editable plan to the operator (a capability,
never a gate), hand the onboarding "bring back my work" step to the boss, and record forward
memory so future discovery is native — all on GENERAL Core primitives with zero agency/MS
knowledge.

## Scope

### In Scope
- General agent-session scanner in Core (`AgentSessionScanner`): RECENT (Claude `~/.claude/projects/<encoded-cwd>/<id>.jsonl`, Copilot `~/.copilot/session-state/<id>/workspace.yaml`) + RUNNING (live processes via injected runner), emitting GENERAL records `{harness, sessionId, cwd, repository, branch, title, lastActive, running}`. Zero command-building.
- A tiny flat-YAML reader in Core (no SPM dependency) for Copilot `workspace.yaml`.
- MCP tool `workbench_discover_agent_sessions` exposing the scanner.
- Propose-for-approval capability: a new MCP tool (`workbench_propose`) + a Core proposal model + a native editable card UI whose result returns to the boss. CAPABILITY, never a forced gate.
- Onboarding hand-off: replace the hardcoded terminal-import step with a boss-driven `see → propose → act` flow; Workbench provides primitives, boss does the context-specific intelligence.
- Forward memory: when Workbench launches a session, record `{agent, command, cwd, harness, sessionId}` on the persisted entry so future discovery is native.
- Boss-forward UI: boss is the primary surface + a session STATUS list (running / waiting-on-you / done); terminals stay reachable in the sidebar (additive, not a rip-out).
- Health-probe: boss can confirm a resumed session came up healthy (reuse `transcript_tail`/`status`; add a Core helper only if a gap is found).
- Audit `request_action` control actions; add archive/group-create ONLY if absent (grounding shows both already exist).

### Out of Scope
- Any agency / ms-desk / repo→agent map / `agency --resume` command construction (boss-owned).
- Modifying or removing the existing `RecentSessionScanner` (the rejected bespoke approach) — the new scanner is a separate, dumber, general Core type.
- Ripping out the terminal UI; the wizard the `fix/onboarding-audit` branch repaired.
- A new YAML SPM dependency.
- v1/v2 gating — build everything useful here.

## Completion Criteria
- [ ] General `AgentSessionScanner` discovers Claude recent, Copilot recent, and running sessions; emits general records; no command-building; no agency knowledge.
- [ ] Flat-YAML reader parses Copilot `workspace.yaml` keys.
- [ ] `workbench_discover_agent_sessions` MCP tool returns the records as JSON.
- [ ] `workbench_propose` MCP tool + Core proposal model + native editable card; result returns to boss.
- [ ] Onboarding import step is boss-driven (hardcoded import replaced); wizard still works.
- [ ] Forward memory persisted on session create and surfaced by the scanner's RUNNING/native path.
- [ ] Boss-forward UI with a session status list; terminals reachable.
- [ ] Health-probe path documented/working.
- [ ] `request_action` control-action audit complete (archive/group-create confirmed present or added).
- [ ] 100% line+region test coverage on all new OuroWorkbenchCore code (`scripts/check-coverage.sh`).
- [ ] App + MCP compile under `-warnings-as-errors -strict-concurrency=complete`.
- [ ] All tests pass. No warnings. No `Co-Authored-By` / AI attribution anywhere.

## Code Coverage Requirements
**MANDATORY: 100% line+region coverage on all new OuroWorkbenchCore code.**
- No new `coverage-allowlist.txt` entries unless STRUCTURALLY unreachable (documented).
- All branches covered; all error/empty/missing-file paths tested.
- Edge cases: missing dirs, malformed JSONL/YAML lines, empty tails, partial first lines, non-file paths, zero-byte reads, dedup collisions.
- FS-touching code MUST use the injected `homeURL: URL` seam (per `SessionActivityReader`) and run against temp dirs in tests.
- Running-process detection MUST use an injected runner closure (per `ProviderVerifyRunner` / `DaemonManager`) so it's fully testable.

## Open Questions
- [x] New SPM YAML dep? → No. Custom flat-YAML line reader in Core (Copilot schema is flat key:value).
- [x] Modify `RecentSessionScanner`? → No. New separate general scanner; the old one is the rejected bespoke approach.
- [x] New action kinds for archive/group-create? → No (both exist in `BossWorkbenchActionKind` + applied). Audit-only; add only if a true gap surfaces.
- [x] Where does forward memory live? → New optional fields on `ProcessEntry` + `CustomTerminalSessionDraft`, stamped in `CustomTerminalSessionFactory.makeEntry`, decoded-if-present (schema-drift-safe).
- [x] Running-session detection mechanism? → Injected runner closure returning process lines; Core parses; the App wires a real `ps`/`pgrep`-style runner.

## Decisions Made
- **Autopilot authorization treated as approval.** The operator gave full ownership and explicitly said NOT to return for human approval; the standard human approval gate is satisfied by that explicit mandate. Planning → doing proceeds in one pass.
- **New scanner is a clean sibling, not an edit of `RecentSessionScanner`.** The existing one builds `claude --resume` commands (harness knowledge) and was the rejected bespoke approach. The new `AgentSessionScanner` emits general records only.
- **Custom flat-YAML reader** keeps Core zero-dependency and 100%-coverage-friendly.
- **Forward memory as additive `ProcessEntry` fields**, following the existing decode-if-present pattern (`owner`, `isPinned`, `friend`).
- **Propose is a capability**: the boss may call `workbench_propose` OR just act (TTFA). Never a gate.
- **Boss-forward UI is additive**: a status list + boss-primary surface; the terminal UI stays.

## Context / References
- Spec: `docs/boss-owned-workspace.md`.
- MCP surface + tool defs + apply queue: `Sources/OuroWorkbenchMCP/main.swift` (tools `callTool`, `toolDefinitions`).
- Action model: `Sources/OuroWorkbenchCore/BossWorkbenchAction.swift` (`BossWorkbenchActionKind` already has createGroup/createTerminal/createSession/moveSession/archive/restore; `validateForQueueing`).
- App apply path: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` `applyBossAction` (~14695), `createCustomSession` (~14481), `createGroup` (~11411), `archiveCustomSession` (~14587), `applyExternalActionRequests` (~14066).
- FS-injection template: `Sources/OuroWorkbenchCore/SessionActivityReader.swift` (injected `homeURL`, pure parse fns, bounded reads, `claudeProjectDirName`) + `Tests/OuroWorkbenchCoreTests/SessionActivityReaderTests.swift` (temp-dir fixtures).
- Runner-injection template: `Sources/OuroWorkbenchCore/ProviderVerify.swift` (`ProviderVerifyRunner`), `Tests/.../DaemonManagerTests.swift` (closure injection, `Counter`).
- Forward-memory seam: `Sources/OuroWorkbenchCore/CustomTerminalSession.swift` (`CustomTerminalSessionDraft`/`Factory.makeEntry`), `Sources/OuroWorkbenchCore/WorkspaceModels.swift` (`ProcessEntry` decode-if-present).
- Session listing: `Sources/OuroWorkbenchCore/SessionSnapshot.swift` (`SessionSnapshot`, `WorkbenchSessionsRenderer.snapshots`).
- Existing (rejected) scanner: `Sources/OuroWorkbenchCore/Onboarding.swift` (`RecentSessionScanner` 496–1379) — do NOT reuse/extend.
- Onboarding wizard pages/flow: `OuroWorkbenchApp.swift` `OnboardingPage` (~5002), `scanForOnboardingSessions` (~12856), `applyOnboardingProposal` (~12909), `OnboardingBootstrapView` (~5900); flow policy `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift`.
- Coverage gate: `scripts/check-coverage.sh` (100% line+region, llvm-cov), `scripts/coverage-allowlist.txt`. Build flags: `scripts/package-app.sh` line 18.
- Branch: stay on / branch from `fix/onboarding-audit` (NOT main).

## Notes
- JSON parsed via `JSONSerialization` (tolerant), not Codable — match it.
- Claude project-dir encoding is forward-only (`/` and `.` → `-`); discovery enumerates dirs and reads the encoded path back from the JSONL records, not by decoding the dir name.
- `ProcessEntry.agentKind: TerminalAgentKind?` already exists (claudeCode/githubCopilotCLI/openAICodex) — reuse for harness mapping.
- MCP request loop is synchronous off `readLine()`; any probe must be sync (`probeSynchronously` pattern) — keep new tools synchronous.

## Progress Log
- 2026-06-19 11:09 Created (grounded against MCP surface, action model, scanner/FS-injection templates, coverage gate, onboarding wizard map).
- 2026-06-19 11:09 Approved under autopilot mandate; converted to doing doc (boss-owned-workspace-doing.md) — Passes 1–5 complete, READY_FOR_EXECUTION.
