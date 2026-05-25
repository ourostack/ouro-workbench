import XCTest
@testable import OuroWorkbenchCore

final class OuroAgentInstallCommandTests: XCTestCase {
    func testHatchPlanLaunchesConversationalSerpentGuideFlow() {
        let plan = OuroAgentInstallCommandBuilder().hatch()

        XCTAssertEqual(plan.sessionName, "Hatch Ouro Agent")
        XCTAssertEqual(plan.commandLine, "ouro hatch")
        XCTAssertEqual(plan.notes, "Conversational Ouro hatch flow launched from Workbench.")
    }

    func testClonePlanAllowsOptionalAgentName() throws {
        let plan = try OuroAgentInstallCommandBuilder().clone(
            remote: "https://github.com/ourostack/sprout.ouro.git",
            agentName: "sprout"
        )

        XCTAssertEqual(plan.sessionName, "Clone sprout")
        XCTAssertEqual(plan.commandLine, "ouro clone https://github.com/ourostack/sprout.ouro.git --agent sprout")
    }

    func testClonePlanQuotesRemoteWithShellCharacters() throws {
        let plan = try OuroAgentInstallCommandBuilder().clone(
            remote: "git@github.com:ourostack/private agent.ouro.git",
            agentName: nil
        )

        XCTAssertEqual(plan.sessionName, "Clone Ouro Agent")
        XCTAssertEqual(plan.commandLine, "ouro clone 'git@github.com:ourostack/private agent.ouro.git'")
    }

    func testInstallPlansRejectInvalidInputs() {
        XCTAssertThrowsError(try OuroAgentInstallCommandBuilder().clone(remote: " ", agentName: nil)) { error in
            XCTAssertEqual(error as? OuroAgentInstallCommandError, .emptyRemote)
        }
        XCTAssertThrowsError(try OuroAgentInstallCommandBuilder().clone(remote: "git@example.com:repo.git", agentName: "../sprout")) { error in
            XCTAssertEqual(error as? OuroAgentInstallCommandError, .invalidAgentName("../sprout"))
        }
    }
}
