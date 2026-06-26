#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-6 — `BossConversationView` (`:5828`) enumerated state-set.
///
/// The captured tree carries: the "Boss Line" `Label` (a `Text` + a
/// `bubble.left.and.text.bubble.right` `Image`), the bound `$model.bossQuestion`
/// `TextField` VALUE (AN-002 `input()` — NOT the placeholder, which interpolates the boss
/// name and is de-duped by the host), the "Ask" button `Label`, and the
/// `ForEach(bossQuickQuestions)` (`:5857`) four fixed quick-question button titles
/// ("What's Going On?", "Waiting On Me?", "Keep Moving", "Respond For Me").
///
/// The data-driven, logic-bearing dimension is the bound `bossQuestion` VALUE — a real
/// `@Published` value-flip that changes the captured `TextField` node (the `SidebarCountBadge`
/// value-flip standard). The Ask button's `.disabled(...)` (trimmed-empty || running) is a
/// DROPPED attribute (the host whitelist drops `.disabled`), so it is asserted on model
/// state, not the tree.
///
/// **Provenance (P2).** `model` via the `makeVM` store seam (AN-001 hermetic); `bossQuestion`
/// is the real stored `@Published` the field binds to. The quick-question titles come from the
/// module's fixed `bossQuickQuestions` catalogue (the real production source).
///
/// **Enumerated state-set (the bound-value flip):**
///   - `empty` — `bossQuestion == ""` → the empty bound field + the 4 quick-question buttons.
///   - `typed` — a typed question → the bound value renders in the captured `TextField`.
@MainActor
final class BossConversationViewTests: XCTestCase {

    private func makeVM(bossName: String = "boss-agent") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-bcv-\(UUID().uuidString)", isDirectory: true)
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

    private func conversation(question: String) throws -> BossConversationView {
        let model = try makeVM()
        model.bossQuestion = question
        return BossConversationView(model: model)
    }

    // MARK: - Enumerated state-set

    func testConversation_empty() throws {
        let view = try conversation(question: "")
        XCTAssertEqual(view.model.bossQuestion, "", "provenance: empty bound question")
        try assertViewSnapshot(of: view, named: "BossConversationView.empty")
    }

    func testConversation_typed() throws {
        let view = try conversation(question: "What is running right now?")
        XCTAssertEqual(view.model.bossQuestion, "What is running right now?",
                       "provenance: the bound question value")
        try assertViewSnapshot(of: view, named: "BossConversationView.typed")
    }

    // MARK: - Determinism (P3)

    func testConversation_determinism_byteIdenticalTwiceAndNoLeak() throws {
        for (name, q) in [("empty", ""), ("typed", "What is running right now?")] {
            let a = try ViewSnapshotHost.snapshotText(of: try conversation(question: q))
            let b = try ViewSnapshotHost.snapshotText(of: try conversation(question: q))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The bound `bossQuestion` value flips the captured `TextField` (a value-flip), and the
    /// `ForEach(bossQuickQuestions)` renders the four fixed quick-question titles.
    func testConversation_negativeControl_boundValueAndQuickQuestionsInTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: try conversation(question: ""))
        let typed = try ViewSnapshotHost.snapshotText(of: try conversation(question: "What is running right now?"))

        // (a) the bound value flips the field node.
        XCTAssertNotEqual(empty, typed, "the bound question value must drive the tree")
        XCTAssertTrue(typed.contains("What is running right now?"),
                      "typed: the bound value renders:\n\(typed)")
        XCTAssertFalse(empty.contains("What is running right now?"),
                       "empty: the typed value is absent:\n\(empty)")

        // (b) the ForEach renders all four fixed quick-question titles + the Boss Line label.
        for title in ["What's Going On?", "Waiting On Me?", "Keep Moving", "Respond For Me"] {
            XCTAssertTrue(empty.contains(title), "the quick-question '\(title)' must render:\n\(empty)")
        }
        XCTAssertTrue(empty.contains("Boss Line"), "the Boss Line label renders:\n\(empty)")
    }
}
#endif
