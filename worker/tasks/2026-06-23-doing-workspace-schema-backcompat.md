# Fix: workspace-state schema back-compat (silent data wipe on upgrade)

Branch: `fix/workspace-schema-backcompat` (off `main` @ `b0a6f21`)
Severity: HIGH — silent data wipe
Scope: `Sources/OuroWorkbenchCore/WorkbenchStore.swift` (+ its tests); doc-comment touch in `WorkspaceModels.swift`.
Status: done (committed + pushed; NOT merged — parent cold-reviews + merges).

## The bug

`WorkbenchStore.load` first `decoder.decode(WorkspaceState.self, from:)` — which
fully decodes every project / terminal / row, because the per-field decoders are
lenient (`decodeIfPresent` + defaults) — and THEN gated schemaVersion with an
EQUALITY check (`state.schemaVersion == currentSchemaVersion`).

Because the version check is a SEPARATE gate AFTER a successful decode, an OLDER
but fully-readable `workspace-state.json` was decoded intact and then wrongly
treated as "unreadable": quarantined aside (`.corrupt-<stamp>` sibling) and the
visible workspace reset to EMPTY. On upgrade, any backward-compatible older file
silently wiped the user's workspace view.

The decode-before-gate ordering is the key fact: the rows are already present in
`state` by the time the gate runs, so the only thing dropping them was the `==`.
The original `unsupportedStateVersion` / `stateWrittenByNewerWorkbench` naming and
the advisory ("written by a newer Workbench … your data is intact") already
assume the rejected case is a FUTURE file — the equality gate violated that intent
for older files.

## The fix

`WorkbenchStore.swift:~115`: replace the equality gate with
`state.schemaVersion <= WorkspaceState.currentSchemaVersion` (accept older/equal —
the lenient decoders already produced a usable state). Reject (quarantine for the
owning store; `unsupportedStateVersion` for read-only consumers) ONLY
`> currentSchemaVersion` — a file written by a FUTURE build whose shape can't be
safely interpreted. The forward-incompat quarantine/backup behavior is unchanged.

Also updated the `currentSchemaVersion` doc comment in `WorkspaceModels.swift` to
describe the `<=` read window instead of the stale "rejects any file whose
schemaVersion differs" wording.

Inverse-bug guard: a `> current` file is NOT loaded — that path still rejects /
quarantines. Only older/equal became readable.

## Tests (TDD; red → green)

Added to `WorkbenchStoreTests`:
- `testOlderSchemaVersionLoadsWithAllRowsIntactAndIsNotQuarantined` — older file
  (current-1) with a real project + terminal LOADS with all rows intact, no
  `.corrupt-` sibling. (Was red: wrongly quarantined.)
- `testEqualSchemaVersionLoadsWithRowsIntact` — current-version file still loads
  (regression).
- `testNewerSchemaVersionIsStillQuarantinedByOwningStore` — current+1 file is
  STILL quarantined by the owning store AND rejected as `unsupportedStateVersion`
  for the read-only consumer (forward-incompat preserved).
- `testSchemaVersionZeroIsTreatedAsOldestReadableAndLoads` — explicit oldest
  version (0, the accept-range lower boundary) loads, matching the
  lenient-decode intent. (Was red: wrongly quarantined.)

Tests use `WorkspaceState.currentSchemaVersion ± 1` so they don't go stale on a
future schema bump.

## Verify

- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
  — Build complete, 0 warnings/errors.
- `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
  — 2581 tests, 0 failures (1 pre-existing skip, unrelated).
- `Scripts/check-coverage.sh` — PASS; OuroWorkbenchCore 100% line+region;
  allowlist unchanged at 2 (`BossAgentMCPClient.swift`, `SessionActivityReader.swift`);
  `WorkbenchStore.swift` at 100%, not allowlisted.

## Commits

- `9576f56` test(core): older/equal schema files load, only newer rejects (red)
- `7c59486` fix(core): load older/equal workspace schemas, quarantine only newer (green)
