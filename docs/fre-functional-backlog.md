# Ouro Workbench — make-it-work backlog (functionality audit, F1–F12)

> **Verdict (from `workbench-functionality-audit`, 62 agents / 4.47M tokens, 2026-06-21):**
> **"Not usable today. 3 P0s block first-run; a P1 tail makes the rest unreliable."**
>
> 10 capability auditors deep-traced real end-to-end flows (terminals, boss-connect,
> autonomy, recovery, MCP surface, agent lifecycle, ouro integration, persistence, error
> modes, the coverage-gap surfaces), ran the tests, then adversarial-verify → synthesize.

## Mandate + verification protocol

- **Mission:** make the product *actually functional and usable* — not polish. Core fully in
  scope (terminal/process model, recovery, security/anonymization, boss decision logic).
- **Autonomy:** autopilot-merge to main. Build new capabilities where a surface needs one.
  Don't flag; decide → build → verify → ship → merge. Best judgment + creativity + technical chops.
- **Verify bar (fully autonomous, NO computer-use this run — it wedges on a blocking dialog):**
  100% Core TDD (red→green) + independent cold-review subagent per PR + the MCP-binary
  JSON-RPC smokes (`scripts/smoke-mcp-*.sh`) + source-pin tests for App-target changes.
  **Queue every live drive-through / screenshot-verify item** into a batch the operator runs
  when present.
- **Merge:** per-unit (or tightly-coupled pair) PRs off `main`, cold-reviewed, **squash-merged
  to main** — public repo `ourostack/ouro-workbench`. (Push identity + commit-author hygiene are
  tracked operationally outside this repo.)
- **Relationship to the UX backlog (U7–U36 in `fre-ux-backlog.md`):** complementary, not
  duplicative. Those fixed *display honesty* (what the surface says); these fix the *underlying
  mechanism* (whether it works). Overlaps noted per-unit.

## Sequence (priority order)

| Phase | Units | Theme |
|-------|-------|-------|
| **P0 — first-run is broken** | F1, F2, F3 | A first-run user cannot get a working, safe boss at all |
| **P1 — unreliable tail** | F4, F5, F6, F7, F8, F9, F10, F11 | Works sometimes; loses data / lies / leaks / double-executes |
| **P2/P3 — folded** | F12 | Smaller degraded-mode + polish gaps |

---

## P0 — block first-run

### [F1] Cold-start agent creation is a silent dead end — credential dropped, no vault, dead bundle scans "ready"
**rank 1 · P0 · operator + boss · capability: Agent lifecycle**

**What breaks:** `ColdStartHatchRunner.runHeadless` (`ProviderConfigForm.swift:271-288`) ignores the
`ouro hatch` exit. Hatch throws (no headless vault to persist into), so the credential never
persists — yet the form dismisses as **success** and the bundle scan marks it **ready**. The user
"creates an agent," sees success, and has a dead, credential-less bundle.

**Fix:** honor the hatch exit code; add a vault create+unlock flow for the headless path; gate
"ready" on a post-hatch probe (the bundle actually has a working provider credential).

**Status:** ☐ not started

### [F2] False-green Connect — `ouro check` exit 0 on credential failure is recorded "This connection is working"
**rank 2 · P0 · operator + boss · capability: Boss setup + provider connection**

**What breaks:** readiness state is derived from `terminationStatus == 0`
(`OuroWorkbenchApp.swift:14665`). `ouro check` exits 0 even on a bitwarden-locked vault or a 401,
so readiness flips to **ready** and an **unauthenticated** boss is handed off. The historically
multi-week-blocking connect path *looks* fixed but green-lights a boss that can't actually run.

**Fix:** classify connection health from the **post-command provider probe**, not the exit code.

**Status:** ☐ not started

### [F3] Boss auto-advance kill-switch + per-friend trust are bypassed by the actions/MCP `sendInput` channel
**rank 3 · P0 · operator + boss · capability: Boss autonomy (safety)**

**What breaks:** `bossActionAuthorizer.authorize` (`BossWorkbenchActionAuthorizer.swift:74-99`)
checks only entry-trust + safety — **never the kill-switch or friend trust**. So with auto-advance
**OFF**, the boss still injects keystrokes via the MCP/actions `sendInput` path. The master
hands-off switch the operator relies on for trust does not actually stop the boss. (Security/trust hole.)

**Fix:** run `evaluateAutoAdvanceGate` **app-side** in `applyBossAction` before `sendInput`, so the
kill-switch + per-friend trust gate every injection channel, not just the auto-advance loop.

**Status:** ☐ not started

---

## P1 — unreliable tail

### [F4] Native session-id resume is dead code — recovery uses ambiguous `--continue`/`--last`, collapses multi-session repos
**rank 4 · P1 · operator + boss · capability: Reboot recovery**

**What breaks:** `terminalSessionId` is never written in production (`markStarted`,
`OuroWorkbenchApp.swift:17745` omits it), so recovery always falls back to `--continue`/`--last`;
two sessions in the same cwd collapse onto one. (Complements U7/U8, which fixed the recovery
*display*; this fixes the actual resume *mechanism*.)

**Fix:** populate `ProcessRun.terminalSessionId` at `markStarted` from the discovered/scanner id.

**Status:** ☐ not started

### [F5] Persistence silently destroys data — failed quarantine move mislabeled "preserved" then overwritten; dropped row re-saved without the row
**rank 5 · P1 · operator + boss · capability: Persistence / corruption**

**What breaks:** `quarantine()` uses `try? moveItem` (`WorkbenchStore.swift:94`) — claims
"preserved" on a *failed* move, then `save()` overwrites the original. And `WorkspaceState.init`
drops an undecodable row and **re-saves without it** (`:18124`), turning a transient decode error
into permanent data loss.

