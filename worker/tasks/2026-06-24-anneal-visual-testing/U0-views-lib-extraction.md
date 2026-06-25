# Doing: ANNEAL U0 — Views-Library Extraction (CRITICAL PATH)

**Status**: drafting (running passes; not yet READY_FOR_EXECUTION)
**Execution Mode**: spawn
**Created**: 2026-06-25 00:02
**Campaign**: ../2026-06-24-anneal-visual-testing.md (PERT U0; D-A1, D-A5)
**Artifacts**: ./U0-views-lib-extraction/
**Branch**: `feat/anneal-views-lib-extract` (already checked out; do NOT branch). Off `origin/main` @ 8c2adce; campaign doc @ cab08c8.

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (interactive)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default)

**Chosen: `spawn`.** Each increment below is its own PR through the work-suite (doer → ≥2 adversarial reviewers → merger), serialized at merge per the anneal guardrail. The increments are sequenced (each builds on the prior), so they merge one-at-a-time on a re-greened branch — NOT in parallel.

## Objective

Make the 121 `View` structs in the 21,326-line `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` **importable + coverage-gateable** by extracting them — plus `WorkbenchViewModel` and the four exe-defined types they cannot be separated from — into a new `OuroWorkbenchAppViews` **library target**. The executable becomes a thin shell that depends on the lib. This unlocks `@testable import` (impossible against an `executableTarget`), which the rest of Phase 0 (U1 harness, U2/U3 snapshots, U4 coverage gate) depends on.

**This is a pure structural move. No behavior change. Strict flags green. The grep-guards (~295 at HEAD) stay green throughout.**

> **Baseline verified real (2026-06-25 00:14):** `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` → `Build complete! (50.20s)`, exit 0, zero errors/warnings. The regression-locked plan rests on a confirmed-green baseline. (Unit 0 re-captures this + the test/guard/uisurfacetest/coverage results before any move.)

## Objective boundary — what was discovered (read before planning)

The campaign's stated boundary ("`TerminalPane`/`TerminalSessionController` STAY in the exe") is **infeasible as literally stated** — it would create a `lib → exe` dependency, which SwiftPM forbids. The validation pass found **four `lib → exe` edges** (the MOVING code references types DEFINED in the staying exe):

| Edge | Site(s) | Why it blocks the naive boundary |
|---|---|---|
| **E1 — PTY** | `TerminalFocusView` (9747) holds `var session: TerminalSessionController` (9749) and builds `TerminalPane(session:)` (9757, 8579). `WorkbenchViewModel` owns `@Published var activeSessions: [UUID: TerminalSessionController]` (10597), `func activeSession(for:) -> TerminalSessionController?` (14830), and **constructs + drives** the session: `try TerminalSessionController(plan:…)` (19722), `.terminatePersistentSessionAwaiting()` / `.terminateLocalClient()` (19715-16). | VM (moving) constructs/owns/drives the PTY type (staying). View (moving) embeds the pane (staying). |
| **E2 — Menu bar** | `WorkbenchViewModel.setShowMenuBarStatusItem` calls `WorkbenchMenuBarController.shared.attach(model: self)` / `.setVisible(_:)` (13048-49). | VM (moving) calls the menu-bar controller singleton (staying). |
| **E3 — Login item** | Views hold `@StateObject/@ObservedObject … LoginItemController` (4561, 4661, 4803, 10238). | Views (moving) hold the login-item controller (staying). |
| **E4 — AppKit (NON-edge)** | VM calls `NSApp.terminate(nil)` (11359, 14981, 15023), reads `NSApp.windows`/`keyWindow` (15516-18), registers `NSApplication.willTerminateNotification` observer in `registerTerminationObserver()` (11262-11271, `MainActor.assumeIsolated` + `prepareForTermination()`); root view (`WorkbenchRootView`, 226) uses `WindowChromeConfigurator` (438) + `NSApp.dockTile.badgeLabel` (443, 448); `NSStatusItem`. | **NOT a blocker.** `NSApp`/`NSWindow`/`NSStatusItem`/`NSApplication.willTerminateNotification` are **AppKit framework** symbols — a *library* target can `import AppKit` freely. Only references to types DEFINED IN the executable target block extraction. `WindowChromeConfigurator` (902, exe-defined `NSViewRepresentable`) is referenced by a moving view → it moves with the views (lib-internal, AppKit). The termination observer is already `@MainActor`-correct and moves with the VM unchanged. |

