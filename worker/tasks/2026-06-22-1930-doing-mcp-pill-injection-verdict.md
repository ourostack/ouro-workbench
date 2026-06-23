# Doing: MCP-registration pill false-green — gate green on a confirmed-present injection probe

- **Branch:** `fix/mcp-pill-injection-verdict` (off `main` @ `4600b59`)
- **Execution Mode:** direct
- **Artifacts:** `./2026-06-22-1930-doing-mcp-pill-injection-verdict/`
- **Status:** done (committed + pushed; parent cold-reviews + merges)

## The bug (false-success family)
The MCP-registration pill renders GREEN "registered" off the registration STATUS alone, even
when no live injection probe has confirmed the `workbench_*` tools actually inject into the
boss at runtime. `applyingInjectionVerdict` only downgrades `.registered → .toolsNotInjected`
on a CONFIRMED `.absent`; a `nil` (never probed) / `.unconfirmed` / confirmed-`.present`-absent
verdict leaves the config-only `.registered` → all three pills read green.

The injection verdict (`WorkbenchToolsInjectionProbeOutcome`) is NOT consulted by any of the
three pill-presentation surfaces; they switch on status alone.

### Real enum cases (verified at HEAD)
- `WorkbenchToolsInjectionProbeOutcome`: `.confirmed(WorkbenchToolsInjection)` | `.unconfirmed`
- `WorkbenchToolsInjection`: `.present` | `.absent`
- **Confirmed-present = `.confirmed(.present)`** — the ONLY green-worthy verdict.
- `BossWorkbenchMCPRegistrationStatus`: `.registered`, `.notRegistered`, `.needsUpdate`,
  `.agentMissing`, `.executableMissing`, `.invalidConfig`, `.toolsNotInjected`.

## Units

### Unit 1 (Core) — `BossMCPPillPresentation` seam (pure, 100% line+region) ✅
New `Sources/OuroWorkbenchCore/BossMCPPillPresentation.swift`:
- `Tone`: `.verified` | `.unverified` | `.notInjected` | `.needsAttention` | `.notRegistered` | `.error`
- `tone(status:injection:)` — `.verified` reachable ONLY from `.registered` + `.confirmed(.present)`.
- `SemanticColor`: `.green` | `.neutral` | `.orange` | `.red`; `color(for:)`.
- `label(for:)`.
- Exhaustive switches, no `default`. Sweep test asserts green reachable ONLY for that one combo.

### Unit 2 (App) — route all three pills through the seam, threading the verdict ✅
- Agent-detail card (`AgentStatusCard`): tone from `registration.status` × `model…[agent.name]`.
- Boss-section pill (`OuroAgentRowView`): same with `agent.name`.
- Harness-diagnostic pill: add `HarnessAgentEntry.toolsInjection` (Core, additive, default nil);
  thread `injectionByAgentName` through `HarnessStatusBuilder.build` → `agentInventory`; App passes
  `bossWorkbenchToolsInjectionByAgentName`. Render via the seam.
- Keep `applyingInjectionVerdict`'s confirmed-absent downgrade as-is. Do NOT touch the harness
  rollup / reachability axes (only pill PRESENTATION changes).

## Verify (every unit)
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
- `swift test  -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
- `Scripts/check-coverage.sh` (Core 100% line+region; allowlist unchanged at 2)

## Completion gates
- [x] Green (`.verified`) reachable ONLY from `.registered` + `.confirmed(.present)`. (Unit 1)
- [x] Registered+unverified reads NEUTRAL (pending), never red/error (the #262 inverse-bug watch). (Unit 1 + 2)
- [x] Confirmed-present still reads green at all three surfaces. (Unit 2)
- [x] All three pills route through `BossMCPPillPresentation` with the injection verdict. (Unit 2)
- [x] `HarnessAgentEntry` carries `toolsInjection`; builder + App `harnessStatus` thread it. (Unit 2)
- [x] Harness rollup/reachability axes untouched (`isReachable`/`state` still status-only). (Unit 2)
- [x] Core 100% line+region; allowlist unchanged at 2; 0 test failures; warnings-as-errors clean.

## Flagged (out of scope — "flag, don't silently change" per brief)
- `OuroWorkbenchApp.swift:~1389` boss-reachability detail row colors the boss's MCP status via
  `status.boss.mcpStatus.harnessTint` (status-only) — and `HarnessBossReachability.mcpStatusText`
  reads "available at runtime" for a `.registered` boss. Both STILL false-green a
  registered-but-unverified boss. This is the boss-REACHABILITY surface (`HarnessBossReachability`
  carries no injection verdict), NOT one of the three named pills, and the brief told me to keep
  reachability on its existing status-based axes. Threading the verdict here would require touching
  the reachability type — left out of scope, flagged for a follow-up.

## Progress log
- 2026-06-22 20:26 Unit 1 complete: `BossMCPPillPresentation` seam — tone/color/label, green ONLY from `.registered`+`.confirmed(.present)`, registered+unverified→NEUTRAL (never red). 10 sweep tests green; Core 100% line+region; allowlist unchanged at 2; full suite 2562 pass.
- 2026-06-22 20:45 Unit 2 complete: all 3 pills (agent-detail card, boss-section row, harness-diagnostic) route through the seam with the live verdict; `HarnessAgentEntry.toolsInjection` (additive) threaded by `HarnessStatusBuilder.build` ← App's `bossWorkbenchToolsInjectionByAgentName`. Removed dead status-only pill helpers; fixed one upstream slice-anchor test that pinned on a removed helper. Reachability/rollup axes untouched; `applyingInjectionVerdict` untouched. Flagged the boss-reachability detail row (line 1389) as a residual out-of-scope false-green. Full suite 2570 tests, 0 failures; Core 100% line+region; allowlist 2; strict build clean.
