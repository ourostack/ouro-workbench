# [F9] DOING-SPEC — ouro version-floor / `workbench_*` injection probe

> P1 · operator + boss · capability: ouro daemon / CLI / bridge
> Backlog source: `docs/fre-functional-backlog.md:144`
> Model: pure logic → Core seams (100% line+region); App target = source-pin tests.
> **No `swift build` / `swift test` while another build is in flight.**

---

## 1. Root cause (file:line)

The boss↔Workbench "connected" verdict is derived from **on-disk facts only** — the
Workbench MCP binary existing + the boss bundle being clean — and from a `status`
round-trip against the **boss's own** tool. Neither path ever asks the live
`mcp-serve` process *"did you actually inject the `workbench_*` tools?"*. So an older
`ouro mcp-serve` that silently ignores `--workbench-mcp` (the flag is `alpha.660+`
only) strips every `workbench_*` tool yet reads fully green.

The trust happens in three concrete places, all keyed on `mcpStatus == .registered`:

- **`Sources/OuroWorkbenchCore/HarnessStatus.swift:320-322`** —
  `HarnessBossReachability.isReachable` = `bundleIsReady && mcpStatus == .registered`.
  `mcpStatus` is the registrar's on-disk snapshot status. This is the literal
  `isReachable` the bug names: it equates "binary on disk + bundle clean" with
  "boss can drive Workbench".

- **`Sources/OuroWorkbenchCore/BossAgentBridge.swift:206-256`** (`BossWorkbenchMCPRegistrar.snapshot`)
  — returns `.registered` purely from `isExecutableFile(mcpExecutableURL)` +
  "bundle has no stale entry" (`BossAgentBridge.swift:224-247`). Its own doc comment
  (`BossAgentBridge.swift:204-205`) admits *"the boss actually HAVING the tools at
  runtime is confirmed separately by the handoff round-trip (`BossAgentMCPClient.status`)"*
  — but that round-trip (below) does NOT confirm injection.

- **`Sources/OuroWorkbenchCore/BossBridgeContract.swift:88-95`** — `bridgeVerdict`
  maps `.registered → .ok`. Both readiness surfaces derive from this one contract:
  - autonomy/TTFA: `AutonomyReadiness.swift:131-133` (`mcpCheck` → `boss-mcp` check),
  - onboarding wizard: `Onboarding.swift:362-371` (the `workbench-mcp` repair step only
    fires on a `.blocker`; `.registered` ⇒ `.ok` ⇒ no step ⇒ "ready",
    `Onboarding.swift:401-407`).

**The handoff edge does not save us.** `AgentReadinessBootstrap` reports `.handedOff`
on the first successful **`statusPing`** (`AgentReadinessBootstrap.swift:308-311`),
wired in the App at **`OuroWorkbenchApp.swift:17131-17134`** to
`client.status(agentName:)`. That calls `tools/call` with name **`status`**
(`BossAgentMCPClient.swift:73-75`) — the **boss agent's own** `status` tool, NOT a
`workbench_*` tool (`status` is absent from `WorkbenchGuide.advertisedToolNames`;
the workbench one is `workbench_status`). An old `mcp-serve` answers `status` fine,
so handoff + reachability both go green with zero Workbench tools injected.

**Where the version floor is enforced: nowhere.** There is no `ouro --version`
probe and no `alpha.660` constant anywhere in `Sources/` (grep: only the Workbench
app's own `WorkbenchRelease.version` at `WorkbenchRelease.swift:9`, and a `660` that's
a SwiftUI `.frame(maxWidth: 660)`). The app has no way today to learn the ouro version
or whether `--workbench-mcp` is supported.

**Why a `tools/list` probe is the right fix.** `BossAgentMCPClient` currently exposes
**only `tools/call`** (`BossAgentMCPClient.swift:233-243`) — there is no `tools/list`
call. The MCP wire shape is already proven: the server answers `tools/list` with
`{"result":{"tools":[{"name":…,"description":…,"inputSchema":…}]}}`
(`OuroWorkbenchMCPMain.swift:122-123`, `983-…`), and `scripts/smoke-mcp-tool-catalog.sh`
already drives a real binary's `tools/list` and asserts the names equal
`WorkbenchGuide.advertisedToolNames`. When the boss is spawned
`ouro mcp-serve --agent <boss> --workbench-mcp <path>` (`BossAgentBridge.swift:37-48`),
an `alpha.660+` runtime injects the `workbench_*` tools INTO that list; an old runtime
returns only the boss's native ouro tools (no `workbench_*`). So a post-bringup
`tools/list` that looks for any `workbench_*` name is the direct, version-agnostic
injection check.

