# Doing: Agent readiness detail-pane final sweep (false-green fix)

Branch: `fix/agent-readiness-detail-pane` (off `main` @ `ca9642c`)
Execution Mode: direct
Status: done (committed + pushed; NOT merged — parent cold-reviews)

## Goal

PRs #261/#262 made agent readiness live-aware: green/"ready" ONLY when a live
`ouro check` outward verdict is `.working`, resolved via
`InstalledAgentRowPresentation.liveReadiness(status:verdict:isChecking:)`. A grep
sweep found MORE surfaces still deriving readiness color/icon/pill/help/count from
raw config `agent.status`. After this change, NO readiness color/icon/pill/help/count
anywhere may derive from raw config `agent.status` — all must route through
`liveReadiness`, using the viewmodel maps `model.agentOutwardVerdicts[agent.name]`
+ `model.agentChecksInFlight.contains(agent.name)`.

## Surfaces

1. `OuroAgentRowView` (~:5713): `agentStatusColor`, `agentStatusImage`, `.help(agent.detail)`.
2. `AgentTitleStrip` (~:7792): `statusColor`. Has `model`.
3. `AgentStatusCard` (~:7969): `statusIcon`, `bundleStatusPillText`, color. Has `model`.
4. `ouroAgentStatusLine` (~:12261): `readyCount` live, not `status == .ready`.
5. `BossSelectorView.menuLabel` (~:4211): honest suffix for confirmed-bad verdict.

## Shared-seam icon helper (Core)

Add `iconSystemName(for: LiveReadiness) -> String` to InstalledAgentRowPresentation.swift.
Success glyph (`checkmark.seal.fill`) reachable ONLY from `.ready`. Exhaustive switch.

## Units

- ✅ **Unit 1 (Core):** add `iconSystemName(for:)` + exhaustive tests (100% line+region; allowlist unchanged at 2).
- ✅ **Unit 2 (App views):** route OuroAgentRowView, AgentTitleStrip, AgentStatusCard through the seam; thread verdicts. Source-pin tests in `AgentDetailReadinessWiringTests.swift`.
- ✅ **Unit 3 (App count + menu):** fix `ouroAgentStatusLine` readyCount (live) + `BossSelectorView.menuLabel` honest suffix. Source-pin.

## Verify (each unit)

`swift build`/`swift test` with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`;
`Scripts/check-coverage.sh` (Core 100% line+region; allowlist unchanged at 2). 0 failures.

## Constraints

- Do NOT stage untracked `SerpentGuide.ouro/`.
- No Co-Authored-By; no AI attribution.
- Commit per unit; push; DO NOT merge/PR.
- Pending/unverified is CALM (orange "checking…"/"not verified") — only confirmed-bad
  verdicts show warning glyph / "sign-in needed". No inverse false-RED.

## Progress Log

- 2026-06-22 17:06 Unit 1 complete: `iconSystemName(for:)` added to InstalledAgentRowPresentation.swift; 11 exhaustive tests (success glyph maps from `.ready` alone; pending stays calm). Core 100% line+region, allowlist still 2, 2468 tests pass, strict build clean.
- 2026-06-22 17:14 Unit 2 complete: OuroAgentRowView, AgentTitleStrip, AgentStatusCard each resolve a live `liveReadiness` (folding `model.agentOutwardVerdicts[agent.name]` + `agentChecksInFlight`) and derive color/icon/pill/help from the seam; config-only `bundleStatusPillText` removed. 10 source-pin tests in AgentDetailReadinessWiringTests pass. Strict build clean, Core 100%, allowlist 2.
- 2026-06-22 17:21 Unit 3 complete: `ouroAgentStatusLine` readyCount now counts `liveReadiness(...) == .ready`; `BossSelectorView.menuLabel` appends "— sign-in needed"/"— offline" for confirmed-bad verdicts, config suffixes kept, ready/pending/vault calm. 6 source-pin tests pass. Strict build clean, Core 100% line+region, allowlist 2. Full suite 2484 tests green (one pre-existing flake passed on rerun; my 27 tests deterministic).
- 2026-06-22 17:26 All gates passed. Grep proof: no readiness color/icon/pill/help/count derives from raw `agent.status` — remaining `agent.status` refs are all (a) the `status:` arg into `liveReadiness`, (b) config-descriptive `reason`/`statusHeadline` copy (renders only for non-ready config), or (c) probe-gating logic (`refreshAgentOutwardReadiness`/`runOnboardingProviderChecksIfNeeded`, which #261's tests pin as correct). SF-symbol map: `.ready`→`checkmark.seal.fill`, `.checking`→`ellipsis.circle`, `.unverified`→`questionmark.circle`, `.authExpired`/`.vaultLocked`/`.unreachable`→`exclamationmark.triangle.fill`, `.disabled`→`pause.circle.fill`, `.missingConfig`/`.invalidConfig`→`xmark.octagon.fill`. Final: strict build clean, 2484 tests / 0 failures, Core 100% line+region, allowlist 2. Branch pushed, NOT merged.
