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

    // MARK: - All-agents bundle-cleanup sweep
    //
    // `install(for:)` only cleans the BOSS bundle. But under runtime injection NOTHING belongs in
    // ANY synced bundle, and a non-boss agent can still carry a stale `ouro_workbench` /
    // `senses.workbench` (written by an older Workbench, or synced from another machine). The
    // all-agents sweep runs the SAME safe cleanup over every `*.ouro` bundle, regardless of who's
    // boss — never throwing on a single bad/missing bundle.

    func testCleanupAllAgentsRemovesStaleEntriesFromEveryDirtyBundle() throws {
        // TWO non-boss agents both carry stale Workbench entries — the all-agents point.
        let ouroborosConfig = try writeAgentConfig(
            agentName: "ouroboros",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "browser": { "command": "npx", "args": ["@playwright/mcp@latest"] },
                "ouro_workbench": { "command": "/tmp/old", "args": [] }
              },
              "senses": {
                "cli": { "enabled": true },
                "workbench": { "enabled": true }
              }
            }
            """
        )
        let sluggerConfig = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": {
                "ouro_workbench": { "command": "/tmp/old", "args": [] }
              }
            }
            """
        )
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: try writeExecutable()
        )

        let changed = registrar.cleanupAllAgents()

        XCTAssertEqual(Set(changed), ["ouroboros", "slugger"], "both dirty agents must be cleaned")

        let ouroboros = try loadJSON(ouroborosConfig)
        let ouroborosServers = try XCTUnwrap(ouroboros["mcpServers"] as? [String: Any])
        XCTAssertNil(ouroborosServers["ouro_workbench"], "stale Workbench server removed from non-boss agent")
        XCTAssertNotNil(ouroborosServers["browser"], "unrelated server preserved")
        let ouroborosSenses = try XCTUnwrap(ouroboros["senses"] as? [String: Any])
        XCTAssertNil(ouroborosSenses["workbench"], "stale Workbench sense removed from non-boss agent")
        XCTAssertEqual((ouroborosSenses["cli"] as? [String: Any])?["enabled"] as? Bool, true, "unrelated sense preserved")

        let slugger = try loadJSON(sluggerConfig)
        XCTAssertNil((slugger["mcpServers"] as? [String: Any])?["ouro_workbench"], "stale Workbench server removed from second agent")
    }

    func testCleanupAllAgentsIsNoOpWriteWhenAllBundlesClean() throws {
        // A clean machine must produce NO writes — idempotent. We assert the file is byte-for-byte
        // untouched (no reserialization), which also proves we don't rewrite on every launch.
        let configURL = try writeAgentConfig(
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
        let before = try Data(contentsOf: configURL)
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: try writeExecutable()
        )

        let changed = registrar.cleanupAllAgents()

        XCTAssertTrue(changed.isEmpty, "no agent should be reported changed on a clean machine")
        XCTAssertEqual(try Data(contentsOf: configURL), before, "clean bundle must NOT be rewritten")
    }

    func testCleanupAllAgentsPreservesUnrelatedTopLevelKeys() throws {
        // Cleanup is surgical — only the two Workbench keys go; everything else survives verbatim.
        let configURL = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "enabled": true,
              "humanFacing": { "provider": "anthropic", "model": "opus" },
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
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: try writeExecutable()
        )

        _ = registrar.cleanupAllAgents()

        let root = try loadJSON(configURL)
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertEqual(root["enabled"] as? Bool, true)
        let human = try XCTUnwrap(root["humanFacing"] as? [String: Any])
        XCTAssertEqual(human["provider"] as? String, "anthropic")
        XCTAssertEqual(human["model"] as? String, "opus")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["ouro_workbench"])
        XCTAssertNotNil(servers["browser"])
        let senses = try XCTUnwrap(root["senses"] as? [String: Any])
        XCTAssertNil(senses["workbench"])
        XCTAssertEqual((senses["cli"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((senses["mail"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    func testCleanupAllAgentsSkipsGarbageAndMissingBundlesWithoutThrowing() throws {
        // One clean dirty-then-cleaned bundle, one bundle whose agent.json is non-JSON garbage,
        // and one bundle directory with NO agent.json at all. The sweep must clean the good one
        // and skip the bad ones gracefully — never throwing, never corrupting.
        let dirtyConfig = try writeAgentConfig(
            agentName: "slugger",
            json: """
            {
              "version": 2,
              "mcpServers": { "ouro_workbench": { "command": "/tmp/old", "args": [] } }
            }
            """
        )
        // garbage agent.json
        let garbageConfig = try writeAgentConfig(agentName: "garbage", json: "this is not json {{{")
        let garbageBefore = try Data(contentsOf: garbageConfig)
        // bundle dir with no agent.json
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent("noconfig.ouro", isDirectory: true),
            withIntermediateDirectories: true
        )
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory,
            mcpExecutableURL: try writeExecutable()
        )

        let changed = registrar.cleanupAllAgents()

        XCTAssertEqual(changed, ["slugger"], "only the valid dirty bundle is cleaned")
        XCTAssertNil((try loadJSON(dirtyConfig)["mcpServers"] as? [String: Any])?["ouro_workbench"])
        XCTAssertEqual(try Data(contentsOf: garbageConfig), garbageBefore, "garbage bundle left untouched, not corrupted")
    }

    func testCleanupAllAgentsReturnsEmptyWhenBundlesDirectoryMissing() throws {
        // No AgentBundles directory at all (fresh machine) → empty result, no throw.
        let registrar = BossWorkbenchMCPRegistrar(
            agentBundlesURL: temporaryDirectory.appendingPathComponent("does-not-exist", isDirectory: true),
            mcpExecutableURL: try writeExecutable()
        )

        XCTAssertEqual(registrar.cleanupAllAgents(), [])
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
