# U0 Units 0–2 — Diff Audit (low-risk scaffolding PR)

**Scope:** Units 0, 1, 2 only (the low-risk scaffolding). Unit 3 (the VM + 4-edge-types move)
and Units 4–6 are deliberately OUT of this run — separately, harder-gated PRs.

**Branch:** `feat/anneal-views-lib-extract` · **Base:** `origin/main` @ `8c2adce`

## Commits

| Unit | SHA | Subject |
|---|---|---|
| 0 | `7242886` | docs(doing): complete Unit 0 — baseline capture + move manifest + catalogs |
| 1 | `459cc30` | feat(views): Unit 1 — OuroWorkbenchAppViews lib + importability proof test (keystone) |
| 2 | `9a95f8a` | refactor(tests): Unit 2 — retarget appSource() to the lib dir + de-dup 43 copies |

## Source diff (vs 8c2adce) — move + access-control + import ONLY

```
 Package.swift                                   | 26 ++  (new lib target + test target + exe dep wiring)
 Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift | 14 +-  (+1 import; -13 = moved DashboardRowLabel struct)
 Sources/OuroWorkbenchAppViews/Views/DashboardRowLabel.swift | 29 ++  (moved struct, body byte-identical, +public init)
```

- **No logic statement changed inside any moved/retained body.** `DashboardRowLabel.body` in the
  lib is byte-identical to the original (`Label(...).font(.caption.weight(.semibold)).lineLimit(1)
  .frame(width: 132, alignment: .leading).fixedSize(horizontal: true, vertical: false)`).
- Access widening is the minimum to cross the module boundary: `private`→`public` on the type +
  its two stored props + a new `public init(title:systemImage:)`. Nothing else widened.

## Test diff (vs 8c2adce) — pure helper de-dup, zero assertion changes

- 43 files: per-file `appSource()`/`sourceSlice()`/`repoRoot()` helper defs removed; all call sites
  rerouted to the shared `WorkbenchAppSource`. **0 `XCTAssert` lines added, 0 removed** across these
  files (verified by `git diff … | grep -c XCTAssert` = 0 both directions) — no assertion/marker/test
  logic touched.
- New: `WorkbenchAppSource.swift` (shared union reader, deterministic adjacency-preserving concat)
  + `WorkbenchAppSourceRetargetTests.swift` (the no-op proof: union contains both an exe-side marker
  and the lib-side marker; every lib file explicitly ordered; self-reading slice routes through the
  shared reader).

## Gates (all green, from the committed branch state)

| Gate | Result |
|---|---|
| `swift build` strict (`-warnings-as-errors -strict-concurrency=complete`) | exit 0, 0 warn (our products; SwiftTermFuzz 3rd-party out of scope) |
| `swift test` strict | **2845** tests / 0 failures / 1 skipped, exit 0 (baseline 2841 + Unit-1 proof + Unit-2 ×3) |
| All ~257 OuroWorkbenchApp grep-guards | GREEN — every one still executes + passes via the shared union reader (no-op retarget proven) |
| Importability proof (`@testable import OuroWorkbenchAppViews` + construct `DashboardRowLabel`) | PASS — the thing impossible against an executableTarget |
| `swift run OuroWorkbench --uisurfacetest` | exit 0, all "ok" — no behavior change |
| `Scripts/check-coverage.sh` | PASS 149/151 @ 100% (2 allowlisted) — unchanged from baseline; new lib NOT gated (that's campaign-U4) |

## Hygiene

- `SerpentGuide.ouro/` never staged (left untracked throughout).
- No stray `default.profraw` staged.
- No Co-Authored-By / AI-attribution in any commit.

## Key risk REFUTED this run

The "first AppKit/SwiftUI-importing library target in the package" concern (Unit 1) is **refuted,
not a blocker** — `OuroWorkbenchAppViews` compiles clean under the full strict flag set. The C1
declaration-order hazard is pre-mitigated structurally in the shared reader (deterministic
declaration-order concat + `assertEveryLibFileIsOrdered()`), ready for Unit 3's first guarded split.
