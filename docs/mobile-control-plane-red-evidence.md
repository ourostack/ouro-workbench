# Mobile control plane test-first evidence

## Untouched baseline

- `scripts/check-swift-tests.sh` passed on reviewed base `d57d344fc801fc005769223c13def91a4df01c25`: the AppViews shard and 2,907 Core/Shell tests completed with zero failures; two existing tests were skipped.
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` passed.
- `scripts/check-coverage.sh` passed: 150 of 154 gated files reached exact 100% line and region coverage; the remaining four used only the repository's existing documented structural exclusions.
- `scripts/package-app.sh` built and signed `dist/Ouro Workbench.app`. The existing script prompted before replacing SwiftTerm's read-only checkout source during its supported resource-lookup patch, then completed successfully.

## Frozen red suite

Command: `swift test --filter 'Remote(AccountSafety|SessionSafety|Guardian|Operations)Tests'`

Observed result: exit 1 on 2026-09-06. Compilation failed because the frozen tests reference the absent production boundaries, beginning with `cannot find type 'RemoteAccountBroker' in scope`, `cannot find type 'RemoteProfileRegistry' in scope`, `cannot find 'RemoteResumeLedger' in scope`, and `cannot find 'RemoteGuardian' in scope`.

Intended failure: the reviewed base has no strict profile registry, account broker, session map, one-shot resume ledger, child supervisor, one-boot guardian, read-only doctor/observer, or checksummed standalone runtime installer. No production source or package manifest was changed before this red run.

## Relay supervisor status contract

Command: `scripts/test-remote-helper.sh`

Observed red: exit 1 after adding a real Relay supervisor fixture whose JSON uses the checked-in `status` field and requiring `doctor --json` to report `tripped`.

Intended failure: the helper was reading an obsolete `state` key, so every real Relay supervisor state would have been translated to `unknown`.

Green: `RemoteHealthCommands` now consumes `status`; the rebuilt real helper passed the complete account/session/shim smoke including the `tripped` doctor assertion.

Account scope: profile credential selection, environment scrubbing, owner checks, and the managed `gh`/`git` shims are fail-closed guardrails against accidental cross-account work. Copilot itself intentionally runs with `--allow-all`, so this design does not claim OS-level confinement or protection against a worker deliberately invoking another absolute executable or reading host credentials outside the shims.

## Active runtime rollback safety

Command: `swift test --filter RemoteOperationsTests/testRollbackCannotDeleteTheActiveRuntimeWhenACallerClaimsNoNativeReferences`

Observed red: exit 1. A false caller assertion returned `removed`, deleted the active version, and deleted its `current` pointer.

Intended failure: rollback trusted an externally supplied assertion about native references instead of preserving the helper that an active Herdr generation may still need for cold resume.

Green: active revisions are now retained regardless of a caller assertion, the CLI no longer accepts that assertion, and its rollback path always retains the helper for native resume. The 31-operation-test plus seven-contract-test gate passed.

## Standalone helper artifact

Command: `scripts/test-package-remote-helper.sh`

Observed red: exit 127 because no standalone packaging path existed. A first green shell implementation proved the artifact shape, then the policy-bearing packaging logic was deliberately moved into the covered helper before delivery.

Intended failure: there was no checkout-to-versioned-artifact path, so Gate 3R could only run the helper directly from `.build`.

Green: `OuroWorkbenchRemote package` now packages its own exact executable from an exact clean Git worktree root without a production release shell. The helper SHA-256 remains the independently supplied binary trust anchor; the manifest revision is derived from the full clean `HEAD`, must match the requested revision, and is rechecked with the exact staged tree immediately before promotion and as the unchanged manifest/tree contract after promotion. The Core fixture and real-binary smoke prove a new-path-only, mode-0700 artifact containing exactly one mode-0755 helper and a mode-0600 manifest; invalid or mismatched revisions, staged/unstaged/untracked dirt, portable path collisions, missing or non-executable helpers, symlinked and hard-linked helpers, physical-ancestor retargeting, interrupted builds, staging tampering, cleanup, and output replacement are rejected.

The independent installed-runtime smoke then removes the source artifact, executes `--version` solely from the checksummed version root, exercises CLI rollback, and proves both the active pointer and helper remain intact for native resume.
