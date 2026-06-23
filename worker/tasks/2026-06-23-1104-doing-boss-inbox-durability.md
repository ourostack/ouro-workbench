# Doing: Boss-Inbox Durability Fixes

- **Created:** 2026-06-23 11:04
- **Branch:** `fix/boss-inbox-durability` (off `main` @ dd852d5)
- **Worktree:** `/Users/microsoft/code/ouro-workbench/.claude/worktrees/agent-aa589966d07f4e056`
- **Execution Mode:** direct
- **Scope:** `Sources/OuroWorkbenchCore/BossInboxDecision.swift` + `Tests/OuroWorkbenchCoreTests/BossInboxDecisionTests.swift`
- **Status:** in-progress
- **Constraints:** strict TDD; commit per fix; push; DO NOT merge/PR; allowlist unchanged at 2; warnings-as-errors + strict-concurrency=complete; Core coverage 100%.

## Context

Three correctness bugs in how the boss's decisions/escalations are deduped + retained:

1. **FIX 1 (HIGH)** — `recordDecision` caps `decisionLog` at 200 and `removeLast`s the
   oldest unconditionally. An OPEN, un-acknowledged escalation can be silently evicted
   → the session is stuck with nothing surfacing it.
2. **FIX 2 (MED)** — `isNewDecision` compares only `decisionLog.first(where: entryId==)`
   (the LATEST row). Interleaved A→B→A treats A as NEW → boss re-sends input it already sent.
3. **FIX 3 (MED)** — nil-`entryId` decisions never dedupe in `openInbox` (`guard let entryId
   else { return true }`) → repeated ticks pile up N identical open items.

## Cap-eviction policy (FIX 1)

`recordDecision` inserts newest-first, then trims to cap via a **pure** function
`Self.trimmedToCap(_:cap:now:)`. Trimming evicts **non-open** (resolved / acknowledged /
audit-only) entries oldest-first; an entry that `openInbox` would surface (`needsHuman &&
isOpenForTriage`) is NEVER evicted by the cap. If after evicting every non-open entry the
log is still over cap (all-open boundary), the open entries are kept — bounded in practice
by the number of live sessions, documented as the accepted ceiling (the inverse-bug guard:
we still evict resolved-first and never grow by unbounded *non-open* churn).

## Dedup window + nil-key scheme (FIX 2 + FIX 3)

- **Stable key.** `BossInboxDecision.dedupKey` = the entry's `UUID` string when present;
  otherwise a stable pseudo-key `"nil:" + sessionName + "\u{1F}" + prompt + "\u{1F}" + kind`.
  Identical nil-entry decisions collapse; different prompt OR kind OR sessionName stays distinct.
- **FIX 2 window.** `isNewDecision` scans the most-recent `dedupScanWindow` (= 50) decisions
  matching the same dedup key for a `(prompt, kind)` match — not just `.first`. Interleaved
  A→B→A finds A's row in the window → not new.
- **FIX 3 collapse.** `openInbox` collapses by `dedupKey` (covers both real entries and the
  stable nil key), so repeated nil-entry ticks show once; distinct nil-entry decisions stay separate.

## Units

- ✅ **Unit 1 (FIX 1):** cap never evicts an open escalation. Pure `trimmedToCap`; tests at the boundary (open+resolved mix, all-open). Commit.
- ✅ **Unit 2 (FIX 2):** windowed dedup. `dedupGroupKey` + windowed `isNewDecision`; interleaved A→B→A test. Commit.
- ⬜ **Unit 3 (FIX 3):** nil-entry stable-key collapse in `openInbox`. Tests: identical nil collapse to one; distinct nil stay separate. Commit.

## Completion Criteria

- [x] FIX 1: open escalation never evicted by cap; resolved evicted first; cap bounded.
- [x] FIX 2: interleaved A→B→A does NOT re-fire A; distinct (prompt/kind) still new.
- [ ] FIX 3: identical nil-entry decisions collapse to one; distinct nil-entry stay separate.
- [ ] `swift build` + `swift test` with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`, 0 failures.
- [ ] `Scripts/check-coverage.sh` Core 100% line+region; allowlist unchanged at 2.
- [ ] 3 commits (one per fix), pushed; NOT merged/PR'd.

## Progress Log

- 2026-06-23 11:11 Unit 1 (FIX 1) complete @933a57d: pure `trimmedToCap` evicts resolved/audit-only oldest-first, never an open escalation; at the all-open boundary the log exceeds the cap rather than drop a waiting session. 4 new cap tests + updated `testRecordDecisionTrimsToCap` (now resolved-row based). Strict build clean, coverage 100%, allowlist at 2. Pushed.
- 2026-06-23 11:23 Unit 2 (FIX 2) complete @f1572f1: windowed `isNewDecision` scans the recent `dedupScanWindow` (50) in the same `dedupGroupKey` group; interleaved A→B→A no longer re-fires A. Shared pure `dedupGroupKey` (real entryId, else stable (sessionName,prompt,kind) pseudo-key) introduced for FIX 2 + FIX 3. Red proven by reverting to `.first` (3 failures), then restored. 5 new dedup tests (incl. nil-name path). Full suite 2603 pass; coverage 100%; allowlist at 2.
