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

---

## Progress log

- 2026-06-21 19:47 Unit 1 (Seam A) complete — `WorkbenchToolsInjectionProbe.swift` + tests. `WorkbenchToolsInjection {present, absent}`; `verdict(fromToolNames:)` reuses `WorkbenchGuide.advertisedToolNames.contains` (no hand-rolled prefix); `toolNames(fromToolsListJSON:)` tolerant `JSONSerialization` parse with every guard arm (bad JSON / non-object root / no result / no tools / non-array tools / non-object entry / nameless entry). 19 tests green incl. silent-strip `["ask","status","catchup"] → .absent`.
- 2026-06-21 19:49 Unit 2 (Seam B) complete — `OuroVersionFloor.swift` + tests. `OuroWorkbenchMCPSupport {supported, tooOld, unknown}`; `support(forVersionString:)` locates `alpha.<N>`, reads leading digits, compares to `minimumAlpha = 660`. `.unknown` for no-token / non-numeric / `alpha.` — pinned NEVER to block. 13 tests green.
- 2026-06-21 19:51 Unit 3 (Client) complete — `BossAgentMCPClient.listToolNames(agentName:)`. Mirrors `callTool`: spawns `ouro` + `mcpServeArguments(agentName:)` (same `--workbench-mcp`), writes `initialize` (id 1) + `tools/list` (id 2, via new public `toolsListRequest(id:)`), reads the id-2 line VERBATIM (new `ProcessIOBox.readRawLine` / `rawLineIfMatching`), parses via the pure `WorkbenchToolsInjectionProbe.toolNames`. Reuses `timeoutNanoseconds`. Source-pin tests: arg shape == `mcpServeArguments`, `tools/list` body shape. Functional mock-ouro tests: injected→names, silent-strip→names, timeout, stderr, no-newline EOF, id-skip. Later refactored both readers onto one shared `readMatchingLine` loop for coverage (the single unreachable `while true` closing brace fits the PRE-EXISTING `BossAgentMCPClient.swift 1 3` allowlist budget — NO new allowlist entry). 35 tests green.
- 2026-06-21 20:01 Unit 4 (Wiring) complete — gated the handoff on confirmed injection.
  - New pure seam `WorkbenchHandoffGate.decide(statusPingSucceeded:injectionProbe:)` → `{awaitingHandoff, handedOff, toolsStripped}`. Distinguishes CONFIRMED `.absent` (hard blocker: stay awaiting + flag strip) from `.unconfirmed` (timeout/spawn-error → stay awaiting, NOT a blocker). Only `.handedOff` returns true to `AgentReadinessBootstrap`.
  - New `WorkbenchToolsInjectionProbeOutcome {confirmed(_), unconfirmed}`.
  - New registration status case `.toolsNotInjected` (binary on disk but tools stripped at runtime). Overlaid onto a `.registered` snapshot ONLY by `BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict(_:to:)` and ONLY on confirmed `.absent`; never upgrades a non-registered on-disk status.
  - `BossBridgeContract.bridgeVerdict` maps `.toolsNotInjected → .blocker` with copy naming `ouro alpha.660+` (no raw CLI verbs) — auto-lights autonomy `boss-mcp`, onboarding `workbench-mcp`, and drops `HarnessBossReachability.isReachable` from the single contract.
  - Exhaustive switches updated: `BossBridgeContract.bridgeVerdict`, `HarnessStatus.mcpStatusText`, `WorkbenchMCPRegistrationTruth.classify` (→ `.needsManual`), App `bossWorkbenchMCPStatusLine`/`Color`, `harnessTint`/`harnessShortLabel`, `registrationPillText`/`registrationTint`, `mcpPillText`/`mcpPillColor`. `HarnessStatus.state` had a `default` (→ `.blocked`, correct). `WorkbenchScenarioMatrix.registration` maps from a string with a `default` (no change).
  - Tests: `WorkbenchHandoffGateTests` (5), `WorkbenchToolsNotInjectedStatusTests` (incl. Codable round-trip across all 7 cases + overlay confirmed-only + never-upgrade-non-registered), extended `BossBridgeContractTests` severity + never-contradict loops to include `.toolsNotInjected`.
  - App wiring: `statusPing` closure now ANDs `status` with `listToolNames`→verdict via the gate; records the verdict into a thread-safe `WorkbenchToolsInjectionRecorder` (off-main), drained on the main actor in `completeFirstRunBootstrap` BEFORE `refreshWorkbenchMCPRegistration` (which applies the overlay). Probe runs ONCE per bringup; cached into `@Published bossWorkbenchToolsInjectionByAgentName` — never per readiness getter. A confirmed strip is audited in the `recordActionLog` lane (raw `mcp-serve`/`--workbench-mcp` verbs allowed there only).
  - Full suite: 2193 tests, 0 failures, strict build clean, coverage gate PASS (Core 100%, no new allowlist entries).
- 2026-06-21 Unit 5 (optional `ouro --version` fast-path) DEFERRED — out of scope per the doc ("No `ouro --version` invocation exists yet — adding one is in scope only for the message fast-path, not required for the core gate"). The authoritative gate is the `tools/list` probe (Seam A); `OuroVersionFloor` (Seam B) is shipped and ready to sharpen copy when/if a version string is obtained, but no `ouro --version` spawn is added.
- 2026-06-21 Cold-review (adversarial fold-bug pass over the 6 documented App-fold risks): Items 1–5 CLEAN — probe runs once at the handoff edge only (single `listToolNames` caller, never a per-getter spawn); timeout/spawn-error stays `.unconfirmed` → `awaitingHandoff`, never a blocker; `.absent` never reports `.handedOff` (`AgentReadinessBootstrap.run()` calls `statusPing` once and returns, no loop); overlay flips only on confirmed-`.absent` against `.registered`; recorder drained before `refreshWorkbenchMCPRegistration` in the same main-actor pass. Item 6 (MINOR, safe direction — a sticky false-BLOCKER, never a false-green): a boss re-selected after being stripped under an OLD ouro could inherit a stale `.toolsNotInjected` if ouro was upgraded without a bootstrap in between. FIXED — `selectBoss` now clears the incoming boss's cached injection verdict so its next bootstrap re-probes (commit 92c97fd). The Core recovery contract (a `nil` cached verdict leaves the on-disk status standing) was already pinned by the overlay's `nil` test.

---

## Completion

Status: **done**. Units 1–4 landed (Unit 5 deferred per the doc as out-of-scope). Strict TDD red→green throughout; per-unit commits on `fix/f9-version-floor-tools-probe`; no push/PR/merge.

Gates:
- **Implementation coverage:** every unit committed and matches its spec description; locked decisions verified present in the diff (reuse `advertisedToolNames` not `hasPrefix`; `minimumAlpha=660`; `.unknown` never blocks; `timeoutNanoseconds` reused; seam-aware copy — raw `mcp-serve`/`--workbench-mcp` verbs only in the `recordActionLog` audit lane).
- **Build:** `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — clean.
- **Tests:** full suite 2196 tests, 1 skipped, 0 failures (strict flags).
- **Coverage:** `Scripts/check-coverage.sh` PASS — Core 100% line+region; NO new allowlist entries (the consolidated single read-loop's unreachable `while true` closing brace fits the pre-existing `BossAgentMCPClient.swift 1 3` budget; the three pure seams are fully covered).
- **PR review (design match):** all spec-locked decisions + CRITICAL/IMPORTANT fold risks verified in the implementation, not just documented.
