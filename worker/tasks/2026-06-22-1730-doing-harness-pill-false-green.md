# Doing: Fix Harness Status sheet false-green pills (live readiness)

- **Branch:** `fix/harness-pill-false-green` (off `main` @ 335967d)
- **Execution Mode:** direct
- **Artifacts:** `./2026-06-22-1730-doing-harness-pill-false-green/`
- **Status:** in progress

## The bug
PR #261 fixed the steady-state sidebar + home "Installed agents" rows to show green/"ready"
ONLY when a live `ouro check --lane outward` returns `working`. The Harness Status sheet
("Harness Status…", Local agents section) was left unfixed and STILL false-greens: its
per-agent pill (`HarnessAgentRow`) AND its rollups all derive from `HarnessAgentEntry.isReady`,
which is config-only (`status == .ready`). An agent with an expired token counts as "ready" in
the headline AND shows a green pill on the surface an operator opens to check agent health.

## Reuse (do NOT reinvent)
- `InstalledAgentRowPresentation.liveReadiness(status:verdict:isChecking:) -> LiveReadiness`
  (honest seam; `.ready`/green producible ONLY by `verdict == .working`) plus `dotColor(for:)`
  / `label(for:)` / `help(for:)`.
- Viewmodel state #261 already computes: `agentOutwardVerdicts: [String: ProviderConnectionVerdict]`,
  `agentChecksInFlight: Set<String>`, populated by `refreshAgentOutwardReadiness()` (fires on
  launch + Refresh, called at end of `refreshOuroAgents()`). NO new `ouro check` calls.

## Units

### ✅ Unit 1 (Core, `HarnessStatus.swift`) — make `isReady` live-aware
- Add to `HarnessAgentEntry`: `var verdict: ProviderConnectionVerdict?` (default `nil`) and
  `var isChecking: Bool` (default `false`) — ADDITIVE init params with defaults.
- Add computed `var liveReadiness: InstalledAgentRowPresentation.LiveReadiness`.
- Change `isReady` from `status == .ready` to `liveReadiness == .ready`. Auto-fixes
  `readyCount`/`hasUnready`/`summaryLine`/`headline`/`overallState`/boss-reachability.
- Thread `outwardVerdicts`/`checksInFlight` dicts (defaulted empty) through
  `HarnessStatusBuilder.build()` → `agentInventory()` so the App can feed them in.
- Tests: update existing `.ready` fixtures to carry `verdict: .working` so they still count as
  ready (new correct semantics). ADD: `.ready` + `.unauthorized` → not ready / excluded /
  `hasUnready` / headline+overallState reflect it; `.ready` + nil + `isChecking` → not ready;
  config-problem entries unaffected (config dominates).
- **Acceptance:** `swift test` green; `Scripts/check-coverage.sh` 100% Core; allowlist stays 2.

### ⬜ Unit 2 (App wiring, `harnessStatus` / `refreshHarnessStatus`)
- At the `harnessStatusBuilder.build(...)` call site, thread
  `outwardVerdicts: agentOutwardVerdicts`, `checksInFlight: agentChecksInFlight`.
- Confirm `refreshHarnessStatus()` → `refreshOuroAgents()` → `refreshAgentOutwardReadiness()`
  keeps the dict current when the sheet (re)builds (already wired via #261 path).
- Source-pin test (`HarnessReadinessOverlayWiringTests.swift`): assert the `harnessStatus`
  build threads `agentOutwardVerdicts` + `agentChecksInFlight`.
- **Acceptance:** build + test green with strict flags.

### ⬜ Unit 3 (App view, `HarnessAgentRow`)
- Render pill label + tint + dot via `InstalledAgentRowPresentation.label(for: entry.liveReadiness)`,
  `dotColor(for: entry.liveReadiness)`, `help(for: entry.liveReadiness, detail: entry.detail)` —
  replacing `entry.status.harnessLabel`/`harnessTint`. Add a SwiftUI mapping from
  `InstalledAgentRowPresentation.DotColor` if not already present in this file.
- Remove the now-unused `OuroAgentBundleStatus.harnessLabel`/`harnessTint` extension (only used
  by `HarnessAgentRow`) — an unused private decl breaks `-warnings-as-errors`. Leave the
  `BossWorkbenchMCPRegistrationStatus` variants (still used).
- Source-pin (extend Unit-2 file): `HarnessAgentRow` no longer derives label/tint from the
  config-only `harnessLabel`/`harnessTint`; consults `liveReadiness`.
- **Acceptance:** build + test green with strict flags; coverage 100%; allowlist 2.

## Verify (every unit)
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
- `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
- `Scripts/check-coverage.sh` (Core 100% line+region; allowlist 2)

## Progress log
- 2026-06-22 16:16 Unit 1 complete (c0598df): `HarnessAgentEntry` gains `verdict`/`isChecking`
  (defaulted) + `liveReadiness` accessor; `isReady` = `liveReadiness == .ready`. Verdict maps
  threaded through `HarnessStatusBuilder.build()`. Updated existing `.ready` fixtures to carry
  `verdict: .working`; added 6 false-green honesty tests. 2447 tests pass (was 2441), Core 100%
  line+region, allowlist still 2. Strict build + strict harness tests green.
