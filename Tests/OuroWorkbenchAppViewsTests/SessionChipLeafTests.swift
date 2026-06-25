#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C1 — `SessionChip`, the SECOND audit "look-covered-but-AREN'T" real target (with
/// `GitBranchChip`, closed in C0). The chip is constructed inside `TerminalAgentRow`
/// ONLY behind `if !entry.isArchived, activity != nil || isStalled` — and NO live
/// sidebar fixture ever drives `activity != nil` / `isStalled`, so its `if let activity,
/// let todoLabel` body never renders in any existing reference (the AN-003 false-coverage
/// illusion). This leaf closes it (Q5 default: STANDALONE — the cleanest hermetic seam,
/// the SU3r-leaf pattern; defense-in-depth on the row is added in `SessionChipOnRowTests`).
///
/// **Provenance (P2).** `SessionActivity` is provenance-built through its REAL producer —
/// `SessionActivity.parse(claudeJSONLTail:)` — fed canonical Claude Code JSONL tail bytes
/// (the exact shape `SessionActivityReader.activity(forDirectory:agentKind:)` tails out of
/// `~/.claude/projects/*.jsonl`). We do NOT hand-assemble the struct's fields; we parse a
/// real transcript tail so the chip renders the SAME `todoLabel`/`activeForm` the live
/// reader would yield (the GitBranchChip-porcelain precedent). The chip is then instantiated
/// DIRECTLY via its own `View` initializer (the legitimate leaf seam — P2 forbids
/// hand-assembling serializer OUTPUT / model STATE, not instantiating a `View` with a real
/// Core value, exactly the SU3r precedent). The `isStalled`/`attention` facets are plain
/// `View` inputs (the row passes `entry.attention` + a `ProcessRun.lastOutputAt`-derived
/// flag — value inputs, not a producer).
///
/// **Determinism (P3).** The JSONL fixtures carry NO machine path, clock, or UUID (todo
/// status enums + an `activeForm` label only) — the serialized tree is byte-identical twice
/// and leak-free. The chip's `.help(...)` tooltips are dropped by the host (AN-004), so the
/// only captured content is the health glyph `Image`, the `checklist` glyph, the `done/total`
/// `Text`, the `· activeForm` `Text`, and the a11y label.
///
/// **Enumerated state-set (the chip's data-driven branches):**
///   - `healthOnly`      — `activity == nil`, not stalled → ONLY the health glyph (the row
///                         only builds the chip at all when stalled here; the standalone
///                         leaf exercises the `activity == nil` arm directly).
///   - `stalled`         — `isStalled == true` → the amber `zzz` glyph (vs the attention
///                         health symbol) + "stalled" a11y.
///   - `todoProgress`    — a parsed TodoWrite snapshot → the `checklist` glyph + `done/total`
///                         `Text`; no in-progress item → no `· activeForm`.
///   - `todoActiveForm`  — a parsed in-progress todo → `done/total` + the `· <activeForm>`
///                         `Text` (the agent's own step description).
@MainActor
final class SessionChipLeafTests: XCTestCase {

    /// Canonical Claude Code JSONL tail, assembled from the documented schema (one JSON
    /// object per line; an `assistant` record whose `message.content[]` carries a
    /// `TodoWrite` tool_use with `input.todos[]` of `{content,status,activeForm}`) — the
    /// exact shape `SessionActivityReader` tails and `SessionActivity.parse(claudeJSONLTail:)`
    /// distills. Building the TAIL (not the struct) keeps the provenance on the real producer.
    private func claudeTail(todos: [(content: String, status: String, activeForm: String)]) -> String {
        let todoJSON = todos.map { todo in
            "{\"content\":\"\(todo.content)\",\"status\":\"\(todo.status)\",\"activeForm\":\"\(todo.activeForm)\"}"
        }.joined(separator: ",")
        let line = """
        {"type":"assistant","message":{"id":"msg_fixture_1","model":"claude-opus-4-8",\
        "content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[\(todoJSON)]}}]}}
        """
        // A leading partial line + the real record — the byte-bounded-tail shape the reader sees.
        return "…partial-first-line-skipped\n" + line + "\n"
    }

    /// Build the chip's `SessionActivity` by PARSING real Claude JSONL (the producer),
    /// then instantiate the chip directly.
    private func chip(
        attention: AttentionState = .active,
        isStalled: Bool = false,
        todos: [(content: String, status: String, activeForm: String)]? = nil
    ) -> SessionChip {
        let activity = todos.map { SessionActivity.parse(claudeJSONLTail: claudeTail(todos: $0)) }
        return SessionChip(attention: attention, activity: activity, isStalled: isStalled)
    }

    // MARK: - Enumerated state-set

