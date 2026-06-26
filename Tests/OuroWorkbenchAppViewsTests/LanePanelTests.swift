#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C7-4 — `LanePanel` (`:8452`), the agent-detail pane's per-lane (`Human-facing` /
/// `Agent-facing`) provider/model row. The agent-detail (path-leak) cluster: it renders a
/// `provider` pill + a model `Text` (with `.textSelection`), neither a path — the captured
/// surface is the provider/model identifiers, supplied as FIXED `OuroAgentLane` values.
///
/// **Data-driven branch (the captured-tree flip):**
///   - `if let lane, lane.summary != nil` → the configured row (`if let provider, !isEmpty`
///     → the provider `StatusPill`; `if let model, !isEmpty` → the model `Text`).
///   - `else` → the "Not configured" `Text`.
///
/// `lane.summary` is non-nil iff provider OR model is present, so a provider-only or
/// model-only lane still takes the configured arm (rendering only the present half).
///
/// **Provenance (P2).** `OuroAgentLane` is a `public` Core value type; constructing it with
/// deterministic provider/model strings IS the real seam (the same way the inventory parses a
/// lane out of `agent.json`). No `model`/store seam is needed — `LanePanel` is a pure leaf.
///
/// **Access-widening (C7-4, SU-E precedent):** `LanePanel` was `private struct` → widened to
/// `internal`. Zero behavior change.
@MainActor
final class LanePanelTests: XCTestCase {

    private func panel(lane: OuroAgentLane?, title: String = "Human-facing") -> LanePanel {
        LanePanel(title: title, systemImage: "person.crop.circle", lane: lane)
    }

    // MARK: - Enumerated state-set

    /// Both provider + model present → the provider pill AND the model `Text`.
    func testLane_configured() throws {
        let view = panel(lane: OuroAgentLane(provider: "anthropic", model: "claude-opus-4"))
        XCTAssertNotNil(view.lane?.summary, "provenance: a fully configured lane has a summary")
        try assertViewSnapshot(of: view, named: "LanePanel.configured")
    }

    /// Provider only → the provider pill, NO model `Text` (the `if let model, !isEmpty` arm is
    /// false), still the configured arm (summary == provider).
    func testLane_providerOnly() throws {
        let view = panel(lane: OuroAgentLane(provider: "anthropic", model: nil))
        XCTAssertEqual(view.lane?.summary, "anthropic", "provenance: provider-only summary")
        try assertViewSnapshot(of: view, named: "LanePanel.providerOnly")
    }

    /// Model only → the model `Text`, NO provider pill.
    func testLane_modelOnly() throws {
        let view = panel(lane: OuroAgentLane(provider: nil, model: "claude-opus-4"))
        XCTAssertEqual(view.lane?.summary, "claude-opus-4", "provenance: model-only summary")
        try assertViewSnapshot(of: view, named: "LanePanel.modelOnly")
    }

    /// A nil lane → the `else` "Not configured" `Text`.
    func testLane_notConfigured() throws {
        let view = panel(lane: nil)
        XCTAssertNil(view.lane, "provenance: no lane")
        try assertViewSnapshot(of: view, named: "LanePanel.notConfigured")
    }

    // MARK: - Determinism (P3)

    func testLane_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let lanes: [(String, OuroAgentLane?)] = [
            ("configured", OuroAgentLane(provider: "anthropic", model: "claude-opus-4")),
            ("providerOnly", OuroAgentLane(provider: "anthropic", model: nil)),
            ("modelOnly", OuroAgentLane(provider: nil, model: "claude-opus-4")),
            ("notConfigured", nil)
        ]
        for (label, lane) in lanes {
            let a = try ViewSnapshotHost.snapshotText(of: panel(lane: lane))
            let b = try ViewSnapshotHost.snapshotText(of: panel(lane: lane))
            XCTAssertEqual(a, b, "\(label) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(label): no /Users/ leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `lane.summary != nil` branch flips the tree (configured row vs "Not configured"),
    /// and the present-half gates (`provider`/`model`) flip which children render.
    func testLane_negativeControl_branchesFlipTree() throws {
        let configured = try ViewSnapshotHost.snapshotText(of: panel(lane: OuroAgentLane(provider: "anthropic", model: "claude-opus-4")))
        let providerOnly = try ViewSnapshotHost.snapshotText(of: panel(lane: OuroAgentLane(provider: "anthropic", model: nil)))
        let modelOnly = try ViewSnapshotHost.snapshotText(of: panel(lane: OuroAgentLane(provider: nil, model: "claude-opus-4")))
        let notConfigured = try ViewSnapshotHost.snapshotText(of: panel(lane: nil))

        XCTAssertNotEqual(configured, notConfigured, "the summary gate must drive the tree")
        XCTAssertTrue(notConfigured.contains(#"text="Not configured""#), "nil lane: the fallback:\n\(notConfigured)")
        XCTAssertFalse(configured.contains(#"text="Not configured""#), "configured: no fallback:\n\(configured)")

        XCTAssertTrue(configured.contains(#"text="anthropic""#), "configured: the provider pill:\n\(configured)")
        XCTAssertTrue(configured.contains(#"text="claude-opus-4""#), "configured: the model text:\n\(configured)")

        XCTAssertNotEqual(configured, providerOnly, "a missing model must drop the model text")
        XCTAssertFalse(providerOnly.contains(#"text="claude-opus-4""#), "providerOnly: no model text:\n\(providerOnly)")

        XCTAssertNotEqual(configured, modelOnly, "a missing provider must drop the provider pill")
        XCTAssertFalse(modelOnly.contains(#"text="anthropic""#), "modelOnly: no provider pill:\n\(modelOnly)")
    }
}
#endif
