import XCTest
@testable import OuroWorkbenchCore

/// #F9 wiring: the new `.toolsNotInjected` registration status — the boss's tools binary
/// is present on disk (the registrar reads it as available) BUT a CONFIRMED `tools/list`
/// probe found zero `workbench_*` tools injected (an old `ouro` silently stripped them).
/// It must read as the loud register everywhere the on-disk snapshot drives readiness,
/// and the overlay that produces it must only fire on a CONFIRMED-absent verdict.
final class WorkbenchToolsNotInjectedStatusTests: XCTestCase {

    private func registration(_ status: BossWorkbenchMCPRegistrationStatus) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "slugger",
            serverName: "ouro_workbench",
            commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
            agentConfigPath: "/tmp/slugger.ouro/agent.json",
            status: status,
            detail: status.rawValue
        )
    }

    // MARK: - bridgeVerdict (the single contract)

    func testToolsNotInjectedIsABlockerNamingTheVersionFloor() {
        let verdict = BossBridgeContract.bridgeVerdict(registration(.toolsNotInjected))
        XCTAssertEqual(verdict.severity, .blocker)
        // Human-facing copy names the concrete version target (allowed per the doc) but no
        // raw mcp-serve / --workbench-mcp verbs.
        XCTAssertTrue(verdict.detail.lowercased().contains("alpha.660"), "should name the version floor: \(verdict.detail)")
        XCTAssertFalse(verdict.detail.contains("mcp-serve"), "no raw CLI seam in human copy")
        XCTAssertFalse(verdict.detail.contains("--workbench-mcp"), "no raw flag in human copy")
    }

    // MARK: - HarnessStatus reachability + text

    func testToolsNotInjectedDropsReachabilityAndIsBlocked() {
        let boss = HarnessBossReachability(agentName: "slugger", bundleIsReady: true, mcpStatus: .toolsNotInjected)
        XCTAssertFalse(boss.isReachable, "stripped tools means the boss can't drive Workbench")
        XCTAssertEqual(boss.state, .blocked)
        XCTAssertFalse(boss.mcpStatusText.isEmpty)
        XCTAssertNotEqual(boss.mcpStatusText, "unknown")
    }

    // MARK: - registration-truth classifier stays exhaustive

    func testRegistrationTruthClassifiesToolsNotInjectedAsNeedsManual() {
        // The registrar's install/cleanup can't fix a version-too-old strip, so it's manual.
        XCTAssertEqual(
            WorkbenchMCPRegistrationTruth.classify(status: .toolsNotInjected),
            .needsManual
        )
    }

    // MARK: - Codable round-trip (silent test-gap guard)

    func testToolsNotInjectedRoundTripsThroughCodable() throws {
        let all: [BossWorkbenchMCPRegistrationStatus] = [
            .registered, .notRegistered, .needsUpdate, .agentMissing,
            .executableMissing, .invalidConfig, .toolsNotInjected
        ]
        for status in all {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(BossWorkbenchMCPRegistrationStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
        // The new case's wire value is stable.
        XCTAssertEqual(BossWorkbenchMCPRegistrationStatus.toolsNotInjected.rawValue, "toolsNotInjected")
    }

    // MARK: - the overlay that produces .toolsNotInjected

    func testOverlayFlipsRegisteredToToolsNotInjectedOnlyOnConfirmedAbsent() {
        let onDisk = registration(.registered)

        // Confirmed absent (the silent strip) ⇒ flip to .toolsNotInjected.
        XCTAssertEqual(
            BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict(.confirmed(.absent), to: onDisk).status,
            .toolsNotInjected
        )
        // Confirmed present ⇒ untouched.
        XCTAssertEqual(
            BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict(.confirmed(.present), to: onDisk).status,
            .registered
        )
        // Unconfirmed (timeout / not-probed) ⇒ untouched — never block on an unanswered probe.
        XCTAssertEqual(
            BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict(.unconfirmed, to: onDisk).status,
            .registered
        )
        // nil cached verdict ⇒ untouched.
        XCTAssertEqual(
            BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict(nil, to: onDisk).status,
            .registered
        )
    }

    func testOverlayNeverUpgradesANonRegisteredOnDiskStatus() {
        // If the binary is missing on disk, a confirmed-absent probe doesn't change the
        // (already loud) on-disk verdict — the binary problem is the real story.
        for status in [BossWorkbenchMCPRegistrationStatus.notRegistered, .needsUpdate, .agentMissing, .executableMissing, .invalidConfig] {
            let onDisk = registration(status)
            XCTAssertEqual(
                BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict(.confirmed(.absent), to: onDisk).status,
                status,
                "a non-registered on-disk status (\(status)) must be preserved, not overwritten by the injection overlay"
            )
        }
    }
}
