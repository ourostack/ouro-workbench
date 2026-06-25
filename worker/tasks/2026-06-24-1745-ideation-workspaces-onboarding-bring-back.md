# Ideation: Workspaces, Required Onboarding & Propose-First Bring-Back

**Status:** design converged (operator signoff 2026-06-24) — handoff to `work-planner`. **No implementation yet.**
**Source:** live design conversation, post-reboot, after "Bring back your work" reported "Nothing to bring back" while work was lost.
**Operator intent (verbatim-ish):** "focused and intentional work, not spend anxiety." "always propose first, never auto spawn — as soon as it's wrong, folks will drop off and never return." "this product needs to require onboarding." "auditability is important for trust, which is a precursor to TTFAing."

---

## The mental model (settled): cmux / soloterm, full stop

A sidebar of **named workspaces**, each containing **named, tabbed terminals**. That is the whole model.

- **Workspace** = a named, human-meaningful grouping (a *theme/task*, not a directory). It can span repos (cmux "Ouroboros" = ouro-workbench + ouroboros + ouro-md) and the same repo can back many workspaces (`~/ms-desk` backs several). Sidebar row is lean: name + light work-context. **No PWD dump.**
- **Tab** = one named terminal / agent session inside a workspace.
- **"Terminals in Home" is deleted** as a concept. There is no second meaning of "workspace" and no junk-drawer bucket. Everything lives in a named workspace.
- **Right metadata = work context** (git branch, diffstat, "waiting on you" / attention state — e.g. `main · ~/ms-desk :3,457 :9,222`). **Wrong metadata = spend** (per-tab `$X tok`, ⚡, 💤 are all removed).

This collapses the old "workspace vs Home" muddle into a model every developer already understands.

## The five failures this resolves

| # | Failure (observed) | Resolved by |
|---|---|---|
| 1 | Per-tab cost badges (`$6.47 tok`, ⚡/💤) | Remove cost surfacing; show work-context instead |
| 2 | Bring-back can't tell 2 open sessions from 30 historical; UI lies "Nothing to bring back" | Propose-first flow + evidence tags (below) |
| 3 | Reboot silently auto-spawns 4 duplicate `Resume ouro-workben…` terminals into Home | Never auto-spawn; named workspaces/tabs; retire `autoResume`-as-launch |
| 4 | Onboarding is skippable and does not return after factory reset | Required onboarding; re-entered on reset |
| 5 | "workspaces" vs "terminals in home" is incoherent | The cmux model above (no Home) |

Two root causes: **(A)** "workspace" was overloaded with no enforced model; **(B)** nothing established or restored the model, so state arrived malformed.

## Flow 1 — Onboarding (required, returns on factory reset)

