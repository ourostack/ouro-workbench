#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C8 — `OnboardingAgentProviderSummary` (the AN-001 cluster's onboarding lane-summary).
///
/// A leaf taking `var agent: OuroAgentRecord?` directly. Branches:
///   - `if let agent` — nil → an EMPTY tree (no rows at all).
///   - `agent.lanesShareOneConnection` — when both lanes resolve to the SAME fully-configured
///       provider+model → ONE calm line ("Your agent uses" + a single `ProviderModelPill`);
///       else → TWO `laneRow`s ("Talks with you using" / "Thinks with"), each its own pill.
///   - inside `ProviderModelPill`: `if let label` — the lane's real `displayLabel`
///       (`provider · model`, middle-dot) vs the muted "not connected yet" when a lane has no
///       fully-configured provider/model.
///
/// **Provenance (P2).** `OuroAgentRecord`/`OuroAgentLane` are `public` Core value types;
/// `lanesShareOneConnection` + `OuroAgentLane.displayLabel` are the REAL pure Core producers
/// that decide the branch — the test builds a fixed record and lets those producers drive the
/// tree (no fabrication: the rendered pill labels ARE the producers' output).
///
/// **AN-001 (the cluster's named hazard).** This leaf takes the record DIRECTLY (no VM /
/// inventory scan), so there is no `~/AgentBundles` read in THIS surface. The fixture uses a
/// FIXED record (relative paths, deterministic provider/model) → no machine value reaches the
/// tree. (In production the record originates from `model.ouroAgent(named:)`, which the
/// cluster's other surfaces pin via the temp-`agentBundlesURL` dual-injection.)
///
/// **Access-widening:** `OnboardingAgentProviderSummary` `private`→`internal` (zero-behavior,
/// the SU-E precedent — surfaced to the operator).
///
/// **Enumerated state-set:**
///   - `nilAgent`     — `agent == nil` → empty tree (no rows).
///   - `sharedOne`    — both lanes = the same fully-configured provider+model → one calm line.
///   - `diverging`    — lanes differ → two lane rows, each with its own provider · model pill.
///   - `notConnected` — diverging, with the inner lane unconfigured → the "not connected yet" pill.
@MainActor
final class OnboardingAgentProviderSummaryTests: XCTestCase {

    /// A FIXED record (relative paths; AN-001 hygiene). The lanes drive the rendered branch.
    private func record(
        human: OuroAgentLane?,
        agent agentLane: OuroAgentLane?
    ) -> OuroAgentRecord {
        OuroAgentRecord(
            name: "alpha-agent",
            bundlePath: "AgentBundles/alpha-agent.ouro",
            configPath: "AgentBundles/alpha-agent.ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: human,
            agentFacing: agentLane
        )
    }

    private func view(_ agent: OuroAgentRecord?) -> OnboardingAgentProviderSummary {
        OnboardingAgentProviderSummary(agent: agent)
    }

    // MARK: - Enumerated state-set

