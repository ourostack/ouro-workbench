#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-2 — `HarnessAgentRow` (the per-agent readiness row inside the Harness
/// Status sheet's "Local agents" section).
///
/// A pure presentational LEAF: it takes a `HarnessAgentEntry` value directly (the
/// SAME value the real `HarnessStatusBuilder.build` produces from the live agent
/// scan + MCP-registration + injection verdicts). Direct value construction IS the
/// production seam (the builder is exercised end-to-end by the C11-3 sheet test);
/// here we drive the row's own enumerated state-set through the public value type.
///
/// **Reclassified LOGIC (reconfirm-by-mutation).** Three captured-node axes flip:
///   - the readiness ICON `Image(systemName: entry.isReady ? "person.crop.circle"
///     : "person.crop.circle.badge.exclamationmark")` — a captured SF-symbol flip;
///   - the readiness PILL `StatusPill(text: InstalledAgentRowPresentation.label(
///     for: entry.liveReadiness))` — "ready" / "not verified" / "bad config" … —
///     a captured `Text` flip through the REAL pure Core producer;
///   - the `if entry.isSelectedBoss` "boss" pill + the `if let mcpStatus` "mcp …"
///     pill — captured-node presence flips.
/// All proven by the negative control. The `.help(...)` tooltip (machine-derived
/// detail) is dropped by the host (AN-004).
///
/// **Honesty note (P2).** `isReady` is GREEN only on a confirmed `.working`
/// verdict; a config-only `.ready` with no verdict reads `.unverified` ("not
/// verified") — so the fixtures inject the OUTWARD verdict, never a config-only
/// false green (the same discipline the C7 `AgentStatusCard` cluster proved).
///
/// **Determinism (P3):** fixed agent names + the `InstalledAgentRowPresentation`
/// producer strings; no clock / path / UUID renders → no cross-TZ proof needed
/// (asserted: no `/Users/`, no `/var/folders/`, byte-identical twice).
@MainActor
final class HarnessAgentRowTests: XCTestCase {

    private func entry(
        name: String,
        status: OuroAgentBundleStatus = .ready,
        detail: String = "configured",
        isSelectedBoss: Bool = false,
        mcpStatus: BossWorkbenchMCPRegistrationStatus? = nil,
        toolsInjection: WorkbenchToolsInjectionProbeOutcome? = nil,
        verdict: ProviderConnectionVerdict? = nil
    ) -> HarnessAgentEntry {
        HarnessAgentEntry(
            name: name,
            status: status,
            detail: detail,
            isSelectedBoss: isSelectedBoss,
            mcpStatus: mcpStatus,
            toolsInjection: toolsInjection,
            verdict: verdict
        )
    }

    private func view(_ e: HarnessAgentEntry) -> HarnessAgentRow { HarnessAgentRow(entry: e) }

    // MARK: - Enumerated state-set

