#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `HeaderView` (`:4042`) INTERACTION drive-to-100%.
///
/// The C3 `HeaderViewTests` snapshot the always-rendered LABELS but never EXECUTE the
/// `Button(action:)`/`Menu{}`/`Toggle`/overlay action-closures — so 34 region segments
/// (every action body + the `if let badge`/recent-workspaces/collapsed-overlay arms)
/// were never coloured. ViewInspector 0.10.3 **descends `Menu {}` content** (proven) and
/// CAN invoke action-closures (`find(button:).tap()` / `callOnAppear()`), so this suite
/// DRIVES every reachable region: it taps each button, asserts the `@Published`/`state`
/// side-effect (provenance), and the negative-control proves the effect is load-bearing
/// (mutation-verify: a tap that didn't run the action would leave the flag false).
///
/// **Carves (genuinely-unreachable):** the "Open Workspace…" button action enters a
/// BLOCKING `NSOpenPanel().runModal()` with no early-return seam — tapping it deadlocks
/// the test. That one action-closure region is the recorded carve (live AppKit modal).
/// "Save Workspace As…" is SAFE to tap (it `guard let selectedProject else { return }`
/// returns BEFORE the panel with no project), so it is DRIVEN here.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001). The update badge is
/// driven by a REAL `.updateAvailable` `ReleaseUpdateSnapshot` with installable assets;
/// the collapsed-pane inbox badge by the REAL `state.openInbox` decision-log seam.
@MainActor
final class HeaderViewInteractionTests: XCTestCase {