---

## 2. Core seam(s) to TDD (pure, 100% line+region)

Two pure verdict functions in `Sources/OuroWorkbenchCore/`. Both are framework-free,
deterministic, and exhaustively testable with string/array fixtures — no live process.

### Seam A — `WorkbenchToolsInjectionVerdict` (the `tools/list` → present|absent verdict)

New file `Sources/OuroWorkbenchCore/WorkbenchToolsInjectionProbe.swift`.

```
public enum WorkbenchToolsInjection: String, Equatable, Sendable {
    case present   // ≥1 workbench_* tool appeared in the live tools/list
    case absent    // tools/list answered, but ZERO workbench_* tools (silent-strip)
}

public enum WorkbenchToolsInjectionProbe {
    /// Pure verdict from the tool names a live `tools/list` returned.
    /// `present` iff at least one name is in `WorkbenchGuide.advertisedToolNames`.
    public static func verdict(fromToolNames names: [String]) -> WorkbenchToolsInjection

    /// Pure parse of a raw JSON-RPC `tools/list` response line → tool names.
    /// Tolerant: missing/!object/!result/!tools/empty ⇒ []; ignores nameless entries.
    public static func toolNames(fromToolsListJSON line: String) -> [String]
}
```

Recognition reuses the canonical set: a name counts iff
`WorkbenchGuide.advertisedToolNames.contains(name)` (`WorkbenchGuide.swift:160-179`).
Do NOT hand-roll a `hasPrefix("workbench_")` — reusing `advertisedToolNames` keeps the
probe locked to the same single source `bossTools` and the smoke already pin, and is
robust if a non-`workbench_`-prefixed tool is ever added.

**Test cases (`Tests/OuroWorkbenchCoreTests/WorkbenchToolsInjectionProbeTests.swift`):**

| input (tool names) | expected |
|---|---|
| `["workbench_status","ask","status"]` | `.present` |
| every name in `advertisedToolNames` | `.present` |
| `["ask","status","catchup"]` (old `mcp-serve`, boss-native only) | **`.absent`** ← the silent-strip case |
| `[]` | `.absent` |
| `["Workbench_Status"]` (case mismatch) | `.absent` (exact match only) |
| one valid + many invalid | `.present` |

JSON-parse cases (`toolNames(fromToolsListJSON:)`):

| input line | expected names |
|---|---|
| `{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"workbench_status"},{"name":"ask"}]}}` | `["workbench_status","ask"]` |
| `…"result":{"tools":[]}` | `[]` |
| `…"result":{}` (no `tools`) | `[]` |
| `{"error":{"message":"x"}}` | `[]` |
| `not json` | `[]` |
| tools entry missing `name` | skipped |

> Region coverage: cover every guard arm in `toolNames` (bad JSON / not-object /
> no-result / no-tools / non-array / nameless entry) and both `verdict` branches.

### Seam B — `OuroVersionFloor` (the version-string → supports-`--workbench-mcp` check)

New file `Sources/OuroWorkbenchCore/OuroVersionFloor.swift`. A defense-in-depth /
operator-messaging seam (the `tools/list` probe in Seam A is the real gate; the floor
turns an `absent` verdict into an actionable *"your ouro is too old"* message and lets
the app fast-path before even spawning a turn if it has the version).

```
public enum OuroWorkbenchMCPSupport: String, Equatable, Sendable {
    case supported       // ouro is alpha.660 or newer
    case tooOld          // ouro recognized but below the floor
    case unknown         // version string couldn't be parsed → don't block on it
}

public enum OuroVersionFloor {
    public static let minimumAlpha = 660
    /// Parse an `ouro --version` string → support verdict. Tolerant of leading
    /// text / prefixes (`ouro 1.2.3-alpha.660`, `alpha.661`, `v…`). Unparseable ⇒ `.unknown`.
    public static func support(forVersionString raw: String) -> OuroWorkbenchMCPSupport
}
```

