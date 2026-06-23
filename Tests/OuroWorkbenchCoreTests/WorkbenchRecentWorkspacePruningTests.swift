import XCTest
@testable import OuroWorkbenchCore

/// FIX 3 — broken recents must not stay clickable. Opening a recent workspace
/// pruned the dead path from the recents list ONLY on `configFileMissing`; on
/// `malformedJSON`, `noTerminals`, and the generic catch the broken entry stayed
/// in the menu and re-errored on every click.
///
/// The prune-or-keep choice is a pure decision extracted to Core so it can be
/// exhaustively unit-tested: prune on STRUCTURAL failures (missing / malformed /
/// unreadable / empty), KEEP on a TRANSIENT / unknown failure (a recoverable
/// error a retry might clear — we must not silently drop a recent on a blip).
final class WorkbenchRecentWorkspacePruningTests: XCTestCase {

    // MARK: - Exhaustive classification → prune decision

    func testPrunesOnConfigMissing() {
        XCTAssertTrue(
            WorkbenchRecentWorkspacePruning.shouldForget(after: .configMissing),
            "a recent whose .workbench.json is gone is structurally dead — prune it"
        )
    }

    func testPrunesOnMalformed() {
        XCTAssertTrue(
            WorkbenchRecentWorkspacePruning.shouldForget(after: .malformed),
            "a recent whose .workbench.json is malformed/unreadable is structurally dead — prune it"
        )
    }

    func testPrunesOnEmpty() {
        XCTAssertTrue(
            WorkbenchRecentWorkspacePruning.shouldForget(after: .empty),
            "a recent whose .workbench.json declares no terminals is structurally useless — prune it"
        )
    }

    func testKeepsOnTransient() {
        XCTAssertFalse(
            WorkbenchRecentWorkspacePruning.shouldForget(after: .transient),
            "a transient/unknown failure may clear on retry — keep the recent (do NOT silently drop it)"
        )
    }

    // MARK: - Mapping from the typed config error (the structural failures)

    func testClassifiesConfigFileMissingAsStructuralPrune() {
        let failure = WorkbenchRecentWorkspacePruning.classify(.configFileMissing("/x/.workbench.json"))
        XCTAssertEqual(failure, .configMissing)
        XCTAssertTrue(WorkbenchRecentWorkspacePruning.shouldForget(after: failure))
    }

    func testClassifiesMalformedJSONAsStructuralPrune() {
        let failure = WorkbenchRecentWorkspacePruning.classify(.malformedJSON("bad"))
        XCTAssertEqual(failure, .malformed)
        XCTAssertTrue(WorkbenchRecentWorkspacePruning.shouldForget(after: failure))
    }

    func testClassifiesNoTerminalsAsStructuralPrune() {
        let failure = WorkbenchRecentWorkspacePruning.classify(.noTerminals)
        XCTAssertEqual(failure, .empty)
        XCTAssertTrue(WorkbenchRecentWorkspacePruning.shouldForget(after: failure))
    }

    // MARK: - The read-failure case is TRANSIENT (keep, do NOT prune)

    /// A `Data(contentsOf:)` failure (file momentarily locked, EACCES hiccup,
    /// network-volume blip, EIO) is RECOVERABLE — a retry may clear it. It must
    /// classify as `.transient` so the recent is KEPT, not dropped. Confusing it
    /// with genuine bad JSON would wrongly prune a good workspace from the menu.
    func testClassifiesFileUnreadableAsTransientKeep() {
        let failure = WorkbenchRecentWorkspacePruning.classify(.fileUnreadable("EIO"))
        XCTAssertEqual(failure, .transient)
        XCTAssertFalse(
            WorkbenchRecentWorkspacePruning.shouldForget(after: failure),
            "a recoverable file-read failure must KEEP the recent (a retry may clear it)"
        )
    }

    /// The STRUCTURAL typed config errors map to prune; the file-READ failure maps
    /// to keep. This pins the split: only a genuine structural failure (missing /
    /// bad JSON / empty) drops the recent — a read blip never does.
    func testStructuralErrorsPruneButReadFailureKeeps() {
        let structural: [WorkbenchWorkspaceConfigError] = [
            .configFileMissing("/x/.workbench.json"),
            .malformedJSON("bad"),
            .noTerminals
        ]
        for error in structural {
            XCTAssertTrue(
                WorkbenchRecentWorkspacePruning.shouldForget(after: WorkbenchRecentWorkspacePruning.classify(error)),
                "structural config error is a prune: \(error)"
            )
        }
        XCTAssertFalse(
            WorkbenchRecentWorkspacePruning.shouldForget(
                after: WorkbenchRecentWorkspacePruning.classify(.fileUnreadable("locked"))
            ),
            "the file-read failure is the lone typed error that KEEPS the recent"
        )
    }
}
