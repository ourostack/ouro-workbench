import XCTest
@testable import OuroWorkbenchCore

final class BossAgentBridgeTests: XCTestCase {
    func testBossMcpServePlanUsesSelectedAgent() {
        let plan = BossAgentBridgePlanner().mcpServePlan(for: BossAgentSelection(agentName: "slugger"))

        XCTAssertEqual(plan.executable, "ouro")
        XCTAssertEqual(plan.arguments, ["mcp-serve", "--agent", "slugger"])
        XCTAssertEqual(plan.displayCommand, "ouro mcp-serve --agent slugger")
    }

    func testDefaultCheckInQuestionTargetsWorkbenchNeeds() {
        let question = BossAgentBridgePlanner().checkInQuestion()

        XCTAssertTrue(question.contains("what is going on"))
        XCTAssertTrue(question.contains("what is waiting on Ari"))
        XCTAssertTrue(question.contains("active terminal agents"))
    }
}
