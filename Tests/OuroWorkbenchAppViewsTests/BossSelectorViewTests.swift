#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-2 — `BossSelectorView` (`:4292`) enumerated state-set.
///
/// The view is a `Menu { … } label: { … }`. ViewInspector does NOT descend `Menu {}`
/// content (the same non-descent that applies to `.contextMenu{}`/`.popover{}`), so the
/// `if !bossAgentChoices.isEmpty` menu-row branch is asserted via model STATE (the
/// `bossAgentChoices` provenance), and the SNAPSHOT captures the always-rendered LABEL,
/// whose nodes are driven by `presentation = HeaderCalmPresentation.resolve(...)`:
///   - `bossLabelText` Text ("No boss yet" / "Boss: <name>")
///   - the `if presentation.bossShowsMissingPill` "missing" Text (named-but-not-installed)
///   - the trailing `chevron.down` Image.
/// (The leading health `Circle().accessibilityHidden(true)` contributes no captured node.)
///
/// **Provenance (P2).** `model` via the `makeVM` store seam (AN-001 hermetic). The boss
/// name is the persisted `state.boss.agentName`; whether it resolves to an installed
/// bundle is driven by injecting `model.ouroAgents` (the SU-E3 `@Published` seam). The
/// label/pill text comes from the pure `HeaderCalmPresentation.resolve` Core seam, fed
/// `model.ouroAgent(named:)?.status`.
///
/// **Enumerated state-set (the calm-vs-loud decision the Core seam makes):**
///   - `noBoss`    — empty boss name → calm "No boss yet", NO missing pill.
///   - `missing`   — named boss, NOT installed → loud "Boss: <name>" + "missing" pill.
///   - `installed` — named boss, installed `.ready` record → "Boss: <name>", NO missing pill.
@MainActor
final class BossSelectorViewTests: XCTestCase {

    private func makeVM(bossName: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-bsv-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: bossName)))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func record(name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready"
        )
    }

    /// Build the selector for a boss name, optionally injecting an installed record
    /// resolving that name. `installed == false` leaves `ouroAgents` empty → the name
    /// resolves to nothing → the loud "missing" branch.
    private func selector(bossName: String, installed: Bool) throws -> BossSelectorView {
        let model = try makeVM(bossName: bossName)
        if installed {
            model.ouroAgents = [record(name: bossName)]
        }
        return BossSelectorView(model: model)
    }

    // MARK: - Enumerated state-set

    func testSelector_noBoss() throws {
        // Empty boss name → the calm no-boss-yet header (the subtractive-FRE state).
        let view = try selector(bossName: "", installed: false)
        XCTAssertTrue(view.model.state.boss.agentName.isEmpty, "provenance: no boss chosen")
        try assertViewSnapshot(of: view, named: "BossSelectorView.noBoss")
    }

    func testSelector_missing() throws {
        // Named boss with no installed bundle → loud "Boss: <name>" + "missing" pill.
        let view = try selector(bossName: "ghost-boss", installed: false)
        XCTAssertNil(view.model.ouroAgent(named: "ghost-boss"),
                     "provenance: the boss name resolves to no bundle")
        try assertViewSnapshot(of: view, named: "BossSelectorView.missing")
    }

    func testSelector_installed() throws {
        // Named boss with an installed `.ready` bundle → "Boss: <name>", no missing pill,
        // and `bossAgentChoices` is non-empty (the menu-row branch — asserted via state).
        let view = try selector(bossName: "alpha-boss", installed: true)
        XCTAssertEqual(view.model.ouroAgent(named: "alpha-boss")?.status, .ready,
                       "provenance: the boss resolves to an installed bundle")
        XCTAssertFalse(view.model.bossAgentChoices.isEmpty,
                       "provenance: the choices menu has rows")
        try assertViewSnapshot(of: view, named: "BossSelectorView.installed")
    }

    // MARK: - Determinism (P3)

    func testSelector_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, String, Bool)] = [
            ("noBoss", "", false), ("missing", "ghost-boss", false), ("installed", "alpha-boss", true)
        ]
        for (name, boss, installed) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try selector(bossName: boss, installed: installed))
            let b = try ViewSnapshotHost.snapshotText(of: try selector(bossName: boss, installed: installed))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The calm-vs-loud Core decision flips the captured label tree: (a) an empty name
    /// renders the calm "No boss yet" vs a named boss's "Boss: <name>"; (b) a
    /// named-but-not-installed boss adds the "missing" pill an installed one omits.
    func testSelector_negativeControl_calmVsLoudFlipsTree() throws {
        let noBoss = try ViewSnapshotHost.snapshotText(of: try selector(bossName: "", installed: false))
        let missing = try ViewSnapshotHost.snapshotText(of: try selector(bossName: "ghost-boss", installed: false))
        let installed = try ViewSnapshotHost.snapshotText(of: try selector(bossName: "ghost-boss", installed: true))

        // (a) the empty-name calm branch vs a named boss.
        XCTAssertNotEqual(noBoss, missing, "the empty-name gate must drive the label")
        XCTAssertTrue(noBoss.contains("No boss yet"), "no-boss: the calm label:\n\(noBoss)")
        XCTAssertFalse(noBoss.contains("missing"), "no-boss: no missing pill:\n\(noBoss)")
        XCTAssertTrue(missing.contains("Boss: ghost-boss"), "missing: the named label:\n\(missing)")

        // (b) the missing pill is present iff the boss is named-but-not-installed.
        XCTAssertNotEqual(missing, installed, "installing the boss must drop the missing pill")
        XCTAssertTrue(missing.contains("missing"), "named-uninstalled: the missing pill:\n\(missing)")
        XCTAssertFalse(installed.contains("missing"), "installed: no missing pill:\n\(installed)")
    }
}
#endif
