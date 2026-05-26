import XCTest
@testable import OuroWorkbenchCore

final class BossAgentBridgeTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossAgentBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

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

    func testWatchQuestionTargetsChangesAndAutonomy() {
        let question = BossAgentBridgePlanner().watchQuestion()

        XCTAssertTrue(question.contains("workspace changes"))
        XCTAssertTrue(question.contains("waiting on Ari"))
        XCTAssertTrue(question.contains("keep trusted terminal agents moving"))
    }

    func testWorkbenchMCPRegistrationInstallsServerIntoBossAgentConfig() throws {
        let agentConfigURL = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "browser": {
                  "command": "npx",
                  "args": ["@playwright/mcp@latest"]
                }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        let before = registrar.snapshot(for: BossAgentSelection(agentName: "slugger"))
        XCTAssertEqual(before.status, .notRegistered)

        let after = try registrar.install(for: BossAgentSelection(agentName: "slugger"))

        XCTAssertEqual(after.status, .registered)
        let root = try loadJSON(agentConfigURL)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["browser"])
        let workbench = try XCTUnwrap(servers["ouro_workbench"] as? [String: Any])
        XCTAssertEqual(workbench["command"] as? String, executableURL.path)
        XCTAssertEqual(workbench["args"] as? [String], [])
        let senses = try XCTUnwrap(root["senses"] as? [String: Any])
        let workbenchSense = try XCTUnwrap(senses["workbench"] as? [String: Any])
        XCTAssertEqual(workbenchSense["enabled"] as? Bool, true)
    }

    func testWorkbenchMCPRegistrationDetectsDriftAndUpdates() throws {
        let agentConfigURL = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "ouro_workbench": {
                  "command": "/tmp/old",
                  "args": ["--old"]
                }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        XCTAssertEqual(registrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status, .needsUpdate)

        try registrar.install(for: BossAgentSelection(agentName: "slugger"))

        let root = try loadJSON(agentConfigURL)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let workbench = try XCTUnwrap(servers["ouro_workbench"] as? [String: Any])
        XCTAssertEqual(workbench["command"] as? String, executableURL.path)
        XCTAssertEqual(workbench["args"] as? [String], [])
    }

    func testWorkbenchMCPRegistrationRepairsMissingWorkbenchSenseFlag() throws {
        let executableURL = try writeExecutable()
        try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "ouro_workbench": {
                  "command": "\(executableURL.path)",
                  "args": []
                }
              },
              "senses": {
                "cli": { "enabled": true }
              }
            }
            """
        )
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        let snapshot = registrar.snapshot(for: BossAgentSelection(agentName: "slugger"))

        XCTAssertEqual(snapshot.status, .needsUpdate)
        XCTAssertTrue(snapshot.detail.contains("senses.workbench.enabled"))
    }

    func testWorkbenchMCPRegistrationPreservesExistingSenses() throws {
        let agentConfigURL = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "senses": {
                "cli": { "enabled": true },
                "mail": { "enabled": true }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        try registrar.install(for: BossAgentSelection(agentName: "slugger"))

        let root = try loadJSON(agentConfigURL)
        let senses = try XCTUnwrap(root["senses"] as? [String: Any])
        XCTAssertEqual((senses["cli"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((senses["mail"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((senses["workbench"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    func testWorkbenchMCPRegistrationReportsMissingAgentAndExecutable() throws {
        let executableURL = try writeExecutable()
        let missingAgentRegistrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        XCTAssertEqual(missingAgentRegistrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status, .agentMissing)

        try writeAgentConfig(agentName: "slugger", json: #"{"version":2}"#)
        let missingExecutableRegistrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: temporaryDirectory.appendingPathComponent("missing")
        )

        XCTAssertEqual(missingExecutableRegistrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status, .executableMissing)
    }

    func testWorkbenchMCPRegistrationRejectsUnsafeBossAgentNames() throws {
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        XCTAssertFalse(BossWorkbenchMCPRegistrar.isValidAgentBundleName("../slugger"))
        XCTAssertFalse(BossWorkbenchMCPRegistrar.isValidAgentBundleName("nested/slugger"))
        XCTAssertFalse(BossWorkbenchMCPRegistrar.isValidAgentBundleName(" slugger"))
        XCTAssertEqual(registrar.snapshot(for: BossAgentSelection(agentName: "../slugger")).status, .invalidConfig)
        XCTAssertThrowsError(try registrar.install(for: BossAgentSelection(agentName: "../slugger"))) { error in
            XCTAssertEqual(error as? BossWorkbenchMCPRegistrationError, .invalidAgentName("../slugger"))
        }
    }

    func testDefaultWorkbenchMCPExecutableURLUsesBundleWhenRunningFromAppBundle() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Ouro Workbench.app")
        let homeURL = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let executableURL = BossWorkbenchMCPRegistrar.defaultMCPExecutableURL(bundleURL: bundleURL, homeURL: homeURL)

        XCTAssertEqual(executableURL.path, "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP")
    }

    func testDefaultWorkbenchMCPExecutableURLFallsBackToHomeApplicationsForDevelopmentRuns() {
        let bundleURL = URL(fileURLWithPath: "/tmp/debug", isDirectory: true)
        let homeURL = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let executableURL = BossWorkbenchMCPRegistrar.defaultMCPExecutableURL(bundleURL: bundleURL, homeURL: homeURL)

        XCTAssertEqual(executableURL.path, "/Users/test/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP")
    }

    @discardableResult
    private func writeAgentConfig(agentName: String, json: String) throws -> URL {
        let bundleURL = temporaryDirectory
            .appendingPathComponent("\(agentName).ouro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let agentConfigURL = bundleURL.appendingPathComponent("agent.json")
        try Data(json.utf8).write(to: agentConfigURL)
        return agentConfigURL
    }

    private func writeExecutable() throws -> URL {
        let executableURL = temporaryDirectory.appendingPathComponent("OuroWorkbenchMCP")
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return executableURL
    }

    private func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
