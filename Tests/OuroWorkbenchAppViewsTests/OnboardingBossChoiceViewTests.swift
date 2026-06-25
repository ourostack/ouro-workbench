#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU-E3 — Surface E (onboarding) `OnboardingBossChoiceView` boss-choice states.
///
/// Provenance (Q3 default, confirmed by the SU-E0 spike
/// `./U3-onboarding-recovery/onboarding-provenance-spike.md`): inject `model.ouroAgents =
/// [OuroAgentRecord(...)]` directly with FIXED records — the same `@Published` the live
/// `refreshOuroAgents()` scanner writes — and set `model.state.boss.agentName` for the
/// selected/empty seams. `onboardingBossChoices` then derives names/status/isSelected/isUsable
/// from `ouroAgents` + `state.boss.agentName` (the real model seam). AN-001 temp
/// `agentBundlesURL` is STILL injected into BOTH the registrar AND the inventory, so a stray
/// `refreshOuroAgents()` would scan an empty temp dir — never the real home — and the boss-choice
/// surface renders NO `bundlePath`/`configPath` (so the ignored fixture paths can't leak).
///
/// The view tree (per `WorkbenchViewsAndModel.swift:6695-6817`):
///   - the page header ("Who should watch this Mac?" + the sub-line) + a "Refresh Agents" button;
///   - if `onboardingBossChoices.isEmpty` → "No local agents found" + "Create Agent" + "Clone from Git…";
///   - else a `ForEach` of `OnboardingBossChoiceRow`s, each: a radio (`largecircle.fill.circle`
///     when selected, else `circle`), `choice.name`, a "selected"/green `StatusPill` when selected,
///     the `choice.statusLabel`/`statusColor` `StatusPill` ("installed"/green, "turned off"/orange,
///     "needs setup"/orange), and `choice.detail`; `.disabled(!choice.isUsable)`.
///
/// Determinism (P3): FIXED agent names + pure Core status copy; no `bundlePath`/`configPath`
/// rendered; AN-001 confirms no home scan.
@MainActor
final class OnboardingBossChoiceViewTests: XCTestCase {

    // MARK: - Hermetic VM (AN-001-safe)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suE3-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func view(_ model: WorkbenchViewModel) -> OnboardingBossChoiceView { OnboardingBossChoiceView(model: model) }

