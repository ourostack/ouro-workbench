# Doing: Slice ②a — Durable Workspace/Tab Structure Schema + Migration (PURE CORE)

**Status**: drafting | READY_FOR_EXECUTION | in-progress | done
**Execution Mode**: direct
**Created**: 2026-06-24 18:32
**Planning**: ./2026-06-24-1755-planning-workspaces-converged-design.md
**Ideation**: ./2026-06-24-1745-ideation-workspaces-onboarding-bring-back.md
**Artifacts**: ./2026-06-24-1832-doing-slice2a-storage-schema/
**Branch**: `feat/slice2a-storage-schema` (off `origin/main` @ 40eb132 — do NOT branch again)

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (interactive)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default) ← **this slice**

Rationale: real XCTest-driven TDD against test-visible Core. Units are tightly coupled (schema → decode → migration → integration), share `WorkspaceModels.swift`, and each must leave the build/test/coverage gates green. Sequential `direct`, **one commit per unit**.

---

## Objective
Introduce the durable **structure** entities for the cmux model — a `Workspace` (named, auto+override name, pinned, ordered members) of named `Tab`s (a tab = an agent-session terminal: working dir, agentKind, resume metadata, name override) — into `Sources/OuroWorkbenchCore/WorkspaceModels.swift`, persisted via `WorkbenchStore`. Make the **durable-structure vs ephemeral-runtime** boundary explicit and enforced. Migrate the existing flat `processEntries` (schemaVersion 1, including the malformed 4 "Resume …" duplicate rows) into the new structure **non-destructively**, bumping `currentSchemaVersion` while keeping all old files decodable.

**This slice is App-UI-FREE.** No sidebar/tab layout, no deletion of the "Home" concept, no consumer rewiring. ②a ships the Core model + persistence + migration only. The 89+ existing `processEntries`/`projects` consumers across App+Core stay on the legacy fields, UNTOUCHED (②b rewires them).

---

## Target model (whole Slice ②, for forward-compat — design once, build ②a only)

Designed so ②a's schema does not paint ②b–②d into a corner. **②a introduces the types and persists them additively; ②b–②d adopt/extend them.**

### Durable STRUCTURE (persisted in `WorkspaceState`, git-backable in ②c)
```
Workspace
  id: UUID
  nameOverride: String?          // operator's custom name; nil ⇒ use autoName (revertible override; ideation §Flow 2)
  autoName: String               // boss/heuristic-derived name (Slice ⑤ improves derivation; ②a seeds a safe default)
  isPinned: Bool                 // Pin Workspace (②d affordance; modeled now, no UI)
  tabIds: [UUID]                 // ORDERED members → ProcessEntry.id (a tab IS the existing terminal row; see "tab ⇒ entry" below)
  // forward headroom (NOT added in ②a unless a unit needs it — listed so the shape is known):
  //   groupings (②b sub-grouping within a workspace), createdAt/sort (②b ordering)
```
- **A workspace spans ≥1 dir** (cmux fact): it does NOT carry a single `rootPath`. Its dir set is *derived* from its tabs' `workingDirectory` values, never stored as the identity. This is the deliberate departure from `WorkbenchProject` (which is dir-anchored). The same repo can back many workspaces; a workspace can span repos.
- **Name model = `effectiveName` computed**: `nameOverride ?? autoName`. "Remove Custom Workspace Name" (②d) = set `nameOverride = nil` → reverts to `autoName`. Pure, modeled in ②a; the ⌘-key affordances are ②d.

### Tab ⇒ existing `ProcessEntry` (NO duplicate entity)
A **Tab is the agent-session terminal that already exists as `ProcessEntry`.** ②a does NOT create a parallel `Tab` row that re-stores working dir / agentKind / resume metadata — that would fork the source of truth and re-introduce the exact "two meanings" muddle the design kills. Instead:
- The `Workspace.tabIds` array references `ProcessEntry.id`s in tab order. The entry remains the carrier of `workingDirectory`, `agentKind`, resume/`discoveredHarness`/`discoveredSessionId`.
- ②a adds ONE field to the structure side for the tab's **custom-name override**: a per-entry `tabNameOverride: String?` on `ProcessEntry` (additive, decode-if-present). `ProcessEntry.name` is the auto/derived tab name; `tabNameOverride` is the operator's revertible custom name. `effectiveTabName = tabNameOverride ?? name`. (Mirrors the workspace name model.) Rename Tab (⌘R, ②d) sets it; revert clears it.
- **Why a tab is not its own struct in ②a:** `ProcessEntry` already holds every per-tab runtime/launch fact and has 89+ consumers; minting a second tab entity now forces those consumers to choose, before ②b is ready to rewire them. Modeling membership+name on top of the existing entry is the forward-compatible, reversible choice. (Recorded as Decision DA1.)

