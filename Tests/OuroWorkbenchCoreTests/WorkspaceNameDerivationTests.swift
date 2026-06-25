import XCTest
@testable import OuroWorkbenchCore

final class WorkspaceNameDerivationTests: XCTestCase {
    func testDerivesLastPathComponentForANormalPath() {
        XCTAssertEqual(WorkspaceNameDerivation.nameFromPath("/Users/x/code/foo"), "foo")
    }

    func testIgnoresATrailingSlash() {
        XCTAssertEqual(WorkspaceNameDerivation.nameFromPath("/Users/x/code/foo/"), "foo")
    }

    func testCollapsesRedundantTrailingSlashes() {
        XCTAssertEqual(WorkspaceNameDerivation.nameFromPath("/Users/x/code/foo///"), "foo")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(WorkspaceNameDerivation.nameFromPath("  /Users/x/code/foo  "), "foo")
    }

    func testRootSlashHasNoSensibleBasenameSoReturnsNil() {
        XCTAssertNil(WorkspaceNameDerivation.nameFromPath("/"))
        XCTAssertNil(WorkspaceNameDerivation.nameFromPath("///"))
    }

    func testEmptyOrWhitespaceReturnsNil() {
        XCTAssertNil(WorkspaceNameDerivation.nameFromPath(""))
        XCTAssertNil(WorkspaceNameDerivation.nameFromPath("   "))
    }

    func testSingleComponentRelativePathYieldsThatComponent() {
        XCTAssertEqual(WorkspaceNameDerivation.nameFromPath("foo"), "foo")
    }

    func testHomeFolderBasename() {
        XCTAssertEqual(WorkspaceNameDerivation.nameFromPath("/Users/ari"), "ari")
    }

    // MARK: - autofill policy: only fill when the name is still empty / unedited

    func testAutofillFillsAnEmptyNameFromThePath() {
        XCTAssertEqual(
            WorkspaceNameDerivation.autofilledName(currentName: "", chosenPath: "/Users/x/code/foo"),
            "foo"
        )
    }

    func testAutofillFillsAWhitespaceOnlyName() {
        XCTAssertEqual(
            WorkspaceNameDerivation.autofilledName(currentName: "   ", chosenPath: "/Users/x/code/foo"),
            "foo"
        )
    }

    func testAutofillDoesNotClobberANameTheOperatorTyped() {
        XCTAssertNil(
            WorkspaceNameDerivation.autofilledName(currentName: "my-project", chosenPath: "/Users/x/code/foo")
        )
    }

    func testAutofillReturnsNilWhenThePathHasNoBasename() {
        XCTAssertNil(WorkspaceNameDerivation.autofilledName(currentName: "", chosenPath: "/"))
    }

    // MARK: - App wiring: the New Workspace sheet autofills Name from the chosen path

    func testNewWorkspaceSheetAutofillsNameFromTheChosenRootPath() throws {
        // U34: the autofill must hang off the Root Path change in NewTerminalGroupSheet
        // (covering both the Choose panel and a typed path), routed through the
        // empty-guarded autofilledName so a typed name is never clobbered.
        let source = try WorkbenchAppSource.appSource()
        let sheet = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct NewTerminalGroupSheet: View",
            to: "struct EditTerminalGroupSheet: View"
        )

        XCTAssertTrue(sheet.contains(".onChange(of: rootPath)"), "autofill must trigger on the root path change")
        XCTAssertTrue(
            sheet.contains("WorkspaceNameDerivation.autofilledName(currentName: name, chosenPath: rootPath)"),
            "autofill must route through the empty-guarded derivation"
        )
    }
}
