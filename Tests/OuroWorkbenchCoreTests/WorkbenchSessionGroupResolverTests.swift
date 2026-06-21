import XCTest
@testable import OuroWorkbenchCore

/// U29: the pure get-or-create resolution behind a single `workbench_create_session`
/// call. Given the requested group + the create-if-missing intent + a rootPath, the
/// resolver decides: use an existing group, create a new one (validated per U14),
/// defer to the app's selected group, or fail with a clear reason — without touching
/// the filesystem (the directory probe is injected).
final class WorkbenchSessionGroupResolverTests: XCTestCase {
    private func state(_ projects: [WorkbenchProject]) -> WorkspaceState {
        WorkspaceState(projects: projects, processEntries: [], processRuns: [])
    }

    private let alwaysDirectory: (String) -> WorkspaceRootValidation.PathKind = { _ in .directory }
    private let alwaysMissing: (String) -> WorkspaceRootValidation.PathKind = { _ in .missing }

    // MARK: - Existing-group match

    func testResolvesExistingGroupByUniqueName() {
        let project = WorkbenchProject(name: "Acme", rootPath: "/tmp/acme")
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "acme",
            createGroupIfMissing: true,
            rootPath: "/anything",
            workspaceState: state([project]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        XCTAssertEqual(resolution, .existing(project))
    }

    func testResolvesExistingGroupByID() {
        let project = WorkbenchProject(name: "Acme", rootPath: "/tmp/acme")
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: project.id.uuidString,
            createGroupIfMissing: false,
            rootPath: nil,
            workspaceState: state([project]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysMissing
        )
        XCTAssertEqual(resolution, .existing(project))
    }

    // MARK: - Deferred (no group named)

    func testNilGroupDefersToApp() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: nil,
            createGroupIfMissing: true,
            rootPath: "/tmp/x",
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        XCTAssertEqual(resolution, .deferred)
    }

    func testBlankGroupDefersToApp() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "   ",
            createGroupIfMissing: false,
            rootPath: nil,
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        XCTAssertEqual(resolution, .deferred)
    }

    // MARK: - Create-new (get-or-create)

    func testCreatesNewGroupWhenMissingAndFlagSet() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "NewProj",
            createGroupIfMissing: true,
            rootPath: "/tmp/newproj",
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        XCTAssertEqual(resolution, .create(name: "NewProj", rootPath: "/tmp/newproj"))
    }

    func testCreateExpandsTildeRootPath() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "NewProj",
            createGroupIfMissing: true,
            rootPath: "~/code/newproj",
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        XCTAssertEqual(resolution, .create(name: "NewProj", rootPath: "/Users/me/code/newproj"))
    }

    func testCreateRejectsMissingRootPath() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "NewProj",
            createGroupIfMissing: true,
            rootPath: "/tmp/missing",
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysMissing
        )
        XCTAssertEqual(
            resolution,
            .invalid("That folder doesn't exist: /tmp/missing")
        )
    }

    func testCreateRejectsEmptyRootPath() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "NewProj",
            createGroupIfMissing: true,
            rootPath: "  ",
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        // Empty rootPath can't create a group — surface the same root-required message.
        XCTAssertEqual(
            resolution,
            .invalid(WorkbenchSurfacePolicy.workspaceRootPathRequiredMessage)
        )
    }

    func testCreateRejectsNilRootPath() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "NewProj",
            createGroupIfMissing: true,
            rootPath: nil,
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        XCTAssertEqual(
            resolution,
            .invalid(WorkbenchSurfacePolicy.workspaceRootPathRequiredMessage)
        )
    }

    // MARK: - Strict must-already-exist (default)

    func testMissingGroupWithoutFlagMustExist() {
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "Ghost",
            createGroupIfMissing: false,
            rootPath: "/tmp/ghost",
            workspaceState: state([]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        XCTAssertEqual(
            resolution,
            .mustExist("No unique group matches Ghost. Create it first via workbench_request_action (createGroup), or pass createGroupIfMissing with a workingDirectory.")
        )
    }

    func testAmbiguousNameWithoutFlagMustExist() {
        let a = WorkbenchProject(name: "Dup", rootPath: "/tmp/a")
        let b = WorkbenchProject(name: "Dup", rootPath: "/tmp/b")
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: "dup",
            createGroupIfMissing: true,
            rootPath: "/tmp/c",
            workspaceState: state([a, b]),
            homeDirectory: "/Users/me",
            directoryProbe: alwaysDirectory
        )
        // Ambiguous name is never auto-created — there IS a matching name, just not unique.
        XCTAssertEqual(
            resolution,
            .mustExist("No unique group matches dup. Create it first via workbench_request_action (createGroup), or pass createGroupIfMissing with a workingDirectory.")
        )
    }

    // MARK: - Convenience: needsGroupCreate

    func testResolutionExposesCreateRequest() {
        let create = WorkbenchSessionGroupResolver.Resolution.create(name: "P", rootPath: "/tmp/p")
        XCTAssertEqual(create.groupToCreate?.name, "P")
        XCTAssertEqual(create.groupToCreate?.rootPath, "/tmp/p")
        XCTAssertNil(WorkbenchSessionGroupResolver.Resolution.deferred.groupToCreate)
    }
}