### Ephemeral RUNTIME (NEVER persisted as structure; reconstructed at launch)
- `ProcessRun` (pids, `status`, `startedAt/endedAt`, exit codes, `terminalSessionId`, `transcriptPath`, `lastOutputAt`) — already a separate collection; this is the runtime side. ②a makes the boundary **explicit and documented**, and adds a guard so structure types carry NO live-process fields.
- Live process status, transcript-run liveness, `AttentionState` *current* value — runtime. (`AttentionState` persists as a hint but is recomputed; out of ②a's structure surface.)
- **Persistence boundary rule (②a deliverable):** a `Workspace` is a pure structural value — id, names, pinned, ordered tab ids. It contains NO `pid`, NO `ProcessRun`, NO live status. A unit-tested invariant pins this (a compile-time + test-level assertion that `Workspace`'s stored properties are structure-only).

### Forward slices consume this shape
- **②b** deletes "Terminals in Home" + the second "workspace" meaning, adopts the sidebar(workspaces)/tabs(top) layout, and rewires the 89 consumers from raw `processEntries` to "entries grouped by their `Workspace.tabIds`." The migration in ②a guarantees every entry is already a member of exactly one workspace, so ②b never faces an orphan.
- **②c** moves the durable structure to a dedicated `git init`-able store path (new `WorkbenchPaths` member) with opt-in remote; boss reads/writes as MCP client. ②a keeps structure in `WorkspaceState` for now (additive), but **structurally separable**: `Workspace`/structure fields are grouped so ②c can lift them into their own file without a second migration.
- **②d** wires Rename Workspace (⇧⌘R), Rename Tab (⌘R), Pin Workspace, Remove Custom Workspace Name to the `nameOverride`/`tabNameOverride`/`isPinned` fields ②a already models.
- **⑤** improves `autoName`/`name` *derivation* (name-by-work). ②a only needs a deterministic, safe seed name; the field is in place.

---

## Migration approach (old flat state → new structure, NON-DESTRUCTIVE)

The current on-disk `workspace-state.json` is `schemaVersion 1`: a flat `processEntries` array (with the malformed 4 "Resume …" duplicate rows) and a `projects` array. The new build:

1. **Bumps `WorkspaceState.currentSchemaVersion` 1 → 2.** Per the hardened backcompat posture (PR #275, confirmed in `WorkbenchStore.load`): the gate accepts `schemaVersion <= current` and rejects ONLY `> current`. So a v1 file still decodes cleanly via the lenient per-field decoders; only a *future* (v3+) file is quarantined. **Old files never wipe.**
2. **Adds a pure, idempotent Core migration** `WorkspaceState.migrateToWorkspaceStructure()` (mutating, on `WorkspaceState`, mirroring `applyAutomaticBossDefaults`/`pruneProcessRuns`). It:
   - Leaves `processEntries`, `projects`, `processRuns`, and every existing field **byte-for-byte intact** (no entry deleted, no "Resume …" row dropped — auditability/recovery truth: the malformed rows are PRESERVED, not silently cleaned; ②b/④ decide their fate with operator visibility).
   - Ensures every non-archived `ProcessEntry` is a member of exactly one `Workspace`. For a v1 file with no `workspaces`, it creates a **single default/migrated workspace** whose `tabIds` are all current entries in their existing order, with a deterministic `autoName` (e.g. `"Restored workspace"` — a safe seed; ⑤ improves derivation later). Idempotent: re-running adds nothing (entries already mapped), so it's safe to run on every load.
   - Is **additive-only on the structure side**: the new `workspaces` collection and `tabNameOverride` field are decode-if-present (absent ⇒ `[]` / nil), so a v1 file loads with `workspaces == []`, then the migration populates it.
3. **Decode stays lenient.** New `workspaces` collection decodes via the existing `decodeLenientArray` (one corrupt workspace can't sink the load; drops attributed into `decodeReport`). New `tabNameOverride` is `decodeIfPresent`.
4. **Re-save is safe.** Because the migration only ADDS structure (never drops entries), `decodeReport.isLossy` is driven solely by genuine per-element decode drops, unchanged. A migrated state re-encodes with `schemaVersion 2` + the new `workspaces`; on the next launch the new build reads it as current. (An OLD build reading the v2 file: it'd see `schemaVersion 2 > its current 1` and quarantine — acceptable; that is the existing forward-incompat contract and only happens on a downgrade, which already loses the new build's data by definition.)

**Where the migration runs (App, ②a-scoped):** at bootstrap right after `store.load()` (App `OuroWorkbenchApp.swift:19930`), alongside the existing `pruneProcessRuns()` (:19426) and `applyAutomaticBossDefaultsMigrationIfNeeded()` (:19944). Because the migration is **idempotent**, it does NOT need a run-once `UserDefaults` gate (unlike `applyAutomaticBossDefaults`, which flips trust and must run once): it can run every load and converge. The single App call site (one line) is the only App touch in ②a and is NOT coverage-gated, but IS compiled under the strict flags. (Recorded as Decision DA3.)

---

## Completion Criteria
- [ ] `Workspace` struct exists in `WorkspaceModels.swift`: `id`, `autoName`, `nameOverride: String?`, `isPinned: Bool`, `tabIds: [UUID]` — `Codable, Equatable, Identifiable, Sendable`, with `effectiveName` computed (`nameOverride ?? autoName`) and lenient/forward-compatible decode (decode-if-present defaults, no throw on absent optional fields).
- [ ] `ProcessEntry` gains `tabNameOverride: String?` (additive, decode-if-present) + `effectiveTabName` computed (`tabNameOverride ?? name`); every pre-②a file decodes with it nil.
- [ ] `WorkspaceState` gains `workspaces: [Workspace]` (additive, lenient-decoded via `decodeLenientArray`, present-or-empty); `currentSchemaVersion` bumped 1 → 2; CodingKeys updated; memberwise init + custom decode + round-trip all green.
- [ ] `WorkspaceState.migrateToWorkspaceStructure()` is pure, mutating, **idempotent**, and **non-destructive**: preserves all entries (incl. the 4 "Resume …" rows), maps every non-archived entry into exactly one workspace (single default workspace for a v1 file), and re-running is a no-op.
- [ ] Persistence boundary enforced + tested: `Workspace` carries NO pid/run/live-status field; a test pins that structure types are runtime-free (DA2 invariant).
- [ ] Old v1 file (incl. one with the malformed "Resume …" duplicate rows) loads under the v2 build with all rows intact, NOT quarantined, and migrates into a single default workspace.
- [ ] v2 round-trips: save → load preserves `workspaces`, `tabNameOverride`, ordering, names, pin flag.
- [ ] A future (v3) file is STILL quarantined by the owning store / rejected for read-only (forward-incompat contract preserved).
- [ ] App bootstrap calls `migrateToWorkspaceStructure()` after `store.load()` (one line; no run-once gate — idempotent).
- [ ] 100% line + region coverage on all new Core code (`Scripts/check-coverage.sh` green; `Scripts/coverage-allowlist.txt` does NOT grow).
- [ ] `swift build`/`swift test` with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 warnings, 0 failures.
- [ ] `swift run … OuroWorkbench --uisurfacetest` passes (no crash; App still builds+renders with the one-line migration call).
- [ ] `SerpentGuide.ouro/` NOT staged. No Co-Authored-By / AI attribution. One commit per unit.

## Code Coverage Requirements
**MANDATORY: 100% line + region coverage on all new Core code.**
- No growth of `Scripts/coverage-allowlist.txt`. Every new line + every branch arm of `Workspace`, the new `WorkspaceState` decode/migration paths, `effectiveName`/`effectiveTabName`, and `tabNameOverride` decode must be exercised by an XCTest.
- All error/edge paths tested: empty `workspaces`, absent `tabNameOverride`, corrupt workspace element (lenient drop attributed to `decodeReport`), idempotent re-run, v1-with-entries, v1-empty, archived-entry handling, mixed override/no-override names.
- Core IS test-visible (`@testable import OuroWorkbenchCore`) — unlike Slice ①'s App view. This is **strict XCTest TDD**, not a shell guard.

## TDD Requirements
**Strict TDD — no exceptions:**
1. **Tests first**: Write failing XCTest BEFORE any implementation.
2. **Verify failure**: Run `swift test`, confirm the new tests FAIL (red) — and that they fail for the RIGHT reason (missing symbol / wrong behavior, not a typo).
3. **Minimal implementation**: Write just enough Core code to pass.
4. **Verify pass**: Run `swift test` strict, confirm PASS (green), 0 warnings.
5. **Refactor + coverage**: `Scripts/check-coverage.sh` → 100%; refactor with tests green.
6. **No skipping**: never write implementation without a failing test first.

---

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

> Every unit: red XCTest first → green minimal impl → coverage 100% → strict build/test → **one commit**. Save red/green/coverage tails to the artifacts dir per unit.

### ⬜ Unit 0: Pre-flight baseline + fixtures (Setup/Research)
**What**:
- Capture the GREEN baseline before any change: run `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` and `Scripts/check-coverage.sh`; save tails to `./2026-06-24-1832-doing-slice2a-storage-schema/baseline-gate.txt`. Confirms the branch starts clean and coverage is green with the existing allowlist (2 entries).
- Build a **v1 fixture JSON** representing the malformed real state: a `schemaVersion 1` file with a `projects` entry and `processEntries` containing 4 rows whose `name` begins `"Resume "` (e.g. `"Resume ouro-workben…"`, `"Resume ms-desk (Clau…"`) plus 1–2 normal rows — NO `workspaces` key, NO `tabNameOverride`. Save as `./2026-06-24-1832-doing-slice2a-storage-schema/fixtures/v1-malformed-resume-state.json`. This is the migration/backcompat test fixture (synthetic — do NOT copy real operator data).
- Record the exact current `currentSchemaVersion` (= 1) and the WorkbenchStore gate semantics (`<= current` accepts) in `./2026-06-24-1832-doing-slice2a-storage-schema/baseline-notes.md` so the bump's blast radius is documented.
**Output**: `baseline-gate.txt`, `fixtures/v1-malformed-resume-state.json`, `baseline-notes.md`.
**Acceptance**: baseline `swift test` + coverage are GREEN as recorded; fixture is valid JSON parsable as the current v1 shape (sanity: `python3 -m json.tool` succeeds); notes capture schemaVersion=1 and the accept-`<=` gate. (No commit — pure research; artifacts may ride on Unit 1's commit OR a `docs(doing):` commit if preferred. Default: fold into Unit 1 commit.)

### ⬜ Unit 1a: `Workspace` struct + name model — Tests (RED)
**What**: Add `WorkspaceModelsTests`-style XCTest (new file `Tests/OuroWorkbenchCoreTests/WorkspaceStructureTests.swift`) asserting, all FAILING (type doesn't exist yet):
- `Workspace(id:autoName:nameOverride:isPinned:tabIds:)` memberwise init exists with the documented defaults (`nameOverride: nil`, `isPinned: false`, `tabIds: []`).
- `effectiveName == nameOverride ?? autoName`: with an override → override; with `nameOverride == nil` → `autoName`; with `nameOverride == ""` → the EMPTY override is HONORED (it is a deliberate value, NOT nil — pin this edge so "revert" is unambiguously `nil`, not empty-string). (DA4: empty override ≠ revert.)
- `Workspace` is `Codable` round-trip equal (encode → decode → `==`).
- Forward-compat decode: a workspace JSON missing `nameOverride`/`isPinned`/`tabIds` decodes with the documented defaults (decode-if-present), and an UNKNOWN extra key is ignored (no throw).
**Acceptance**: tests exist and FAIL to COMPILE/RUN because `Workspace` is undefined (red). Record the red `swift test` tail to `artifacts/unit1a-red.txt`.

### ⬜ Unit 1b: `Workspace` struct + name model — Implementation (GREEN)
**What**: In `Sources/OuroWorkbenchCore/WorkspaceModels.swift`, add:
- `public struct Workspace: Codable, Equatable, Identifiable, Sendable` with `id: UUID`, `autoName: String`, `nameOverride: String?`, `isPinned: Bool`, `tabIds: [UUID]`; memberwise `init` with documented defaults; custom `init(from:)` using `decodeIfPresent` for `nameOverride`/`isPinned`/`tabIds` (matching the file's lenient posture — absent optional/defaulted fields never throw). Doc-comment it as **durable STRUCTURE** and state the persistence-boundary rule (no pid/run/live-status here).
- `public var effectiveName: String { nameOverride ?? autoName }`.
**Acceptance**: Unit 1a tests PASS (green). `swift build`/`swift test` strict — 0 warnings/0 failures. Record green tail to `artifacts/unit1b-green.txt`. **Commit** `feat(core): add durable Workspace structure entity (name override + pin + ordered tabs)`.

### ⬜ Unit 1c: `Workspace` coverage + persistence-boundary invariant — Coverage & Refactor
**What**:
- Run `Scripts/check-coverage.sh`; if any line/region of `Workspace` is uncovered, add the targeted XCTest (e.g. the empty-`tabIds` branch, the `nameOverride == nil` arm, the unknown-extra-key decode). Goal: 100% line+region on the new code; `coverage-allowlist.txt` unchanged.
- Add the **persistence-boundary invariant test** (DA2): a test that constructs a `Workspace` and asserts (via its `Mirror` children / explicit property enumeration) that it exposes ONLY structure fields (`id`, `autoName`, `nameOverride`, `isPinned`, `tabIds`) — NO `pid`, `status`, `ProcessRun`, `startedAt`, `transcriptPath`, etc. This pins "structure carries no runtime" so a later field-add can't smuggle runtime into the durable type without a test failing.
**Acceptance**: `Scripts/check-coverage.sh` 100% on `Workspace`; allowlist not grown; boundary invariant green. Record to `artifacts/unit1c-coverage.txt`. **Commit** `test(core): pin Workspace 100% coverage + structure/runtime boundary invariant`.

### ⬜ Unit 2a: `ProcessEntry.tabNameOverride` + `effectiveTabName` — Tests (RED)
**What**: Extend the structure tests (or a sibling file) asserting, FAILING:
- `ProcessEntry` has `tabNameOverride: String?`, defaulting to `nil` via memberwise init; `effectiveTabName == tabNameOverride ?? name`.
- Backcompat decode: a `ProcessEntry` JSON WITHOUT `tabNameOverride` (every pre-②a row, incl. the v1 fixture's "Resume …" rows) decodes with `tabNameOverride == nil` and `effectiveTabName == name`. Use the Unit-0 fixture path here.
- Round-trip: an entry WITH a `tabNameOverride` survives save→load; clearing it (set nil) reverts `effectiveTabName` to `name`.
**Acceptance**: tests FAIL (field/computed prop missing) for the right reason (red). Record `artifacts/unit2a-red.txt`.

### ⬜ Unit 2b: `ProcessEntry.tabNameOverride` + `effectiveTabName` — Implementation (GREEN)
**What**: In `WorkspaceModels.swift` `ProcessEntry`:
- Add stored `public var tabNameOverride: String?`; add to memberwise `init` (default `nil`, placed last to preserve call-site compatibility); add to `CodingKeys`; add `decodeIfPresent` in `init(from:)`; add `public var effectiveTabName: String { tabNameOverride ?? name }`. Doc-comment it (revertible custom tab name; mirrors `Workspace.nameOverride`; pre-②a state loads nil).
- Verify the 89+ existing call sites still compile (the new init param is last + defaulted, so memberwise callers are unaffected; encode is synthesized off CodingKeys + the explicit `init(from:)`).
**Acceptance**: Unit 2a tests PASS. `swift build`/`swift test` strict — 0 warnings/0 failures (proves no existing `ProcessEntry` call site broke). Record `artifacts/unit2b-green.txt`. **Commit** `feat(core): add revertible per-tab custom name override to ProcessEntry`.

### ⬜ Unit 2c: `tabNameOverride` coverage — Coverage & Refactor
**What**: `Scripts/check-coverage.sh`; cover any uncovered arm of the new `tabNameOverride` decode / `effectiveTabName` (e.g. nil vs present, empty-string-honored-not-reverted edge matching DA4). Allowlist unchanged.
**Acceptance**: 100% line+region on the `ProcessEntry` additions; allowlist not grown. Record `artifacts/unit2c-coverage.txt`. **Commit** `test(core): pin tabNameOverride 100% coverage (override/revert/backcompat)`.

### ⬜ Unit 3a: `WorkspaceState.workspaces` + schema bump 1→2 — Tests (RED)
**What**: Extend `WorkbenchStoreTests`/`WorkspaceState` tests asserting, FAILING:
- `WorkspaceState.currentSchemaVersion == 2`.
- `WorkspaceState` has `workspaces: [Workspace]`; memberwise init defaults it to `[]`; it is in `CodingKeys`; absent in JSON ⇒ `[]` (present-or-empty).
- A current-build SAVE writes `schemaVersion: 2` and a `workspaces` array; round-trip preserves `workspaces` (ordering + names + pin).
- **Lenient decode of `workspaces`**: a state JSON with one valid + one corrupt workspace element keeps the valid one, drops the corrupt one, and attributes the drop into `decodeReport.skippedByCollection["workspaces"]` (mirrors the `projects` lenient test).
- **Backcompat**: the Unit-0 v1 fixture (schemaVersion 1, no `workspaces`) loads under the v2 build with `workspaces == []` (pre-migration), all `processEntries` intact, NOT quarantined.
- **Forward-incompat preserved**: a `schemaVersion 3` file is still quarantined (owning store) / `unsupportedStateVersion(3)` (read-only). (Adapt the existing `testNewerSchemaVersionIsStillQuarantinedByOwningStore` to current+1 = 3.)
**Acceptance**: tests FAIL for the right reasons (currentSchemaVersion still 1, `workspaces` missing) — red. Record `artifacts/unit3a-red.txt`.

### ⬜ Unit 3b: `WorkspaceState.workspaces` + schema bump — Implementation (GREEN)
**What**: In `WorkspaceModels.swift` `WorkspaceState`:
- Bump `public static let currentSchemaVersion = 2` (update its doc-comment to note v1→v2 = structure addition).
- Add `public var workspaces: [Workspace]`; add to memberwise init (default `[]`, grouped with structure fields and documented as **the durable structure collection, separable for ②c**); add to `CodingKeys`; decode via `decodeLenientArray(Workspace.self, forKey: .workspaces, into: &report, collection: "workspaces")` in `init(from:)`.
- Keep all existing fields/decoders byte-identical.
**Acceptance**: Unit 3a tests PASS. Existing `WorkbenchStoreTests` (older/equal/newer schema, lenient decode, round-trip, decodeReport) all STILL pass — the bump must not regress the v0/v1-load tests (they assert `<= current` loads, which still holds with current=2). `swift build`/`swift test` strict green. Record `artifacts/unit3b-green.txt`. **Commit** `feat(core): persist durable workspaces collection; bump state schema v1→v2`.

### ⬜ Unit 3c: schema/persistence coverage — Coverage & Refactor
**What**: `Scripts/check-coverage.sh`; cover every new arm: empty-`workspaces` decode, lenient-drop attribution, round-trip, the bumped version gate boundaries (v1 loads, v2 loads, v3 rejects). Confirm `decodeReport`-excluded-from-encode round-trip still holds with `workspaces` present. Allowlist unchanged.
**Acceptance**: 100% line+region on the `WorkspaceState` additions; allowlist not grown; all pre-existing store tests green. Record `artifacts/unit3c-coverage.txt`. **Commit** `test(core): pin workspaces persistence + schema-v2 gate 100% coverage`.

### ⬜ Unit 4a: `migrateToWorkspaceStructure()` — Tests (RED)
**What**: Add migration tests (in the structure test file) asserting, FAILING (function missing):
- **v1-with-entries**: load the Unit-0 v1 fixture, call `migrateToWorkspaceStructure()` → exactly ONE `Workspace` is created; its `tabIds` == every non-archived entry id IN ORIGINAL ORDER; `autoName` is the deterministic seed (e.g. `"Restored workspace"`); `nameOverride == nil`; `isPinned == false`. **No `processEntries` row deleted** — the 4 "Resume …" rows are all still present and all members.
- **Idempotence**: calling it a SECOND time changes NOTHING (`==` before/after the second call) — every entry already mapped, no duplicate workspace, no duplicate tabId.
- **Already-migrated (v2 with workspaces)**: a state that already has a workspace covering all entries is unchanged by the call.
- **Empty state**: no entries ⇒ no workspace created (don't mint an empty default; an empty machine has nothing to restore — onboarding ③ seeds workspaces). (DA5.)
- **Archived entries**: an archived entry is NOT forced into the default workspace's `tabIds` (archived = not an active tab); pin the chosen rule. (DA6: archived excluded from auto-membership; preserved in `processEntries`, never dropped.)
- **Non-destructiveness invariant**: after migration, `processEntries`, `projects`, `processRuns`, `actionLog` are byte-for-byte equal to pre-migration (only `workspaces` grew).
**Acceptance**: tests FAIL (function undefined) — red. Record `artifacts/unit4a-red.txt`.

### ⬜ Unit 4b: `migrateToWorkspaceStructure()` — Implementation (GREEN)
**What**: In `WorkspaceModels.swift` `extension WorkspaceState`, add `public mutating func migrateToWorkspaceStructure()`:
- Compute the set of entry ids already covered by any existing `workspaces[*].tabIds`.
- Determine the **unmapped, non-archived** entries (preserving `processEntries` order).
- If there are unmapped active entries AND no existing default workspace, create ONE `Workspace(autoName: "Restored workspace", tabIds: <unmapped active entry ids in order>)`. If a single migrated/default workspace already exists, APPEND the unmapped ids to it (keeps idempotence + handles incremental). Choose the simplest correct rule that passes 4a — document it inline.
- NEVER mutate/delete `processEntries` or any other collection. Pure structure addition. Idempotent by construction (mapped ids are skipped).
**Acceptance**: Unit 4a tests PASS (green). `swift build`/`swift test` strict — 0 warnings/0 failures. Record `artifacts/unit4b-green.txt`. **Commit** `feat(core): non-destructive migration of flat entries into default workspace`.

### ⬜ Unit 4c: migration coverage + edge arms — Coverage & Refactor
**What**: `Scripts/check-coverage.sh`; cover every branch of the migration: unmapped-active path, already-mapped (idempotent) path, empty-state path, archived-excluded path, append-to-existing-default path. Add any missing targeted test. Allowlist unchanged.
**Acceptance**: 100% line+region on `migrateToWorkspaceStructure()`; allowlist not grown. Record `artifacts/unit4c-coverage.txt`. **Commit** `test(core): pin migration 100% coverage (idempotent, non-destructive, edge arms)`.

### ⬜ Unit 5: App bootstrap wiring + full-gate integration (GREEN, confirm)
**What**:
- In `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, add ONE call to `state.migrateToWorkspaceStructure()` at bootstrap right after `store.load()` (near :19930, alongside `pruneProcessRuns()` / `applyAutomaticBossDefaultsMigrationIfNeeded()`). **No run-once UserDefaults gate** — the migration is idempotent (DA3). This is the ONLY App edit in ②a.
- Confirm the App still builds and the migrated structure is in `state.workspaces` after load (read the surrounding bootstrap to place the call correctly; do not reorder existing calls).
- Run the FULL gate set and save tails to `artifacts/unit5-gates.txt`:
  - `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 warnings.
  - `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 failures.
  - `swift run -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete OuroWorkbench --uisurfacetest` — no crash.
  - `Scripts/check-coverage.sh` — PASS; `git diff Scripts/coverage-allowlist.txt` EMPTY (did not grow).
- `git diff --name-only` for the slice touches ONLY: `Sources/OuroWorkbenchCore/WorkspaceModels.swift`, the new `Tests/OuroWorkbenchCoreTests/WorkspaceStructureTests.swift`, possibly `Tests/OuroWorkbenchCoreTests/WorkbenchStoreTests.swift` (schema-gate test edits), `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (the one migration line), plus `worker/tasks/...` doc/artifacts. NO `SerpentGuide.ouro/`.
**Acceptance**: all four gates green; allowlist unchanged; only the expected files changed; the App bootstrap populates `workspaces` post-load. Record `artifacts/unit5-gates.txt`. **Commit** `feat(app): run idempotent workspace-structure migration at bootstrap`.

---

## Execution
- **TDD strictly enforced** (real XCTest): red → green → coverage → strict build/test → commit, per unit.
- **One commit per unit** (4a/4b/4c are separate commits — red test, green impl, coverage). Suggested messages are inline per unit. NO Co-Authored-By / AI attribution.
- **Push** after the slice's units complete (per repo workflow); do NOT open a PR (operator instruction).
- **All artifacts** (red/green/coverage tails, fixtures, baseline notes) → `./2026-06-24-1832-doing-slice2a-storage-schema/`.
- **Do NOT stage** `SerpentGuide.ouro/`.
- **Do NOT touch** other slices' docs, the App sidebar/tab layout, the "Home" concept, or the 89 `processEntries`/`projects` consumers (②b owns the rewire).
- **Fixes/blockers**: if a gate fails unexpectedly (e.g. a hidden `ProcessEntry` memberwise call site that breaks despite the defaulted-last param, or a store test that assumed `currentSchemaVersion == 1` literally rather than via the constant), spawn a sub-agent to investigate immediately; update this doc + commit.
- **Decisions made during execution**: update this doc immediately, commit right away (`docs(doing):`).

## Decisions Made (②a defaults — reversible/auditable picks)
- **DA1 — A Tab is the existing `ProcessEntry`, not a new struct.** `Workspace.tabIds` references entry ids; the per-tab custom name rides as `ProcessEntry.tabNameOverride`. Avoids forking the source of truth before ②b rewires consumers. Reversible: ②b can promote a richer `Tab` type later if needed; nothing here blocks it.
- **DA2 — Persistence boundary is enforced by an invariant test.** `Workspace` carries structure-only fields; a Mirror/property test pins no-runtime-in-structure so future field-adds can't smuggle a pid/run in.
- **DA3 — Migration is idempotent and runs every load (no run-once gate).** Unlike `applyAutomaticBossDefaults` (one-shot trust flip), structure migration converges and is safe to re-run; a UserDefaults gate would add state with no benefit and risk a stuck flag.
- **DA4 — Empty-string name override is HONORED, not treated as revert.** Revert is unambiguously `nameOverride = nil`. An empty string is a deliberate (if odd) operator value. Pins the ②d revert semantics now.
- **DA5 — Empty machine → no default workspace minted.** Nothing to restore; onboarding (③) seeds workspaces. Avoids a junk empty default on first run.
- **DA6 — Archived entries are excluded from auto-membership** but preserved in `processEntries` (never dropped). Archived = not an active tab. Reversible; ②b/④ can surface archived rows explicitly.
- **DA7 — Structure stays in `WorkspaceState` for ②a (additive), grouped for ②c lift-out.** Defers the dedicated git-init store (②c/D4) without a second migration: the fields are co-located so ②c moves them as a block.

## Open forks for the human (flagged, NOT blocking — defaults chosen above)
1. **Default workspace auto-name seed** (`"Restored workspace"`). ⑤ improves derivation; if the operator wants a different seed string (or to seed from the dominant repo basename even pre-⑤), that's a one-line change. Default chosen: a neutral, honest, non-directory string (directory-naming is the anti-pattern the design calls out).
2. **DA1 (tab = entry vs new Tab struct).** The genuine model fork. Chosen: reuse `ProcessEntry` to avoid a premature second entity + 89-consumer churn before ②b. If the operator's ②b/②c vision needs tabs decoupled from entries (e.g. a tab that outlives its process record, or a tab with no entry), promoting `Tab` to its own struct in ②b is the alternative — ②a's additive shape does not preclude it, but it's the one place a human might prefer a different foundation.
3. **DA6 (archived excluded from auto-membership).** If the operator wants archived sessions visible as (collapsed) tabs in the restored workspace rather than excluded, flip the filter. Chosen exclusion keeps the restored workspace = "what was active," matching bring-back intent.

## Progress Log
- 2026-06-24 18:32 Created from master plan Slice ②a. Read master plan (Slice ② decomposition, D4), ideation (cmux model, durable state, naming model), and verified all anchors against current source at branch-point 40eb132: `WorkspaceModels.swift` (`ProcessEntry`/`WorkspaceState`/`currentSchemaVersion=1`/lenient `init(from:)`/`decodeLenientArray`/`applyAutomaticBossDefaults` migration pattern), `WorkbenchStore.load` (accept-`<=`-current gate, PR #275 posture), `WorkbenchPaths`, `FailableDecodable`, `TerminalAgentKind`/`AgentHarness` enums, the App bootstrap migration call sites (:19426 prune, :19930 load, :19944 boss-defaults, :20108 run-once pattern), and the 89+ `processEntries`/`projects` consumers (⇒ ②a must be purely additive). Designed the whole Slice-② target model (Workspace/Tab/runtime split) for forward-compat; scoped ONLY ②a to executable units. Defaults DA1–DA7 recorded; 3 forks flagged for the human.
</content>
</invoke>