**Fix:** propagate the move failure (name the `stateURL`); surface "skipped" + write a `.salvage`
copy before the post-load `save()`.

**Status:** ☐ not started

### [F6] Existing-agent credential rotation is unimplemented — Connect on an existing agent always errors; no remove-agent path
**rank 6 · P1 · operator · capability: Credentials**

**What breaks:** `ProviderConfigSheet` for an *existing* agent short-circuits
(`OuroWorkbenchApp.swift:16837-16839`) — no headless sink, so rotating a credential always errors.
There is also no remove-agent path.

**Fix:** add an `ouro` non-interactive credential-set affordance (or a read-only state when it
can't), plus a remove-agent action.

**Status:** ☐ not started

### [F7] Headless clone reports success but leaves an unauthenticated non-running agent; watchdog timeout mis-reported as Git-remote failure
**rank 7 · P1 · operator + boss · capability: Agent lifecycle**

**What breaks:** `runHeadless` treats `ouro clone` exit 0 as full success, though a headless clone
only *prints manual next-steps*; a missing `agent.json` still returns success; the 120s watchdog
kill maps to "Check the Git remote" (wrong cause).

**Fix:** run a post-clone status/check probe; flag a missing `agent.json` as invalid; distinguish a
watchdog timeout from a remote error.

**Status:** ☐ not started

### [F8] Boss-loop robustness — daemon-down never trips Boss Watch backoff; `ProcessWatchdog` only SIGTERMs, so wedged remediations hang + leak grandchildren
**rank 8 · P1 · operator + boss · capability: Boss autonomy / degraded modes**

**What breaks:** `needsManualRecovery` returns early (`OuroWorkbenchApp.swift:15416`) without
bumping backoff (hot-loops a dead daemon). `ProcessWatchdog` (`ProcessWatchdog.swift:19-35`) only
`terminate()`s, relying on a blocked `waitUntilExit()`, so a wedged child hangs and its
grandchildren leak.

**Fix:** bump backoff on `needsManualRecovery`; make the watchdog terminate→grace→SIGKILL and
`killpg` the process group.

**Status:** ☐ not started

### [F9] No ouro version-floor / capability check — an older `ouro` silently strips ALL `workbench_*` tools while reading "reachable"
**rank 9 · P1 · operator + boss · capability: ouro daemon / CLI / bridge**

**What breaks:** `--workbench-mcp` is honored only on `alpha.660+`; an older `mcp-serve` ignores it;
`isReachable` + the registration snapshot trust `mcpStatus == .registered` and never verify
injection. So the boss reads "connected" with **zero** Workbench tools actually present.

**Fix:** add a post-bringup `tools/list` probe; gate readiness on a `workbench_*` tool actually
appearing.

**Status:** ☐ not started

### [F10] MCP tool surface lies — a tool omitted from the boss catalog (smoke RED); a dedup-dropped `request_action` acks a phantom id reading "unknown"; a newer-schema file blinds all read tools opaquely
**rank 10 · P1 · boss · capability: MCP tool surface**

**What breaks:** `bossTools` omits `workbench_report_bug` (the `smoke-mcp-tool-catalog.sh` smoke
FAILS; the doc-drift test passes as a tautology). `enqueue()` drops a duplicate but `requestAction()`
returns a *fresh* id that forever reads "unknown." `store.load` re-throws on `schemaVersion != 1`
with a `WorkbenchStoreError` lacking `LocalizedError`, so a newer file blinds every read tool
opaquely. (Complements U25, whose set-equality test didn't catch the post-U30 `report_bug` add.)

**Fix:** fix the catalog + gate the smoke in CI; return the existing `requestId` on dedup; add
`LocalizedError` + a typed "degraded read" payload.

**Status:** ☐ not started

### [F11] Terminal lifecycle + replay — deleted session leaks its screen+process forever; restart races quit-vs-reattach; retried/crashed actions double-execute launch/createSession/sendInput
**rank 11 · P1 · operator + boss · capability: Terminal lifecycle / boss autonomy**

**What breaks:** delete/archive (`OuroWorkbenchApp.swift:16408,16347`) never quit `ouro-wb`, leaking
the screen + process. `start()` races an async quit vs an immediate `-D -RR` on the same socket.
Retry/crash replay bypass dedup (the `sendInput` guard is keyed on the *current* prompt), so a
launch/createSession/sendInput can **double-execute**.

**Fix:** quit screen on delete/archive + a startup reaper; await the quit before `-D -RR`; persist
applied-requestIds and count `processing/` in dedup.

**Status:** ☐ not started

---

## P2 / P3 — folded

### [F12] Smaller degraded-mode + polish gaps (folded)
**rank 12 · P2/P3 · operator + boss · capability: persistence / boss + terminal surfaces / recovery**

- save() failure deletes `processing/` so `action_result` lies "unknown."
- a missing `screen` binary dies as "exited 127" with no signal; Copilot dead-ends despite the CLI flags.
- un-emitted boss decisions stay un-triaged; boss prose has no history (overwritten).
- **P3 nits:** reattach drops scrollback (`-h 0`); respawn passes the prompt as a bare positional;
  proposal-id filenames can collide.

**Fix:** don't delete `processing/` on save failure; preflight `screen` + add a copilot sink;
reconcile waiting sessions + persist boss prose; fix reattach scrollback, respawn delivery, and
proposal-id filenames.

**Status:** ☐ not started

---

## Progress log

_(append one line per landed unit: `- DATE Fn ✅ (PR #NNN, main <sha>). one-line.`)_
