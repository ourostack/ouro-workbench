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

    func testBossMcpServePlanAppendsWorkbenchMCPFlagWhenPathKnown() {
        // RUNTIME-INJECTION model: when the installed Workbench MCP binary path is known,
        // the boss-bridge passes `--workbench-mcp <path>` so the ouro runtime injects the
        // Workbench MCP into the boss's turn per-turn — nothing is written to the bundle.
        let plan = BossAgentBridgePlanner().mcpServePlan(
            for: BossAgentSelection(agentName: "slugger"),
            workbenchMCPPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
        )

        XCTAssertEqual(
            plan.arguments,
            ["mcp-serve", "--agent", "slugger", "--workbench-mcp", "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"]
        )
    }

    func testBossMcpServePlanPassesWorkbenchMCPFlagPathlessWhenPathUnresolved() {
        // When the binary path can't be resolved, pass the flag path-less so the ouro side
        // self-discovers the Workbench MCP.
        let plan = BossAgentBridgePlanner().mcpServePlan(
            for: BossAgentSelection(agentName: "slugger"),
            workbenchMCPPath: ""
        )

        XCTAssertEqual(plan.arguments, ["mcp-serve", "--agent", "slugger", "--workbench-mcp"])
    }

    func testBossMcpServePlanOmitsWorkbenchMCPFlagWhenNotRequested() {
        // The path-less default (`nil`) preserves the legacy arg shape for callers that
        // don't opt into runtime injection.
        let plan = BossAgentBridgePlanner().mcpServePlan(
            for: BossAgentSelection(agentName: "slugger"),
            workbenchMCPPath: nil
        )

        XCTAssertEqual(plan.arguments, ["mcp-serve", "--agent", "slugger"])
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

    // MARK: - RUNTIME-INJECTION model
    //
    // The registrar no longer WRITES the boss bundle. `install` is now a CLEANUP migration that
    // REMOVES any stale `ouro_workbench` from `mcpServers` and removes `senses.workbench`. The
    // `snapshot` reads `.registered` when the Workbench MCP binary is present on disk AND the
    // bundle is clean (runtime injection available); `.needsUpdate` when the binary is present but
    // a stale bundle entry remains (cleanup-pending); `.notRegistered` when the binary is missing.

    func testSnapshotRegisteredWhenBinaryPresentAndBundleClean() throws {
        // A bundle with no Workbench entry + an installed binary → runtime injection available.
        try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "browser": { "command": "npx", "args": ["@playwright/mcp@latest"] }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        let snapshot = registrar.snapshot(for: BossAgentSelection(agentName: "slugger"))
        XCTAssertEqual(snapshot.status, .registered)
    }

    func testSnapshotNotRegisteredWhenBinaryMissing() throws {
        // A clean bundle but a missing binary → runtime injection NOT available.
        try writeAgentConfig(agentName: "slugger", json: #"{"version":2}"#)
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: temporaryDirectory.appendingPathComponent("missing")
        )

        XCTAssertEqual(
            registrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status,
            .notRegistered
        )
    }

    func testSnapshotNeedsUpdateWhenStaleWorkbenchServerInBundle() throws {
        // Binary present, but a stale `ouro_workbench` entry survives in the bundle (e.g. written
        // by an older Workbench, or synced from another machine) → cleanup-pending.
        try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "ouro_workbench": { "command": "/tmp/old", "args": ["--old"] }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        XCTAssertEqual(
            registrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status,
            .needsUpdate
        )
    }

    func testSnapshotNeedsUpdateWhenStaleWorkbenchSenseInBundle() throws {
        // Binary present, no stale server, but a stale `senses.workbench` entry remains.
        try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "senses": {
                "cli": { "enabled": true },
                "workbench": { "enabled": true }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        XCTAssertEqual(
            registrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status,
            .needsUpdate
        )
    }

    func testInstallCleansStaleWorkbenchServerAndSenseFromBundle() throws {
        // The migration: `install` REMOVES the stale `ouro_workbench` server and the stale
        // `senses.workbench` entry — and preserves everything else.
        let agentConfigURL = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "browser": { "command": "npx", "args": ["@playwright/mcp@latest"] },
                "ouro_workbench": { "command": "/tmp/old", "args": [] }
              },
              "senses": {
                "cli": { "enabled": true },
                "mail": { "enabled": true },
                "workbench": { "enabled": true }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        XCTAssertEqual(
            registrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status,
            .needsUpdate
        )

        let after = try registrar.install(for: BossAgentSelection(agentName: "slugger"))
        XCTAssertEqual(after.status, .registered)

        let root = try loadJSON(agentConfigURL)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["ouro_workbench"], "stale Workbench server must be removed")
        XCTAssertNotNil(servers["browser"], "unrelated servers must be preserved")
        let senses = try XCTUnwrap(root["senses"] as? [String: Any])
        XCTAssertNil(senses["workbench"], "stale Workbench sense must be removed")
        XCTAssertEqual((senses["cli"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((senses["mail"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    func testInstallIsNoOpWriteWhenBundleAlreadyClean() throws {
        // A clean bundle stays clean (and `install` does NOT add `ouro_workbench`/`senses.workbench`).
        let agentConfigURL = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "browser": { "command": "npx", "args": ["@playwright/mcp@latest"] }
              }
            }
            """
        )
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )

        let after = try registrar.install(for: BossAgentSelection(agentName: "slugger"))
        XCTAssertEqual(after.status, .registered)

        let root = try loadJSON(agentConfigURL)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["ouro_workbench"], "install must NEVER write the Workbench server")
        XCTAssertNotNil(servers["browser"])
        if let senses = root["senses"] as? [String: Any] {
            XCTAssertNil(senses["workbench"], "install must NEVER write the Workbench sense")
        }
    }

    func testSnapshotReportsMissingAgentBundle() throws {
        let executableURL = try writeExecutable()
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: executableURL
        )
        XCTAssertEqual(
            registrar.snapshot(for: BossAgentSelection(agentName: "slugger")).status,
            .agentMissing
        )
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