    /// A FIXED `OuroAgentRecord` (the bundlePath/configPath are NOT rendered by this surface;
    /// kept as canonical ignored values, never machine paths).
    private func record(_ name: String, _ status: OuroAgentBundleStatus) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "/agent-bundles/\(name).ouro",
            configPath: "/agent-bundles/\(name).ouro/agent.json",
            status: status,
            detail: status == .ready ? "ready" : "disabled in agent.json"
        )
    }

    /// Build a VM with the injected fixed records + boss name (no live scan — Q3 / AN-001).
    private func vm(agents: [OuroAgentRecord], boss: String) throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.ouroAgents = agents
        model.state.boss.agentName = boss
        return model
    }

    // MARK: - SU-E3.a — boss-choice state-set

    func testE3_none() throws {
        // A TRUE empty set needs BOTH empty ouroAgents AND empty boss name (a non-empty boss
        // always yields ≥1 choice — verified in the SU-E0 spike).
        let model = try vm(agents: [], boss: "")
        XCTAssertTrue(model.onboardingBossChoices.isEmpty, "provenance: empty choice set")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains("No local agents found"), "empty → No local agents found:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Create Agent""#), "empty → Create Agent:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Clone from Git…""#), "empty → Clone from Git…:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E3.none")
    }

    func testE3_one() throws {
        // One fixed record, NOT the boss → one row, not selected, usable.
        let model = try vm(agents: [record("alpha", .ready)], boss: "")
        XCTAssertEqual(model.onboardingBossChoices.map(\.name), ["alpha"], "provenance: one choice")
        XCTAssertFalse(model.onboardingBossChoices[0].isSelected, "provenance: not selected")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(#"text="alpha""#), "one row named alpha:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="installed""#), "ready → installed pill:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="selected""#), "not the boss → no selected pill:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E3.one")
    }

    func testE3_many() throws {
        // Two distinct ready records, neither the boss → two rows, distinct names (Q6).
        let model = try vm(agents: [record("alpha", .ready), record("bravo", .ready)], boss: "")
        XCTAssertEqual(model.onboardingBossChoices.map(\.name), ["alpha", "bravo"], "provenance: two choices (sorted)")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(#"text="alpha""#) && tree.contains(#"text="bravo""#), "both rows:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E3.many")
    }

    func testE3_selected() throws {
        // The boss name matches one ready record → that row shows the "selected"/green pill +
        // the filled radio (largecircle.fill.circle). A second non-selected record contrasts.
        let model = try vm(agents: [record("alpha", .ready), record("bravo", .ready)], boss: "alpha")
        let selected = try XCTUnwrap(model.onboardingBossChoices.first { $0.name == "alpha" })
        XCTAssertTrue(selected.isSelected, "provenance: alpha is selected")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(#"text="selected""#), "selected → selected pill:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="largecircle.fill.circle""#), "selected → filled radio:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="circle""#), "the non-selected row keeps the empty radio:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E3.selected")
    }

    func testE3_unusable() throws {
        // A .disabled record → isUsable == false (the row is disabled); the status pill reads
        // "turned off". Single row so the unusable state is the only one rendered.
        let model = try vm(agents: [record("charlie", .disabled)], boss: "")
        let choice = try XCTUnwrap(model.onboardingBossChoices.first { $0.name == "charlie" })
        XCTAssertFalse(choice.isUsable, "provenance: disabled → not usable")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(#"text="charlie""#), "row named charlie:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="turned off""#), "disabled → turned off pill:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E3.unusable")
    }

    // MARK: - SU-E3.b — MUTATION-verified negative control (P2)

    /// NEGATIVE CONTROL — flipping a record's `status` `.ready`↔`.disabled` flips `isUsable` +
    /// the `statusLabel` pill ("installed"↔"turned off"); changing `state.boss.agentName` moves
    /// the "selected" pill. Proves the `OnboardingBossChoice.isUsable`/`statusLabel`/`isSelected`
    /// seams are load-bearing in the rendered surface.
    func testE3_negativeControl_statusAndSelectionFlip() throws {
        let ready = try vm(agents: [record("alpha", .ready)], boss: "alpha")
        let disabled = try vm(agents: [record("alpha", .disabled)], boss: "")
        let readyTree = try ViewSnapshotHost.snapshotText(of: view(ready))
        let disabledTree = try ViewSnapshotHost.snapshotText(of: view(disabled))
        XCTAssertNotEqual(readyTree, disabledTree, "status+selection flip the tree")
        XCTAssertTrue(readyTree.contains(#"text="installed""#) && readyTree.contains(#"text="selected""#),
                      "ready boss → installed + selected:\n\(readyTree)")
        XCTAssertTrue(disabledTree.contains(#"text="turned off""#) && !disabledTree.contains(#"text="selected""#),
                      "disabled non-boss → turned off, no selected:\n\(disabledTree)")
    }

    // MARK: - Determinism (P3)

    func testE3_determinism_eachStateByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> WorkbenchViewModel)] = [
            ("none", { try self.vm(agents: [], boss: "") }),
            ("one", { try self.vm(agents: [self.record("alpha", .ready)], boss: "") }),
            ("many", { try self.vm(agents: [self.record("alpha", .ready), self.record("bravo", .ready)], boss: "") }),
            ("selected", { try self.vm(agents: [self.record("alpha", .ready), self.record("bravo", .ready)], boss: "alpha") }),
            ("unusable", { try self.vm(agents: [self.record("charlie", .disabled)], boss: "") })
        ]
        for (name, makeModel) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: view(try makeModel()))
            let b = try ViewSnapshotHost.snapshotText(of: view(try makeModel()))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path / home-scan leak:\n\(a)")
        }
    }
}
#endif
