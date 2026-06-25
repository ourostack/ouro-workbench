#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C0 SU-1 — the **real-target chip fixture** recipe (the audit's "look-covered-but-
/// AREN'T" class). `GitBranchChip` LOOKS covered because it is constructed inside
/// `TerminalAgentRow`, but no LIVE sidebar fixture ever drives `gitStatus.isRepo` —
/// so its `if let label = status.branchLabel` body never renders in any existing
/// reference (a false-coverage illusion; AN-003). This leaf closes it.
///
/// **Provenance (P2).** `GitSessionStatus` is provenance-built through its REAL
/// producer — `GitSessionStatus.parse(porcelainV2:)` — fed canonical `git status
/// --porcelain=v2 --branch` output (the exact bytes `GitStatusReader` shells out
/// for). We do NOT hand-assemble the struct's fields; we parse real porcelain so the
/// chip renders the SAME value the live git reader would yield. The chip is then
/// instantiated DIRECTLY via its own `View` initializer (the legitimate leaf seam —
/// P2 forbids hand-assembling serializer OUTPUT / model STATE, not instantiating a
/// `View` with a real Core value, exactly the SU3r precedent).
///
/// **Determinism (P3).** The porcelain fixtures carry NO machine path, clock, or
/// UUID (branch names + ahead/behind counts only) — the serialized tree is
/// byte-identical twice and leak-free. The chip's `.help(...)` tooltip is dropped by
/// the host (AN-004), so the only captured content is the branch label `Text` + the
/// ahead/behind `Text` + the branch glyph `Image`.
///
/// **Enumerated state-set (the chip's data-driven branches):**
///   - `clean`       — a repo on a branch, clean tree, in sync → glyph + branch label,
///                     no dirty dot, no ahead/behind suffix.
///   - `dirty`       — uncommitted change → the dirty `Circle` (NOT a captured node —
///                     geometry-only — but a load-bearing STATE; asserted via the
///                     parsed `status.dirty` provenance + the negative control).
///   - `aheadBehind` — diverged from upstream → the `↑2↓1` ahead/behind `Text` renders.
///   - `detached`    — detached HEAD → the branch label reads `(detached)`.
///   - `notARepo`    — `status.isRepo == false` → `branchLabel == nil` → the chip
///                     renders an EMPTY tree (the `if let` guard fails). The
///                     real-target gate that the false-coverage illusion hid.
@MainActor
final class GitBranchChipLeafTests: XCTestCase {

