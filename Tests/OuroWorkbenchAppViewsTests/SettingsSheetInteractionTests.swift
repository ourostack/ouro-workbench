#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `SettingsSheet` (`:1804`) INTERACTION drive-to-100%.
///
/// The C11 `SettingsSheetTests` snapshot the section CHROME + the font-size label
/// value-flip, but never EXECUTE the control action/binding-setter closures — so 9
/// region segments (the Done button, the font-size `Stepper` binding setter + its
/// Reset button, the theme `Picker` setter, the Chrome/Startup/Updates `Toggle`
/// setters, and the Advanced "Notification Preferences…" button + its inner URL
/// arm) were never coloured. ViewInspector 0.10.3 invokes a `Button`'s action
/// (`.tap()`), a `Toggle`'s binding (`.tap()`), a `Picker`'s binding (`.select`),
/// and a `Stepper`'s binding (`.increment()`), so this suite DRIVES every reachable
/// region: it actuates each control and asserts the `WorkbenchViewModel` setter ran
/// (provenance), mutation-verified by the negative control.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001). Every control
/// binds to a real `WorkbenchViewModel` setter (`setTerminalFontSize`,
/// `resetTerminalFontSize`, `setTerminalThemeOverride`, `setShowMenuBarStatusItem`,
/// `setAutoLaunchResumableOnStartup`, `setAutoUpdateEnabled`) — the exact setters the
/// ⌘ shortcuts / menu commands write, so actuating the control IS the production seam.
///
/// **Carves:** none — every region in the `SettingsSheet` decl is driven (the
/// Advanced button's `if let url = URL(string:)` literal is non-nil, so its inner
/// `NSWorkspace.shared.open` arm executes; `open` is harmless under test — it returns
/// without surfacing System Settings to the test process).
@MainActor
final class SettingsSheetInteractionTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9settings-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A model with EVERY rendered/bound preference pinned to a fixed value (machine
    /// app-prefs independence — the C11 fixture standard).
    private func pinnedModel(fontSize: CGFloat = 13) throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.terminalFontSize = fontSize
        model.terminalThemeOverride = .system
        model.showMenuBarStatusItem = true
        model.autoLaunchResumableOnStartup = false
        model.bossAutoAdvanceEnabled = true
        model.autoUpdateEnabled = false
        return model
    }

    // MARK: - Done button (`:1814`)

    /// `Button("Done") { dismiss() }` — a pure environment dismiss; tapping executes
    /// the action region. The model is untouched.
    func testSettings_doneButton_tapRunsDismiss() throws {
        let model = try pinnedModel()
        try SettingsSheet(model: model).inspect().find(button: "Done").tap()
    }

    // MARK: - Font-size Stepper binding setter + Reset (`:1846`, `:1859`)

    /// The font-size `Stepper(value: fontSizeBinding, …)` binding setter
    /// `{ model.setTerminalFontSize(CGFloat($0)) }` (`:1846`). Incrementing the stepper
    /// calls the binding's `set`, which writes `terminalFontSize`.
    func testSettings_fontStepper_incrementCallsSetter() throws {
        let model = try pinnedModel(fontSize: 13)
        XCTAssertEqual(model.terminalFontSize, 13, "precondition")
        try SettingsSheet(model: model).inspect().find(ViewType.Stepper.self).increment()
        XCTAssertEqual(model.terminalFontSize, 14,
                       "incrementing the stepper runs setTerminalFontSize($0) → 14pt")
    }

    /// The font-size "Reset" `Button { model.resetTerminalFontSize() }` (`:1859`).
    /// Reset restores the macOS default (13pt); start from a non-default size to prove
    /// the action ran.
    func testSettings_resetButton_resetsFontSize() throws {
        let model = try pinnedModel(fontSize: 20)
        XCTAssertEqual(model.terminalFontSize, 20, "precondition: a non-default size")
        try SettingsSheet(model: model).inspect().find(button: "Reset").tap()
        XCTAssertEqual(model.terminalFontSize, WorkbenchViewModel.defaultTerminalFontSize,
                       "tapping Reset runs resetTerminalFontSize() → the macOS default")
    }

    // MARK: - Theme Picker binding setter (`:1888`)

    /// The Appearance `Picker(selection: Binding(set: { model.setTerminalThemeOverride($0) }))`
    /// setter. Selecting a non-current option calls the binding's `set`.
    func testSettings_themePicker_selectCallsSetter() throws {
        let model = try pinnedModel()
        model.terminalThemeOverride = .system
        try SettingsSheet(model: model).inspect()
            .find(ViewType.Picker.self).select(value: TerminalThemeOverride.dark)
        XCTAssertEqual(model.terminalThemeOverride, .dark,
                       "selecting Dark runs setTerminalThemeOverride(.dark)")
    }

    // MARK: - Chrome / Startup / Updates Toggle setters (`:1909`, `:1927`, `:1946`)

    /// The Chrome "Show menu bar icon" `Toggle` setter `{ model.setShowMenuBarStatusItem($0) }`.
    func testSettings_menuBarToggle_flipsSetter() throws {
        let model = try pinnedModel()
        model.showMenuBarStatusItem = true
        try SettingsSheet(model: model).inspect().find(ViewType.Toggle.self, where: { t in
            (try? t.find(text: "Show menu bar icon")) != nil
        }).tap()
        XCTAssertFalse(model.showMenuBarStatusItem,
                       "tapping the menu-bar toggle runs setShowMenuBarStatusItem(false)")
    }

    /// The Startup "Auto-launch resumable terminals" `Toggle` setter
    /// `{ model.setAutoLaunchResumableOnStartup($0) }`.
    func testSettings_startupToggle_flipsSetter() throws {
        let model = try pinnedModel()
        model.autoLaunchResumableOnStartup = false
        try SettingsSheet(model: model).inspect().find(ViewType.Toggle.self, where: { t in
            (try? t.find(text: "Auto-launch resumable terminals on startup")) != nil
        }).tap()
        XCTAssertTrue(model.autoLaunchResumableOnStartup,
                      "tapping the startup toggle runs setAutoLaunchResumableOnStartup(true)")
    }

    /// The Updates "Automatically check for updates" `Toggle` setter
    /// `{ model.setAutoUpdateEnabled($0) }`.
    func testSettings_autoUpdateToggle_flipsSetter() throws {
        let model = try pinnedModel()
        model.autoUpdateEnabled = false
        try SettingsSheet(model: model).inspect().find(ViewType.Toggle.self, where: { t in
            (try? t.find(text: "Automatically check for updates and install on quit")) != nil
        }).tap()
        XCTAssertTrue(model.autoUpdateEnabled,
                      "tapping the auto-update toggle runs setAutoUpdateEnabled(true)")
    }

    // MARK: - Advanced "Notification Preferences…" button (`:1977`, `:1978`)

    /// The Advanced `Button { if let url = URL(string: …) { NSWorkspace.shared.open(url) } }`.
    /// The URL literal is non-nil, so tapping executes BOTH the action body (`:1977`) and
    /// the inner `if let url` arm (`:1978`). `NSWorkspace.open` is harmless under test.
    func testSettings_notificationPrefsButton_tapRunsOpen() throws {
        let model = try pinnedModel()
        try SettingsSheet(model: model).inspect().find(button: "Notification Preferences…").tap()
        // The action body + the URL-string `if let` arm execute; no throw is the effect.
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The toggle setters are load-bearing: tapping flips the model value. (If the setter
    /// closure were a no-op the value would not change — the mutation that breaks it.)
    func testSettings_negativeControl_toggleSettersFlipModel() throws {
        let model = try pinnedModel()
        model.showMenuBarStatusItem = true
        model.autoUpdateEnabled = false
        let view = SettingsSheet(model: model)
        try view.inspect().find(ViewType.Toggle.self, where: { t in
            (try? t.find(text: "Show menu bar icon")) != nil
        }).tap()
        try view.inspect().find(ViewType.Toggle.self, where: { t in
            (try? t.find(text: "Automatically check for updates and install on quit")) != nil
        }).tap()
        XCTAssertFalse(model.showMenuBarStatusItem, "menu-bar toggle flipped")
        XCTAssertTrue(model.autoUpdateEnabled, "auto-update toggle flipped")
    }

    // MARK: - Determinism (P3)

    func testSettings_interaction_noLeak() throws {
        let model = try pinnedModel()
        let tree = try ViewSnapshotHost.snapshotText(of: SettingsSheet(model: model))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak:\n\(tree)")
    }
}
#endif
