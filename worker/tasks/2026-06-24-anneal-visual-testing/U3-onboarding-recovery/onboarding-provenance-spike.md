# SU-E0 — onboarding provenance spike (Q3 + Q4 + Q2) — VERDICT: GO

Throwaway spike (`Tests/OuroWorkbenchAppViewsTests/SUE0SpikeThrowaway.swift`, now deleted)
run on branch `feat/anneal-u3-su-e-onboarding` @ the SU-E2 commit (`d408c55`).

## Q3 — boss-choice provenance seam: direct `model.ouroAgents` injection — CONFIRMED (default taken)

Setting `model.ouroAgents = [OuroAgentRecord(...)]` (the same `@Published` the live
`refreshOuroAgents()` scanner writes) + `model.state.boss.agentName = "<name>"` produces the
intended `onboardingBossChoices` deterministically:
- `bossAgentChoices = Set(ouroAgents.map(\.name) + bossDashboard?.knownAgentNames + [state.boss.agentName])`
  filtered to valid bundle names + sorted case-insensitively → exactly the injected names.
- `choice.isSelected` ← `state.boss.agentName` case-insensitive match (verified: "alpha" selected).
- `choice.isUsable` ← `status == .ready && isValidAgentBundleName` (verified: `.ready` usable,
  `.disabled` NOT usable).
- `choice.statusLabel` ← pure Core `OnboardingBossChoiceCopy` (`.ready`→"installed",
  `.disabled`→"turned off").
- NO `refreshOuroAgents()` / home scan needed; the rendered `OnboardingBossChoiceView` tree has
  NO `/Users/` leak (AN-001 temp `agentBundlesURL` is injected into BOTH the registrar AND the
  inventory anyway, so a stray scan would hit the empty temp dir, not the real home).
- `bundlePath`/`configPath` are NOT rendered by the boss-choice surface (confirmed — only
  `choice.name`/`detail`/`statusLabel` render), so the (ignored) fixture paths can't leak.

Fallback (b) — writing fixture `*.ouro` bundles into the temp `agentBundlesURL` so `scan()`
returns them — was NOT needed.

## Q4 — readiness / first-run producer seam — CONFIRMED (already exercised in SU-E2)

`FirstRunBootstrapDrive.presentIdle()` / `.present(result:activeStep:)` → `model.firstRunPresentation`
maps injected inputs deterministically (SU-E2 landed all 6 mode refs through this seam). The
`WorkbenchOnboardingAdvisor.readiness(...)` → `model.onboardingReadiness` producer is validated
in SU-E4.

## Q2 — `.onAppear` / `.task` no-fire under the synchronous `inspect()` path — CONFIRMED

`OnboardingBossChoiceView` has no `.onAppear`/`.task` of its own; `OnboardingReadinessView` has
`.onAppear { startFirstRunBootstrapIfNeeded() }`. Snapshotting both via `ViewSnapshotHost`
(the no-`ViewHosting` `inspect()` path) did NOT fire/crash either side effect — consistent with
the U2 precedent (`BossProposalCardList`/`WorkbenchSidebarView` `.task` did not fire).

## Decision recorded

Use direct `model.ouroAgents` injection for boss-choice (Q3 default), with the AN-001 temp
`agentBundlesURL` injected in every VM fixture. The true-empty state (`E3.none`) requires BOTH
empty `ouroAgents` AND empty `state.boss.agentName` (a non-empty boss always yields ≥1 choice).
The spike test file is deleted; only this verdict is retained.
