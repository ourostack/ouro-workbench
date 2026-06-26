#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C10-4 — the transcript-search panel (`TranscriptSearchView` `:8007`). A search field bound to
/// `model.transcriptSearchQuery` plus a results list driven by `model.transcriptSearchResults`.
///
/// **Provenance (P2) + hermetic seam.** The real `TranscriptSearcher` OPENS + READS transcript
/// FILES off `ProcessRun.transcriptPath` (real disk I/O — non-hermetic + a path-leak risk). The
/// production app populates `@Published var transcriptSearchResults` by assigning the searcher's
/// output (the async `searchTranscripts()` completion). So the LEGITIMATE deterministic seam is to
/// assign `transcriptSearchResults` directly with FIXED `TranscriptSearchMatch` value types (the
/// same direct-`@Published` injection `bossWatchChangeSummaries` uses) — NOT to write throwaway
/// transcript files. Each match is built via its REAL public initializer; the group label is
/// resolved through the REAL `model.groupName(for:)` (a real `WorkspaceState` project + entry).
///
/// **Path-leak (P3).** `TranscriptSearchMatch.transcriptPath` is rendered ONLY into the row's
/// `.help(match.transcriptPath)` TOOLTIP, which the host DROPS (`isHelpTooltip` / AN-004) — it
/// never reaches the serialized tree. The VISIBLE row nodes are `entryName`/group, `line N`, and
/// the matched `line` (all fixture-controlled). A fixed `/tmp/u4/...` transcriptPath + a
/// `!tree.contains("/Users/")` assertion defend it belt-and-suspenders.
///
/// **No clock surface.** The view renders no timestamp → no cross-TZ proof needed.
///
/// **Enumerated state-set (the view's data-driven branches):**
///   - `emptyQuery`   — no query, no results → the "Enter a query…" status line is absent (the
///                      `else if !query.isEmpty` guard is false) → just the search field/labels.
///   - `noResults`    — a non-empty query with no results → the `transcriptSearchStatusLine`
///                      ("Press Search…" / "No transcript matches…") renders.
///   - `withResults`  — a non-empty `transcriptSearchResults` → the `ForEach(prefix(6))` rows.
@MainActor
final class TranscriptSearchViewStateSetTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let entryId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let runId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!

    /// A real `WorkspaceState` so `model.groupName(for: match)` resolves the "alpha" group label
    /// from the match's `entryId` → entry → project.
    private func makeVM(query: String, results: [TranscriptSearchMatch]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c10transcript-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        model.state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/u4")],
            processEntries: [ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "deploy-runner",
                                          kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4")]
        )
        // The real production seam: assign the (would-be searcher) results to the @Published.
        model.transcriptSearchQuery = query
        model.transcriptSearchResults = results
        return model
    }

    private func match(line: String, lineNumber: Int) -> TranscriptSearchMatch {
        TranscriptSearchMatch(
            entryId: Self.entryId, entryName: "deploy-runner", runId: Self.runId,
            // Rendered ONLY into the dropped .help() tooltip — fixed/relative defends it anyway.
            transcriptPath: "/tmp/u4/transcripts/deploy-runner.log",
            lineNumber: lineNumber, line: line
        )
    }

    private func view(query: String, results: [TranscriptSearchMatch]) throws -> TranscriptSearchView {
        TranscriptSearchView(model: try makeVM(query: query, results: results))
    }

    // MARK: - Enumerated state-set

    /// EMPTY QUERY — no query, no results → no results rows AND no status line (the
    /// `else if !query.isEmpty` guard is false): just the search field + labels.
    func testSearch_emptyQuery() throws {
        let view = try view(query: "", results: [])
        XCTAssertTrue(view.model.transcriptSearchResults.isEmpty, "provenance: no results")
        try assertViewSnapshot(of: view, named: "TranscriptSearchView.emptyQuery")
    }

    /// NO RESULTS — a non-empty query with no matches → the `transcriptSearchStatusLine` renders
    /// (the empty-results-with-query branch).
    func testSearch_noResults() throws {
        let view = try view(query: "needle", results: [])
        XCTAssertTrue(view.model.transcriptSearchResults.isEmpty)
        XCTAssertFalse(view.model.transcriptSearchStatusLine.isEmpty, "provenance: a status line shows")
        try assertViewSnapshot(of: view, named: "TranscriptSearchView.noResults")
    }

    /// WITH RESULTS — a non-empty `transcriptSearchResults` → the `ForEach(prefix(6))` rows with
    /// the group/entry label, the "line N" number, and the matched line.
    func testSearch_withResults() throws {
        let results = [match(line: "found the needle here", lineNumber: 42)]
        let view = try view(query: "needle", results: results)
        XCTAssertEqual(view.model.transcriptSearchResults.count, 1)
        XCTAssertEqual(view.model.groupName(for: results[0]), "alpha",
                       "provenance: the group label resolves through the real state")
        try assertViewSnapshot(of: view, named: "TranscriptSearchView.withResults")
    }

    // MARK: - Path-leak defense (P3 — transcriptPath is a dropped tooltip)

    func testSearch_pathLeakDefense_transcriptPathDroppedFromTree() throws {
        let results = [match(line: "needle in line", lineNumber: 7)]
        let tree = try ViewSnapshotHost.snapshotText(of: try view(query: "needle", results: results))
        XCTAssertFalse(tree.contains("transcripts/deploy-runner.log"),
                       "the transcriptPath is a dropped .help() tooltip, never in the tree:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
        XCTAssertTrue(tree.contains("line 7"), "the visible line-number node renders:\n\(tree)")
    }

    // MARK: - Determinism (P3)

    func testSearch_determinism_byteIdenticalTwice() throws {
        let results = [match(line: "needle", lineNumber: 1)]
        let a = try ViewSnapshotHost.snapshotText(of: try view(query: "needle", results: results))
        let b = try ViewSnapshotHost.snapshotText(of: try view(query: "needle", results: results))
        XCTAssertEqual(a, b, "the transcript-search panel must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// A non-empty results list flips the tree: the result rows (group/line/match) appear and the
    /// no-results status line vanishes — a real `transcriptSearchResults`-driven branch.
    func testSearch_negativeControl_resultsFlipTree() throws {
        let noResults = try ViewSnapshotHost.snapshotText(of: try view(query: "needle", results: []))
        let withResults = try ViewSnapshotHost.snapshotText(of: try view(
            query: "needle", results: [match(line: "found the needle", lineNumber: 42)]))

        XCTAssertNotEqual(noResults, withResults, "a non-empty results list must flip the tree")
        XCTAssertTrue(withResults.contains("line 42"), "with-results: the line-number renders:\n\(withResults)")
        XCTAssertTrue(withResults.contains("found the needle"), "with-results: the matched line renders")
        XCTAssertFalse(withResults.contains("No transcript matches"),
                       "with-results: the no-match status line is gone")
        XCTAssertTrue(noResults.contains("No transcript matches") || noResults.contains("Press Search"),
                      "no-results: a status line shows:\n\(noResults)")
    }
}
#endif
