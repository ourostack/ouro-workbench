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

## Gaps to build

1. **Discover sessions not yet in Workbench** — the foundation of reconstruct + adopt. A new
   `workbench_discover_agent_sessions` tool backed by a **general** Core scanner:
   - Claude: `~/.claude/projects/<encoded-cwd>/<id>.jsonl` → cwd, gitBranch, timestamp, title.
   - Copilot: `~/.copilot/session-state/<id>/workspace.yaml` → cwd, repository, branch, name, timestamps.
   - Plus *running* agent sessions (live processes) for adopt.
   - Returns general records: `{harness, sessionId, cwd, repository, branch, title, lastActive, running}`.
   - **No `agency` knowledge** — the boss builds the relaunch command itself.
2. **Propose-for-approval** — a general "boss proposes a list of items, operator ticks/edits,
   result returns to the boss" primitive. This *is* the editable map, and it's reused by
   reconstruct/tidy/adopt. Conversational fallback if the card slips.
3. **Archive / organize** — confirm `request_action` covers archive + group-create; add what's missing.
4. **Onboarding hand-off** — replace the hardcoded terminal-session import step with: hand the
   boss the `see → propose → act` task. (The old `RecentSessionScanner` terminal-scan is the
   "messy" approach the operator rejected.)
5. **Boss-primary UX** — operator interacts with the boss + a boss-managed session view;
   terminals are drop-in-to-collaborate. (Assess scope against usefulness.)
6. **Forward memory** — when Workbench launches a session it owns the command, so it records
   `{agent, command, cwd, harness, sessionId}`. Future discovery is then native, never inferred.
   Inference is a one-time bridge for sessions that already exist.

## Status of the separate onboarding-fix batch (already done, green)

Independent of this feature: the 26-day onboarding root cause (provider check ran `ouro` with no
PATH → failed for every agent) is fixed + proven, plus ~20 audit findings (hang watchdogs, the
dead `repair-*-provider` buttons now re-check, the Arrange-footer dead button, boss-pick gibberish
copy, raw-error-leak banners, lane jargon). Core coverage 100%. Ready to install whenever the
operator wants a working wizard — independent of the boss-owned-workspace build above.
