#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `TerminalAgentRow` (`:3717`) git-dirty accessibilityLabel arm drive-to-100%.
///
/// The SU3r `TerminalAgentRowRunningLeafTests` never pass a DIRTY `gitStatus`, so the
/// `accessibilityLabel`'s `gitStatus.dirty ? ", uncommitted changes" : ""` TRUE arm (`L3839:60`)
/// was uncovered. This suite renders the row with a dirty repo status and asserts the a11y read
/// includes "uncommitted changes", then MUTATION-VERIFIES it against a clean repo.
///
/// **Provenance (P2).** `GitSessionStatus` is built through its REAL producer
/// `GitSessionStatus.parse(porcelainV2:)` fed canonical porcelain (the GitBranchChip leaf
/// precedent), so the row reads the SAME value the live git reader yields. The row is a pure
/// value view instantiated directly.
///
/// **Determinism (P3).** Fixed ids; FIXED `/tmp/u5b1tar` working dir; no clock; `!contains("/Users/")`.
@MainActor
final class TerminalAgentRowGitLabelInteractionTests: XCTestCase {

    private func entry() -> ProcessEntry {
        ProcessEntry(id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000B")!,
                     projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000FA")!,
                     name: "git-agent", kind: .shell, executable: "/bin/zsh",
                     workingDirectory: "/tmp/u5b1tar")
    }

    private func porcelain(branch: String, dirty: Bool) -> String {
        var lines = ["# branch.oid abcdef0123456789", "# branch.head \(branch)"]
        if dirty { lines.append("1 .M N... 100644 100644 100644 abc def file.txt") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func row(dirty: Bool) -> TerminalAgentRow {
        let status = GitSessionStatus.parse(porcelainV2: porcelain(branch: "main", dirty: dirty))
        return TerminalAgentRow(entry: entry(), isSelected: false, gitStatus: status)
    }

    // MARK: - Dirty repo → the ", uncommitted changes" a11y arm

    func testDirtyGit_accessibilityLabelIncludesUncommitted() throws {
        let view = row(dirty: true)
        XCTAssertTrue(view.gitStatus?.dirty == true, "provenance: parsed a dirty tree")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("uncommitted changes"),
                      "the dirty arm renders ', uncommitted changes' in the a11y label:\n\(tree)")
        XCTAssertTrue(tree.contains("git main"), "the a11y label names the branch:\n\(tree)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The dirty ternary is load-bearing: a clean repo omits "uncommitted changes"; a dirty one
    /// includes it. (Mutation-verify: forcing the ternary to always-"" makes the dirty case omit
    /// the substring → the dirty assertion above RED.)
    func testNegativeControl_cleanVsDirtyLabel() throws {
        let cleanTree = try ViewSnapshotHost.snapshotText(of: row(dirty: false))
        let dirtyTree = try ViewSnapshotHost.snapshotText(of: row(dirty: true))
        XCTAssertNotEqual(cleanTree, dirtyTree, "the dirty flag must change the a11y label")
        XCTAssertFalse(cleanTree.contains("uncommitted changes"), "clean: no 'uncommitted changes':\n\(cleanTree)")
        XCTAssertTrue(dirtyTree.contains("uncommitted changes"), "dirty: 'uncommitted changes' present:\n\(dirtyTree)")
    }

    // MARK: - Determinism (P3)

    func testRow_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: row(dirty: true))
        let b = try ViewSnapshotHost.snapshotText(of: row(dirty: true))
        XCTAssertEqual(a, b, "the dirty-git row must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
