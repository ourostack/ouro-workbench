import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchSurfacePolicyTests: XCTestCase {
    func testSidebarPrimaryLabelsUseWorkbenchStoryNouns() {
        XCTAssertEqual(WorkbenchSurfacePolicy.workspaceSectionTitle, "Workspaces")
        XCTAssertEqual(WorkbenchSurfacePolicy.newWorkspaceTitle, "New Workspace")
        XCTAssertEqual(WorkbenchSurfacePolicy.newWorkspaceSheetTitle, "New Workspace")
        XCTAssertEqual(WorkbenchSurfacePolicy.editWorkspaceSheetTitle, "Edit Workspace")
        XCTAssertEqual(WorkbenchSurfacePolicy.bossSectionTitle, "Boss")
    }

    func testWorkspaceManagementCopyUsesWorkspaceNouns() {
        XCTAssertEqual(WorkbenchSurfacePolicy.workspaceNameRequiredMessage, "Workspace name is required")
        XCTAssertEqual(WorkbenchSurfacePolicy.workspaceRootPathRequiredMessage, "Workspace root path is required")
        XCTAssertEqual(WorkbenchSurfacePolicy.noWorkspaceSelectedToSaveMessage, "No workspace is selected to save")
        XCTAssertEqual(WorkbenchSurfacePolicy.workspaceNoLongerExistsMessage(name: "Fixture"), "Workspace no longer exists: Fixture")
        XCTAssertEqual(WorkbenchSurfacePolicy.keepAtLeastOneWorkspaceMessage, "Keep at least one workspace")
        XCTAssertEqual(
            WorkbenchSurfacePolicy.moveOrDeleteTerminalsBeforeDeletingMessage(name: "Fixture"),
            "Move or delete terminals before deleting Fixture"
        )
    }

    func testAppWorkspaceCopyIsWiredThroughSurfacePolicy() throws {
        let source = try appSource()

        XCTAssertTrue(source.contains("Section(WorkbenchSurfacePolicy.bossSectionTitle)"))
        XCTAssertTrue(source.contains("Section(WorkbenchSurfacePolicy.workspaceSectionTitle)"))
        XCTAssertTrue(source.contains("SidebarActionRow(title: WorkbenchSurfacePolicy.newWorkspaceTitle"))
        XCTAssertTrue(source.contains("WorkbenchSurfacePolicy.shouldShowRecovery(recoverableCount: model.recoveryDigest.actionableCount)"))
        XCTAssertFalse(source.contains("New Terminal Group"))
        XCTAssertFalse(source.contains("Edit Terminal Group"))
        XCTAssertFalse(source.contains("Group name is required"))
        XCTAssertFalse(source.contains("Group root path is required"))
        XCTAssertFalse(source.contains("No group is selected to save"))
        XCTAssertFalse(source.contains("Keep at least one terminal group"))
    }

    func testEmptyStateLeadsTerminalsFirstWithBossAsOptIn() throws {
        // The subtractive FRE redesign inverts the old boss-first empty state: it now
        // leads with purpose + `New Terminal` (the prominent, gate-free primary) and makes
        // the boss a secondary opt-in. The copy lives in Core (AgentHomeEmptyStateCopy) so
        // the view renders it through those constants rather than as raw literals.
        let source = try appSource()
        let emptyState = try sourceSlice(
            in: source,
            from: "struct AgentHomeEmptyState: View",
            to: "                if !model.ouroAgents.isEmpty {"
        )

        // The old boss-first headline / button label are gone.
        XCTAssertFalse(emptyState.contains("Text(\"Set up Workbench\")"))
        XCTAssertFalse(emptyState.contains("Label(\"Set Up Workbench\""))

        // Headline + subtext are wired through the Core copy seam, not view literals.
        XCTAssertTrue(emptyState.contains("Text(AgentHomeEmptyStateCopy.headline)"))
        XCTAssertTrue(emptyState.contains("Text(AgentHomeEmptyStateCopy.subtext)"))

        // New Terminal is the prominent primary and leads the button row; the boss
        // opt-in ("Set up a boss") comes after it and uses a plain bordered style.
        let newTerminalLabel = try XCTUnwrap(
            emptyState.range(of: "Label(AgentHomeEmptyStateCopy.newTerminalButton")
        )
        let setUpBossLabel = try XCTUnwrap(
            emptyState.range(of: "Label(AgentHomeEmptyStateCopy.setUpBossButton")
        )
        XCTAssertLessThan(newTerminalLabel.lowerBound, setUpBossLabel.lowerBound)

        // The prominent style attaches to New Terminal only — assert it appears between the
        // New Terminal label and the Set up a boss label (i.e. on the primary button).
        let prominent = try XCTUnwrap(
            emptyState.range(of: ".buttonStyle(.borderedProminent)", range: newTerminalLabel.upperBound..<emptyState.endIndex)
        )
        XCTAssertLessThan(prominent.lowerBound, setUpBossLabel.lowerBound)
    }

    func testTitleStripUsesSessionControlPolicyWithoutPrimaryRestartLeak() throws {
        let source = try appSource()
        let titleStrip = try sourceSlice(
            in: source,
            from: "private struct SessionTitleStrip: View",
            to: "    @ViewBuilder\n    private var statusDot: some View"
        )

        XCTAssertTrue(titleStrip.contains("RunningSessionHeaderControls(entry: entry, model: model)"))
        XCTAssertFalse(titleStrip.contains("if model.activeSession(for: entry) != nil {\n                    RunningSessionHeaderControls"))
        XCTAssertFalse(titleStrip.contains("model.activeSession(for: entry) == nil ? \"Launch\" : \"Restart\""))
        XCTAssertFalse(source.contains("Move this session to another group"))
    }

    func testSetupWorkspaceNameIsNeutralHomeNotUnsortedOrThisMac() {
        // U32: the default workspace is a neutral "Home", not the state-claiming
        // "Unsorted Sessions" (nor "This Mac").
        XCTAssertEqual(WorkbenchSurfacePolicy.setupWorkspaceName, "Home")
        XCTAssertNotEqual(WorkbenchSurfacePolicy.setupWorkspaceName, "Unsorted Sessions")
        XCTAssertNotEqual(WorkbenchSurfacePolicy.setupWorkspaceName, "This Mac")
    }

    func testBossStatusLabelsStayCompact() {
        XCTAssertEqual(WorkbenchSurfacePolicy.bossStatus(agentName: "", isReady: false), "Choose boss")
        XCTAssertEqual(WorkbenchSurfacePolicy.bossStatus(agentName: "slugger", isReady: true), "slugger ready")
        XCTAssertEqual(WorkbenchSurfacePolicy.bossStatus(agentName: "slugger", isReady: false), "slugger setup needed")
    }

    func testRecoverySectionIsHiddenWhenThereIsNothingActionable() {
        XCTAssertFalse(WorkbenchSurfacePolicy.shouldShowRecovery(recoverableCount: 0))
    }

    func testRecoverySectionIsShownWhenActionable() {
        XCTAssertTrue(WorkbenchSurfacePolicy.shouldShowRecovery(recoverableCount: 2))
    }

    func testParseSidebarSessionControlsFixtureAction() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--write-e2e-state",
            "sidebar-session-controls",
            "/tmp/workspace-state.json"
        ])

        XCTAssertEqual(
            diagnostics.action,
            .writeE2EState(.sidebarSessionControls, URL(fileURLWithPath: "/tmp/workspace-state.json"))
        )
    }

    func testParseSidebarSessionControlsFixtureRequiresPath() {
        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--write-e2e-state",
            "sidebar-session-controls"
        ]))
    }

    func testRunningSessionShowsOnlyStopAsPrimaryAction() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: true, isArchived: false, isRecoverable: false)

        XCTAssertEqual(policy.primaryActions, [.stop])
        XCTAssertEqual(policy.advancedActions, [.focus, .redraw, .restart, .controlC, .escape, .eof])
    }

    func testStoppedSessionShowsLaunchAsPrimaryAction() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: false, isArchived: false, isRecoverable: false)

        XCTAssertEqual(policy.primaryActions, [.launch])
        XCTAssertTrue(policy.advancedActions.isEmpty)
    }

    func testRecoverableSessionShowsRecoverAsPrimaryAction() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: false, isArchived: false, isRecoverable: true)

        XCTAssertEqual(policy.primaryActions, [.recover])
        XCTAssertTrue(policy.advancedActions.isEmpty)
    }

    func testArchivedSessionShowsNoPrimaryOrAdvancedActions() {
        let policy = WorkbenchSurfacePolicy.sessionControls(isRunning: false, isArchived: true, isRecoverable: false)

        XCTAssertTrue(policy.primaryActions.isEmpty)
        XCTAssertTrue(policy.advancedActions.isEmpty)
    }

    // MARK: - U11: Stop confirmation gate (keyed on run/attention state)

    func testStopNeedsConfirmationForALiveHoldingAgent() {
        // A live process holding context — running, parked on a prompt, stuck, or
        // flagged for review — must confirm before being killed: something real
        // is lost.
        for attention in [AttentionState.active, .waitingOnHuman, .blocked, .needsBossReview] {
            XCTAssertTrue(
                WorkbenchSurfacePolicy.stopNeedsConfirmation(isLiveProcess: true, attention: attention),
                "expected confirmation for live \(attention.rawValue)"
            )
        }
    }

    func testStopDoesNotConfirmWhenNoLiveProcess() {
        // Idle / finished / never-started: nothing is lost, so stop is frictionless
        // regardless of the stored attention.
        for attention in [AttentionState.active, .waitingOnHuman, .blocked, .needsBossReview, .idle] {
            XCTAssertFalse(
                WorkbenchSurfacePolicy.stopNeedsConfirmation(isLiveProcess: false, attention: attention),
                "expected no confirmation when there's no live process (\(attention.rawValue))"
            )
        }
    }

    func testStopDoesNotConfirmForABareIdleLiveShell() {
        // A live but plainly-idle shell parked at its prompt holds no agent context
        // — stopping it is frictionless.
        XCTAssertFalse(WorkbenchSurfacePolicy.stopNeedsConfirmation(isLiveProcess: true, attention: .idle))
    }

    func testStopConfirmationCopyNamesTheSessionAndStatesTheConsequence() {
        XCTAssertEqual(
            WorkbenchSurfacePolicy.stopConfirmationTitle(name: "claude-fix-bug"),
            "Stop claude-fix-bug?"
        )
        let message = WorkbenchSurfacePolicy.stopConfirmationMessage
        XCTAssertTrue(message.contains("ends the running agent"))
        XCTAssertTrue(message.contains("live context"))
    }

    func testStopConfirmationButtonNamesTheSession() {
        XCTAssertEqual(
            WorkbenchSurfacePolicy.stopConfirmationButton(name: "claude-fix-bug"),
            "Stop claude-fix-bug"
        )
    }

    func testStopCallSitesRouteThroughTheConfirmationGate() throws {
        // U11: every human Stop entry point — the ⌘. chord and the Stop buttons —
        // must go through requestStop (the consequence gate), never call
        // model.terminate(entry) directly, so a reflexive chord can't nuke a live
        // agent. (The bulk Stop-All / reset / boss-MCP paths intentionally keep
        // calling terminate directly and are asserted elsewhere by behavior.)
        let source = try appSource()

        // The ⌘. menu chord handler is gated.
        XCTAssertTrue(source.contains("if let entry = model.activeEntry { model.requestStop(entry) }"))
        XCTAssertFalse(source.contains("if let entry = model.activeEntry { model.terminate(entry) }"))

        // The Stop buttons call requestStop.
        XCTAssertFalse(
            source.contains("Button(role: .destructive) {\n                    model.terminate(entry)"),
            "no Stop button calls model.terminate directly"
        )
        XCTAssertTrue(source.contains("model.requestStop(entry)"))

        // The menubar / palette Stop-Selected command is gated too.
        XCTAssertTrue(source.contains("requestStop(selectedEntry)"))
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}
