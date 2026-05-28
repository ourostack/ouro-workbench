# Preference-Driven Inbox — Design & User Stories

Status: **draft for review** (no implementation yet).

## 1. Problem & vision

Workbench can now *detect* when a session needs the human (`waitingOnHuman`),
*surface* it (sidebar dot, menubar, Boss Watch, notifications), and let the
operator *jump* to it (`⌘J`). The next step closes the loop: let the **boss
agent advance a waiting session on the operator's behalf** — answer the prompt,
approve or decline the command, pick the menu option — so the operator only has
to deal with the things that genuinely need them.

The decision of *what to do* must **not** be a static allow-list of "safe
commands". It is **preference-driven**: the boss consults the relevant
**friend's notes and preferences** and asks "what would this friend want me to
do here?" The same waiting prompt may be auto-approved for one friend and
escalated for another, because their preferences differ.

This makes the boss a delegate that learns and honors each friend's working
style — not a rules engine.

## 2. What already exists (so we build on it, not around it)

**Ouro friend model** (in the boss's brain, `ourostack/ouroboros`
`src/mind/friends/types.ts`) — the boss already keeps, per friend:

- `kind`: `human` | `agent`
- `trustLevel`: `family` | `friend` | `acquaintance` | `stranger`
  (`family` + `friend` are the trusted levels)
- `toolPreferences: Record<string, string>` — preferences keyed by integration
- `notes: Record<string, {value, savedAt}>` — timestamped general knowledge
- the boss can already *gather and judge* relevant kept-notes
  (`gatherKeptNotesCandidates`, `createKeptNotesJudge`)

**Workbench model** (`ourostack/ouro-workbench`):

- `AttentionState.waitingOnHuman` is auto-detected from output, and
  `.needsHuman` drives `⌘J` / Boss Watch / notifications.
- `BossWorkbenchAction` already supports `sendInput` (text + appendNewline),
  `recover`, `terminate`, etc., queued via `workbench_request_action`.
- `BossWorkbenchActionAuthorizer` already trust-gates every boss action against
  the session's `ProcessTrust` (`trusted` / `untrusted`).
- Every applied/skipped action is written to a durable `actionLog` with source,
  action, target, result, timestamp.

**The gap:** Workbench has no notion of *which friend a session belongs to*, the
boss isn't handed the waiting prompt + that friend's identity, and there's no
preference-driven decision step before `sendInput` — today a boss action is
gated only by a binary trusted/untrusted flag.

## 3. Conceptual model & terms

- **Session friend**: the friend a Workbench session acts for / as — a `human`
  **or** an `agent`, first-class and symmetric (today it's almost always the
  human operator; the model is built so a delegated agent friend works the same
  way without rework). A session has exactly one friend (or "unassigned").
- **Friend preference**: structured + freeform guidance the boss holds about a
  friend — e.g. *"auto-approve file edits and test runs in my repos; always ask
  before force-push, `rm -rf`, anything touching prod or secrets; never accept
  ToS on my behalf."* Lives in the friend's `toolPreferences` + `notes`.
- **Advance**: the boss responding to a waiting prompt — `sendInput` of the
  chosen answer (e.g. selecting "1. Yes", typing `y`, pressing enter).
- **Decision**: for a given waiting prompt + friend, one of
  `auto-advance` (boss answers now), `escalate` (ask the human), or `hold`
  (do nothing; leave it waiting).
- **Confidence**: how sure the boss is the friend would want this exact answer.
  Low confidence always degrades `auto-advance` → `escalate`.

## 4. Principles (safety rails)

1. **Preference-driven, not allow-list.** The friend's notes are the policy. No
   global "these commands are safe" table.
2. **Default to escalate.** Absent a clear, confident preference match, the boss
   asks the human. A missed auto-advance is cheap; a wrong one is not.
3. **Destructive/irreversible always escalates** regardless of preference,
   unless the friend's note *explicitly* pre-authorizes that exact class
   (`rm -rf`, force-push, `git reset --hard`, prod deploys, payments, accepting
   agreements, granting access, anything matching the existing prohibited/
   explicit-permission safety lists).
4. **Trust-gated.** Auto-advance requires the session `trust == trusted` **and**
   a trusted friend (`family`/`friend`). `acquaintance`/`stranger` never
   auto-advance.
