# C0 — Edge-case spike pack: per-recipe GO/NO-GO + proven fixture snippets

The C0 spike proves the **6 provenance recipes** (+ the Q1 `WorkbenchRootView` host
spike + the Q3 `ProviderConfigSheet` `NSFullUserName()` determinism spike) ONCE on the
cheapest representative of each, so every later cluster (C1–C11) reuses a PROVEN recipe
instead of re-discovering it. Each representative is the **first member of its home
cluster** (no double-count — see the doing doc C0 note): it counts ONCE in that cluster's
tally and is real logic-bearing coverage, not throwaway.

Discipline applied per representative (the doing doc's TDD + gates):
strict TDD (red/record → green compare) → **mutation-verify** (mutate the actual rendered
branch → snapshot RED → revert byte-identically → green; SINGLE-ACTOR SERIAL) →
determinism (byte-identical twice + `!contains("/Users/")`) → provenance through the REAL
seam. One commit per sub-unit, `test(views): …`.

Baseline views-lib coverage @ branch HEAD (measured `xcrun llvm-cov export …
Sources/OuroWorkbenchAppViews`, the canonical per-cluster command):
**13.01% region (760/5843) · 13.92% line (4450/31957)**.
(The doing doc's stated "16.02% region / 13.02% line" is an earlier, differently-scoped
llvm-cov invocation; this file uses ONE consistent command so the running % is
apples-to-apples cluster-over-cluster.)

---

## Recipe 1 — real-target chip fixture → `GitBranchChip` (home cluster C1) ✅ GO

**The risk it de-risks:** the audit's "look-covered-but-AREN'T" class (AN-003). The chip
is constructed inside `TerminalAgentRow`, so it LOOKS covered — but no LIVE sidebar
fixture ever drives `gitStatus.isRepo`, so its `if let label = status.branchLabel` body
never renders in any existing reference (a false-coverage illusion).

**Proven seam (P2):** `GitSessionStatus` is provenance-built through its REAL producer
`GitSessionStatus.parse(porcelainV2:)` — fed canonical `git status --porcelain=v2
--branch` output (the exact bytes `GitStatusReader` shells out for). We build the
PORCELAIN, not the struct, so the chip renders the same value the live git reader yields.
The chip is then instantiated DIRECTLY via its `View` initializer (the legitimate leaf
seam — the SU3r precedent; P2 forbids hand-assembling serializer OUTPUT / model STATE, not
instantiating a `View` with a real Core value).

```swift
// Build the chip's status by PARSING real porcelain (the producer):
let status = GitSessionStatus.parse(porcelainV2: """
    # branch.oid abcdef0123456789
    # branch.head main
    # branch.ab +2 -1
    1 .M N... 100644 100644 100644 abc def file.txt
    """)
GitBranchChip(status: status)            // direct leaf seam
GitBranchChip(status: .notARepo)         // the real-target gate → empty body
```

**Enumerated state-set + recorded references** (`__Snapshots__/GitBranchChip.*.txt`):
| state | reference tree (whitelisted nodes) |
|---|---|
| `clean` | `Image "arrow.triangle.branch"` · `Text "main"` |
| `dirty` | `Image "arrow.triangle.branch"` · `Text "feature/login"` (dirty `Circle` is geometry-only → dropped; the STATE is asserted via `status.dirty` provenance + the negative control) |
| `aheadBehind` | glyph · `Text "main"` · `Text "↑2↓1"` |
| `detached` | glyph · `Text "(detached)"` |
| `notARepo` | **EMPTY** — `branchLabel == nil` → `if let` body never renders (the gate the illusion hid) |

**Determinism (P3):** porcelain carries no path/clock/UUID; byte-identical twice;
`!contains("/Users/")`; the `.help(...)` tooltip is dropped by the host (AN-004).

**Mutation-verify (P2):** mutated `Text(label)` → `Text("MUTANT")` in `GitBranchChip.body`
→ **5 snapshot refs + the negative control went RED** (the negative control's
`XCTAssertNotEqual` correctly collapsed when all branches render the same constant →
non-vacuous) → reverted byte-identically → green. **CAUGHT.**

**a11y-id:** none needed (every state's tree is already distinct; no two byte-identical
nodes defeat a control).

**GO.** Recipe sound; C1 reuses `GitSessionStatus.parse`-porcelain → chip-leaf for
`GitBranchChip` + the same porcelain-producer seam where the row accepts `gitStatus:`.
