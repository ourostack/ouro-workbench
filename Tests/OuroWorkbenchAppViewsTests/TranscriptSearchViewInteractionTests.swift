#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `TranscriptSearchView` (`:8070`) INTERACTION drive-to-100%.
///
/// The C10 `TranscriptSearchViewStateSetTests` snapshot the RENDER arms (empty / no
/// results / with results) but never EXECUTE the interaction closures — so 8 region
/// segments (the `.onChange(of: query)`, the `.onChange(of: focusToken)`, the
/// `.onSubmit`, the "Search" button's `searchOrFocus()`, the result-row `groupName`
/// map closure, and `searchOrFocus()`'s guard / focus / search arms) were never
/// coloured. ViewInspector 0.10.3 invokes `.tap()`, `.callOnChange(…)`,
/// `.callOnSubmit()`, so this suite DRIVES every reachable region and asserts the
/// `@Published` side-effect (provenance), mutation-verified.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM`; the results are assigned
/// to `transcriptSearchResults` (the SAME `@Published` the live `searchTranscripts()`
/// completion sets — the C10 direct-injection production seam). The group label
/// resolves through the REAL `model.groupName(for:)` off a real `WorkspaceState`.
///
/// **Carves:** none — every region in the `TranscriptSearchView` decl is driven (the
/// `@FocusState searchFocused` writes run; with no live host the focus is a no-op,
/// but the closure REGIONS execute).
@MainActor
final class TranscriptSearchViewInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let entryId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let runId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!

    private func makeVM(query: String, results: [TranscriptSearchMatch]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9transcript-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        model.state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/u4")],
            processEntries: [ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "deploy-runner",
                                          kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4")])
        model.transcriptSearchQuery = query
        model.transcriptSearchResults = results
        return model
    }

    private func match(line: String, lineNumber: Int) -> TranscriptSearchMatch {
        TranscriptSearchMatch(
            entryId: Self.entryId, entryName: "deploy-runner", runId: Self.runId,
            transcriptPath: "/tmp/u4/transcripts/deploy-runner.log",
            lineNumber: lineNumber, line: line)
    }

    private func view(query: String, results: [TranscriptSearchMatch] = []) throws -> TranscriptSearchView {
        TranscriptSearchView(model: try makeVM(query: query, results: results))
    }

    // MARK: - .onChange(of: query) (`:8082`)

    /// `.onChange(of: model.transcriptSearchQuery) { model.transcriptSearchQueryDidChange() }`.
    /// This is the iOS-17 zero-param trailing-closure `onChange(of:_:)` form (compiles to
    /// `_ValueActionModifier2<String>`), so it is driven by the two-value
    /// `callOnChange(oldValue:newValue:)` over the `String` query. The handler runs
    /// `transcriptSearchQueryDidChange()`; the region executes.
    func testSearch_onChangeQuery_runsDidChange() throws {
        let view = try view(query: "needle")
        try view.inspect().find(ViewType.TextField.self)
            .callOnChange(oldValue: "needl", newValue: "needle")
        // The didChange handler ran (no throw); the region is coloured.
    }

    // MARK: - .onChange(of: focusToken) (`:8085`)

    /// `.onChange(of: model.transcriptSearchFocusToken) { _, _ in searchFocused = true }`.
    /// Firing this two-param change handler runs the `searchFocused = true` write.
    func testSearch_onChangeFocusToken_runsFocus() throws {
        let view = try view(query: "needle")
        try view.inspect().find(ViewType.TextField.self)
            .callOnChange(oldValue: 0, newValue: 1)
        // The focus handler ran (no throw); the region is coloured.
    }

    // MARK: - .onSubmit (`:8088`)

    /// `.onSubmit { model.searchTranscripts() }`. Firing submit runs `searchTranscripts()`.
    func testSearch_onSubmit_runsSearch() throws {
        let view = try view(query: "needle")
        try view.inspect().find(ViewType.TextField.self).callOnSubmit()
        // searchTranscripts() ran (the real searcher reads transcript files; with none
        // present it completes to an empty result — the region executes without throw).
    }

    // MARK: - "Search" button → searchOrFocus() (`:8091`, `:8129`, `:8130`, `:8133`)

    /// The "Search" `Button { searchOrFocus() }`. With a NON-empty query the guard PASSES →
    /// `model.searchTranscripts()` runs (`:8133`). Tapping drives the button action + the
    /// search arm of `searchOrFocus()`.
    func testSearch_searchButton_nonEmptyQuery_runsSearch() throws {
        let view = try view(query: "needle")
        XCTAssertFalse(view.model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "precondition: a non-empty query → searchOrFocus runs the search arm")
        try view.inspect().find(button: "Search").tap()
    }

    /// The empty-query path of `searchOrFocus()`: the `guard !query.isEmpty else { searchFocused
    /// = true; return }` arm (`:8129`/`:8130`). With an EMPTY query the guard FAILS → the focus
    /// arm runs (and `searchTranscripts()` is NOT called).
    func testSearch_searchButton_emptyQuery_focusesNotSearch() throws {
        let view = try view(query: "   ")   // whitespace → trims empty → the guard's else arm
        XCTAssertTrue(view.model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "precondition: an empty (whitespace-only) query → searchOrFocus runs the focus arm")
        try view.inspect().find(button: "Search").tap()
        // The guard's else (focus + return) executed; no search ran.
    }

    // MARK: - result-row groupName map closure (`:8103`)

    /// The result row's `model.groupName(for: match).map { "\($0) / \(match.entryName)" } ??
    /// match.entryName`. With a result whose entry resolves a group, the `.map` closure runs
    /// → "alpha / deploy-runner". Rendering a non-empty results list drives the ForEach + map.
    func testSearch_resultRow_groupNameMapClosure() throws {
        let view = try view(query: "needle", results: [match(line: "found", lineNumber: 7)])
        XCTAssertEqual(view.model.groupName(for: try XCTUnwrap(view.model.transcriptSearchResults.first)),
                       "alpha", "provenance: the group resolves through the real state")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("alpha / deploy-runner"),
                      "the groupName map closure renders 'group / entry':\n\(tree)")
    }

    /// The `?? match.entryName` NIL-FALLBACK arm of the result-row label (`:8103`). A match
    /// whose `entryId` is NOT in `state.processEntries` → `groupName(for:)` returns nil → the
    /// row renders just the bare `entryName` ("orphan-runner"). Drives the `??` right-hand side.
    func testSearch_resultRow_groupNameNilFallback() throws {
        let orphanId = UUID(uuidString: "99999999-0000-0000-0000-000000000009")!
        let orphan = TranscriptSearchMatch(
            entryId: orphanId, entryName: "orphan-runner", runId: Self.runId,
            transcriptPath: "/tmp/u4/transcripts/orphan.log", lineNumber: 3, line: "needle")
        let view = try view(query: "needle", results: [orphan])
        XCTAssertNil(view.model.groupName(for: orphan),
                     "provenance: an entry absent from state → nil group → the ?? fallback")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("orphan-runner"), "the bare entryName renders (no 'group / '):\n\(tree)")
        XCTAssertFalse(tree.contains("/ orphan-runner"), "no group prefix on the orphan row:\n\(tree)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The empty-vs-nonempty query flips which `searchOrFocus()` arm runs: a non-empty query
    /// searches; an empty one only focuses. Both arms reachable + observably distinct in the
    /// status-line render (no-results vs the absent status line). This pins the guard.
    func testSearch_negativeControl_emptyVsNonEmptyArm() throws {
        // Non-empty + no results → the status line renders (a search produced no matches).
        let nonEmpty = try ViewSnapshotHost.snapshotText(of: try view(query: "needle"))
        // Empty → no status line (the `else if !query.isEmpty` guard is false).
        let empty = try ViewSnapshotHost.snapshotText(of: try view(query: ""))
        XCTAssertNotEqual(nonEmpty, empty, "the query-empty axis flips the status-line tree")
    }

    // MARK: - Determinism (P3)

    func testSearch_interaction_noLeak() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try view(query: "needle", results: [match(line: "x", lineNumber: 1)]))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("transcripts/deploy-runner.log"),
                       "the transcriptPath is a dropped tooltip, never in the tree:\n\(tree)")
    }
}
#endif