5. **Auditable & reversible posture.** Every decision (incl. "escalated" and
   "held") is logged with the friend, the prompt, the preference cited, and the
   answer sent. The operator can see exactly why the boss did what it did.
6. **Human is sovereign.** A global kill-switch ("never auto-advance"), per-
   session opt-out, and the ability to undo/override are first-class.
7. **The boss owns the judgment; Workbench owns the rails.** Workbench supplies
   the prompt, the friend identity, the trust/destructiveness gate, and the
   audited action channel. The boss's friend-notes reasoning decides.

## 5. User stories

### A. Binding a session to a friend
1. As the operator, I can set a session's (or a group's) **friend** so the boss
   knows whose preferences apply, and sessions inherit their group's friend by
   default.
2. As the operator, I want a sensible default — a new session on my own machine
   is assigned to **me** (a `family` friend) unless I say otherwise — so I don't
   have to configure every terminal.
3. As the boss, when a session has no assigned friend, I treat it as
   **unassigned** and never auto-advance it; I escalate instead.
4. As the operator, I can see each session's friend in the sidebar/inspector so
   it's obvious whose policy governs it.

### B. Preference-driven advancing (the core)
5. As the boss, when a session is `waitingOnHuman`, I read the waiting **prompt**
   (the same tail the detector saw), identify the **friend**, and consult that
   friend's **preferences + notes** before deciding.
6. As the boss, if the friend's notes clearly cover this prompt (e.g. "auto-
   approve test runs"), I **auto-advance** with the answer the friend would give
   and record which preference I relied on.
7. As the boss, if the friend has *no* relevant preference, I **escalate** — I
   surface the prompt to the human with my best-guess suggestion, but I do not
   act.
8. As the boss, if my confidence that the friend wants this specific answer is
   low, I **downgrade to escalate** even when a preference seems to apply.
9. As the boss, two different friends with two different preferences on the same
   kind of prompt get **different** outcomes — proving it's preference-driven,
   not a shared allow-list.
10. As the operator, when the boss auto-advances, the session's attention clears
    automatically and I see a log entry: *friend, prompt, preference cited,
    answer sent* — so I can audit after the fact.

### C. Escalation & human control
11. As the operator, I get a single, prioritized **inbox** of escalations
    ("3 sessions need a decision") rather than per-session noise, and `⌘J`-style
    navigation walks me through them.
12. As the operator, for an escalated prompt I can **approve the boss's
    suggestion in one action**, answer differently, or tell the boss to hold.
13. As the operator, I can flip a global **"never auto-advance"** kill-switch and
    a per-session **"don't auto-advance this one"** so the boss only ever
    escalates when I want hands-off-by-default.
14. As the operator, I can **undo / override** a boss auto-advance shortly after
    (and the boss notes the correction), so a wrong call is recoverable.

### D. Destructive & sensitive prompts
15. As the operator, I am **always** asked before the boss answers a destructive
    or irreversible prompt (`rm -rf`, force-push, hard reset, deploy, payment,
    accept-agreement, grant-access) — even if a preference seems to allow it —
    unless my note *explicitly names that class* as pre-authorized.
16. As the operator, prompts that touch **secrets/credentials** (passphrase,
    token, password) are never auto-answered by the boss; they always escalate
    to me (consistent with Workbench's existing credential rules).

### E. Learning & notes
17. As the operator, when I answer an escalation, I can optionally tell the boss
    **"remember this for next time"**, which updates the friend's preference
    notes so the boss can auto-advance the same situation later.
18. As the boss, when the operator overrides my auto-advance, I **record the
    correction** against the friend so I don't repeat it.

### F. Transparency & trust
19. As the operator, the boss's reasoning ("auto-advanced because *Ari's note:
    'test runs are fine'*") is visible in the action log and the boss pane.
20. As an inner agent (Claude/Codex) running in a session, my `agent-context.md`
    explains that a boss may advance my prompts on the operator's behalf and how
    to mark a prompt as human-only — so I'm not surprised by input I didn't get
    from a person.

### G. Edge cases
21. As the boss, if the prompt changes or the session produces new output while
    I'm deciding, I **abort** the stale decision (the detector already reverts
    `waiting → active` on resume).
22. As the boss, I never auto-advance the **same prompt twice** (idempotent on
    `(session, prompt-hash)`) so a missed-revert can't double-send input.
