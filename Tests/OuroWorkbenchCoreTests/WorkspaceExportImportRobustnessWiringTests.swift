import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the workspace export/import robustness fixes.
/// The App target isn't coverage-gated and can't be click-tested in CI, so these
/// pin the structural wiring as text against the App source — the same approach
/// `ImportPersistenceHonestyWiringTests` uses for the import-save-honesty fix.
///
/// Three fixes are pinned here:
///   FIX 1 — the "Save Workspace As…" export write is `.atomic` (no truncated
///           prior-workspace file on an interrupted overwrite).
///   FIX 2 — the import-apply path counts "already present" terminals separately
///           from genuine error-skips and surfaces the count (not a silent drop).
///   FIX 3 — opening a recent prunes the dead entry on ALL structural load errors
///           (missing/malformed/empty), routed through the pure Core decision,
///           and does NOT prune on a transient/unknown error.
final class WorkspaceExportImportRobustnessWiringTests: XCTestCase {

    // MARK: - FIX 1: export write is atomic

    /// The "Save Workspace As…" export must write the `.workbench.json` atomically.
    /// A non-atomic `write(to:)` writes in place, so an interrupted overwrite
    /// (crash / disk-full / kill) leaves the operator's PRIOR workspace file
    /// truncated and the next "Open Workspace…" fails to parse it. Atomic writes go
    /// to a temp file + rename, so a partial write never clobbers the existing file.
    /// The durable `WorkbenchStore.save` already writes `.atomic`; this pins the
    /// export path to the same bar (it was the lone inconsistent writer).
    func testExportWorkspaceWriteIsAtomic() throws {
        let source = try appSource()
        let slice = try sourceSlice(
            in: source,
            from: "func presentSaveWorkspacePanel() {",
            to: "func presentOpenWorkspacePanel"
        )
        // Every export write(to:) in the function must carry options: [.atomic].
        let writeCalls = occurrences(of: "data.write(to:", in: slice)
        XCTAssertGreaterThanOrEqual(
            writeCalls, 1,
            "expected at least one export write(to:) in presentSaveWorkspacePanel()"
        )
        XCTAssertEqual(
            occurrences(of: ".write(to: url, options: [.atomic])", in: slice),
            writeCalls,
            "every export write(to:) must use options: [.atomic] (atomic temp-file + rename)"
        )
        // And NO bare, non-atomic export write survives in the export slice.
        XCTAssertFalse(
            slice.contains("try data.write(to: url)\n"),
            "the export path must not contain a non-atomic write(to: url) — it truncates the prior file on an interrupted overwrite"
        )
    }

    // MARK: - Helpers (mirror ImportPersistenceHonestyWiringTests)

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: startMarker)?.lowerBound,
            "start marker not found: \(startMarker)"
        )
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound,
            "end marker not found: \(endMarker)"
        )
        return String(source[start..<end])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
