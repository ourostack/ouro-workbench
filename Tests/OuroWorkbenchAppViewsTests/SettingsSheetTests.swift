#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-5 — `SettingsSheet` (the app preferences sheet).
///
/// The seven-section settings surface (Terminal / Appearance / Chrome / Startup /
/// Software Updates / Boss / Advanced). Its section CHROME is static, but one
/// data-driven captured node flips: the **font-size label** `Text("\(Int(model.
/// terminalFontSize))pt")` — a captured `Text` value that tracks the
/// `model.terminalFontSize` `@Published` (the SAME var `setTerminalFontSize` /
/// the ⌘+/⌘-/⌘0 commands write). Driving it directly IS the production seam.
///
/// **Reconfirm-by-mutation (the host whitelist applied).** The Toggle / Picker /
/// Stepper bound values are NOT captured by the host (only `textField()` is
/// special-cased; `Toggle`/`Picker` aren't) — so the toggle ON/OFF + picker
/// selection are attribute-only-from-the-harness's-view and do NOT flip the tree.
/// The genuine captured-node discriminator is the font-size label value-flip (the
/// `SidebarCountBadge`/C1 value-flip standard). So `SettingsSheet` STAYS LOGIC and
/// is COVERED through that flip; the static section labels pin the composition.
///
/// **Determinism (P3):** the font size is set to a fixed value; the section labels
/// are static literals; no clock / path / machine-name renders → no cross-TZ proof
/// (asserted: no `/Users/`, no `/var/folders/`, byte-identical twice). The font
/// `@Published`s default to persisted app-prefs, so the fixture PINS the values it
/// asserts on (never relies on the machine default).
@MainActor
final class SettingsSheetTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11settings-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// Pin EVERY rendered-or-bound preference to a fixed value so the snapshot is
    /// independent of this machine's persisted app prefs.
    private func view(fontSize: CGFloat = 13) throws -> SettingsSheet {
        let model = try makeVM()
        model.terminalFontSize = fontSize
        model.terminalThemeOverride = .system
        model.showMenuBarStatusItem = true
        model.autoLaunchResumableOnStartup = false
        model.bossAutoAdvanceEnabled = true
        model.autoUpdateEnabled = false
        return SettingsSheet(model: model)
    }

    // MARK: - Enumerated state-set (the font-size value-flip + the static composition)

    func testSettings_fontSize13_rendersComposition() throws {
        let view = try view(fontSize: 13)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Settings""#), "the sheet title:\n\(tree)")
        // The static section composition (all seven groups present).
        for section in ["Terminal", "Appearance", "Workbench Chrome", "Startup",
                        "Software Updates", "Boss", "Advanced"] {
            XCTAssertTrue(tree.contains(section), "the \(section) section header renders:\n\(tree)")
        }
        XCTAssertTrue(tree.contains(#"text="13pt""#),
                      "the font-size label tracks model.terminalFontSize:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SettingsSheet.fontSize13")
    }

    func testSettings_fontSize20_labelTracksModel() throws {
        let view = try view(fontSize: 20)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="20pt""#),
                      "the font-size label flips with model.terminalFontSize:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="13pt""#), "the 13pt label must be gone:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SettingsSheet.fontSize20")
    }

    // MARK: - Determinism (P3)

    func testSettings_deterministic_byteIdenticalTwiceAndNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try view(fontSize: 13))
        let b = try ViewSnapshotHost.snapshotText(of: try view(fontSize: 13))
        XCTAssertEqual(a, b, "the settings sheet must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-path leak:\n\(a)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The font-size label is the data-driven captured node: changing
    /// `model.terminalFontSize` must flip it. (The Toggle/Picker bound values are
    /// NOT host-captured, so the font-size label is the load-bearing discriminator.)
    func testSettings_negativeControl_fontSizeLabelFlips() throws {
        let small = try ViewSnapshotHost.snapshotText(of: try view(fontSize: 11))
        let large = try ViewSnapshotHost.snapshotText(of: try view(fontSize: 22))
        XCTAssertNotEqual(small, large, "the font-size label must flip with the model value")
        XCTAssertTrue(small.contains(#"text="11pt""#))
        XCTAssertTrue(large.contains(#"text="22pt""#))
    }
}
#endif
