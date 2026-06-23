# Doing: MCP-registration pill false-green — gate green on a confirmed-present injection probe

- **Branch:** `fix/mcp-pill-injection-verdict` (off `main` @ `4600b59`)
- **Execution Mode:** direct
- **Artifacts:** `./2026-06-22-1930-doing-mcp-pill-injection-verdict/`
- **Status:** in progress

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

### Unit 2 (App) — route all three pills through the seam, threading the verdict
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
- [ ] Registered+unverified reads NEUTRAL (pending), never red/error (the #262 inverse-bug watch).
- [ ] Confirmed-present still reads green at all three surfaces.
- [ ] All three pills route through `BossMCPPillPresentation` with the injection verdict.
- [ ] `HarnessAgentEntry` carries `toolsInjection`; `refreshHarnessStatus`/builder thread it.
- [ ] Harness rollup/reachability axes untouched.
- [ ] Core 100% line+region; allowlist unchanged at 2; 0 test failures; warnings-as-errors clean.

## Progress log
- 2026-06-22 20:26 Unit 1 complete: `BossMCPPillPresentation` seam — tone/color/label, green ONLY from `.registered`+`.confirmed(.present)`, registered+unverified→NEUTRAL (never red). 10 sweep tests green; Core 100% line+region; allowlist unchanged at 2; full suite 2562 pass.
