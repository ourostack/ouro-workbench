# Onboarding overhaul — autonomous fix loop (doing doc)

Durable spec for the autonomous bug-fix loop the operator handed off ("ship is yours, don't
return control until literally all this is fixed"). This file is the source of truth across
context compactions — post-compaction, read this + `gh issue list --repo ourostack/ouro-workbench
--state open` to resume.

Branch: `fix/onboarding-audit` (already carries the `-ilc` PATH fix, the onboarding doctor, and
the boss-owned-workspace feature). New fixes land here; merge to `main` when onboarding works
end-to-end + verifies. Commits: NO Co-Authored-By, NO AI attribution (per global CLAUDE.md).
Push/gh on `ourostack/*` needs the personal identity (`gh auth switch -u arimendelow`), restore
EMU (`arimendelow_microsoft`) after.

## Investigation findings (subagents, 2026-06-20)

**Lane architecture (ouro side):**
- `outward` + `inner` are the CURRENT canonical lanes. `humanFacing`/`agentFacing` are DEPRECATED
  legacy aliases (outward=humanFacing, inner=agentFacing). README: outward = CLI/Teams/Mail/Voice;
  inner = private agent-facing turns ("The Agent's Inner Life"). Inner is NOT removed.
- Lanes are independently configurable per agent: `ouro use --lane outward|inner --provider <p>
  --model <m>`. Proof: slugger = outward openai-codex/gpt-5.5, inner minimax/MiniMax-M2.5.
- ouroboros: BOTH lanes = github-copilot/gpt-5.4 (same) → the double-check is redundant for it.
- Per-lane provider/model readable from `<bundle>/state/providers/readiness.json` (JSON: lanes.
  {outward,inner}.{provider,model,status,checkedAt}) or agent.json (humanFacing/agentFacing).
- **No model catalog in ouro.** Providers = fixed enum of 5. Model validation is prefix-only; any
  string passing the prefix is accepted. The github-copilot `/models` endpoint helper exists in code
  but is wired to NO command. ⇒ "a newer model (5.5) is available" CANNOT be detected from ouro;
  needs an external source of truth. DEFER that nudge; offer manual model-change only.

**Workbench side (lane usage map):**
- Checks: `runOnboardingProviderCheck` / `runOnboardingProviderChecksIfNeeded` (App.swift ~13136),
  already SERIALIZED, 40s watchdog each. Warm `ouro check` = ~12s and passes → #228 timeout is a
  slow COLD first-check after reset, not concurrency.
- `friendlyLaneLabel` (App.swift ~13289): outward→"main", inner→"background" (Workbench invention).
- Readiness + repair steps: `WorkbenchOnboardingAdvisor.readiness` + `providerRepairSteps`
  (Core/Onboarding.swift 189-425). "Repair <agent>" + "needs setup before it can be a reliable
  boss" at 354-362. Connect rows render from `readiness.repairSteps`.
- Connect view: `OnboardingReadinessView` (5757), `OnboardingRepairStepRow` (5825); `actorLabel`
  (5894): "checking"/"agent"/"you"/"choose"; Fix/Run/Connect button (5862).
- Workbench ALREADY reads each lane's real provider/model (OuroAgentInventory humanFacing/
  agentFacing) → same-provider collapse needs no new plumbing, just a comparison.
- Wizard pages (App.swift 5011): welcome → boss → connect → importWork. "Done" header button
  (5259) dismisses at any page. NO "onboarding completed" flag anywhere → the stale-boss lockout.
- Present logic: `shouldPresentOnboardingOnLaunch` / `canAutoPresentOnboardingOnLaunch` (10287) key
  on "boss set + auto-presented once", never on genuine completion.

## Units (ordered)

