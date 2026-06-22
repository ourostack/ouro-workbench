# Doing: F11b — replay double-execute prevention (action layer)

Execution Mode: direct
Branch: fix/f11b-replay-dedup (off F11a-merged main 3a49abf)
Spec: /tmp/f11-design-spec.md (build ONLY F11b = PR2, replay-dedup action layer)
Status: in-progress

## Disambiguation
This is the DISJOINT ACTION layer (persisted applied-requestIds + `processing/` count),
NOT the JSON-RPC `MCPRequestDedupLedger` from F10a. Durable key is
`WorkbenchActionRequest.id` (already keys the `processing/` filename).

## ORDERING CONTRACT (THE key invariant)
side-effect → markApplied (durable) → confirmApplied (delete processing) → clearApplied (delete marker)

markApplied must land on the MAIN actor SYNCHRONOUSLY, AFTER the synchronous
`applyBossAction` for each request and BEFORE the detached confirm loop. If a fold
removes markApplied or orders it AFTER confirm, the crash window reopens → double-execute.

## Units

### U1 — Core seam `ReplayDedupDecider.swift` (pure, 100%) ✅
- What: `enum ReplayDecision { apply; skipAlreadyApplied }`;
  `decide(requestId: UUID, appliedRequestIds: Set<UUID>) -> ReplayDecision`
  (contains → skip, else apply).
- Tests: `ReplayDedupDeciderTests` 3 arms (in-set→skip, not-in→apply, empty→apply).
- Acceptance: red→green; 100% line+region on new file.

### U2 — Extend `WorkbenchActionRequestQueue.swift` (applied ledger + processing dedup) ✅
- What:
  - `appliedDirectoryURL` (= directoryURL/applied/, MARKER-DIR like processing/, set in init)
  - `markApplied(_ requestId:)` zero-byte `<id>.json` marker, atomic, idempotent
  - `appliedRequestIds() -> Set<UUID>` (list applied/, parse UUIDs, best-effort [])
  - `clearApplied(_ requestId:)` (remove marker, idempotent)
  - `hasProcessingDuplicate(of:)` (fingerprint-scan processing/, skip ids in applied/),
    OR'd into the enqueue gate
- Tests (extend `WorkbenchActionRequestQueueTests`): markApplied→contains+idempotent;
  clearApplied removes+absent-noop; CRASH-MID-PROCESSING (enqueue→drain→markApplied →
  recoverUnconfirmed STILL returns it AND appliedRequestIds contains it → decider skips);
  appliedRequestIds [] when applied/ absent; processing/ counted (enqueue→drain→twin dropped);
  twin whose id in applied/ NOT a processing-dup; convenience init sets appliedDirectoryURL.
- Acceptance: red→green; Core 100%.

### U3 — App wiring + `ReplayDedupWiringTests` ⬜
- What:
  - skip-on-replay at applyBossAction TOP (after validateForQueueing, BEFORE first switch):
    if requestId != nil → ReplayDedupDecider().decide(...); on .skipAlreadyApplied →
    finishBossAction("Skipped <kind>: already applied (replay)"). UNIVERSAL.
  - markApplied AFTER applyBossAction, BEFORE the detached confirm loop, MAIN actor SYNC.
  - detached confirm loop: confirmApplied(id) THEN clearApplied(id).
  - startup sweep after recoverUnconfirmedExternalActionRequests: clearApplied any marker
    whose processing/ file no longer exists.
  - LEAVE isNewDecision/bossActionLivePrompt sendInput guard UNCHANGED.
- Tests: source-pins (decider consulted + early return AFTER validate BEFORE first switch;
  markApplied AFTER apply BEFORE detached confirm [by index]; detached loop calls BOTH
  confirmApplied + clearApplied; isNewDecision guard UNCHANGED; startup sweep wired).
- Acceptance: red→green.

### U4 — Verify ⬜
- `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green
- `Scripts/check-coverage.sh` PASS, Core 100% line+region, no new allowlist
- Strict build clean

## Completion Criteria
- [x] ReplayDedupDecider seam exists, pure, 3-arm tested (100% verified in U4)
- [x] applied/ marker-dir ledger (markApplied/appliedRequestIds/clearApplied) + hasProcessingDuplicate
- [x] enqueue gate ORs in processing-dup; applied ids excluded from processing-dup
- [x] crash-mid-processing test proves replay is skipped
- [ ] App: universal skip-on-replay at applyBossAction top
- [ ] App: markApplied ordering pinned (after apply, before detached confirm)
- [ ] App: detached loop confirmApplied + clearApplied; startup orphan sweep wired
- [ ] isNewDecision sendInput guard unchanged
- [ ] swift test (strict) green; coverage PASS; strict build clean

## Progress Log
- 2026-06-21 23:11 U1 complete: ReplayDedupDecider seam (enum ReplayDecision {apply; skipAlreadyApplied}, id-keyed decide). Red (type missing) → green, 3 arms pass. Commit 6874e3a.
- 2026-06-21 23:18 U2 complete: applied/ marker-dir ledger (markApplied/appliedRequestIds/clearApplied) + hasProcessingDuplicate OR'd into enqueue (applied ids excluded). Red (members missing) → green, 30 queue tests pass incl. crash-mid-processing (recoverUnconfirmed STILL returns + appliedRequestIds contains → decider .skipAlreadyApplied). Core 100% line+region, no new allowlist. Commit 959bec1.
