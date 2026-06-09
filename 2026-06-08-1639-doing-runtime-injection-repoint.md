# Doing: Repoint Workbench to runtime-injection MCP model

Status: in-progress
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

### Unit 2a (test): registrar cleanup + reinterpreted snapshot ⬜
- `install(for:)` removes stale `ouro_workbench` and disables `senses.workbench`.
- `snapshot` reads `.registered` when binary present + bundle clean; `.notRegistered`
  when... binary present but stale entry remains? (cleanup-pending) — see design.
- `snapshot` reads `.executableMissing` → maps to runtime-unavailable.

### Unit 2b (impl): rewrite registrar to runtime model ⬜

### Unit 3a (test): readiness + S5 + action repointed ⬜
### Unit 3b (impl): repoint readiness/action/S5 ⬜

### Unit 4: full suite + build green, commit, report ⬜

## Completion Criteria
- [ ] `--workbench-mcp <path>` passed in `mcpServePlan` and `BossAgentMCPClient`
- [ ] `install(for:)` no longer writes bundle; cleans stale entries
- [ ] readiness `workbench-mcp` step means "binary present for runtime injection"
- [ ] S5 + `registerWorkbenchMCP` action repointed to binary-present + cleanup
- [ ] `.registered`/`.notRegistered` reinterpreted; seam-free copy updated
- [ ] one-boss invariant preserved; no per-agent bundle registration reintroduced
- [ ] `swift build` + `swift test` green; no warnings
- [ ] recovery-truth preserved; R2 livePrompt floor untouched

## Progress Log
- 2026-06-08 16:39 doing doc created; baseline build green (822-ish tests expected).
