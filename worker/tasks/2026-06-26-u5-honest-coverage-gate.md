# Doing: U5 — Honest per-file-100% coverage gate on the OuroWorkbench view layer

**Status**: drafting
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
snapshotting the genuinely-uncovered branchless presentational views (content-pinned, mutation-verified)
instead of allowlisting them, and (3) wiring the gate with an HONEST minimal allowlist sized to only the
genuinely-untestable carves. The ANNEAL view-snapshot campaign (C0–C11, 297 refs, energy-0) covered all
~69 logic-bearing views; U5 closes the last gap — the gate itself — so the whole view layer is held to 100%.

## Completion Criteria

- [ ] `WorkbenchViewModel` (+ pure-behavioral non-View helpers) extracted to a NEW file
      `Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift`; the views file holds only View structs
      (renamed `WorkbenchViews.swift` — reversible default, see Decisions).
- [ ] The extract PR is PROVEN pure-move: build green + full `swift test` green + `git diff` is pure
      code-movement (only access-widen promotions, no logic change). Promotions enumerated, each justified.
- [ ] `appSource()` union-reader + `orderedLibFiles` updated for the new file boundary; all structural-guard
      slices stay adjacency-correct (`assertEveryLibFileIsOrdered` green; full guard suite green).
- [ ] Every genuinely-uncovered branchless view has one provenance-built, content-pinned snapshot,
      mutation-verified for CONTENT catch (mutate a rendered Text/Image → RED → revert).
- [ ] Genuinely-nodeless views (pure Color/Divider/frame — serializer captures nothing) are allowlisted
      with a verified "nodeless" justification (NOT fabricated as vacuous greens).
- [ ] `scripts/check-coverage.sh` gates the views file at per-file 100% line+region; the views file's
      allowlist budget is the MEASURED MINIMUM (exact residual, not padded), one comment per carve.
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

### ⬜ Unit 0: Measure the residual + reconfirm the branchless set (research, NO code change)

**What**:
- Run `swift test --enable-code-coverage`; export per-file summary for `Sources/OuroWorkbenchAppViews`
  (reuse `./2026-06-26-u5-honest-coverage-gate/measure-views-residual.py`). Record the CURRENT
  uncovered line+region count for `WorkbenchViewsAndModel.swift` — this is the pre-split residual.
- For EACH of the 28 branchless-presentational views (classification doc + dossier #8), determine
  whether its body is ALREADY 100%-covered (transitively, via a composite snapshot) or has live
  uncovered lines/regions. Use `xcrun llvm-cov show <bin> -instr-profile <prof> <file>` and locate
  each view's `body` line range. Output the RECONFIRMED split: {already-covered} vs {genuinely-uncovered
  + snapshot-able} vs {nodeless → allowlist}.
- For each genuinely-uncovered branchless view, check `ViewSnapshotHost.mapNode`'s whitelist (Text string /
  TextField bound value / Image SF-symbol name / a11y label-value-id): does the body render ANY captured
  node? If yes → snapshot-able (Unit 2). If it renders only Color/Divider/frame/geometry → nodeless →
  allowlist (Unit 3) with the "serializer captures nothing" justification.

**Output**: `./2026-06-26-u5-honest-coverage-gate/residual-baseline.md` —
  (a) pre-split per-file residual for the views file; (b) the reconfirmed branchless table:
  `<View> | covered? | snapshot-able? | nodeless? | body-line-range`; (c) the projected carve list
  (the 8 dossiered carves + any nodeless views) with each one's expected uncovered line/region count.

**Acceptance**: The residual-baseline.md exists; every branchless view from the classification doc is
  accounted for as covered / snapshot-able / nodeless; no view is left unclassified. This is the
  empirical input that sizes Units 2 and 3. NO source/test/gate change in this unit.

---

### ⬜ Unit 1a: Extract `WorkbenchViewModel` — risk map + plan (NO code change yet)

**What**: Produce the precise extraction plan from a first-hand read:
- Confirm the VM class extent (one contiguous block, ~lines 10607–20732).
- Enumerate EVERY `private`/`fileprivate` cross-reference that the split would break: a member/extension/
  free-function the VM and a View struct currently share via same-file access. For each: line, what it is,
  why the split breaks it, and that promoting it `private`→`internal` is the minimal fix (same-module).
