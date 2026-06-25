import XCTest
@testable import OuroWorkbenchCore

/// Slice ②d — D2d-1: the pure decision for what an inline-rename COMMIT does.
/// The model layer (②a DA4) still honors an empty override if set programmatically
/// (that's `WorkspaceStructureTests`' concern); THIS helper only constrains what the
/// EDITOR can produce: empty/whitespace = no-op (reject), non-empty = trimmed commit,
/// trimmed==current = no-op (no spurious override write). Tab rename uses the same rule.
final class WorkspaceRenameCommitTests: XCTestCase {

    func testEmptyInputIsNoOp() {
        XCTAssertEqual(WorkspaceRenameCommit.resolve(input: "", current: "Current"), .noop)
    }

    func testWhitespaceOnlyInputIsNoOp() {
        XCTAssertEqual(WorkspaceRenameCommit.resolve(input: "   ", current: "Current"), .noop)
        XCTAssertEqual(WorkspaceRenameCommit.resolve(input: "\t\n ", current: "Current"), .noop)
    }

    func testNonEmptyInputWithSurroundingWhitespaceCommitsTrimmed() {
        XCTAssertEqual(
            WorkspaceRenameCommit.resolve(input: "  Renamed  ", current: "Current"),
            .commit("Renamed")
        )
    }

    func testNonEmptyInputWithoutWhitespaceCommitsAsIs() {
        XCTAssertEqual(
            WorkspaceRenameCommit.resolve(input: "Renamed", current: "Current"),
            .commit("Renamed")
        )
    }

    func testTrimmedInputEqualToCurrentIsNoOp() {
        // No spurious override write / no needless save when the name didn't change.
        XCTAssertEqual(WorkspaceRenameCommit.resolve(input: "Current", current: "Current"), .noop)
    }

    func testTrimmedInputEqualToCurrentAfterTrimmingIsNoOp() {
        // Surrounding whitespace that trims down to the current value is still a no-op.
        XCTAssertEqual(WorkspaceRenameCommit.resolve(input: "  Current  ", current: "Current"), .noop)
    }

    func testTrimmedInputDifferentFromCurrentCommits() {
        XCTAssertEqual(
            WorkspaceRenameCommit.resolve(input: "New Name", current: "Old Name"),
            .commit("New Name")
        )
    }

    func testCommitIsCaseSensitiveAgainstCurrent() {
        // A pure case change IS a real change (the operator deliberately re-cased it).
        XCTAssertEqual(
            WorkspaceRenameCommit.resolve(input: "current", current: "Current"),
            .commit("current")
        )
    }
}
