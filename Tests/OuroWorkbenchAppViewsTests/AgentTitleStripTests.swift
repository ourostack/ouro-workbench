#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C7-2 — `AgentTitleStrip` (`:8120`), the agent-detail pane's slim title strip. The
/// agent-detail (path-leak) cluster: it surfaces no visible path (the bundle/reveal actions
/// live in the descended `Menu {}` as static labels + `.help(...)` tooltips the host drops,
/// AN-004) — the captured leak surface is the agent NAME, kept machine-value-free by the
/// fixed/relative-path `OuroAgentRecord`.
///
/// **Data-driven branch (the captured-tree flip):**
///   - `if isBoss` → the accent **"boss"** capsule `Text`. (The status dot is a `Circle().fill`
///     — geometry-only, dropped by the host whitelist; the LOGIC is the boss capsule + the
///     disclosure chevron's `showsInspector` glyph.)
///
/// ViewInspector DOES descend `Menu {}` content (the C3 finding), so the "More" menu's
/// static action labels ("Open agent.json…", "Reveal Bundle in Finder", "Run ouro check…",
/// …) are captured — deterministic constants, no machine value.
///
/// **Provenance (P2).** `model` via the `makeVM` dual-injection store seam (AN-001). `agent`
/// is a FIXED `OuroAgentRecord` (relative paths). `showsInspector` is a `.constant` binding
/// (the strip reads it for the chevron glyph; the detail pane owns the live `@State`).
///
/// **Access-widening (C7-2, SU-E precedent):** `AgentTitleStrip` was `private struct` →
/// widened to `internal` so `@testable import` can reach it. Zero behavior change.
@MainActor
final class AgentTitleStripTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c7title-\(UUID().uuidString)", isDirectory: true)
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

    private func strip(boss: String, agentName: String, showsInspector: Bool = false) throws -> AgentTitleStrip {
        let model = try makeVM(bossName: boss)
        let isBoss = model.state.boss.agentName.caseInsensitiveCompare(agentName) == .orderedSame
        return AgentTitleStrip(
            agent: record(name: agentName),
            model: model,
            isBoss: isBoss,
            showsInspector: .constant(showsInspector)
        )
    }

    // MARK: - Enumerated state-set

    /// Non-boss → the title name + the "More" menu + the "Use as Boss" action, NO boss capsule.
    func testStrip_plain() throws {
        let view = try strip(boss: "someone-else", agentName: "alpha-agent")
        XCTAssertFalse(view.isBoss, "provenance: not the boss")
        try assertViewSnapshot(of: view, named: "AgentTitleStrip.plain")
    }

    /// The boss agent → the accent "boss" capsule appears AND the primary button reads "Boss".
    func testStrip_boss() throws {
        let view = try strip(boss: "alpha-agent", agentName: "alpha-agent")
        XCTAssertTrue(view.isBoss, "provenance: the boss")
        try assertViewSnapshot(of: view, named: "AgentTitleStrip.boss")
    }

    // MARK: - Determinism (P3)

    func testStrip_determinism_byteIdenticalTwiceAndNoLeak() throws {
        for (boss, name) in [("someone-else", "alpha-agent"), ("alpha-agent", "alpha-agent")] {
            let a = try ViewSnapshotHost.snapshotText(of: try strip(boss: boss, agentName: name))
            let b = try ViewSnapshotHost.snapshotText(of: try strip(boss: boss, agentName: name))
            XCTAssertEqual(a, b, "\(name) (boss=\(boss)) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `isBoss` branch flips the tree: the boss capsule appears + the primary button label
    /// switches "Use as Boss" → "Boss".
    func testStrip_negativeControl_isBossFlipsTree() throws {
        let plain = try ViewSnapshotHost.snapshotText(of: try strip(boss: "x", agentName: "alpha-agent"))
        let boss = try ViewSnapshotHost.snapshotText(of: try strip(boss: "alpha-agent", agentName: "alpha-agent"))
        XCTAssertNotEqual(plain, boss, "the isBoss branch must drive the tree")
        XCTAssertTrue(boss.contains(#"text="boss""#), "boss: the accent capsule renders:\n\(boss)")
        XCTAssertFalse(plain.contains(#"text="boss""#), "non-boss: no capsule:\n\(plain)")
        XCTAssertTrue(plain.contains(#"text="Use as Boss""#), "non-boss: the action reads 'Use as Boss':\n\(plain)")
        XCTAssertTrue(boss.contains(#"text="Boss""#), "boss: the action reads 'Boss':\n\(boss)")
    }
}
#endif
