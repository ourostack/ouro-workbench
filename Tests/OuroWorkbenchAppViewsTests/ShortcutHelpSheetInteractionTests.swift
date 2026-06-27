#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `ShortcutHelpSheet` (`:1701`) INTERACTION drive-to-100%.
///
/// The C-era `ShortcutHelpSheetTests` snapshot the RENDER arms (the shortcut groups
/// + rows) but never EXECUTE the lone action-closure — so 1 region segment (the
/// "Done" button's `{ dismiss() }`) was never coloured. ViewInspector 0.10.3 invokes
/// button actions (`.tap()`), so this suite DRIVES it.
///
/// **Carves:** none — the only un-driven region was the Done action, driven here.
@MainActor
final class ShortcutHelpSheetInteractionTests: XCTestCase {

    /// `Button("Done") { dismiss() }` — a pure environment dismiss; tapping executes the
    /// action region. `ShortcutHelpSheet` has no model, so the observable effect is "no throw".
    func testShortcutHelp_doneButton_tapRunsDismiss() throws {
        try ShortcutHelpSheet().inspect().find(button: "Done").tap()
    }

    /// The sheet renders its shortcut composition (sanity: the Done button is reachable in a
    /// fully-rendered tree, and no machine path leaks).
    func testShortcutHelp_rendersAndNoLeak() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: ShortcutHelpSheet())
        XCTAssertTrue(tree.contains("Keyboard Shortcuts"), "the sheet title renders:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }
}
#endif
