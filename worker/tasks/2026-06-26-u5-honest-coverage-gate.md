# Doing: U5 — Honest per-file-100% coverage gate on the OuroWorkbench view layer

**Status**: READY_FOR_EXECUTION
**Execution Mode**: spawn
**Created**: 2026-06-26 09:11
**Planning**: (none — converted directly from the operator's firm-decision brief; campaign planning lives in the ANNEAL journal)
**Campaign journal**: ../2026-06-24-anneal-visual-testing.md
**Artifacts**: ./2026-06-26-u5-honest-coverage-gate/

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (interactive)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default)

**Chosen: spawn.** Operator present but trusts the plan ("fully autonomous"). Each PR-unit is independently
reviewable; a fresh unbiased sub-agent review gate runs before READY (see Unit R). Units are SERIAL (each
builds on the prior); spawn-per-unit keeps each PR's context clean and lets the review gate run on a fresh
agent that did not author the code.

## Objective

Make the OuroWorkbench view layer (`Sources/OuroWorkbenchAppViews/`) honestly per-file-100% line+region
covered and GATED by `scripts/check-coverage.sh`, by (1) splitting `WorkbenchViewModel` out of the
21,444-line `WorkbenchViewsAndModel.swift` into its own file so a real per-file gate is possible, (2)
closing the MEASURED post-split views residual (content-pinned, mutation-verified snapshots) instead of
allowlisting it, and (3) wiring the gate with an HONEST minimal allowlist sized to ONLY the genuinely-
untestable carves (K1). The ANNEAL view-snapshot campaign (C0–C11, 297 refs, energy-0) reached energy-0 on
the SNAPSHOT-MUTATION rubric (every view "exercised") but never added the views file to COVERAGE_DIRS — so
per-file llvm-cov region coverage was never measured. U5 turns the gate on, and turning it on reveals the
real gap: **~1,019 uncovered region segments across 93 of ~124 view decls** (see residual-baseline.md THE
FORK), dominated NOT by the ~28 branchless views the brief assumed but by un-hit regions in ALREADY-
snapshotted logic-bearing views (secondary `@ViewBuilder` arms / helper closures the chosen fixtures
didn't execute). U5 closes that real residual so the whole view layer is honestly held to per-file 100%.

## Completion Criteria

- [ ] `WorkbenchViewModel` (+ pure-behavioral non-View helpers) extracted to a NEW file
      `Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift`; the views file holds only View structs
      (renamed `WorkbenchViews.swift` — reversible default, see Decisions).
- [ ] The extract PR is PROVEN pure-move: build green + full `swift test` green + `git diff` is pure
      code-movement (only access-widen promotions, no logic change). Promotions enumerated, each justified.
- [ ] `appSource()` union-reader + `orderedLibFiles` updated for the new file boundary; all structural-guard
      slices stay adjacency-correct (`assertEveryLibFileIsOrdered` green; full guard suite green).
- [ ] The MEASURED post-split views residual (~1,019 region segments across 93 decls — NOT just the 28
      branchless; see residual-baseline.md THE FORK) is closed to ZERO for every non-K1 view: K2
      (already-snapshotted, un-hit regions) gets the missing fixture states; K3 (branchless) gets a
      provenance-built content-pinned snapshot; all mutation-verified (mutate a rendered Text/Image → RED →
      revert).
- [ ] Genuinely-nodeless views (pure Color/Divider/frame — serializer captures nothing) and ②b-recorded
      genuinely-unreachable regions are allowlisted with a verified justification (NOT fabricated as vacuous
      greens, NOT contorted tests).
- [ ] `scripts/check-coverage.sh` gates the views file at per-file 100% line+region; the views file's
      allowlist budget is the MEASURED MINIMUM = ONLY K1 (verified genuinely-untestable carves), not padded
      with K2; one comment per carve tracing to its dossier/nodeless/②b justification.
- [ ] `WorkbenchViewModel.swift` (+ other behavioral lib files) is NOT gated (GUI-adjacent behavioral logic,
      like the app shell) — documented why.
- [ ] Core/ShellAdapter stay 100% (their existing gate unchanged).
- [ ] All per-PR gates green (see below).
- [ ] Fresh unbiased sub-agent review gate passes before READY.
- [ ] 100% test coverage on all new code (the new snapshot tests; no new behavioral code is written).
- [ ] All tests pass; no warnings.

## Code Coverage Requirements

**MANDATORY: 100% coverage on all new code.**
- No `[ExcludeFromCodeCoverage]` or equivalent on new code. (Swift: no `// llvm-cov` skips; the ONLY
  permitted exclusion mechanism is the documented `scripts/coverage-allowlist.txt`, sized to the measured
  minimum with a per-carve justification.)
- All branches covered (if/else, switch, ForEach arms) for the views file → that is the point of U5.
- All error paths tested.
- Edge cases: empty / one / many / boundary states (the campaign's P4 state-set discipline).
- The views FILE goes to per-file 100% (minus the honest allowlist); the ViewModel FILE is GUI-adjacent
  behavioral logic, NOT in COVERAGE_DIRS (documented — like the `@main`/App shell carve).

## TDD Requirements

**Strict TDD — no exceptions:**
1. **Tests first**: Write the failing snapshot test (provenance-built fixture, expected reference) BEFORE
   committing the reference.
2. **Verify failure**: Run, confirm RED (no committed reference yet, or a deliberately-wrong reference).
3. **Minimal**: Record the real serialized tree as the reference; commit.
4. **Verify pass**: Run, confirm GREEN.
5. **Mutation-verify (anneal P2)**: Mutate a rendered Text/Image in the fixture → snapshot RED → revert →
   GREEN. Proves the snapshot catches SOME content mutation (non-vacuous-for-content).
6. **No skipping**: Never commit a reference without the RED→GREEN→mutation cycle.

NOTE: Steps 1 (the extract) and 3 (gate wiring) write NO new product logic — step 1 is a pure code-MOVE
(its "test" is build+full-suite-green proving no logic changed), step 3 edits the gate script + allowlist
(its "test" is the gate run itself going green at the measured minimum). Step 2 is the TDD-snapshot work.

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**CRITICAL: Every unit header starts with status emoji (⬜ for new units).**

---

### ⬜ Unit 0: Measure the residual + bucket every uncovered view (BASELINE DONE during conversion)

**What**: The pre-split residual is ALREADY measured (during this doc's conversion) →
  `./2026-06-26-u5-honest-coverage-gate/residual-baseline.md`. Key results:
- Views file: 58.1% line / 41.8% region (13,346 uncov lines, 3,391 uncov regions) at the gate metric.
- Partitioned: VM body (10607–20716) = 2,226 uncovered region segments (MOVES OUT); post-VM terminal =
  129 (moves with VM); **pre-VM view structs = ~1,019 uncovered region segments across 93 of ~124 decls**.
- Per-view attribution table (top offenders, bucketed K1/K2/K3/K4) is in residual-baseline.md.

**The doer's Unit-0 work (AFTER the PR#1 split lands)** is to RE-MEASURE on the post-split `WorkbenchViews.swift`
  and produce the per-view bucketing that DRIVES Unit 2:
- Re-run coverage; export the views file; for each view with residual, classify: K1 (dossiered carve →
  allowlist), K2 (already-snapshotted, un-hit regions → fixture-extend), K3 (branchless → new snapshot),
  nodeless (→ allowlist), K4 (behavioral → moved with VM/covered).
- For each K2/K3 view, locate the exact un-hit regions (`llvm-cov show … --show-regions` → the `^0` arms)
  and the body line range, so Unit 2 knows precisely which states to add.
- For each candidate snapshot, check `ViewSnapshotHost.mapNode`'s whitelist (Text string / TextField bound
  value / Image SF-symbol name / a11y label-value-id): renders a captured node → snapshot-able (Unit 2);
  only Color/Divider/frame/geometry → nodeless → allowlist (Unit 3) with the "serializer captures nothing"
  justification.

**Output**: `residual-baseline.md` updated with the POST-SPLIT per-view bucketing table
  (`<View> | bucket | uncov regions | un-hit arms | snapshot-able? | nodeless?`). This is the input that
  sizes Unit 2 (the close-list) and Unit 3 (the K1 allowlist budget).

**Acceptance**: residual-baseline.md exists (DONE for pre-split) and is updated post-split with EVERY
  residual-bearing view bucketed; no view left unclassified. NO source/test/gate change in this unit.

---

### ✅ Unit 1a: Extract `WorkbenchViewModel` — risk map + plan (DONE during conversion; doer RE-VERIFIES)

**What**: The extraction plan is already produced (during this doc's conversion) in
  `./2026-06-26-u5-honest-coverage-gate/extract-plan.md` from a first-hand structural read. Key results:
- VM class extent: **one contiguous block, lines 10607–20716 (10,110 lines)**.
- `private`→`internal` promotions: **N = 3** (`ProviderCheckProcessResult` :104, `BossQuickQuestion`
  :5833, `bossQuickQuestions` :5839 — defined in the view section, used inside the VM). 9 `private extension`
  blocks are view-section-only → NOT promoted.
- Move-set: VM + `MailboxFetchResult`, `SingleShotContinuation`, `TerminalSessionController`,
  `CapturingLocalProcessTerminalView` → new file. `TerminalPane`/`TerminalHostView`/`WorkbenchTerminalPalette`/
  `TerminalThemeOverride` placement is a recorded FORK (D3): the gate-clean default moves the AppKit
  live-PTY representable types to the NON-gated file too.
- Guard-slice retargets: **M = 0** (no `sourceSlice` pair straddles the VM boundary; the two cross-decl
  pairs stay within one file as long as TerminalSessionController + CapturingLocalProcessTerminalView move
  together).

**The doer RE-VERIFIES N and M at execution against a real compiler build** (N = exactly the symbols the
  compiler reports as inaccessible after the split — no more, no fewer; M = re-grep every `sourceSlice`
  from/to marker against the post-split file boundaries). The read-estimates (N=3, M=0) are the expectation,
  not a license to skip the compiler check.

**Acceptance**: extract-plan.md exists with concrete N/M backed by line citations (DONE). Doer's re-verified
  N/M recorded in the Progress Log before 1b commits. NO source change in this unit.

### ✅ Unit 1b: Extract `WorkbenchViewModel` — the pure code-MOVE (PR #1)

**What**: Execute the plan from 1a:
- Create `Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift`; move the VM class (+ the agreed
  behavioral helpers/types) BYTE-IDENTICALLY (cut, not retype) into it.
- Rename `WorkbenchViewsAndModel.swift` → `WorkbenchViews.swift` (it now holds only View structs).
  Reversible default; record it.
- Promote ONLY the enumerated `private`/`fileprivate` cross-references to `internal` (minimal; each noted
  with a `// U5: widened private→internal for the VM/views file split (was same-file)` comment or a single
  collected note — pick the lower-noise option, record which).
- Update `WorkbenchAppSource.orderedLibFiles` to insert `WorkbenchViewModel.swift` + the renamed
  `WorkbenchViews.swift` in declaration order; update any guard slice that now spans the boundary.

**Acceptance** (this is the "test" — it is a pure MOVE, proven by green, not by a new test):
- `git diff` is pure code-movement: only the file split, the rename, and the enumerated access-widen
  promotions. NO logic change. (Spot-check: `git log -p` / a normalized-diff that shows moved lines as
  pure relocation.)
- Strict build 0-warn: `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`.
- Full `swift test` 0-fail (the whole campaign's 297 refs + all guards + `assertEveryLibFileIsOrdered`).
- `--uisurfacetest` green; structural guards green.
- ONE commit (`refactor(views): split WorkbenchViewModel out of the views file (pure move)`).
- The views file is NOT yet in COVERAGE_DIRS (that's Unit 3) — coverage gate unchanged, still green for
  Core/ShellAdapter.

---

> **RE-SCOPED FROM THE BRIEF (see THE FORK in residual-baseline.md).** The brief framed Unit 2 as "snapshot
> the ~28 branchless views." The MEASURED post-split views residual is ~1,019 uncovered region segments
> across **93 of ~124 view decls** — dominated NOT by the 28 branchless views (K3) but by un-hit regions in
> ALREADY-snapshotted logic-bearing views (K2: HeaderView, DecisionInboxSheet, CommandPaletteSheet, …). "Has
> a mutation-surviving snapshot" (campaign energy-0) ≠ "every llvm-cov region executed" (the per-file gate).
> Unit 2 closes the REAL residual (K2 + K3), not just the 28 branchless. K1 (verified genuinely-untestable
> shells/live-arms) is NOT closed here — it is the honest allowlist in Unit 3. This is the largest unit;
> the doer drives it to a measured zero (per-view residual → 0 for every non-K1 view) in residual-ranked
> batches, each its own commit, NOT one mega-commit. It MAY itself spawn parallel sub-agents per batch.

### ⬜ Unit 2a: Close the views residual — batch plan + tests first (RED)

**What**:
- From Unit 0's `residual-baseline.md`, take the per-view uncovered list and BUCKET each view: K1 (dossiered
  carve → skip, goes to allowlist), K2 (already-snapshotted, un-hit regions → add the missing fixture
  states), K3 (branchless → new content-pinned snapshot), nodeless (→ allowlist), K4 (behavioral helper →
  moved with VM or covered as logic).
- For each K2 view: identify WHICH regions are un-hit (`xcrun llvm-cov show … <viewsfile>` → the `^0` arms),
  determine the fixture state that exercises each (the missing `@ViewBuilder` arm / helper-closure / secondary
  body path), and write the failing test/fixture for it. For each K3 view: a new provenance-built snapshot.
- ALL fixtures provenance-built per the campaign's ②b law (real model/queue, never hand-assembled; reuse the
  proven recipes: `workbenchTimeText`+cross-TZ, AN-001 `agentBundlesURL` dual-injection, path-leak fixed
  `/tmp` paths, standalone `.popover`/`.contextMenu` but `Menu{}` IS descended). First run RED.
- **②b law guard:** if a region is genuinely unreachable through any real seam (no fixture can execute it
  without fabricating a state the app can't produce), it is NOT force-covered — it becomes a RECORDED carve
  candidate for Unit 3's allowlist WITH a verified justification (the AN-006/C1 discipline). The doer must
  not contort a test to colour a region; honest allowlist > gamed metric (rubric D-A5).

**Acceptance**: Every non-K1 view with residual has failing test(s) targeting its specific un-hit regions;
  fixtures provenance-built + deterministic (no `Date()`/`.now`/`UUID()`/clock leaks); any genuinely-
  unreachable region is logged as a carve candidate (not a contorted test). Each FAILS (RED) on first run.

### ⬜ Unit 2b: Close the views residual — record references (GREEN)

**What**: Record the real serialized tree for each new/extended snapshot; commit in residual-ranked
  batches (highest-residual views first). Run the suite → GREEN after each batch.

**Acceptance**: All new/extended snapshots GREEN; references under the test target's `__Snapshots__/`;
  full suite 0-fail after each batch; no warnings. One commit per batch (not one mega-commit).

### ⬜ Unit 2c: Close the views residual — mutation-verify + re-measure to zero

**What**: For EACH new snapshot, mutate a rendered static Text/Image in the fixture → RED → revert → GREEN
  (anneal P2: non-vacuous-for-content). For each K2 extension, confirm the new fixture state actually
  EXECUTES the previously-un-hit region (re-run `llvm-cov show` → the `^0` arm is now hit). Re-measure the
  whole views file; confirm the per-view residual is ZERO for every non-K1 view.

**Acceptance**: Every new snapshot mutation-verified (RED on content mutation, GREEN on revert); coverage
  re-measure shows the ONLY remaining views-file residual is K1 (the dossiered carves + verified nodeless +
  any ②b-recorded genuinely-unreachable region). The exact remaining count is recorded → it becomes Unit 3's
  allowlist budget. One commit per batch. NO AI attribution. Never stage
  `SerpentGuide.ouro/`/`default.profraw`/`*.actual.txt`.

---

## Unit 2 — RE-MEASURED batch plan (post-split @ `origin/main 0c9f803`)

> Full per-view region targets + per-batch recipes: `./2026-06-26-u5-honest-coverage-gate/unit2-batch-plan.md`.
> Scripts (committed): `uncovered-by-view-postsplit.py`, `decls-postsplit.txt` (this dir).

**Authoritative re-measurement** (3426 tests / 1 skip / 0 fail; `swift test --enable-code-coverage` →
`xcrun llvm-cov export … WorkbenchViews.swift`): the gated views file is **64.99% region** — **1,046
uncovered regions** (gate metric `regions.count − covered`) / 78.47% line, across 102 of 127 decls. (The
pre-split residual-baseline's 41.8% was diluted by the VM body; 1,046 ≈ the pre-split ~1,019 estimate and
is now the AUTHORITATIVE target.) Classification (sums to 1,046):

| bucket | decls | regions | disposition |
|---|---|---|---|
| **K1** dossiered carves (#1–#8) | 10 | 330 | → Unit 3 allowlist (partial carves have a K2 tail — split per-arm; firm floor 249) |
| **K4** non-View behavioral helpers in gated file | 14 | 72 | → B10: MOVE DropDelegate to VM file; DIRECT logic-test the rest |
| **K2/K3** closeable views | 78 | 644 | → B1–B9, drive+assert+mutation-verify each |

**K1 carve seed (NOT closed in Unit 2):** WorkbenchRootView 155 · WorkbenchMenuBarController 54 ·
LoginItemController 23 · AboutSheet 10 · MachineRuntimeView 7 (full shells = firm floor 249) +
SessionDetailView 29 · BossDashboardView 28 · AutonomyStatusPopover 14 · AutonomyStatusButton 8 ·
DetailSplitContainer 2 (partial live/login arms ≤81 — split per-arm, drive non-carve arms, carve only the
live/login/build-hash arm). **Do NOT blind-seed the allowlist at 330** — the measured minimum after the
per-arm split (likely < 330) is the budget.

**K4 finding (the brief's "K4 helper that stayed in WorkbenchViews.swift"):** 14 non-View types stayed in
the gated file. `WorkspaceFolderDropDelegate` (12, a `DropDelegate` over `DropInfo`/async `Task` — near-
undrivable, behavioral) → **MOVE to `WorkbenchViewModel.swift`** (the K4 follow-up move). The rest
(`WorkbenchGroupColor.swiftUIColor` 10, `AutonomyReadinessState` 7, `DetailSplitState`/`DetailPaneID`/
`AttentionState` 6 ea, `DetailSplitAxis`/`AutonomyRemediationKind`/`BossWorkbenchMCPRegistrationStatus` 5 ea,
`WorkbenchImportApplyResult` 4, `WorkbenchToolsInjectionRecorder` 2, `Optional` 2, `HarnessHealthState`/
`HeaderCalmPresentation` 1 ea) are pure enums/structs/extensions → **DIRECT `XCTAssert` logic tests** (NOT
snapshots — they render no captured node). Reversible default recorded (D8).

### ⬜ Unit 2 batches (each: re-measure → drive reachable arm + asserting ref → mutation-verify → re-measure to ~0 minus carves; ONE commit per view/sub-unit; all per-PR gates green). Sequenced high-region-first; B1–B10 independent (fan-out OK; serialize doc commits).

| seq | batch | views | regions | recipe |
|---|---|---|---|---|
| 1 | ⬜ B4 Terminal group/session sheets | 6 | 113 | model project/group/session state; FIXED `/tmp/u4` path-leak pins |
| 2 | ⬜ B5 Session detail strip + panels | 11 | 102 | `activeSession==nil` carve seam (C9); `workbenchTimeText`; always-true arms recorded |
| 3 | ⬜ B3 Onboarding flow | 9 | 79 | onboarding `@Published` seams (C10); page/step arm coverage |
| 4 | ⬜ B9 Harness/settings/import/recovery/misc | 12 | 74 | `HarnessStatusBuilder` AN-001 hermetic (C11); import presentation; RecoveryDrill producer |
| 5 | ⬜ B2 Header/boss-selector/autonomy rows | 6 | 67 | `workbenchTimeText` cross-TZ; descended `Menu{}`; standalone rows |
| 6 | ⬜ B6 Decision inbox/log + command palette | 4 | 59 | `state.recordDecision`/`decisionLog` real producer (C2); command-row arms |
| 7 | ⬜ B1 Sidebar + workspace tabs/rows | 12 | 54 | standalone `.contextMenu`; `GitSessionStatus.parse` (C1); `workbenchTimeText` |
| 8 | ⬜ B7 Agent manager/detail/install + provider | 8 | 52 | AN-001 dual-injection; C6 `initialHumanName` seam; fixed records/paths |
| 9 | ⬜ B8 Boss dashboard sub-views + watch + receipts | 10 | 44 | `BossDashboardBuilder`/`BossActionReceiptSummary` producers; `workbenchTimeText` |
| 10 | ⬜ B10 K4 behavioral helpers | 14 | 72 | MOVE `WorkspaceFolderDropDelegate`→VM file; DIRECT logic-test the rest |

**Target after B1–B10:** every non-K1 region driven+asserted+mutation-verified (or moved/direct-tested); the
ONLY remaining views-file residual is K1, split to its measured minimum (≤330, likely less) in Unit 3.

---

### ⬜ Unit 3: Wire the gate with the honest minimal allowlist (PR #3)

**What**:
- Add the views file to the coverage gate. **DECISION (record in doc):** COVERAGE_DIRS is directory-
  granular but only `WorkbenchViews.swift` (the views file) should be gated, NOT `WorkbenchViewModel.swift`
  / `WorkbenchUpdateInstaller.swift` / `WorkbenchKeyboardAccessibilityContract.swift` / the Terminal* PTY
  types. Reversible default: extend the gate's per-file filter to gate ONLY the views file (an explicit
  gated-files set), keeping the directory-add from sweeping in the behavioral files. (Alternative recorded:
  a per-file skiplist. Pick the lower-complexity one at execution; record which + why.)
- Measure the EXACT residual uncovered lines/regions on `WorkbenchViews.swift` AFTER Units 1-2. The
  residual MUST by then be ONLY K1 (the dossiered genuinely-untestable carves + verified nodeless views +
  any ②b-recorded genuinely-unreachable regions). Add a single allowlist entry sized to EXACTLY that
  residual, with a per-carve comment in `scripts/coverage-allowlist.txt` tracing each to its dossier (#1–#8
  in `allowlist-candidates.md`) or its verified nodeless/②b justification. Do NOT pad. The budget MUST be
  the minimum that passes. **K2 must NOT appear in the allowlist** (it is un-exercised, not untestable —
  it was closed in Unit 2; if any K2 residual remains, Unit 2 is not done, do NOT allowlist it).
- Document why `WorkbenchViewModel.swift` (+ the moved behavioral/terminal files) is NOT gated (GUI-adjacent
  behavioral logic, like the app shell; `@main`/App/AppDelegate/`TerminalPane` precedent — the live-PTY/
  controller types are not pure logic).

**Acceptance**:
- `scripts/check-coverage.sh` PASS: Core/ShellAdapter at 100% (allowlist=2, unchanged) AND `WorkbenchViews.swift`
  at per-file 100% line+region minus the documented K1-only allowlist.
- The views-file allowlist budget equals the MEASURED K1 residual (verified: lowering any carve count by 1
  makes the gate FAIL → proves it is minimal, not padded). Every carve traces to a verified justification.
- Strict build 0-warn; full `swift test` 0-fail; `--uisurfacetest` green; structural guards green.
- ONE commit (`test(coverage): gate the views file at per-file 100% with the honest K1-only allowlist`).

---

### ⬜ Unit R: Fresh unbiased sub-agent review gate (before READY)

**What**: Spawn a FRESH general-purpose sub-agent (did NOT author Units 1-3) to independently verify:
- The extract is a TRUE pure-move (diff shows only relocation + the enumerated ≤3 promotions; no logic delta).
- Every new/extended snapshot (K2 fixture-extensions AND K3 branchless) is provenance-built + mutation-
  verified (no vacuous greens; no hand-assembled fixtures; no `Date()`/`UUID()`/clock leaks); each K2
  extension actually EXECUTES the previously-un-hit region it claims.
- The views-file residual is closed to ZERO for every non-K1 view (re-measure; do not trust prior logs).
- The allowlist budget is HONEST + minimal = ONLY K1 (each carve traces to a verified dossier #1–#8 /
  verified nodeless / ②b-recorded-unreachable justification; NO K2 in the allowlist; lowering any count
  fails the gate).
- All per-PR gates are actually green (re-run them).
- No `SerpentGuide.ouro/` / `default.profraw` / `*.actual.txt` staged anywhere.

**Output**: `./2026-06-26-u5-honest-coverage-gate/review-gate.md` — the fresh agent's findings + verdict.

**Acceptance**: The review gate verdict is PASS (or its findings are resolved and it re-passes). Only then:
  (a) this doc's Status flips to `done`; (b) a TERSE pointer is appended to the campaign journal
  `../2026-06-24-anneal-visual-testing.md` (e.g. "U5 — views file gated at per-file 100%, K1-only honest
  allowlist of N lines/M regions; VM split out; energy-0 still holds") linking back to this doing doc.
  NO PR is opened (per brief).

## Execution

- **TDD strictly enforced** for Unit 2: provenance fixture → RED → record reference → GREEN → mutation-verify.
- Units 1 and 3 write no product logic; their "test" is the full-suite + gate going green.
- Per-PR gates (ALL must pass before a unit is done). Two runners (validated @ conversion):
  - `scripts/preflight.sh` — strict build/test 0-warn (`-Xswiftc -warnings-as-errors -Xswiftc
    -strict-concurrency=complete`), full `swift test` 0-fail, `--uisurfacetest`, `--keyboarda11ycontract`,
    and the scenario verifier with `--expect-coverage-digest <digest>` pins. **NOTE:** preflight does NOT
    run `check-coverage.sh`; and the scenario-verifier `--expect-coverage-digest` values may shift when
    coverage changes — if Unit 2/3 moves a digest, update the pinned digest in preflight.sh in the SAME PR.
  - `scripts/check-coverage.sh` — the per-file coverage gate (separate; run in CI at `.github/workflows/
    ci.yml:212`). Core/ShellAdapter always 100%; the views file after Unit 3.
  - structural guards green (incl. `assertEveryLibFileIsOrdered` via `WorkbenchAppSourceRetargetTests`).
- ONE commit per sub-unit. NO AI attribution. NEVER stage `SerpentGuide.ouro/` / `default.profraw` /
  `*.actual.txt`.
- Branch: `u5-honest-coverage-gate` (off `origin/main` @ 687b6c7). NO PR (per brief).
- **All artifacts**: save to `./2026-06-26-u5-honest-coverage-gate/`.
- **Fixes/blockers**: spawn a sub-agent immediately — don't ask, just do it (autonomous).
- **Decisions made**: update this doc + the campaign journal pointer immediately; commit right away.
- PR decomposition: **3 PRs, serial** (Unit 2 is the heavy one and MAY internally fan out to parallel
  sub-agents per residual batch, but lands as ONE PR). PR#1 = Unit 1 (extract, pure move, lands FIRST,
  ≥2 adversarial reviewers per the U0 precedent for a move this size). PR#2 = Unit 2 (close the measured
  K2+K3 residual to zero, batched commits). PR#3 = Unit 3 (gate wiring + K1-only allowlist). Unit R review
  gate runs after PR#3. Each PR's per-PR gates must pass before the next starts (serial dependency).

## Decisions Made

- **D1 — file rename:** `WorkbenchViewsAndModel.swift` → `WorkbenchViews.swift` once the VM leaves it.
  Reversible default (the name is now accurate; `orderedLibFiles` + `appSource()` updated in the same PR).
- **D2 — gate granularity:** gate ONLY `WorkbenchViews.swift`, not the whole dir, so the behavioral lib
  files (`WorkbenchViewModel.swift`, `WorkbenchUpdateInstaller.swift`,
  `WorkbenchKeyboardAccessibilityContract.swift`, Terminal* PTY types) are NOT force-100%'d. Reversible
  default: explicit gated-files set in `check-coverage.sh` (alternative: per-file skiplist — chosen at exec).
- **D3 — `TerminalPane`/`TerminalHostView` placement (RECORDED FORK):** the structural read recommends they
  STAY in the views file (code-org: they're UI). The GATE-clean default is the opposite — move them into the
  NON-gated `WorkbenchViewModel.swift` with the terminal machinery, so the gated views file contains ZERO
  categorically-uncoverable AppKit-representable code (no carve needed for them). Reversible default: move
  them to the non-gated file. If the doer finds this triggers a guard-slice inversion or a worse public
  surface, the fallback is "stays in views + allowlist carve." Doer records which at exec.
- **D6 — THE RESIDUAL FORK (the big one):** the brief assumed Unit 2 = "snapshot ~28 branchless views." The
  measured post-split residual is ~1,019 region segments across 93 views, dominated by K2 (un-hit regions in
  already-snapshotted views), not branchless. Reversible default adopted: **CLOSE the real residual** (K2
  fixture-extend + K3 snapshot) and allowlist ONLY K1 — do NOT pad the budget with K2 (the brief forbids
  padding). This makes Unit 2 substantially larger than the brief implied. **This is the fork to surface to
  the operator** — if they prefer a faster honest gate, the recorded alternative is: gate the views file at a
  documented PARTIAL threshold that carves ONLY verified-K1 today and tracks the K2 region-closing as an
  explicit backlog effort (NOT hand-waved into the allowlist). Either path keeps the allowlist honest; they
  differ only in whether K2 is closed now or sequenced.
- **D7 — recipe reuse (no re-derivation):** all new fixtures reuse the campaign's proven determinism recipes
  (`workbenchTimeText`+cross-TZ, AN-001 `agentBundlesURL` dual-injection, fixed `/tmp` path-leak anchors,
  standalone `.popover`/`.contextMenu`, `Menu{}` descended) and the `ViewSnapshotHost`/②b-law provenance
  harness — U5 writes no new harness.
- **D4 — execution mode = spawn** (fully autonomous; fresh review gate before READY).
- **D5 — no PR** (per brief; branch pushed at most, doc + journal pointer committed).
- **D8 — K4 behavioral-helper disposition (NEW, post-split re-measure):** 14 non-View types stayed in the
  gated `WorkbenchViews.swift` after the Unit-1 split (72 uncovered regions). Reversible default:
  **MOVE `WorkspaceFolderDropDelegate`** (12 regions — a `DropDelegate` over `DropInfo`/`NSItemProvider`/
  async `Task`, behavioral and near-undrivable in-process) — and optionally `WorkbenchToolsInjectionRecorder`
  (2) — **to the non-gated `WorkbenchViewModel.swift`** (same rationale as moving the VM/terminal machinery:
  they are behavioral, not views); **DIRECT `XCTAssert` logic-test the rest** (pure enums/structs/extensions
  — `WorkbenchGroupColor.swiftUIColor`, `AutonomyReadinessState`, `DetailSplitState/Axis/PaneID`,
  `AttentionState` ext, etc. — they render no host-captured node, so they are NOT snapshots). Fallback if a
  move triggers a guard-slice inversion: direct-test-in-place or allowlist with a verified justification.
  This is batch B10, landed BEFORE Unit 3 measures the carve budget (a move changes the residual).
- **D9 — partial-carve K2 tail (NEW):** the 5 K1 PARTIAL carves (SessionDetailView 29, BossDashboardView 28,
  AutonomyStatusPopover 14, AutonomyStatusButton 8, DetailSplitContainer 2 = 81 measured regions) are NOT
  all carve — their residual may include ordinary un-driven arms the campaign's fixtures didn't hit. Default:
  the partial-carve / Unit-3 doer MUST `llvm-cov show --show-regions` each and SPLIT per-arm — DRIVE the
  non-carve arms (do NOT allowlist), carve ONLY the genuinely-untestable live/login/build-hash arm. The
  allowlist budget is the measured minimum after this split (firm full-shell floor 249; total ≤330, likely
  less). **Never blind-seed the allowlist at 330.**

## Progress Log
- 2026-06-26 09:14 Created from the operator's firm-decision brief (Q1=SPLIT, Q2=SNAPSHOT)
- 2026-06-26 09:21 Granularity pass + measured the residual (THE FORK: ~1,019 region segments / 93 views,
  NOT just 28 branchless) + extract risk numbers (N=3 promotions, M=0 guard retargets, VM 10607–20716)
- 2026-06-26 09:22 Validation pass: verified VM extent, the 3 promotion symbols + 2 move-helpers exact
  lines, post-VM terminal type lines, `ViewSnapshotHost.mapNode` harness, `--uisurfacetest`/preflight gates,
  `check-coverage.sh` in CI, `assertEveryLibFileIsOrdered` wired. Noted preflight ≠ coverage gate + the
  scenario-verifier coverage-digest pins.
- 2026-06-26 09:23 Quality pass (all unit headers carry status emoji, no TBDs, criteria testable — no
  changes). Planning coverage check: every brief requirement mapped to a unit (planning-coverage-checklist.md
  — full coverage); tightened Unit R to explicitly write the terse campaign-journal pointer.
- 2026-06-26 RE-VERIFIED at the compiler (Unit 1a ground truth): **N = 2 promotions, NOT 3.** The compiler
  named exactly `ProviderCheckProcessResult` (:104) AND `ProviderCheckOutputBuffer` (:110) as inaccessible
  after the split — both view-section `private` types the VM uses. The plan's estimate `BossQuickQuestion`
  (:5833) / `bossQuickQuestions` (:5839) were WRONG: both are referenced ONLY inside the views file
  (the `ForEach(bossQuickQuestions)` view body @ :5891) → no promotion needed, kept `private`. The plan
  MISSED `ProviderCheckOutputBuffer`. Net: 2 promotions, both `private`→`internal`, pure access-widen.
  **M = 0 confirmed** (re-grepped every `appSource()` `sourceSlice` from/to pair against the post-split
  boundaries; every cross-decl pair is co-file — `TerminalSessionController`→`CapturingLocalProcessTerminalView`
  both in WorkbenchViewModel.swift, `WorkbenchRootView`→`WorkbenchMenuBarController` both in WorkbenchViews.swift;
  `WorkbenchAppSourceRetargetTests` + `assertEveryLibFileIsOrdered` green).
- 2026-06-26 Unit 1b COMPLETE (PR#1): pure code-MOVE. `WorkbenchViewsAndModel.swift` (21,444 lines) split
  into `WorkbenchViews.swift` (10,623 lines — View structs + relocated `WorkbenchGroupColor.swiftUIColor`
  view helper) + new `WorkbenchViewModel.swift` (10,838 lines — VM @ old 10606–20716 + MailboxFetchResult +
  TerminalThemeOverride + WorkbenchTerminalPalette + TerminalPane + TerminalHostView + SingleShotContinuation
  + TerminalSessionController + CapturingLocalProcessTerminalView + 2 private extensions; D3 default applied —
  all AppKit/PTY UI moved to the NON-gated file so the gated views file has zero categorically-uncoverable
  AppKit code). Multiset content-conservation check: every non-blank code line byte-identical (only delta is
  the duplicated `#if/imports/#endif` + 5-line doc header + 1 cosmetic blank). 2 access promotions. Plus one
  rename-propagation: `WorkbenchKeyboardAccessibilityContract.swift` :308 path retargeted
  `WorkbenchViewsAndModel.swift`→`WorkbenchViews.swift` (all 4 a11y needles live in the views file; was a
  hardcoded filename, not logic). GATES: strict build 0/0; full `swift test` 3426 tests / 1 skip (pre-existing
  env-gated RepairAgentKeystone) / 0 fail (same count as baseline); `--uisurfacetest` ok; structural+a11y
  guards green; `check-coverage.sh` green + COVERAGE_DIRS/allowlist UNCHANGED (gate wiring is Unit 3).
- 2026-06-26 Unit 2 RE-MEASURED on the post-split `WorkbenchViews.swift` (`origin/main 0c9f803`) + decomposed
  into batches. **Authoritative residual: 64.99% region = 1,046 uncovered regions / 78.47% line, 102 of 127
  decls** (3426 tests / 0 fail; `swift test --enable-code-coverage` → `llvm-cov export`). The pre-split 41.8%
  was diluted by the VM body; 1,046 ≈ the pre-split ~1,019 estimate, now authoritative. **Classification
  (sums to 1,046):** K1 carve seed 330 (10 decls; firm full-shell floor 249 + ≤81 partial-arm tail to split),
  K4 behavioral helpers 72 (14 decls; MOVE DropDelegate→VM + direct-test the rest), K2/K3 closeable 644 (78
  decls). **Batch decomposition: B1–B9 (644 regions, 78 views) + B10 (K4, 72) — 10 batches, sequenced
  high-region-first** (B4 113 · B5 102 · B3 79 · B9 74 · B2 67 · B6 59 · B1 54 · B7 52 · B8 44 · B10 72);
  each independent (fan-out OK), each: re-measure → drive reachable arm + asserting ref → mutation-verify →
  re-measure to ~0 minus carves; one commit per view. **New decisions D8 (K4 move/direct-test) + D9 (split
  partial carves per-arm, never blind-seed allowlist at 330).** Artifacts: `unit2-batch-plan.md` (full per-
  view region targets + per-batch recipes), `uncovered-by-view-postsplit.py`, `decls-postsplit.txt`.
