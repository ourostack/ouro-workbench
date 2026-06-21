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

    // MARK: - (b) terminals section names the relationship

    func testTerminalsSectionTitleExpressesTheRelationship() {
        XCTAssertEqual(
            WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: "Home"),
            "Terminals in Home"
        )
        XCTAssertEqual(
            WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: "my-project"),
            "Terminals in my-project"
        )
    }

    func testTerminalsSectionTitleFallsBackWhenNoWorkspaceIsSelected() {
        // With nothing selected there is no workspace to name a relationship to, so
        // the bare "Terminals" label is the sensible fallback (no "Terminals in ").
        XCTAssertEqual(
            WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: nil),
            "Terminals"
        )
        XCTAssertEqual(
            WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: "   "),
            "Terminals"
        )
    }

    // MARK: - App wiring: the sidebar terminals section names the relationship

    func testSidebarTerminalsSectionUsesTheRelationshipLabelNotTheBareName() throws {
        // U32: the terminals section header must route through the relationship-naming
        // seam so the sidebar no longer renders the selected workspace's name twice
        // (once in the Workspaces list, once as the bare section header).
        let source = try appSource()
        XCTAssertTrue(
            source.contains("Section(WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: model.selectedProject?.name))"),
            "the terminals section must use terminalsSectionTitle, not the bare project name"
        )
        XCTAssertFalse(
            source.contains("Section(model.selectedProject?.name ?? \"Terminals\")"),
            "the bare-name section header must be gone"
        )
    }

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
}
