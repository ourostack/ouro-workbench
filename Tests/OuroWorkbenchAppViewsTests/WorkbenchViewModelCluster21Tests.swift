#if os(macOS)
import XCTest
import OuroWorkbenchCore
import SwiftUI
import SwiftTerm
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 21 — the computed-var micro-tail (the dispatch + status-line decls are driven).
///
/// Drives the still-untested directly-callable computed properties — `Binding<Bool>` get+set arms,
/// nil-guard folds, and pure delegations the view tests never exercised. Every one is pure logic.
///   • `errorIsPresented` / `deleteConfirmationIsPresented` / `deleteGroupConfirmationIsPresented`
///     (`:~`) — the `Binding<Bool>` get (underlying != nil) + the set-to-false clear arm.
///   • `onboardingHasConfigGap` (`:~`) — the nil-readiness guard + the repair-step contains check.
///   • `recentActionLogEntries` — the sort fold.
///   • `releaseUpdateURL` / `canAutoPresentOnboardingOnLaunch` / `currentSearchOptions` /
///     `bossMCPCommand` — pure delegations.
@MainActor
final class WorkbenchViewModelCluster21Tests: XCTestCase {

    private static let projectId = UUID(uuidString: "C21F1A00-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C21F1A00-0000-0000-0000-0000000000B1")!

