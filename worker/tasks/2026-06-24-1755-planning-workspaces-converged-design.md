# Planning: Workspaces, Required Onboarding & Propose-First Bring-Back (Converged Design)

**Status**: approved
**Created**: 2026-06-24 (autonomous; gated by fresh sub-agent review, not human signoff)

## Goal
Decompose the signed-off converged design (`2026-06-24-1745-ideation-workspaces-onboarding-bring-back.md`) into PR-scoped, dependency-ordered build units that move Ouro Workbench from the broken "workspaces vs terminals-in-Home" muddle to the settled cmux/soloterm model: named workspaces of named tabs, durable git-backable structure, required onboarding, and a propose-first (never auto-spawn) bring-back. This master plan is the index; each slice converts to its own doing doc when its turn comes. Only Slice ① is converted now.

## Scope

### In Scope
- A master decomposition of the whole arc into five PR-scoped slices in the operator's recommended build order, with sub-divisions where a slice is too big for one clean PR, and explicit cross-slice dependencies.
- Full conversion of **Slice ① only** (kill per-tab cost badges) to a `READY_FOR_EXECUTION` doing doc.
- Re-verified file anchors for every slice (grep/symbol confirmed at current HEAD), so later conversions start from truth, not the ideation doc's possibly-stale line numbers.

### Out of Scope
- Implementation of any slice (work-doer executes; work-planner only produces docs).
- Converting Slices ②–⑤ to doing docs now — each converts at its turn, after the slice before it lands (named here as forward-declared units only).
- Work-context metadata (branch/diffstat/attention chips) as a *new* surface — that is a later slice, explicitly NOT part of Slice ① (which replaces the removed cost text with nothing).
- Re-pricing / billing accuracy work on `SessionPricing` — orthogonal; the Core pricing model is retained, just not surfaced per-tab.

## Completion Criteria
- [x] Master plan enumerates all five slices in build order with sub-divisions and cross-slice dependency notes.
- [x] Every slice carries re-verified file anchors (symbol + current-HEAD line), not just the ideation doc's numbers.
- [x] Slice ① is converted to a `READY_FOR_EXECUTION` doing doc with strict-TDD units, explicit acceptance, and the repo gates.
- [x] The exact cost-badge render site(s) are located by grep/symbol and recorded.
- [x] Defaults chosen for every ambiguity the ideation doc left open at the Slice-① level are recorded with rationale.
- [ ] 100% test coverage on all new code (enforced per-slice at doing-doc time)
- [ ] All tests pass (enforced per-slice)
- [ ] No warnings (enforced per-slice)

## Code Coverage Requirements
**MANDATORY: 100% coverage on all new code.**
- No `[ExcludeFromCodeCoverage]` or equivalent on new code (Swift: no growth of `Scripts/coverage-allowlist.txt`).
- All branches covered (if/else, switch, try/catch). Core uses region coverage (Swift llvm-cov has no branch counters) — 100% region == every arm taken.
- All error paths tested.
- Edge cases: null, empty, boundary values.
- New Core/ShellAdapter seams are gated by `Scripts/check-coverage.sh` to 100% line + region. App-side (`OuroWorkbenchApp`, GUI shell) is NOT coverage-gated but IS compiled under warnings-as-errors + strict-concurrency-complete.

## Open Questions
(Resolved as defaults — see Decisions Made. Listed here for traceability.)
- [x] Does removing the per-tab cost surface require touching Core `usd`/`usdLabel`/`SessionPricing`? → No; presentation-only removal (Decision D1).
- [x] Are the ⚡/💤 glyphs "spend icons" to remove, or work-context to keep? → They are `AttentionState` health glyphs (work-context), kept (Decision D2).
- [x] Does any test or UI surface probe assert on the cost chip? → No; verified (Decision D3).

## Decisions Made

### D1 — Slice ① is presentation-only; Core pricing model is retained.
The cost surface to remove is App-side render only: the `$X tok` `MetricChip` in `SessionChip`, its `tokenHelp` tooltip, the now-dead `compact(_:)` helper, and the `usd` mention in the chip's accessibility label. Core `SessionActivity.usd` / `.usdLabel` and `SessionPricing` are **kept** — they are pure Core seams under the 100% coverage gate with dedicated tests (`SessionActivityTests.swift`, `TailCoverageTests.swift`). Deleting them would force test deletions, risk the coverage gate, and exceed "minimal, independent, reversible." Rationale: scope discipline + reversibility — re-surfacing later (if ever) stays trivial.

