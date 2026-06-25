#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C1 — defense-in-depth for the `SessionChip` / `GitBranchChip` real-target gap (Q5
/// default: STANDALONE leaf + on the REAL `TerminalAgentRow(activity:gitStatus:isStalled:)`
/// path). The standalone leaves (`SessionChipLeafTests`, `GitBranchChipLeafTests`) prove
/// the chips render their data; THIS file proves the chips are actually WIRED into the row
/// behind the row's own gate — the gate the live sidebar never exercises:
///
///   `if !entry.isArchived, activity != nil || isStalled { SessionChip(...) }`   (the chip gate)
///   `if let gitStatus, gitStatus.isRepo { GitBranchChip(status: gitStatus) }`    (the branch gate)
///
/// No live sidebar fixture drives those gates (AN-003: the sidebar constructs the row WITHOUT
/// `activity`/`gitStatus`), so this closes the false-coverage illusion on the composition,
/// not just the leaves.
///
/// **Provenance (P2).** `SessionActivity` ← `SessionActivity.parse(claudeJSONLTail:)` (the real
/// producer); `GitSessionStatus` ← `GitSessionStatus.parse(porcelainV2:)` (the real producer).
/// `ProcessEntry` is a `public` Core value; the row is then instantiated via its own `View`
/// initializer (the leaf seam, SU3r precedent). No model needed — the row is a pure value view.
///
/// **Determinism (P3).** Fixed entry id + a fixed `/tmp/u4` working directory + a fixed branch
/// + fixed parsed todos; no clock (no `runningSince` → no `ElapsedTimePill`); byte-identical
/// twice; `!contains("/Users/")`.
@MainActor
final class SessionChipOnRowTests: XCTestCase {

    private static let entryId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    private func entry(isArchived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId,
            projectId: Self.projectId,
            name: "agent-session",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/u4",
            isArchived: isArchived,
            attention: .active
        )
    }

    /// A parsed activity with one in-progress todo (the real producer).
    private func activity() -> SessionActivity {
        SessionActivity.parse(claudeJSONLTail: """
        {"type":"assistant","message":{"id":"m1","model":"claude-opus-4-8","content":[\
        {"type":"tool_use","name":"TodoWrite","input":{"todos":[\
        {"content":"a","status":"completed","activeForm":"A"},\
        {"content":"b","status":"in_progress","activeForm":"Wiring the chip"}]}}]}}
        """ + "\n")
    }

    /// A clean repo on `main` (the real porcelain producer).
    private func gitStatus() -> GitSessionStatus {
        GitSessionStatus.parse(porcelainV2: "# branch.oid abc\n# branch.head main\n")
    }

    private func row(
        activity: SessionActivity? = nil,
        gitStatus: GitSessionStatus? = nil,
        isStalled: Bool = false,
        isArchived: Bool = false
    ) -> TerminalAgentRow {
        TerminalAgentRow(
            entry: entry(isArchived: isArchived),
            isSelected: false,
            gitStatus: gitStatus,
            activity: activity,
            isStalled: isStalled
        )
    }

    // MARK: - The row's gates render the chips (the closed illusion)

    func testRow_withActivity_rendersSessionChipOnRow() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: row(activity: activity()))
        XCTAssertTrue(tree.contains("checklist"), "the SessionChip todo mini renders ON the row:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="1/2""#), "the parsed todo label renders on the row:\n\(tree)")
        XCTAssertTrue(tree.contains("· Wiring the chip"), "the parsed activeForm renders on the row:\n\(tree)")
        try assertViewSnapshot(of: row(activity: activity()), named: "TerminalAgentRow.withActivity")
    }

    func testRow_withGitRepo_rendersGitBranchChipOnRow() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: row(gitStatus: gitStatus()))
        XCTAssertTrue(tree.contains("arrow.triangle.branch"), "the GitBranchChip glyph renders on the row:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="main""#), "the parsed branch label renders on the row:\n\(tree)")
        try assertViewSnapshot(of: row(gitStatus: gitStatus()), named: "TerminalAgentRow.withGitRepo")
    }

    func testRow_stalledAndRepo_rendersBothChips() throws {
        // Both gates open: stalled SessionChip (no activity needed — `isStalled` alone opens it) + the branch chip.
        let view = row(gitStatus: gitStatus(), isStalled: true)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("zzz"), "stalled session chip on the row:\n\(tree)")
        XCTAssertTrue(tree.contains("arrow.triangle.branch"), "branch chip on the row:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TerminalAgentRow.stalledAndRepo")
    }

    // MARK: - Negative control (P2): the row's gates govern the chips

    /// The row's two gates each govern a chip's presence: no activity & not stalled → NO
    /// SessionChip; a not-a-repo `gitStatus` → NO GitBranchChip; an ARCHIVED entry suppresses
    /// the SessionChip even when stalled (the `!entry.isArchived` half of the gate).
    func testRow_negativeControl_gatesGovernChips() throws {
        let bare = try ViewSnapshotHost.snapshotText(of: row())
        let withChip = try ViewSnapshotHost.snapshotText(of: row(activity: activity()))
        let withBranch = try ViewSnapshotHost.snapshotText(of: row(gitStatus: gitStatus()))
        let notARepo = try ViewSnapshotHost.snapshotText(of: row(gitStatus: .notARepo))
        let archivedStalled = try ViewSnapshotHost.snapshotText(of: row(isStalled: true, isArchived: true))

        XCTAssertFalse(bare.contains("checklist"), "no activity & not stalled → no SessionChip:\n\(bare)")
        XCTAssertNotEqual(bare, withChip, "an activity must open the chip gate")
        XCTAssertTrue(withChip.contains("checklist"), "activity → SessionChip:\n\(withChip)")

        XCTAssertFalse(bare.contains("arrow.triangle.branch"), "no gitStatus → no branch chip:\n\(bare)")
        XCTAssertNotEqual(bare, withBranch, "a repo gitStatus must open the branch gate")
        XCTAssertFalse(notARepo.contains("arrow.triangle.branch"), "not-a-repo → no branch chip:\n\(notARepo)")

        XCTAssertFalse(archivedStalled.contains("zzz"), "archived → the !isArchived gate suppresses the chip:\n\(archivedStalled)")
    }

    // MARK: - Determinism (P3)

    func testRow_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("withActivity", { try ViewSnapshotHost.snapshotText(of: self.row(activity: self.activity())) }),
            ("withGitRepo", { try ViewSnapshotHost.snapshotText(of: self.row(gitStatus: self.gitStatus())) }),
            ("stalledAndRepo", { try ViewSnapshotHost.snapshotText(of: self.row(gitStatus: self.gitStatus(), isStalled: true)) })
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
