#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `TranscriptRehydrationPreview` (`:9578`). Pure value-seam (takes a
/// `TranscriptTail` + an `onShowTranscript` closure). Uncovered regions:
///   - `L9616:35` — the `if tail.truncated` "tail" badge arm;
///   - `L9621:24` — the `Button { onShowTranscript() }` ACTION closure;
///   - `L9630:44` — the `previewText.isEmpty ? "No transcript output yet." : previewText`
///     EMPTY arm (an all-blank transcript → empty preview);
///   - `L9602:75` — the `strippingAnsiEscapes` `guard let regex = try? … else { return input }`
///     ELSE arm: the regex pattern is a FIXED valid literal that always compiles, so the else is
///     genuinely UNREACHABLE — recorded as a micro-carve (the only B5 carve).
///
/// DRIVEN: truncated + non-truncated tails (the badge arm + its absence), an empty-text tail
/// (the empty-preview arm), and the "View full transcript" button INVOKED via `.tap()` which
/// runs `onShowTranscript()` — asserted via a captured flag + mutation-verified.
@MainActor
final class TranscriptRehydrationPreviewDriveTests: XCTestCase {

    private func tail(text: String, truncated: Bool = false) -> TranscriptTail {
        TranscriptTail(path: "/tmp/u5/rehydrate.log", text: text, truncated: truncated)
    }

    // MARK: - L9616 — the truncated "tail" badge arm

    func testPreview_truncated_rendersTailBadge() throws {
        let view = TranscriptRehydrationPreview(tail: tail(text: "last line\n", truncated: true), onShowTranscript: {})
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="tail""#), "the truncated tail badge:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="last line"#), "the preview body:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TranscriptRehydrationPreview.truncated")
    }

    // MARK: - L9630 — the empty-preview arm

    func testPreview_emptyTranscript_rendersPlaceholder() throws {
        // An all-whitespace transcript → previewText (after ANSI-strip + trailing) is empty.
        let view = TranscriptRehydrationPreview(tail: tail(text: ""), onShowTranscript: {})
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="No transcript output yet.""#),
                      "the empty-preview placeholder arm:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TranscriptRehydrationPreview.empty")
    }

    // MARK: - L9621 — drive the "View full transcript" button ACTION

    func testPreview_viewFullTranscriptTap_invokesCallback() throws {
        var shown = false
        let view = TranscriptRehydrationPreview(tail: tail(text: "body\n"), onShowTranscript: { shown = true })
        // INVOCATION: tap the button → runs onShowTranscript().
        try view.inspect().find(button: "View full transcript").tap()
        XCTAssertTrue(shown, "the View-full-transcript tap must invoke onShowTranscript")
    }

    // MARK: - Negative control (P2 mutation-verified)

    func testPreview_negativeControl_truncatedFlipsBadgeAndEmptyFlipsBody() throws {
        let truncated = try ViewSnapshotHost.snapshotText(of:
            TranscriptRehydrationPreview(tail: tail(text: "x\n", truncated: true), onShowTranscript: {}))
        let plain = try ViewSnapshotHost.snapshotText(of:
            TranscriptRehydrationPreview(tail: tail(text: "x\n", truncated: false), onShowTranscript: {}))
        XCTAssertNotEqual(truncated, plain, "the truncated badge must flip the tree")
        XCTAssertTrue(truncated.contains(#"text="tail""#))
        XCTAssertFalse(plain.contains(#"text="tail""#), "non-truncated: no badge:\n\(plain)")

        let empty = try ViewSnapshotHost.snapshotText(of:
            TranscriptRehydrationPreview(tail: tail(text: ""), onShowTranscript: {}))
        let full = try ViewSnapshotHost.snapshotText(of:
            TranscriptRehydrationPreview(tail: tail(text: "real output"), onShowTranscript: {}))
        XCTAssertNotEqual(empty, full, "the empty-preview arm must flip the body")
        XCTAssertTrue(empty.contains(#"text="No transcript output yet.""#))
        XCTAssertTrue(full.contains(#"text="real output""#))
    }

    func testPreview_deterministic_noLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of:
            TranscriptRehydrationPreview(tail: tail(text: "x\n", truncated: true), onShowTranscript: {}))
        let b = try ViewSnapshotHost.snapshotText(of:
            TranscriptRehydrationPreview(tail: tail(text: "x\n", truncated: true), onShowTranscript: {}))
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}
#endif