### D2 — ⚡/💤 are health glyphs (work-context), not spend; they stay.
In code the `⚡`(`bolt.fill`) / `💤`(`moon.zzz.fill`) glyphs are driven by `AttentionState` (active/idle **health**), not by cost. They are exactly the "attention state / work context" the design wants to KEEP (AGENTS.md: attention state is P0). The ideation table's "remove ⚡/💤 spend icons" was a label misattribution: the only real *spend* surface is the `$X tok` text. Removing that text satisfies failure #1 without removing health context.

### D3 — No test/surface coupling to the cost chip.
`swift run … --uisurfacetest` (`UISurfaceTest.swift`) does not render or assert on `SessionChip`/`MetricChip`/`tok`/`usd`. No test references the App-side cost render. So Slice ① is safely independent; the only coverage to maintain is the unchanged Core pricing tests.

### D4 — Storage split (Slice ②) default: separate dedicated git-init-able store, not boss-bundled.
Per ideation §"Durable workspace state": durable **structure** (workspaces, tabs, names, groupings) splits from ephemeral **runtime** (pids, live status) in a separate, dedicated, `git init`-able store with an opt-in remote — NOT the boss bundle. The boss reads/writes structure as an MCP client; every change auditable. (Forward-declared; resolved at Slice ② conversion.)

### D5 — "Never auto-spawn" supersedes AGENTS.md P0 "safe auto-resume."
The AGENTS.md P0 line "safe auto-resume where the underlying CLI supports it" conflicts with the design's "never auto-spawn." Slice ④ reframes it to "propose-to-resume; restore the tab/representation, never auto-spawn the process," and updates AGENTS.md in the same PR. (Forward-declared.)

## Context / References

### Source of truth
- `worker/tasks/2026-06-24-1745-ideation-workspaces-onboarding-bring-back.md` — signed-off design.
- `AGENTS.md` — product truth, P0s, autonomy (TTFA), safety/auditability.

### Re-verified anchors at current HEAD (44f06e2)

**Slice ① — cost-badge render (CONFIRMED, exact):**
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3828-3831` — `SessionChip.body`: `if let activity, let usd = activity.usdLabel { MetricChip(label: "tok", value: usd).help(tokenHelp(activity)) }` — **this is the `$X tok` surface.**
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3868-3874` — `tokenHelp(_:)` (tooltip; cost-only helper).
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3876-3880` — `compact(_:)` (called ONLY by `tokenHelp`; becomes dead after removal).
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3889` — `accessibilityLabel`: `if let usd = activity.usdLabel { pieces.append("about \(usd) tokens") }`.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3636` — `TerminalAgentRow` uses `SessionChip(...)`; the chip still renders health glyph + todo mini after the cost removal (so the `activity != nil || isStalled` guard at :3635 stays valid).
- KEEP: `AttentionState.healthSymbol` (`bolt.fill`/`moon.zzz.fill`) @ :3767-3775 — health, not spend (D2).
- KEEP: `Sources/OuroWorkbenchCore/SessionActivity.swift:82-105` (`usd`, `usdLabel`) + `SessionPricing` @ :117 — Core pricing model retained (D1).

**Slice ②–⑤ anchors (re-verified, forward-declared):**
- Detection pipeline: `Sources/OuroWorkbenchCore/AgentSessionScanner.swift` — `scan(state:processLister:)`; forward-memory gate `discoverFromWorkbench` (drops entries lacking `discoveredHarness`/`discoveredSessionId` → root false-negative for Slice ④; ideation cites ~378-394, re-verify at conversion).
- UI lie: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` — `bossReconstructEmpty` rendered unconditionally (ideation cites :7256); `OnboardingBossReconstructView` (~7206-7274); `startBossReconstruction()` (~15642); `runBossQuickQuestion`/`runBossCheckIn` store reply in `bossCheckInAnswer`/`bossAppliedActions`. Re-verify at conversion.
- Onboarding strings + policy: `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift` (`WorkbenchOnboardingFlowPolicy`, `OnboardingReadiness`).
- Persistence: `Sources/OuroWorkbenchCore/WorkbenchStore.swift` (JSONDecoder .iso8601, schema backcompat), `WorkspaceModels.swift` (`ProcessEntry`, `workspace-state.json`), `WorkbenchPaths.swift`.

### Gates (every slice)
- Build/test strict: `swift build`/`swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`. 0 failures, 0 warnings.
- Coverage: `Scripts/check-coverage.sh` — new Core/ShellAdapter seams 100% line+region; `Scripts/coverage-allowlist.txt` must NOT grow.
- Local full gate: `Scripts/preflight.sh` (tests + `--uisurfacetest` + scenario verifier + package + artifact smokes).
- One commit per fix/unit. NO Co-Authored-By, NO AI attribution. Do NOT stage `SerpentGuide.ouro/`.

## Notes