**Resolution (the chosen boundary, an explicit amendment to the campaign — see "Decision: boundary amendment" below):**
Move the **four exe-defined coupled types into the lib** alongside the views+VM. They are AppKit/SwiftTerm types (`NSObject`/`NSViewRepresentable`/`ObservableObject`) the library can host. Keep them honest under the coverage gate by **allowlisting the genuinely-GUI/PTY/login-item code WITHIN the lib** (per D-A5: honest verified allowlist > test contortion). The truly untestable app lifecycle — `@main` arg-dispatch in `main.swift`, `OuroWorkbenchApp: App`, `WorkbenchAppDelegate` — **stays in the exe, genuinely outside the gated lib**, satisfying P1's "`@main`/`App`/`AppDelegate`/`TerminalPane` live outside the gated lib" in spirit (TerminalPane is allowlisted inside the lib rather than physically outside — the amendment).

### Final target layout

```
Sources/
  OuroWorkbenchAppViews/          (NEW library target — gated by U4 later)
    Views/        ← the 121 View structs (split into themed files OR one big file first; see increments)
    WorkbenchViewModel.swift       ← @MainActor ObservableObject (line 10515-~20590)
    Terminal/     ← TerminalPane, TerminalHostView, SingleShotContinuation, TerminalSessionController,
                     CapturingLocalProcessTerminalView, WorkbenchTerminalPalette, TerminalThemeOverride,
                     MailboxFetchResult   (allowlisted: PTY/GUI lifecycle)
    Controllers/  ← WorkbenchMenuBarController, LoginItemController   (allowlisted: NSStatusItem/SMAppService)
    Support/      ← DetailSplitState, DetailPaneID, DetailSplitAxis, HarnessActionResult,
                     WorkspaceFolderDropDelegate, OnboardingBossChoice, BossQuickQuestion,
                     WorkbenchImportApplyResult, WorkbenchToolsInjectionRecorder, WorkbenchMenuCommand,
                     WindowChromeConfigurator   (pure value/presenter types; mostly gateable)
  OuroWorkbenchApp/               (thin EXECUTABLE target — stays outside the gate, genuinely)
    main.swift                     ← top-level @main arg-dispatch (unchanged)
    OuroWorkbenchApp.swift         ← SHRINKS to: OuroWorkbenchApp: App (26) + WorkbenchAppDelegate (20) only
    UISurfaceTest.swift            ← stays in exe but GAINS `import OuroWorkbenchAppViews` (it constructs views directly — see note below)
    WorkbenchUpdateInstaller.swift ← unchanged
Tests/
  OuroWorkbenchAppViewsTests/      (NEW test target — proves @testable import works)
```

### Access-control landmine (pervasive — read before any move)

**52 of the file's types are `private`/`fileprivate`** (most of the 121 views are `private struct …: View`; many helpers are nested or generic `private struct Foo<Content: View>`). This is the dominant mechanical hazard of the whole unit:

