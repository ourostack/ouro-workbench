# Doing: nav-checkin-batch (four functional fixes)

- **Branch:** `fix/nav-checkin-batch` (off `main` @ dd852d5)
- **Execution Mode:** direct
- **Worktree:** `/Users/microsoft/code/ouro-workbench/.claude/worktrees/agent-a72e7deca3a30407d`
- **Status:** done
- **Constraint:** strict TDD; `swift build`/`swift test` with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`; `Scripts/check-coverage.sh` 100% line+region on new Core logic; allowlist unchanged at 2. DO NOT merge/PR.

## Units

### ✅ Unit 1 — FIX 1 (HIGH, destructive): focus mode acts on the WRONG terminal — DONE @ 8dbec6d
- **What:** `focusTerminal()` sets only `terminalFocusEntryID`; menu chords (`.stopSelected`/`.redraw`) route through `activeEntry`, which ignores `terminalFocusEntry`. So ⌘./⌘L can act on (and KILL) a different terminal than the one on screen.
- **Approach:** (b) — extract the active-entry decision into a pure Core seam `ActiveEntryResolver`; focus-mode wins. `activeEntry` consumes the seam. (Robust: focus mode authoritatively defines the active terminal.)
- **Output:** `Sources/OuroWorkbenchCore/ActiveEntryResolver.swift` (pure resolver: given selectedEntryID, terminalFocusEntryID, split/secondary-pane state → active id; focus wins). `activeEntry` in App rewired through it.
- **Acceptance:** focus on B while A is sidebar-selected → active == B. Focus OFF → active stays sidebar selection (inverse-bug guard). Secondary-pane path preserved when focus OFF.
- **Tests:** `ActiveEntryResolverTests` (exhaustive pure) + source-pin in `NavCheckInWiringTests`.

### ✅ Unit 2 — FIX 2 (MED): manual Check-In failure falsely promises a retry — DONE @ 3aee47b
- **What:** With Boss Watch OFF, a failed manual Check In shows "Workbench will try again shortly" / "keeps trying…" but nothing retries (only `runBossWatchLoop`, gated on `bossWatchIsEnabled`, retries).
- **Approach:** pure Core seam `BossCheckInFailureCopy.copy(failureCount:bossWatchIsEnabled:)` → returns honest copy. Watch OFF → "Check-In didn't go through. Press Check In to try again." Watch ON → existing "will try again"/"keeps trying" copy.
- **Output:** new copy seam in Core (alongside `BossWatchBackoff`); catch-path `bossCheckInAnswer` + the persistent banner (≥2 failures) wired through it.
- **Acceptance:** watch OFF → no false "will try again" promise. watch ON → truthful "will try again" preserved (inverse-bug guard).
- **Tests:** copy-selector pure tests + source-pin.

### ✅ Unit 3 — FIX 3 (LOW): ⌘J on empty attention queue silently no-ops — DONE @ 5f71845
- **What:** `case .jumpToAttention: _ = model.jumpToNextAttentionSession()` discards the `false` return; nothing happens, no feedback.
- **Approach:** when the jump returns `false`, surface a brief transient status via the app's existing transient mechanism (no new infra). Copy reuses the existing inbox-zero phrasing "Nothing needs you right now."
- **Output:** the ⌘J dispatch handles the `false` path.
- **Acceptance:** empty queue + ⌘J → transient status set. Non-empty → jumps, no status noise (inverse-bug guard).
- **Tests:** source-pin (the false-path sets a status).

### ✅ Unit 4 — FIX 4 (LOW): Check-In on unreachable-but-configured boss dumps into full onboarding — DONE @ 65be074
- **What:** `checkInAvailability` collapses "no boss" and "boss unusable" both into `.needsBoss` → both route to full onboarding pick.
- **Approach:** split `CheckInAvailability` into `.noBoss` (→ onboarding) vs `.bossUnreachable(name)` (→ reconnect/honest message). Wire `attemptCheckIn` to route each appropriately.
- **Output:** `CheckInAvailability` enum split + `resolve` updated; `attemptCheckIn` + `helpText` updated; existing `CheckInAvailabilityTests` updated.
- **Acceptance:** configured-but-unreachable → `.bossUnreachable`; no-boss → `.noBoss`; usable → `.ready` (inverse-bug guard: a usable boss is never `.bossUnreachable`).
- **Tests:** pure split tests + source-pin (Check-In routes `.bossUnreachable` to reconnect not onboarding).

## Completion Criteria
- [x] FIX 1: pure resolver + focus-mode-wins; normal case unchanged
- [x] FIX 2: honest copy when watch OFF; truthful copy when ON
- [x] FIX 3: ⌘J empty-queue sets transient status (reused infra)
- [x] FIX 4: `.noBoss` vs `.bossUnreachable` split, wired
- [x] `swift build` + `swift test` clean (warnings-as-errors, strict concurrency)
- [x] `Scripts/check-coverage.sh` 100% line+region; allowlist still 2
- [x] 4 commits, pushed; NOT merged

## Progress Log
- 2026-06-23 09:36 doing doc created; branch off main @ dd852d5; baseline build clean. Symbols re-located (line numbers were stale).
- 2026-06-23 09:53 Unit 1 (FIX 1) complete @ 8dbec6d: ActiveEntryResolver pure seam (approach b — focus-mode wins authoritatively); activeEntry folds through it; 9 resolver tests + 4 wiring pins; coverage 100% (allowlist still 2); build clean (warnings-as-errors + strict concurrency).
- 2026-06-23 09:59 Unit 2 (FIX 2) complete @ 3aee47b: BossCheckInFailureCopy seam (failureLine + persistentBanner, branched on bossWatchIsEnabled); catch-path transient line + persistent banner wired through it. Note: persistent banner is watch-gated (bossWatchLastError only set when watch ON) — wired the seam defensively anyway. 8 copy tests + 6 wiring pins; coverage 100% (allowlist 2).
- 2026-06-23 10:05 Unit 3 (FIX 3) complete @ 5f71845: ⌘J dispatch consumes the bool; false (empty-queue) path sets errorMessage = "Nothing needs you right now." (reused existing one-shot message channel — precedent: "X is not running" no-op feedback). Empty-queue decision already pure in jumpToNextAttentionSession; App-side wiring pin added. No Core coverage delta; gate still PASS.
- 2026-06-23 10:13 Unit 4 (FIX 4) complete @ 65be074: CheckInAvailability split .needsBoss → .noBoss (→ presentOnboarding) + .bossUnreachable(name) (→ Harness Status reconnect/repair sheet, which states "Boss X is not reachable" honestly). resolve trims+carries the name; added routesToReconnect / unreachableBossName accessors + honest helpText. attemptCheckIn routes both distinctly. CheckInAvailabilityTests rewritten for the split; 2 wiring pins added. Coverage 100% (allowlist 2).
- 2026-06-23 10:21 All gates passed. Full suite 2627 tests, 0 failures (1 pre-existing skip), with -warnings-as-errors -strict-concurrency=complete. Clean build. check-coverage.sh: 144/146 files 100% line+region, allowlist unchanged at 2. Tree clean; no SerpentGuide.ouro staged. NOT merged — parent cold-reviews.
