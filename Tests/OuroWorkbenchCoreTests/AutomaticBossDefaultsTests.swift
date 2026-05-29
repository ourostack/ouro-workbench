import XCTest
@testable import OuroWorkbenchCore

final class AutomaticBossDefaultsTests: XCTestCase {
    func testNewSessionDefaultsToTrusted() {
        let entry = ProcessEntry(projectId: UUID(), name: "s", kind: .shell, executable: "zsh", workingDirectory: "/tmp")
        XCTAssertEqual(entry.trust, .trusted, "opt-out posture: new sessions are trusted by default")
    }

    func testNewWorkspaceDefaultsBossWatchOn() {
        XCTAssertTrue(WorkspaceState().bossWatchEnabled)
    }

    func testStateMissingBossWatchKeyDecodesOn() throws {
        let json = """
        {"schemaVersion":1,"boss":{"agentName":"slugger","scope":"machine"},"projects":[],"processEntries":[],"processRuns":[],"actionLog":[],"updatedAt":0}
        """
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        XCTAssertTrue(state.bossWatchEnabled, "absent key defaults on")
    }

    func testExplicitBossWatchFalseSurvivesDecode() throws {
        // A deliberate "off" must persist — the migration (not decode) is what flips it.
        let json = """
        {"schemaVersion":1,"boss":{"agentName":"slugger","scope":"machine"},"bossWatchEnabled":false,"projects":[],"processEntries":[],"processRuns":[],"actionLog":[],"updatedAt":0}
        """
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        XCTAssertFalse(state.bossWatchEnabled)
    }

    func testApplyAutomaticBossDefaultsTrustsUntrustedAndEnablesWatch() {
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let handsOff = ProcessEntry(projectId: project.id, name: "untrusted", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p", trust: .untrusted)
        let already = ProcessEntry(projectId: project.id, name: "trusted", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p", trust: .trusted)
        var state = WorkspaceState(bossWatchEnabled: false, projects: [project], processEntries: [handsOff, already])

        state.applyAutomaticBossDefaults()

        XCTAssertTrue(state.processEntries.allSatisfy { $0.trust == .trusted }, "untrusted flips, trusted stays")
        XCTAssertTrue(state.bossWatchEnabled)
    }
}
