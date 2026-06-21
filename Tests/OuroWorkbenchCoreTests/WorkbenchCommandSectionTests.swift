import XCTest
@testable import OuroWorkbenchCore

/// U37(b): the ~34-item command palette was one ungrouped flat list that scrolled
/// far past the window. This pure classifier assigns every `WorkbenchCommandID` to
/// one labelled section (Session / Boss / Workspace / Agents / Diagnostics / App)
/// and groups a descriptor list into ordered sections, so the sheet can render
/// section headers without the App-target re-deriving the grouping.
final class WorkbenchCommandSectionTests: XCTestCase {

    // MARK: - Every command ID is classified

    func testEveryCommandIDHasASection() {
        for id in WorkbenchCommandID.allCases {
            // No fatal/`default`-bucket fallback: each ID is explicitly placed.
            XCTAssertNotNil(WorkbenchCommandSection.section(for: id), "unclassified: \(id)")
        }
    }

    func testSectionAssignmentsAreStable() {
        XCTAssertEqual(WorkbenchCommandSection.section(for: .newSession), .session)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .stopSelectedSession), .session)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .bossCheckIn), .boss)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .toggleBossWatch), .boss)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .installWorkbenchMCPForBoss), .boss)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .openWorkspaceConfig), .workspace)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .saveWorkspaceConfig), .workspace)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .manageAgents), .agents)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .selectAgent), .agents)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .installOuroAgent), .agents)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .collectSupportDiagnostics), .diagnostics)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .reportBug), .diagnostics)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .runRecoveryDrill), .diagnostics)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .openSettings), .app)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .checkReleaseUpdates), .app)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .resetToFirstRun), .app)
        XCTAssertEqual(WorkbenchCommandSection.section(for: .openOnboarding), .boss)
    }

    // MARK: - Section titles + order

    func testSectionTitlesAreLabelled() {
        XCTAssertEqual(WorkbenchCommandSection.session.title, "Session")
        XCTAssertEqual(WorkbenchCommandSection.boss.title, "Boss")
        XCTAssertEqual(WorkbenchCommandSection.workspace.title, "Workspace")
        XCTAssertEqual(WorkbenchCommandSection.agents.title, "Agents")
        XCTAssertEqual(WorkbenchCommandSection.diagnostics.title, "Diagnostics")
        XCTAssertEqual(WorkbenchCommandSection.app.title, "App")
    }

    func testDisplayOrderIsStable() {
        XCTAssertEqual(
            WorkbenchCommandSection.displayOrder,
            [.session, .boss, .workspace, .agents, .diagnostics, .app]
        )
    }

    // MARK: - Grouping

    private func cmd(_ id: WorkbenchCommandID, _ title: String = "x") -> WorkbenchCommandDescriptor {
        WorkbenchCommandDescriptor(id: id, title: title, detail: "", systemImage: "x")
    }

    func testGroupingPlacesEachCommandInItsSectionPreservingOrder() {
        let commands = [
            cmd(.openSettings, "Settings"),       // app
            cmd(.newSession, "New Terminal"),     // session
            cmd(.bossCheckIn, "Check In"),        // boss
            cmd(.stopSelectedSession, "Stop"),    // session
            cmd(.manageAgents, "Manage Agents")   // agents
        ]
        let groups = WorkbenchCommandSection.grouped(commands)

        // Sections appear in display order, and empty sections are dropped.
        XCTAssertEqual(groups.map(\.section), [.session, .boss, .agents, .app])
        // Within a section, original order is preserved.
        let session = groups.first { $0.section == .session }!
        XCTAssertEqual(session.commands.map(\.title), ["New Terminal", "Stop"])
    }

    func testGroupingDropsEmptySections() {
        let groups = WorkbenchCommandSection.grouped([cmd(.newSession)])
        XCTAssertEqual(groups.map(\.section), [.session])
    }

    func testGroupingFlattensBackToTheSameCommandsInDisplayOrder() {
        let commands = [
            cmd(.openAbout, "About"),       // app
            cmd(.selectAgent, "Agent"),     // agents
            cmd(.newSession, "Term")        // session
        ]
        let flat = WorkbenchCommandSection.grouped(commands).flatMap(\.commands)
        XCTAssertEqual(flat.map(\.title), ["Term", "Agent", "About"])
    }
}
