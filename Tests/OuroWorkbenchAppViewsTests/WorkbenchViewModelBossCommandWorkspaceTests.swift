#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 12 — the boss / command-dispatch / workspace tail.
///
/// Drives the synchronous-logic remainder of three cohesive areas (clusters 1/2 drove the spine;
/// this drives the residual arms):
///   • COMMAND DISPATCH — `performCommand(_ descriptor:)` (`:5867`) payload-bearing arms:
///     `.selectAgent`, `.useSelectedAgentAsBoss` (success), `.openSelectedAgentConfig` /
///     `.revealSelectedAgentBundle` / `.repairSelectedAgent` / `.installMCPForSelectedAgent`
///     (the `focusedAgentForCommand` resolve + the "No agent is selected" else-arm), `.manageAgents`.
///   • DISPATCH TARGETS — `selectAgent` (`:2800`, all 4 arms), `selectBoss` (`:3107`, guard /
///     invalid-name / re-select reset), `openAgentConfig` (`:2529`, config-not-found arm),
///     `revealAgentBundle` (`:2442`, via the `revealFileViewerSelectingURLs` seam), `repairAgent`
///     (`:2543`, the draft + `createCustomSession` via the `launchTerminalSession` seam),
///     `focusedAgentForCommand` (`:5911`, payload / selected / boss fallback).
///   • BOSS FLOWS — `recordBossDecisions(from:)` (`:6469`, empty-parse guard + a recorded
///     `.escalate` decision via an `OURO_WORKBENCH_DECISIONS:` marker answer),
///     `reconcileWaitingSessionsIntoInbox` (`:6569`, no-untriaged guard + the escalation loop),
///     `escalateWithheldBossInput` (`:7992`, widened private→internal; recorded + dedup arms).
///   • WORKSPACE / GROUP — `deleteGroup` (`:3705`, last-workspace / non-empty / delete+reselect),
///     `moveSessionEntries` (`:1125`, filter-active no-op + reorder), `moveGroups` (`:1146`),
///     `openWorkspaceConfig(config:configDirectory:)` (`:3362`, the import-apply: create +
///     already-present count).
///
/// CARVED (genuine machinery, NOT driven here): the `Task { await runBossQuickQuestion/
/// refreshWorkspace }` detached dispatches in performCommand; the `runExternalActionPump`
/// `while`-loop + `Task.sleep`; the boss-check-in MCP/daemon round-trip; `openAgentConfig`'s
/// `NSWorkspace.shared.open` success syscall (only the config-not-found guard drives); the private
/// `runBossCheckIn(...)` overload (two WiringTests pin its `private func` source marker, so it stays
/// private — only the public entry's guards are reachable here).
@MainActor
final class WorkbenchViewModelBossCommandWorkspaceTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C12DA9D5-0000-0000-0000-0000000000A1")!
    private static let entryId = UUID(uuidString: "C12DA9D5-0000-0000-0000-0000000000E1")!
    private static let wsId = UUID(uuidString: "C12DA9D5-0000-0000-0000-0000000000B1")!

    @MainActor private final class RevealRecorder { var urls: [URL] = [] }

    private func makeVM(
        withEntry: Bool = false,
        extraProjects: [WorkbenchProject] = []
    ) throws -> (WorkbenchViewModel, RevealRecorder) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmbcw-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let entries = withEntry ? [entry()] : []
        let projects = [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/vmbcw")] + extraProjects
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            bossWatchEnabled: false,
            projects: projects,
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        let rev = RevealRecorder()
        m.revealFileViewerSelectingURLs = { urls in rev.urls.append(contentsOf: urls) }
        return (m, rev)
    }

    private func entry(name: String = "build") -> ProcessEntry {
        ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: name, kind: .shell,
                     executable: "/bin/zsh", workingDirectory: "/tmp/vmbcw", trust: .trusted)
    }

    /// An agent record whose `configPath` exists on disk (so openAgentConfig's existence guard
    /// can be exercised either way) — written under a temp dir we own.
    private func seedAgent(_ m: WorkbenchViewModel, name: String, configExists: Bool) throws -> OuroAgentRecord {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmbcw-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundlePath = dir.appendingPathComponent("\(name).ouro").path
        try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
        let configPath = dir.appendingPathComponent("\(name).ouro/agent.json").path
        if configExists {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: configPath))
        }
        let rec = OuroAgentRecord(name: name, bundlePath: bundlePath, configPath: configPath,
                                  status: .ready, detail: "ready")
        m.ouroAgents.append(rec)
        return rec
    }

    private func descriptor(_ id: WorkbenchCommandID, payload: String? = nil) -> WorkbenchCommandDescriptor {
        WorkbenchCommandDescriptor(id: id, title: "", detail: "", systemImage: "", payload: payload)
    }

    // MARK: - selectAgent (4 arms)

    func testSelectAgent_nil_clearsSelection() throws {
        let (m, _) = try makeVM()
        m.selectedAgentName = "x"
        m.selectAgent(nil)
        XCTAssertNil(m.selectedAgentName)
    }

    func testSelectAgent_knownName_selectsIt() throws {
        let (m, _) = try makeVM()
        _ = try seedAgent(m, name: "alpha", configExists: true)
        m.selectAgent("alpha")
        XCTAssertEqual(m.selectedAgentName, "alpha")
    }

    func testSelectAgent_unknownNameButAgentsExist_selectsFirst() throws {
        let (m, _) = try makeVM()
        _ = try seedAgent(m, name: "alpha", configExists: true)
        m.selectAgent("ghost")
        XCTAssertEqual(m.selectedAgentName, "alpha", "unknown name falls back to the first agent")
    }

    func testSelectAgent_noAgents_presentsCreateForm() throws {
        let (m, _) = try makeVM()
        m.ouroAgents = []
        m.selectAgent("ghost")
        XCTAssertNil(m.selectedAgentName)
        XCTAssertTrue(m.isProviderConfigPresented, "no agents → opens the create-agent form")
    }

    // MARK: - selectBoss (guard / invalid / reselect)

    func testSelectBoss_sameName_isNoOp() throws {
        let (m, _) = try makeVM()
        m.selectBoss(agentName: "boss")  // already the boss
        XCTAssertEqual(m.state.boss.agentName, "boss")
    }

    func testSelectBoss_empty_isNoOp() throws {
        let (m, _) = try makeVM()
        m.selectBoss(agentName: "   ")
        XCTAssertEqual(m.state.boss.agentName, "boss")
    }

    func testSelectBoss_validNewName_switchesAndResets() throws {
        let (m, _) = try makeVM()
        m.bossCheckInAnswer = "stale"
        m.selectBoss(agentName: "newboss")
        XCTAssertEqual(m.state.boss.agentName, "newboss")
        XCTAssertNil(m.bossCheckInAnswer, "re-selecting the boss clears the cached check-in answer")
        // The per-project boss tracks the global selection.
        XCTAssertEqual(m.state.projects.first?.boss.agentName, "newboss")
    }

    // MARK: - openAgentConfig (config-not-found guard)

    func testOpenAgentConfig_missingConfig_setsError() throws {
        let (m, _) = try makeVM()
        let rec = try seedAgent(m, name: "noconf", configExists: false)
        m.openAgentConfig(rec)
        XCTAssertEqual(m.errorMessage, "Agent config not found at \(rec.configPath)")
    }

    // MARK: - revealAgentBundle (via the reveal seam)

    func testRevealAgentBundle_revealsConfigPathWhenPresent() throws {
        let (m, rev) = try makeVM()
        let rec = try seedAgent(m, name: "alpha", configExists: true)
        m.revealAgentBundle(rec)
        XCTAssertEqual(rev.urls.map(\.path), [rec.configPath], "reveals the config path when it exists")
    }

    func testRevealAgentBundle_revealsBundlePathWhenConfigMissing() throws {
        let (m, rev) = try makeVM()
        let rec = try seedAgent(m, name: "noconf", configExists: false)
        m.revealAgentBundle(rec)
        XCTAssertEqual(rev.urls.map(\.path), [rec.bundlePath], "falls back to the bundle path")
    }

    // MARK: - repairAgent (draft + createCustomSession via launch seam)

    func testRepairAgent_createsAndLaunchesRepairSession() throws {
        let (m, _) = try makeVM()
        let rec = try seedAgent(m, name: "alpha", configExists: true)
        let before = m.state.processEntries.count
        let ok = m.repairAgent(rec)
        XCTAssertTrue(ok, "repairAgent creates the repair session")
        XCTAssertEqual(m.state.processEntries.count, before + 1, "a repair terminal entry was created")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "repairAgent" })
    }

    // MARK: - focusedAgentForCommand (via performCommand dispatch)

    func testPerformCommand_selectAgent_routesToSelectAgent() throws {
        let (m, _) = try makeVM()
        _ = try seedAgent(m, name: "alpha", configExists: true)
        m.performCommand(descriptor(.selectAgent, payload: "alpha"))
        XCTAssertEqual(m.selectedAgentName, "alpha")
    }

    func testPerformCommand_useSelectedAgentAsBoss_withPayload_selectsBoss() throws {
        let (m, _) = try makeVM()
        m.performCommand(descriptor(.useSelectedAgentAsBoss, payload: "newboss"))
        XCTAssertEqual(m.state.boss.agentName, "newboss")
    }

    func testPerformCommand_openSelectedAgentConfig_resolvesPayloadAgent() throws {
        let (m, _) = try makeVM()
        let rec = try seedAgent(m, name: "noconf", configExists: false)
        m.performCommand(descriptor(.openSelectedAgentConfig, payload: rec.name))
        // Resolved the payload agent, then hit openAgentConfig's missing-config guard.
        XCTAssertEqual(m.errorMessage, "Agent config not found at \(rec.configPath)")
    }

    func testPerformCommand_revealSelectedAgentBundle_resolvesAndReveals() throws {
        let (m, rev) = try makeVM()
        let rec = try seedAgent(m, name: "alpha", configExists: true)
        m.performCommand(descriptor(.revealSelectedAgentBundle, payload: "alpha"))
        XCTAssertEqual(rev.urls.map(\.path), [rec.configPath])
    }

    func testPerformCommand_repairSelectedAgent_resolvesAndRepairs() throws {
        let (m, _) = try makeVM()
        _ = try seedAgent(m, name: "alpha", configExists: true)
        let before = m.state.processEntries.count
        m.performCommand(descriptor(.repairSelectedAgent, payload: "alpha"))
        XCTAssertEqual(m.state.processEntries.count, before + 1)
    }

    func testPerformCommand_revealSelectedAgentBundle_noAgent_setsError() throws {
        let (m, _) = try makeVM()
        m.ouroAgents = []
        m.state.boss = BossAgentSelection(agentName: "")  // so the boss fallback resolves to nothing
        m.performCommand(descriptor(.revealSelectedAgentBundle, payload: nil))
        XCTAssertEqual(m.errorMessage, "No agent is selected")
    }

    func testPerformCommand_manageAgents_selectsAnAgent() throws {
        let (m, _) = try makeVM()
        _ = try seedAgent(m, name: "alpha", configExists: true)
        m.performCommand(descriptor(.manageAgents, payload: "alpha"))
        XCTAssertEqual(m.selectedAgentName, "alpha")
    }

    // MARK: - recordBossDecisions (empty + recorded escalate)

    func testRecordBossDecisions_emptyAnswer_isNoOp() throws {
        let (m, _) = try makeVM()
        let before = m.state.openInbox().count
        m.recordBossDecisions(from: "no decisions block here")
        XCTAssertEqual(m.state.openInbox().count, before, "no parseable decisions → no inbox rows")
    }

    func testRecordBossDecisions_escalateDecision_recordsInbox() throws {
        let (m, _) = try makeVM(withEntry: true)
        let answer = """
        Here is my call.
        OURO_WORKBENCH_DECISIONS: [{"entry":"build","kind":"escalate","prompt":"Proceed? (y/N)","reasoning":"needs a human"}]
        """
        let before = m.state.openInbox().count
        m.recordBossDecisions(from: answer)
        XCTAssertGreaterThan(m.state.openInbox().count, before,
                             "an escalate decision is recorded into the inbox")
    }

    // MARK: - reconcileWaitingSessionsIntoInbox

    func testReconcileWaiting_noWaiting_isNoOp() throws {
        let (m, _) = try makeVM(withEntry: true)
        let before = m.state.openInbox().count
        m.reconcileWaitingSessionsIntoInbox()
        XCTAssertEqual(m.state.openInbox().count, before, "no waiting session → nothing to reconcile")
    }

    func testReconcileWaiting_untriagedWaiting_escalatesIntoInbox() throws {
        let (m, _) = try makeVM(withEntry: true)
        m.state.processEntries[0].attention = .waitingOnHuman
        m.state.processEntries[0].attentionReason = "Confirm? (y/N)"
        let before = m.state.openInbox().count
        m.reconcileWaitingSessionsIntoInbox()
        XCTAssertGreaterThan(m.state.openInbox().count, before,
                             "an untriaged waiting session is escalated into the inbox")
    }

    // MARK: - escalateWithheldBossInput (recorded + dedup)

    func testEscalateWithheldBossInput_recordsThenDedups() throws {
        let (m, _) = try makeVM(withEntry: true)
        let e = m.state.processEntries[0]
        let before = m.state.openInbox().count
        m.escalateWithheldBossInput(entry: e, source: "boss:watch", prompt: "Proceed?",
                                    proposedInput: "y", reason: "untrusted")
        let afterFirst = m.state.openInbox().count
        XCTAssertGreaterThan(afterFirst, before, "the withheld input is escalated once")
        // Identical re-escalation (same entry+prompt+kind) is deduped.
        m.escalateWithheldBossInput(entry: e, source: "boss:watch", prompt: "Proceed?",
                                    proposedInput: "y", reason: "untrusted")
        XCTAssertEqual(m.state.openInbox().count, afterFirst, "an identical re-escalation is deduped")
    }

    // (external-action-pump prologue methods recoverUnconfirmed*/sweepOrphaned* are `private` and
    // source-pinned by ReplayDedupWiringTests; left to the boss-flow batch's existing coverage —
    // the pump's `while`-loop + Task.sleep is the carve boundary regardless.)

    // MARK: - deleteGroup (3 arms)

    func testDeleteGroup_lastWorkspace_setsError() throws {
        let (m, _) = try makeVM()  // only "Home"
        let home = m.state.projects[0]
        m.deleteGroup(home)
        XCTAssertEqual(m.errorMessage, WorkbenchSurfacePolicy.keepAtLeastOneWorkspaceMessage)
        XCTAssertEqual(m.state.projects.count, 1, "the only workspace is not deleted")
    }

    func testDeleteGroup_nonEmpty_setsError() throws {
        let other = WorkbenchProject(id: UUID(), name: "Other", rootPath: "/tmp/other")
        let (m, _) = try makeVM(withEntry: true, extraProjects: [other])
        // the entry is in projectId (Home); deleting Home (non-empty) must error.
        let home = m.state.projects.first { $0.id == Self.projectId }!
        m.deleteGroup(home)
        XCTAssertNotNil(m.errorMessage)
        XCTAssertTrue(m.state.projects.contains { $0.id == Self.projectId }, "non-empty workspace not deleted")
    }

    func testDeleteGroup_emptyAndNotLast_deletesAndLogs() throws {
        let empty = WorkbenchProject(id: UUID(), name: "Empty", rootPath: "/tmp/empty")
        let (m, _) = try makeVM(extraProjects: [empty])
        m.deleteGroup(empty)
        XCTAssertFalse(m.state.projects.contains { $0.id == empty.id }, "empty non-last workspace deleted")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "deleteGroup" })
    }

    // MARK: - moveSessionEntries / moveGroups

    func testMoveSessionEntries_filterActive_isNoOp() throws {
        let (m, _) = try makeVM(withEntry: true)
        m.sidebarFilter = "build"  // a non-empty filter
        let before = m.state.processEntries.map(\.id)
        m.moveSessionEntries(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        XCTAssertEqual(m.state.processEntries.map(\.id), before, "reorder is a no-op while filtering")
    }

    func testMoveGroups_reorders() throws {
        let other = WorkbenchProject(id: UUID(), name: "Other", rootPath: "/tmp/other")
        let (m, _) = try makeVM(extraProjects: [other])
        let firstBefore = m.state.projects.first?.id
        m.moveGroups(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertNotEqual(m.state.projects.first?.id, firstBefore, "the first group moved")
    }

    // MARK: - openWorkspaceConfig (import-apply: create + already-present)

    func testOpenWorkspaceConfig_createsNewTerminalAndCountsAlreadyPresent() throws {
        let (m, _) = try makeVM()
        let cfg = WorkbenchWorkspaceConfig(
            group: "Imported",
            terminals: [
                WorkbenchWorkspaceConfig.TerminalConfig(name: "first", command: "echo hi"),
                WorkbenchWorkspaceConfig.TerminalConfig(name: "first", command: "echo dup"),
            ])
        let result = m.openWorkspaceConfig(config: cfg, configDirectory: "/tmp/imported")
        // First "first" is created; the second is a (projectId,name) dup → already-present.
        XCTAssertEqual(result.createdCount, 1, "one terminal created")
        XCTAssertEqual(result.alreadyPresentCount, 1, "the duplicate name is counted as already present")
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_selectBossActuallySwitches() throws {
        let (m, _) = try makeVM()
        XCTAssertEqual(m.state.boss.agentName, "boss", "precondition")
        m.selectBoss(agentName: "switched")
        XCTAssertEqual(m.state.boss.agentName, "switched", "selectBoss mutated the boss name")
    }
}
#endif