    func testSummary_nilAgent_emptyTree() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: view(nil))
        XCTAssertFalse(tree.contains("Your agent uses"), "nil: no shared line:\n\(tree)")
        XCTAssertFalse(tree.contains("Talks with you using"), "nil: no lane rows:\n\(tree)")
        try assertViewSnapshot(of: view(nil), named: "OnboardingAgentProviderSummary.nilAgent")
    }

    func testSummary_sharedOneConnection() throws {
        let lane = OuroAgentLane(provider: "anthropic", model: "opus")
        let rec = record(human: lane, agent: lane)
        // Provenance: the real producer confirms the lanes collapse to one connection.
        XCTAssertTrue(rec.lanesShareOneConnection,
                      "provenance: identical fully-configured lanes share one connection")
        let tree = try ViewSnapshotHost.snapshotText(of: view(rec))
        XCTAssertTrue(tree.contains(#"text="Your agent uses""#),
                      "shared: the calm one-line label:\n\(tree)")
        XCTAssertTrue(tree.contains(try XCTUnwrap(lane.displayLabel)),
                      "shared: the real provider · model pill label:\n\(tree)")
        XCTAssertFalse(tree.contains("Talks with you using"),
                       "shared: NO separate lane rows:\n\(tree)")
        try assertViewSnapshot(of: view(rec), named: "OnboardingAgentProviderSummary.sharedOne")
    }

    func testSummary_divergingLanes() throws {
        let human = OuroAgentLane(provider: "anthropic", model: "opus")
        let inner = OuroAgentLane(provider: "openai", model: "gpt5")
        let rec = record(human: human, agent: inner)
        XCTAssertFalse(rec.lanesShareOneConnection,
                       "provenance: divergent lanes do NOT share one connection")
        let tree = try ViewSnapshotHost.snapshotText(of: view(rec))
        XCTAssertTrue(tree.contains(#"text="Talks with you using""#),
                      "diverging: the outward lane row:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Thinks with""#),
                      "diverging: the inner lane row:\n\(tree)")
        XCTAssertTrue(tree.contains(try XCTUnwrap(human.displayLabel)),
                      "diverging: the outward provider · model:\n\(tree)")
        XCTAssertTrue(tree.contains(try XCTUnwrap(inner.displayLabel)),
                      "diverging: the inner provider · model:\n\(tree)")
        try assertViewSnapshot(of: view(rec), named: "OnboardingAgentProviderSummary.diverging")
    }

    func testSummary_notConnectedLane() throws {
        let human = OuroAgentLane(provider: "anthropic", model: "opus")
        // Inner lane unconfigured (no model) → displayLabel == nil → "not connected yet" pill.
        let inner = OuroAgentLane(provider: "openai", model: nil)
        let rec = record(human: human, agent: inner)
        XCTAssertFalse(rec.lanesShareOneConnection,
                       "provenance: an unconfigured lane cannot share one connection")
        XCTAssertNil(inner.displayLabel,
                     "provenance: an unconfigured lane has no displayLabel → the muted pill")
        let tree = try ViewSnapshotHost.snapshotText(of: view(rec))
        XCTAssertTrue(tree.contains(#"text="not connected yet""#),
                      "notConnected: the muted ProviderModelPill else-arm:\n\(tree)")
        XCTAssertTrue(tree.contains(try XCTUnwrap(human.displayLabel)),
                      "notConnected: the configured outward lane still renders its label:\n\(tree)")
        try assertViewSnapshot(of: view(rec), named: "OnboardingAgentProviderSummary.notConnected")
    }

    // MARK: - Determinism (P3)

    func testSummary_byteIdenticalTwiceAndNoLeak() throws {
        let lane = OuroAgentLane(provider: "anthropic", model: "opus")
        let cases: [(String, OuroAgentRecord?)] = [
            ("nil", nil),
            ("shared", record(human: lane, agent: lane)),
            ("diverging", record(human: lane, agent: OuroAgentLane(provider: "openai", model: "gpt5")))
        ]
        for (name, rec) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: view(rec))
            let b = try ViewSnapshotHost.snapshotText(of: view(rec))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `lanesShareOneConnection` gate AND the `ProviderModelPill` `if let label` gate both
    /// drive the captured tree (one calm line vs two lane rows; real label vs "not connected yet").
    func testSummary_negativeControl_lanesAndLabelGatesFlipTree() throws {
        let lane = OuroAgentLane(provider: "anthropic", model: "opus")
        let shared = try ViewSnapshotHost.snapshotText(of: view(record(human: lane, agent: lane)))
        let diverging = try ViewSnapshotHost.snapshotText(
            of: view(record(human: lane, agent: OuroAgentLane(provider: "openai", model: "gpt5"))))
        let notConnected = try ViewSnapshotHost.snapshotText(
            of: view(record(human: lane, agent: OuroAgentLane(provider: "openai", model: nil))))

        XCTAssertNotEqual(shared, diverging,
                          "the lanesShareOneConnection gate must drive one-line vs two-row")
        XCTAssertTrue(shared.contains(#"text="Your agent uses""#), "shared: calm line:\n\(shared)")
        XCTAssertFalse(diverging.contains(#"text="Your agent uses""#),
                       "diverging: NO calm line:\n\(diverging)")

        XCTAssertNotEqual(diverging, notConnected,
                          "the ProviderModelPill label gate must drive real-label vs muted")
        XCTAssertTrue(diverging.contains(#"text="openai · gpt5""#),
                      "diverging: the inner lane's real label:\n\(diverging)")
        XCTAssertTrue(notConnected.contains(#"text="not connected yet""#),
                      "notConnected: the muted else-arm:\n\(notConnected)")
    }
}
#endif
