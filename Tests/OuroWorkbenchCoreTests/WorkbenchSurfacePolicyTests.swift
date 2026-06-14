import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchSurfacePolicyTests: XCTestCase {
    func testSidebarPrimaryLabelsUseWorkbenchStoryNouns() {
        XCTAssertEqual(WorkbenchSurfacePolicy.workspaceSectionTitle, "Workspaces")
        XCTAssertEqual(WorkbenchSurfacePolicy.newWorkspaceTitle, "New Workspace")
        XCTAssertEqual(WorkbenchSurfacePolicy.bossSectionTitle, "Boss")
    }

    func testSetupWorkspaceNameIsUnsortedSessionsNotThisMac() {
        XCTAssertEqual(WorkbenchSurfacePolicy.setupWorkspaceName, "Unsorted Sessions")
        XCTAssertNotEqual(WorkbenchSurfacePolicy.setupWorkspaceName, "This Mac")
    }

    func testBossStatusLabelsStayCompact() {
        XCTAssertEqual(WorkbenchSurfacePolicy.bossStatus(agentName: "", isReady: false), "Choose boss")
        XCTAssertEqual(WorkbenchSurfacePolicy.bossStatus(agentName: "slugger", isReady: true), "slugger ready")
        XCTAssertEqual(WorkbenchSurfacePolicy.bossStatus(agentName: "slugger", isReady: false), "slugger setup needed")
    }

    func testRecoverySectionIsHiddenWhenThereIsNothingActionable() {
        XCTAssertFalse(WorkbenchSurfacePolicy.shouldShowRecovery(recoverableCount: 0))
    }

    func testRecoverySectionIsShownWhenActionable() {
        XCTAssertTrue(WorkbenchSurfacePolicy.shouldShowRecovery(recoverableCount: 2))
    }

    func testParseSidebarSessionControlsFixtureAction() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--write-e2e-state",
            "sidebar-session-controls",
            "/tmp/workspace-state.json"
        ])

        XCTAssertEqual(
            diagnostics.action,
            .writeE2EState(.sidebarSessionControls, URL(fileURLWithPath: "/tmp/workspace-state.json"))
        )
    }

    func testParseSidebarSessionControlsFixtureRequiresPath() {
        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--write-e2e-state",
            "sidebar-session-controls"
        ]))
    }

    func testRunningSessionShowsOnlyStopAsPrimaryAction() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: true, isArchived: false, isRecoverable: false)

        XCTAssertEqual(policy.primaryActions, [.stop])
        XCTAssertEqual(policy.advancedActions, [.focus, .redraw, .restart, .controlC, .escape, .eof])
    }

    func testStoppedSessionShowsLaunchAsPrimaryAction() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: false, isArchived: false, isRecoverable: false)

        XCTAssertEqual(policy.primaryActions, [.launch])
        XCTAssertTrue(policy.advancedActions.isEmpty)
    }

    func testRecoverableSessionShowsRecoverAsPrimaryAction() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: false, isArchived: false, isRecoverable: true)

        XCTAssertEqual(policy.primaryActions, [.recover])
        XCTAssertTrue(policy.advancedActions.isEmpty)
    }

    func testArchivedSessionShowsNoPrimaryOrAdvancedActions() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: false, isArchived: true, isRecoverable: false)

        XCTAssertTrue(policy.primaryActions.isEmpty)
        XCTAssertTrue(policy.advancedActions.isEmpty)
    }
}