    func testChip_healthOnly() throws {
        // The `activity == nil` arm: only the health glyph renders (no checklist/todo Text).
        let view = chip(attention: .active, isStalled: false, todos: nil)
        XCTAssertNil(view.activity, "provenance: no transcript activity → health-only chip")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("checklist"), "health-only: no todo mini:\n\(tree)")
        XCTAssertTrue(tree.contains("bolt.fill"), "active health glyph renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SessionChip.healthOnly")
    }

    func testChip_stalled() throws {
        // `isStalled` overrides the attention glyph with the amber `zzz` + "stalled" a11y.
        let view = chip(attention: .active, isStalled: true, todos: nil)
        XCTAssertTrue(view.isStalled, "provenance: stalled flag set")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("zzz"), "stalled: the zzz glyph renders:\n\(tree)")
        XCTAssertTrue(tree.contains("stalled"), "stalled: the a11y read:\n\(tree)")
        XCTAssertFalse(tree.contains("bolt.fill"), "stalled: the active glyph is replaced:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SessionChip.stalled")
    }

    func testChip_todoProgress() throws {
        // Two completed of three todos, none in-progress → "2/3", no `· activeForm`.
        let view = chip(attention: .active, todos: [
            (content: "Write tests", status: "completed", activeForm: "Writing tests"),
            (content: "Implement", status: "completed", activeForm: "Implementing"),
            (content: "Ship it", status: "pending", activeForm: "Shipping it")
        ])
        let activity = try XCTUnwrap(view.activity)
        XCTAssertEqual(activity.todoLabel, "2/3", "provenance: parsed 2 done of 3")
        XCTAssertNil(activity.activeForm, "provenance: nothing in-progress")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("checklist"), "todo mini renders the checklist glyph:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="2/3""#), "the done/total label renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SessionChip.todoProgress")
    }

    func testChip_todoActiveForm() throws {
        // One in-progress todo → "1/3" + the `· Merging PR chain` step description.
        let view = chip(attention: .active, todos: [
            (content: "Plan", status: "completed", activeForm: "Planning"),
            (content: "Merge the chain", status: "in_progress", activeForm: "Merging PR chain"),
            (content: "Verify", status: "pending", activeForm: "Verifying")
        ])
        let activity = try XCTUnwrap(view.activity)
        XCTAssertEqual(activity.todoLabel, "1/3", "provenance: 1 done of 3")
        XCTAssertEqual(activity.activeForm, "Merging PR chain", "provenance: parsed the in-progress step")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("· Merging PR chain"), "the activeForm step renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SessionChip.todoActiveForm")
    }

    // MARK: - Negative control (P2 mutation-verified): the parsed activity + stalled flag drive the tree

    /// Each parsed todo snapshot / stalled flip changes the captured tree. The load-bearing
    /// proof the chip renders its DATA (not a constant) — the false-coverage illusion was
    /// precisely that no live fixture ever exercised `activity != nil` / `isStalled`.
    func testChip_negativeControl_parsedActivityAndStalledFlipTree() throws {
        let healthOnly = try ViewSnapshotHost.snapshotText(of: chip(todos: nil))
        let stalled = try ViewSnapshotHost.snapshotText(of: chip(isStalled: true, todos: nil))
        let progress = try ViewSnapshotHost.snapshotText(of: chip(todos: [
            (content: "a", status: "completed", activeForm: "A"),
            (content: "b", status: "pending", activeForm: "B")
        ]))
        let activeForm = try ViewSnapshotHost.snapshotText(of: chip(todos: [
            (content: "a", status: "completed", activeForm: "A"),
            (content: "b", status: "in_progress", activeForm: "Doing B")
        ]))

        XCTAssertNotEqual(healthOnly, stalled, "the isStalled flag must drive the glyph")
        XCTAssertTrue(stalled.contains("zzz"), "stalled: zzz glyph:\n\(stalled)")
        XCTAssertFalse(healthOnly.contains("zzz"), "not-stalled: no zzz glyph:\n\(healthOnly)")

        XCTAssertNotEqual(healthOnly, progress, "a parsed todo snapshot must add the todo mini")
        XCTAssertTrue(progress.contains(#"text="1/2""#), "progress: the parsed done/total:\n\(progress)")
        XCTAssertFalse(healthOnly.contains("checklist"), "health-only: no todo mini:\n\(healthOnly)")

        XCTAssertNotEqual(progress, activeForm, "a parsed in-progress step must add the activeForm Text")
        XCTAssertTrue(activeForm.contains("· Doing B"), "activeForm: the step renders:\n\(activeForm)")
        XCTAssertFalse(progress.contains("· "), "no in-progress todo: no activeForm step:\n\(progress)")
    }

    // MARK: - Determinism (P3)

    func testChip_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("healthOnly", { try ViewSnapshotHost.snapshotText(of: self.chip(todos: nil)) }),
            ("stalled", { try ViewSnapshotHost.snapshotText(of: self.chip(isStalled: true, todos: nil)) }),
            ("todoProgress", { try ViewSnapshotHost.snapshotText(of: self.chip(todos: [
                (content: "x", status: "completed", activeForm: "X"),
                (content: "y", status: "pending", activeForm: "Y")
            ])) }),
            ("todoActiveForm", { try ViewSnapshotHost.snapshotText(of: self.chip(todos: [
                (content: "x", status: "in_progress", activeForm: "Doing X")
            ])) })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