Parsing rule (keep it narrow — see Open Risks): locate an `alpha.<N>` token and compare
`<N>` to `minimumAlpha`. Prior art for splitting exists in
`ReleaseUpdate.swift:313-342` (`SemanticVersion`) — mirror its tolerance style (strip a
`-…` suffix, `Int(...)` guard) but DON'T force a strict 3-part semver, since ouro
versions carry an `-alpha.NNN` channel the floor keys on.

**Test cases (`Tests/OuroWorkbenchCoreTests/OuroVersionFloorTests.swift`):**

| input | expected |
|---|---|
| `"ouro 0.9.0-alpha.660"` | `.supported` (== floor) |
| `"alpha.661"` | `.supported` |
| `"ouro 0.9.0-alpha.659"` | `.tooOld` |
| `"ouro 0.9.0-alpha.12"` | `.tooOld` |
| `"ouro 0.9.0"` (no alpha token) | `.unknown` |
| `""` / `"garbage"` | `.unknown` |
| `"alpha.abc"` | `.unknown` |
| whitespace / extra prose around a valid token | `.supported`/`.tooOld` per N |

> `.unknown` must NEVER hard-block (a parse miss is not evidence of "too old") — the
> `tools/list` probe is the authority; the floor only sharpens messaging.

---

## 3. App-side wiring

The injection probe runs **once per bringup, right at the handoff edge**, replacing the
boss-native `status` ping as the readiness gate (or, lower-risk, ANDed with it).

**Add to `BossAgentMCPClient`** (`Sources/OuroWorkbenchCore/BossAgentMCPClient.swift`):
a `listToolNames(agentName:)` that mirrors `callTool` — spawns
`ouro` + `mcpServeArguments(agentName:)` (so `--workbench-mcp` is passed identically,
`BossAgentMCPClient.swift:57-67`), writes `initialize` (id 1) then a `tools/list`
request (id 2, `method:"tools/list"`, sibling of `toolCallRequest` at line 233-243),
reads the id-2 line, and returns `WorkbenchToolsInjectionProbe.toolNames(...)`. The
private `MCPResponse`/`MCPToolResult` decoders (line 267-283) only model tool-call
results, so parse `tools/list` via the new pure `toolNames(fromToolsListJSON:)` seam
rather than extending those.

**Gate the handoff** (`OuroWorkbenchApp.swift:17131-17134`, the `statusPing` closure):
after (or instead of) the `status` round-trip, call `listToolNames`, run
`WorkbenchToolsInjectionProbe.verdict(...)`, and return `true` only on `.present`.
`.absent` ⇒ stay `.awaitingHandoff` (`AgentReadinessBootstrap.swift:309-311` already
maps a `false` ping to `.awaitingHandoff`) — never report `.handedOff` with stripped
tools. Carry the `.absent` outcome into a new registration status so the readiness
surfaces flip loud (next bullet).