- **Non-skippable.** A fresh or factory-reset machine cannot reach steady-state without completing it.
- Onboarding = **spawn/pick a boss** (if you don't already have one) → **set up your workspace**. The boss's *first act is the propose-first discovery* (Flow 3), which seeds your initial workspaces. One unified flow — not a separate "now manually create workspaces" step.

## Flow 2 — Steady state

- Sidebar = named workspaces; active workspace shows named tabs across the top (cmux layout).
- In-app editing is first-class (matches cmux affordances the operator confirmed): **Rename Workspace (⇧⌘R), Rename Tab (⌘R), Pin Workspace, Remove Custom Workspace Name** (revert auto-name).
- Naming model: **auto-name (boss-proposed) + optional custom override (operator), revertible.**

## Flow 3 — Bring-back (THE make-or-break: propose-first, never auto-spawn)

The retention-critical surface. Get it wrong once and users churn permanently.

1. **Discover broadly.** Keep the full `AgentSessionScanner.scan()` candidate set — the operator's own persisted record is *incomplete* (it missed an open Copilot session), so broad scan is the safety net.
2. **Propose, conversational + fully transparent.** Boss presents proposed org — workspace names + tab names — grouped, each row carrying its **evidence tag**: `·established` (was in saved workspace state), `·active 4m before restart`, `·recent`. Confident items pre-ticked; the rest offered ("here's what I think you had open; tick any of these others").
3. **Operator approves / edits / renames.** **Nothing spawns until approved.**
4. **Then** spawn — into named workspaces with named tabs.

**Naming insight (make-or-break):** *name by the work, not the directory.* `~/ms-desk` hosts many unrelated tasks, so "ms-desk" is a useless tab name; "Agent Substrate" (the task) is the good one. The boss reads the session to derive it. Directory-naming is what produced `Resume ms-desk (Clau…`.

## Durable workspace state (settled: first-class + git-backable)

- Workspace structure (workspaces, tabs, names, groupings) is **durable, first-class state** — it survives reboot so a restart restores *"your workspaces + which tabs to resume,"* not "30 loose sessions to re-sort."
- **Store: separate + dedicated + `git init`-able with an opt-in remote.** NOT the boss's bundle. Ownership is the point: the boss is a *swappable coordinator* (AGENTS.md: an Ouro agent is *selected as* boss). Boss-bundled state fails three ways — onboarding has nowhere to put workspaces before a boss exists; swapping bosses orphans/forks the layout; two bosses = two competing copies.
- The current `workspace-state.json` is the seed: split durable **structure** from ephemeral **runtime** (pids, live status). The boss reads/writes the structure as an MCP client; every change is auditable. Opt-in git remote matches how the operator already runs (`~/worker-workspace` propagating via git).

## Principle: transparency/auditability always

Every proposed row shows its *why* (evidence tag) before approval. Audit trail → trust → TTFA. This is a hard requirement, not a nice-to-have.

## Calibration evidence (empirical, 2026-06-24, against real post-reboot disk)

- `discoverFromWorkbench` → **0 records**: all 4 persisted "open" entries have `discoveredHarness=nil`, so the forward-memory gate (`AgentSessionScanner.swift:378–394`) drops every one — the clean provenance signal is lost.
- Full `scan(state:, processLister:{[]})` → **32 records** (11 Claude + 21 Copilot). Detection is *not* empty.
- The 2 real open Claude sessions (`939957c4…` ouro-workbench, `2698d0f0…` ms-desk) are present and **top-sorted**, but buried among 30 historical sessions with no "was open here" marker.
- The persisted record is **incomplete** (missed an open Copilot session) → broad scan must stay.
- Recency is **reboot-contaminated** (this session went active *after* the 07:34 boot) → lean on provenance, not pure recency, for "confident."
- UI bug confirmed: `OuroWorkbenchApp.swift:7256` renders `bossReconstructEmpty` **unconditionally** (during search AND regardless of result), decoupled from the boss's actual reply (`bossCheckInAnswer`/`bossAppliedActions`).

## Things to retire / reword

- Per-tab cost badges + ⚡/💤 spend icons.
- The "Terminals in Home" concept and the second meaning of "workspace."
- Silent auto-spawn on reboot; `autoResume`-as-launch (reframe to "pre-ticked in the proposal").
- **AGENTS.md P0 "safe auto-resume where the underlying CLI supports it"** conflicts with "never auto-spawn." Reword to "propose-to-resume; restore the tab/representation, never auto-spawn the process."

## Open build-seams (for planning, not blockers)

1. **Storage shape**: exact split of structure vs runtime in `workspace-state.json`; the git-init/opt-in-remote mechanics; conflict handling on multi-machine sync.
2. **Migration**: what happens to the current malformed 4-entry state when the new model ships (new bring-back should supersede it).
3. **Confidence tiering rule**: precise definition of `·established` vs `·active before restart` vs `·recent` given incomplete record + contaminated recency.
4. **Workspace boundary on restore**: restore into persisted structure when present; boss *proposes* a grouping (editable) for net-new/unknown work.

## Recommended build sequence (operator may veto)

0. **Kill cost badges** — small, independent, immediate relief (decoupled from everything).
1. **Model + durable storage** — named workspaces/tabs, no Home, structure/runtime split, git-backable. The foundation everything else restores into.
2. **Required onboarding + returns-on-reset** — the gate that establishes the model.
3. **Propose-first bring-back** — the make-or-break; depends on (1).
4. **Boss naming intelligence** — name-by-work for workspaces + tabs.

Each ships as its own PR-scoped unit (per repo workflow: planning → doing → merging).