    /// A confirmed-working boss whose MCP injection is verified: green-ready icon,
    /// "ready" pill, "boss" pill, "mcp on" pill — every captured node at its
    /// affirmative value.
    func testRow_readyVerifiedBoss_allPills() throws {
        let e = entry(name: "alpha-boss", isSelectedBoss: true,
                      mcpStatus: .registered, toolsInjection: .confirmed(.present),
                      verdict: .working)
        let tree = try ViewSnapshotHost.snapshotText(of: view(e))
        XCTAssertTrue(e.isReady, "provenance: a .working verdict is the only producer of isReady")
        XCTAssertTrue(tree.contains("person.crop.circle"), "ready icon:\n\(tree)")
        XCTAssertFalse(tree.contains("person.crop.circle.badge.exclamationmark"),
                       "ready row must NOT show the exclamation icon:\n\(tree)")
        XCTAssertTrue(tree.contains("alpha-boss"), "the agent name:\n\(tree)")
        XCTAssertTrue(tree.contains(InstalledAgentRowPresentation.label(for: .ready)),
                      "the 'ready' pill via the real producer:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="boss""#), "the boss pill:\n\(tree)")
        XCTAssertTrue(tree.contains("mcp on"), "the verified mcp pill:\n\(tree)")
        try assertViewSnapshot(of: view(e), named: "HarnessAgentRow.readyVerifiedBoss")
    }

    /// A config-only `.ready` agent with no live verdict → `.unverified` (NOT
    /// green): the exclamation icon + "not verified" pill, no boss pill, no mcp pill.
    func testRow_unverifiedNonBoss_noFalseGreen() throws {
        let e = entry(name: "beta-agent")   // .ready config, no verdict → .unverified
        let tree = try ViewSnapshotHost.snapshotText(of: view(e))
        XCTAssertFalse(e.isReady, "provenance: config-only .ready is NEVER green without a verdict")
        XCTAssertTrue(tree.contains("person.crop.circle.badge.exclamationmark"),
                      "unverified row shows the exclamation icon:\n\(tree)")
        XCTAssertTrue(tree.contains(InstalledAgentRowPresentation.label(for: .unverified)),
                      "the 'not verified' pill via the real producer:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="boss""#), "non-boss: no boss pill:\n\(tree)")
        XCTAssertFalse(tree.contains("mcp "), "no mcpStatus → no mcp pill:\n\(tree)")
        try assertViewSnapshot(of: view(e), named: "HarnessAgentRow.unverifiedNonBoss")
    }

    /// A malformed `agent.json` agent → the `.invalidConfig` "bad config" pill (the
    /// config-problem axis dominates the live verdict).
    func testRow_badConfig_pill() throws {
        let e = entry(name: "gamma-agent", status: .invalidConfig, detail: "bad json",
                      mcpStatus: .notRegistered, verdict: .working)
        let tree = try ViewSnapshotHost.snapshotText(of: view(e))
        XCTAssertTrue(tree.contains(InstalledAgentRowPresentation.label(for: .invalidConfig)),
                      "the 'bad config' pill via the real producer:\n\(tree)")
        XCTAssertTrue(tree.contains("mcp off"), "the unregistered mcp pill:\n\(tree)")
        try assertViewSnapshot(of: view(e), named: "HarnessAgentRow.badConfig")
    }

    // MARK: - Determinism (P3)

    func testRow_deterministic_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [HarnessAgentEntry] = [
            entry(name: "alpha-boss", isSelectedBoss: true,
                  mcpStatus: .registered, toolsInjection: .confirmed(.present), verdict: .working),
            entry(name: "beta-agent"),
            entry(name: "gamma-agent", status: .invalidConfig, detail: "bad json", mcpStatus: .notRegistered)
        ]
        for e in cases {
            let a = try ViewSnapshotHost.snapshotText(of: view(e))
            let b = try ViewSnapshotHost.snapshotText(of: view(e))
            XCTAssertEqual(a, b, "\(e.name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(e.name): no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "\(e.name): no temp-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The readiness, boss, and mcp axes each flip a captured node. This asserts the
    /// row is non-vacuous on all three: the ready/unverified pill differs, the
    /// boss pill appears only for the boss, and the mcp pill appears only with a
    /// registration status.
    func testRow_negativeControl_axesFlipTree() throws {
        let readyBoss = try ViewSnapshotHost.snapshotText(of: view(
            entry(name: "x", isSelectedBoss: true, mcpStatus: .registered,
                  toolsInjection: .confirmed(.present), verdict: .working)))
        let unverified = try ViewSnapshotHost.snapshotText(of: view(entry(name: "x")))

        XCTAssertNotEqual(readyBoss, unverified,
                          "the readiness/boss/mcp axes must flip the captured tree")
        XCTAssertTrue(readyBoss.contains(InstalledAgentRowPresentation.label(for: .ready)))
        XCTAssertTrue(unverified.contains(InstalledAgentRowPresentation.label(for: .unverified)))
        XCTAssertTrue(readyBoss.contains(#"text="boss""#))
        XCTAssertFalse(unverified.contains(#"text="boss""#))
        XCTAssertTrue(readyBoss.contains("mcp on"))
        XCTAssertFalse(unverified.contains("mcp "))
    }
}
#endif
