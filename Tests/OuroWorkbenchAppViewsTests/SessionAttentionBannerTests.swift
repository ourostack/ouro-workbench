#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 — `SessionAttentionBanner` (`:8750`) drive-to-100%.
///
/// The slim one-line attention banner rendered above the terminal pane when a live
/// session needs the human. Its ONLY production call site is inside `SessionDetailView`
/// (a live-PTY K1 view ViewInspector cannot descend), so the C-series snapshot campaign
/// never reached it — its `body`, the three-arm `state` switch (waitingOnHuman / blocked /
/// needsBossReview), and BOTH `offersJumpToPrompt` arms were uncovered. This suite drives
/// every region directly (the view was promoted private->internal for the seam) and
/// mutation-verifies the rendered content.
///
/// **Provenance (P2).** `Banner` is built from its public init with fixed text — no model,
/// no clock, no path. The `onJump` closure is captured to a flag so the "Jump to prompt"
/// button action is asserted (not just rendered).
///
/// **Carves:** none — every region (both `offersJumpToPrompt` arms, all three `state`
/// kinds, the Jump action) is driven here.
@MainActor
final class SessionAttentionBannerTests: XCTestCase {

    private func banner(
        kind: SessionDetailAttentionPresentation.BannerKind,
        text: String = "Waiting on you · approve the change",
        offersJumpToPrompt: Bool = true
    ) -> SessionDetailAttentionPresentation.Banner {
        SessionDetailAttentionPresentation.Banner(
            kind: kind, text: text, offersJumpToPrompt: offersJumpToPrompt)
    }

    // MARK: - body + the offersJumpToPrompt TRUE arm + the Jump action

    /// `offersJumpToPrompt == true` renders the "Jump to prompt" button; tapping it fires
    /// the `onJump` callback (the SessionDetailView call site focuses the terminal).
    func testBanner_offersJump_rendersJumpButtonAndFiresOnJump() throws {
        var jumped = false
        let view = SessionAttentionBanner(banner: banner(kind: .waitingOnHuman)) { jumped = true }
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Waiting on you · approve the change"), "the headline renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Jump to prompt"), "the jump button renders when offered:\n\(tree)")
        try view.inspect().find(button: "Jump to prompt").tap()
        XCTAssertTrue(jumped, "tapping Jump to prompt fires the onJump callback")
    }

    // MARK: - the offersJumpToPrompt FALSE arm

    /// `offersJumpToPrompt == false` (the boss-review flag — no operator prompt to jump to)
    /// renders the headline but NO jump button (the `if banner.offersJumpToPrompt` FALSE arm).
    func testBanner_noJump_omitsJumpButton() throws {
        let view = SessionAttentionBanner(
            banner: banner(kind: .needsBossReview, text: "Flagged for boss review", offersJumpToPrompt: false)) {}
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Flagged for boss review"), "the headline still renders:\n\(tree)")
        XCTAssertFalse(tree.contains("Jump to prompt"), "no jump button when not offered:\n\(tree)")
        XCTAssertThrowsError(try view.inspect().find(button: "Jump to prompt"),
                             "the FALSE arm renders no Jump button")
    }

    // MARK: - the three-arm `state` switch (color/glyph per BannerKind)

    /// Every `BannerKind` resolves through the private `state` switch (each arm maps onto a
    /// distinct `AttentionState`). Snapshotting one banner per kind drives all three arms;
    /// each renders a non-empty tree with the right headline (mutation-verified below).
    func testBanner_everyKind_rendersThroughStateSwitch() throws {
        let cases: [(SessionDetailAttentionPresentation.BannerKind, String)] = [
            (.waitingOnHuman, "Waiting on you · approve"),
            (.blocked, "Blocked · build failed"),
            (.needsBossReview, "Flagged for boss review")
        ]
        for (kind, text) in cases {
            let view = SessionAttentionBanner(banner: banner(kind: kind, text: text)) {}
            let tree = try ViewSnapshotHost.snapshotText(of: view)
            XCTAssertTrue(tree.contains(text), "kind \(kind): the headline renders through the state switch:\n\(tree)")
        }
    }

    // MARK: - mutation guard (P2 — the content catch is non-vacuous)

    /// The headline is read from `banner.text`. Mutating the fixture text must change the
    /// rendered tree — proving the snapshot pins the real content, not a constant.
    func testBanner_mutationGuard_textFlipsTree() throws {
        let a = try ViewSnapshotHost.snapshotText(
            of: SessionAttentionBanner(banner: banner(kind: .blocked, text: "Blocked · build failed")) {})
        let b = try ViewSnapshotHost.snapshotText(
            of: SessionAttentionBanner(banner: banner(kind: .blocked, text: "MUTATED HEADLINE")) {})
        XCTAssertNotEqual(a, b, "changing banner.text changes the rendered tree (content is pinned)")
        XCTAssertTrue(b.contains("MUTATED HEADLINE"), "the mutated text reaches the tree")
    }

    // MARK: - determinism + no leak (P3)

    func testBanner_deterministicAndNoLeak() throws {
        let make = { SessionAttentionBanner(banner: self.banner(kind: .waitingOnHuman)) {} }
        let first = try ViewSnapshotHost.snapshotText(of: make())
        let second = try ViewSnapshotHost.snapshotText(of: make())
        XCTAssertEqual(first, second, "the banner serializes byte-identically twice")
        XCTAssertFalse(first.contains("/Users/"), "no machine-path leak:\n\(first)")
        XCTAssertFalse(first.contains("/var/folders/"), "no temp-path leak:\n\(first)")
    }
}
#endif