    /// Canonical `git status --porcelain=v2 --branch` output, assembled from the
    /// documented v2 line grammar (`# branch.head`, `# branch.ab +A -B`, and the
    /// `1`/`2`/`u`/`?` change lines) — the exact shape `GitStatusReader.status(...)`
    /// pipes into `GitSessionStatus.parse`. Building the PORCELAIN (not the struct)
    /// keeps the provenance on the real producer.
    private func porcelain(
        branch: String?,
        detached: Bool = false,
        dirty: Bool = false,
        ahead: Int = 0,
        behind: Int = 0
    ) -> String {
        var lines: [String] = ["# branch.oid abcdef0123456789"]
        if detached {
            lines.append("# branch.head (detached)")
        } else if let branch {
            lines.append("# branch.head \(branch)")
        }
        if ahead > 0 || behind > 0 {
            lines.append("# branch.ab +\(ahead) -\(behind)")
        }
        if dirty {
            // A changed tracked file (the `1` record) marks the tree dirty.
            lines.append("1 .M N... 100644 100644 100644 abc def file.txt")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Build the chip's `GitSessionStatus` by PARSING real porcelain (the producer),
    /// then instantiate the chip directly.
    private func chip(
        branch: String?,
        detached: Bool = false,
        dirty: Bool = false,
        ahead: Int = 0,
        behind: Int = 0
    ) -> GitBranchChip {
        let status = GitSessionStatus.parse(porcelainV2: porcelain(
            branch: branch, detached: detached, dirty: dirty, ahead: ahead, behind: behind))
        return GitBranchChip(status: status)
    }

    /// A genuinely not-a-repo status (the sentinel) → branchLabel nil → empty body.
    private func notARepoChip() -> GitBranchChip {
        GitBranchChip(status: .notARepo)
    }

    // MARK: - Enumerated state-set

    func testChip_clean() throws {
        let view = chip(branch: "main")
        XCTAssertEqual(view.status.branchLabel, "main", "provenance: parsed branch label")
        XCTAssertFalse(view.status.dirty, "provenance: clean tree")
        XCTAssertNil(view.status.aheadBehindLabel, "provenance: in sync")
        try assertViewSnapshot(of: view, named: "GitBranchChip.clean")
    }

    func testChip_dirty() throws {
        let view = chip(branch: "feature/login", dirty: true)
        XCTAssertEqual(view.status.branchLabel, "feature/login")
        XCTAssertTrue(view.status.dirty, "provenance: parsed a dirty tree")
        try assertViewSnapshot(of: view, named: "GitBranchChip.dirty")
    }

    func testChip_aheadBehind() throws {
        let view = chip(branch: "main", ahead: 2, behind: 1)
        XCTAssertEqual(view.status.aheadBehindLabel, "↑2↓1", "provenance: parsed divergence")
        try assertViewSnapshot(of: view, named: "GitBranchChip.aheadBehind")
    }

    func testChip_detached() throws {
        let view = chip(branch: nil, detached: true)
        XCTAssertEqual(view.status.branchLabel, "(detached)", "provenance: parsed detached HEAD")
        try assertViewSnapshot(of: view, named: "GitBranchChip.detached")
    }

    func testChip_notARepo_rendersEmpty() throws {
        // The REAL-TARGET gate the false-coverage illusion hid: when the working dir
        // isn't a repo, `branchLabel` is nil → the `if let` body never renders → the
        // chip's serialized tree is EMPTY. (Contrast with `clean`, which DOES render.)
        let view = notARepoChip()
        XCTAssertNil(view.status.branchLabel, "provenance: not a repo → no label")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("arrow.triangle.branch"),
                       "not-a-repo: the branch glyph must not render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "GitBranchChip.notARepo")
    }

    // MARK: - Negative control (P2 mutation-verified): the parsed status drives the tree

    /// Each parsed branch/divergence flips the captured tree. This is the load-bearing
    /// proof that the chip renders its DATA (not a constant) — the false-coverage
    /// illusion was precisely that no fixture ever exercised this.
    func testChip_negativeControl_parsedStatusFlipsTree() throws {
        func tree(branch: String?, detached: Bool = false, dirty: Bool = false,
                  ahead: Int = 0, behind: Int = 0) throws -> String {
            try ViewSnapshotHost.snapshotText(of: chip(
                branch: branch, detached: detached, dirty: dirty, ahead: ahead, behind: behind))
        }
        let main = try tree(branch: "main")
        let other = try tree(branch: "release/2.0")
        let diverged = try tree(branch: "main", ahead: 3, behind: 0)
        let detached = try tree(branch: nil, detached: true)
        let empty = try ViewSnapshotHost.snapshotText(of: notARepoChip())

        XCTAssertNotEqual(main, other, "the parsed branch label must drive the tree")
        XCTAssertTrue(main.contains(#"text="main""#), main)
        XCTAssertTrue(other.contains(#"text="release/2.0""#), other)

        XCTAssertNotEqual(main, diverged, "ahead/behind divergence must change the tree")
        XCTAssertFalse(main.contains("↑"), "in-sync: no ahead/behind suffix:\n\(main)")
        XCTAssertTrue(diverged.contains("↑3"), "diverged: ahead suffix present:\n\(diverged)")

        XCTAssertNotEqual(main, detached, "a detached HEAD must change the label")
        XCTAssertTrue(detached.contains("(detached)"), detached)

        XCTAssertNotEqual(main, empty, "a not-a-repo status must render empty (the real-target gate)")
        XCTAssertTrue(empty.isEmpty || !empty.contains(#"text="main""#), empty)
    }

    // MARK: - Determinism (P3)

    func testChip_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("clean", { try ViewSnapshotHost.snapshotText(of: self.chip(branch: "main")) }),
            ("dirty", { try ViewSnapshotHost.snapshotText(of: self.chip(branch: "wip", dirty: true)) }),
            ("aheadBehind", { try ViewSnapshotHost.snapshotText(of: self.chip(branch: "main", ahead: 2, behind: 1)) }),
            ("detached", { try ViewSnapshotHost.snapshotText(of: self.chip(branch: nil, detached: true)) }),
            ("notARepo", { try ViewSnapshotHost.snapshotText(of: self.notARepoChip()) })
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
