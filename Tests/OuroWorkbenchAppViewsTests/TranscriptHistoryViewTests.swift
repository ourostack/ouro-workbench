#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `TranscriptHistoryView` (`:9917`). The campaign drove the populated /
/// truncated arms but never the EMPTY-transcript fallback (`L9938:42` —
/// `Text(tail.text.isEmpty ? "No transcript output yet" : tail.text)`'s
/// `isEmpty` arm). This view takes a `TranscriptTail` directly (no model), so the
/// fixture is a pure value-seam: an empty-text tail renders the placeholder; a
/// populated tail renders the body. The `tail.truncated` header arm is also driven
/// here (both arms) to keep the decl at 0 uncovered.
///
/// FIXED tail.path (`/tmp/u5/session.log`) — the path renders verbatim, so a real
/// machine path would leak; pinned + defended by `!contains("/Users/")`.
@MainActor
final class TranscriptHistoryViewTests: XCTestCase {

    private func tail(text: String, truncated: Bool = false) -> TranscriptTail {
        TranscriptTail(path: "/tmp/u5/session.log", text: text, truncated: truncated)
    }

    // MARK: - The empty-text arm (the uncovered region L9938:42)

    func testHistory_emptyTranscript_rendersPlaceholder() throws {
        let view = TranscriptHistoryView(tail: tail(text: ""))
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="No transcript output yet""#),
                      "the empty-text arm renders the placeholder:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Latest Transcript""#), "the header:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TranscriptHistoryView.empty")
    }

    // MARK: - The populated arm + the truncated-badge arm

    func testHistory_populatedTruncated_rendersBodyAndTailBadge() throws {
        let view = TranscriptHistoryView(tail: tail(text: "$ make\nok\n", truncated: true))
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="$ make"#), "the populated body renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="tail""#), "the truncated badge renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TranscriptHistoryView.populatedTruncated")
    }

    // MARK: - Negative control (P2 mutation-verified — the empty/populated flip)

    func testHistory_negativeControl_emptyFlipsBody() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(tail: tail(text: "")))
        let full = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(tail: tail(text: "hello")))
        XCTAssertNotEqual(empty, full, "the empty-text arm must flip the body text")
        XCTAssertTrue(empty.contains(#"text="No transcript output yet""#))
        XCTAssertTrue(full.contains(#"text="hello""#))
        XCTAssertFalse(full.contains(#"text="No transcript output yet""#),
                       "populated: not the placeholder:\n\(full)")
    }

    // MARK: - Path-leak + determinism (P3)

    func testHistory_noMachinePathLeak_deterministic() throws {
        let a = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(tail: tail(text: "x", truncated: true)))
        let b = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(tail: tail(text: "x", truncated: true)))
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ machine-path leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir path leak:\n\(a)")
    }
}
#endif
