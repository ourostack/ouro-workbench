# Doing: Fix steady-state agent-row false-green (live readiness)

- **Branch:** `fix/agent-readiness-false-green` (off `main` @ 911a93e)
- **Execution Mode:** direct
- **Artifacts:** `./2026-06-22-1516-doing-agent-readiness-false-green/`
- **Status:** done

## The bug
Steady-state agent rows (sidebar `SidebarAgentRow` + home-screen "Installed agents"
card) show a GREEN dot + "ready" for every agent whose `agent.json` exists and isn't
disabled — WITHOUT a live connection check. Ground truth: `ouro check --agent slugger
--lane outward` → `failed (401 … authentication token is expired)`, yet the UI shows
slugger "ready". Same false-green family as the F2 Connect fix, on a surface F2 didn't
cover.

Root cause: `OuroAgentInventory.swift:157` sets `status = enabled==false ? .disabled :
.ready` (config-only). Views render that static `.ready` as a green dot + "ready" pill +
"ready" tooltip, computed once at launch and frozen.

## Reuse (do NOT reinvent)
- `ProviderCheckClassifier` → `ProviderConnectionVerdict { working, vaultLocked,
  unauthorized, unreachable, indeterminate }`. Never false-greens.
- `runColdStartProviderCheck(agentName:lane:) async -> ProviderConnectionVerdict?`
  (`OuroWorkbenchApp.swift:15120`, on `WorkbenchViewModel`) — 15s watchdog, resolved
  PATH, classifies via the classifier, nil = couldn't confirm. REUSE for lane "outward".

## Units

### ✅ Unit 1 (Core) — live-aware presentation seam
Extend `InstalledAgentRowPresentation` (do NOT touch `OuroAgentBundleStatus`). Add
`LiveReadiness` enum + `liveReadiness(status:verdict:isChecking:)` + `dotColor(for:
LiveReadiness)` + `label(for:)` + `help(for:detail:)`. Keep existing `dotColor(for
status:)` + `reason(for:detail:)`.
- Resolution order (HONESTY INVARIANT): config problems dominate → else verdict!=nil map
  it → else isChecking → `.checking` → else `.unverified`.
- Pinned: green IFF `.ready` IFF only producer is `verdict==.working`; static `.ready` +
  nil verdict + !checking → `.unverified` (not green); + checking → `.checking`.
- Tests: exhaustive truth table (status × verdict × isChecking) over LiveReadiness +
  dotColor + label. 100% line+region. Allowlist stays at 2 entries.
- **Acceptance:** `swift test` green; `Scripts/check-coverage.sh` 100% Core.

### ✅ Unit 2 (App wiring) — run the live check + store verdicts
On `WorkbenchViewModel` add `@Published var agentOutwardVerdicts: [String:
ProviderConnectionVerdict]` + `@Published var agentChecksInFlight: Set<String>`. Add
`func refreshAgentOutwardReadiness()` that, for each `ouroAgents` record with `status ==
.ready` AND configured outward lane (`humanFacing?.provider/model != nil`), marks
in-flight, calls `runColdStartProviderCheck(... lane: "outward")`, stores verdict, clears
in-flight — all `@Published` mutations on main actor, per-agent checks concurrent
(`TaskGroup`), non-blocking. Call it at the end of `refreshOuroAgents()`.
- Source-pin test (`AgentReadinessOverlayWiringTests.swift`): `refreshOuroAgents` calls
  `refreshAgentOutwardReadiness`; that method references `runColdStartProviderCheck` +
  `"outward"` + gates on `humanFacing`; the @Published props exist.
- **Acceptance:** build + test green with strict flags.

### ✅ Unit 3 (App views) — route rows through the live-aware seam
- `SidebarAgentRow`: take `verdict` + `isChecking` (or pre-resolved `LiveReadiness`).
  Dot via `dotColor(for: liveReadiness)` (replace `dotColor(for: agent.status)`); tooltip
  via `help(for: liveReadiness, detail:)` (replace `.help(agent.detail)`).
- Home-screen card (call site ~2847) + sidebar list (~3021): thread params from
  `agentOutwardVerdicts`/`agentChecksInFlight`.
- Harness pill (`HarnessAgentRow`/`harnessLabel`): **DECISION — left as-is.** It lives in
  the Harness Status DIAGNOSTIC sheet ("Local agents" section), built in Core
  (`HarnessStatus.swift`) from `OuroAgentRecord.status` via a `Sendable` `HarnessAgentEntry`
  that carries `status: OuroAgentBundleStatus` (+ an `mcpStatus`), driven by its own separate
  `refreshHarnessStatus()` async pipeline — NOT by the viewmodel's `agentOutwardVerdicts`. It
  represents the same installed agents and its "ready" pill carries the same config-only
  false-green, but routing live verdicts through it means adding fields to a pure Core type,
  threading them through `refreshHarnessStatus`, and changing the section's `hasUnready` health
  rollup — a meaningfully larger, separable change on a distinct surface. The task's primary
  surfaces (sidebar + home card, the F2-uncovered steady-state rows) are fixed; the harness
  diagnostic pill is logged as a fast-follow.
- Source-pin: `SidebarAgentRow` no longer `.help(agent.detail)` for readiness, no longer
  `dotColor(for: agent.status)`; consults live-aware API.
- **Acceptance:** build + test green; coverage 100%; ~2409 tests pass.

## Verification (every unit)
`swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
`swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
`Scripts/check-coverage.sh` (Core 100% line+region; allowlist unchanged at 2).

## Constraints
- Do NOT add/commit `SerpentGuide.ouro/`. Stage only changed source+test files.
- No Co-Authored-By; no AI attribution. Commit per unit. Push branch. NO PR / merge.

## Completion Criteria
- [x] Unit 1: live-aware seam + exhaustive Core tests, 100% coverage.
- [x] Unit 2: viewmodel runs outward checks concurrently, stores verdicts, wired into refresh.
- [x] Unit 3: sidebar + card rows render live readiness; harness-pill decision recorded (left as-is — distinct diagnostic surface; see report).
- [x] Strict build + full test suite green; coverage gate passes; allowlist at 2.

## Progress log
- 2026-06-22 15:23 Unit 1 complete: Core live-aware seam (LiveReadiness + dotColor/label/help), exhaustive truth table, 2430 tests pass, coverage 100%, allowlist still 2. SHA 4585aa6.
- 2026-06-22 15:38 Unit 2 complete: WorkbenchViewModel runs concurrent outward ouro-check per config-ready agent (TaskGroup), stores verdicts + in-flight set, wired into refreshOuroAgents. Strict build clean; 6 wiring tests green; coverage gate PASS. SHA 7bc8a23. (Noted a pre-existing intermittent test flake — no test invokes the viewmodel, so it is independent of this diff; characterizing in background.)
- 2026-06-22 15:43 Unit 3 complete: SidebarAgentRow + both call sites (sidebar list + home card) route dot/tooltip through InstalledAgentRowPresentation.liveReadiness; harness diagnostic pill left as-is (distinct surface, logged as fast-follow). Strict build clean; 11 wiring tests green; full suite 2441 tests 0 failures; coverage PASS; allowlist 2. SHA 5a19bf8.