- Decide which non-View behavioral types move WITH the VM into `WorkbenchViewModel.swift` vs stay in the
  views file (candidates flagged: `TerminalSessionController`, `CapturingLocalProcessTerminalView`,
  `TerminalHostView`, `WorkbenchTerminalPalette`, `TerminalThemeOverride`, `WorkbenchMenuBarController`,
  and `TerminalPane` — note: `TerminalPane` is the `@main`-allowlisted live-PTY representable already
  outside coverage; it should land in the NON-gated file so the gate doesn't try to 100% it).
- Enumerate the structural-guard `sourceSlice` pairs whose `from`/`to` markers span the VM (one in a
  pre-VM view, one in a post-VM view, or one inside the VM body): after the move they land in different
  files; the `orderedLibFiles` declaration-order concat must keep them adjacency-correct.

**Output**: `./2026-06-26-u5-honest-coverage-gate/extract-plan.md` — the promotion list (N entries),
  the move-set (which types to the VM file vs views file), the guard-retarget list (M slices), and the
  new `orderedLibFiles` ordering (where `WorkbenchViewModel.swift` slots in declaration order).

**Acceptance**: extract-plan.md complete; promotion count N and guard-retarget count M are concrete
  numbers backed by line citations; no ambiguity left for 1b. NO source change in this unit.

### ⬜ Unit 1b: Extract `WorkbenchViewModel` — the pure code-MOVE (PR #1)

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

### ⬜ Unit 2a: Cover the branchless views — tests first (RED)

**What**: For each genuinely-uncovered-AND-snapshot-able branchless view from Unit 0's reconfirmed list,
  write a provenance-built snapshot test (real model/queue-built fixture per the campaign's ②b law — never
  hand-assembled output; reuse the proven recipes: `workbenchTimeText`+cross-TZ, AN-001 `agentBundlesURL`
  dual-injection, path-leak fixed `/tmp` paths, standalone `.popover`/`.contextMenu` but `Menu{}` IS
  descended). Write the test + the EXPECTED reference such that the first run is RED (no committed
  reference, or a deliberately-wrong one).

**Acceptance**: One test per snapshot-able branchless view; each FAILS (RED) on first run; fixtures are
  provenance-built (no hand-assembled trees); deterministic (no `Date()`/`.now`/`UUID()`/clock leaks).

### ⬜ Unit 2b: Cover the branchless views — record references (GREEN)

**What**: Record the real serialized tree as each committed reference; commit. Run the suite → GREEN.

**Acceptance**: All new branchless snapshots GREEN; references committed under the test target's
  `__Snapshots__/`; full suite still 0-fail; no warnings.

### ⬜ Unit 2c: Cover the branchless views — mutation-verify CONTENT catch + coverage

**What**: For EACH new branchless snapshot, mutate a rendered static Text/Image in the fixture →
  confirm snapshot RED → revert → GREEN (anneal P2: every committed snapshot catches SOME content
  mutation; no vacuous greens). Re-run coverage; confirm each newly-snapshotted view's body lines/regions
  are now covered (the residual for those views drops to 0).

**Acceptance**: Every new snapshot is mutation-verified (RED on a content mutation, GREEN on revert);
  coverage re-measure shows the snapshot-able branchless views now 100% in the views file; the ONLY
  remaining views-file residual is {the 8 dossiered carves + nodeless views}. One commit per sub-feature
  cluster. NO AI attribution. Never stage `SerpentGuide.ouro/`/`default.profraw`/`*.actual.txt`.

---

### ⬜ Unit 3: Wire the gate with the honest minimal allowlist (PR #3)

**What**:
- Add the views file to the coverage gate. **DECISION (record in doc):** COVERAGE_DIRS is directory-
  granular but only `WorkbenchViews.swift` (the views file) should be gated, NOT `WorkbenchViewModel.swift`
  / `WorkbenchUpdateInstaller.swift` / `WorkbenchKeyboardAccessibilityContract.swift` / the Terminal* PTY
  types. Reversible default: extend the gate's per-file filter to gate ONLY the views file (an explicit
  gated-files set), keeping the directory-add from sweeping in the behavioral files. (Alternative recorded:
  a per-file skiplist. Pick the lower-complexity one at execution; record which + why.)
- Measure the EXACT residual uncovered lines/regions on `WorkbenchViews.swift` AFTER Units 1-2. Add a
  single allowlist entry sized to EXACTLY that residual (the 8 dossiered carves + any nodeless-view lines),
  with a per-carve comment in `scripts/coverage-allowlist.txt`. Do NOT pad. The budget MUST be the minimum
  that passes.
- Document why `WorkbenchViewModel.swift` is NOT gated (GUI-adjacent behavioral logic, like the app shell;
  `@main`/App/AppDelegate/`TerminalPane` precedent — the live-PTY/controller types are not pure logic).

