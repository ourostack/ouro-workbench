import XCTest
@testable import OuroWorkbenchCore

/// U32: the bootstrapped default workspace gets a neutral, welcoming name (not the
/// state-claiming "Unsorted Sessions"), and the terminals section names its
/// RELATIONSHIP to the selected workspace instead of repeating the workspace name.
final class WorkspaceHomeNamingTests: XCTestCase {
    // MARK: - (a) neutral default name

    func testDefaultWorkspaceNameIsNeutralAndDoesNotImplyDisorder() {
        let name = WorkbenchSurfacePolicy.setupWorkspaceName
        XCTAssertEqual(name, "Home")
        // No "unsorted / unfiled / pending cleanup" language on a clean install.
        let lowered = name.lowercased()
        XCTAssertFalse(lowered.contains("unsorted"))
        XCTAssertFalse(lowered.contains("unfiled"))
        XCTAssertFalse(lowered.contains("session"))
    }

    func testDefaultWorkspaceNameIsNotThisMac() {
        XCTAssertNotEqual(WorkbenchSurfacePolicy.setupWorkspaceName, "This Mac")
    }

    // Slice ②b removed `terminalsSectionTitle(workspaceName:)` and the "Terminals in
    // <name>" sidebar section entirely (tabs moved to the cmux tab-strip), so its
    // value-tests are gone with it. The default-workspace-name tests above stay (the
    // backing "Home" project is unchanged under DB1/DB6).

    // MARK: - App wiring: Slice ②b removed the "Terminals in <name>" sidebar section

    func testSidebarNoLongerRendersATerminalsInRelationshipSection() throws {
        // Slice ②b kills the "Terminals in <name>" framing: the sidebar no longer
        // renders a terminals section scoped to the selected project; the tabs move to
        // the cmux tab-strip and the sidebar renders named workspaces instead. (The
        // detailed new-wiring assertions live in WorkspaceSidebarWiringTests.)
        let source = try WorkbenchAppSource.appSource()
        XCTAssertFalse(
            source.contains("Section(WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: model.selectedProject?.name))"),
            "the 'Terminals in <name>' sidebar section must be removed by ②b"
        )
        XCTAssertFalse(
            source.contains("Section(model.selectedProject?.name ?? \"Terminals\")"),
            "the bare-name section header must be gone"
        )
        // And the sidebar now renders the persisted workspace structure through the seam.
        XCTAssertTrue(
            source.contains("WorkspaceSidebarPresentation.resolve("),
            "the sidebar must render state.workspaces via the WorkspaceSidebarPresentation seam"
        )
    }
}
