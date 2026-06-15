# Readiness Bug Hunt - Current Head

- Branch: `worker/product-center-of-gravity`
- Runtime commit packaged/installed: `fdb646d24cc4c295cb08d9c479fc9de328b9e360`
- Installed app: `/Users/arimendelow/Applications/Ouro Workbench.app`
- Installed version/build: `0.1.155` / `340`

## Findings

1. Installed app evidence was one commit behind the terminology cleanup.
   - Fixed by rebuilding, reinstalling, and reverifying the app from current head.

2. Current docs still had stale workspace/group and default-shell label wording in active readiness surfaces.
   - Fixed in `README.md`, `docs/guide.md`, `docs/product-tour.md`, `docs/surface-audit.md`, `docs/workbench-surface-spec.md`, `docs/cmux-workbench-test-matrix.md`, and broadened `validate-product-center-docs.sh`.

## Verification

- `validate-product-center-docs.sh`: pass.
- Current user-facing docs scan for the retired default-shell label: no matches.
- Repo text scan for the retired terminology: no matches outside ignored build/git internals.
- `swift test`: 933 tests, 1 skipped, 0 failures.
- `scripts/package-app.sh`: pass.
- `scripts/install-app.sh --install-dir "$HOME/Applications"`: pass.
- `scripts/verify-app-bundle.sh "$HOME/Applications/Ouro Workbench.app"`: pass.
- `validate-product-center-e2e.sh fresh reset imported_shell verify`: pass.
- Persisted-state assertions:
  - fresh root has `Unsorted Sessions`, no process entries, no retired default-shell label, no `This Mac`;
  - reset root consumes setup marker and returns to the same empty setup truth;
  - imported shell remains editable/managed, and delete-target shell is removed.
- MCP assertions:
  - `tools/list` includes `workbench_status`, `workbench_sessions`, `workbench_request_action`, and `workbench_create_session`;
  - `workbench_sessions` reports exactly the surviving `Imported User Shell` fixture;
  - fresh `workbench_sense` has no stale default session naming.
- Recent-session scanner:
  - focused scanner tests: 16 tests, 0 failures;
  - installed real-home diagnostic completed with no stderr and found candidates by aggregate source: Claude Code 1, cmux 1, OpenAI Codex 476.
- `scripts/smoke-support-diagnostics-crash-reports.sh`: pass.
