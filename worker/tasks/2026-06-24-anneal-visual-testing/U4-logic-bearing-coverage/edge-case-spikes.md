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

---

## Recipe 4 — fixed-timestamp clock → `BossWatchStatusView` (home cluster C10) ✅ GO

**The risk it de-risks:** edge-case playbook #4 — `BossWatchStatusView` renders
`Text(change.occurredAt.formatted(date:.omitted, time:.standard))` (`:7875`), an absolute
`Date` baked into a STRING at view construction. Unlike the `TimelineView` clock (which has
the injectable `now:`, U2), this one has NO injection seam — a `Date()`-built summary would
render a wall-clock-dependent string. **The fixture pins the clock:** one CANONICAL FIXED
`Date` epoch fed to the producer + the host's UTC-TZ pin → byte-identical formatted string.

**Proven seam (P2):** change summaries are produced by the REAL Core producer
`WorkspaceChangeSummarizer.summarize(previous:current:occurredAt:)` (fed two real
`WorkspaceState`s with a rename diff + the FIXED `occurredAt`), then assigned to
`model.bossWatchChangeSummaries` (the SAME `@Published` the production boss-watch ingest
sets — direct injection IS the real seam here). `model` via the `makeVM` dual-injection.

```swift
static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)   // 2026-01-02 03:04:05 UTC
let summaries = WorkspaceChangeSummarizer().summarize(
    previous: stateWith("old-name"), current: stateWith("new-name"), occurredAt: fixedDate)
model.bossWatchChangeSummaries = summaries          // the @Published the ingest path sets
```

**Enumerated state-set + references** (`__Snapshots__/BossWatchStatusView.*`):
| state | tree |
|---|---|
| `enabledNoChanges` | `Text "Boss Watch"` · `Image "eye.fill"` · `Text "watching"` |
| `disabledNoChanges` | `Text "Boss Watch"` · `Image "eye"` · `Text "paused"` |
| `withChanges` | …enabled… + `Text "03:04:05"` (the FIXED-TZ timestamp) · `Text "Session renamed"` · `Text "old-name is now new-name"` |

(`bossWatchLastRunAt = nil` keeps the STATUS LINE clock-free — "watching"/"paused"; the
ONLY clock value is the producer-driven change-row timestamp, pinned by `occurredAt`.)

