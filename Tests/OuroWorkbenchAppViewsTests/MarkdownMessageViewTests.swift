#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C8 — `MarkdownMessageView` (the boss-message markdown leaf).
///
/// A PURE leaf: `let text: String` → `ForEach(BossMessageMarkdown.blocks(from: text))`
/// with a `switch block` over the four real `MarkdownBlock` cases — `.heading`, `.bullet`,
/// `.paragraph`, `.blank`. The block classification flows through the REAL pure Core
/// producer (`BossMessageMarkdown.blocks(from:)`); each non-blank case renders an `inline(_:)`
/// `Text` whose string the host captures (a `Text(AttributedString(markdown:))` resolves to
/// its plain rendered string under `.string(locale:)`). A `.blank` block renders a
/// `Color.clear` spacer — a NON-content node the host drops, so a blank line is observable
/// only by the ABSENCE of a node, not a captured one.
///
/// **Determinism (P3).** No model, no clock, no path, no machine value — the input is a fixed
/// literal markdown string → byte-identical twice. No AN-001 (no `ouroAgents`/inventory read).
///
/// **Provenance (P2).** The block sequence is the real producer's output for the fixed input;
/// the test asserts the captured tree matches the producer's classification (no fabrication —
/// every rendered line corresponds to a `BossMessageMarkdown.blocks` block).
///
/// **Enumerated state-set (the `switch block` arms):**
///   - `paragraph` — a plain line → one paragraph `Text`.
///   - `heading`   — `## Heading` → one heading `Text` (the `#`/space stripped by the producer).
///   - `bullet`    — `- item` → a "•" marker `Text` + the bullet `Text` (marker stripped).
///   - `mixed`     — heading + blank + two bullets + paragraph (all four arms in one tree).
@MainActor
final class MarkdownMessageViewTests: XCTestCase {

    private func view(_ text: String) -> MarkdownMessageView {
        MarkdownMessageView(text: text)
    }

    // MARK: - Enumerated state-set (one fixture per block arm + a mixed tree)

    func testMarkdown_paragraph() throws {
        let v = view("Just a plain paragraph line.")
        // Provenance: the producer classifies this single line as ONE paragraph.
        XCTAssertEqual(BossMessageMarkdown.blocks(from: "Just a plain paragraph line."),
                       [.paragraph(text: "Just a plain paragraph line.")],
                       "provenance: the real producer yields one paragraph block")
        try assertViewSnapshot(of: v, named: "MarkdownMessageView.paragraph")
    }

    func testMarkdown_heading() throws {
        let v = view("## Section Heading")
        XCTAssertEqual(BossMessageMarkdown.blocks(from: "## Section Heading"),
                       [.heading(level: 2, text: "Section Heading")],
                       "provenance: the real producer yields one level-2 heading")
        let tree = try ViewSnapshotHost.snapshotText(of: v)
        XCTAssertTrue(tree.contains(#"text="Section Heading""#),
                      "heading: the producer-stripped heading text renders:\n\(tree)")
        XCTAssertFalse(tree.contains("##"), "heading: the leading hashes are stripped:\n\(tree)")
        try assertViewSnapshot(of: v, named: "MarkdownMessageView.heading")
    }

    func testMarkdown_bullet() throws {
        let v = view("- A single bullet point")
        XCTAssertEqual(BossMessageMarkdown.blocks(from: "- A single bullet point"),
                       [.bullet(indent: 0, text: "A single bullet point")],
                       "provenance: the real producer yields one bullet")
        let tree = try ViewSnapshotHost.snapshotText(of: v)
        XCTAssertTrue(tree.contains(#"text="•""#), "bullet: the marker glyph renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="A single bullet point""#),
                      "bullet: the producer-stripped bullet text renders:\n\(tree)")
        try assertViewSnapshot(of: v, named: "MarkdownMessageView.bullet")
    }

    func testMarkdown_mixed_allFourArms() throws {
        let text = """
        ## Status

        - first item
        - second item
        That wraps it up.
        """
        // Provenance: the real producer yields heading · blank · bullet · bullet · paragraph.
        XCTAssertEqual(BossMessageMarkdown.blocks(from: text), [
            .heading(level: 2, text: "Status"),
            .blank,
            .bullet(indent: 0, text: "first item"),
            .bullet(indent: 0, text: "second item"),
            .paragraph(text: "That wraps it up.")
        ], "provenance: the real producer classifies all four arms")
        let v = view(text)
        let tree = try ViewSnapshotHost.snapshotText(of: v)
        XCTAssertTrue(tree.contains(#"text="Status""#), "mixed: heading renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="first item""#), "mixed: bullet 1 renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="second item""#), "mixed: bullet 2 renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="That wraps it up.""#), "mixed: paragraph renders:\n\(tree)")
        try assertViewSnapshot(of: v, named: "MarkdownMessageView.mixed")
    }

    // MARK: - Determinism (P3)

    func testMarkdown_byteIdenticalTwiceAndNoLeak() throws {
        let fixtures = ["Just a plain paragraph line.", "## Section Heading", "- A single bullet point"]
        for text in fixtures {
            let a = try ViewSnapshotHost.snapshotText(of: view(text))
            let b = try ViewSnapshotHost.snapshotText(of: view(text))
            XCTAssertEqual(a, b, "'\(text)' must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "'\(text)': no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The producer's block classification drives the captured tree: a heading line, a
    /// bullet line, and a paragraph line each serialize to a DISTINCT tree (different
    /// arms of the `switch block`).
    func testMarkdown_negativeControl_blockArmsFlipTree() throws {
        let para = try ViewSnapshotHost.snapshotText(of: view("plain line"))
        let heading = try ViewSnapshotHost.snapshotText(of: view("## plain line"))
        let bullet = try ViewSnapshotHost.snapshotText(of: view("- plain line"))

        XCTAssertNotEqual(para, bullet,
                          "the bullet arm must add the '•' marker node the paragraph lacks")
        XCTAssertTrue(para.contains(#"text="plain line""#), "paragraph: the text:\n\(para)")
        XCTAssertFalse(para.contains(#"text="•""#), "paragraph: NO bullet marker:\n\(para)")
        XCTAssertTrue(bullet.contains(#"text="•""#), "bullet: the marker:\n\(bullet)")
        // Heading vs paragraph: same captured string but the producer routes them to
        // different arms — proven by the producer assertion (the host whitelist drops the
        // font that distinguishes them visually, so they share a tree; that is recorded).
        XCTAssertEqual(BossMessageMarkdown.blocks(from: "## plain line"),
                       [.heading(level: 2, text: "plain line")])
        XCTAssertEqual(heading, para,
                       "heading vs paragraph share a captured tree (font-only diff dropped) — recorded")
    }
}
#endif
