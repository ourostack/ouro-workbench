# F12b — terminal/proposal polish (gaps 4 + 6 of the F12 fold)

Status: done
Execution Mode: direct
Branch: fix/f12b-terminal-proposal-polish (off F12a-merged main f12d7eb)
Spec: /tmp/f12-design-spec.md (GAP 4 + GAP 6 sections)

Both gaps are pure-Core nits. NO push/PR/merge. Strict TDD (red→green per gap).
Ignore untracked leftovers (SerpentGuide.ouro/, *-doing-*.md); git add only changed files.

## Gap 4 — reattach drops scrollback (`-h 0`)
`PersistentTerminalSession.attachOrCreateArguments` (CommandPlanner.swift:171) hardcodes
`"-h", "0"` → screen scrollback history = 0 lines, so on `-D -RR` reattach the operator
sees an empty buffer. Fix: `"-h", "0"` → `"-h", "10000"` (conventional non-zero default).
- ✅ U4a (test/red): updated CommandPlannerTests pin to `"-h", "10000"`; added
  `testReattachPreservesScrollback` asserting `-h` immediately followed by a non-zero number.
- ✅ U4b (impl/green): changed the one line in CommandPlanner.swift (-h 0 → -h 10000).

Note: only ONE `-h 0` pin exists in tests (CommandPlannerTests.swift:34) — the planner
test and the launchInvocation assertion are the SAME block. No scenario-matrix pin.

## Gap 6 — proposal-id filename collisions
`AgentProposalQueue.fileSafe(_:)` (AgentProposalQueue.swift:104) maps every non-alphanumeric
scalar → `_`, so distinct ids (`recover-1`, `recover.1`, `recover_1`, `recover/1`) all collapse
to one basename `recover_1` — deterministic but NOT injective. Boss polls by ORIGINAL id, can
read back ANOTHER proposal's result; a colliding re-enqueue silently overwrites a different pending.
Fix: injective basename = readable prefix (.prefix(40)) + "-" + SHA256 hex prefix of the FULL id
(reuse the CryptoKit SHA256 idiom already in MCPDispatchDedup.swift). Deterministic, directory-safe,
injective, and preserves same-id-replaces-same-file (no random suffix).
- ✅ U6a (test/red): added `testDistinctIdsThatCollapseToSameBasenameDoNotCollide` and
  `testSameIdReEnqueueStillReplaces`.
- ✅ U6b (impl/green): rewrote `fileSafe` to readable-prefix(.prefix(40)) + "-" +
  SHA-256 hex prefix (16 bytes) of the FULL id, via CryptoKit.

### Migration note (gap 6)
Changing `fileSafe` changes on-disk basenames, so a proposal written under the OLD scheme
won't be found under the NEW scheme — an in-flight-across-upgrade proposal is DROPPED
(not corrupted). Low blast radius: proposals are short-lived + re-proposable. No migration
code needed.

## Verification gates
- `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green.
- `Scripts/check-coverage.sh` PASS — Core 100% line+region, no new allowlist.
- Strict build clean.

## Completion Criteria
- [x] Gap 4: `-h 10000`, both the changed line + the test pin updated, scrollback test green.
- [x] Gap 6: injective `fileSafe`; collision test proves distinctness; same-id-replace regression green.
- [x] All gates pass.

## Progress log
- 2026-06-22 02:26 doing-doc created; spec + source read; one `-h 0` pin confirmed (not two);
  CryptoKit SHA256 idiom available in MCPDispatchDedup.swift for the injective hash.
- 2026-06-22 02:29 Gap 4 complete: U4a red → U4b (1f67a8c) green.
  -h 0 → -h 10000 in CommandPlanner.swift; CommandPlannerTests pin updated +
  testReattachPreservesScrollback added. Both green.
- 2026-06-22 02:31 Gap 6 complete: U6a red → U6b (fab2c64) green. Injective fileSafe
  via SHA-256 suffix; collision test + same-id-replace regression both green; all 16
  AgentProposalQueueTests pass.
- 2026-06-22 02:35 Gates: strict suite 2409 tests / 0 fail; check-coverage.sh PASS
  (Core 100% line+region, no new allowlist); strict release build clean. Status: done.