- A `private`/`fileprivate` type today is file-scoped within the single `OuroWorkbenchApp.swift`. The instant it (or a sibling it references) moves to a SEPARATE file in the lib, file-private scoping **breaks the cross-file reference** → it must widen to at least `internal` (lib-internal) — and to `public` only if the App scene / AppDelegate / a test / another module needs it.
- **Minimize the public surface**: widen to `public` ONLY the types the exe (App/AppDelegate), `UISurfaceTest.swift`, or the proof test actually touch (`WorkbenchViewModel` + its used members, `WorkbenchRootView`, `WorkbenchMenuCommand`, and whatever the App scene references). Everything else stays `internal` to the lib. Over-publicizing is a reviewable defect (it enlarges the API surface U4 must reason about).
- **`UISurfaceTest.swift` is a THIRD in-exe consumer** (alongside the App scene and AppDelegate). It currently lives in the exe and constructs views + the VM DIRECTLY in-target: `WorkbenchViewModel(paths:)`, `AboutSheet(model:)`, `WorkbenchReleaseUpdateControls(model:showTitle:)`, and many more views via `fittingSize(...)`. After the move it must `import OuroWorkbenchAppViews`, and EVERY view it constructs plus `WorkbenchViewModel.init(paths:)` must be `public`. The `--uisurfacetest` gate therefore transitively PROVES the public surface is sufficient for real construction — treat a `--uisurfacetest` compile failure as the signal that a needed `public` was missed. (The doer should enumerate every view name in `UISurfaceTest.swift` in Unit 0's manifest and mark them `public`-required.)
- **Nested `private` types move with their parent**: e.g. `OnboardingPage` (`fileprivate enum` nested in `WorkbenchOnboardingSheet` 6417), generic helpers like `RecoverySheetSection<Content>` (1033), `HarnessSection<Content>` (1452). These cannot be split from their parent view in a different batch — Unit 0's manifest keeps each parent+its-nested-helpers in ONE batch.
- The doer must, per batch, run the strict-flag build after widening access and fix every "X is inaccessible due to 'private'/'fileprivate' protection level" error by the MINIMUM widening that compiles — never blanket-`public`. Reviewers check that no access modifier was widened beyond what the build required.

## Completion Criteria

(copied from campaign U0 acceptance; gate on OUR products — ignore the pre-existing 3rd-party `SwiftTermFuzz` error)

- [ ] New `OuroWorkbenchAppViews` library target exists; `OuroWorkbenchApp` executable depends on it.
- [ ] `swift build` green under strict flags (`-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`).
- [ ] `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green (our targets).
- [ ] New `OuroWorkbenchAppViewsTests` target exists with **≥1 real XCTest that `@testable import OuroWorkbenchAppViews`s and constructs a view** (proves importability end-to-end — the thing impossible before).
- [ ] **All grep-guards stay green** — `appSource()` retargeted to read the new lib dir in the SAME increment that moves code. (Campaign baseline cited 296 = 130 `source.contains` + 166 `sourceSlice`; **at HEAD on 2026-06-25 the live count is 295 = 129 + 166** — the count drifts with merges, so Unit 0 RE-MEASURES the exact baseline count and every later unit asserts "count unchanged from Unit 0's baseline," NOT a hardcoded 296.)
- [ ] `swift run OuroWorkbench --uisurfacetest` still passes (no behavior change).
- [ ] App still launches and behaves identically (manual/CI app-bundle job green).
- [ ] No behavior change anywhere; the diff is a mechanical move + access-control widening only.
- [ ] Coverage gate (`Scripts/check-coverage.sh`) still green — U0 does NOT add the new lib to `COVERAGE_DIRS` (that is U4), but the lib is STRUCTURED so U4 can add it cleanly with the PTY/controller files allowlisted.
- [ ] 100% test coverage on any genuinely-new logic code U0 introduces (the proof test is structural; if U0 adds a tiny seam/helper, it is tested or allowlisted with justification).
- [ ] All tests pass; no warnings.

## Code Coverage Requirements

**MANDATORY for any NEW logic U0 writes.** U0 is overwhelmingly a *move*, not new code — moved code keeps whatever coverage it had (none gated yet; that is U4). But:

- The retargeted `appSource()` helper (concatenating the lib dir) is NEW logic → it is exercised by the 296 guards that call it (they pass = it works) AND must not introduce an uncovered branch in any gated target. It lives in test code, so it is not coverage-gated, but it MUST be correct (a wrong concatenation silently breaks every guard).
- Any new `public` initializer / seam added purely to cross the module boundary: if it is reachable in a test, it is tested; if it is GUI/PTY-only, it goes on the lib allowlist (prepared for U4) with a verified justification — never silently uncovered.
- No `[ExcludeFromCodeCoverage]`-equivalent shortcuts. The lib's PTY/controller exclusions are honest `coverage-allowlist.txt` entries (added by U4, structured-for here).

## TDD Requirements

**Adapted for a structural-move unit.** Pure TDD ("write failing test, then impl") does not map onto "relocate 121 structs unchanged." The TDD discipline here is **regression-locked refactoring**:

1. **Green baseline first**: before any move, run the full strict-flag suite + grep-guards + `--uisurfacetest` and record the green baseline to `./U0-views-lib-extraction/baseline-green.txt`.
2. **Importability test is written test-first** (Unit 1): write `OuroWorkbenchAppViewsTests` asserting `@testable import OuroWorkbenchAppViews` + constructing a view → it FAILS to compile (lib does not exist yet = red).
3. **Move minimally to green**: each increment makes the smallest move that compiles + keeps EVERY existing test green. Run the full suite after each increment; a single red = stop, do not proceed.
4. **Guard-parity is the safety net** (replaces classic negative-control): after each move, the 296 grep-guards MUST still pass — they are the regression oracle proving the moved source is still readable + unchanged. If a guard goes red, the `appSource()` retarget or a marker changed → fix before proceeding.
5. **No behavior touch**: if any increment is tempted to change logic to make it compile, STOP — that is a behavior change, escalate per the safety valve.

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

### ⬜ Unit 0: Baseline capture + decomposition lock
**What**: Capture the green baseline so every later increment can prove "no regression." Record the EXACT live numbers at HEAD (do not trust the campaign's stale baseline): full strict-flag `swift test` result; grep-guard counts via `grep -rc 'source.contains' Tests/ | awk -F: '{s+=$2} END {print s}'` and the same for `sourceSlice(` (at 2026-06-25 these were 129 + 166 = **295**, NOT the campaign's 296 — record whatever HEAD shows and use THAT as the invariant); `--uisurfacetest` pass; `Scripts/check-coverage.sh` pass; and the exact line ranges of every type that moves (from this doc's layout table). Confirm the four `lib→exe` edges from this doc still match HEAD (the file shifts lines with merges). Re-grep the boundary type line numbers and update the layout if drifted.
**Output**: `./U0-views-lib-extraction/baseline-green.txt` (test/guard/uisurfacetest/coverage results) + `./U0-views-lib-extraction/move-manifest.md` (every type → source line range → destination file). Committed.
**Acceptance**: Baseline file shows all four checks green at HEAD; move-manifest enumerates all 121 views + VM + the 4 coupled types + helpers with current line numbers; the four edges re-confirmed (or safety valve tripped if a NEW edge to an exe-only type appeared).

### ⬜ Unit 1: Empty lib target + importability proof test (the keystone, test-first)
**What**: Create the `OuroWorkbenchAppViews` library target in `Package.swift` (depends on `OuroWorkbenchCore`, `OuroWorkbenchShellAdapter`, `OuroAppShellUI`, `SwiftTerm`). Make `OuroWorkbenchApp` executable depend on it. Create `Tests/OuroWorkbenchAppViewsTests` test target. Write `ImportabilityProofTests.swift` that `@testable import OuroWorkbenchAppViews` and constructs ONE trivial view — pick the smallest pure-render leaf view with no VM dependency (Unit 0's manifest names it). Move ONLY that one leaf view + any tiny value type it needs into the lib (`public` as required). This proves the entire pipeline end-to-end on the minimum surface.
**Acceptance**: `OuroWorkbenchAppViewsTests` compiles (was red — lib did not exist — now green); the proof test constructs the view and asserts something trivial-but-real (e.g. `_ = TheLeafView(…)` does not crash / `fittingSize` or a `Mirror` reflects an expected child). Full strict-flag suite green. `--uisurfacetest` green. **296 grep-guards still green** — because this increment also retargets `appSource()` (see Unit 2 — done SAME PR if any guarded source moved; if the chosen leaf view is unguarded, the retarget is deferred to the first guarded move). Smallest possible diff.

### ⬜ Unit 2: `appSource()` retarget — decouple the grep guards (MUST land with/before the first guarded view moves)
**What**: The grep guards (Unit 0's re-measured count; ~295 at HEAD) live across **43 test files**, each with a private `appSource()` that hardcodes `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` via a `#filePath`-relative `repoRoot()`. The moment a guarded view leaves that file, `source.contains(...)` goes red. Retarget `appSource()` to read **the union of the old file AND the new lib dir** (concatenate `Sources/OuroWorkbenchAppViews/**/*.swift` + the shrinking `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`), so a guard finds its marker regardless of which side the code currently lives on. **Factor the 43 duplicate copies into ONE shared test helper** (e.g. `WorkbenchAppSource.swift` in the test target with a `static func appSource()` + `sourceSlice` overloads) and have all 43 call sites delegate to it — this kills the duplication AND means the retarget is a one-line change, not 43. Verify both `sourceSlice` signatures (`(in source:…)` and the `(from:to:)` self-reading variant in `BossMCPPillVerdictWiringTests`/`DaemonChipAvailabilityWiringTests`) route through the shared reader.
**Acceptance**: All 296 guards green BEFORE any guarded view has moved (retarget is a no-op while everything is still in the old file — proves it is non-breaking) AND green AFTER (it reads both dirs). The shared helper has exactly one `appSource()` implementation; all 43 files reference it. `grep -rc 'private func appSource' Tests/` drops from 43 → 0 (or to 1 shared). No guard count change (still 296). Strict-flag suite green.

### ⬜ Unit 3: Move the coupled core — `WorkbenchViewModel` + the four edge types (the unavoidable larger move)
**What**: This is the one increment that **cannot be a single view** — the VM is referenced by ~all 121 views and itself reaches E1/E2/E3, so it must move together with its hard dependencies. Move into the lib, as ONE reviewable mechanical PR:
- `WorkbenchViewModel` (10515-~20590) — make `public` (type + every member the App scene / AppDelegate / moved views touch; keep the rest `internal`).
- E1 PTY cluster: `TerminalPane`, `TerminalHostView`, `SingleShotContinuation`, `TerminalSessionController`, `CapturingLocalProcessTerminalView`, `WorkbenchTerminalPalette`, `TerminalThemeOverride`, `MailboxFetchResult` (20600-21326+).
- E2: `WorkbenchMenuBarController` (680). E3: `LoginItemController` (10386).
- The support types referenced by the VM: `DetailSplitState`, `DetailPaneID`, `DetailSplitAxis`, `HarnessActionResult`, `WorkbenchImportApplyResult`, `WorkbenchToolsInjectionRecorder`, `OnboardingBossChoice`, `BossQuickQuestion`, `WorkspaceFolderDropDelegate`, `WorkbenchMenuCommand` (+ its `Notification.Name`), `WindowChromeConfigurator`.
- Then the App scene (`OuroWorkbenchApp: App`, stays in exe) `import OuroWorkbenchAppViews` and references `WorkbenchViewModel`/`WorkbenchRootView`/`WorkbenchMenuCommand` as `public` lib types.
- Resolve `@MainActor` across the boundary: `WorkbenchViewModel`, `TerminalSessionController`, and the App scene are ALL already `@MainActor` (10514, 21006, 679) — keep them so; verify no NEW cross-actor hop is introduced (none should be: both sides of every eliminated edge are main-actor). Under `-strict-concurrency=complete`, `public` `@MainActor` members are fine; watch for any `public` API exposing a non-`Sendable` across the module boundary (the PTY types now live INSIDE the lib, so no cross-module non-Sendable hop remains).
- The VM's `registerTerminationObserver()` (11262-11271) registers an `NSApplication.willTerminateNotification` observer (`MainActor.assumeIsolated` + `prepareForTermination()`). It moves with the VM **unchanged** — AppKit imports into the lib, and the observer is already main-actor-correct. The doer must confirm the observer still fires identically post-move (the app-bundle CI job + a manual quit-detach check), since this is the one place the VM touches the real app-termination lifecycle.
**Output**: VM + 4 edge types + helpers relocated; `OuroWorkbenchApp.swift` shrinks toward just `App` + `AppDelegate`; `appSource()` (Unit 2) already reads the lib dir so guards follow the code.
**Acceptance**: Strict-flag suite green; `--uisurfacetest` green; **296 guards green** (markers now found in the lib dir); app launches identically; NO logic line changed (diff is move + `public` + `import` only — reviewer verifies via `git diff` that no statement inside any moved body changed). If strict-concurrency forces a real isolation change (not just an annotation move) or any behavior touch → **SAFETY VALVE: stop + report**.

### ⬜ Unit 4: Move the remaining views in themed batches (mechanical, repeatable)
**What**: With the VM + edges in the lib, the remaining ~119 views are now movable in small themed batches — **each batch is its own atomic PR** (own commit, own full-suite run, own ≥2-reviewer gate, serialized merge). Unit 0's move-manifest assigns every view to exactly one batch so batches are non-overlapping. Suggested batches (the doer may re-slice per the manifest, but each must be one reviewable session): **4a** sidebar + tab-strip (surfaces A/B; `WorkbenchSidebarView`, `WorkspaceSidebarRow`, `SidebarWorkspaceEmptyRow`, `WorkspaceTabStrip`, `InlineRenameEditor`); **4b** recovery + archived (surface D; `RecoverySheet`, `NeedsYouEntryRow`, `RecoverableEntryRow`); **4c** onboarding (surface E; `WorkbenchOnboardingSheet` 6412 — NOTE: `OnboardingPage` is its nested `fileprivate enum` at 6417, NOT a View; the views are `OnboardingPageContent` 6654, `OnboardingBossChoiceView` 6772, `OnboardingReadinessView` 7057, `FirstRunBootstrapView`, `OnboardingRepairStepRow` 7219, etc. — the nested enum + the sheet's other `private` helpers move together as one unit); **4d** proposal card (surface F; `BossProposalCardList`, `BossProposalCard`, `BossProposalItemRow`); **4e** boss/agents pane views; **4f** settings views; **4g** `WorkbenchRootView` + `SessionDetailView` + `TerminalFocusView` + remaining misc (the pane-embedders that touch `TerminalPane` — already lib-internal after Unit 3, so these move cleanly here). Each batch: cut the view structs into themed files under `OuroWorkbenchAppViews/Views/`, widen access to `public` only where the App scene or another module needs them (most stay `internal` to the lib), keep everything else unchanged.
**Output**: All 121 views in the lib, themed across batch files; `OuroWorkbenchApp.swift` reduced to the two genuine lifecycle types.
**Acceptance**: After EACH batch PR: strict-flag suite green, 296 guards green, `--uisurfacetest` green, no behavior change (reviewer confirms via `git diff` the batch is move + `public` + `import` only). Final state after the last batch: `grep -c ': View' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` == 0; the file contains only `OuroWorkbenchApp: App` + `WorkbenchAppDelegate`. (Batches may be developed in parallel as WORK but MERGE one-at-a-time, each rebased + re-greened, per the anneal serialized-merge guardrail.)

### ⬜ Unit 5: Coverage-gate readiness (structure only — gating is U4 of the campaign)
**What**: Do NOT add `OuroWorkbenchAppViews` to `COVERAGE_DIRS` (that is campaign-U4, post-snapshots). U0's job: confirm the lib is STRUCTURED so campaign-U4 can add it cleanly. Verify: the PTY cluster + `WorkbenchMenuBarController` + `LoginItemController` + `WindowChromeConfigurator` are in clearly-named files (`Terminal/`, `Controllers/`, `Support/`) so their future allowlist entries are obvious and honest; the `@main`/`App`/`AppDelegate` are genuinely OUTSIDE the lib (in the exe) and thus never need a lib allowlist entry. Write `./U0-views-lib-extraction/coverage-readiness.md` listing exactly which lib files will need allowlist entries in campaign-U4 and the verified GUI/PTY/login-item justification for each (so U4 does not have to re-derive them).
**Output**: `coverage-readiness.md` — the U4 allowlist plan, pre-justified.
**Acceptance**: `Scripts/check-coverage.sh` still green (lib NOT yet in `COVERAGE_DIRS`, so the gate is unchanged — proving U0 did not regress the existing gate). The readiness doc names every future-allowlisted lib file with a verified justification; `@main`/`App`/`AppDelegate` confirmed outside the lib.

### ⬜ Unit 6: Final verification + campaign journal update
**What**: Full green sweep on the final branch state: strict-flag `swift test`, `--uisurfacetest`, `Scripts/check-coverage.sh`, all 296 guards, app-bundle build. Diff-audit: confirm the ENTIRE branch diff is move + access-control + import only (no logic statement changed) — produce `./U0-views-lib-extraction/diff-audit.md` summarizing the move and asserting zero behavior change with evidence (e.g. `git diff --stat`, spot-checked moved bodies). Update the campaign doc's Iteration log + PERT to mark U0 done and record the boundary amendment (D-A5 refinement: TerminalPane lives in-lib-allowlisted, not physically-outside).
**Output**: `diff-audit.md`; campaign doc updated + committed.
**Acceptance**: Every gate green; diff-audit shows no behavior change; campaign doc reflects U0 complete + the amendment; U1 (harness) is now unblocked (it can `@testable import OuroWorkbenchAppViews`).

## Decision: boundary amendment (records the deviation from campaign as-written)

**Campaign said**: `@main`/`App`/`AppDelegate`/`TerminalPane` live OUTSIDE the gated lib.
**Reality found**: `TerminalPane`/`TerminalSessionController` are inseparable from the VM+views (VM constructs/owns/drives the PTY; `TerminalFocusView` embeds the pane) — keeping them in the exe creates a forbidden `lib→exe` dependency.
**Amendment**: `TerminalPane` (+ PTY cluster) + `WorkbenchMenuBarController` + `LoginItemController` move INTO the lib but are **allowlisted within it** (honest GUI/PTY/login-item justification, per D-A5). `@main`/`App`/`AppDelegate` stay genuinely outside (in the exe), so P1's intent — "lifecycle code that gets allowlisted lives outside the gated lib for the truly-untestable part" — holds for the truly-untestable `@main`/`App`/`AppDelegate`, and the PTY/controllers are honestly allowlisted rather than test-contorted. This is a deliberate, recorded refinement of D-A5, NOT a silent scope change. (No human gate available — operator asleep; recorded here + in campaign for audit. If the operator prefers the protocol-seam alternative — abstract the PTY behind a lib-side protocol so `TerminalSessionController` can stay in the exe — that is a larger, behavior-touching change; flagged as the fallback, not chosen, to honor "smallest safe increment.")

## Execution

- **Regression-locked refactoring** (see TDD Requirements): green baseline → smallest move → full suite + 296 guards + `--uisurfacetest` green → next. A single red = stop.
- Commit after each increment; push after each unit; full strict-flag suite before marking a unit done.
- Each increment is its own PR through the work-suite (doer → ≥2 adversarial reviewers → merger). **Serialized merges** (anneal guardrail): rebase on latest branch → CI green → merge → next. The reviewers specifically check: (a) `git diff` shows NO logic statement changed inside any moved body; (b) the 296-guard count is unchanged; (c) no `public` exposes a non-`Sendable` across the boundary under strict-concurrency.
- **All artifacts** → `./U0-views-lib-extraction/`.
- **Blockers/fixes**: spawn a sub-agent immediately — do not ask.
- **SAFETY VALVE** (campaign-mandated): if any increment cannot be done without breaking strict-concurrency-complete (a real isolation change, not an annotation move), changing behavior, or only as an unreviewable big-bang → STOP and report the specific blocker. The operator's fallback is an in-binary AX dump without extraction. Unit 3 is the most likely valve point.

## Progress Log
- 2026-06-25 00:12 Created from campaign doc U0 (Pass 1 first draft). Folded in independent Explore-agent boundary corroboration (NSApplication.willTerminateNotification observer detail).
- 2026-06-25 00:12 Pass 2 granularity: sliced Unit 4 into atomic themed batch PRs (4a–4g), each its own reviewable/mergeable session.
- 2026-06-25 00:13 Pass 3 validation (against HEAD source): corrected guard count (live 295 = 129+166, not campaign's 296 — made the invariant "re-measured at Unit 0," not hardcoded); corrected `OnboardingPage` (it is a nested `fileprivate enum`, not a View — real onboarding views are `WorkbenchOnboardingSheet`/`OnboardingPageContent`/etc.); added the pervasive access-control landmine (52 `private`/`fileprivate` types, mostly views, all needing minimal widening on move); added `UISurfaceTest.swift` as a third in-exe consumer that must `import` the lib + drives the `public` surface. Verified all 18 other named surface structs resolve to their cited lines; confirmed `SwiftTermFuzz` is the ignorable 3rd-party target. Kicked off strict-flag baseline build to confirm green baseline is real.
- 2026-06-25 00:16 Pass 4 quality: confirmed all 7 unit headers carry `⬜`, zero TBD/TODO, every unit has What+Acceptance, completion criteria testable, coverage reqs present. Fixed stale "296" in Unit 2 header + objective; recorded the VERIFIED-GREEN baseline (build exit 0, 50.20s, no warnings under strict flags); set Status to explicit `drafting`.
- 2026-06-25 00:18 Pass 5 planning-coverage check: wrote `./U0-views-lib-extraction/planning-coverage-checklist.md` mapping all 15 campaign-U0 requirements + 10 task-brief safety constraints to doing units. Full coverage confirmed, zero gaps (the lone deviation is the recorded D-A5 amendment, not a dropped requirement).
