# Planning Coverage Checklist — Slice ②a

Every Slice-②a requirement from the master plan, the ideation doc, and the task prompt, mapped to a doing unit. ✅ = has a doing unit. ❌ = MISSING.

## From master plan §②a + D4
- ✅ Split durable **structure** (workspaces, tabs, names, groupings) from ephemeral **runtime** (pids, live status) in `WorkspaceModels.swift`/`WorkbenchStore.swift` → Units 1b (Workspace struct), 1c (boundary invariant DA2), Target-model §Ephemeral RUNTIME.
- ✅ `Workspace` (id, name=auto+optional override, pinned, ordered member tabs) → Unit 1a/1b (`autoName`+`nameOverride`+`isPinned`+`tabIds`, `effectiveName`).
- ✅ Named **Tabs** (working dir, agentKind, resume metadata, custom-name override) → DA1: tab = existing `ProcessEntry` (carries workingDir/agentKind/resume); custom-name override = `tabNameOverride` in Units 2a/2b; `effectiveTabName`.
- ✅ cmux fact: a workspace spans ≥1 dir → Target-model (Workspace has no single rootPath; dir set derived from tabs).
- ✅ cmux fact: same repo backs many workspaces / workspace spans repos → Target-model §Durable STRUCTURE (explicit departure from dir-anchored `WorkbenchProject`).
- ✅ names auto+overridable+revertible → `effectiveName`/`effectiveTabName` = `override ?? auto`; revert = override→nil (DA4); Units 1a/2a pin it.
- ✅ Backcompat migration NON-DESTRUCTIVE of the flat `processEntries` (incl. 4 malformed "Resume …" rows) → Units 4a/4b/4c (`migrateToWorkspaceStructure`, non-destructiveness invariant, "Resume …" rows preserved).
- ✅ Migrate flat entries into a single default/migrated workspace WITHOUT data loss → Unit 4b (single default workspace; non-destructive).
- ✅ Respect existing `WorkbenchStore` backcompat posture (PR #275: load older/equal, never wipe) → Unit 3a/3b (accept-`<=`-current gate preserved; v1 loads not quarantined; validated in Pass 3).
- ✅ Bump `currentSchemaVersion`; old files still decode → Unit 3b (1→2; v1 fixture loads under v2).
- ✅ App-UI-free; sidebar/tab/Home deletion is ②b OUT of scope → Objective + Scope reminder + Execution (89 consumers untouched).

## From ideation §"Durable workspace state" + naming model
- ✅ Workspace structure durable + first-class (survives reboot) → Units 1b/3b (persisted in `WorkspaceState`).
- ✅ Split structure from runtime (pids, live status) → Units 1c (boundary invariant) + Target-model.
- ✅ Naming model = auto-name (boss-proposed) + revertible custom override → Units 1a/2a (`nameOverride`/`tabNameOverride` ?? auto; revert=nil).
- ✅ Boss is an MCP client, not the owner; separate dedicated git-init-able store (D4) → DEFERRED to ②c by design; ②a keeps structure additively in `WorkspaceState`, **grouped/separable** for ②c lift-out (DA7 + Target-model §②c). (②a does NOT build the store path — correctly out of ②a scope.)
- ✅ Boss reads/writes structure as MCP client; auditable → DA7 defers store; ②a's non-destructive, additive migration + lenient decode preserve auditability/recovery truth (malformed rows kept, not cleaned).

## From task prompt "Slice ②a scope" + "Constraints"
- ✅ Introduce durable structure entities in `WorkspaceModels.swift` → Units 1b/2b/3b.
- ✅ Make the persistence boundary explicit in `WorkbenchStore`/`WorkspaceModels` → Unit 1c (invariant) + Target-model + doc-comments (Units 1b/2b/3b).
- ✅ pids/live status/transcript-run liveness are RUNTIME, reconstructed at launch → Target-model §Ephemeral RUNTIME (ProcessRun is the runtime side; Workspace carries none).
- ✅ Non-destructive migration is P0 auditability/recovery truth → Units 4a (non-destructiveness invariant test) / 4b.
- ✅ 100% line+region coverage on all new Core code; allowlist must NOT grow → every Nc coverage unit (1c/2c/3c/4c) + Completion Criteria + Code Coverage Requirements.
- ✅ Strict TDD: failing XCTest first (Core IS test-visible) → TDD Requirements + every Na (red) unit.
- ✅ Verify gates: `swift build`/`swift test` with `-warnings-as-errors -strict-concurrency=complete`, 0/0 → every Nb green + Unit 5 full gate.
- ✅ `Scripts/check-coverage.sh` green → every Nc + Unit 5.
- ✅ One commit per unit (real XCTest TDD) → Execution + per-unit Commit lines (4a/4b/4c distinct commits).
- ✅ Native macOS first; preserve auditability/recovery truth → non-destructive migration; malformed rows preserved.
- ✅ NO Co-Authored-By / AI attribution → Execution + Completion Criteria.
- ✅ Do NOT stage `SerpentGuide.ouro/` → Execution + Completion Criteria + Unit 5 file-list guard.
- ✅ Stay on `feat/slice2a-storage-schema`, do NOT branch, do NOT open a PR, do NOT touch other slices' docs → Branch header + Execution.

## Skepticism-pass resolutions / error-handling / trust gating
- ✅ Lenient decode of new `workspaces` collection (one corrupt workspace can't sink load; drop attributed to `decodeReport`) → Unit 3a/3c (mirrors existing `projects` lenient test).
- ✅ Forward-incompat preserved (v3 file still quarantined / `unsupportedStateVersion`) → Unit 3a + adapted `testNewerSchemaVersionIsStillQuarantinedByOwningStore`.
- ✅ Schema-bump blast radius: 3 literal-`1` tests updated in lockstep → Unit 3b (validated in Pass 3: DegradedReadTests:72, PaneLayoutStateTests:73, WorkbenchStoreTests:15).
- ✅ App bootstrap wiring validated against real source (reconcile/bootstrap, not bare `state=loaded`) → Migration-approach §Where + Unit 5 (anchor corrected in Pass 3).
- ✅ Idempotent migration, no run-once gate → DA3 + Unit 4a (idempotence test).
- ✅ Edge cases: empty state (no default minted), archived entries (excluded from auto-membership), empty-string override (honored, not revert) → DA4/DA5/DA6 + Units 4a/1a/2a.

## Verdict
No ❌. All Slice-②a requirements from master plan, ideation, and task prompt are covered by a doing unit. ②c-scoped items (dedicated git-init store, opt-in remote, boss-as-MCP-client store ownership) are CORRECTLY deferred (out of ②a scope) but their forward-compat headroom is captured in DA7 + the Target-model section so ②a doesn't paint ②c into a corner.
</content>