**Determinism (P3):** `Text "03:04:05"` is byte-identical twice under the host UTC pin;
`!contains("/Users/")`. (The summary's `id` UUID is NOT rendered by the view.)

**Mutation-verify (P2):** mutated `Text(change.occurredAt.formatted(...))` → `Text("MUTANT")`
→ **the `withChanges` snapshot went RED** (the one carrying the timestamp) → reverted
byte-identically → green. **CAUGHT.**

**a11y-id:** none needed.

**GO.** Recipe sound; C10/C11 reuse the fixed-`Date` constant for
`BossActionReceiptStrip`/`ActionLogView`/`HabitHistoryPanelView`/`HarnessStatusSheet`
(`observedAt`) timestamped rows; the same producer-or-`@Published` seam applies.

---

## Recipe 5 — AN-001 + fixed `OuroAgentRecord` → `OuroAgentManagerView` (home cluster C8) ✅ GO

**The risk it de-risks:** edge-case playbook #2 / the AN-001 SOURCE defect. A VM built with
the default inventory scans the REAL `~/AgentBundles` in its initializer
(`refreshOuroAgents()`), leaking machine-local agent NAMES into `model.ouroAgents` → the
rendered tree (P3). The recipe pins it twofold: (1) inject a temp `agentBundlesURL` into
BOTH the registrar AND the inventory (non-existent temp dir → `scan() == []`) so the init
scan is hermetic; (2) drive `model.ouroAgents = [fixed OuroAgentRecord]` directly (the
SU-E3 seam) with FIXED names + relative paths.

**Proven seam (P2):** `model.ouroAgents` is the SAME `@Published` the inventory scan
populates — direct injection of `public OuroAgentRecord` values IS the production seam. The
view's `.task { model.refreshOuroAgents() }` does NOT run under the synchronous `inspect()`,
so the injected agents survive the snapshot. `model` via the `makeVM` dual-injection.

```swift
return WorkbenchViewModel(paths: paths,
    bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: tempAgentBundles), // AN-001
    ouroAgentInventory: OuroAgentInventory(agentBundlesURL: tempAgentBundles))               // AN-001
model.ouroAgents = [OuroAgentRecord(name: "alpha-agent",
    bundlePath: "AgentBundles/alpha-agent.ouro", configPath: ".../agent.json",
    status: .ready, detail: "ready")]                                                        // SU-E3 seam
```

**Enumerated state-set + references** (`__Snapshots__/OuroAgentManagerView.*`):
| state | distinguishing nodes |
|---|---|
| `empty` | "no local agents" status line · `Text "No Ouro agents are installed on this machine yet."` |
| `one` | one row: `Text "alpha-agent"` · `Text "ready"` (no boss pill) |
| `many` | two rows; the boss-matching row carries the `Text "boss"` pill; status "2 local, 0 ready; boss boss-agent" |

(The boss row's MCP-pill "registration error" comes from the temp registrar — deterministic
& hermetic, asserted byte-identical-twice.)

**Determinism (P3):** fixed agent names + relative paths + fixed boss name; byte-identical
twice; `!contains("/Users/")`.

**Mutation-verify (P2):** inverted the `if model.ouroAgents.isEmpty` gate → **all 3
snapshots + the negative control went RED** → reverted byte-identically → green. **CAUGHT.**

**a11y-id:** none needed (each row's `View label="<name>, ready"` a11y label is already
distinct).

**GO.** Recipe sound; C8 reuses the dual-injection + `model.ouroAgents` direct seam for
`OuroAgentRowView`/`AgentHomeEmptyState`; C3/C7 reuse AN-001 for boss-choice/autonomy name
reads + the agent-detail family.

---

## Recipe 6 — live-terminal-arm carve-out → `SessionDetailView` inactive arm (home cluster C9) ✅ GO

**The risk it de-risks:** edge-case playbook #6 / allowlist-candidate #3. `SessionDetailView`
(`:8477`) branches `if let session = model.activeSession(for: entry)` → the LIVE arm embeds
`TerminalPane(session:)` (the live PTY, `@main`-allowlisted, outside coverage) `else` →
`InactiveTerminalSurface`. The LIVE arm is non-snapshottable in-process. We CARVE it out
(allowlist that arm) and snapshot the INACTIVE arm via the REAL `activeSession == nil` seam:
a VM with NO launched session → the `else` branch renders. (Not a fabricated unreachable
state — the `activeSession == nil` is the GENUINE state a fresh VM produces; AN-006 discipline.)

**Path-leak (verified):** the inactive arm renders `Text(model.launchCommand(for: entry))`
(`:9381`, built from the entry's executable + working dir). The fixture uses a FIXED `/tmp/u4`
working dir (the SU3 `/tmp/su3` precedent), defended by `!tree.contains("/Users/")`.

**Proven seam (P2):** VM via the `makeVM` dual-injection store seam; the `ProcessEntry` is
persisted + loaded through the real store; no session is ever launched →
`activeSession(for:) == nil` is the genuine seam state.

**Enumerated state-set + references** (`__Snapshots__/SessionDetailView.*`):
| state | distinguishing nodes (the inactive arm) |
|---|---|
| `readyToLaunch` | `Image "terminal"` · `Text "Ready to launch"` · `Text "Launch"` · `Image "play.fill"` · `Text "$"` · `Text "/bin/zsh"` |
| `archived` | `Image "archivebox"` · `Text "Archived"` · `Text "Restore this session…"` · `Text "Restore"` |

(No `TerminalPane` node in EITHER tree → the live arm is provably never constructed —
the carve-out holds.)

**Determinism (P3):** the launch command renders `/bin/zsh` (no path leak — the bare login
shell's displayCommand omits the working dir); `!contains("/Users/")` AND
`!contains("/var/folders/")`; byte-identical twice.

**Mutation-verify (P2):** mutated `InactiveTerminalSurface.statusHeadline`'s "Ready to launch"
default → "MUTANT" → **the `readyToLaunch` snapshot + the negative control went RED** →
reverted byte-identically → green. **CAUGHT.**

**a11y-id:** none needed.

**Allowlist dossier (candidate #3):** the `if let session` LIVE arm is confirmed
non-snapshottable (it constructs `TerminalPane`, the live PTY) — snapshot the inactive
states (this recipe), allowlist the live arm. Dossier filled in `allowlist-candidates.md`.

**GO.** Recipe sound; C9 reuses the `activeSession == nil` seam + fixed `/tmp/u4` paths for
the whole session-detail family (`DetailSplitContainer` inactive arms, `EmptyPanePicker`,
`SessionInspectorPanel`, `TranscriptHistoryView` `Text(tail.path)` leak, etc.).

---

## Q1 spike — `WorkbenchRootView` / `MachineRuntimeView` host viability → **ALLOWLIST** (NO-GO for in-process snapshot)

**P1 discipline: the untestability claim is CHECKED first-hand, not asserted.**

### `WorkbenchRootView` (`:131`) — ALLOWLIST
- **Verified shape (re-read @ branch HEAD):** `@StateObject private var model: WorkbenchViewModel`
  (`:132`); its ONLY initializer is `init(diagnostics: WorkbenchLaunchDiagnostics)` (`:141`) which
  constructs the `@StateObject` model INTERNALLY — there is **no model-injection seam**, so any
  in-process host would build a real `WorkbenchViewModel` that scans the REAL `~/AgentBundles`
  in its init (`refreshOuroAgents()`) → a non-hermetic, machine-name-leaking AN-001 violation
  the C0 recipes can't pin (the temp-`agentBundlesURL` dual-injection is unreachable through
  `init(diagnostics:)`). Plus `NavigationSplitView(columnVisibility:)` (`:282`) +
  `@Environment(\.scenePhase)` (`:139`) = the window/scene shell, no data-state seam.
- **Verdict: ALLOWLIST.** The Q1 reversible default holds — there is no clean hostable subtree
  reachable deterministically; the body IS the split + menu wiring. Dossier in `allowlist-candidates.md`.

### `MachineRuntimeView` (`:10170`) — ALLOWLIST (login-item arm)
- **Verified shape:** `@StateObject private var loginItem = LoginItemController()` constructed
  IN-PLACE (no `paths`/init seam); only `MachineRuntimeView(model:)` exists (`:5273`) — the
  `model` is injectable but the `@StateObject LoginItemController()` is NOT, and it shares the
  SAME `body` as the model-driven `supportDiagnostics` rows → it taints the whole view's
  determinism (the login-item `isEnabled`/`isUpdating`/`lastError` are driven by the live service).
- **Verdict: ALLOWLIST (login-item arm).** A future `LoginItemController` protocol-injection seam
  would reclaim it — recorded as a POSSIBLE source-fix, NOT done in U4. Dossier in `allowlist-candidates.md`.

---

## Q3 spike — `ProviderConfigSheet` `@State humanName = NSFullUserName()` determinism → **RESOLVED (recipe proven; ship in C6)**

**The leak is REAL (verified first-hand):** `@State private var humanName: String = NSFullUserName()`
(`:6075`) flows into `TextField("Your name", text: $humanName)` (`:6111`); the harness reads a bound
`TextField`'s value via `input()` (AN-002), so the machine user name IS captured in the tree. On this
machine `NSFullUserName() == "Microsoft"` → it would land in a committed reference (a P3 violation).
This is the ONE determinism landmine beyond the audit's enumerated edge-cases.

**Resolution (the reversible default, PROVEN VIABLE — to SHIP IN C6, not C0):** the brief says
"if the doc's C0 includes the Q3 fix as a representative, do it; otherwise leave Q3 to C6." C0's
`ProviderConfigSheet` is NOT a committed C0 snapshot representative (its home cluster is C6) — so
C0 RESOLVES the recipe and C6 ships it. The proven recipe:

  **Seed the `@State humanName` from a model seam.** Add `@Published var providerConfigHumanName: String`
  to `WorkbenchViewModel` defaulting to `NSFullUserName()` (the machine read moves to the MODEL layer,
  where a test injects a fixed value), and give `ProviderConfigSheet` a custom `init` that seeds
  `_humanName = State(initialValue: model.providerConfigHumanName)`. **Zero behavior change in
  production** (same default value, same render) — the SU-E precedent (a minimal source seam surfaced
  to the operator). The C6 snapshot then drives `model.providerConfigHumanName = "Ada Lovelace"` (a
  fixed value), and asserts `!tree.contains(NSFullUserName())`.

  **Fallback (if the binding-seam is judged too invasive at C6):** carve the `humanName` row from the
  asserted subtree and assert `!tree.contains(NSFullUserName())` on the model-driven (non-initial)
  states only — the doc's recorded fallback. Either way the committed reference is `NSFullUserName()`-free.

**Status: GO (recipe proven viable, leak confirmed, reversible default + fallback both recorded).**
The source change + the `ProviderConfigSheet` snapshot land in **C6** (not C0) — C0 ships NO
`ProviderConfigSheet` source touch (keeping the spike clean per the brief). C6 must apply the model-seam
(or the fallback) and assert the leak-free tree.

---

## C0 summary — all 6 recipes GO; Q1 ALLOWLIST; Q3 RESOLVED

| recipe | representative | home cluster | status | mutation |
|---|---|---|---|---|
| 1 real-target chip | `GitBranchChip` | C1 | ✅ GO | CAUGHT |
| 2 standalone menu | `TerminalRowContextMenu` | C1 | ✅ GO | CAUGHT |
| 3 path-leak (hard) | `AgentInspectorPanel` (private→internal) | C7 | ✅ GO | CAUGHT |
| 4 fixed-timestamp clock | `BossWatchStatusView` | C10 | ✅ GO | CAUGHT |
| 5 AN-001 + fixed record | `OuroAgentManagerView` | C8 | ✅ GO | CAUGHT |
| 6 live-arm carve-out | `SessionDetailView` inactive | C9 | ✅ GO | CAUGHT |

Q1 `WorkbenchRootView`/`MachineRuntimeView` → **ALLOWLIST** (verified non-hostable). Q3
`ProviderConfigSheet` `NSFullUserName()` → **RESOLVED** (model-seam recipe proven; ship in C6).
**Mutation tally: 6 surfaces mutated, 6 CAUGHT, 0 uncaught.** No uncaught guards → no backlog item.
Access-widening: `AgentInspectorPanel` private→internal (1; surfaced to the operator).
The 4 reusable fixture primitives (fixed-`Date`, fixed `OuroAgentRecord`/relative paths, temp
`agentBundlesURL` dual-injection, standalone menu/popover instantiation) are all proven — every
later cluster imports the recipe.
