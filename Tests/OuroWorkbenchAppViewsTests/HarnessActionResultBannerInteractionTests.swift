#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `HarnessActionResultBanner` (`:1589`) INTERACTION drive-to-100%.
///
/// The C11 `HarnessActionResultBannerTests` snapshot the RENDER arms (success seal /
/// warning triangle / message) but never EXECUTE the dismiss action — so 1 region
/// segment (the close `Button { onDismiss() }`) was never coloured. ViewInspector
/// 0.10.3 invokes button actions (`.tap()`), so this suite DRIVES it and asserts the
/// `onDismiss` callback fired (provenance), mutation-verified.
///
/// **Carves:** none — the only un-driven region was the dismiss action, driven here.
@MainActor
final class HarnessActionResultBannerInteractionTests: XCTestCase {

    private func result(succeeded: Bool = true) -> HarnessActionResult {
        HarnessActionResult(kind: .repairDaemon, succeeded: succeeded,
                            message: "Brought your agent back online.")
    }

    /// The close `Button { onDismiss() } label: { Image("xmark") }` — tapping fires the
    /// injected `onDismiss` callback (the `HarnessStatusSheet` call site clears
    /// `model.harnessActionResult`). Assert the callback ran via a captured flag.
    func testBanner_dismissButton_firesOnDismiss() throws {
        var dismissed = false
        let banner = HarnessActionResultBanner(result: result()) { dismissed = true }
        try banner.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(dismissed, "tapping the close button fires the onDismiss callback")
    }

    /// Negative control (P2): the dismiss callback is the ONLY action. With success vs
    /// failure the icon flips, but the callback is invariant — proven by the flag flip.
    func testBanner_negativeControl_dismissFiresForBothTones() throws {
        for succeeded in [true, false] {
            var dismissed = false
            let banner = HarnessActionResultBanner(result: result(succeeded: succeeded)) { dismissed = true }
            try banner.inspect().find(ViewType.Button.self).tap()
            XCTAssertTrue(dismissed, "tone succeeded=\(succeeded): the dismiss callback fired")
        }
    }

    func testBanner_rendersAndNoLeak() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: HarnessActionResultBanner(result: result()) {})
        XCTAssertTrue(tree.contains("Brought your agent back online."), "the message renders:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }
}
#endif
