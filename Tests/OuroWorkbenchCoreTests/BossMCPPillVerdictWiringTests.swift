import XCTest
@testable import OuroWorkbenchCore

/// Durable source-pin assertions for the MCP-pill injection-verdict fix. The App target
/// isn't coverage-gated and can't be click-tested in CI, so — exactly like
/// `AgentReadinessOverlayWiringTests` / `ColdStartHonestWiringTests` — we pin the structural
/// wiring in source: each of the three MCP-pill render sites must compute its colour + text
/// from `BossMCPPillPresentation` folding the registration STATUS with the live injection
/// VERDICT (`bossWorkbenchToolsInjectionByAgentName`), never from the status alone. A
/// status-only pill is the false-green this fix removes.
final class BossMCPPillVerdictWiringTests: XCTestCase {

    // MARK: - Core: HarnessAgentEntry carries the injection verdict, threaded by the builder

    /// `HarnessAgentEntry` must carry the per-agent injection verdict so the harness-diagnostic
    /// pill can render verdict-aware. Additive (default nil) so existing constructions compile.
    func testHarnessAgentEntryCarriesToolsInjectionVerdict() {
        let entry = HarnessAgentEntry(
            name: "boss",
            status: .ready,
            detail: "",
            isSelectedBoss: true,
            mcpStatus: .registered,
            toolsInjection: .confirmed(.present)
        )
        XCTAssertEqual(entry.toolsInjection, .confirmed(.present))
    }

    /// The verdict defaults to nil so every pre-existing `HarnessAgentEntry(...)` keeps compiling.
    func testHarnessAgentEntryToolsInjectionDefaultsNil() {
        let entry = HarnessAgentEntry(
            name: "boss",
            status: .ready,
            detail: "",
            isSelectedBoss: false
        )
        XCTAssertNil(entry.toolsInjection)
    }

