import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchStoreTests: XCTestCase {
    func testStoreRoundTripsWorkspaceState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkbenchStore(stateURL: root.appendingPathComponent("workspace.json"))
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            projects: [project]
        )

        try store.save(state)
        let loaded = try store.load()

        XCTAssertEqual(loaded.boss.agentName, "slugger")
        XCTAssertEqual(loaded.projects, [project])
        try? FileManager.default.removeItem(at: root)
    }
}
