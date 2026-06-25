import XCTest
@testable import OuroWorkbenchCore

final class WorkspaceRootValidationTests: XCTestCase {
    // MARK: - expandedPath: tilde + standardization, no FS access

    func testExpandsLeadingTilde() {
        let home = "/Users/fixture"
        XCTAssertEqual(
            WorkspaceRootValidation.expandedPath("~/code/foo", homeDirectory: home),
            "/Users/fixture/code/foo"
        )
    }

    func testExpandsBareTildeToHome() {
        XCTAssertEqual(
            WorkspaceRootValidation.expandedPath("~", homeDirectory: "/Users/fixture"),
            "/Users/fixture"
        )
    }

    func testLeavesAbsolutePathUntouchedExceptTrimming() {
        XCTAssertEqual(
            WorkspaceRootValidation.expandedPath("  /tmp/work  ", homeDirectory: "/Users/fixture"),
            "/tmp/work"
        )
    }

    func testDoesNotExpandTildeInTheMiddle() {
        // Only a leading "~" is a home reference; an interior "~" is a literal.
        XCTAssertEqual(
            WorkspaceRootValidation.expandedPath("/tmp/~backup", homeDirectory: "/Users/fixture"),
            "/tmp/~backup"
        )
    }

    func testDoesNotResolveAForeignUserHome() {
        // "~someone" is another user's home — we don't resolve it here; the existence
        // check downstream decides whether it's real.
        XCTAssertEqual(
            WorkspaceRootValidation.expandedPath("~someone/code", homeDirectory: "/Users/fixture"),
            "~someone/code"
        )
    }

    // MARK: - validate: usable-directory predicate with injected existence check

    func testValidPathThatIsAnExistingDirectory() {
        let result = WorkspaceRootValidation.validate("~/code/foo", homeDirectory: "/Users/fixture") { path in
            XCTAssertEqual(path, "/Users/fixture/code/foo")
            return .directory
        }
        XCTAssertTrue(result.isUsable)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.expandedPath, "/Users/fixture/code/foo")
    }

    func testEmptyPathIsRejectedWithRootRequiredMessage() {
        let result = WorkspaceRootValidation.validate("   ", homeDirectory: "/Users/fixture") { _ in
            XCTFail("existence check must not run for an empty path")
            return .missing
        }
        XCTAssertFalse(result.isUsable)
        XCTAssertEqual(result.errorMessage, WorkbenchSurfacePolicy.workspaceRootPathRequiredMessage)
    }

    func testNonExistentPathIsRejectedWithPathSpecificMessage() {
        let result = WorkspaceRootValidation.validate("~/code/typo", homeDirectory: "/Users/fixture") { _ in
            .missing
        }
        XCTAssertFalse(result.isUsable)
        // The error must name the offending (expanded) path so the operator can see the typo.
        XCTAssertEqual(result.errorMessage, "That folder doesn't exist: /Users/fixture/code/typo")
    }

    func testPathThatExistsButIsAFileIsRejectedAsNotADirectory() {
        let result = WorkspaceRootValidation.validate("/tmp/notes.txt", homeDirectory: "/Users/fixture") { _ in
            .file
        }
        XCTAssertFalse(result.isUsable)
        XCTAssertEqual(result.errorMessage, "That path isn't a folder: /tmp/notes.txt")
    }

    func testIsUsableDirectoryConvenienceMatchesValidate() {
        XCTAssertTrue(
            WorkspaceRootValidation.isUsableDirectory("~/x", homeDirectory: "/Users/fixture") { _ in .directory }
        )
        XCTAssertFalse(
            WorkspaceRootValidation.isUsableDirectory("~/x", homeDirectory: "/Users/fixture") { _ in .missing }
        )
        XCTAssertFalse(
            WorkspaceRootValidation.isUsableDirectory("", homeDirectory: "/Users/fixture") { _ in .directory }
        )
    }

    // MARK: - fileSystemProbe / validateOnDisk: the real-FS bridge (deterministic temp paths)

    func testFileSystemProbeClassifiesDirectoryFileAndMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wb-root-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)

        XCTAssertEqual(WorkspaceRootValidation.fileSystemProbe(dir.path), .directory)
        XCTAssertEqual(WorkspaceRootValidation.fileSystemProbe(file.path), .file)
        XCTAssertEqual(
            WorkspaceRootValidation.fileSystemProbe(dir.appendingPathComponent("nope").path),
            .missing
        )
    }

    func testValidateOnDiskAcceptsARealDirectoryAndRejectsAMissingOne() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wb-root-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        XCTAssertTrue(WorkspaceRootValidation.validateOnDisk(dir.path).isUsable)

        let missing = WorkspaceRootValidation.validateOnDisk(dir.appendingPathComponent("ghost").path)
        XCTAssertFalse(missing.isUsable)
        XCTAssertEqual(missing.errorMessage, "That folder doesn't exist: \(dir.appendingPathComponent("ghost").path)")
    }

    // MARK: - App wiring: createGroup / renameGroup route through the validation

    func testCreateAndRenameGroupRejectBadRootThroughValidateOnDisk() throws {
        // U14: the operator's sheets AND the boss's MCP `createGroup` action both land
        // in model.createGroup / renameGroup, so the existence check must live there —
        // not only in the sheet — to reject a bad root at create time for both.
        let source = try WorkbenchAppSource.appSource()

        for method in ["func createGroup(name: String, rootPath: String) -> Bool", "func renameGroup("] {
            let slice = try WorkbenchAppSource.sourceSlice(in: source, from: method, to: "\n    func ")
            XCTAssertTrue(
                slice.contains("WorkspaceRootValidation.validateOnDisk(trimmedRoot)"),
                "\(method) must validate the root path on disk"
            )
            XCTAssertTrue(
                slice.contains("guard rootValidation.isUsable else"),
                "\(method) must bail (and surface errorMessage) on an unusable root"
            )
            XCTAssertTrue(
                slice.contains("rootPath: rootValidation.expandedPath")
                    || slice.contains(".rootPath = rootValidation.expandedPath"),
                "\(method) must persist the tilde-expanded path"
            )
        }
    }
}
