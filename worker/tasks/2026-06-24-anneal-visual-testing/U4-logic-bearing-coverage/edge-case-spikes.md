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

---

## Recipe 2 — standalone menu → `TerminalRowContextMenu` (home cluster C1) ✅ GO

**The risk it de-risks:** edge-case playbook #5 — ViewInspector's synchronous `findAll`
does NOT descend a parent's `.contextMenu { }` content, so a context-menu view can never
be reached by snapshotting its host row. All five named menu/popover views are top-level
`View` structs (verified first-hand), so they're snapshotted STANDALONE via their own
initializer.

**Proven seam (P2):** the menu's `entry` + `model` are provenance-built via the REAL store
seam (`WorkbenchStore.save(state)` → fresh `WorkbenchViewModel.load()`), the same
`SidebarSurfaceStateSetTests.makeVM` dual-injection (AN-001: temp `agentBundlesURL` into
BOTH the registrar AND the inventory). The menu is then instantiated standalone with the
LOADED entry (re-read through `model.state.processEntries`).

```swift
let model = try makeVM(state: state(entry: entry(kind: .shell)))   // real store seam
let loaded = model.state.processEntries.first!                     // loaded provenance
TerminalRowContextMenu(entry: loaded, model: model)                // standalone leaf
```

**Enumerated state-set + recorded references** (`__Snapshots__/TerminalRowContextMenu.*`):
| state | distinguishing nodes |
|---|---|
| `inactiveCustom` (`.shell`, not archived, no live session) | "Launch" · full custom block · ends "Archive Session" |
| `archivedCustom` (`.shell`, archived) | custom block with "**Restore**" (not Archive) |
| `nonCustom` (`.command`) | **NO custom block** — stops at "Open Working Directory" |

(`activeSession == nil` in a fresh VM → "Launch" not "Restart"; the single loaded project
"Home" appears in the Move-to-Workspace submenu — deterministic.)

**Determinism (P3):** fixed entry/project/workspace ids + fixed `/tmp/u4` working dir +
fixed boss name "boss"; no clock; byte-identical twice; `!contains("/Users/")`.

**Mutation-verify (P2):** swapped the `if entry.isArchived` "Restore" label →
"Archive Session" (collapsing the archive/restore branch) → **`archivedCustom` snapshot +
the negative control went RED** → reverted byte-identically → green. **CAUGHT.**

**a11y-id:** none needed (every label string is distinct).

**GO.** Recipe sound; C1/C3 reuse standalone instantiation for
`WorkspaceRowContextMenu`/`WorkspaceTabContextMenu`/`AutonomyStatusPopover`/`BossAgentNamePopover`.

---

## Recipe 3 — path-leak (hard) → `AgentInspectorPanel` (home cluster C7) ✅ GO

**The risk it de-risks:** edge-case playbook #3 — `AgentInspectorPanel` renders
`Text(agent.bundlePath)` (`:8181`) + `Text(agent.configPath)` (`:8192`) as VISIBLE
content. The host whitelist can NOT strip a content `Text` (unlike the `.help` drop), and
`OuroAgentInventory.scan` always sets `bundlePath: bundleURL.path` (an ABSOLUTE machine
path — `/Users/<name>/…` or a `/var/folders/<random>/…` temp path) → a scanned record
would leak. **The FIXTURE is the only fix:** construct the `OuroAgentRecord` with FIXED,
RELATIVE paths, defended by `!tree.contains("/Users/")` (and `!contains("/var/folders/")`).

**Proven seam (P2):** `OuroAgentRecord` is a `public` Core value type; constructing it with
deterministic relative paths IS the real seam (same class as building a real `ProcessEntry`
or parsing a real `GitSessionStatus` — P2 forbids hand-assembling serializer OUTPUT, not
instantiating a real model VALUE). The panel's `model` is the `makeVM` dual-injection seam;
`registration` (the panel's one `if let` branch) is a real `BossWorkbenchMCPRegistrationSnapshot`.

```swift
OuroAgentRecord(name: "fixture-agent",
                bundlePath: "AgentBundles/fixture-agent.ouro",            // fixed/relative
                configPath: "AgentBundles/fixture-agent.ouro/agent.json", // fixed/relative
                status: .ready, detail: "ready")
AgentInspectorPanel(agent: record, model: try makeVM(), registration: nil /* or a fixed snapshot */)
```

**Access-widening (SU-E precedent):** `AgentInspectorPanel` was `private struct` → widened
to `internal` (visibility-only, zero behavior). The structural guard in
`AgentDetailReadinessWiringTests.agentTitleStripDecl()` anchored its slice on the literal
`"\nprivate struct AgentInspectorPanel: View {"` → its `to:` marker was updated to
`"\nstruct AgentInspectorPanel: View {"` (the same minimal marker-retarget the SU-E
widenings established; the `AgentTitleStrip` content assertions are unaffected).

**Enumerated state-set + references** (`__Snapshots__/AgentInspectorPanel.*`):
| state | tree |
|---|---|
| `noRegistration` | shippingbox · `Text "AgentBundles/fixture-agent.ouro"` · doc · `Text ".../agent.json"` · info · `Text "ready"` |
| `withRegistration` | …above… + link · `Text "MCP: registered"` (the `if let registration` arm) |

**Determinism (P3):** the relative paths render verbatim; `!contains("/Users/")` AND
`!contains("/var/folders/")`; byte-identical twice.

**Mutation-verify (P2):** mutated `Text(agent.bundlePath)` → `Text("MUTANT")` → **both
snapshots went RED** (+ the path-leak-defense `contains("AgentBundles/…")` would fail) →
reverted byte-identically → green. **CAUGHT.**

**a11y-id:** none needed.

**GO.** Recipe sound; C7 reuses fixed/relative `OuroAgentRecord` paths for
`AgentStatusCard`/`OuroAgentRowView` (same visible-`Text` path vectors) + AN-001; C9 reuses
the same fixed-path discipline for the transcript/launch-command leaks (`/tmp/u4`).