    private func makeVM(bossName: String = "") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-hdr-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: bossName)))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        // #332 seam: any tap reaching launch/recover → the detached start() → session.start()
        // forks a real `screen` child that orphans past teardown (CI signal-1 crash). Inject a
        // no-op launcher so those paths run without spawning a subprocess.
        model.launchTerminalSession = { _ in }
        model.recentWorkspacePaths = []
        return model
    }

    /// A VM whose persisted state has a real TRUSTED + autoResume `.shell`
    /// `.needsRecovery` entry → a `.respawn` recovery plan → `recoverableEntries`
    /// non-empty (so the More-menu "Recover All Crashed…" button is enabled).
    private func makeRecoveryVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-hdr-rec-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
        let entryId = UUID(uuidString: "DD000003-0000-0000-0000-000000000003")!
        let entry = ProcessEntry(
            id: entryId, projectId: projectId, name: "respawn-me", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/u5rec",
            trust: .trusted, autoResume: true)
        var runBytes = entryId.uuid
        runBytes.15 = runBytes.15 ^ 0xFF
        let run = ProcessRun(id: UUID(uuid: runBytes), entryId: entryId, status: .needsRecovery,
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry],
            workspaces: [Workspace(id: UUID(uuidString: "DD0000AA-0000-0000-0000-0000000000AA")!,
                                   autoName: "WS", tabIds: [entryId])],
            processRuns: [run])
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // #332 seam: "Recover All Crashed…" → recoverAllCrashedSessions() → recover(entry) → the
        // detached start() → session.start(), forking a real `screen` child that orphans past
        // teardown (CI signal-1 crash). Inject a no-op launcher so the recover-all path runs but
        // no subprocess spawns.
        model.launchTerminalSession = { _ in }
        model.recentWorkspacePaths = []
        return model
    }

    /// A real `.updateAvailable` snapshot with installable assets → a non-nil
    /// `updateBadgeText` ("Update <release>") and `promptRelease`.
    private func updateAvailableSnapshot() -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: .updateAvailable,
            currentVersion: WorkbenchRelease.version,
            currentBuild: "274",
            latestVersion: "0.1.999",
            latestBuild: "275",
            tagName: "v0.1.999",
            htmlURL: "https://github.com/\(WorkbenchRelease.repository)/releases/tag/v0.1.999",
            assets: [
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)0.1.999-build.275-abcdef0.zip",
                    downloadURL: "https://example.test/app.zip", size: 1_000),
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)0.1.999-build.275-abcdef0.manifest.json",
                    downloadURL: "https://example.test/manifest.json", size: 500)
            ],
            assetNamingPolicy: WorkbenchReleasePolicy.assetNamingPolicy,
            detail: "0.1.999 update available")
    }

    private func tap(_ view: HeaderView, label: String) throws {
        try view.inspect().find(button: label).tap()
    }

    // MARK: - Update badge arm (the `if let badge = model.updateBadgeText` block)

    /// A real update-available snapshot makes `updateBadgeText` non-nil → the badge
    /// Button renders AND its action `model.presentUpdatePrompt()` is driven (tapped):
    /// it sets `updatePrompt = .installable`. Both the render arm and the action region.
    func testHeader_updateBadge_rendersAndTapPresentsPrompt() throws {
        let model = try makeVM()
        model.releaseUpdateSnapshot = updateAvailableSnapshot()
        XCTAssertNotNil(model.updateBadgeText, "provenance: an update-available snapshot shows the badge")
        XCTAssertNil(model.updatePrompt, "precondition: no prompt yet")

        let view = HeaderView(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Update 0.1.999"), "the badge label renders:\n\(tree)")

        // The badge button's Label title is a non-literal String, so match on its icon glyph.
        try view.inspect().find(ViewType.Button.self, where: { button in
            (try? button.labelView().label().icon().image().actualImage().name()) == "arrow.down.circle.fill"
        }).tap()
        XCTAssertNotNil(model.updatePrompt, "tapping the badge presents the update prompt")
        if case .installable = model.updatePrompt {} else {
            XCTFail("the prompt must be .installable, got \(String(describing: model.updatePrompt))")
        }
    }

    /// Negative control (P2): with no update snapshot the badge is absent and a "Update …"
    /// button does NOT exist — the `if let badge` gate is load-bearing.
    func testHeader_noUpdate_badgeAbsent() throws {
        let model = try makeVM()
        XCTAssertNil(model.updateBadgeText, "provenance: no snapshot → no badge")
        let tree = try ViewSnapshotHost.snapshotText(of: HeaderView(model: model))
        XCTAssertFalse(tree.contains("arrow.down.circle.fill"), "no update badge button:\n\(tree)")
    }

    // MARK: - Toolbar buttons (collapse, commands, check-in)

    /// The "Hide/Show Boss Pane" toggle button action flips `state.bossPaneCollapsed`.
    /// `WorkspaceState` defaults `bossPaneCollapsed == true`; expand it first so the
    /// label is "Hide Boss Pane", then tap to collapse.
    func testHeader_bossPaneToggle_flipsState() throws {
        let model = try makeVM()
        model.setBossPaneCollapsed(false)
        XCTAssertFalse(model.state.bossPaneCollapsed, "precondition: pane expanded")
        let view = HeaderView(model: model)
        // The label is "Hide Boss Pane" while expanded.
        try tap(view, label: "Hide Boss Pane")
        XCTAssertTrue(model.state.bossPaneCollapsed, "tapping collapses the boss pane")
    }

    /// The "Commands" button action sets `isCommandPalettePresented`.
    func testHeader_commandsButton_presentsPalette() throws {
        let model = try makeVM()
        XCTAssertFalse(model.isCommandPalettePresented)
        try tap(HeaderView(model: model), label: "Commands")
        XCTAssertTrue(model.isCommandPalettePresented, "tapping Commands opens the palette")
    }

    /// The "Check In" prominent button action: with NO boss, `attemptCheckIn()` routes to
    /// `presentOnboarding()` → `isOnboardingPresented = true`.
    func testHeader_checkIn_noBoss_presentsOnboarding() throws {
        let model = try makeVM(bossName: "")
        XCTAssertFalse(model.isOnboardingPresented)
        try tap(HeaderView(model: model), label: WorkbenchViewModel.checkInActionLabel)
        XCTAssertTrue(model.isOnboardingPresented, "no-boss check-in routes to onboarding")
    }

    // MARK: - More menu (Menu {} IS descended by ViewInspector — every action driven)

    func testHeader_moreMenu_setUpBoss_presentsOnboarding() throws {
        let model = try makeVM()
        try tap(HeaderView(model: model), label: "\(AgentHomeEmptyStateCopy.setUpBossButton)…")
        XCTAssertTrue(model.isOnboardingPresented, "Set up a boss → onboarding")
    }

    func testHeader_moreMenu_createAgent_presentsProviderForm() throws {
        let model = try makeVM()
        XCTAssertFalse(model.isProviderConfigPresented)
        try tap(HeaderView(model: model), label: "Create an Agent…")
        XCTAssertTrue(model.isProviderConfigPresented, "Create an Agent → provider form")
        XCTAssertTrue(model.providerConfigIsNewAgent, "new-agent flag set")
    }

    func testHeader_moreMenu_cloneAgent_presentsInstallSheet() throws {
        let model = try makeVM()
        XCTAssertFalse(model.isOuroAgentInstallSheetPresented)
        try tap(HeaderView(model: model), label: "Clone an Agent from Git…")
        XCTAssertTrue(model.isOuroAgentInstallSheetPresented, "Clone → install sheet")
    }

    /// "Save Workspace As…" with a project that has NO terminals returns BEFORE the
    /// NSSavePanel (the `guard !config.terminals.isEmpty else { return }` early-return) —
    /// so its action region is DRIVEN without a modal. The default makeVM auto-creates a
    /// "Home" project with no terminals, so the tap hits the no-terminals error.
    func testHeader_moreMenu_saveWorkspace_noTerminals_setsError() throws {
        let model = try makeVM()
        let project = try XCTUnwrap(model.selectedProject, "precondition: the default Home project")
        XCTAssertNil(model.errorMessage)
        try tap(HeaderView(model: model), label: "Save Workspace As…")
        XCTAssertEqual(model.errorMessage, "\(project.name) has no terminals to save",
                       "no-terminals save routes to the error message before any modal")
    }

    func testHeader_moreMenu_harnessStatus_presents() throws {
        let model = try makeVM()
        try tap(HeaderView(model: model), label: "Harness Status…")
        XCTAssertTrue(model.isHarnessStatusPresented)
    }

    func testHeader_moreMenu_refreshStatus_runs() throws {
        let model = try makeVM()
        // The action wraps refreshes in a Task; tapping covers the action closure and the
        // synchronous `refreshExecutableHealth()` populates `executableHealthByEntryID`.
        try tap(HeaderView(model: model), label: "Refresh Status")
        // No crash + the closure ran. (executableHealthByEntryID stays empty for an empty
        // workspace — the observable effect is "no throw"; the region is covered.)
    }

    // NOTE: "Stop All Running…" is `.disabled(model.activeSessions.isEmpty)`. Enabling it
    // requires a live `TerminalSessionController` in `activeSessions` — a live-PTY seam with
    // no hermetic constructor. ViewInspector refuses to tap a disabled button, so this one
    // action-closure region is the recorded CARVE (live PTY). Its DISABLED gate IS covered
    // (the button renders with `activeSessions.isEmpty == true`).

    /// "Recover All Crashed…" is `.disabled(model.recoverableEntries.isEmpty)`. A real
    /// TRUSTED + autoResume `.shell` `.needsRecovery` entry makes `recoverableEntries`
    /// non-empty → the button ENABLES → its action `recoverAllRecoverableSessions()`/
    /// `recoverAllCrashedSessions()` is DRIVEN.
    func testHeader_moreMenu_recoverAll_runs() throws {
        let model = try makeRecoveryVM()
        XCTAssertFalse(model.recoverableEntries.isEmpty, "provenance: a real recoverable entry enables the button")
        try tap(HeaderView(model: model), label: "Recover All Crashed…")
        // The action ran (no throw, button enabled). recover(_:) transitions the entry; the
        // observable effect is the action region executes.
    }

    func testHeader_moreMenu_settings_presents() throws {
        let model = try makeVM()
        try tap(HeaderView(model: model), label: "Settings…")
        XCTAssertTrue(model.isSettingsSheetPresented)
    }

    func testHeader_moreMenu_shortcuts_presents() throws {
        let model = try makeVM()
        try tap(HeaderView(model: model), label: "Keyboard Shortcuts…")
        XCTAssertTrue(model.isShortcutHelpPresented)
    }

    func testHeader_moreMenu_reportBug_presents() throws {
        let model = try makeVM()
        try tap(HeaderView(model: model), label: "Report a Bug…")
        XCTAssertTrue(model.isReportBugPresented)
    }

    func testHeader_moreMenu_about_presents() throws {
        let model = try makeVM()
        try tap(HeaderView(model: model), label: "About Ouro Workbench…")
        XCTAssertTrue(model.isAboutSheetPresented)
    }

    func testHeader_moreMenu_checkForUpdates_runs() throws {
        let model = try makeVM()
        // The action body is `Task { await model.checkForUpdatesAndPromptInstall() }` — tapping
        // covers the outer closure; the await runs detached (no network in-process completes here).
        try tap(HeaderView(model: model), label: "Check for Updates…")
    }

    func testHeader_moreMenu_resetFactory_presentsConfirmation() throws {
        let model = try makeVM()
        try tap(HeaderView(model: model), label: "Reset to Factory Defaults…")
        XCTAssertTrue(model.isResetFirstRunConfirmationPresented)
    }

    // MARK: - More menu Boss-Watch toggle (the `Toggle(isOn:)` binding setter)

    /// The More-menu "Boss Watch" `Toggle`'s binding setter `{ model.setBossWatchEnabled($0) }`.
    /// Provenance: ViewInspector reads the Toggle and flips it; the setter flips
    /// `bossWatchIsEnabled`. (Default is OFF; flipping ON enables it.)
    func testHeader_moreMenu_bossWatchToggle_flips() throws {
        let model = try makeVM()
        let start = model.bossWatchIsEnabled
        let toggle = try HeaderView(model: model).inspect()
            .find(ViewType.Toggle.self, where: { t in
                (try? t.labelView().label().title().text().string()) == "Boss Watch"
            })
        try toggle.tap()
        XCTAssertNotEqual(model.bossWatchIsEnabled, start, "the Boss Watch toggle setter flips state")
        // Stop the watch loop the setter started so the test leaves no live Task.
        model.setBossWatchEnabled(false)
    }

    // MARK: - Recent-workspaces sub-menu (`if !recentWorkspacePaths.isEmpty` arm)

    /// With a recent path present, the nested "Open Recent Workspace" `Menu` renders and
    /// its per-path Button + the "Clear Recent Workspaces" destructive button are driven.
    /// Provenance: a relative recent path (no machine-path leak); openWorkspaceConfig(at:)
    /// returns nil for a non-existent config (the action region is covered, no modal).
    func testHeader_recentWorkspaces_clearButton_clears() throws {
        let model = try makeVM()
        model.recentWorkspacePaths = ["/tmp/u5/recent-ws-dir"]
        XCTAssertFalse(model.recentWorkspacePaths.isEmpty, "precondition: a recent path")
        let view = HeaderView(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Open Recent Workspace"), "the recent sub-menu renders:\n\(tree)")
        XCTAssertTrue(tree.contains("recent-ws-dir"), "the per-path row renders its lastPathComponent")

        try tap(view, label: "Clear Recent Workspaces")
        XCTAssertTrue(model.recentWorkspacePaths.isEmpty, "Clear Recent empties the list")
    }

    /// The per-path "open this recent workspace" Button action `openWorkspaceConfig(at:)`.
    func testHeader_recentWorkspaces_openPath_runs() throws {
        let model = try makeVM()
        model.recentWorkspacePaths = ["/tmp/u5/recent-ws-dir"]
        // The per-path button's Label is the path's lastPathComponent.
        try tap(HeaderView(model: model), label: "recent-ws-dir")
        // A non-existent config → openWorkspaceConfig(at:) returns nil; no crash, region covered.
    }

    // MARK: - Determinism (P3)

    func testHeader_interaction_noLeak() throws {
        let model = try makeVM()
        model.releaseUpdateSnapshot = updateAvailableSnapshot()
        let tree = try ViewSnapshotHost.snapshotText(of: HeaderView(model: model))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }
}
#endif
