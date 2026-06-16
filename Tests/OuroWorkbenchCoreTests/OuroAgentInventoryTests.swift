import XCTest
@testable import OuroWorkbenchCore

final class OuroAgentInventoryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroAgentInventoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testScanDiscoversAgentBundlesAndProviderLanes() throws {
        try writeAgent(
            "slugger",
            json: """
            {
              "enabled": true,
              "humanFacing": {
                "provider": "minimax",
                "model": "MiniMax-M2.7"
              },
              "agentFacing": {
                "provider": "openai",
                "model": "gpt-5.2"
              }
            }
            """
        )
        try writeAgent("boss-b", json: #"{"enabled":true}"#)
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent("not-an-agent", isDirectory: true),
            withIntermediateDirectories: true
        )

        let agents = OuroAgentInventory(agentBundlesURL: temporaryDirectory).scan()

        XCTAssertEqual(agents.map(\.name), ["boss-b", "slugger"])
        let slugger = try XCTUnwrap(agents.first { $0.name == "slugger" })
        XCTAssertEqual(slugger.status, .ready)
        XCTAssertEqual(slugger.detail, "ready")
        XCTAssertEqual(slugger.humanFacing?.summary, "minimax/MiniMax-M2.7")
        XCTAssertEqual(slugger.agentFacing?.summary, "openai/gpt-5.2")
        XCTAssertTrue(slugger.isUsableAsBoss)
    }

    func testScanReportsMissingDisabledAndInvalidConfigs() throws {
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent("missing.ouro", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeAgent("disabled", json: #"{"enabled":false}"#)
        try writeAgent("invalid", json: #"["nope"]"#)

        let agents = OuroAgentInventory(agentBundlesURL: temporaryDirectory).scan()

        XCTAssertEqual(agents.first { $0.name == "missing" }?.status, .missingConfig)
        XCTAssertEqual(agents.first { $0.name == "disabled" }?.status, .disabled)
        XCTAssertEqual(agents.first { $0.name == "invalid" }?.status, .invalidConfig)
        XCTAssertFalse(try XCTUnwrap(agents.first { $0.name == "disabled" }).isUsableAsBoss)
    }

    func testScanSupportsCurrentLaneNames() throws {
        try writeAgent(
            "serpent",
            json: """
            {
              "outward": {
                "provider": "anthropic",
                "model": "claude-sonnet"
              },
              "inner": {
                "provider": "openai",
                "model": "gpt-5.2"
              }
            }
            """
        )

        let agent = try XCTUnwrap(OuroAgentInventory(agentBundlesURL: temporaryDirectory).scan().first)

        XCTAssertEqual(agent.humanFacing?.summary, "anthropic/claude-sonnet")
        XCTAssertEqual(agent.agentFacing?.summary, "openai/gpt-5.2")
    }

    func testLaneSummaryCoversProviderOnlyModelOnlyAndEmpty() {
        XCTAssertEqual(OuroAgentLane(provider: "anthropic").summary, "anthropic")
        XCTAssertEqual(OuroAgentLane(model: "claude-sonnet").summary, "claude-sonnet")
        XCTAssertNil(OuroAgentLane().summary)
    }

    func testRecordIdIsAgentNameAndSummaryLineIncludesAvailableLanes() {
        let record = OuroAgentRecord(
            name: "slugger",
            bundlePath: "/Users/example/AgentBundles/slugger.ouro",
            configPath: "/Users/example/AgentBundles/slugger.ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: OuroAgentLane(provider: "anthropic"),
            agentFacing: OuroAgentLane(model: "gpt-5.2")
        )

        XCTAssertEqual(record.id, "slugger")
        XCTAssertEqual(record.summaryLine, "ready · human anthropic · agent gpt-5.2")
    }

    func testScanReturnsEmptyWhenBundleDirectoryCannotBeRead() {
        let missing = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)

        XCTAssertEqual(OuroAgentInventory(agentBundlesURL: missing).scan(), [])
    }

    func testEmptyLaneObjectsAreIgnored() throws {
        try writeAgent(
            "empty-lanes",
            json: """
            {
              "humanFacing": {},
              "agentFacing": {},
              "outward": {},
              "inner": {}
            }
            """
        )

        let agent = try XCTUnwrap(OuroAgentInventory(agentBundlesURL: temporaryDirectory).scan().first)

        XCTAssertNil(agent.humanFacing)
        XCTAssertNil(agent.agentFacing)
        XCTAssertEqual(agent.summaryLine, "ready")
    }

    private func writeAgent(_ name: String, json: String) throws {
        let bundleURL = temporaryDirectory.appendingPathComponent("\(name).ouro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("agent.json"))
    }
}
