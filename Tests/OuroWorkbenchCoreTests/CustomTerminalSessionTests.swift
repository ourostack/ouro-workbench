import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class CustomTerminalSessionTests: XCTestCase {
    func testCustomSessionCreatesShellWrappedTerminalEntry() throws {
        let projectId = UUID()
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: "  Local Agent  ",
                command: "  aider --yes  ",
                workingDirectory: "  /repo  ",
                trust: .trusted,
                autoResume: true
            )
        )

        XCTAssertEqual(entry.projectId, projectId)
        XCTAssertEqual(entry.name, "Local Agent")
        XCTAssertEqual(entry.kind, .terminalAgent)
        XCTAssertNil(entry.agentKind)
        XCTAssertEqual(entry.executable, "/bin/zsh")
        XCTAssertEqual(entry.arguments, ["-lc", "aider --yes"])
        XCTAssertEqual(entry.workingDirectory, "/repo")
        XCTAssertEqual(entry.trust, .trusted)
        XCTAssertTrue(entry.autoResume)
        XCTAssertEqual(entry.lastSummary, "Custom terminal session: aider --yes")
    }

    func testCustomSessionRequiresNameCommandAndWorkingDirectory() {
        let projectId = UUID()
        let factory = CustomTerminalSessionFactory()

        XCTAssertThrowsError(try factory.makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: " ",
                command: "aider",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .emptyName)
        }

        XCTAssertThrowsError(try factory.makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: " ",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .emptyCommand)
        }

        XCTAssertThrowsError(try factory.makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: "aider",
                workingDirectory: " ",
                trust: .trusted,
                autoResume: true
            )
        )) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .emptyWorkingDirectory)
        }
    }
}
