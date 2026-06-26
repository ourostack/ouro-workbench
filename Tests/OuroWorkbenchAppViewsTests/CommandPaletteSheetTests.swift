#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C4-2 — `CommandPaletteSheet` (`:4992`) enumerated state-set.
///
/// The palette body has two data-driven arms over `model.filteredCommandPaletteItems`:
///   - `if model.filteredCommandPaletteItems.isEmpty` (`:5018`) → the system
///     `ContentUnavailableView("No Commands", systemImage: "command", …)` (ViewInspector
///     DESCENDS it — its title/description/image are captured, per the C0/recovery finding).
///   - else → `ForEach(sectionedRows)` (`:5032`): the filtered commands grouped into labelled
///     sections via the REAL `WorkbenchCommandSection.grouped(_:)` pure classifier, each row a
///     `Text(command.title)` + `Text(command.detail)` + `Image(command.systemImage)`.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection).
/// The command list is the model's REAL `commandPaletteItems` (the same property the live palette
/// reads), filtered through the REAL `commandPalette.filter(_:query:)` seam by setting
/// `model.commandPaletteQuery` — the production filter path. NO fabricated descriptor list. The
/// empty arm is reached by a query that matches NOTHING (`"zzqqx"`); the grouped arm by the
/// default empty query (every command, grouped). The grouping is the real
/// `WorkbenchCommandSection.grouped` (asserted: ≥2 sections render for the full list).
///
/// **`.onAppear` note.** The body's `.onAppear` resets `commandPaletteQuery = ""`; ViewInspector's
/// synchronous `inspect()` does NOT fire `.onAppear` (same as `withAnimation`/`TimelineView`
/// drivers), so the query we set on the model is exactly what the snapshot renders — verified by
/// the empty-arm capturing "No Commands" (only reachable with a non-matching query).
///
/// **Determinism (P3).** No clock / path / machine value — command titles/details are static
/// copy; the only host concern is the `en_US_POSIX` pin (applied). The `toggleBossWatch` /
/// `toggleBossPane` command titles flip on `bossWatchIsEnabled` / `bossPaneCollapsed`, but those
/// default deterministically off in the hermetic VM. Byte-identical twice; no `/Users/` leak.
///
/// **Non-vacuity (P2).** The negative control flips the `isEmpty` arm: empty-query → grouped rows
/// (section titles + command titles present); non-matching-query → the `ContentUnavailableView`
/// "No Commands" replaces them. The two trees differ; named content appears/vanishes per arm.
@MainActor
final class CommandPaletteSheetTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c4-palette-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func palette(query: String) throws -> CommandPaletteSheet {
        let model = try makeVM()
        model.commandPaletteQuery = query
        return CommandPaletteSheet(model: model)
    }

    // MARK: - Enumerated state-set

    /// The grouped arm: the default empty query → every command, grouped into labelled
    /// sections by the real `WorkbenchCommandSection.grouped` classifier.
    func testPalette_groupedSections() throws {
        let view = try palette(query: "")
        XCTAssertFalse(view.model.filteredCommandPaletteItems.isEmpty,
                       "provenance: the empty query yields the full command list")
        let sections = WorkbenchCommandSection.grouped(view.model.filteredCommandPaletteItems)
        XCTAssertGreaterThanOrEqual(sections.count, 2,
                                    "provenance: the real classifier yields ≥2 labelled sections")
        try assertViewSnapshot(of: view, named: "CommandPaletteSheet.groupedSections")
    }

    /// The empty arm: a non-matching query → `ContentUnavailableView("No Commands", …)`.
    func testPalette_noMatches() throws {
        let view = try palette(query: "zzqqx-no-such-command")
        XCTAssertTrue(view.model.filteredCommandPaletteItems.isEmpty,
                      "provenance: a non-matching query empties the filtered list")
        try assertViewSnapshot(of: view, named: "CommandPaletteSheet.noMatches")
    }

    /// A specific-query arm: a narrowing token filters to a subset that still groups (defense in
    /// depth that the real filter seam — not just empty/full — drives the tree).
    func testPalette_filteredSubset() throws {
        let view = try palette(query: "boss")
        let filtered = view.model.filteredCommandPaletteItems
        XCTAssertFalse(filtered.isEmpty, "provenance: 'boss' matches ≥1 command")
        XCTAssertLessThan(filtered.count, view.model.commandPaletteItems.count,
                          "provenance: the filter NARROWS the list (real filter seam)")
        try assertViewSnapshot(of: view, named: "CommandPaletteSheet.filteredSubset")
    }

    // MARK: - Determinism (P3)

    func testPalette_determinism_byteIdenticalTwiceNoLeak() throws {
        for (name, q) in [("groupedSections", ""), ("noMatches", "zzqqx-no-such-command"), ("filteredSubset", "boss")] {
            let a = try ViewSnapshotHost.snapshotText(of: try palette(query: q))
            let b = try ViewSnapshotHost.snapshotText(of: try palette(query: q))
            XCTAssertEqual(a, b, "\(name) must be byte-identical twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The `filteredCommandPaletteItems.isEmpty` gate swaps the grouped rows for the
    /// `ContentUnavailableView`, and the command titles/section labels are real content that
    /// reaches the rendered tree (a value through the filter seam).
    func testPalette_negativeControl_emptyGateFlipsTree() throws {
        let grouped = try ViewSnapshotHost.snapshotText(of: try palette(query: ""))
        let empty = try ViewSnapshotHost.snapshotText(of: try palette(query: "zzqqx-no-such-command"))

        XCTAssertNotEqual(grouped, empty, "the isEmpty gate must drive the tree")
        // Grouped arm: a real section label + a real command title render.
        XCTAssertTrue(grouped.contains("Session"), "grouped: the Session section label renders:\n\(grouped)")
        XCTAssertTrue(grouped.contains("New Terminal"), "grouped: a real command title renders")
        XCTAssertFalse(grouped.contains("No Commands"), "grouped: not the empty state")
        // Empty arm: the ContentUnavailableView replaces them.
        XCTAssertTrue(empty.contains("No Commands"), "empty: the No-Commands title renders:\n\(empty)")
        XCTAssertFalse(empty.contains("New Terminal"), "empty: the command rows are gone")
    }
}
#endif
