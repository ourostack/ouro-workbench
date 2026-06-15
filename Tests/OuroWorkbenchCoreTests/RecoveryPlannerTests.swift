import XCTest
@testable import OuroWorkbenchCore

final class RecoveryPlannerTests: XCTestCase {
    func testClaudeCodeWithSessionIdAutoResumes() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            terminalSessionId: "claude-session-123"
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan, [
            RecoveryPlan(
                entryId: entry.id,
                runId: run.id,
                action: .autoResume,
                reason: "Claude Code has native resume metadata"
            )
        ])
    }

    func testPlanRecoveryUsesMostRecentRunForEachEntry() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let old = ProcessRun(entryId: entry.id, status: .needsRecovery, startedAt: Date(timeIntervalSince1970: 1))
        let newest = ProcessRun(entryId: entry.id, status: .exited, startedAt: Date(timeIntervalSince1970: 2))
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [old, newest])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.runId, newest.id)
        XCTAssertEqual(plan.first?.action, .noAction)
        XCTAssertEqual(plan.first?.reason, "latest run status is exited")
    }

    func testCopilotRespawnsFromCheckpointUntilNativeResumeIsVerified() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Copilot",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "copilot",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .respawn)
        XCTAssertEqual(plan.first?.reason, "GitHub Copilot CLI will reopen from persisted checkpoint context")
    }

    func testCustomTerminalAgentRespawnsFromCheckpointContext() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Custom TUI",
            kind: .terminalAgent,
            agentKind: .custom,
            executable: "/bin/zsh",
            arguments: ["-lc", "aider --yes"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .respawn)
        XCTAssertEqual(plan.first?.reason, "custom terminal agent will reopen from persisted checkpoint context")
    }

    func testClaudeCodeWithoutSessionIdUsesLatestSessionFallback() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .autoResume)
        XCTAssertEqual(plan.first?.reason, "Claude Code can continue the most recent session in this working directory")
    }

    func testNativeResumePresetWithoutFallbackRequiresManualActionWithoutSessionID() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let preset = TerminalAgentPreset(
            id: .claudeCode,
            displayName: "Claude Code",
            executable: "claude",
            defaultArguments: [],
            yoloArguments: [],
            resumeStrategy: ResumeStrategy(kind: .nativeResumeCommand, notes: "native only")
        )

        let plan = RecoveryPlanner().planRecovery(for: entry, latestRun: run, presetFor: { _ in preset })

        XCTAssertEqual(plan.action, .manualActionNeeded)
        XCTAssertEqual(plan.reason, "Claude Code lacks a persisted session id")
    }

    func testManualPresetRequiresManualRecovery() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Manual Agent",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "manual",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let preset = TerminalAgentPreset(
            id: .claudeCode,
            displayName: "Manual Agent",
            executable: "manual",
            defaultArguments: [],
            yoloArguments: [],
            resumeStrategy: ResumeStrategy(kind: .manual, notes: "manual")
        )

        let plan = RecoveryPlanner().planRecovery(for: entry, latestRun: run, presetFor: { _ in preset })

        XCTAssertEqual(plan.action, .manualActionNeeded)
        XCTAssertEqual(plan.reason, "Manual Agent requires manual recovery")
    }

    func testUntrustedEntriesNeverAutoResume() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Untrusted",
            kind: .command,
            executable: "rm",
            arguments: ["-rf", "/tmp/example"],
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: true
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .noAction)
        XCTAssertEqual(plan.first?.reason, "no prior run to recover")
    }

    func testUntrustedNeedsRecoveryRequiresManualAction() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Untrusted",
            kind: .command,
            executable: "rm",
            arguments: ["-rf", "/tmp/example"],
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .manualActionNeeded)
        XCTAssertEqual(plan.first?.reason, "entry is not trusted")
    }

    func testExitedRunDoesNotRecover() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(entryId: entry.id, status: .exited, terminalSessionId: "claude-session-123")
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .noAction)
        XCTAssertEqual(plan.first?.reason, "latest run status is exited")
    }

    func testLiveSessionReattachesEvenWhenUntrustedAndNonAutoResume() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Hands-off",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: false
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])
        let live: Set<String> = [PersistentTerminalSession.sessionName(for: entry.id)]

        let plan = RecoveryPlanner().planRecovery(for: state, liveSessionNames: live)

        XCTAssertEqual(plan.first?.action, .reattach)
        XCTAssertEqual(plan.first?.reason, "session still running — reconnect the terminal")
    }

    func testLiveSessionReattachBeatsNativeResume() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery, terminalSessionId: "claude-session-123")
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])
        let live: Set<String> = [PersistentTerminalSession.sessionName(for: entry.id)]

        // A live session reattaches (lossless) instead of native-resuming a new one.
        XCTAssertEqual(RecoveryPlanner().planRecovery(for: state, liveSessionNames: live).first?.action, .reattach)
        // With no live session, the existing native-resume path is unchanged.
        XCTAssertEqual(RecoveryPlanner().planRecovery(for: state).first?.action, .autoResume)
    }

    // MARK: - Auto-launch-on-startup eligibility

    /// The original bug: a fresh `autoResume` shell with no prior run gets a
    /// `.noAction` ("no prior run to recover") plan, which is inert. Deduping
    /// against *all* plans excluded it; it must stay eligible to auto-launch.
    func testFreshAutoResumeEntryWithNoPriorRunIsEligibleToAutoLaunch() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Fresh shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry])
        let plans = RecoveryPlanner().planRecovery(for: state)
        // Sanity: the plan for this entry really is the inert no-op.
        XCTAssertEqual(plans.first?.action, .noAction)

        let eligible = RecoveryPlanner.autoLaunchEligibleEntries(
            entries: state.processEntries,
            recoveryPlans: plans,
            activeEntryIDs: []
        )

        XCTAssertEqual(eligible.map(\.id), [entry.id])
    }

    /// An entry whose live `screen` session survived gets a `.reattach` plan —
    /// startup recovery reconnects it losslessly, so auto-launch must NOT also
    /// launch it (that would double-launch / spawn a duplicate).
    func testEntryHandledByRecoveryReattachIsExcludedFromAutoLaunch() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Live agent",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])
        let live: Set<String> = [PersistentTerminalSession.sessionName(for: entry.id)]
        let plans = RecoveryPlanner().planRecovery(for: state, liveSessionNames: live)
        XCTAssertEqual(plans.first?.action, .reattach)

        let eligible = RecoveryPlanner.autoLaunchEligibleEntries(
            entries: state.processEntries,
            recoveryPlans: plans,
            activeEntryIDs: []
        )

        XCTAssertTrue(eligible.isEmpty)
    }

    /// A respawn plan is also a launch recovery performs, so it's deduped out.
    func testEntryHandledByRecoveryRespawnIsExcludedFromAutoLaunch() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Copilot",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "copilot",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])
        let plans = RecoveryPlanner().planRecovery(for: state)
        XCTAssertEqual(plans.first?.action, .respawn)

        let eligible = RecoveryPlanner.autoLaunchEligibleEntries(
            entries: state.processEntries,
            recoveryPlans: plans,
            activeEntryIDs: []
        )

        XCTAssertTrue(eligible.isEmpty)
    }

    func testAlreadyRunningEntryIsExcludedFromAutoLaunch() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Already up",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry])
        let plans = RecoveryPlanner().planRecovery(for: state)

        let eligible = RecoveryPlanner.autoLaunchEligibleEntries(
            entries: state.processEntries,
            recoveryPlans: plans,
            activeEntryIDs: [entry.id]
        )

        XCTAssertTrue(eligible.isEmpty)
    }

    func testNonAutoResumeArchivedAndNonLaunchableKindsAreExcludedFromAutoLaunch() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let notAutoResume = ProcessEntry(
            projectId: project.id,
            name: "Manual shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: false
        )
        let archived = ProcessEntry(
            projectId: project.id,
            name: "Archived shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true,
            isArchived: true
        )
        // A one-shot command is not a resumable terminal, so it never auto-launches.
        let command = ProcessEntry(
            projectId: project.id,
            name: "One-shot",
            kind: .command,
            executable: "ls",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let eligibleShell = ProcessEntry(
            projectId: project.id,
            name: "Eligible shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let entries = [notAutoResume, archived, command, eligibleShell]
        let state = WorkspaceState(projects: [project], processEntries: entries)
        let plans = RecoveryPlanner().planRecovery(for: state)

        let eligible = RecoveryPlanner.autoLaunchEligibleEntries(
            entries: state.processEntries,
            recoveryPlans: plans,
            activeEntryIDs: []
        )

        XCTAssertEqual(eligible.map(\.id), [eligibleShell.id])
    }

    func testStartupRecoveryHandledEntryIDsExcludesInertPlans() {
        let reattachId = UUID()
        let autoResumeId = UUID()
        let respawnId = UUID()
        let manualId = UUID()
        let noActionId = UUID()
        let plans = [
            RecoveryPlan(entryId: reattachId, runId: nil, action: .reattach, reason: ""),
            RecoveryPlan(entryId: autoResumeId, runId: nil, action: .autoResume, reason: ""),
            RecoveryPlan(entryId: respawnId, runId: nil, action: .respawn, reason: ""),
            RecoveryPlan(entryId: manualId, runId: nil, action: .manualActionNeeded, reason: ""),
            RecoveryPlan(entryId: noActionId, runId: nil, action: .noAction, reason: ""),
        ]

        let handled = RecoveryPlanner.startupRecoveryHandledEntryIDs(plans)

        XCTAssertEqual(handled, [reattachId, autoResumeId, respawnId])
    }

    func testArchivedEntryDoesNotRecoverEvenWithNeedsRecoveryRun() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Archived",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "aider --yes"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true,
            isArchived: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .noAction)
        XCTAssertEqual(plan.first?.reason, "entry is archived")
    }
}
