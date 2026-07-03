# AppViews local-test hang — CLOSED (coverage is no longer CI-only)

**Status:** RESOLVED. The historical "AppViews tests hang locally, so AppViews coverage can
only be measured on CI" constraint is empirically dead. The full coverage gate now runs green
end-to-end on a local macOS machine.

## The asterisk (historical)

The `OuroWorkbenchAppViewsTests` suite used to hang when run locally, which forced the whole U5
coverage campaign to measure `WorkbenchViews.swift` / `WorkbenchViewModel.swift` on CI only. Two
blocking call classes were suspected in the campaign notes:

- `NSFullUserName()` → wakes the live Contacts / CoreData / XPC store during owner-name resolution.
- `NSSavePanel().runModal()` / `NSOpenPanel().runModal()` → live modal panels that deadlock a
  headless test process.

## What fixed it (already landed — no new work needed)

The campaign's own seam work closed the hang, shipped in **v0.1.211 — "Hermetic Swift-test and
coverage shards"** (see CHANGELOG.md):

- Owner-name resolution routes through an XCTest-safe seam — `SessionFriend.resolvedMachineOwner`
  carries an `isRunningUnderXCTest` guard that uses the short-username fallback instead of calling
  the live `NSFullUserName()` lookup under test.
- The workspace/directory panels are behind injectable seams (`chooseWorkspaceOpenURL`,
  `chooseWorkspaceSaveURL`, `chooseDirectory`) defaulting to the real `runModal()` only outside tests.
- `scripts/check-coverage.sh` runs the suite in per-target shards and enforces a no-Contacts/CoreData/
  XPC-noise contract per shard (`scripts/check-test-log-noise.sh`).

There was **no remaining seam to add** — the hang was already gone at HEAD. This note records the
verification the overnight investigation (agent `a64820b0`) was performing when its session died on
an API-key error before it could write up.

## Verification (current main `c4ebecc` / v0.1.241, local macOS, Apple Swift 6.0.3)

- AppViews shard, the exact CI-only trigger condition:
  `swift test --enable-code-coverage --filter OuroWorkbenchAppViewsTests`
  → **1570 tests, 0 failures, ~72s, exit 0.** No hang. No Contacts/CoreData/XPC noise.
- Full gate, both shards end-to-end: `./scripts/check-coverage.sh`
  → **PASS in ~2.5 min.** `149/154 files at 100% line+region (5 allowlisted structural exclusions)`;
  the per-shard no-noise contract passed; 0 test failures.
- CI runs the **identical** script (`.github/workflows/ci.yml` → `run: scripts/check-coverage.sh`),
  and `check-coverage.sh` has no CI-environment guard and no local skip — it runs the AppViews shard
  unconditionally. Local and CI are the same path.

## Consequence

Any engineer can now run the complete per-file-100% line+region gate locally in ~2.5 min, including
the AppViews surface that used to be CI-only. The "AppViews can't run locally" folklore is retired.

## Follow-up (NOT done here — needs an explicit decision)

`scripts/preflight.sh` does **not** currently run `check-coverage.sh` (its gates are build / tests /
scenario-verifier / bundle, not the coverage gate). Now that the gate runs locally, wiring it into
preflight would catch coverage regressions before push. That is deliberately left as a decision, not
shipped here, because: (1) `scripts/*` is a release-relevant path (`release-policy.sh` freshness), so
the change would need a `VERSION` bump and would publish a prerelease; and (2) it adds ~2.5 min to
the local preflight — a workflow-cost tradeoff worth deciding on purpose.