23. As the operator, if the boss is unreachable/paused (Boss Watch off), nothing
    auto-advances — sessions simply stay in my inbox.

### H. Agent-friend collaboration (forward-looking; humans first in practice)
24. As an **agent friend**, I can be the friend a session belongs to, so when my
    delegated work hits a prompt the boss advances it per *my* preferences and
    trust — not the operator's — exactly as it would for a human friend.
25. As the boss, I apply the **same** preference-driven gate to agent friends as
    to humans: an `agent` friend's `trustLevel` gates auto-advance identically,
    so an `acquaintance`/`stranger` agent's session never auto-advances.
26. As the boss, when an agent friend exposes **structured** advancing
    preferences (machine-readable) alongside freeform notes, I prefer the
    structured preference — agents can state policy precisely.
27. As the operator, I can tell at a glance whether a session's friend is **me**,
    another human, or an **agent**, and an agent-owned session is visually
    distinct so I never mistake autonomous agent work for my own.
28. As the operator, when the boss advances an agent-friend's session, the audit
    log names the **agent friend** as the policy source (and the delegation it
    came from, when applicable) so accountability is clear across the collab
    boundary.
29. As the boss, an escalation on an agent-friend's session routes to the right
    decider — to the operator when it's local, or **back to the agent friend
    over a2a** when that friend owns the decision (future channel).

## 6. Trust gate (combining the two trust systems)

Auto-advance is permitted **only** when **all** hold:

- session `ProcessTrust == .trusted` (Workbench session trust), **and**
- friend `trustLevel ∈ {family, friend}` (Ouro friend trust), **and**
- the prompt is **not** destructive/sensitive (or the friend note explicitly
  pre-authorizes that class), **and**
- the boss's confidence ≥ threshold, **and**
- neither the global kill-switch nor the per-session opt-out is set.

Otherwise → **escalate** (or **hold** if Boss Watch is off).

## 7. Open questions for Ari

- **Friend identity source of truth.** Should Workbench store a `friendId` per
  session/group, or should the boss infer the friend from the working dir /
  who launched it? (Proposal: Workbench stores an optional `friendId`; default
  the operator; boss may refine.)
- **Default posture.** Out of the box, should the boss *auto-advance where
  preferences allow*, or *escalate-only until I opt into auto-advance per friend*?
  (Proposal: escalate-only by default; opt into auto-advance explicitly — safest
  start, matches "human is sovereign".)
- **Where the decision runs.** Confirm the boss makes the call via its own
  kept-notes/friend reasoning (Workbench just hands it prompt+friend+gate),
  rather than Workbench reimplementing preference matching. (Proposal: yes.)
- **Preference authoring.** Do we add a Workbench affordance to edit a friend's
  advancing preferences, or keep that purely in the boss's notes tools?
  (Proposal: phase 2 — start by consuming notes the boss already has.)

## 8. Phased implementation (after sign-off)

- **Phase 0 — identity:** add optional `friendId` (+ resolved friend name/kind/
  trust) to sessions/groups; default the operator; show it in the UI. Pure
  schema + UI, no behavior change.
- **Phase 1 — escalate-only inbox:** when a session is `waitingOnHuman`, the boss
  receives the prompt + friend + gate and produces a *suggestion*; Workbench
  shows a prioritized escalation inbox with one-tap approve/answer/hold. No
  auto-advance yet. Full audit.
- **Phase 2 — opt-in auto-advance:** per-friend opt-in lets the boss auto-advance
  when preferences clearly apply, behind the §6 gate, with kill-switch, undo, and
  idempotency. Destructive/secret prompts always escalate.
- **Phase 3 — learning:** "remember this" updates friend preferences; overrides
  record corrections.

Each phase is independently shippable and safe; we never enable auto-advance
before the escalate-only loop and the audit trail are proven.

**On agent friends:** the friend model (`kind: human | agent`, per-friend trust
and preferences) is agent-ready from Phase 0, so cluster H needs no separate
schema — but behavior is validated with human friends first (that's the real
traffic today). Agent-specific surfaces (structured preferences in §26, a2a
escalation routing in §29) are deferred until there's an agent friend actually
driving a session; we build the rails now and don't speculatively wire the
agent-only paths.
