import XCTest
@testable import OuroWorkbenchCore

/// F8b source-pins. The own-group spawn + killpg group-reap is opted into by EXACTLY the two
/// grandchild-forkers (mcp-serve via `ProcessIOBox`, the detached daemon) and NOTHING else.
/// These pins fail if the wiring drifts: a forker silently dropping the own-group spawn (the
/// leak returns), or a finite child-only runner / a `/bin/ps` lister opting into killpg (which
/// would reap Workbench's SHARED process group).
final class SpawnOwnGroupWiringTests: XCTestCase {

    // MARK: - Positive pins (the two forkers DO use the own-group mechanism)

    func testMCPServeSpawnsBothToolPathsViaSpawnInOwnGroup() throws {
        let source = try coreSource("BossAgentMCPClient.swift")
        // Both mcp-serve spawns flow through the shared `spawnMCPServe`, which spawns via
        // SpawnInOwnGroup — there is NO bare Process()/process.run() spawn for that path anymore.
        XCTAssertTrue(
            source.contains("SpawnInOwnGroup.spawn"),
            "mcp-serve must spawn its child in its own process group"
        )
        XCTAssertTrue(
            source.contains("try spawnMCPServe(agentName: agentName)"),
            "both callTool and listToolNames must route through the shared own-group spawn helper"
        )
        // callTool + listToolNames both call spawnMCPServe (two call sites).
        let callSites = source.components(separatedBy: "try spawnMCPServe(agentName: agentName)").count - 1
        XCTAssertEqual(callSites, 2, "exactly callTool + listToolNames spawn the own-group mcp-serve child")
        // The live mcp-serve path no longer constructs a Foundation Process for the spawn.
        XCTAssertFalse(
            source.contains("try process.run()"),
            "the mcp-serve spawn must NOT fall back to a bare Process().run() (shared group → leak)"
        )
        // The ProcessIOBox now holds a raw pid, not a Process — pin that the type's stored
        // property is the pid (a regression to a `Process` field would reintroduce child-only kill).
        XCTAssertTrue(
            source.contains("private let pid: pid_t"),
            "ProcessIOBox must hold a raw pid (not a Process) so forceKill can killpg the group"
        )
        XCTAssertFalse(
            source.contains("private let process: Process"),
            "ProcessIOBox must NOT store a Process — that path force-kills child-only"
        )
    }

    func testMCPServeMarshallingIsByteIdenticalToThePriorProcessPath() throws {
        let source = try coreSource("BossAgentMCPClient.swift")
        // Executable, argv, environment, stdio must match the prior Process() construction so
        // PATH-resolution of `ouro` is unchanged (the correctness linchpin).
        XCTAssertTrue(source.contains(#"executablePath: "/usr/bin/env""#), "must keep /usr/bin/env")
        XCTAssertTrue(
            source.contains(#"arguments: ["env", "ouro"] + mcpServeArguments(agentName: agentName)"#),
            "argv must be [env, ouro] + the same mcpServeArguments the prior path used"
        )
        XCTAssertTrue(
            source.contains("TerminalEnvironment().valuesWithResolvedPath()"),
            "environment must be the same resolved-PATH terminal environment"
        )
    }

    func testProcessIOBoxForceKillRoutesViaGroupKillerOnKillGroup() throws {
        let source = try coreSource("BossAgentMCPClient.swift")
        // forceKill consults the policy and, on .killGroup, delivers via the groupKiller (killpg)
        // seam — NOT the child-only processKiller.
        XCTAssertTrue(source.contains("WatchdogEscalation.nextSignal"), "forceKill must use the escalation policy")
        XCTAssertTrue(source.contains("case .killGroup:"), "forceKill must have a .killGroup arm")
        XCTAssertTrue(source.contains("groupKiller(pid, SIGKILL)"), "the .killGroup arm must killpg via groupKiller")
        XCTAssertTrue(source.contains("childInOwnGroup: childInOwnGroup"), "the policy must be gated on the box's own-group flag")
        // FAIL-CLOSED: the own-group flag is verified from getpgid == pid at the spawn site.
        XCTAssertTrue(source.contains("getpgid(spawned.pid)"), "the box must be built fail-closed from getpgid")
    }

    func testDetachedDaemonStartSpawnsViaSpawnInOwnGroup() throws {
        let source = try coreSource("DaemonLiveness.swift")
        XCTAssertTrue(
            source.contains("SpawnInOwnGroup.spawn"),
            "detachedStart must spawn the daemon in its own process group"
        )
        XCTAssertFalse(
            source.contains("try process.run()"),
            "detachedStart must NOT spawn the daemon via a bare Process().run()"
        )
    }

    // MARK: - Negative pins (the finite child-only runners must NOT opt in)

    /// The finite ProcessWatchdog runners wait on `ouro` children that SHARE Workbench's process
    /// group; opting any of them into killpg/own-group would reap Workbench itself. Pin that none
    /// reference the own-group mechanism.
    func testFiniteRunnersDoNotOptIntoOwnGroupOrKillpg() throws {
        for file in [
            "AgentRepair.swift",
            "ProviderRefresh.swift",
            "ProviderVerify.swift",
            "LaneSelection.swift",
            "ProviderConfigForm.swift",
            "OuroAgentInstallCommand.swift",
        ] {
            let source = try coreSource(file)
            assertNoOwnGroupOptIn(source, file: file)
        }
    }

    /// The `/bin/ps` listers only READ the process table — they never spawn a grandchild-forker,
    /// so they must never touch the own-group / killpg machinery either.
    func testProcessListersDoNotOptIntoOwnGroupOrKillpg() throws {
        // Core onboarding ps lister.
        assertNoOwnGroupOptIn(try coreSource("Onboarding.swift"), file: "Onboarding.swift")
        // The MCP RunningProcessLister (/bin/ps) in the OuroWorkbenchMCP target.
        let mcpLister = try source(target: "OuroWorkbenchMCP", "RunningProcessLister.swift")
        assertNoOwnGroupOptIn(mcpLister, file: "RunningProcessLister.swift")
        // The App ps lister.
        let appLister = try source(target: "OuroWorkbenchApp", "OuroWorkbenchApp.swift")
        XCTAssertFalse(appLister.contains("SpawnInOwnGroup"), "the App ps lister must not reference SpawnInOwnGroup")
        XCTAssertFalse(appLister.contains("killpg"), "the App ps lister must not killpg")
    }

    // MARK: - helpers

    private func assertNoOwnGroupOptIn(_ source: String, file: String) {
        XCTAssertFalse(source.contains("SpawnInOwnGroup"), "\(file) must NOT reference SpawnInOwnGroup (child-only)")
        XCTAssertFalse(source.contains("killpg"), "\(file) must NOT killpg (would reap Workbench's shared group)")
        XCTAssertFalse(source.contains("POSIX_SPAWN_SETPGROUP"), "\(file) must NOT set its own process group")
        XCTAssertFalse(source.contains("childInOwnGroup"), "\(file) must NOT opt into the own-group escalation gate")
    }

    private func coreSource(_ file: String) throws -> String {
        try source(target: "OuroWorkbenchCore", file)
    }

    private func source(target: String, _ file: String) throws -> String {
        let url = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent(target)
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
