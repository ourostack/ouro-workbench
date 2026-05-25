import XCTest
@testable import OuroWorkbenchCore

final class OuroAgentInstallCommandTests: XCTestCase {
    func testHatchPlanBuildsQuotedCommandLine() throws {
        let plan = try OuroAgentInstallCommandBuilder().hatch(
            agentName: "sprout",
            humanName: "Ari Mendelow",
            provider: "minimax"
        )

        XCTAssertEqual(plan.sessionName, "Hatch sprout")
        XCTAssertEqual(plan.commandLine, "ouro hatch --agent sprout --human 'Ari Mendelow' --provider minimax")
        XCTAssertEqual(plan.notes, "Ouro agent hatch flow launched from Workbench.")
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
        XCTAssertThrowsError(try OuroAgentInstallCommandBuilder().hatch(
            agentName: "../sprout",
            humanName: "Ari",
            provider: "minimax"
        )) { error in
            XCTAssertEqual(error as? OuroAgentInstallCommandError, .invalidAgentName("../sprout"))
        }
        XCTAssertThrowsError(try OuroAgentInstallCommandBuilder().hatch(
            agentName: "sprout",
            humanName: " ",
            provider: "minimax"
        )) { error in
            XCTAssertEqual(error as? OuroAgentInstallCommandError, .emptyHumanName)
        }
        XCTAssertThrowsError(try OuroAgentInstallCommandBuilder().clone(remote: " ", agentName: nil)) { error in
            XCTAssertEqual(error as? OuroAgentInstallCommandError, .emptyRemote)
        }
    }
}
