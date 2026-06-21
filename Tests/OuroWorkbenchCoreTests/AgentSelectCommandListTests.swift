import XCTest
@testable import OuroWorkbenchCore

/// U37(a): the command palette emitted one "Select Agent: <name>" row per scanned
/// bundle, so a duplicate inventory record (e.g. "slugger" twice) produced a
/// byte-identical duplicate row, and the current boss appeared as a redundant
/// "Select Agent: <boss> (boss)" even though it's already addressable via the boss
/// selector. This pure builder emits exactly one row per installed bundle,
/// de-duped by case-insensitive name, and EXCLUDES the current boss.
final class AgentSelectCommandListTests: XCTestCase {
    private func agent(_ name: String, _ status: OuroAgentBundleStatus = .ready) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "/b/\(name).ouro",
            configPath: "/b/\(name).ouro/agent.json",
            status: status,
            detail: status == .ready ? "ready" : "disabled in agent.json"
        )
    }

    func testOneRowPerBundleExcludingTheBoss() {
        let commands = AgentSelectCommandList.commands(
            agents: [agent("slugger"), agent("ouroboros"), agent("scout")],
            bossAgentName: "slugger"
        )
        XCTAssertEqual(commands.map(\.payload), ["ouroboros", "scout"])
        XCTAssertEqual(commands.map(\.title), ["Select Agent: ouroboros", "Select Agent: scout"])
        // No "(boss)" suffix survives — the boss isn't in this list at all.
        XCTAssertFalse(commands.contains { $0.title.contains("(boss)") })
        // Every row is the selectAgent command with the agent name as payload.
        XCTAssertTrue(commands.allSatisfy { $0.id == .selectAgent })
    }

    func testDuplicateInventoryRecordEmitsOneRow() {
        // The live-hunt bug: "slugger" listed twice in the inventory ⇒ one row, not two.
        let commands = AgentSelectCommandList.commands(
            agents: [agent("slugger"), agent("slugger"), agent("ouroboros")],
            bossAgentName: "ouroboros"
        )
        XCTAssertEqual(commands.map(\.payload), ["slugger"])
        XCTAssertEqual(commands.filter { $0.payload == "slugger" }.count, 1)
    }

    func testDeDupIsCaseInsensitiveAndKeepsFirstSpelling() {
        let commands = AgentSelectCommandList.commands(
            agents: [agent("Slugger"), agent("slugger"), agent("SLUGGER")],
            bossAgentName: ""
        )
        XCTAssertEqual(commands.map(\.payload), ["Slugger"], "first spelling wins; later case-variants drop")
    }

    func testBossExclusionIsCaseInsensitive() {
        let commands = AgentSelectCommandList.commands(
            agents: [agent("Slugger"), agent("scout")],
            bossAgentName: "slugger"
        )
        XCTAssertEqual(commands.map(\.payload), ["scout"])
    }

    func testEmptyBossNameKeepsEveryBundle() {
        let commands = AgentSelectCommandList.commands(
            agents: [agent("slugger"), agent("scout")],
            bossAgentName: ""
        )
        XCTAssertEqual(commands.map(\.payload), ["slugger", "scout"])
    }

    func testNonReadyAgentStillListedWithExclamationGlyph() {
        // A non-ready agent is still selectable (to inspect/repair it); the glyph
        // signals it needs attention, matching the prior behavior.
        let commands = AgentSelectCommandList.commands(
            agents: [agent("broken", .invalidConfig)],
            bossAgentName: ""
        )
        XCTAssertEqual(commands.first?.systemImage, "person.crop.circle.badge.exclamationmark")
        XCTAssertEqual(commands.first?.detail, agent("broken", .invalidConfig).summaryLine)
    }

    func testReadyAgentUsesPlainGlyph() {
        let commands = AgentSelectCommandList.commands(agents: [agent("ok")], bossAgentName: "")
        XCTAssertEqual(commands.first?.systemImage, "person.crop.circle")
    }
}
