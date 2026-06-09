# Doing: Repoint Workbench to runtime-injection MCP model

Status: done
Execution Mode: direct
Branch: first-run-agent-drives-ui
Planning: (none — spec is the task prompt)
Artifacts: ./2026-06-08-1639-doing-runtime-injection-repoint/

## Goal
Stop writing `ouro_workbench` + `senses.workbench` into the boss's synced `agent.json`.
Instead pass `--workbench-mcp <path>` at runtime when Workbench connects to the boss via
`ouro mcp-serve --agent <boss>`. Repoint readiness/action/S5 from "is it in the bundle"
to "is the MCP binary present on disk for runtime injection (+ bundle is clean of stale
entries)".

## Mental model after this change
- `.registered` now means: the Workbench MCP **binary is present on disk** (runtime
  injection available) AND the boss bundle is clean (no stale `ouro_workbench` /
  `senses.workbench`).
- `.notRegistered` now means: the binary is **missing** (runtime injection unavailable).
- `install(for:)` no longer writes the bundle; it now performs a **cleanup migration**:
  removes any stale `ouro_workbench` from `mcpServers` and disables `senses.workbench`.
- The boss actually HAVING the tools is confirmed by the existing `status` handoff
  round-trip — unchanged.

## Units

### Snapshot-state mapping (LOCKED DECISION)
Under runtime injection the registrar's `snapshot` means:
- binary present + bundle clean → `.registered` (runtime injection available)
- binary present + stale `ouro_workbench`/`senses.workbench` in bundle → `.needsUpdate`
  (cleanup-pending; the action/S5 runs the cleanup, re-snapshot reads `.registered`)
- binary missing → `.notRegistered` (reinstall Workbench; NOT auto-recoverable)
- agent bundle missing → `.agentMissing`; unsafe name / unparseable → `.invalidConfig`
`classify`: `.registered`→registered; `.needsUpdate`→stillUnregistered (cleanup retries);
`.notRegistered`/`.agentMissing`/`.executableMissing`/`.invalidConfig`→needsManual.
`install(for:)` no longer WRITES the bundle — it REMOVES stale `ouro_workbench` from
`mcpServers` and removes `senses.workbench`.

### Unit 1a (test): boss-bridge + MCP client pass `--workbench-mcp` ✅
- Test `mcpServePlan` appends `--workbench-mcp <path>` when a path is supplied.
- Test `BossAgentMCPClient` builds args with `--workbench-mcp <path>` when configured.

### Unit 1b (impl): pass the flag in both spawn sites ✅
- `BossAgentBridgePlanner.mcpServePlan` appends `--workbench-mcp <path>`.
- `BossAgentMCPClient.callTool` appends `--workbench-mcp <path>` (path-less fallback when unresolved).
- App wires resolved path into `bossMCPClient.workbenchMCPPath` + `bossMCPCommand`.

### Unit 2a (test): registrar cleanup + reinterpreted snapshot ✅
### Unit 2b (impl): rewrite registrar to runtime model ✅
- `install(for:)` removes stale `ouro_workbench` + `senses.workbench`, writes only if changed,
  NEVER writes the workbench server/sense.
- `snapshot`: binary present + clean → `.registered`; present + stale entry → `.needsUpdate`;
  binary missing → `.notRegistered`; bundle missing → `.agentMissing`; bad name → `.invalidConfig`.
- `classify`: `.notRegistered` → `.needsManual` (binary missing, reinstall); `.needsUpdate` →
  `.stillUnregistered` (cleanup retries).

### Unit 3a (test): readiness + S5 + action repointed ✅
### Unit 3b (impl): repoint readiness/action/S5 ✅
- Readiness `workbench-mcp` step title "Connect Workbench tools"; ready detail runtime framing.
- S5 effect + `startRegisterWorkbenchMCP` + `registrationHealth` doc repointed.
- `AutonomyReadiness.mcpCheck` copy repointed to runtime model.
- `OuroWorkbenchMCP/main.swift` createSession doc repointed (no more bundle-write claim).

### Unit 4: full suite + build green, commit, report ✅

## Completion Criteria
- [x] `--workbench-mcp <path>` passed in `mcpServePlan` and `BossAgentMCPClient`
- [x] `install(for:)` no longer writes bundle; cleans stale entries
- [x] readiness `workbench-mcp` step means "binary present for runtime injection"
- [x] S5 + `registerWorkbenchMCP` action repointed to binary-present + cleanup
- [x] `.registered`/`.notRegistered` reinterpreted; seam-free copy updated
- [x] one-boss invariant preserved; no per-agent bundle registration reintroduced
- [x] `swift build` + `swift test` green; no warnings
- [x] recovery-truth preserved; R2 livePrompt floor untouched

## Progress Log
- 2026-06-08 16:39 doing doc created; baseline build green (822-ish tests expected).
- 2026-06-08 17:40 Unit 1a/1b: both spawn sites pass `--workbench-mcp`; app wires resolved path.
- 2026-06-08 17:46 Unit 2a/2b: registrar stops writing bundle; cleans stale entries; runtime snapshot.
- 2026-06-08 17:55 Unit 3a/3b: readiness/S5/action/autonomy + all human-facing copy repointed.
- 2026-06-08 17:55 Gates: impl-coverage ✅ | swift build + 834 tests green ✅ | no warnings ✅ |
  PR-review vs spec ✅ (both spawn sites pass flag; bundle-write gone; cleanup removes stale).