Master decomposition into PR-scoped slices (operator's recommended build order). `→` = hard dependency.

**Slice ① — Kill per-tab cost badges** (independent; converted now)
- Remove the `$X tok` spend surface from sidebar terminal rows; replace with nothing.
- One PR. No dependencies. Reversible (presentation-only; Core pricing retained).
- Doing doc: `2026-06-24-1755-doing-slice1-kill-cost-badges.md`.

**Slice ② — Model + durable git-backable storage** (foundation) → none
The foundation everything else restores into. Likely sub-divides into clean PRs:
- ②a — Storage schema: split durable **structure** (workspaces, tabs, names, groupings) from ephemeral **runtime** (pids, live status) in `WorkspaceModels.swift`/`WorkbenchStore.swift`; migration of the current malformed 4-entry `workspace-state.json` (backcompat decoder). Pure Core; coverage-gated.
- ②b — Named workspaces/tabs model: delete the "Terminals in Home" concept and the second meaning of "workspace"; every session lives in a named workspace. Core model + App sidebar/tab layout (cmux: workspaces in sidebar, tabs across top).
- ②c — Dedicated git-init-able store + opt-in remote (D4): separate store path (`WorkbenchPaths`), `git init`, opt-in remote, multi-machine conflict handling. Boss reads/writes structure as MCP client; audit trail.
- ②d — In-app editing affordances: Rename Workspace (⇧⌘R), Rename Tab (⌘R), Pin Workspace, Remove Custom Workspace Name (revert auto-name). Naming model = auto-name + revertible custom override.
- Cross-slice: ②a→②b→②c; ②d after ②b. Slices ③ and ④ both depend on ②.

**Slice ③ — Required onboarding + returns-on-factory-reset** → ②
- Non-skippable onboarding; re-entered on factory reset. Unified flow: spawn/pick a boss → boss's first act is the propose-first discovery (which IS Slice ④'s flow) → seeds initial workspaces. `WorkbenchOnboardingFlowPolicy`/`OnboardingReadiness` enforce non-skippability and reset re-entry.
- Cross-slice: depends on ② (somewhere to put workspaces). Its discovery step is delivered by ④, so ③ and ④ co-design; ③'s gating/UX can land first behind a stubbed discovery, then ④ fills it — OR ④ lands first and ③ wraps it. Recommended: ④ first (the make-or-break engine), ③ second (the gate around it). Resolve ordering at conversion.

**Slice ④ — Propose-first bring-back** (THE make-or-break) → ②
- Never auto-spawn. Broad `AgentSessionScanner.scan()` candidate set (the persisted record is incomplete — missed an open Copilot session). Boss proposes org (workspace + tab names), each row carrying an **evidence tag** (`·established` / `·active Nm before restart` / `·recent`); confident items pre-ticked, rest offered. Operator approves/edits/renames. NOTHING spawns until approved. Then spawn into named workspaces/tabs.
- Sub-divisions likely:
  - ④a — Fix the forward-memory false-negative: `discoverFromWorkbench` gate drops valid entries (calibration: 0 records vs full scan's 32). Decide provenance-vs-recency confidence tiering (recency is reboot-contaminated).
  - ④b — Evidence-tag derivation + confidence tiering rule (`·established` vs `·active before restart` vs `·recent`).
  - ④c — Fix the UI lie: `bossReconstructEmpty` rendered unconditionally; wire the proposal UI to the boss's actual reply (`bossCheckInAnswer`/`bossAppliedActions`).
  - ④d — Approve-before-spawn flow: proposal → edit/rename → approve → spawn into named workspaces/tabs. Retire silent auto-spawn + `autoResume`-as-launch (reframe to "pre-ticked in proposal").
- Cross-slice: depends on ② (named-workspace targets to spawn into). Feeds ③'s onboarding discovery step.

**Slice ⑤ — Boss naming intelligence** → ②, ④
- Name-by-work, not directory: boss reads the session to derive a task-meaningful name (`~/ms-desk` → "Agent Substrate", not "ms-desk"). Auto-name + revertible custom override. Applies to both workspace and tab names produced by ④'s proposal.
- Cross-slice: depends on ② (naming model + revert affordance) and ④ (the proposal surface that consumes derived names).

**Retire/reword (spread across slices, tracked here so nothing is lost):**
- Per-tab cost badges → Slice ① (the `$X tok` text). (Note: ⚡/💤 are health glyphs, kept — D2.)
- "Terminals in Home" concept + second meaning of "workspace" → Slice ②b.
- Silent auto-spawn on reboot + `autoResume`-as-launch → Slice ④d.
- AGENTS.md P0 "safe auto-resume" reword → Slice ④ (D5).

## Progress Log
- 2026-06-24 Created master plan; anchors re-verified at HEAD 44f06e2; Slice-① render site confirmed.
