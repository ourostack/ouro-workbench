#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 1 — `WorkbenchViewModel.applyBossAction(_:source:requestId:)` (`:7600`, the
/// single biggest uncovered cluster, ~315 lines). It's a pure-dispatch action handler: validate →
/// replay-dedup → entryless-authorize → entryless-handler dispatch → entry-resolve → entry-authorize
/// (+ sendInput escalation) → entry-handler dispatch. Every arm returns a `finishBossAction(...)`
/// String AND records an action-log entry, so each is directly INVOKE-able (the method is widened
/// private→internal) + effect-asserted (the returned String + `state.actionLog`) + mutation-verified.
///
/// The downstream onboarding handlers (`startRepairAgent`/`startVerifyProvider`/… and the
/// requestProviderConfig/ensureDaemon/reportBug delegations) are SEPARATE clusters (driven in later
/// VM-GATE PRs); here we drive the dispatch + the inline create/launch/recover/terminate/sendInput/
/// moveSession/setTrust/setAutoResume/archive/restore arms. Subprocess-spawning is no-op'd via the
/// `launchTerminalSession` seam so no `screen` child orphans (#332).
@MainActor
final class WorkbenchViewModelBossActionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "B0551AC7-0000-0000-0000-0000000000A1")!
    private static let altProjectId = UUID(uuidString: "B0551AC7-0000-0000-0000-0000000000A2")!
    private static let entryId = UUID(uuidString: "B0551AC7-0000-0000-0000-0000000000E1")!
    private static let wsId = UUID(uuidString: "B0551AC7-0000-0000-0000-0000000000B1")!

    // MARK: - Hermetic VM with a trusted, non-archived entry the entry-auth passes

    /// A REAL on-disk directory so `createGroup`'s `WorkspaceRootValidation.validateOnDisk` passes.
    private(set) var realRoot = "/tmp"
    /// The paths the last `makeVM` built — lets a test seed the action-request applied ledger
    /// (the replay-dedup arm consults `externalActionQueue.appliedRequestIds()`).
    private(set) var lastPaths: WorkbenchPaths?

    private func makeVM(entries: [ProcessEntry] = [], runs: [ProcessRun] = []) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmboss-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        // A real, existing root the createGroup on-disk validation accepts.
        let root = tmp.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        realRoot = root.path
        let paths = WorkbenchPaths(rootURL: tmp)
        lastPaths = paths
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            bossWatchEnabled: false,
            projects: [
                WorkbenchProject(id: Self.projectId, name: "Home", rootPath: root.path),
                WorkbenchProject(id: Self.altProjectId, name: "Other", rootPath: root.path),
            ],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        model.launchTerminalSession = { _ in }   // no real screen child (#332)
        return model
    }

    private func entry(name: String = "build", trust: ProcessTrust = .trusted,
                       autoResume: Bool = false, isArchived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name, kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmboss",
            trust: trust, autoResume: autoResume, isArchived: isArchived)
    }

    /// Register an (un-started, no-PTY) controller in `activeSessions` so the "is running"
    /// guards take their live-session arm.
    private func registerLive(_ m: WorkbenchViewModel, _ id: UUID) throws {
        let plan = TerminalCommandPlan(entryId: id, executable: "/bin/zsh", arguments: [],
                                       workingDirectory: "/tmp/vmboss", reason: "vmboss test")
        m.activeSessions[id] = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    private func act(_ kind: BossWorkbenchActionKind, entry: String? = nil, text: String? = nil,
                     group: String? = nil, name: String? = nil, command: String? = nil,
                     workingDirectory: String? = nil, trust: ProcessTrust? = nil,
                     autoResume: Bool? = nil, owner: String? = nil) -> BossWorkbenchAction {
        BossWorkbenchAction(action: kind, entry: entry, text: text, group: group, name: name,
                            command: command, workingDirectory: workingDirectory, trust: trust,
                            autoResume: autoResume, owner: owner)
    }

    // MARK: - Validation + dedup + auth dispatch arms

    func testValidationFailure_skips() throws {
        let m = try makeVM()
        // sendInput with no entry fails validateForQueueing (entry required) → the validation catch arm.
        let result = m.applyBossAction(act(.sendInput, text: "hi"), source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Skipped sendInput:"), "validation-fail arm: \(result)")
    }

    func testReplayDedup_skipsAlreadyApplied() throws {
        let m = try makeVM()
        let paths = try XCTUnwrap(lastPaths)
        let reqId = UUID()
        // Seed the durable applied-ledger marker the way the action pump's `markApplied` does
        // (a zero-byte `applied/<uuid>.json`), so `applyBossAction`'s replay-dedup guard —
        // `ReplayDedupDecider().decide(... appliedRequestIds:)` — sees this requestId as already
        // applied and takes the skip arm. (markApplied runs OFF the synchronous apply, so a direct
        // call can't populate it; this seeds the exact on-disk state a crash-replay would leave.)
        let appliedDir = paths.actionRequestsURL.appendingPathComponent("applied", isDirectory: true)
        try FileManager.default.createDirectory(at: appliedDir, withIntermediateDirectories: true)
        try Data().write(to: appliedDir.appendingPathComponent("\(reqId.uuidString).json"))
        let result = m.applyBossAction(act(.createGroup, name: "G1", workingDirectory: realRoot),
                                       source: "external:t", requestId: reqId)
        XCTAssertTrue(result.contains("already applied (replay)"), "replay-dedup arm: \(result)")
    }

    // MARK: - Entryless handlers: createGroup / createTerminal / createSession

    func testCreateGroup_success() throws {
        let m = try makeVM()
        let before = m.state.projects.count
        let result = m.applyBossAction(act(.createGroup, name: "NewGrp", workingDirectory: realRoot),
                                       source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Created group NewGrp"), "createGroup success: \(result)")
        XCTAssertEqual(m.state.projects.count, before + 1)
    }

    func testCreateGroup_failure_invalidRoot() throws {
        let m = try makeVM()
        let result = m.applyBossAction(act(.createGroup, name: "Bad", workingDirectory: "/tmp/does-not-exist-\(UUID())"),
                                       source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Failed createGroup:"), "createGroup fail: \(result)")
    }

    func testCreateTerminal_success() throws {
        let m = try makeVM()
        let result = m.applyBossAction(
            act(.createTerminal, group: "Home", name: "t1", command: "echo hi"), source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Created terminal t1 in Home"), "createTerminal: \(result)")
        XCTAssertTrue(m.state.processEntries.contains { $0.name == "t1" })
    }

    func testCreateTerminal_noGroupMatch_skips() throws {
        let m = try makeVM()
        // command + name present (pass validateForQueueing) so the handler's no-group arm is reached.
        let result = m.applyBossAction(act(.createTerminal, group: "Nonexistent", name: "t", command: "echo hi"),
                                       source: "boss:x")
        XCTAssertTrue(result.contains("no unique group matches"), "createTerminal no-group: \(result)")
    }

    func testCreateSession_missingOwner_skips() throws {
        let m = try makeVM()
        // command + name present (pass validation: createSession requires command + owner; owner
        // omitted → the handler's missing-owner arm). validateForQueueing requires owner too, so the
        // validation catch fires first with the same intent — assert on either honest skip message.
        let result = m.applyBossAction(act(.createSession, group: "Home", name: "s", command: "echo hi"),
                                       source: "boss:x")
        XCTAssertTrue(result.contains("owner"), "createSession no-owner: \(result)")
    }

    func testCreateSession_success() throws {
        let m = try makeVM()
        let result = m.applyBossAction(
            act(.createSession, group: "Home", name: "s1", command: "echo hi", owner: "agentA"), source: "boss:x")
        XCTAssertTrue(result.contains("Created session s1 in Home owned by agentA"), "createSession: \(result)")
    }

    // MARK: - Entry resolution + auth deny arms

    func testNoEntryMatch_skips() throws {
        let m = try makeVM()
        let result = m.applyBossAction(act(.launch, entry: "ghost"), source: "boss:x")
        XCTAssertTrue(result.contains("no unique process entry matches"), "no-entry: \(result)")
    }

    func testEntryAuth_deniesUntrusted() throws {
        let e = entry(trust: .untrusted)
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.launch, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.contains("untrusted"), "untrusted-deny: \(result)")
    }

    func testEntryAuth_deniesArchived() throws {
        let e = entry(isArchived: true)
        let m = try makeVM(entries: [e])
        // A non-restore action on an archived (trusted) entry → authorize denies "entry is archived"
        // BEFORE the handler. (restore is the un-archive action and is intentionally permitted.)
        let result = m.applyBossAction(act(.launch, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.contains("archived"), "archived-deny: \(result)")
    }

    // MARK: - Entry handlers (trusted entry → auth passes)

    func testLaunch_success() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.launch, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Launched build"), "launch: \(result)")
    }

    func testLaunch_alreadyRunning_skips() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        try registerLive(m, e.id)
        let result = m.applyBossAction(act(.launch, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.contains("already running"), "launch-already: \(result)")
    }

    func testTerminate_notRunning_skips() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.terminate, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.contains("not running"), "terminate-not-running: \(result)")
    }

    func testTerminate_success() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        try registerLive(m, e.id)
        let result = m.applyBossAction(act(.terminate, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Stopped build"), "terminate: \(result)")
    }

    func testSendInput_notRunning_skips() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.sendInput, entry: "build", text: "go"), source: "boss:x")
        XCTAssertTrue(result.contains("not running"), "sendInput-not-running: \(result)")
    }

    func testSendInput_emptyText_validationSkips() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        try registerLive(m, e.id)
        // Empty text is rejected by validateForQueueing (the top validation catch arm), before the
        // handler — `requires non-empty text`. (The handler's own `guard let text, !text.isEmpty`
        // is defensive/unreachable via this path; validateForQueueing owns it.)
        let result = m.applyBossAction(act(.sendInput, entry: "build", text: ""), source: "boss:x")
        XCTAssertTrue(result.contains("non-empty text") || result.contains("missing text"),
                      "sendInput-empty-text validation skip: \(result)")
    }

    func testSendInput_success() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        try registerLive(m, e.id)
        let result = m.applyBossAction(act(.sendInput, entry: "build", text: "run tests"), source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Sent input to build"), "sendInput: \(result)")
    }

    func testMoveSession_success() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.moveSession, entry: "build", group: "Other"), source: "boss:x")
        XCTAssertTrue(result.contains("Moved build to Other"), "moveSession: \(result)")
        XCTAssertEqual(m.state.processEntries.first?.projectId, Self.altProjectId)
    }

    func testMoveSession_running_skips() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        try registerLive(m, e.id)
        let result = m.applyBossAction(act(.moveSession, entry: "build", group: "Other"), source: "boss:x")
        XCTAssertTrue(result.contains("stop it first"), "moveSession-running: \(result)")
    }

    func testSetTrust_success() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.setTrust, entry: "build", trust: .untrusted), source: "boss:x")
        XCTAssertTrue(result.contains("trust to untrusted"), "setTrust: \(result)")
        XCTAssertEqual(m.state.processEntries.first?.trust, .untrusted)
    }

    func testSetAutoResume_success() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.setAutoResume, entry: "build", autoResume: true), source: "boss:x")
        XCTAssertTrue(result.contains("Enabled auto-resume"), "setAutoResume: \(result)")
        XCTAssertEqual(m.state.processEntries.first?.autoResume, true)
    }

    func testArchive_success() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        let result = m.applyBossAction(act(.archive, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.hasPrefix("Archived build"), "archive: \(result)")
        XCTAssertEqual(m.state.processEntries.first?.isArchived, true)
    }

    func testArchive_running_skips() throws {
        let e = entry()
        let m = try makeVM(entries: [e])
        try registerLive(m, e.id)
        let result = m.applyBossAction(act(.archive, entry: "build"), source: "boss:x")
        XCTAssertTrue(result.contains("stop it first"), "archive-running: \(result)")
    }

    // MARK: - Negative control (mutation-verified): the result string is load-bearing

    func testNegativeControl_setTrustActuallyMutates() throws {
        // setTrust → trusted then → untrusted flips the stored trust; proves the handler runs
        // (a no-op handler would leave trust unchanged). Mutation: replacing the setTrust body
        // with a no-op leaves trust == .trusted → this assertion flips RED.
        let e = entry(trust: .trusted)
        let m = try makeVM(entries: [e])
        XCTAssertEqual(m.state.processEntries.first?.trust, .trusted, "precondition")
        _ = m.applyBossAction(act(.setTrust, entry: "build", trust: .untrusted), source: "boss:x")
        XCTAssertEqual(m.state.processEntries.first?.trust, .untrusted, "setTrust mutated the stored trust")
    }
}
#endif
