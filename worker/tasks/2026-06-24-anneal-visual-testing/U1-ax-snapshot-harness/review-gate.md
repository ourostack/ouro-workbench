# U1 doing-doc — fresh-sub-agent review gate (autonomous, operator asleep)

A fresh general-purpose sub-agent with NO authoring context reviewed the U1 doing doc against the
campaign rubric (P1–P7), the brief's scope/out-of-scope, the constraints, and harness-shape
feasibility. It empirically reproduced two claims (the SwiftPM unhandled-file warning; the two
`TimelineView` sites). Verdict before fixes: **NOT READY — 2 surviving HIGH.** Both resolved below;
re-verdict: **READY.**

## Findings + resolutions

### F-1 (HIGH) — `__Snapshots__/*.txt` emits a SwiftPM "unhandled file" build-plan warning; `#filePath` does not suppress it; suppressing needs a `Package.swift` `exclude:` (which the draft's D-U1-2 claimed to avoid, and the draft falsely said it would "error").
**Empirically verified by reviewer** (probe `.txt` under the test target → unhandled-file warning;
build exits 0, i.e. NOT promoted to error by `-warnings-as-errors`).
**Resolution:** rewrote **D-U1-2** to state the warning IS emitted, is a build-PLAN (not compiler)
warning, is NOT promoted to error, and is silenced by `exclude: ["__Snapshots__"]` on the
`OuroWorkbenchAppViewsTests` test target — the ONE allowed `Package.swift` edit (touches no
`dependencies`, no `COVERAGE_DIRS`, no allowlist). Added: a Completion Criterion ("NO unhandled-file
warning"), a Unit 0 step to add the `exclude:` and confirm the warning is gone, and a Unit 5 gate
grep for its absence. Dropped the false "would error / zero churn" claim. **CLOSED.**

### F-3 (HIGH) — the `TimelineView` `context.date` freeze was declared "REQUIRED INFRA in this unit" with a red Unit 2a assertion, but no host-level seam exists to make it pass, and Unit 2b's fallback let the doer delete the requirement → contradictory + gameable.
**Correct.** SwiftUI gives no public override for a `TimelineView`'s `context.date`; freezing needs
a view-source touch at the two sites (`:2166`, `:3775`).
**Resolution:** rewrote **D-U1-5** to split the two clock leaks: (a) the FORMATTER clock
(`coarseDescription(since:now:)`) IS injectable and is OWNED + proven by U1; (b) the `TimelineView`
`context.date` has NO seam → the view-source touch is **explicitly DEFERRED to U2** (the unit that
snapshots the surfaces embedding it). U1 writes NO red test requiring a host-level `TimelineView`
freeze (un-passable = gameable). Updated Unit 2a/2b/2c, the API-shape "determinism is injected"
list, the Completion Criteria, and L1 to match — the deferral is now a recorded, named U2
prerequisite, not "infra delivered in U1." **CLOSED.**

### F-2 (MEDIUM) — no repo precedent for an NSAccessibility walk; Unit 0 spike is load-bearing with no go/no-go fallback.
**Resolution:** Unit 0 now records an explicit GO/NO-GO, tries fallbacks (walk `host.view` vs window
AX root vs `accessibilityChildren(forSubrole:)`), and STOPS + surfaces to the operator if NO path
exposes a readable tree (the one true feasibility wall) — no faked tree. **CLOSED.**

### F-4 (MEDIUM) — "100% coverage via TDD+inspection, not the gate" — sound, honestly caveated.
No change required; reviewer agreed the test target isn't in `COVERAGE_DIRS` so the mechanism is
TDD + manual branch review, and the snapshot-match assertion is honestly flagged as record-then-
compare (not TDD-red). **ACCEPTED as-is.**

### F-5 (NIT) — "shared protocol both NSView and the fake satisfy" needs an ADAPTER, not retroactive conformance (`[Any]?`/`Any?` untyped).
**Resolution:** Unit 1b + the API-shape Pieces §1 + Unit 0 now say "adapter" (maps the real AX
surface to the `AXNode` protocol; the fake conforms directly). **CLOSED.**

### F-6 (LOW) — steer the 2nd proof view explicitly to the internal, VM-free `SidebarWorkspaceEmptyRow`; don't offer the VM-coupled `:3177` site as an equal option.
**Resolution:** the doc now LOCKS `SidebarWorkspaceEmptyRow` as the chosen 2nd proof view (verified
`internal` → `@testable`-reachable; VM-free; explicit AX label; no `TimelineView`), with
`InlineRenameEditor` demoted to a reversible fallback. Added the caveat that 42 of ~75 lib views are
`private` and NOT reachable. **CLOSED.**

## Re-verdict
All HIGH closed; MEDIUMs resolved or accepted-with-honest-caveat; NITs folded in. **READY_FOR_EXECUTION.**