- [x] **U1 — Lane clarity (Core).** `Onboarding.swift`: when outward & inner resolve to the SAME
  provider+model, `readiness` emits ONE connection step (not main+background); when they DIFFER,
  two, each labeled with the actual `provider · model` + a plain role. Drop the opaque bare
  "main/background". TDD in OnboardingTests. (#234, partial #232/#233 copy)
- [ ] **U2 — Lane clarity (App).** Check orchestration runs ONE check (outward) when lanes are
  equivalent; Connect rows show `provider · model` + legible status ("Checking…/Connected/Needs
  you/Timed out"); fix the step title (not "Give the boss its tools" when it's checking — #229);
  no "Repair <agent>" while still checking (#231); "Fix"→"Try again" honest label (#233).
- [ ] **U3 — Transactional wizard (#227).** Add persisted `onboardingHasBeenCompleted`. Present
  until completed (not "boss set"). Snapshot boss on wizard open; rollback (restore snapshot) on
  dismiss-without-completion; set completed when the user reaches the end. Header button = "Cancel"
  (rollback) until complete, then "Done" (commit). Kills the stale-boss lockout at the root.
- [ ] **U4 — Check robustness (#228).** A slow first/cold check must not hard-fail at 40s with a
  scary "took too long"; show a patient "still connecting…" past ~20s, keep a higher ceiling, and a
  real retry. (Combined with U1 collapse, one check not two ⇒ half the wait.)
- [ ] **U5 — Provider/model confirm step (#230 + model-switch).** Before the check, a step that
  SHOWS the agent's provider · model (read agent.json/readiness.json) and lets the user confirm or
  CHANGE it (`ouro use`). "Newer model available" nudge DEFERRED (no ouro catalog — see findings);
  file/keep an issue documenting the external-catalog dependency.
- [ ] **U6 — In-app "Report a Bug" (#236).** Simple "what went wrong" form + auto screenshot +
  anonymized context (version, step, readiness snapshot, recent action-log; strip usernames/paths/
  tokens/agent names) → files a GitHub issue (label needs-triage). Built for boss-triage later;
  human/agent backstop now.
- [ ] **U7 — Version alignment (#235).** DashboardStatusLine alignment param — already staged in
  working tree; verify + keep.
- [ ] **U8 — Verify + merge.** Build, full tests (Core 100% gate), onboarding doctor; independent
  review subagent per concern; merge fix/onboarding-audit → main closing #227-236.

## Precise design notes (for resume after compaction)

**U3 transactional (surface located):**
- Boss persists IMMEDIATELY: `selectBoss(agentName:)` (App.swift ~11417) sets `state.boss.agentName`
  + every `projects[].boss` + calls `save()` (writes to disk). This is the non-transactional leak.
- Add persisted `onboardingHasBeenCompleted` (UserDefault, default false; key like
  `ouro.workbench.onboardingCompleted`).
- Snapshot `state.boss` (+ `projects[].boss`) when the wizard opens (a model prop set in
  `presentOnboarding()`/the sheet `.task`). On dismiss WITHOUT completion, restore the snapshot +
  `save()` (rollback) so a half-finished pick never persists.
- Set `onboardingHasBeenCompleted = true` when `advance()` goes connect→importWork with a ready
  boss (App.swift ~5198-5206, the `else` branch that sets `page = .importWork`).
- Present logic: `shouldPresentOnboardingOnLaunch` (App.swift ~10287) currently returns false when
  boss-ready. Change to present until `!onboardingHasBeenCompleted` (keep the forced-first-run +
  needsAgent paths). `canAutoPresentOnboardingOnLaunch` (~10298) should gate on
  `!onboardingHasBeenCompleted` instead of `!onboardingHasAutoPresented`.
- Header button (App.swift ~5259, currently "Done"): label "Cancel" (→ rollback) until completed,
  "Done" (→ just dismiss; commit already happened) once completed.

**U2 view surface:** OnboardingRepairStepRow (~5825), actorLabel (~5894: "checking"/"agent"/"you"/
"choose" → "Checking…"/"Needs you"), Fix button (~5862 → "Try again"), step header "Give the boss
its tools" (~5763 → accurate), "Repair <agent>" headline while checking (Core Onboarding.swift
354-358 → neutral "Checking <agent>…" when only check-* steps are present, "Repair" only when a
real failure/unconfigured step exists).

## Progress log
- 2026-06-20: doc created; SA1+SA2 investigations complete; #235 alignment committed (8d16be3);
  U1 (Core lane-collapse) dispatched to a work-doer; U3 surface located + design recorded.
- 2026-06-20: U1 complete (92692b8). Core-only, strict TDD. `OuroAgentLane.displayLabel`
  ("provider · model", U+00B7) + `OuroAgentRecord.lanesShareOneConnection` (both lanes fully
  configured AND equal); `readiness` collapses equivalent lanes to ONE outward check ("your
  agent's connection") and labels divergent lanes "the model it talks with" / "…thinks with",
  each carrying its real provider·model; `providerRepairSteps` reworked to (connectionTitle,
  providerLabel) keeping the same step ids/actors/commands. OnboardingTests green
  (`swift test --filter OnboardingTests` = 69 pass), full Core suite 1435 pass / 1 skip / 0 fail,
  Core 100% line+region coverage gate PASS, `swift build` clean (App included).