**Acceptance**:
- `scripts/check-coverage.sh` PASS: Core/ShellAdapter at 100% (allowlist=2, unchanged) AND `WorkbenchViews.swift`
  at per-file 100% line+region minus the documented minimal allowlist.
- The views-file allowlist budget equals the MEASURED residual (verified: lowering any carve count by 1
  makes the gate FAIL → proves it is minimal, not padded).
- Strict build 0-warn; full `swift test` 0-fail; `--uisurfacetest` green; structural guards green.
- ONE commit (`test(coverage): gate the views file at per-file 100% with the honest minimal allowlist`).

---

### ⬜ Unit R: Fresh unbiased sub-agent review gate (before READY)

**What**: Spawn a FRESH general-purpose sub-agent (did NOT author Units 1-3) to independently verify:
- The extract is a TRUE pure-move (diff shows only relocation + the enumerated promotions; no logic delta).
- Every new branchless snapshot is provenance-built + mutation-verified (no vacuous greens; no hand-
  assembled fixtures; no `Date()`/`UUID()`/clock leaks).
- The allowlist budget is HONEST + minimal (each carve traces to a verified dossier justification or a
  verified nodeless finding; lowering any count fails the gate).
- All gates are actually green (re-run them; do not trust prior logs).
- No `SerpentGuide.ouro/` / `default.profraw` / `*.actual.txt` staged anywhere.

**Output**: `./2026-06-26-u5-honest-coverage-gate/review-gate.md` — the fresh agent's findings + verdict.

**Acceptance**: The review gate verdict is PASS (or its findings are resolved and it re-passes). Only then
  does the doc flip to done and the campaign journal pointer is written. NO PR is opened (per brief).

## Execution

- **TDD strictly enforced** for Unit 2: provenance fixture → RED → record reference → GREEN → mutation-verify.
- Units 1 and 3 write no product logic; their "test" is the full-suite + gate going green.
- Per-PR gates (ALL must pass before a unit is done):
  - strict build 0-warn: `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
  - full `swift test` 0-fail
  - `--uisurfacetest` green
  - `scripts/check-coverage.sh` green (Core/ShellAdapter always; views file after Unit 3)
  - structural guards green (incl. `assertEveryLibFileIsOrdered`)
- ONE commit per sub-unit. NO AI attribution. NEVER stage `SerpentGuide.ouro/` / `default.profraw` /
  `*.actual.txt`.
- Branch: `u5-honest-coverage-gate` (off `origin/main` @ 687b6c7). NO PR (per brief).
- **All artifacts**: save to `./2026-06-26-u5-honest-coverage-gate/`.
- **Fixes/blockers**: spawn a sub-agent immediately — don't ask, just do it (autonomous).
- **Decisions made**: update this doc + the campaign journal pointer immediately; commit right away.
- PR decomposition: **3 PRs, serial.** PR#1 = Unit 1 (extract, pure move, lands FIRST). PR#2 = Unit 2
  (branchless snapshots). PR#3 = Unit 3 (gate wiring + allowlist). Unit R review gate runs after PR#3.

## Decisions Made

- **D1 — file rename:** `WorkbenchViewsAndModel.swift` → `WorkbenchViews.swift` once the VM leaves it.
  Reversible default (the name is now accurate; `orderedLibFiles` + `appSource()` updated in the same PR).
- **D2 — gate granularity:** gate ONLY `WorkbenchViews.swift`, not the whole dir, so the behavioral lib
  files (`WorkbenchViewModel.swift`, `WorkbenchUpdateInstaller.swift`,
  `WorkbenchKeyboardAccessibilityContract.swift`, Terminal* PTY types) are NOT force-100%'d. Reversible
  default: explicit gated-files set in `check-coverage.sh` (alternative: per-file skiplist — chosen at exec).
- **D3 — `TerminalPane` placement:** moves into the NON-gated `WorkbenchViewModel.swift` (it is the
  `@main`-allowlisted live-PTY `NSViewRepresentable`, already outside coverage; keeping it in the gated
  views file would force an allowlist carve for a type that is categorically excluded).
- **D4 — execution mode = spawn** (fully autonomous; fresh review gate before READY).
- **D5 — no PR** (per brief; branch pushed at most, doc + journal pointer committed).

## Progress Log
- 2026-06-26 09:11 Created from the operator's firm-decision brief (Q1=SPLIT, Q2=SNAPSHOT)
