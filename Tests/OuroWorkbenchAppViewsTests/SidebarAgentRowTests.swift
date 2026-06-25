#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C1 — `SidebarAgentRow` (`:3448`), the boss-section row for an installed Ouro agent. The
/// row's data-driven captured tree:
///   - `Text(agent.name)` — always.
///   - `if isBoss` → a `Text("boss")` accent pill.
///   - `if let lane = agent.humanFacing?.summary` → a `Text(lane)` mono summary
///     ("provider/model").
/// The status dot is a `Circle().fill(statusColor)` (geometry/color — DROPPED by the host
/// whitelist) and the `.help(...)` tooltip is dropped (AN-004); the `verdict`/`isChecking`
/// inputs only steer the dot color + tooltip, so they do NOT change the captured tree (the
/// row's logic-bearing branches are exactly `isBoss` + `if let lane`).
///
/// **Provenance (P2).** `OuroAgentRecord`/`OuroAgentLane` are `public` Core value types;
/// constructing them with deterministic inputs IS the real seam (`model.ouroAgents` is the
/// `@Published` the inventory scan populates — the SU-E3 / C0 AN-001 precedent). The row is a
/// pure value view (it takes the record + flags directly), so it is instantiated via its own
/// `View` initializer — no model graph, no scan, hence no AN-001 leak surface here. The
/// record's paths are fixed/relative regardless (AN-001 hygiene).
///
/// **Determinism (P3).** Fixed agent names + a fixed provider/model lane; no clock/path/UUID;
/// byte-identical twice; `!contains("/Users/")`.
///
/// **Enumerated state-set:**
///   - `plain`        — a non-boss agent, no lane configured → just the name.
///   - `withLane`     — a non-boss agent with a configured `humanFacing` lane → name + the
///                      "anthropic/claude-opus" summary.
///   - `boss`         — the boss agent (with a lane) → name + the "boss" pill + the summary.
@MainActor
final class SidebarAgentRowTests: XCTestCase {

    /// A FIXED record (relative paths — AN-001 hygiene). `humanFacing` drives the lane summary.
    private func record(name: String, lane: OuroAgentLane? = nil) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: lane
        )
    }

    private func row(name: String, isBoss: Bool = false, lane: OuroAgentLane? = nil) -> SidebarAgentRow {
        SidebarAgentRow(
            agent: record(name: name, lane: lane),
            isBoss: isBoss,
            isSelected: false,
            verdict: nil,
            isChecking: false,
            select: {}
        )
    }

    private static let lane = OuroAgentLane(provider: "anthropic", model: "claude-opus")

    // MARK: - Enumerated state-set

    func testRow_plain() throws {
        let view = row(name: "alpha-agent")
        XCTAssertNil(view.agent.humanFacing?.summary, "provenance: no lane configured")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="alpha-agent""#), "the agent name renders:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="boss""#), "non-boss: no boss pill:\n\(tree)")
        XCTAssertFalse(tree.contains("anthropic"), "no lane: no summary:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarAgentRow.plain")
    }

    func testRow_withLane() throws {
        let view = row(name: "beta-agent", lane: Self.lane)
        XCTAssertEqual(view.agent.humanFacing?.summary, "anthropic/claude-opus", "provenance: lane summary")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="anthropic/claude-opus""#), "the lane summary renders:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="boss""#), "non-boss: no boss pill:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarAgentRow.withLane")
    }

    func testRow_boss() throws {
        let view = row(name: "boss-agent", isBoss: true, lane: Self.lane)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="boss-agent""#), "the agent name renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="boss""#), "boss: the boss pill renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="anthropic/claude-opus""#), "boss: the lane summary renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarAgentRow.boss")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `isBoss` gate adds the "boss" pill; the `if let lane` gate adds the summary `Text`.
    func testRow_negativeControl_bossAndLaneGatesFlipTree() throws {
        let plain = try ViewSnapshotHost.snapshotText(of: row(name: "x"))
        let withLane = try ViewSnapshotHost.snapshotText(of: row(name: "x", lane: Self.lane))
        let boss = try ViewSnapshotHost.snapshotText(of: row(name: "x", isBoss: true))

        XCTAssertNotEqual(plain, withLane, "configuring a lane must add the summary Text")
        XCTAssertFalse(plain.contains("anthropic"), "no lane: no summary:\n\(plain)")
        XCTAssertTrue(withLane.contains(#"text="anthropic/claude-opus""#), "lane: summary present:\n\(withLane)")

        XCTAssertNotEqual(plain, boss, "the isBoss flag must add the boss pill")
        XCTAssertFalse(plain.contains(#"text="boss""#), "non-boss: no pill:\n\(plain)")
        XCTAssertTrue(boss.contains(#"text="boss""#), "boss: pill present:\n\(boss)")
    }

    // MARK: - Determinism (P3)

    func testRow_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("plain", { try ViewSnapshotHost.snapshotText(of: self.row(name: "alpha-agent")) }),
            ("withLane", { try ViewSnapshotHost.snapshotText(of: self.row(name: "beta-agent", lane: Self.lane)) }),
            ("boss", { try ViewSnapshotHost.snapshotText(of: self.row(name: "boss-agent", isBoss: true, lane: Self.lane)) })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