    private func makeVM(boss: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmcluster21-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        try FileManager.default.createDirectory(at: agentBundles, withIntermediateDirectories: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [])])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        m.terminateApp = {}
        return m
    }

    // MARK: - errorIsPresented (Binding get + set-clear)

    func testErrorIsPresented_getAndClear() throws {
        let m = try makeVM()
        XCTAssertFalse(m.errorIsPresented.wrappedValue, "no error → binding reads false")
        m.errorMessage = "boom"
        XCTAssertTrue(m.errorIsPresented.wrappedValue, "an error → binding reads true")
        // The set-to-false arm clears the underlying error.
        m.errorIsPresented.wrappedValue = false
        XCTAssertNil(m.errorMessage, "dismissing the binding clears the error message")
    }

    // MARK: - deleteConfirmationIsPresented (Binding get + set-clear)

    func testDeleteConfirmationIsPresented_getAndClear() throws {
        let m = try makeVM()
        XCTAssertFalse(m.deleteConfirmationIsPresented.wrappedValue, "no pending delete → false")
        m.pendingDeleteSession = ProcessEntry(
            projectId: Self.projectId, name: "x", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp", trust: .trusted)
        XCTAssertTrue(m.deleteConfirmationIsPresented.wrappedValue, "a pending delete → true")
        m.deleteConfirmationIsPresented.wrappedValue = false
        XCTAssertNil(m.pendingDeleteSession, "dismissing clears the pending delete")
    }

    // MARK: - deleteGroupConfirmationIsPresented (Binding get + set-clear)

    func testDeleteGroupConfirmationIsPresented_getAndClear() throws {
        let m = try makeVM()
        XCTAssertFalse(m.deleteGroupConfirmationIsPresented.wrappedValue, "no pending group delete → false")
        m.pendingDeleteGroup = WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")
        XCTAssertTrue(m.deleteGroupConfirmationIsPresented.wrappedValue, "a pending group delete → true")
        m.deleteGroupConfirmationIsPresented.wrappedValue = false
        XCTAssertNil(m.pendingDeleteGroup, "dismissing clears the pending group delete")
    }

    // MARK: - stopConfirmationIsPresented (Binding get + set-clear)

    func testStopConfirmationIsPresented_getAndClear() throws {
        let m = try makeVM()
        XCTAssertFalse(m.stopConfirmationIsPresented.wrappedValue, "no pending stop → false")
        m.pendingStopSession = ProcessEntry(
            projectId: Self.projectId, name: "x", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp", trust: .trusted)
        XCTAssertTrue(m.stopConfirmationIsPresented.wrappedValue, "a pending stop → true")
        m.stopConfirmationIsPresented.wrappedValue = false
        XCTAssertNil(m.pendingStopSession, "dismissing clears the pending stop")
    }

    // MARK: - onboardingHasConfigGap (nil-guard + contains, both arms)

    func testOnboardingHasConfigGap_nilReadiness_isFalse() throws {
        let m = try makeVM()
        m.onboardingReadiness = nil
        XCTAssertFalse(m.onboardingHasConfigGap, "no readiness → no config gap")
    }

    func testOnboardingHasConfigGap_noBlockerSteps_isFalse() throws {
        let m = try makeVM()
        m.onboardingReadiness = OnboardingReadiness(
            state: .ready, headline: "Ready", detail: "", selectedBossName: "boss", repairSteps: [])
        XCTAssertFalse(m.onboardingHasConfigGap, "ready with no repair steps → no config gap")
    }

    func testOnboardingHasConfigGap_blockerStep_isTrue() throws {
        let m = try makeVM()
        // A `workbench-mcp` repair step is one of the config-gap blocker IDs → the contains arm is true.
        let blocker = OnboardingRepairStep(
            id: "workbench-mcp", actor: .humanRequired,
            title: "Connect Workbench tools", detail: "needed")
        m.onboardingReadiness = OnboardingReadiness(
            state: .needsRepair, headline: "Setup", detail: "", selectedBossName: "boss",
            repairSteps: [blocker])
        XCTAssertTrue(m.onboardingHasConfigGap, "a config-gap blocker repair step → config gap")
    }

    // MARK: - deskBridgePlan (delegation per kind)

    func testDeskBridgePlan_delegatesPerKind() throws {
        let m = try makeVM()
        // The delegation evaluates for each kind (the planner returns a plan or nil).
        for kind in TerminalAgentKind.allCases {
            _ = m.deskBridgePlan(for: kind)
        }
    }

    // MARK: - recentActionLogEntries (sort fold)

    func testRecentActionLogEntries_sortedNewestFirst() throws {
        let m = try makeVM()
        // Seed the log out-of-order (older first) so the fold's sort is observable.
        let older = WorkbenchActionLogEntry(
            occurredAt: Date(timeIntervalSince1970: 1_000), source: "native",
            action: "first", result: "r1", succeeded: true)
        let newer = WorkbenchActionLogEntry(
            occurredAt: Date(timeIntervalSince1970: 2_000), source: "native",
            action: "second", result: "r2", succeeded: true)
        m.state.actionLog = [older, newer]
        let entries = m.recentActionLogEntries
        XCTAssertEqual(entries.map(\.action), ["second", "first"],
                       "recentActionLogEntries sorts newest-first")
    }

    // MARK: - pure delegations

    func testReleaseUpdateURL_delegates() throws {
        let m = try makeVM()
        // No staged update → the presentation has no release URL; the delegation still evaluates.
        _ = m.releaseUpdateURL
        XCTAssertNil(m.releaseUpdateURL, "with no update surfaced the release URL delegation is nil")
    }

    func testCanAutoPresentOnboardingOnLaunch_delegates() throws {
        let m = try makeVM()
        // Invokes the OnboardingPresentationPolicy delegation (the value depends on first-run state).
        _ = m.canAutoPresentOnboardingOnLaunch
    }

    func testCurrentSearchOptions_reflectsToggles() throws {
        let m = try makeVM()
        m.terminalSearchCaseSensitive = true
        m.terminalSearchRegex = true
        m.terminalSearchWholeWord = true
        let options = m.currentSearchOptions
        XCTAssertTrue(options.caseSensitive, "the case-sensitive toggle flows into the search options")
        XCTAssertTrue(options.regex, "the regex toggle flows into the search options")
        XCTAssertTrue(options.wholeWord, "the whole-word toggle flows into the search options")
    }

    func testBossMCPCommand_delegates() throws {
        let m = try makeVM()
        // The MCP serve-plan delegation builds a non-empty display command for the boss.
        XCTAssertFalse(m.bossMCPCommand.isEmpty, "the boss MCP command delegation returns a command")
    }
}
#endif
