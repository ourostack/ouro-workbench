import XCTest
@testable import OuroWorkbenchCore

final class StartupRecoveryReconcilerTests: XCTestCase {
    /// With NO live-session signal (the default — and the synchronous load path
    /// before the `screen -ls` probe runs), an in-flight run reclassifies to
    /// needs-recovery and the entry gets the genuine-loss flag. This is the safe
    /// default: until survival is known, treat as lost.
    func testStartupReclassifiesInFlightRunsAsNeedingRecovery() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let running = ProcessRun(entryId: entry.id, pid: 123, status: .running)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [running])

        let reconciled = StartupRecoveryReconciler().reconcile(state)

        XCTAssertEqual(reconciled.processRuns.first?.status, .needsRecovery)
        XCTAssertNil(reconciled.processRuns.first?.pid)
        // A trusted auto-resume agent without a live screen session is genuinely
        // lost but auto-resuming — a calm flag, not an orange "needs boss review".
        XCTAssertEqual(reconciled.processEntries.first?.attention, .idle)
        XCTAssertEqual(
            reconciled.processEntries.first?.lastSummary,
            "Codex will auto-resume on recovery"
        )
    }

    /// The post-probe re-derivation only re-classifies ATTENTION for entries
    /// already in needs-recovery; it must NOT touch runs (so a session launched
    /// fresh between load and the `screen -ls` probe keeps its live `.running`
    /// run instead of being flipped back to needs-recovery).
    func testRederiveAttentionLeavesRunsUntouched() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let recovering = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true,
            attention: .needsBossReview
        )
        let freshlyLaunched = ProcessEntry(
            projectId: project.id,
            name: "Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo"
        )
        let recoveringRun = ProcessRun(entryId: recovering.id, status: .needsRecovery)
        let liveRun = ProcessRun(entryId: freshlyLaunched.id, pid: 99, status: .running)
        let state = WorkspaceState(
            projects: [project],
            processEntries: [recovering, freshlyLaunched],
            processRuns: [recoveringRun, liveRun]
        )

        let result = StartupRecoveryReconciler().rederiveAttention(state, liveSessionNames: [])

        // The freshly-launched live run is untouched.
        XCTAssertEqual(result.processRuns.first(where: { $0.entryId == freshlyLaunched.id })?.status, .running)
        XCTAssertEqual(result.processRuns.first(where: { $0.entryId == freshlyLaunched.id })?.pid, 99)
        // The recovering entry's attention is re-derived (auto-resume → calm idle).
        XCTAssertEqual(result.processEntries.first(where: { $0.id == recovering.id })?.attention, .idle)
    }

    /// U8a: a session whose `screen` session is still alive is the SUCCESS case
    /// of reboot recovery. It must land calm (idle — never `.needsBossReview`,
    /// never in the boss's waiting-on-you bucket) with a reconnect summary, NOT
    /// an orange alarm. Its run is still marked needs-recovery so the async
    /// reattach reconnects the viewer.
    func testSurvivingScreenSessionLandsCalmReconnected() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let running = ProcessRun(entryId: entry.id, pid: 123, status: .running)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [running])
        let liveName = PersistentTerminalSession.sessionName(for: entry.id)

        let reconciled = StartupRecoveryReconciler().reconcile(state, liveSessionNames: [liveName])

        XCTAssertEqual(reconciled.processRuns.first?.status, .needsRecovery)
        XCTAssertEqual(reconciled.processEntries.first?.attention, .idle)
        XCTAssertFalse(reconciled.processEntries.first!.attention.needsHuman)
        XCTAssertEqual(
            reconciled.processEntries.first?.lastSummary,
            "Codex reconnected — kept running while Workbench was closed"
        )
    }

    /// U8a: a genuinely-lost session that can't be auto-resumed (untrusted →
    /// manualActionNeeded) is the only case that gets an attention flag the boss
    /// reads as waiting-on-you. "Needs you", distinct from "auto-resuming".
    func testGenuinelyLostManualSessionGetsNeedsYouFlag() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Untrusted",
            kind: .command,
            executable: "rm",
            arguments: ["-rf", "/tmp/x"],
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: true
        )
        let running = ProcessRun(entryId: entry.id, pid: 123, status: .running)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [running])

        let reconciled = StartupRecoveryReconciler().reconcile(state, liveSessionNames: [])

        XCTAssertEqual(reconciled.processRuns.first?.status, .needsRecovery)
        XCTAssertEqual(reconciled.processEntries.first?.attention, .needsBossReview)
        XCTAssertTrue(reconciled.processEntries.first!.attention.needsHuman)
        XCTAssertEqual(
            reconciled.processEntries.first?.lastSummary,
            "Untrusted needs you to recover"
        )
    }

    /// A survivor that was already stamped `.needsBossReview` on quit (by the
    /// pre-fix quit path or a prior launch) gets that false alarm CLEARED once
    /// survival is known — the reconciler is idempotent toward the truth.
    func testSurvivorClearsAStaleNeedsBossReviewFlag() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true,
            attention: .needsBossReview,
            lastSummary: "Codex needs startup recovery"
        )
        let needsRecovery = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [needsRecovery])
        let liveName = PersistentTerminalSession.sessionName(for: entry.id)

        let reconciled = StartupRecoveryReconciler().reconcile(state, liveSessionNames: [liveName])

        XCTAssertEqual(reconciled.processEntries.first?.attention, .idle)
        XCTAssertEqual(
            reconciled.processEntries.first?.lastSummary,
            "Codex reconnected — kept running while Workbench was closed"
        )
    }

    func testStartupLeavesExitedRunsExited() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let exited = ProcessRun(entryId: entry.id, pid: nil, status: .exited, exitCode: 0)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [exited])

        let reconciled = StartupRecoveryReconciler().reconcile(state)

        XCTAssertEqual(reconciled.processRuns.first?.status, .exited)
        XCTAssertEqual(reconciled.processRuns.first?.exitCode, 0)
        XCTAssertEqual(reconciled.processEntries.first?.attention, .idle)
    }
}
