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

    // MARK: - FIX 2: "already present" import skips are surfaced, not silently dropped

    /// `WorkbenchImportApplyResult` must carry an `alreadyPresentCount` so the
    /// import summary can distinguish terminals that were already in the workbench
    /// (a `(projectId, name)` match — re-import no-op) from genuine error-skips
    /// (e.g. "couldn't create"). Additive field with a default so existing
    /// constructions stay valid.
    func testImportApplyResultCarriesAlreadyPresentCount() throws {
        let source = try appSource()
        let slice = try sourceSlice(
            in: source,
            from: "struct WorkbenchImportApplyResult: Equatable {",
            to: "var hasImports: Bool"
        )
        XCTAssertTrue(
            slice.contains("var alreadyPresentCount: Int"),
            "WorkbenchImportApplyResult must carry an alreadyPresentCount distinct from skippedNames"
        )
    }

    /// The import-apply loop must count a `(projectId, name)` match into the
    /// already-present tally — NOT into `skippedNames` (which is reserved for
    /// genuine error-skips). And it must STILL skip the matched terminal
    /// (`continue`) — FIX 2 only surfaces the count; it does NOT start updating
    /// matched terminals (that's a deferred product decision).
    func testImportApplyCountsAlreadyPresentSeparatelyFromErrorSkips() throws {
        let source = try appSource()
        let body = try sourceSlice(
            in: source,
            from: "func openWorkspaceConfig(\n        config: WorkbenchWorkspaceConfig,",
            to: "return result"
        )
        // The already-present branch increments the dedicated tally, not skippedNames.
        let alreadyPresentBranch = try sourceSlice(
            in: body,
            from: "if alreadyPresent {",
            to: "}"
        )
        XCTAssertTrue(
            alreadyPresentBranch.contains("alreadyPresentCount"),
            "an already-present (projectId,name) match must increment alreadyPresentCount"
        )
        XCTAssertFalse(
            alreadyPresentBranch.contains("skippedNames.append"),
            "an already-present match must NOT be lumped into skippedNames (those are error-skips)"
        )
        // INVERSE-BUG GUARD: the matched terminal is still skipped (continue) — FIX 2
        // must NOT begin updating matched terminals (deferred decision).
        XCTAssertTrue(
            alreadyPresentBranch.contains("continue"),
            "a matched terminal must still be skipped (continue) — FIX 2 surfaces the count, it does not update matched terminals"
        )
        // The error-skip path (the catch) still appends to skippedNames — genuinely
        // new terminals that couldn't be created stay distinct from already-present.
        XCTAssertTrue(
            body.contains("} catch {\n                skippedNames.append(terminal.name)"),
            "a couldn't-create error must still append to skippedNames (error-skip, distinct from already-present)"
        )
        // The constructed result threads the already-present tally through.
        XCTAssertTrue(
            body.contains("alreadyPresentCount: alreadyPresentCount"),
            "the import result must thread the already-present tally into alreadyPresentCount:"
        )
    }

    /// The summary `detail` must surface the already-present count as human text
    /// (e.g. "N already present") so a re-import no-op is VISIBLE instead of a
    /// silent drop.
    func testImportSummaryDetailSurfacesAlreadyPresent() throws {
        let source = try appSource()
        let detail = try sourceSlice(
            in: source,
            from: "var detail: String? {",
            to: "@MainActor"
        )
        XCTAssertTrue(
            detail.contains("alreadyPresentCount"),
            "the import detail must reference alreadyPresentCount"
        )
        XCTAssertTrue(
            detail.contains("already present"),
            "the import detail must surface the already-present count as human text (e.g. \"N already present\")"
        )
    }

    // MARK: - FIX 3: broken recents are pruned on all structural load errors

    /// `openWorkspaceConfig(at:)` must forget the recent on ALL structural load
    /// failures — `configFileMissing` (already), PLUS `malformedJSON` and
    /// `noTerminals` — routed through the pure Core decision. Before the fix, only
    /// `configFileMissing` pruned; a malformed/empty recent stayed clickable and
    /// re-errored on every click. The typed errors are handled in one
    /// `catch let configError as WorkbenchWorkspaceConfigError` whose switch covers
    /// every structural case, then a single decision-gated prune.
    func testOpenRecentPrunesOnAllStructuralErrors() throws {
        let source = try appSource()
        // The typed structural catch — from the typed catch to the prune+return —
        // routes EVERY structural case through the Core decision and forgets.
        let structuralCatch = try sourceSlice(
            in: source,
            from: "catch let configError as WorkbenchWorkspaceConfigError {",
            to: "} catch {"
        )
        // Every structural error case is handled in the switch (so each one reaches
        // the shared decision-gated prune — not just configFileMissing).
        for arm in ["case .configFileMissing", "case .malformedJSON", "case .noTerminals"] {
            XCTAssertTrue(
                structuralCatch.contains(arm),
                "the structural catch must handle \(arm) so it reaches the prune decision"
            )
        }
        // The prune is gated on the pure decision, classified from the typed error,
        // and forgets the recent so it stops re-erroring.
        XCTAssertTrue(
            structuralCatch.contains("WorkbenchRecentWorkspacePruning.shouldForget(")
                && structuralCatch.contains("WorkbenchRecentWorkspacePruning.classify(configError)"),
            "the structural prune must be gated on shouldForget(after: classify(configError))"
        )
        XCTAssertTrue(
            structuralCatch.contains("forgetRecentWorkspace(path: directoryPath)"),
            "a structural failure must prune the dead recent so it stops re-erroring"
        )
    }

    /// FIX: a FILE-READ failure (`.fileUnreadable` — file momentarily locked /
    /// EACCES / network-volume blip / EIO) is recoverable, so it must be handled in
    /// the typed catch (an honest error message) but classify as `.transient` →
    /// KEEP the recent. The typed switch must include a `.fileUnreadable` arm so it
    /// compiles exhaustively AND surfaces the read failure honestly; the single
    /// decision-gated prune (`shouldForget(after: classify(configError))`) then maps
    /// the read failure to keep, so the recent survives a blip.
    func testOpenRecentHandlesReadFailureArmHonestly() throws {
        let source = try appSource()
        let structuralCatch = try sourceSlice(
            in: source,
            from: "catch let configError as WorkbenchWorkspaceConfigError {",
            to: "} catch {"
        )
        XCTAssertTrue(
            structuralCatch.contains("case .fileUnreadable"),
            "the typed catch must handle .fileUnreadable so a read blip surfaces an honest message"
        )
        // The read failure must NOT carry its own forget — pruning stays gated on
        // the single shared decision, which classifies .fileUnreadable as keep.
        XCTAssertTrue(
            structuralCatch.contains("WorkbenchRecentWorkspacePruning.classify(configError)"),
            "the read failure must route through the shared classify(...) decision, not a bespoke prune"
        )
    }

    /// INVERSE-BUG GUARD: the generic `catch` (a transient / unknown error a retry
    /// might clear) must NOT prune the recent — only structural failures do.
    func testOpenRecentDoesNotPruneOnTransientError() throws {
        let source = try appSource()
        // The generic catch is the LAST arm: from the bare `} catch {` (no typed
        // pattern) following the structural catch, to the apply call after the do.
        let genericCatch = try sourceSlice(
            in: source,
            from: "} catch {\n            errorMessage = \"Couldn't open workspace:",
            to: "let result = openWorkspaceConfig(config: config"
        )
        XCTAssertFalse(
            genericCatch.contains("forgetRecentWorkspace"),
            "the generic (transient/unknown) catch must NOT prune the recent — only structural failures do"
        )
    }

    /// The structural decision must NOT silently delegate pruning to the loader or
    /// invent a new transient prune — the App must classify the typed error and the
    /// Core decision must gate the forget. (Pins that pruning is decision-gated.)
    func testStructuralPruneIsDecisionGated() throws {
        let source = try appSource()
        let body = try sourceSlice(
            in: source,
            from: "func openWorkspaceConfig(at directoryPath: String) -> WorkbenchImportApplyResult? {",
            to: "func exportWorkspaceConfig"
        )
        XCTAssertTrue(
            body.contains("WorkbenchRecentWorkspacePruning.shouldForget("),
            "the structural prune must be gated on WorkbenchRecentWorkspacePruning.shouldForget(...)"
        )
        // Exactly ONE forget call survives in the open-recent function (the
        // decision-gated structural prune) — the generic catch adds none.
        XCTAssertEqual(
            occurrences(of: "forgetRecentWorkspace(path: directoryPath)", in: body),
            1,
            "open-recent must prune in exactly one place — the decision-gated structural arm"
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