**Flip `.registered` to require injection.** Today `bossWorkbenchMCPRegistration`
(consumed by `HarnessStatus`, `AutonomyReadiness`, `Onboarding`, all via
`BossBridgeContract`) is purely the on-disk snapshot. Wire the probe's verdict in so a
present-but-stripped boss is NOT `.ok`:
- Add a `BossWorkbenchMCPRegistrationStatus` case (e.g. `.toolsNotInjected`) or thread
  the `WorkbenchToolsInjection` verdict alongside the snapshot. Map it to `.blocker` in
  `BossBridgeContract.bridgeVerdict` (`BossBridgeContract.swift:88-131`) with copy
  naming the floor ("Workbench tools didn't load — your `ouro` may be too old; update to
  `alpha.660+`"). This automatically lights the autonomy `boss-mcp` blocker
  (`AutonomyReadiness.swift:131-133`) and the onboarding `workbench-mcp` repair step
  (`Onboarding.swift:362-371`), and drops `HarnessBossReachability.isReachable`
  (`HarnessStatus.swift:320-322`) — all from the single contract, so the two surfaces
  stay consistent (the `BossBridgeContractTests` invariant).
- A new enum case touches the exhaustive `switch`es in `BossBridgeContract.swift:88`
  and `HarnessStatus.swift:337,356` (`mcpStatusText`) and the `Codable` round-trip
  test in `BossBridgeContractTests.swift:16-26` — update each.

**Optional fast-path (defense in depth):** if/when the app obtains `ouro --version`,
run `OuroVersionFloor.support(...)`; on `.tooOld` surface the update message without
spawning a turn. `.unknown`/`.supported` ⇒ fall through to the authoritative
`tools/list` probe. (No `ouro --version` invocation exists yet — adding one is in scope
only for the message fast-path, not required for the core gate.)

---

## 4. Open risks

- **Probe cost / timing — an extra round-trip per readiness eval?** `tools/list` spawns
  an `ouro mcp-serve` process just like `status` does (`BossAgentMCPClient.callTool`,
  `:108-146`). Do NOT run it on every `autonomyReadiness`/`harnessStatus` getter
  (`OuroWorkbenchApp.swift:11136,11151` are pure computed properties read frequently).
  Run it **once at the handoff edge** and cache the verdict into the published
  registration state (alongside `refreshWorkbenchMCPRegistration()`,
  `OuroWorkbenchApp.swift:17149`), re-probing only on explicit refresh / boss change —
  not on every popover open. Reuse `BossAgentMCPClient.timeoutNanoseconds`
  (`:37,48`) so a hung old `mcp-serve` can't wedge bringup; on timeout treat as
  `.absent`-but-unconfirmed (stay `awaitingHandoff`, surface "still bringing tools
  online"), not a hard blocker, to avoid a false "too old" on a slow cold start.

- **Version-string parsing fragility.** ouro's `--version` format isn't pinned here and
  may carry build metadata, `v` prefixes, or git hashes. Keep `OuroVersionFloor` narrow
  (find the `alpha.<N>` token; everything else ⇒ `.unknown`) and NEVER let `.unknown`
  block — the `tools/list` probe is the source of truth, the floor only sharpens copy.
  This avoids a parser bug locking out a perfectly good ouro.

- **What to surface when the floor isn't met.** The `.absent`/`.tooOld` path must give
  the operator an actionable, seam-aware line — *"Workbench tools didn't load for
  <boss>. Your `ouro` is too old; update to `alpha.660+`, then reopen Workbench."* Place
  it as the `.blocker` `detail` in `BossBridgeContract.bridgeVerdict` so BOTH the TTFA
  popover and the onboarding `workbench-mcp` repair step render it identically
  (the U17 single-source invariant). Honor the cohesive-product copy rule
  (`BootstrapResult.humanFacingLine`, `AgentReadinessBootstrap.swift:184-197`): raw
  `mcp-serve`/`--workbench-mcp` verbs belong only in the audit/action-log lane
  (`recordActionLog`, `OuroWorkbenchApp.swift:17153`), not the human-facing string —
  though "`ouro` alpha.660+" is an acceptable concrete version target to name.

- **Old `mcp-serve` that errors on `tools/list`.** If a sufficiently old runtime returns
  an RPC error (not just an empty list), `toolNames(fromToolsListJSON:)` returns `[]` ⇒
  `.absent` ⇒ correctly NOT ready. Covered by the JSON-parse `{"error":…} → []` case.

---

## Build order (PR-scoped units)

1. **Seam A** — `WorkbenchToolsInjectionProbe` + tests (pure; 100% cov incl. silent-strip + all JSON guards).
2. **Seam B** — `OuroVersionFloor` + tests (pure; 100% cov; `.unknown` never-block pinned).
3. **Client** — `BossAgentMCPClient.listToolNames(agentName:)` (source-pin test: arg shape == `mcpServeArguments`, `tools/list` request body).
4. **Wiring** — new registration status/verdict threading; update `BossBridgeContract` + `HarnessStatus` switches + the `BossBridgeContractTests` Codable/contract pins; gate the handoff `statusPing` closure on `.present`.
5. **(optional)** `ouro --version` fast-path for the too-old message.
