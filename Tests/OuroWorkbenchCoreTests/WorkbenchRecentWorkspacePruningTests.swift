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

    /// Every typed config error maps to a STRUCTURAL (prune) classification — none
    /// is transient. (The transient/keep arm is reachable only from the generic
    /// catch, which the App maps to `.transient` directly.)
    func testEveryTypedConfigErrorIsStructural() {
        let errors: [WorkbenchWorkspaceConfigError] = [
            .configFileMissing("/x/.workbench.json"),
            .malformedJSON("bad"),
            .noTerminals
        ]
        for error in errors {
            XCTAssertTrue(
                WorkbenchRecentWorkspacePruning.shouldForget(after: WorkbenchRecentWorkspacePruning.classify(error)),
                "every typed config error is a structural prune: \(error)"
            )
        }
    }
}