    /// The harness builder must thread a per-agent injection-verdict map into the entries it
    /// builds — so the harness pill renders the SAME verdict the steady-state rows compute.
    func testHarnessStatusBuilderThreadsInjectionVerdictIntoEntries() {
        let builder = HarnessStatusBuilder()
        let agent = OuroAgentRecord(
            name: "boss",
            bundlePath: "/bundle",
            configPath: "/cfg",
            status: .ready,
            detail: ""
        )
        let registration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss",
            serverName: "workbench",
            commandPath: "/usr/bin/ouro",
            agentConfigPath: "/cfg",
            status: .registered,
            detail: ""
        )
        let status = builder.build(
            boss: BossAgentSelection(agentName: "boss"),
            dashboard: nil,
            agents: [agent],
            bossRegistration: registration,
            registrationByAgentName: ["boss": registration],
            injectionByAgentName: ["boss": .confirmed(.present)]
        )
        let entry = status.agents.entries.first { $0.name == "boss" }
        XCTAssertEqual(
            entry?.toolsInjection, .confirmed(.present),
            "the builder must thread injectionByAgentName into each HarnessAgentEntry.toolsInjection"
        )
    }

    /// The reachability/rollup axis must NOT regress: a config-installed + registered boss
    /// whose injection is merely unverified (nil) stays reachable AND keeps the WHOLE rollup
    /// healthy when the daemon is up — `boss.state == .healthy`, `overallState == .healthy`,
    /// and the headline carries no "not reachable". This is the explicit no-false-RED lock:
    /// the detail-row presentation goes neutral, but the structural reachability axes stay
    /// byte-identical and never tip the unverified-but-registered boss into a red rollup.
    func testReachabilityUnchangedForRegisteredButUnverifiedBoss() {
        let builder = HarnessStatusBuilder()
        let agent = OuroAgentRecord(
            name: "boss",
            bundlePath: "/bundle",
            configPath: "/cfg",
            status: .ready,
            detail: ""
        )
        let registration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss",
            serverName: "workbench",
            commandPath: "/usr/bin/ouro",
            agentConfigPath: "/cfg",
            status: .registered,
            detail: ""
        )
        let status = builder.build(
            boss: BossAgentSelection(agentName: "boss"),
            dashboard: dashboardUp(),
            agents: [agent],
            bossRegistration: registration,
            registrationByAgentName: ["boss": registration],
            injectionByAgentName: [:] // not probed → unverified
        )
        XCTAssertTrue(
            status.boss.isReachable,
            "an unverified-but-registered boss must STILL be reachable — only the pill colour changes"
        )
        // No-false-RED guarantee, asserted explicitly across the rollup axes the
        // presentation-only fix must NOT touch.
        XCTAssertEqual(
            status.boss.state, .healthy,
            "a config-installed + registered boss stays .healthy regardless of an unverified injection"
        )
        XCTAssertEqual(
            status.overallState, .healthy,
            "the whole rollup stays .healthy for a registered-but-unverified boss with the daemon up"
        )
        XCTAssertFalse(
            status.headline.contains("not reachable"),
            "the headline must not read 'not reachable' for a registered-but-unverified boss: \(status.headline)"
        )
    }

    // MARK: - Core: the boss-reachability DETAIL row is verdict-aware (presentation only)

    /// `HarnessBossReachability` must carry the boss's live injection verdict (additive,
    /// default nil) so the Harness-Status detail row can render verdict-aware — mirroring the
    /// already-proven `HarnessAgentEntry.toolsInjection` shape.
    func testBossReachabilityCarriesToolsInjectionVerdict() {
        let boss = HarnessBossReachability(
            agentName: "boss",
            bundleIsInstalled: true,
            mcpStatus: .registered,
            toolsInjection: .confirmed(.present)
        )
        XCTAssertEqual(boss.toolsInjection, .confirmed(.present))
    }

    /// The verdict defaults to nil so every pre-existing `HarnessBossReachability(...)` keeps
    /// compiling unchanged.
    func testBossReachabilityToolsInjectionDefaultsNil() {
        let boss = HarnessBossReachability(
            agentName: "boss",
            bundleIsInstalled: true,
            mcpStatus: .registered
        )
        XCTAssertNil(boss.toolsInjection)
    }

    /// The builder must populate `HarnessBossReachability.toolsInjection` from the boss's
    /// inventory entry — ZERO new App-side threading; it rides the map already passed to the
    /// agent inventory.
    func testBossReachabilityBuilderPopulatesToolsInjectionFromBossEntry() {
        let builder = HarnessStatusBuilder()
        let agent = OuroAgentRecord(
            name: "boss",
            bundlePath: "/bundle",
            configPath: "/cfg",
            status: .ready,
            detail: ""
        )
        let registration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss",
            serverName: "workbench",
            commandPath: "/usr/bin/ouro",
            agentConfigPath: "/cfg",
            status: .registered,
            detail: ""
        )
        let status = builder.build(
            boss: BossAgentSelection(agentName: "boss"),
            dashboard: dashboardUp(),
            agents: [agent],
            bossRegistration: registration,
            registrationByAgentName: ["boss": registration],
            injectionByAgentName: ["boss": .confirmed(.present)]
        )
        XCTAssertEqual(
            status.boss.toolsInjection, .confirmed(.present),
            "the builder must thread the boss entry's injection verdict into HarnessBossReachability.toolsInjection"
        )
    }

    /// The detail-row text must be verdict-aware for a `.registered` boss: a confirmed-present
    /// injection reads the positive "available at runtime", while nil / unconfirmed / the
    /// not-yet-overlaid confirmed-absent read an HONEST neutral phrase — never the dishonest
    /// "available at runtime" green for a runtime that was never confirmed.
    func testMCPStatusTextIsVerdictAwareForRegisteredBoss() {
        let confirmed = HarnessBossReachability(
            agentName: "boss",
            bundleIsInstalled: true,
            mcpStatus: .registered,
            toolsInjection: .confirmed(.present)
        )
        XCTAssertEqual(
            confirmed.mcpStatusText, "available at runtime",
            "confirmed-present keeps the positive runtime phrasing"
        )

        for injection in [nil, .unconfirmed, WorkbenchToolsInjectionProbeOutcome.confirmed(.absent)] {
            let unverified = HarnessBossReachability(
                agentName: "boss",
                bundleIsInstalled: true,
                mcpStatus: .registered,
                toolsInjection: injection
            )
            XCTAssertNotEqual(
                unverified.mcpStatusText, "available at runtime",
                "registered + non-confirmed-present must NOT read the positive runtime phrase; "
                    + "injection=\(String(describing: injection))"
            )
            XCTAssertFalse(
                unverified.mcpStatusText.isEmpty,
                "the neutral phrase must be non-empty for injection=\(String(describing: injection))"
            )
            XCTAssertTrue(
                unverified.mcpStatusText.lowercased().contains("not yet confirmed"),
                "registered-but-unverified must read an honest 'not yet confirmed' phrase; "
                    + "got '\(unverified.mcpStatusText)' for injection=\(String(describing: injection))"
            )
        }
    }

    /// The structural (non-registered) detail-row text is unchanged — the injection verdict is
    /// irrelevant when the registration itself is the story.
    func testMCPStatusTextUnchangedForStructuralStates() {
        let cases: [(BossWorkbenchMCPRegistrationStatus, String)] = [
            (.notRegistered, "tools binary missing"),
            (.needsUpdate, "stale entry to clean"),
            (.agentMissing, "agent bundle missing"),
            (.executableMissing, "install app first"),
            (.invalidConfig, "config issue"),
            (.toolsNotInjected, "tools didn't load — update ouro"),
        ]
        for (status, expected) in cases {
            // The injection verdict must NOT change structural-state wording.
            for injection in [nil, .unconfirmed, WorkbenchToolsInjectionProbeOutcome.confirmed(.present), .confirmed(.absent)] {
                let boss = HarnessBossReachability(
                    agentName: "boss",
                    bundleIsInstalled: true,
                    mcpStatus: status,
                    toolsInjection: injection
                )
                XCTAssertEqual(
                    boss.mcpStatusText, expected,
                    "structural state \(status) keeps its wording regardless of injection=\(String(describing: injection))"
                )
            }
        }
        // The nil-mcpStatus sentinel stays "unknown".
        XCTAssertEqual(
            HarnessBossReachability(agentName: "boss", bundleIsInstalled: true, mcpStatus: nil).mcpStatusText,
            "unknown"
        )
    }

    /// The detail-row TINT must route through `BossMCPPillPresentation`: the seam-derived tone
    /// is the single source of truth for both the text and the colour. A registered-but-
    /// unverified boss is the NEUTRAL tone (never green); a confirmed-present boss is the
    /// `.verified` green; structural states keep their own tones.
    func testMCPPillToneRoutesThroughSeam() {
        // nil mcpStatus → no tone (the row has nothing registration-shaped to colour).
        XCTAssertNil(
            HarnessBossReachability(agentName: "boss", bundleIsInstalled: true, mcpStatus: nil).mcpPillTone
        )
        // registered + confirmed-present → the one green.
        XCTAssertEqual(
            HarnessBossReachability(
                agentName: "boss", bundleIsInstalled: true, mcpStatus: .registered,
                toolsInjection: .confirmed(.present)
            ).mcpPillTone,
            .verified
        )
        // registered + unverified (nil / unconfirmed / confirmed-absent) → neutral, never green.
        for injection in [nil, .unconfirmed, WorkbenchToolsInjectionProbeOutcome.confirmed(.absent)] {
            let tone = HarnessBossReachability(
                agentName: "boss", bundleIsInstalled: true, mcpStatus: .registered,
                toolsInjection: injection
            ).mcpPillTone
            XCTAssertEqual(
                tone, .unverified,
                "registered + non-confirmed-present routes to .unverified; injection=\(String(describing: injection))"
            )
            XCTAssertEqual(
                tone.map(BossMCPPillPresentation.color(for:)), .neutral,
                "the detail-row tint for an unverified boss must be the neutral class, never green"
            )
        }
        // The tone must AGREE with the same seam call the pill uses, for every status.
        for status in [BossWorkbenchMCPRegistrationStatus.registered, .notRegistered, .needsUpdate,
                       .agentMissing, .executableMissing, .invalidConfig, .toolsNotInjected] {
            for injection in [nil, .unconfirmed, WorkbenchToolsInjectionProbeOutcome.confirmed(.present), .confirmed(.absent)] {
                let boss = HarnessBossReachability(
                    agentName: "boss", bundleIsInstalled: true, mcpStatus: status, toolsInjection: injection
                )
                XCTAssertEqual(
                    boss.mcpPillTone,
                    BossMCPPillPresentation.tone(status: status, injection: injection),
                    "mcpPillTone must equal BossMCPPillPresentation.tone for status=\(status) injection=\(String(describing: injection))"
                )
            }
        }
    }

    // MARK: - App: the boss-reachability detail row routes its tint through the seam

    /// Source-pin: the boss-reachability detail row (~:1389) must colour its "Workbench MCP"
    /// value through `BossMCPPillPresentation` with the boss's live injection verdict
    /// (`status.boss.toolsInjection`), NOT the status-only `mcpStatus.harnessTint` — the last
    /// residual config-only false-green this fix removes.
    func testBossReachabilityDetailRowRoutesTintThroughSeam() throws {
        let body = try WorkbenchAppSource.sourceSlice(
            from: "title: \"Boss reachability\",",
            to: "private struct HarnessSection<Content: View>: View {"
        )
        XCTAssertTrue(
            body.contains("status.boss.toolsInjection") || body.contains("status.boss.mcpPillTone"),
            "the detail-row tint must read the boss's live injection verdict (toolsInjection / mcpPillTone)"
        )
        XCTAssertTrue(
            body.contains("BossMCPPillPresentation"),
            "the detail-row tint must route through BossMCPPillPresentation, not the status-only tint"
        )
        XCTAssertFalse(
            body.contains("status.boss.mcpStatus.harnessTint"),
            "the status-only mcpStatus.harnessTint must no longer colour the boss-reachability detail row"
        )
    }

    // MARK: - App: all three pill render sites route through the seam with the verdict

    func testAgentDetailCardPillRoutesThroughSeamWithVerdict() throws {
        let body = try WorkbenchAppSource.sourceSlice(
            from: "private struct AgentStatusCard: View {",
            to: "private struct AgentLanesCard: View {"
        )
        XCTAssertTrue(
            body.contains("BossMCPPillPresentation.tone("),
            "the agent-detail card pill must compute its tone via BossMCPPillPresentation"
        )
        XCTAssertTrue(
            body.contains("bossWorkbenchToolsInjectionByAgentName"),
            "the agent-detail card pill must thread the injection verdict, not switch on status alone"
        )
        XCTAssertFalse(
            body.contains("mcpPillColor(registration.status)"),
            "the status-only mcpPillColor(_ status:) must no longer drive the agent-detail pill"
        )
    }

    func testBossSectionRowPillRoutesThroughSeamWithVerdict() throws {
        let body = try WorkbenchAppSource.sourceSlice(
            from: "struct OuroAgentRowView: View {",
            to: "struct ProviderConfigSheet: View {"
        )
        XCTAssertTrue(
            body.contains("BossMCPPillPresentation.tone("),
            "the boss-section row pill must compute its tone via BossMCPPillPresentation"
        )
        XCTAssertTrue(
            body.contains("bossWorkbenchToolsInjectionByAgentName"),
            "the boss-section row pill must thread the injection verdict, not switch on status alone"
        )
        XCTAssertFalse(
            body.contains("registrationTint(registration.status)"),
            "the status-only registrationTint(_ status:) must no longer drive the boss-section pill"
        )
    }

    func testHarnessDiagnosticPillRoutesThroughSeamWithVerdict() throws {
        let body = try WorkbenchAppSource.sourceSlice(
            from: "private struct HarnessAgentRow: View {",
            to: "private struct HarnessActionRow: View {"
        )
        // The harness-diagnostic pill (entry.mcpStatus / entry.toolsInjection) must route
        // through the seam — no longer the status-only harnessShortLabel / harnessTint pair.
        XCTAssertTrue(
            body.contains("BossMCPPillPresentation.tone("),
            "the harness-diagnostic pill must compute its tone via BossMCPPillPresentation"
        )
        XCTAssertTrue(
            body.contains("entry.toolsInjection"),
            "the harness-diagnostic pill must read entry.toolsInjection (the threaded verdict)"
        )
        XCTAssertFalse(
            body.contains("mcpStatus.harnessShortLabel"),
            "the status-only harnessShortLabel must no longer drive the harness pill text"
        )
    }

    /// The App's `harnessStatus` builder call must pass the live injection map so the harness
    /// entries carry the verdict.
    func testHarnessStatusBuildPassesInjectionMap() throws {
        let body = try WorkbenchAppSource.sourceSlice(
            from: "var harnessStatus: HarnessStatus {",
            to: "func refreshHarnessStatus() async {"
        )
        XCTAssertTrue(
            body.contains("injectionByAgentName:"),
            "the App's harnessStatus build call must pass injectionByAgentName"
        )
        XCTAssertTrue(
            body.contains("bossWorkbenchToolsInjectionByAgentName"),
            "the App must thread the live bossWorkbenchToolsInjectionByAgentName map into the builder"
        )
    }

    // MARK: - helpers (mirror AgentReadinessOverlayWiringTests)

    /// A minimal "daemon up" dashboard so the rollup tests can assert `overallState == .healthy`
    /// without a daemon-down short-circuit masking the boss axis.
    private func dashboardUp() -> BossDashboardSnapshot {
        BossDashboardSnapshot(
            agentName: "boss",
            daemonStatus: "running",
            daemonMode: "production",
            daemonVersion: "0.1.0",
            attentionLabel: "active",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            observedAt: "2026-06-03T00:00:00Z",
            availability: BossDashboardAvailability(
                machineAvailable: true,
                needsMeAvailable: true,
                codingAvailable: true,
                issues: []
            )
        )
    }
}
