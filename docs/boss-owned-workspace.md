# Boss-Owned Workspace

The direction Workbench is building toward, and the plan to get there. Captured so the
build stays on-shape instead of churning.

## Vision

Workbench is the **boss agent's workspace to own**. The operator talks to the boss; the boss
sees every agent session — running, recently-ended, or started stray in some other terminal —
and it reconstructs, adopts, tidies, and watches over all of them, proposing what it'll do for
the operator to approve. The operator opens an actual terminal only to *sit with* one agent and
collaborate directly. Everything else, the boss runs. **Terminals are the boss's to manage, not
the operator's to babysit.**

## The loop (evergreen — not an onboarding feature)

`see → propose → act`, run by the boss, anytime:
- **see**: discover agent sessions (recent + running + stray + in-Workbench).
- **propose**: hand the operator a list to approve/edit (or, fallback, just say it in chat).
- **act**: launch / adopt / archive / organize via the boss's Workbench tools.

Use cases that are all the same loop: **reconstruct** lost work, **adopt** a stray session,
**tidy** the workspace, **monitor** what needs attention. Onboarding's "bring back my work" is
just the first time the boss runs the loop.

## Hard principle (why the earlier attempt was wrong)

Workbench provides **general primitives only** — it knows nothing about `agency`, `-a
ms-desk:worker`, repo→agent maps, or any one operator's MS workflow. All context-specific
intelligence (which agent, which repo, the exact `agency … --resume` command, what's worth
keeping) lives in the **boss agent**, which is already configured for the operator and runs the
same models as the assistant building this. The bespoke "pick your agency agent" scanner/UI was
overfitting; it was cut.

**Usefulness is the only cut line.** Build everything in this plan that's useful; cut anything
that isn't. No v1/v2 gating.

## Grounded: what the boss already has (Workbench MCP, `Sources/OuroWorkbenchMCP/main.swift`)

- `workbench_create_session` — launch a terminal (owner, name, command, group, cwd, trust). ✓
- `workbench_request_action` — `createTerminal`, `sendInput`, `moveSession`, provider verify/select. ✓ (drive + organize)
- `workbench_sessions` — list **in-Workbench** sessions (owner/name/archived filters). ✓
- `workbench_transcript_tail` / `workbench_search_transcripts` — inspect output. ✓
- `workbench_status` / `workbench_visibility` / `workbench_sense` — state + the boss's tool contract. ✓

So the boss can already *drive* terminals. The base is solid.

## Gaps — ALL SHIPPED (boss-owned-workspace feature, `fix/onboarding-audit`)

Every gap below landed across Slices 0–9 of `boss-owned-workspace-doing.md`. The Slice 9
integration smoke (`boss-owned-workspace-doing/integration-smoke.py`) proves the whole
`see → propose → act` loop composes end-to-end against the real MCP binary.

1. ✅ **Discover sessions not yet in Workbench** — `workbench_discover_agent_sessions` backed by
   the **general** Core `AgentSessionScanner` (clean sibling of the rejected `RecentSessionScanner`):
   - Claude: `~/.claude/projects/<encoded-cwd>/<id>.jsonl` → cwd, gitBranch, timestamp, title (TOP-LEVEL keys).
   - Copilot: `~/.copilot/session-state/<id>/workspace.yaml` via the custom `FlatYAMLReader` (no SPM dep)
     → cwd, repository, branch, name, timestamps.
   - Plus *running* agent sessions via an injected process-lister closure (App supplies the `ps` shell).
   - Plus *Workbench-native* sessions via forward memory (item 6), merged sessionId-aware.
   - Returns general records `{harness, sessionId, cwd, repository, branch, title, lastActive, running}`.
   - **No `agency` knowledge** — the boss builds the relaunch command itself. *(Slices 0–4)*
2. ✅ **Propose-for-approval** — the general Core `AgentProposal`/`AgentProposalQueue` primitive +
   `workbench_propose` / `workbench_proposal_result` MCP tools + the native `BossProposalCardList`
   card. A CAPABILITY, never a gate — the boss may also just act; conversational fallback stands. *(Slice 5)*
3. ✅ **Archive / organize** — audited: `BossWorkbenchActionKind` + `applyBossAction` already cover
   archive / restore / createGroup / createTerminal / moveSession at model + validation + apply layers.
   No gap, no new action kind. *(Slice 0)*
4. ✅ **Onboarding hand-off** — the wizard's `importWork` page now renders the boss-driven
   `OnboardingBossReconstructView` (`.bossReconstruct` phase) that hands the boss the
   `see → propose → act` task. `RecentSessionScanner` is KEPT-BUT-UNWIRED from the primary path. *(Slice 7)*
5. ✅ **Boss-primary UX** — `SessionStatusListView` (running / waiting-on-you / done, driven by the pure
   Core `SessionStatusList`) fronts the boss dashboard. ADDITIVE — the terminal sidebar is untouched and
   still mounted, so terminals stay drop-in-to-collaborate. *(Slice 8)*
6. ✅ **Forward memory** — additive optional `discoveredHarness`/`discoveredSessionId` on `ProcessEntry`
   (decode-if-present, backward-compatible), stamped at session-create, rediscovered NATIVELY by
   `AgentSessionScanner.discoverFromWorkbench`. Future discovery is native, never inferred. *(Slice 6)*

Bonus (gap found during Slice 8): ✅ **Health-probe** — the pure Core `SessionHealthProbe`
(`healthy / starting / stalled / failed`, reusing `AttentionSignalDetector`) + `workbench_session_health`,
so the boss verifies a resumed session deterministically instead of interpreting raw tails ad hoc.

## Status of the separate onboarding-fix batch (already done, green)

Independent of this feature: the 26-day onboarding root cause (provider check ran `ouro` with no
PATH → failed for every agent) is fixed + proven, plus ~20 audit findings (hang watchdogs, the
dead `repair-*-provider` buttons now re-check, the Arrange-footer dead button, boss-pick gibberish
copy, raw-error-leak banners, lane jargon). Core coverage 100%. Ready to install whenever the
operator wants a working wizard — independent of the boss-owned-workspace build above.
