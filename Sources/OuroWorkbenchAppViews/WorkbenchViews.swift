#if os(macOS)
import AppKit
import Darwin
import OuroAppShellUI
import OuroWorkbenchCore
import OuroWorkbenchShellAdapter
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension Date {
    /// Render an absolute timestamp through `Date.FormatStyle` with an **explicit,
    /// injectable** `TimeZone` *and* `Locale` — the shared seam every body-evaluated
    /// timestamp row uses (C0 recipe; reused by C10/C11 timestamp surfaces).
    ///
    /// **Why a seam, not the host's read-time pins (C0 root cause).** A view body that
    /// calls `Text(date.formatted(date:time:))` formats the date to a `String` at
    /// body-evaluation time, using the `FormatStyle`'s OWN `timeZone` AND `locale`
    /// (both default `.autoupdatingCurrent`). The snapshot host's pins cannot reach it:
    /// (a) the process-wide UTC `TimeZone` pin
    /// (`setenv("TZ")`+`tzset()`+`resetSystemTimeZone()`) is a *global, lazily-run,
    /// ordering-sensitive* `TimeZone.current` mutation, not reliably effective under
    /// the full CI suite; (b) the host's `string(locale: en_US_POSIX)` pins how
    /// ViewInspector READS a `Text`, but the date here was already baked into a plain
    /// `String` under the FormatStyle's `.autoupdatingCurrent` LOCALE — and `.standard`
    /// time is sharply locale-sensitive (`en_GB`→`3:04:05`, `en_US`→`3:04:05 AM` with a
    /// narrow-no-break-space, a 24-h `.current`→`03:04:05`). So a ref recorded on one
    /// runner mismatches another's zone OR locale. An explicit per-call `TimeZone` +
    /// `Locale` makes the rendered string deterministic **independent of any global pin,
    /// test ordering, runner zone, or runner locale** — the strongest, reusable guarantee.
    ///
    /// **Production is byte-identical to today.** Both defaults are `.autoupdatingCurrent`
    /// — exactly what `Date.formatted(date:time:)` already uses — so prod keeps showing
    /// the operator's LOCAL time in their LOCAL locale (verified byte-identical). The
    /// clock tests inject `.gmt` + `en_US_POSIX` for a runner-independent reference.
    func workbenchTimeText(
        date: Date.FormatStyle.DateStyle,
        time: Date.FormatStyle.TimeStyle,
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle(date: date, time: time)
        style.timeZone = timeZone
        style.locale = locale
        return formatted(style)
    }
}

/// A global/navigation command issued from the menu bar. Posted via
/// `.workbenchMenuCommand` and dispatched by the root view to the model — this
/// keeps the shortcut as a real menu key equivalent (which beats the focused
/// terminal) while reusing the existing model methods.
public enum WorkbenchMenuCommand: Hashable, Sendable {
    case commandPalette, bossCheckIn, jumpToAttention
    case newTerminal, newTerminalTab, openWorkspace, saveWorkspace
    case toggleSidebar, toggleFocus, fontIncrease, fontDecrease, fontReset
    case prevTerminal, nextTerminal, prevGroup, nextGroup
    case findInTerminal, redraw, stopSelected
    case settings, shortcutsHelp, about, checkForUpdates, reportBug
    case selectTerminal(Int)
    case splitRight, splitDown, closePane, focusOtherPane
    // Slice ②d — inline-rename chords targeting the active workspace / selected tab.
    case renameWorkspace, renameTab
}

/// Which of the two detail panes is meant when a split is active. Increment 1
/// of W5 supports exactly one split (no recursive nesting), so the model is a
/// flat two-case enum rather than a tree. `primary` is the original detail
/// pane (driven by `selectedEntryID`, exactly as before the split); `secondary`
/// is the second pane opened by Split Right / Split Down.
enum DetailPaneID: Hashable {
    case primary
    case secondary
}

/// Orientation of the single detail split. `vertical` lays the two panes out
/// side-by-side (a vertical divider — "Split Right"); `horizontal` stacks them
/// (a horizontal divider — "Split Down"). Mirrors AppKit's `HSplitView` /
/// `VSplitView` axis naming so the rendering site reads straight across.
enum DetailSplitAxis: Hashable {
    /// Side-by-side panes, vertical divider. "Split Right."
    case vertical
    /// Stacked panes, horizontal divider. "Split Down."
    case horizontal
}

/// In-memory description of the detail pane's single split (Increment 1).
/// `nil` on the view model means "single pane" — the exact pre-W5 behavior.
/// When present, the primary pane shows `selectedEntry` and the secondary pane
/// shows the session identified by `secondaryEntryID` (or an empty picker when
/// that is `nil`). Not persisted this increment: relaunch comes up single-pane.
///
/// The one-NSView-per-session invariant (a session's terminal view lives in
/// exactly one superview) is enforced by the view model: `secondaryEntryID` is
/// never allowed to equal `selectedEntryID`, so the same session can never be
/// mounted in both panes simultaneously.
struct DetailSplitState: Equatable {
    var axis: DetailSplitAxis
    /// The session shown in the secondary pane, or `nil` for an empty picker.
    var secondaryEntryID: UUID?
}

// U5 PR#1: widened private→internal for the WorkbenchViews/WorkbenchViewModel file split.
// `WorkbenchViewModel` (now in WorkbenchViewModel.swift) constructs this result; it was
// same-file `private` before the move. Pure access-widen, no logic change.
internal struct ProviderCheckProcessResult: Sendable {
    var timedOut: Bool
    var terminationStatus: Int32
    var output: String
}

// U5 PR#1: widened private→internal for the WorkbenchViews/WorkbenchViewModel file split.
// `WorkbenchViewModel`'s provider-check process pump uses this buffer; same-file `private`
// before the move. Pure access-widen, no logic change.
internal final class ProviderCheckOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

// MARK: - W5 increment 2: in-memory split <-> persisted `PaneLayoutState`

extension DetailSplitAxis {
    init(_ persisted: PaneLayoutState.Axis) {
        switch persisted {
        case .vertical: self = .vertical
        case .horizontal: self = .horizontal
        }
    }

    var persisted: PaneLayoutState.Axis {
        switch self {
        case .vertical: return .vertical
        case .horizontal: return .horizontal
        }
    }
}

extension DetailPaneID {
    init(_ persisted: PaneLayoutState.Focus) {
        switch persisted {
        case .primary: self = .primary
        case .secondary: self = .secondary
        }
    }

    var persisted: PaneLayoutState.Focus {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        }
    }
}

extension Notification.Name {
    /// Posted by every other menu-bar command (object: `WorkbenchMenuCommand`).
    public static let workbenchMenuCommand = Notification.Name("workbenchMenuCommand")
}

/// Dispatch a menu-bar command to the model. Centralizes the global/navigation
/// shortcuts so they're real menu key equivalents (which fire even when a terminal
/// has keyboard focus) routed to the existing methods.
///
/// Extracted out of `WorkbenchRootView.handleMenuCommand` (the K4-helper pattern):
/// the switch lives behind the non-executable `@StateObject` `Scene` root and was
/// reachable only via `.onReceive`, which ViewInspector cannot drive. As a free
/// function taking the model directly, every dispatch arm is unit-testable. The one
/// view-local arm (`.toggleSidebar`, which mutates the root's `@State columnVisibility`)
/// is threaded back through the `toggleSidebar` closure so this function stays pure
/// dispatch with no view dependency. Prod byte-identical: `handleMenuCommand` now just
/// forwards here with `toggleSidebar: toggleSidebarVisibility`.
@MainActor
func dispatchMenuCommand(
    _ command: WorkbenchMenuCommand,
    to model: WorkbenchViewModel,
    toggleSidebar: () -> Void
) {
    switch command {
    case .commandPalette:
        model.isCommandPalettePresented = true
    case .bossCheckIn:
        // U12: ⌘I / the menubar item route through the same affordance as the
        // header button — with no usable boss this opens set-up instead of
        // silently no-opping.
        model.attemptCheckIn()
    case .jumpToAttention:
        // FIX 3: cmd-J used to discard the false return, so pressing it with an
        // empty attention queue did nothing — a dead key with no feedback. When
        // the jump can't move (nothing needs the operator), surface a brief
        // transient status through the app's existing one-shot message channel
        // (reusing the inbox-zero phrasing) instead of silently no-opping.
        if !model.jumpToNextAttentionSession() {
            model.errorMessage = "Nothing needs you right now."
        }
    case .newTerminal:
        model.isNewSessionSheetPresented = true
    case .newTerminalTab:
        model.isNewSessionSheetPresented = true
    case .openWorkspace:
        model.presentOpenWorkspacePanel()
    case .saveWorkspace:
        model.presentSaveWorkspacePanel()
    case .toggleSidebar:
        toggleSidebar()
    case .toggleFocus:
        model.toggleTerminalFocus()
    case .fontIncrease:
        model.bumpTerminalFontSize(by: 1)
    case .fontDecrease:
        model.bumpTerminalFontSize(by: -1)
    case .fontReset:
        model.resetTerminalFontSize()
    case .prevTerminal:
        _ = model.cycleTerminal(direction: .previous)
    case .nextTerminal:
        _ = model.cycleTerminal(direction: .next)
    case .prevGroup:
        _ = model.cycleGroup(direction: .previous)
    case .nextGroup:
        _ = model.cycleGroup(direction: .next)
    case .findInTerminal:
        model.presentTerminalSearch()
    case .redraw:
        // Targets the *active* pane's session, not just the sidebar
        // selection, so ⌘L hits whichever terminal you're focused on.
        if let entry = model.activeEntry { model.redrawTerminal(entry) }
    case .stopSelected:
        // U11: ⌘. is the reflexive cancel chord — route through the
        // consequence gate so it can't nuke a live/holding agent unconfirmed.
        if let entry = model.activeEntry { model.requestStop(entry) }
    case .splitRight:
        model.splitDetail(axis: .vertical)
    case .splitDown:
        model.splitDetail(axis: .horizontal)
    case .closePane:
        model.closeActivePane()
    case .focusOtherPane:
        model.focusOtherPane()
    case .settings:
        model.isSettingsSheetPresented = true
    case .shortcutsHelp:
        model.isShortcutHelpPresented = true
    case .about:
        model.isAboutSheetPresented = true
    case .checkForUpdates:
        Task { await model.checkForUpdatesAndPromptInstall() }
    case .reportBug:
        model.isReportBugPresented = true
    case let .selectTerminal(index):
        _ = model.selectTerminal(atOneIndexedPosition: index)
    case .renameWorkspace:
        // ⇧⌘R — begin the inline rename on the active workspace (D2d-8).
        model.beginRenameActiveWorkspace()
    case .renameTab:
        // ⌘R — begin the inline rename on the selected tab (D2d-8).
        model.beginRenameSelectedTab()
    }
}

public struct WorkbenchRootView: View {
    @StateObject private var model: WorkbenchViewModel
    /// Sidebar collapse state. Bound to NavigationSplitView's column
    /// visibility so ⌃⌘B can flip between "show only the terminal" and
    /// "show the sidebar." Matches VSCode's chrome-toggle binding.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// The app's scene phase. Drives a readiness re-check when the app regains focus,
    /// catching a provider token that expired while the app sat idle in the background.
    @Environment(\.scenePhase) private var scenePhase

    public init(diagnostics: WorkbenchLaunchDiagnostics) {
        let paths = WorkbenchPaths(rootURL: diagnostics.appSupportRoot ?? WorkbenchPaths.defaultPaths().rootURL)
        _model = StateObject(wrappedValue: WorkbenchViewModel(
            paths: paths,
            autoLaunchResumableForE2E: diagnostics.autoLaunchResumableForE2E
        ))
    }

    /// Flip the sidebar between visible and collapsed. `.automatic` lands
    /// at the system's preferred layout (sidebar shown); `.detailOnly`
    /// hides the sidebar entirely. We don't distinguish .all from
    /// .automatic because the two-column split has only one sidebar.
    private func toggleSidebarVisibility() {
        switch columnVisibility {
        case .detailOnly:
            columnVisibility = .automatic
        default:
            columnVisibility = .detailOnly
        }
    }

    /// Dispatch a menu-bar command to the model. Thin forwarder onto the free
    /// `dispatchMenuCommand(_:to:toggleSidebar:)` (extracted so every arm is
    /// unit-testable outside the non-executable `Scene` root). The only view-local
    /// arm — `.toggleSidebar`, which mutates `@State columnVisibility` — is threaded
    /// in as `toggleSidebarVisibility`. Prod byte-identical.
    private func handleMenuCommand(_ command: WorkbenchMenuCommand) {
        dispatchMenuCommand(command, to: model, toggleSidebar: toggleSidebarVisibility)
    }

    /// The two idle-driver readiness re-check triggers, factored into a `ViewModifier`
    /// so the root `body` modifier chain stays under the SwiftUI type-checker's
    /// complexity ceiling. Both route through `model.refreshOutwardReadinessIfStale`,
    /// whose `AgentReadinessRefreshPolicy` guard shares one debounce window between them.
    private struct ReadinessStalenessRefresh: ViewModifier {
        @ObservedObject var model: WorkbenchViewModel
        let scenePhase: ScenePhase

        func body(content: Content) -> some View {
            content
                .onChange(of: scenePhase) { _, newPhase in
                    // Snappy re-check when the app regains focus — catches a provider token
                    // that expired while the app sat idle in the background. Debounced to 60s
                    // (via the IfStale guard) so rapid app-switching can't spam checks.
                    if newPhase == .active {
                        model.refreshOutwardReadinessIfStale(staleAfter: 60)
                    }
                }
                .task {
                    // Periodic backstop for the daily-driver-left-open case: while this view is
                    // alive, re-check readiness every 5 min so a token that expires mid-session
                    // doesn't leave a stale "ready" pill until the next manual navigation. SwiftUI
                    // cancels this task when the view disappears. The IfStale guard (300s) means
                    // this never double-fires with the scene-phase path above.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 300_000_000_000)
                        model.refreshOutwardReadinessIfStale(staleAfter: 300)
                    }
                }
        }
    }

    public var body: some View {
        Group {
            if let entry = model.terminalFocusEntry,
               let session = model.activeSession(for: entry) {
                TerminalFocusView(entry: entry, session: session, model: model)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    WorkbenchSidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
                } detail: {
                    ZStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Header is pinned to its natural height so a greedy
                            // fill-content view (e.g. the empty state's
                            // maxHeight:.infinity) can't starve it to zero —
                            // which previously collapsed the whole pane.
                            HeaderView(model: model)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            Divider()
                            if !model.state.bossPaneCollapsed {
                                BossDashboardView(model: model)
                                Divider()
                            }
                            // Slice ②b — the cmux tab-strip: the ACTIVE workspace's
                            // tabs across the top of the detail column, above the
                            // session detail. Pinned to its natural height so it never
                            // starves the detail pane.
                            WorkspaceTabStrip(model: model)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            // Every detail branch fills the remaining space
                            // identically and pins to the top, so layout is
                            // deterministic regardless of which view is shown.
                            Group {
                                if let agentName = model.selectedAgentName,
                                   let agent = model.ouroAgent(named: agentName) {
                                    AgentDetailView(agent: agent, model: model)
                                } else if let entry = model.selectedEntry {
                                    // The session-detail branch is the one that
                                    // can split two-up (W5). The container shows
                                    // the single SessionDetailView when no split
                                    // is active — identical to before.
                                    DetailSplitContainer(primaryEntry: entry, model: model)
                                } else {
                                    AgentHomeEmptyState(model: model)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        ImportSummaryBanner(model: model)
                        // ⌃⌘B — toggle sidebar visibility. Invisible button
                        // so the shortcut works regardless of focus; matches
                        // VSCode's `cmd-b` muscle memory adjusted to also
                        // require ctrl (cmd-b alone collides with bold).
                        Button {
                            toggleSidebarVisibility()
                        } label: { EmptyView() }
                        .keyboardShortcut("b", modifiers: [.command, .control])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        .background(WindowChromeConfigurator(title: model.windowTitle))
        .onChange(of: model.activeSessions.count) { _, newCount in
            // Show the running-session count on the Dock icon so the user
            // gets a glanceable "is anything running" signal without bringing
            // the app forward. Empty string clears the badge.
            NSApp.dockTile.badgeLabel = newCount > 0 ? "\(newCount)" : ""
        }
        .task {
            // Set the initial badge on launch — the .onChange above only
            // fires when the count *changes* after the view mounts.
            NSApp.dockTile.badgeLabel = model.activeSessions.count > 0
                ? "\(model.activeSessions.count)"
                : ""
        }
        .modifier(ReadinessStalenessRefresh(model: model, scenePhase: scenePhase))
        .alert("Workbench Error", isPresented: model.errorIsPresented) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .task {
            // FIRST: capture the user's real login-shell PATH so every `ouro` shellout
            // can find `node` (incl. nvm/asdf/brew installs) — must run before the
            // daemon bringup + any provider check below.
            await model.prepareLoginShellEnvironment()
            // Bring the managed daemon online on launch (idempotent, quiet) before
            // recovery + status refreshes, so a daemon that died between sessions is
            // back up without waiting for a check-in.
            await model.ensureDaemonRunningOnLaunch()
            // Detect still-alive `screen` sessions first so startup recovery can
            // reattach to running agents losslessly instead of respawning them.
            await model.refreshLiveScreenSessions()
            // F11a Defect 1 — now that the live-`screen` set is known AND state
            // has loaded (in init, before this task), reap orphan screens: live
            // sessions no known entry owns (past crashes / prior-run delete-or-
            // archive that left a detached-but-alive screen). Gated on
            // load-success so an empty/failed load never quits reattachable
            // survivors. Must run AFTER refreshLiveScreenSessions (reuses that
            // cache) and BEFORE recovery reattaches survivors.
            await model.reapOrphanedScreenSessions()
            // Now that survival is known, re-derive startup attention so
            // sessions whose terminal kept running read as calmly reconnected
            // (not an orange "needs boss review") BEFORE the reattach runs.
            model.reconcileStartupAttentionWithLiveSessions()
            model.recoverEligibleSessionsOnStartup()
            model.launchAutoResumeSessionsOnStartup()
            // F12a gap 3b — now that startup attention is settled, escalate any
            // session that was waiting on a human across the restart with no boss
            // decision, so it's triaged instead of stranded out of the inbox.
            model.reconcileWaitingSessionsIntoInbox()
            model.refreshExecutableHealth()
            model.refreshGitStatus()
            model.refreshSessionActivity()
            model.refreshOnboardingReadiness()
            await model.refreshBossDashboard()
            // Migration: an existing already-onboarded user (ready boss + real sessions) updating
            // to the first build that carries `onboardingHasBeenCompleted` (default false) would
            // otherwise be force-presented the wizard — and, if they Cancel, never get the flag
            // set, so it re-pops every launch. Seed the flag for them. The policy is careful NOT to
            // seed a machine whose boss is merely "ready" but never actually onboarded (ready, no
            // sessions): those still present, or the stale-boss lockout U3 fixed returns. A wiped /
            // first-run machine is neither ready nor has sessions, so forced first-run is unaffected.
            if OnboardingPresentationPolicy.shouldMarkCompletedAtLaunch(
                isReady: model.onboardingReadiness?.isReady == true,
                hasUsedWorkbench: !model.state.processEntries.isEmpty,
                alreadyCompleted: model.onboardingHasBeenCompleted
            ) {
                model.onboardingHasBeenCompleted = true
            }
            if model.canAutoPresentOnboardingOnLaunch {
                // Snapshot the boss before the wizard can mutate it so an
                // abandoned mid-wizard pick rolls back on dismiss (#227).
                model.onboardingBossSnapshot = model.state.boss.agentName
                model.isOnboardingPresented = true
            } else {
                // The subtractive FRE redesign makes this the only path: the wizard
                // never auto-presents, so launch always lands on the working
                // terminals-first app. Run the provider liveness checks in the
                // background so a configured boss's readiness resolves to ready
                // without popping the onboarding sheet (no-op if already passed, or
                // if no ready boss is configured yet). The opt-in wizard is reached
                // only via `presentOnboarding()` (the empty-state "Set up a boss").
                model.runOnboardingProviderChecksIfNeeded()
            }
            if model.bossWatchIsEnabled {
                await model.runBossWatchTick(force: true)
            }
            // Attach the menu bar controller to the live model so the
            // NSStatusItem reflects current state. Singleton ensures the
            // status item is created only once even if SwiftUI re-mounts.
            // Honor the user's persisted "Show menu bar icon" setting.
            WorkbenchMenuBarController.shared.attach(model: model)
            WorkbenchMenuBarController.shared.setVisible(model.showMenuBarStatusItem)
        }
        .sheet(isPresented: $model.isNewSessionSheetPresented) {
            NewTerminalSessionSheet(model: model)
        }
        .sheet(item: $model.editingGroup) { project in
            EditTerminalGroupSheet(model: model, project: project)
        }
        .sheet(item: $model.editingSession) { entry in
            EditTerminalSessionSheet(model: model, entry: entry)
        }
        .sheet(isPresented: $model.isCommandPalettePresented) {
            CommandPaletteSheet(model: model)
        }
        .sheet(isPresented: $model.isShortcutHelpPresented) {
            ShortcutHelpSheet()
        }
        .sheet(isPresented: $model.isSettingsSheetPresented) {
            SettingsSheet(model: model)
        }
        .sheet(isPresented: $model.isAboutSheetPresented) {
            AboutSheet(model: model)
        }
        .sheet(isPresented: $model.isHarnessStatusPresented) {
            HarnessStatusSheet(model: model)
        }
        .sheet(isPresented: $model.isDecisionLogPresented) {
            // The prioritized triageable inbox (with a toggle down to the raw
            // chronological log). Same entry points as before — ⌘K + boss pane.
            DecisionInboxSheet(model: model)
        }
        .sheet(isPresented: $model.isReportBugPresented) {
            ReportBugSheet(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workbenchMenuCommand)) { note in
            guard let command = note.object as? WorkbenchMenuCommand else { return }
            handleMenuCommand(command)
        }
        // Accept Finder folder drops on the window — same end state as
        // Open Workspace…, but with one less click for the muscle memory
        // path of "drag the project root onto Workbench."
        .onDrop(of: [.fileURL], delegate: WorkspaceFolderDropDelegate(model: model))
        .sheet(isPresented: $model.isRecoverySheetPresented) {
            RecoverySheet(model: model)
        }
        .sheet(isPresented: $model.isOuroAgentInstallSheetPresented) {
            OuroAgentInstallSheet(model: model)
        }
        .sheet(isPresented: $model.isOnboardingPresented) {
            WorkbenchOnboardingSheet(model: model)
        }
        .sheet(isPresented: $model.isProviderConfigPresented) {
            ProviderConfigSheet(model: model)
        }
        .confirmationDialog("Delete Terminal?", isPresented: model.deleteConfirmationIsPresented) {
            if let entry = model.pendingDeleteSession {
                Button("Delete \(entry.name)", role: .destructive) {
                    model.deleteCustomSession(entry)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let entry = model.pendingDeleteSession {
                Text("This removes \(entry.name) from the workbench and clears its run records. Transcript files remain on disk.")
            }
        }
        .confirmationDialog(
            model.stopConfirmationTitle,
            isPresented: model.stopConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if let entry = model.pendingStopSession {
                Button(WorkbenchSurfacePolicy.stopConfirmationButton(name: entry.name), role: .destructive) {
                    model.confirmStop()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WorkbenchSurfacePolicy.stopConfirmationMessage)
        }
        .confirmationDialog("Start fresh?", isPresented: model.startFreshConfirmationIsPresented, titleVisibility: .visible) {
            if let entry = model.pendingStartFresh {
                Button("Start \(entry.name) fresh") {
                    model.confirmStartFresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let entry = model.pendingStartFresh {
                Text(model.startFreshConfirmationMessage(for: entry))
            }
        }
        .confirmationDialog("Delete Workspace?", isPresented: model.deleteGroupConfirmationIsPresented) {
            if let project = model.pendingDeleteGroup {
                Button("Delete \(project.name)", role: .destructive) {
                    model.deleteGroup(project)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let project = model.pendingDeleteGroup {
                Text("This removes the empty workspace \(project.name). Workspaces with terminals cannot be deleted.")
            }
        }
        .confirmationDialog("Reset to Factory Defaults?", isPresented: $model.isResetFirstRunConfirmationPresented, titleVisibility: .visible) {
            Button("Reset & Relaunch", role: .destructive) {
                model.resetToFirstRun()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears all of Workbench's own data — your groups, the session list, and every preference — and relaunches into the fresh first-run setup. Running terminals are stopped cleanly. Your agents' session histories (Claude, Codex, …) are stored by those tools, not Workbench, so they stay put — relaunch and resume them anytime. Your previous workspace is backed up to a file first.")
        }
        .confirmationDialog("Software Update", isPresented: model.updatePromptIsPresented, titleVisibility: .visible) {
            if model.updatePrompt?.isInstallable == true {
                Button("Install & Relaunch") {
                    Task { await model.installReleaseUpdate() }
                }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(model.updatePrompt?.message ?? "")
        }
        .task {
            await model.runExternalActionPump()
        }
        .task {
            // FIX4 — start the Boss Watch poll loop ONLY if Watch was persisted on.
            // The loop's lifetime is otherwise owned by the enable toggle
            // (`setBossWatchEnabled`), so it no longer wakes every 60s while OFF.
            model.startBossWatchLoopIfEnabled()
        }
        .task {
            await model.runAutoUpdateCheckIfDue()
        }
    }
}

/// Owns the Workbench menu-bar status item so the user can see boss-watch
/// state, jump to a running session, toggle Watch, ask the boss a quick
/// question, and quit — all without bringing the main window forward.
/// Singleton lifetime: created once at first access and held by the AppKit
/// system menubar for the rest of the app's run.
@MainActor
final class WorkbenchMenuBarController: NSObject, NSMenuDelegate {
    static let shared = WorkbenchMenuBarController()

    // Coverage-tightening (Class 2): widened private→internal so a direct unit test can
    // construct a FRESH, isolated controller (not the shared singleton) and assert on its
    // attached model / built menu / status-item state. Pure access-widen, no logic change —
    // `shared` still constructs identically and is the only instance prod ever uses.
    private(set) weak var model: WorkbenchViewModel?
    let statusItem: NSStatusItem
    let menu: NSMenu
    private var watchObservation: NSObjectProtocol?

    // Coverage-tightening (Class 2): `override private init()` → `override init()` so tests
    // build their own instance. Prod is byte-identical: `shared` is the sole production
    // construction site and still runs this exact body.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        applyIcon(needsAttention: false)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Ouro Workbench"
    }

    func attach(model: WorkbenchViewModel) {
        self.model = model
        refreshIcon()
    }

    /// Show or hide the NSStatusItem in the menu bar. The Settings sheet uses
    /// this to honor the "Show menu bar icon" preference at runtime without
    /// requiring a relaunch. The status item itself is retained either way so
    /// flipping it back on is instantaneous.
    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Update the menu-bar icon based on current state. Called on attach and
    /// whenever the menu opens. Cheap so we don't bother with KVO.
    func refreshIcon() {
        guard let model else {
            applyIcon(needsAttention: false)
            return
        }
        let recoverable = model.recoveryDigest.actionableCount
        applyIcon(needsAttention: recoverable > 0)
        // Surface the running session count directly on the menu-bar item
        // for an at-a-glance signal that matches the Dock badge.
        let activeCount = model.activeSessions.count
        statusItem.button?.title = activeCount > 0 ? " \(activeCount)" : ""
        statusItem.button?.toolTip = activeCount > 0
            ? "Ouro Workbench — \(activeCount) running"
            : "Ouro Workbench"
    }

    private func applyIcon(needsAttention: Bool) {
        let symbol = needsAttention ? "exclamationmark.triangle.fill" : "infinity"
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: needsAttention ? "Ouro Workbench needs attention" : "Ouro Workbench"
        )
        image?.isTemplate = !needsAttention
        statusItem.button?.image = image
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshIcon()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        guard let model else {
            let item = NSMenuItem(title: "Ouro Workbench", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(quitItem())
            return
        }

        // Header: boss + autonomy. #U31c: route through the SAME calm/loud Core
        // seam the in-window header uses, so a fresh no-boss machine reads calm
        // here too ("No boss yet" + "TTFA · off") instead of the alarming
        // "Boss: " + "TTFA · blocked — …" that survived on this second surface.
        let calm = HeaderCalmPresentation.resolve(
            bossAgentName: model.state.boss.agentName,
            bossAgentStatus: model.ouroAgent(named: model.state.boss.agentName)?.status,
            autonomyState: model.autonomyReadiness.state
        )
        let header = NSMenuItem(title: calm.bossLabelText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let autonomyItem = NSMenuItem(
            title: calm.ttfaText,
            action: nil,
            keyEquivalent: ""
        )
        autonomyItem.isEnabled = false
        menu.addItem(autonomyItem)
        menu.addItem(NSMenuItem.separator())

        // Show Workbench
        let show = NSMenuItem(title: "Show Workbench", action: #selector(showWorkbench), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(NSMenuItem.separator())

        // Active sessions submenu — click to jump
        let sessions = model.activeSessions
        if sessions.isEmpty {
            let none = NSMenuItem(title: "No running sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let header = NSMenuItem(
                title: "\(sessions.count) running session\(sessions.count == 1 ? "" : "s")",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            // Iterate the visible session entries so the order matches the
            // sidebar instead of being a dictionary-key dance.
            for entry in model.state.processEntries where sessions[entry.id] != nil {
                let row = NSMenuItem(
                    title: "  · \(entry.name)",
                    action: #selector(jumpToSession(_:)),
                    keyEquivalent: ""
                )
                row.target = self
                row.representedObject = entry.id.uuidString
                menu.addItem(row)
            }
        }
        menu.addItem(NSMenuItem.separator())

        // Recovery — show count and shortcut into the sheet (one shared digest)
        let recoverable = model.recoveryDigest.actionableCount
        if recoverable > 0 {
            let recoverItem = NSMenuItem(
                title: "Recovery: \(recoverable) waiting…",
                action: #selector(openRecoverySheet),
                keyEquivalent: ""
            )
            recoverItem.target = self
            menu.addItem(recoverItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Watch toggle
        let watchTitle = model.bossWatchIsEnabled ? "Stop Boss Watch" : "Start Boss Watch"
        let watch = NSMenuItem(title: watchTitle, action: #selector(toggleBossWatch), keyEquivalent: "")
        watch.target = self
        menu.addItem(watch)

        // Manual Check In (U12: one name — was "Ask <name>…", which diverged
        // from the header/menu "Check In" and collided with the typed-question
        // submit and the Boss Watch loop).
        let ask = NSMenuItem(
            title: WorkbenchViewModel.checkInActionLabel,
            action: #selector(quickAskBoss),
            keyEquivalent: ""
        )
        ask.target = self
        ask.toolTip = model.checkInHelpText
        ask.isEnabled = !model.bossCheckInIsRunning
        menu.addItem(ask)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem())
    }

    private func quitItem() -> NSMenuItem {
        let quit = NSMenuItem(title: "Quit Ouro Workbench", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        return quit
    }

    // MARK: - Actions

    @objc private func showWorkbench() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        for window in NSApp.windows where !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        }
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
    }

    @objc private func jumpToSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let uuid = UUID(uuidString: raw) else {
            return
        }
        model?.selectEntryAcrossGroups(uuid)
        showWorkbench()
    }

    @objc private func openRecoverySheet() {
        model?.isRecoverySheetPresented = true
        showWorkbench()
    }

    @objc private func toggleBossWatch() {
        guard let model else { return }
        model.setBossWatchEnabled(!model.bossWatchIsEnabled)
    }

    @objc private func quickAskBoss() {
        guard let model, !model.bossCheckInIsRunning else { return }
        showWorkbench()
        // U12: route through the shared affordance so a no-boss menubar tap opens
        // set-up instead of silently no-opping.
        model.attemptCheckIn()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    private static let frameAutosaveName = "OuroWorkbenchMainWindow"
    /// Live window title. Even though the title bar is hidden, this value is
    /// used by macOS for the Dock window list, cmd+` window switcher, Mission
    /// Control labels, and screen recordings — so making it dynamic (boss +
    /// active surface) means those system surfaces stay informative.
    var title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }
        window.title = title
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 1100, height: 700)
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }
}

/// Modal sheet that lists every session the recovery planner currently
/// considers actionable. The sidebar Recovery row opens this. Per-row
/// "Recover" + "Open" buttons; top-level "Recover All" when more than one.
struct RecoverySheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recovery")
                        .font(.title3.weight(.semibold))
                    // U8b: one shared derivation — this header, the sidebar row,
                    // its help, and the row count below can never disagree.
                    Text(model.recoveryDigest.sheetHeader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer()
                if model.autoRecoverableEntries.count > 1 {
                    Button {
                        model.recoverAllRecoverableSessions()
                        dismiss()
                    } label: {
                        Label("Recover All", systemImage: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()
            if !model.recoveryDigest.shouldShow {
                ContentUnavailableView(
                    "Nothing to recover",
                    systemImage: "checkmark.seal.fill",
                    description: Text("No sessions are waiting on recovery. Agents that were still running when you quit reconnect automatically on the next launch; only sessions that didn't survive a restart show up here.")
                )
                .frame(minHeight: 240)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // U7: sessions that can't be auto-resumed get their own
                        // labelled group with a plain reason and a one-click fix
                        // where one exists — never silently dropped or handed a
                        // calm "Launch".
                        if !model.needsYouEntries.isEmpty {
                            RecoverySheetSection(
                                title: "Needs you",
                                systemImage: "person.crop.circle.badge.exclamationmark",
                                tint: .orange,
                                subtitle: "These can't be auto-resumed. Fix the blocker, or start fresh."
                            ) {
                                ForEach(model.needsYouEntries) { entry in
                                    NeedsYouEntryRow(entry: entry, model: model, onJump: {
                                        model.selectEntryAcrossGroups(entry.id)
                                        dismiss()
                                    })
                                }
                            }
                        }
                        if !model.autoRecoverableEntries.isEmpty {
                            RecoverySheetSection(
                                title: "Ready to recover",
                                systemImage: "arrow.clockwise.circle",
                                tint: .accentColor,
                                subtitle: "Reconnects to still-running agents losslessly; resumes or reopens the rest."
                            ) {
                                ForEach(model.autoRecoverableEntries) { entry in
                                    RecoverableEntryRow(entry: entry, model: model, onJump: {
                                        model.selectEntryAcrossGroups(entry.id)
                                        dismiss()
                                    }, onRecover: {
                                        model.recover(entry)
                                    })
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 620, height: 520)
    }
}

/// A labelled section within the Recovery sheet (U7) — a header glyph + title +
/// one-line subtitle over its rows.
private struct RecoverySheetSection<Content: View>: View {
    var title: String
    var systemImage: String
    var tint: SwiftUI.Color
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
    }
}

/// A "Needs you" row in the Recovery sheet (U7): a manual-recovery session with
/// its plain-language reason, an inline one-click fix when the blocker is
/// fixable (e.g. Trust), and a "Start fresh" fallback (confirmation-gated).
// U5: private->internal so the per-file-100% gate can drive its trust/start-fresh action
// buttons via a direct ViewInspector tap. Same module, pure presentation — no behavior change.
struct NeedsYouEntryRow: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    var onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.recoveryReasonSentence(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help("Recovery detail: \(model.recoveryReason(for: entry))")
                }
                Spacer()
                Button {
                    onJump()
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Jump to this session in the workbench")
                if model.recoveryTrustFixAvailable(for: entry) {
                    // One-click fix: trusting clears the blocker so recovery
                    // auto-resumes instead of forcing a fresh start.
                    Button {
                        model.trustAndRecover(entry)
                    } label: {
                        Label("Trust & resume", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Trust this session to enable auto-resume, then recover it without losing history.")
                } else {
                    Button {
                        model.requestStartFresh(entry)
                    } label: {
                        Label("Start fresh", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("No resumable session — this begins a new conversation. The previous transcript stays viewable.")
                }
            }
            HStack(spacing: 6) {
                Text(model.launchCommand(for: entry))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct RecoverableEntryRow: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    var onJump: () -> Void
    var onRecover: () -> Void

    /// U8b: a lossless live reattach is calm (a reconnect, no loss), so it reads
    /// in a settled green link rather than the orange "recovery action" tone.
    private var isReattach: Bool { model.isLosslessReattach(for: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isReattach ? "link.circle.fill" : "arrow.clockwise")
                    .foregroundStyle(isReattach ? Color.green : Color.orange)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isReattach {
                            Text("Reconnect — no loss")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                    }
                    if let summary = entry.lastSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(model.recoveryReasonSentence(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help("Recovery detail: \(model.recoveryReason(for: entry))")
                }
                Spacer()
                Button {
                    onJump()
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Jump to this session in the workbench")
                Button {
                    onRecover()
                } label: {
                    Label(model.recoveryButtonTitle(for: entry), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                Text(model.launchCommand(for: entry))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// The transient result of a Harness Status control action, shown as a banner
/// in the sheet until the next refresh. `kind` ties it back to the Core action
/// enum so the banner can phrase itself; `succeeded` picks the tint/icon.
struct HarnessActionResult: Equatable {
    var kind: HarnessControlAction
    var succeeded: Bool
    var message: String
}

/// Refreshable consolidation of the ouro-harness state an operator cares about,
/// in one place: daemon health, the local agent inventory (with the selected
/// boss marked), and boss MCP-registration / reachability. The first W3 step
/// toward Workbench being the human control panel over the harness.
///
/// All three sections are built from reads that already exist elsewhere in the
/// model (the boss dashboard, the onboarding agent scan, the MCP registrar);
/// this sheet presents them together. Beyond Refresh, it offers two confirm-gated
/// control actions so the operator can fix a degraded harness without dropping to
/// a terminal: Repair/start the ouro daemon, and register the Workbench MCP with
/// the selected boss. Which action is surfaced prominently is driven by
/// `HarnessStatus.controlOffer`. Reached from the More menu ("Harness Status…")
/// and the ⌘K palette.
struct HarnessStatusSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing: Bool

    /// `initialIsRefreshing` defaults to `false` — the prod default UNCHANGED. The seam lets a
    /// test seed `@State` so the in-flight render (the Refresh button `.disabled(isRefreshing)`
    /// + the `isBusy: isRefreshing` HarnessActionRow) is reachable (otherwise unreachable: the
    /// flag is flipped only by an async `.task`-style refresh ViewInspector can't drive). Prod
    /// byte-identical.
    init(model: WorkbenchViewModel, initialIsRefreshing: Bool = false) {
        self.model = model
        _isRefreshing = State(initialValue: initialIsRefreshing)
    }

    private var status: HarnessStatus { model.harnessStatus }
    private var offer: HarnessControlOffer { status.controlOffer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Harness Status")
                            .font(.title3.weight(.semibold))
                        StatusPill(text: status.overallState.displayName, color: status.overallState.tint)
                    }
                    Text(status.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = model.harnessActionResult {
                        HarnessActionResultBanner(result: result) {
                            model.harnessActionResult = nil
                        }
                    }
                    daemonSection
                    agentSection
                    bossSection
                    if let observedAt = status.observedAt {
                        Text("Daemon observed at \(observedAt)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 540)
        .animation(.easeInOut(duration: 0.2), value: model.harnessActionResult)
        .confirmationDialog(
            "Bring your agent back online?",
            isPresented: $model.isRepairHarnessDaemonConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Bring back online") {
                Task {
                    await model.repairHarnessDaemon()
                    refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restarts your agent's background runtime so it can respond again. Safe to run when it's already online — Workbench just re-checks what this machine needs. Runs quietly in the background.")
        }
        .confirmationDialog(
            "Connect Workbench tools?",
            isPresented: $model.isRegisterHarnessMCPConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Connect \(status.boss.agentName)") {
                model.registerHarnessWorkbenchMCP()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Makes Workbench's tools available to \(status.boss.agentName) at runtime so the boss can drive Workbench. Nothing is written to the agent's synced config; any stale Workbench entry left by an older setup is cleaned up.")
        }
        .task {
            // Refresh on open so the sheet always reflects current state — the
            // dashboard/agent reads may be stale from an earlier tick. Clear any
            // stale action banner from a previous opening.
            model.harnessActionResult = nil
            refresh()
        }
    }

    /// Refresh the consolidated status, toggling the local spinner. Shared by
    /// the Refresh button, the on-open task, and the post-action refresh so a
    /// fired control action's effect shows up without a manual click.
    private func refresh() {
        Task {
            isRefreshing = true
            await model.refreshHarnessStatus()
            isRefreshing = false
        }
    }

    // MARK: - Daemon

    private var daemonSection: some View {
        HarnessSection(
            title: "ouro daemon",
            systemImage: "bolt.horizontal.circle",
            state: status.daemon.state
        ) {
            HarnessDetailRow(label: "Status", value: status.daemon.statusText, valueColor: status.daemon.state.tint)
            HarnessDetailRow(label: "Mode", value: status.daemon.modeText)
            HarnessDetailRow(label: "Version", value: status.daemon.versionText)
            if offer.isAvailable(.repairDaemon) {
                HarnessActionRow(
                    title: "Bring Back Online",
                    systemImage: "wrench.and.screwdriver",
                    help: offer.isUrgent(.repairDaemon)
                        ? "Your agent isn't reachable. Bring its runtime back online."
                        : "Restart and refresh your agent's background runtime.",
                    isUrgent: offer.isUrgent(.repairDaemon),
                    isBusy: isRefreshing
                ) {
                    model.isRepairHarnessDaemonConfirmationPresented = true
                }
            }
        }
    }

    // MARK: - Agents

    private var agentSection: some View {
        HarnessSection(
            title: "Local agents",
            systemImage: "person.2",
            state: status.agents.hasUnready ? .attention : .healthy,
            trailingText: status.agents.summaryLine
        ) {
            if status.agents.isEmpty {
                Text("No Ouro agents are installed on this machine yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(status.agents.entries) { entry in
                    HarnessAgentRow(entry: entry)
                }
            }
        }
    }

    // MARK: - Boss

    private var bossSection: some View {
        HarnessSection(
            title: "Boss reachability",
            systemImage: "crown",
            state: status.boss.state
        ) {
            HarnessDetailRow(label: "Selected boss", value: status.boss.agentName)
            HarnessDetailRow(
                label: "Bundle",
                value: status.boss.bundleText,
                valueColor: status.boss.bundleIsInstalled ? .green : .orange
            )
            HarnessDetailRow(
                label: "Workbench MCP",
                value: status.boss.mcpStatusText,
                // Route the detail-row tint through the verdict-aware seam, folding the boss's
                // live injection verdict (status.boss.toolsInjection) in via mcpPillTone — the
                // SAME source of truth as the per-agent MCP pills. A registered-but-unverified
                // boss reads NEUTRAL (.secondary), never the config-only false green; only a
                // confirmed-present injection earns green. `.secondary` is the calm fallback
                // when there's no mcpStatus yet (nothing registration-shaped to colour).
                valueColor: status.boss.mcpPillTone
                    .map { BossMCPPillPresentation.color(for: $0).swiftUIColor } ?? .secondary
            )
            if let detail = status.boss.mcpDetail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if offer.isAvailable(.registerWorkbenchMCP) {
                HarnessActionRow(
                    title: status.boss.mcpStatus == .needsUpdate ? "Clean up Workbench entry" : "Connect Workbench tools",
                    systemImage: "antenna.radiowaves.left.and.right",
                    help: "Make Workbench's tools available to \(status.boss.agentName) at runtime so the boss can drive Workbench. Nothing is written to the synced config.",
                    isUrgent: offer.isUrgent(.registerWorkbenchMCP),
                    isBusy: isRefreshing
                ) {
                    model.isRegisterHarnessMCPConfirmationPresented = true
                }
            }
        }
    }
}

/// A bordered card grouping one harness section, with a state-tinted header
/// dot. Mirrors the recovery-row card chrome so the sheet sits visually with
/// the rest of the app.
private struct HarnessSection<Content: View>: View {
    var title: String
    var systemImage: String
    var state: HarnessHealthState
    var trailingText: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct HarnessDetailRow: View {
    var label: String
    var value: String
    var valueColor: SwiftUI.Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// C11: `private`→`internal` (zero-behavior) so the snapshot test can
// `@testable import` the standalone agent-readiness row leaf; sole call site is
// `HarnessStatusSheet`'s agent-section `ForEach` (unchanged).
struct HarnessAgentRow: View {
    var entry: HarnessAgentEntry

    var body: some View {
        // Render the readiness pill/dot/tooltip through the SAME live-aware seam
        // the steady-state sidebar / "Installed agents" rows use, so the
        // diagnostic sheet can never disagree with them — and a config-only
        // `.ready` with an expired token reads "sign-in needed" (orange), not a
        // false green. Driven by the live outward verdict + in-flight flag folded
        // into `entry.liveReadiness`; never the config-only status.
        let readiness = entry.liveReadiness
        let tint = InstalledAgentRowPresentation.dotColor(for: readiness).swiftUIColor
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.isReady ? "person.crop.circle" : "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(tint)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isSelectedBoss {
                        StatusPill(text: "boss", color: .blue)
                    }
                }
                Text(entry.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            StatusPill(text: InstalledAgentRowPresentation.label(for: readiness), color: tint)
            if let mcpStatus = entry.mcpStatus {
                // Fold the on-disk registration STATUS with the live injection VERDICT through
                // the shared seam: GREEN "on" is reachable ONLY when a confirmed-present
                // `tools/list` probe backs a `.registered` snapshot. A config-only `.registered`
                // with no (or an unconfirmed / confirmed-absent) verdict reads NEUTRAL — never a
                // false green that says the tools inject at runtime when they were never probed.
                let mcpTone = BossMCPPillPresentation.tone(
                    status: mcpStatus,
                    injection: entry.toolsInjection
                )
                StatusPill(
                    text: "mcp \(harnessShortLabel(for: mcpTone))",
                    color: BossMCPPillPresentation.color(for: mcpTone).swiftUIColor
                )
            }
        }
        .help(InstalledAgentRowPresentation.help(for: readiness, detail: entry.detail))
    }

    /// Compact diagnostic-row wording for each verdict-aware MCP pill tone. Keeps the
    /// terse harness style ("on"/"off"/"stale") while the GREEN "on" stays gated on a
    /// confirmed-present injection (`.verified`); a registered-but-unverified pill reads
    /// the calm "unverified", never a false "on".
    private func harnessShortLabel(for tone: BossMCPPillPresentation.Tone) -> String {
        switch tone {
        case .verified:
            return "on"
        case .unverified:
            return "unverified"
        case .notInjected:
            return "old ouro"
        case .needsAttention:
            return "stale"
        case .notRegistered:
            return "off"
        case .error:
            return "error"
        }
    }
}

/// A confirm-gated control button inside a harness section. Renders prominently
/// (filled, default keyboard action) when the action is urgent — the harness is
/// degraded in a way this action fixes — and as a quiet bordered button
/// otherwise, so a healthy harness still exposes the control without shouting.
/// Disabled while a refresh is in flight so it can't be double-fired.
// U5: private->internal so the per-file-100% gate can drive the `if isBusy { ProgressView }`
// render arm (isBusy is a plain Bool input). Same module, pure presentation — no behavior change.
struct HarnessActionRow: View {
    var title: String
    var systemImage: String
    var help: String
    var isUrgent: Bool
    var isBusy: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Urgent → filled/prominent so it stands out in a degraded harness.
            // Otherwise → quiet bordered button (still present: Workbench is a
            // control panel even when healthy).
            if isUrgent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .controlSize(.small)
        .disabled(isBusy)
        .help(help)
    }
}

/// Transient banner reporting the outcome of a harness control action. Green
/// check on success, orange warning on failure, with a dismiss affordance.
// C11: `private`→`internal` (zero-behavior) so the snapshot test can
// `@testable import` the standalone leaf; the only call site is
// `HarnessStatusSheet`'s `if let result` arm (unchanged).
struct HarnessActionResultBanner: View {
    var result: HarnessActionResult
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.succeeded ? Color.green : Color.orange)
            Text(result.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((result.succeeded ? Color.green : Color.orange).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder((result.succeeded ? Color.green : Color.orange).opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Harness state styling

// U5 B10: private->internal so the B10 direct logic test can assert every styling arm. Same
// module, no behavior change — these are pure presentation extensions on Core types.
extension HarnessHealthState {
    var tint: SwiftUI.Color {
        switch self {
        case .healthy:
            return .green
        case .attention:
            return .orange
        case .blocked:
            return .red
        }
    }

    var displayName: String {
        switch self {
        case .healthy:
            return "healthy"
        case .attention:
            return "attention"
        case .blocked:
            return "blocked"
        }
    }
}

/// #F9 — a tiny thread-safe sink for the handoff-edge `tools/list` injection verdict. The
/// `@Sendable` `statusPing` closure runs off the main actor, so it can't touch `@Published`
/// state directly; it records the per-agent verdict here, and the main actor drains it after
/// the bootstrap finishes. Last write per agent wins (one probe per bringup).
final class WorkbenchToolsInjectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [String: WorkbenchToolsInjectionProbeOutcome] = [:]

    func record(agentName: String, outcome: WorkbenchToolsInjectionProbeOutcome) {
        lock.lock()
        defer { lock.unlock() }
        outcomes[agentName] = outcome
    }

    /// Read (and keep) the recorded verdicts — called on the main actor to overlay them.
    func snapshot() -> [String: WorkbenchToolsInjectionProbeOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return outcomes
    }
}

// U5 B10: private->internal for the B10 direct logic test (pure presentation, same module).
extension BossWorkbenchMCPRegistrationStatus {
    var harnessTint: SwiftUI.Color {
        switch self {
        case .registered:
            return .green
        case .needsUpdate:
            // Cleanup-pending (stale bundle entry, binary present) — auto-fixable.
            return .orange
        case .notRegistered, .agentMissing, .executableMissing, .invalidConfig, .toolsNotInjected:
            // Binary missing (`.notRegistered`) / structural failure / a too-old runtime that
            // stripped the tools (`.toolsNotInjected`) — needs a reinstall / ouro update.
            return .red
        }
    }
}

// U5 B10: private->internal for the B10 direct logic test (pure presentation, same module).
extension Optional where Wrapped == BossWorkbenchMCPRegistrationStatus {
    /// Tint for a possibly-unknown registration status; unknown reads as
    /// secondary so the row doesn't imply a problem before the check runs.
    var harnessTint: SwiftUI.Color {
        self?.harnessTint ?? .secondary
    }
}

/// User preferences sheet, opened by ⌘, or the More menu's "Settings…"
/// action. Consolidates settings that were previously scattered as raw
/// UserDefaults reads — terminal font size, theme override, and menu-bar
/// icon visibility — into a single discoverable surface. Every control
/// binds directly to a `WorkbenchViewModel` setter so changes persist
/// immediately; no Save button needed.
struct SettingsSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    terminalSection
                    appearanceSection
                    chromeSection
                    startupSection
                    updatesSection
                    bossSection
                    advancedSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 540)
    }

    private var fontSizeBounds: ClosedRange<Int> {
        let lo = Int(WorkbenchViewModel.terminalFontSizeBounds.lowerBound)
        let hi = Int(WorkbenchViewModel.terminalFontSizeBounds.upperBound)
        return lo...hi
    }

    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { Int(model.terminalFontSize) },
            set: { model.setTerminalFontSize(CGFloat($0)) }
        )
    }

    @ViewBuilder
    private var terminalSection: some View {
        SettingsSection(title: "Terminal", systemImage: "terminal") {
            HStack(spacing: 12) {
                Text("Font size")
                    .frame(width: 110, alignment: .leading)
                Stepper(value: fontSizeBinding, in: fontSizeBounds) {
                    fontSizeLabel
                }
                Button("Reset") {
                    model.resetTerminalFontSize()
                }
                .help("Reset to macOS default (13pt). Also bound to ⌘0.")
            }
            Text("Also bound to ⌘+ / ⌘- / ⌘0 in any terminal.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var fontSizeLabel: some View {
        let display = "\(Int(model.terminalFontSize))pt"
        Text(display)
            .monospacedDigit()
            .frame(width: 50, alignment: .leading)
    }

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsSection(title: "Appearance", systemImage: "paintpalette") {
            HStack(spacing: 12) {
                Text("Terminal theme")
                    .frame(width: 110, alignment: .leading)
                Picker(
                    "",
                    selection: Binding(
                        get: { model.terminalThemeOverride },
                        set: { model.setTerminalThemeOverride($0) }
                    )
                ) {
                    ForEach(TerminalThemeOverride.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Text("Follow System matches your macOS light/dark setting. Light or Dark pins the terminal palette regardless of the system appearance.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var chromeSection: some View {
        SettingsSection(title: "Workbench Chrome", systemImage: "menubar.rectangle") {
            Toggle(isOn: Binding(
                get: { model.showMenuBarStatusItem },
                set: { model.setShowMenuBarStatusItem($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show menu bar icon")
                    Text("Adds the ∞ status item with running-session count, jump-to-session menu, and Boss Watch toggle.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private var startupSection: some View {
        SettingsSection(title: "Startup", systemImage: "power") {
            Toggle(isOn: Binding(
                get: { model.autoLaunchResumableOnStartup },
                set: { model.setAutoLaunchResumableOnStartup($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-launch resumable terminals on startup")
                    Text("On launch, start every terminal marked Auto Resume that isn't already running. Lets a `.workbench.json` workspace come up with its agents waiting for you.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        SettingsSection(title: "Software Updates", systemImage: "arrow.down.app") {
            WorkbenchUpdatePanel(model: model, showTitle: false)
            Toggle(isOn: Binding(
                get: { model.autoUpdateEnabled },
                set: { model.setAutoUpdateEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically check for updates and install on quit")
                    Text("Workbench verifies the release manifest and applies staged updates the next time you quit.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var bossSection: some View {
        SettingsSection(title: "Boss", systemImage: "person.2.badge.gearshape") {
            Toggle(isOn: $model.bossAutoAdvanceEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let the boss auto-advance waiting sessions")
                    Text("When a session is waiting, the boss answers the prompt for you using that session's friend's preferences — automatically (Boss Watch is on by default). Mark a session \u{201C}hands off\u{201D} (untrusted) to exclude it. It never auto-answers destructive or secret prompts, and every decision — acted or not — is in the Boss Decision Log (⌘K). Turn this off to make the boss escalate everything instead.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        SettingsSection(title: "Advanced", systemImage: "wrench.and.screwdriver") {
            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Notification Preferences…", systemImage: "bell.badge")
                }
                .help("Opens System Settings → Notifications so you can manage Workbench banners.")
            }
            Text("Notification permission is required for Boss-Watch needs-me pings and unexpected-exit alerts.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// A section within the Settings sheet — header + content slot — so each
/// settings group renders the same way.
private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Slim slide-in banner that confirms what Arrange just did. Auto-dismisses
/// after a few seconds; user can dismiss it explicitly with the close button.
struct ImportSummaryBanner: View {
    @ObservedObject var model: WorkbenchViewModel
    @State private var dismissTask: Task<Void, Never>?

    /// Resolve the honest banner tone via the pure Core seam: green ONLY when the
    /// import's durable write landed; an orange warning when it didn't. A
    /// persisted import (the common case, including a partial import with skips)
    /// still reads as the normal green success.
    private func tone(for summary: WorkbenchImportApplyResult) -> WorkbenchImportSummaryPresentation.Tone {
        WorkbenchImportSummaryPresentation.tone(
            persisted: summary.persisted,
            createdCount: summary.createdCount
        )
    }

    /// Map the framework-free `SemanticColor` the seam returns to a SwiftUI
    /// `Color` (`.green → .green`, `.orange → .orange`).
    private func swiftUIColor(for color: WorkbenchImportSummaryPresentation.SemanticColor) -> SwiftUI.Color {
        switch color {
        case .green:
            return .green
        case .orange:
            return .orange
        }
    }

    var body: some View {
        Group {
            if let summary = model.lastImportSummary {
                let tone = tone(for: summary)
                let accent = swiftUIColor(for: WorkbenchImportSummaryPresentation.color(for: tone))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: WorkbenchImportSummaryPresentation.iconSystemName(for: tone))
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.headline)
                            .font(.subheadline.weight(.semibold))
                        if !summary.persisted {
                            Text(WorkbenchImportSummaryPresentation.notPersistedNote)
                                .font(.caption)
                                .foregroundStyle(accent)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        if let detail = summary.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 8)
                    if let entryID = summary.firstSelectedEntryID,
                       model.state.processEntries.contains(where: { $0.id == entryID }) {
                        Button("Open") {
                            model.selectEntryAcrossGroups(entryID)
                            model.lastImportSummary = nil
                        }
                        .controlSize(.small)
                    }
                    Button {
                        model.lastImportSummary = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accent.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: 560)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    scheduleDismiss()
                }
                .onDisappear {
                    dismissTask?.cancel()
                    dismissTask = nil
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.lastImportSummary)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled {
                model.lastImportSummary = nil
            }
        }
    }
}

/// Compact About sheet — app version, build hash, and a couple of useful
/// pointers. Reached via the More menu and the ⌘K palette. The dedicated
/// macOS About item under the app menu can also dispatch here but the
/// hidden title bar prevents the system's built-in About from surfacing,
/// so the More-menu route is the primary entry.
public struct AboutSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    private let buildHash: String

    /// Seam: open a URL in the system browser. Default = the real `NSWorkspace.shared.open`;
    /// a test injects a recording stub to assert WHICH url the "View Repository" action sends,
    /// without launching a browser. Prod byte-identical.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Seam: write a string to the general pasteboard. Default = the real
    /// `NSPasteboard.general` clear+setString; a test injects a recording stub to assert the
    /// version string the "Copy Version" action copies, without touching the live pasteboard.
    var copyToPasteboard: (String) -> Void = { value in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// `buildHash` defaults to the live `CFBundleVersion` (wired in by package-app.sh; falls
    /// back to "dev" for a `swift run` build with no bundle) — the prod behavior UNCHANGED. The
    /// seam lets a test inject a FIXED hash so the about presentation + version-line render is
    /// driven deterministically (the live bundle read is environment-dependent). Prod
    /// byte-identical: the default still evaluates to the same `CFBundleVersion ?? "dev"`.
    public init(model: WorkbenchViewModel) {
        self.init(model: model, buildHash: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")
    }

    init(model: WorkbenchViewModel, buildHash: String) {
        self.model = model
        self.buildHash = buildHash
    }

    private var aboutPresentation: WorkbenchShellAboutPresentation {
        WorkbenchShellAboutPresentation(buildHash: buildHash)
    }

    public var body: some View {
        WorkbenchShellAboutView(
            presentation: aboutPresentation,
            updateState: model.appShellUpdateState,
            updateActions: model.appShellUpdateActions,
            aboutActions: AppShellAboutActions(
                openRepository: openRepository,
                copyVersion: copyVersion,
                dismiss: { dismiss() }
            )
        )
        .frame(width: 520, height: 500)
    }

    /// The "View Repository" action — sends the repo URL through the `openURL` seam. Internal
    /// so a test can invoke it directly (the action closure is passed into the opaque shell
    /// `AppShellAboutView`, which ViewInspector cannot descend).
    func openRepository() {
        openURL(aboutPresentation.repositoryURL)
    }

    /// The "Copy Version" action — sends the version line through the `copyToPasteboard` seam.
    func copyVersion() {
        copyToPasteboard(aboutPresentation.versionLine)
    }
}

/// The boss decision-log review surface — a chronological audit of every call
/// the boss made about a waiting session and *why*, for auditing and tuning.
/// Reached from the boss pane and the ⌘K palette.
struct DecisionLogSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    /// Threaded into each `DecisionLogRow` so the row's `occurredAt` timestamp is
    /// deterministic under test (AN-007). Prod defaults to `.autoupdatingCurrent`
    /// (unchanged); the snapshot tests inject `.gmt`/`en_GB`.
    var timeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Boss Decision Log")
                        .font(.title3.weight(.semibold))
                    Text("Every decision the boss made about a waiting session, and why")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()
            if model.state.decisionLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No decisions recorded yet")
                        .font(.headline)
                    Text("When a session is waiting on you, the boss records what it would do and why here — automatically, as it checks in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.state.decisionLog) { decision in
                            DecisionLogRow(decision: decision, timeZone: timeZone, locale: locale) { autoAdvance in
                                Task { await model.teachBoss(from: decision, autoAdvance: autoAdvance) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 640, height: 560)
    }
}

/// The prioritized, triageable **decision inbox** — the queue of waiting
/// sessions that actually need the operator, grouped by severity and walkable
/// with ⌘J. A focused variant of `DecisionLogSheet`: it shows only OPEN items
/// (`openInboxGroups`) — typically 1–2 even with ~10 mostly-dormant sessions —
/// reusing `DecisionLogRow` in `.inbox` mode (severity accent + Ack / Snooze /
/// Resolve next to the existing Teach control). A toggle drops to the full raw
/// log for auditing. `now` is refreshed periodically so a snooze that elapses
/// while the sheet is open resurfaces on its own.
struct DecisionInboxSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    /// Inbox (open queue) vs the full chronological log. Defaults to the inbox;
    /// the toggle keeps the raw log reachable without a second entry point. Seeded
    /// via `init(initialShowFullLog:)` (prod default `false`).
    @State private var showFullLog: Bool
    /// Test-only clock override. `nil` in production → the `TimelineView`'s
    /// periodic `context.date` drives `openInboxGroups(now:)` (the sheet keeps
    /// re-grouping every 30s so an elapsed snooze drops back into the queue). A
    /// test injects a fixed `Date` for a deterministic grouping. The
    /// `TimelineView(.periodic)` driver is RETAINED — production is unchanged.
    var now: Date? = nil
    /// Threaded into each `DecisionLogRow` so the row's `occurredAt` timestamp is
    /// deterministic under test (AN-007). Prod defaults to `.autoupdatingCurrent`
    /// (unchanged); the snapshot tests inject `.gmt`/`en_GB`. (Orthogonal to `now`,
    /// which drives the open-inbox GROUPING, not the row timestamp render.)
    var timeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent

    /// Init seam (parallels the `now`/`timeZone`/`locale` test seams). Production callers omit
    /// every argument past `model`, so the sheet opens on the Inbox with the live clock —
    /// byte-identical to the prior synthesized init. A test seeds `initialShowFullLog: true` to
    /// render the full-log arm directly (ViewInspector re-seeds `@State` per inspect, so the
    /// in-view Picker/"View full decision log" toggle is not reachable through a `.tap()` re-render;
    /// the init seam is the sanctioned way to drive the `showFullLog == true` branch — prod default
    /// is UNCHANGED at `false`).
    init(
        model: WorkbenchViewModel,
        now: Date? = nil,
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        initialShowFullLog: Bool = false
    ) {
        self.model = model
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self._showFullLog = State(initialValue: initialShowFullLog)
    }

    var body: some View {
        // Re-evaluate every 30s so an elapsed snooze drops back into the queue
        // without the operator reopening the sheet.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: now ?? context.date)
        }
        .frame(width: 640, height: 560)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let groups = model.state.openInboxGroups(now: now)
        let openCount = groups.reduce(0) { $0 + $1.decisions.count }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showFullLog ? "Boss Decision Log" : "Decision Inbox")
                        .font(.title3.weight(.semibold))
                    Text(showFullLog
                        ? "Every decision the boss made about a waiting session, and why"
                        : inboxSubtitle(openCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $showFullLog) {
                    Text("Inbox").tag(false)
                    Text("Log").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()
            if showFullLog {
                fullLog
            } else if groups.isEmpty {
                inboxZero
            } else {
                inboxQueue(groups)
            }
        }
    }

    private func inboxSubtitle(_ count: Int) -> String {
        switch count {
        case 0: return "Nothing needs you right now"
        case 1: return "1 session needs a decision"
        default: return "\(count) sessions need a decision"
        }
    }

    /// The prioritized, severity-grouped open queue. Each row is the shared
    /// `DecisionLogRow` in `.inbox` mode, wired to the model's triage actions.
    private func inboxQueue(_ groups: [InboxSeverityGroup]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.severity.label.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        ForEach(group.decisions) { decision in
                            DecisionLogRow(
                                decision: decision,
                                mode: .inbox,
                                timeZone: timeZone,
                                locale: locale,
                                onTeach: { autoAdvance in
                                    Task { await model.teachBoss(from: decision, autoAdvance: autoAdvance) }
                                },
                                onAcknowledge: { model.acknowledgeDecision(decision) },
                                onSnooze: { model.snoozeDecision(decision, for: $0) },
                                onResolve: { model.resolveDecision(decision) }
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    /// "Inbox zero" — distinct from the log's "no decisions yet": here the boss
    /// has decided things, they're just all handled / snoozed.
    private var inboxZero: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Inbox zero")
                .font(.headline)
            Text("No session needs a decision right now. When the boss escalates one, it shows here — most urgent first — and ⌘J jumps you to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if !model.state.decisionLog.isEmpty {
                Button("View full decision log") { showFullLog = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// The full chronological audit — identical to `DecisionLogSheet`'s body,
    /// in `.log` mode (Teach only, no triage controls).
    @ViewBuilder
    private var fullLog: some View {
        if model.state.decisionLog.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No decisions recorded yet")
                    .font(.headline)
                Text("When a session is waiting on you, the boss records what it would do and why here — automatically, as it checks in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.state.decisionLog) { decision in
                        DecisionLogRow(decision: decision, timeZone: timeZone, locale: locale) { autoAdvance in
                            Task { await model.teachBoss(from: decision, autoAdvance: autoAdvance) }
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

/// The in-app bug reporter. The operator types what went wrong; submitting
/// bundles a window screenshot, the support diagnostics zip, and a `report.md`
/// (app/OS version, sessions, recent boss decisions + actions) into a stable,
/// timestamped folder under the app-support root. Reached from the More menu
/// (⌘⇧B) and the ⌘K palette.
struct ReportBugSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report a Bug")
                        .font(.title3.weight(.semibold))
                    Text("Bundles a screenshot, diagnostics, and recent activity for debugging")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("What happened?")
                    .font(.headline)
                ZStack(alignment: .topLeading) {
                    // Placeholder sits BEHIND a transparent TextEditor so the
                    // caret and typed text land exactly on top of it — matched
                    // insets keep them aligned (the editor's own line-fragment
                    // padding is ~5pt, so editor leading 4 ≈ placeholder 9).
                    if model.bugReportNote.isEmpty {
                        Text("Describe what you were doing and what went wrong. Steps to reproduce help a lot.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.bugReportNote)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }
                .frame(minHeight: 160)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )

                Label(
                    ReportBugDisclosureCopy.disclosure,
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let error = model.bugReportError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let url = model.lastBugReportURL {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Saved bug report: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        ForEach(model.lastBugReportWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            Button {
                                model.revealLastBugReport()
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            .controlSize(.small)
                            Button {
                                model.copyBugReportPath()
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            .controlSize(.small)
                            if model.bugReportIssueURL == nil {
                                Button {
                                    model.fileLastBugReportAsGitHubIssue()
                                } label: {
                                    Label("File as GitHub Issue", systemImage: "ladybug")
                                }
                                .controlSize(.small)
                                .disabled(model.bugReportIssueIsFiling)
                            }
                            if model.bugReportIssueIsFiling {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        if let issueURL = model.bugReportIssueURL {
                            HStack(spacing: 8) {
                                Label("Filed: \(issueURL)", systemImage: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button {
                                    model.openLastBugReportIssue()
                                } label: {
                                    Label("Open Issue", systemImage: "arrow.up.right.square")
                                }
                                .controlSize(.small)
                            }
                        }
                        if let issueError = model.bugReportIssueError {
                            Label(issueError, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                Spacer(minLength: 0)

                HStack {
                    Button {
                        model.revealBugReportsFolder()
                    } label: {
                        Label("Open Reports Folder", systemImage: "ladybug")
                    }
                    .controlSize(.small)
                    Spacer()
                    if model.bugReportIsSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    Button {
                        model.submitBugReport()
                    } label: {
                        Text("Create Report")
                    }
                    // ⌘↩ rather than plain Return: the note is a multi-line
                    // TextEditor that swallows Return, so ⌘Return is the
                    // reliable "submit the form" gesture.
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(model.bugReportIsSubmitting)
                    .help("Create the report (⌘↩)")
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
    }
}

struct DecisionLogRow: View {
    /// How the row renders. `.log` is the flat reverse-chron audit row (Teach
    /// only). `.inbox` is the prioritized-queue variant: a severity accent plus
    /// Ack / Snooze / Resolve triage controls next to Teach. ~90% of the row is
    /// shared between the two modes — only the accent and the footer differ.
    enum Mode: Equatable { case log, inbox }

    let decision: BossInboxDecision
    var mode: Mode = .log
    /// The zone + locale the row's `occurredAt` timestamp renders in (AN-007).
    /// Both default to the operator's local values (`.autoupdatingCurrent`) so
    /// production is byte-identical to the prior `decision.occurredAt.formatted(…)`
    /// — `Date.FormatStyle`'s own defaults are also `.autoupdatingCurrent`, so the
    /// explicit seam is a no-op in prod. The snapshot tests inject `.gmt` + `en_GB`
    /// for a reference byte-identical across CI runner zones AND locales (the C0
    /// recipe — `.abbreviated`/`.shortened` is both zone- and locale-sensitive, and
    /// a body-evaluated `.formatted()` String is NOT reliably re-pinned by the host
    /// process-TZ pin, the C0 determinism root cause).
    var timeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent
    /// Teach the boss from this decision. `true` = reinforce (auto-advance these
    /// next time), `false` = correct (always ask me).
    var onTeach: (Bool) -> Void
    /// Inbox-mode triage actions (nil in `.log` mode). Acknowledge / snooze for
    /// an interval / resolve — wired to the pure `WorkspaceState` mutations.
    var onAcknowledge: (() -> Void)?
    var onSnooze: ((TimeInterval) -> Void)?
    var onResolve: (() -> Void)?
    @State private var taught: Bool

    /// Explicit init mirroring the prior synthesized memberwise init (every param keeps its
    /// default, so all call sites are unchanged) PLUS `initialTaught` — the same `@State`
    /// init-seam used across this campaign (initialShowsAdvanced/initialShowsInspector/…). The
    /// default `false` is the prod behavior UNCHANGED; a test seeds `true` so the
    /// `if taught { "Sent to boss" }` TRUE arm renders (otherwise unreachable: the
    /// `taught = true` set inside the Teach Menu tap is not re-inspectable post-toggle).
    init(
        decision: BossInboxDecision,
        mode: Mode = .log,
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        onTeach: @escaping (Bool) -> Void,
        onAcknowledge: (() -> Void)? = nil,
        onSnooze: ((TimeInterval) -> Void)? = nil,
        onResolve: (() -> Void)? = nil,
        initialTaught: Bool = false
    ) {
        self.decision = decision
        self.mode = mode
        self.timeZone = timeZone
        self.locale = locale
        self.onTeach = onTeach
        self.onAcknowledge = onAcknowledge
        self.onSnooze = onSnooze
        self.onResolve = onResolve
        _taught = State(initialValue: initialTaught)
    }

    /// Plain-language vocabulary for the status/source footer and the teach
    /// control (#U23a) — the single source so the row never prints raw enum
    /// rawValues or inverts the teach polarity per kind.
    private let phrasebook = DecisionLogPhrasebook()

    /// The severity tier of this decision, for the inbox accent + label.
    private var severity: DecisionSeverity { DecisionSeverity.of(decision) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kindLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(kindColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(kindColor)
                Text(decision.sessionName ?? "unknown session")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let friend = decision.friendName {
                    Text("· \(friend)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                // AN-007: render the timestamp through the shared deterministic
                // seam (injected `.gmt`/`en_GB` in tests; `.autoupdatingCurrent`
                // defaults keep prod byte-identical to the prior `.formatted(…)`).
                Text(decision.occurredAt.workbenchTimeText(
                    date: .abbreviated, time: .shortened, timeZone: timeZone, locale: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !decision.prompt.isEmpty {
                Text(decision.prompt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
            if let proposed = decision.proposedInput, !proposed.isEmpty {
                rowDetail("Proposed input", proposed, mono: true)
            }
            if let pref = decision.preferenceCited, !pref.isEmpty {
                rowDetail("Preference", pref)
            }
            if !decision.reasoning.isEmpty {
                rowDetail("Reasoning", decision.reasoning)
            }
            HStack(spacing: 10) {
                if let confidence = decision.confidence {
                    Text("confidence \(Int((confidence * 100).rounded()))%")
                }
                // #U23a: plain language, not raw telemetry — "Sent" not
                // "status: applied", "decided by: Boss Watch" not
                // "source: boss:slugger". The raw values stay in the tooltip for
                // power users / the raw-log disclosure.
                Text(phrasebook.statusPhrase(decision.status))
                Text("· decided by: \(phrasebook.decidedBy(source: decision.source))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("Raw: status \(decision.status.rawValue) · source \(decision.source)")
            HStack(spacing: 8) {
                // Inbox mode adds triage controls next to Teach: clear an item
                // without leaving the queue (Ack), defer it (Snooze), or close
                // it (Resolve). All three are no-ops in `.log` mode (closures nil).
                if mode == .inbox {
                    if let onResolve {
                        Button {
                            onResolve()
                        } label: {
                            Label("Resolve", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Mark this handled and remove it from the inbox")
                    }
                    if let onSnooze {
                        Menu {
                            Button("1 hour") { onSnooze(3600) }
                            // Computed at tap time, not render time, so "end of
                            // day" is measured from when the operator chooses it.
                            Button("Until end of day") { onSnooze(WorkbenchTriageInterval.untilEndOfDay()) }
                            Button("1 day") { onSnooze(86_400) }
                        } label: {
                            Label("Snooze", systemImage: "clock")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Hide this from the inbox until later; it resurfaces when the snooze elapses")
                    }
                    if let onAcknowledge {
                        Button {
                            onAcknowledge()
                        } label: {
                            Label("Ack", systemImage: "eye")
                        }
                        .buttonStyle(.borderless)
                        .help("Acknowledge — seen and parked, removed from the open queue")
                    }
                    Divider().frame(height: 12)
                }
                if taught {
                    Label("Sent to boss", systemImage: "paperplane.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Request sent. The boss's acknowledgement is in the action log.")
                } else {
                    // #U23a: present BOTH teach intents explicitly so the
                    // operator never has to decode an inverting button label.
                    // "Teach the boss ▾" → "Do this automatically next time" /
                    // "Always ask me", with the current default marked. The
                    // polarity is the pure `reinforces` flag, kind-independent.
                    Menu {
                        ForEach(phrasebook.teachOptions(for: decision.kind)) { option in
                            Button {
                                onTeach(option.reinforces)
                                taught = true
                            } label: {
                                if option.isCurrent {
                                    Label("\(option.title) (current)", systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        Label("Teach the boss", systemImage: "graduationcap")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption2)
                    .help("Tell the boss what to do next time for \(decision.friendName ?? "this friend") — automatically advance, or always ask you.")
                }
            }
            .font(.caption2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(rowFill))
        // Inbox mode adds a leading severity accent stripe + a tinted border so
        // a critical item reads as urgent at a glance; the log keeps its neutral
        // chrome.
        .overlay(alignment: .leading) {
            if mode == .inbox {
                RoundedRectangle(cornerRadius: 3)
                    .fill(severityColor)
                    .frame(width: 4)
                    .padding(.vertical, 6)
                    .padding(.leading, 2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(mode == .inbox ? severityColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// Background fill — neutral for the log; a faint severity tint for the inbox.
    private var rowFill: SwiftUI.Color {
        mode == .inbox ? severityColor.opacity(0.06) : Color.primary.opacity(0.04)
    }

    /// Accent color per severity tier, reused for the stripe and border.
    private var severityColor: SwiftUI.Color {
        switch severity {
        case .critical: return .red
        case .elevated: return .orange
        case .normal: return .blue
        case .low: return .secondary
        }
    }

    private func rowDetail(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindLabel: String {
        switch decision.kind {
        case .autoAdvance: return "Auto-advance"
        case .escalate: return "Escalate"
        case .hold: return "Hold"
        }
    }

    private var kindColor: SwiftUI.Color {
        switch decision.kind {
        case .autoAdvance: return .green
        case .escalate: return .orange
        case .hold: return .secondary
        }
    }
}

/// Default detail-pane content when nothing is selected: surface the agent
/// hatching + onboarding entry points instead of an empty "no session" card.
struct AgentHomeEmptyState: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        // The content lives in a ScrollView so its height is bounded by the
        // detail viewport. A bare greedy VStack (.frame(maxHeight:.infinity,
        // alignment:.top)) here made the NavigationSplitView lay out ~2.5x the
        // window height and shift, blanking BOTH columns — a SwiftUI sizing
        // pathology. The ScrollView clamps it and can't propagate an over-tall
        // ideal to the split view.
        ScrollView {
            VStack(alignment: .center, spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "infinity")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    // Terminals-first: lead with purpose, not a setup demand. The
                    // six-word story is the cut-test — "Your terminals. An agent
                    // runs them." Copy lives in Core (AgentHomeEmptyStateCopy) so
                    // it's pinned by tests, not buried as a view literal.
                    Text(AgentHomeEmptyStateCopy.headline)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(AgentHomeEmptyStateCopy.subtext)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 540)
                }
                HStack(spacing: 12) {
                    // Primary, gate-free action. ⌘N has no gate; this is the whole
                    // point of the product, so it's the prominent button. Unit 4:
                    // open a blank login-shell terminal INSTANTLY — zero typing,
                    // no sheet — matching the help text "Open a blank terminal
                    // session." (The sidebar New Terminal / ⌘N still open the
                    // sheet for the typed-command path.)
                    Button {
                        model.createBlankTerminal()
                    } label: {
                        Label(AgentHomeEmptyStateCopy.newTerminalButton, systemImage: "plus")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Open a blank terminal session.")

                    // Secondary opt-in: the (now opt-in) boss wizard — same call
                    // the old prominent "Set Up Workbench" button used.
                    Button {
                        model.presentOnboarding()
                    } label: {
                        Label(AgentHomeEmptyStateCopy.setUpBossButton, systemImage: "wand.and.stars")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Choose a boss to watch the whole Mac, connect its tools, and bring back recent terminals.")

                    // Lowest weight: create a new agent. U18 — opens the native
                    // "Create your agent" form (name + provider + credentials, headless),
                    // NOT the raw `ouro hatch` CLI pane.
                    Button {
                        model.presentNewAgentProviderConfigForm()
                    } label: {
                        Label(AgentHomeEmptyStateCopy.createAgentButton, systemImage: "sparkles")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(AgentHomeEmptyStateCopy.createAgentHelp)
                }
                if !model.ouroAgents.isEmpty {
                    // #U36: the "Installed agents" card is an honest launchpad, not
                    // an inert look-alike of the sidebar. Each row is the SAME
                    // interactive SidebarAgentRow (a Button → selectAgent,
                    // keyboard-reachable, .help(agent.detail)) so clicking it
                    // selects + inspects that agent exactly like the sidebar. A
                    // non-ready row shows a human-readable reason (disabled /
                    // agent.json missing / invalid config) instead of a wordless
                    // orange dot, via the InstalledAgentRowPresentation seam.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            Text("Installed agents")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.ouroAgents) { agent in
                            VStack(alignment: .leading, spacing: 2) {
                                SidebarAgentRow(
                                    agent: agent,
                                    isBoss: agent.name == model.state.boss.agentName,
                                    isSelected: false,
                                    verdict: model.agentOutwardVerdicts[agent.name],
                                    isChecking: model.agentChecksInFlight.contains(agent.name),
                                    select: { model.selectAgent(agent.name) }
                                )
                                if let reason = InstalledAgentRowPresentation.reason(
                                    for: agent.status,
                                    detail: agent.detail
                                ) {
                                    Text(reason)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 20)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 440)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The persistent filter field at the top of the sidebar. Narrows the visible
/// session list as the operator types (matches name / group, plus `owner:` and
/// `status:` tokens — see `SidebarSessionFilter`). Distinct from the
/// in-terminal ⌘F search and the ⌘K command palette. Empty = everything shown.
struct SidebarFilterField: View {
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // U19(c): a structured example in the placeholder so the grammar is
                // discoverable at the spot the operator already looks — plain-text
                // filtering still works with zero learning.
                TextField("Filter — try status:waiting", text: $model.sidebarFilter)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($fieldIsFocused)
                    .help("Filter the session list: matches name or group; structured queries search every workspace — try owner:agent, owner:human, owner:<name>, or status:waiting")
                if !model.sidebarFilter.isEmpty {
                    Button {
                        model.sidebarFilter = ""
                        fieldIsFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .accessibilityLabel("Clear session filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if model.sidebarFilterIsActive {
                // U19(a): scope is never silent — a structured query reads "Searching all
                // workspaces", a plain one names the current workspace.
                Text(SidebarFilterPresentation.scopeIndicator(
                    isGlobal: model.sidebarFilterIsGlobal,
                    workspaceName: model.selectedProject?.name
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            } else {
                // U19(c): tap-to-insert suggestion chips surface the structured grammar
                // without the operator having to discover the token syntax.
                HStack(spacing: 5) {
                    ForEach(SidebarFilterField.suggestionChips, id: \.token) { chip in
                        Button {
                            model.sidebarFilter = chip.token
                            fieldIsFocused = true
                        } label: {
                            Text(chip.label)
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .help("Filter by \(chip.label.lowercased()) — searches every workspace")
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 10)
    }

    /// U19(c): one-tap structured-token chips. Inserting one flips the search global.
    private static let suggestionChips: [(label: String, token: String)] = [
        (label: "Waiting", token: "status:waiting"),
        (label: "Agent", token: "owner:agent"),
        (label: "Idle", token: "status:idle"),
    ]
}

public struct WorkbenchSidebarView: View {
    @ObservedObject var model: WorkbenchViewModel

    public init(model: WorkbenchViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 6) {
            SidebarFilterField(model: model)
                .padding(.top, 28)
            sessionList
        }
        // Keep the per-session chips live while the sidebar is on screen. The
        // refresh is cheap and self-throttling — it only re-tails transcripts
        // for sessions with recent output (dormant ones are carried forward) —
        // so a slow tick is enough to feel current without hammering the disk.
        // Timer-free (a sleeping Task), matching the app's existing
        // TimelineView-driven refresh posture and staying @MainActor-clean.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SessionChip.refreshIntervalNanoseconds)
                if Task.isCancelled { break }
                model.refreshSessionActivity()
            }
        }
    }

    private var sessionList: some View {
        List(selection: $model.selectedEntryID) {
            Section(WorkbenchSurfacePolicy.bossSectionTitle) {
                ForEach(model.ouroAgents) { agent in
                    SidebarAgentRow(
                        agent: agent,
                        isBoss: model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame,
                        isSelected: model.selectedAgentName?.caseInsensitiveCompare(agent.name) == .orderedSame,
                        verdict: model.agentOutwardVerdicts[agent.name],
                        isChecking: model.agentChecksInFlight.contains(agent.name),
                        select: { model.selectAgent(agent.name) }
                    )
                }
                if model.ouroAgents.isEmpty {
                    // U18: the newcomer's first-agent row opens the native "Create your
                    // agent" form, NOT the raw `ouro hatch` CLI pane.
                    SidebarActionRow(title: "Create Your First Agent", systemImage: "sparkles") {
                        model.presentNewAgentProviderConfigForm()
                    }
                } else {
                    // U18: create goes native; clone keeps its dedicated Git-remote sheet.
                    SidebarActionRow(title: "Create Agent", systemImage: "plus") {
                        model.presentNewAgentProviderConfigForm()
                    }
                    SidebarActionRow(title: "Clone from Git…", systemImage: "arrow.down.doc") {
                        model.presentCloneAgentSheet()
                    }
                }
            }
            // Slice ②b — the sidebar renders the persisted `state.workspaces` as named
            // rows (the design's visible truth), via the pure
            // `WorkspaceSidebarPresentation` seam. Each workspace row shows its
            // `effectiveName` + a lean attention summary (NO PWD dump, NO cost); its
            // active tabs render beneath it by `effectiveTabName`, navigable here while
            // the cmux tab-strip surfaces the ACTIVE workspace's tabs across the top
            // (Unit 3). The old projects-as-workspaces surface + the "Terminals in
            // <name>" framing are gone (DB1 render swap; the WorkbenchProject backing
            // model stays, just invisible). DB8: no in-app "New Workspace" row (②d).
            Section(WorkbenchSurfacePolicy.workspaceSectionTitle) {
                // FIX PASS (FP5) — LEAN-CMUX layout: the sidebar shows ONLY lean
                // workspace rows (name + attention summary; + the "no tabs yet" marker
                // for an empty workspace). Tabs live SOLELY in the top strip
                // (`WorkspaceTabStrip`), which renders the active workspace's tabs with
                // the active filter applied (the nested per-tab `TerminalAgentRow`s that
                // used to live here are gone — they duplicated the strip and re-derived
                // the filter against the wrong list). `workspaceSidebarModel.rows` is
                // empty when there are no workspaces, so the section collapses to just
                // the New Terminal row.
                ForEach(model.workspaceSidebarModel.rows) { row in
                    WorkspaceSidebarRow(row: row, model: model)
                    if row.isEmpty {
                        // FORK #3 / DB5 — an empty workspace renders its row + an inline
                        // "no tabs yet" marker, never blank pixels (onboarding ③ seeds
                        // legitimately-empty workspaces).
                        SidebarWorkspaceEmptyRow()
                    }
                }
                SidebarActionRow(title: "New Terminal", systemImage: "plus") {
                    model.isNewSessionSheetPresented = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            if !model.archivedSessionEntries.isEmpty {
                Section("Archived") {
                    ForEach(model.archivedSessionEntries) { entry in
                        TerminalAgentRow(
                            entry: entry,
                            isSelected: model.selectedEntryID == entry.id,
                            cliName: model.cliName(for: entry),
                            health: model.executableHealth(for: entry)
                        )
                            .tag(entry.id)
                            .contextMenu {
                                TerminalRowContextMenu(entry: entry, model: model)
                            }
                    }
                }
            }
            // U8b: the section's visibility, its row text, the hover help, the
            // sheet header, and the sheet's row count ALL derive from the single
            // `recoveryDigest` so they can never disagree — a lossless-reattach-
            // only workspace never reads "0 recovery actions" over a non-empty list.
            if WorkbenchSurfacePolicy.shouldShowRecovery(recoverableCount: model.recoveryDigest.actionableCount) {
                Section("Recovery") {
                    Button {
                        model.isRecoverySheetPresented = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle")
                                .foregroundStyle(Color.orange)
                            Text(model.recoveryDigest.statusLine)
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.recoveryDigest.helpText)
                }
            }
        }
    }
}

/// Slice ②b — a LEAN named-workspace header row: the workspace's `effectiveName` + a
/// glanceable attention summary glyph (from the pure `WorkspaceSidebarPresentation`
/// seam's `WorkspaceRowContext`). Selecting it makes the workspace active (its tabs
/// surface in the cmux tab-strip). NO PWD dump, NO cost — the only work-context shown
/// is the already-available attention summary (the design's lean-row rule).
struct WorkspaceSidebarRow: View {
    var row: WorkspaceRow
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        // Slice ②d — swap the row label for an inline rename editor while THIS workspace
        // is being renamed (D2d-3 inline editor, not a sheet); else render the normal row.
        if model.inlineRename.isEditing(.workspace(row.id)) {
            InlineRenameEditor(model: model)
                .padding(.vertical, 1)
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button {
            model.selectedWorkspaceID = row.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: row.isPinned ? "pin.fill" : (row.isActive ? "square.stack.3d.up.fill" : "square.stack.3d.up"))
                    .foregroundStyle(row.isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(row.effectiveName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fontWeight(row.isActive ? .semibold : .regular)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let summary = row.context.summary, summary != .idle {
                    Image(systemName: summary.healthSymbol)
                        .font(.caption2)
                        .foregroundStyle(summary.healthColor)
                        .help(row.context.needsAttention ? "\(summary.healthLabel) — needs you" : summary.healthLabel)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            WorkspaceRowContextMenu(row: row, model: model)
        }
    }

    private var accessibilityLabel: String {
        var pieces = [row.effectiveName]
        pieces.append(row.isActive ? "active workspace" : "workspace")
        if row.isPinned { pieces.append("pinned") }
        pieces.append("\(row.tabs.count) tabs")
        if let summary = row.context.summary, summary != .idle {
            pieces.append(row.context.needsAttention ? "\(summary.healthLabel), needs you" : summary.healthLabel)
        }
        return pieces.joined(separator: ", ")
    }
}

/// Slice ②d — the workspace row's context menu: Pin/Unpin, Rename Workspace… (⇧⌘R),
/// and — only when a custom override exists (D2d-2) — Remove Custom Workspace Name.
/// Mirrors `TerminalRowContextMenu`'s `Button { … } label: { Label(…) }` shape. The
/// "⇧⌘R" affordance is shown as the menu-item label so it reads like cmux; the actual
/// chord is wired through the menu-bar command dispatcher (D2d-8), which targets the
/// ACTIVE workspace (this menu's Rename item targets THIS row directly).
struct WorkspaceRowContextMenu: View {
    var row: WorkspaceSidebarPresentation.WorkspaceRow
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        Group {
            Button {
                model.toggleWorkspacePin(row.id)
            } label: {
                Label(
                    row.isPinned ? "Unpin Workspace" : "Pin Workspace",
                    systemImage: row.isPinned ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button {
                model.beginRename(.workspace(row.id), prefill: row.effectiveName)
            } label: {
                Label("Rename Workspace…  ⇧⌘R", systemImage: "pencil")
            }
            if row.nameOverride != nil {
                Button {
                    model.removeCustomWorkspaceName(row.id)
                } label: {
                    Label("Remove Custom Workspace Name", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }
}

/// Slice ②d — the inline rename editor shared by the workspace row and the tab button
/// (D2d-3). A `TextField` bound to `model.inlineRename.draft`, prefilled by `beginRename`;
/// Enter (`.onSubmit`) commits via `model.commitRename()`, Escape (`.onExitCommand`)
/// cancels via `model.cancelRename()`, and a caption matches the cmux affordance. The
/// empty/whitespace/unchanged guard lives in `WorkspaceRenameCommit` (D2d-1) behind
/// `commitRename`, so a blank commit just closes the editor without changing the name.
struct InlineRenameEditor: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Name", text: $model.inlineRename.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.commitRename() }
                .onExitCommand { model.cancelRename() }
            Text("Press Enter to rename, Escape to cancel.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rename")
    }
}

/// Slice ②b (FORK #3 / DB5) — the inline "no tabs yet" marker shown UNDER an empty
/// workspace's header so a just-created/seeded workspace is honest and never blank.
struct SidebarWorkspaceEmptyRow: View {
    var body: some View {
        Text("No tabs yet")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)
            .padding(.vertical, 1)
            .accessibilityLabel("No tabs yet")
    }
}

/// Slice ②b — the cmux tab-strip: a horizontal strip of the ACTIVE workspace's named
/// tabs across the top of the detail column. Tabs are sourced from the pure
/// `WorkspaceSidebarPresentation` active workspace (`model.activeWorkspaceRow`), NOT a
/// re-derived flat list, so the strip and sidebar can never disagree. Each tab is
/// labeled by `effectiveTabName`; selecting one sets `model.selectedEntryID` and
/// highlights it. An empty active workspace shows the "no tabs yet" marker (FORK #3).
/// Renders nothing when there's no active workspace (empty machine).
public struct WorkspaceTabStrip: View {
    @ObservedObject var model: WorkbenchViewModel

    public init(model: WorkbenchViewModel) {
        self.model = model
    }

    /// The active workspace's active tabs AFTER the sidebar filter (FP5 — the filter
    /// now lives in the strip; `workspaceTabRows` resolves the seam's active tabs and
    /// applies `SidebarSessionFilter`). The seam already dropped dangling/archived ids.
    private func filteredTabs(_ active: WorkspaceRow) -> [ResolvedTab] {
        model.workspaceTabRows(for: active).map(\.resolved)
    }

    /// Select a tab — sets the entry selection; the row's workspace stays active.
    private func select(_ tab: ResolvedTab) { model.selectedEntryID = tab.id }

    public var body: some View {
        if let active = model.activeWorkspaceRow {
            let filtered = filteredTabs(active)
            // FP4 — the filter empty-state is decided by the pure Core seam against the
            // FILTERED count (not the unfiltered list): a filter is active AND it hid
            // every tab the workspace actually has.
            let filterHidAll = WorkspaceSidebarPresentation.stripFilterHidAllTabs(
                tabsBeforeFilter: active.tabs.count,
                tabsAfterFilter: filtered.count,
                filterActive: model.sidebarFilterIsActive
            )
            VStack(spacing: 0) {
                if filterHidAll {
                    // FP4 — the filter hid every tab in the active workspace: show an
                    // explicit, quoted "No sessions match …" state with a one-click
                    // Clear, distinct from a genuinely-empty workspace.
                    stripFilterEmptyState
                } else if filtered.isEmpty {
                    // FORK #3 / DB5 — never blank: an empty active workspace (no tabs at
                    // all, no filter hiding them) still shows an honest "no tabs yet".
                    HStack {
                        Text("\(active.effectiveName) — no tabs yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(filtered) { tab in
                                tabButton(tab)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                }
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs in \(active.effectiveName)")
        }
    }

    /// FP4 — the in-strip "No sessions match …" empty-state with a one-click Clear.
    /// Reuses the Core-pinned `SidebarFilterPresentation` copy (the same text the
    /// sidebar previously showed) so the filter's voice stays consistent.
    private var stripFilterEmptyState: some View {
        HStack(spacing: 8) {
            Label(
                SidebarFilterPresentation.emptyStateTitle(query: model.sidebarFilter),
                systemImage: "line.3.horizontal.decrease.circle"
            )
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                model.sidebarFilter = ""
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func tabButton(_ tab: ResolvedTab) -> some View {
        let isSelected = model.selectedEntryID == tab.id
        // Slice ②d — swap the tab label for the inline rename editor while THIS tab is
        // being renamed (D2d-3); else render the normal tab button.
        if model.inlineRename.isEditing(.tab(tab.id)) {
            InlineRenameEditor(model: model)
                .frame(width: 180)
                .padding(.horizontal, 4)
        } else {
            Button {
                select(tab)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tab.attention.healthSymbol)
                        .font(.caption2)
                        .foregroundStyle(tab.attention.healthColor)
                    Text(tab.effectiveTabName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fontWeight(isSelected ? .semibold : .regular)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.attention.healthLabel)
            .accessibilityLabel("\(tab.effectiveTabName), \(tab.attention.healthLabel)\(isSelected ? ", selected" : "")")
            .contextMenu {
                WorkspaceTabContextMenu(tab: tab, model: model)
            }
        }
    }
}

/// Slice ②d — the tab's context menu: Rename Tab… (⌘R). Mirrors
/// `WorkspaceRowContextMenu`; the "⌘R" affordance is shown on the label (the chord is
/// wired through the command dispatcher targeting the selected tab; D2d-8). No tab-level
/// revert affordance this slice (cmux tab menu = Rename Tab only).
struct WorkspaceTabContextMenu: View {
    var tab: ResolvedTab
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        Button {
            model.beginRename(.tab(tab.id), prefill: tab.effectiveTabName)
        } label: {
            Label("Rename Tab…  ⌘R", systemImage: "pencil")
        }
    }
}

struct SidebarActionRow: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Compact sidebar row representing one Ouro agent bundle. Clicking selects
/// the agent in the detail pane; the boss flag and a health dot keep status
/// glanceable.
struct SidebarAgentRow: View {
    var agent: OuroAgentRecord
    var isBoss: Bool
    var isSelected: Bool
    /// The live outward-lane `ouro check` verdict for this agent, or `nil` when no live
    /// check has produced a verdict yet. Folded with `agent.status` + `isChecking` into an
    /// honest `LiveReadiness` so the row's dot/tooltip never false-green a config-only
    /// `.ready` that hasn't been live-confirmed.
    var verdict: ProviderConnectionVerdict?
    /// Whether a live outward check is currently in flight for this agent (→ "checking…").
    var isChecking: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isBoss {
                            Text("boss")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .fixedSize()
                        }
                    }
                    if let lane = agent.humanFacing?.summary {
                        Text(lane)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(InstalledAgentRowPresentation.help(for: liveReadiness, detail: agent.detail))
    }

    /// The honest, LIVE readiness for this row — the scanner's config-only `agent.status`
    /// folded with the real outward-lane verdict and the in-flight flag. The bug: the row
    /// used to render the config-only `.ready` as a green "ready" dot/tooltip WITHOUT a live
    /// check (slugger read "ready" while `ouro check` returned `401 … expired`). This is now
    /// only `.ready`/green when a live check actually returned `.working`.
    private var liveReadiness: InstalledAgentRowPresentation.LiveReadiness {
        InstalledAgentRowPresentation.liveReadiness(
            status: agent.status,
            verdict: verdict,
            isChecking: isChecking
        )
    }

    // Route the dot color through the shared Core seam, now LIVE-aware: the sidebar row and
    // the empty-state "Installed agents" card stay in agreement, and neither shows green
    // unless the live check confirmed it.
    private var statusColor: SwiftUI.Color {
        InstalledAgentRowPresentation.dotColor(for: liveReadiness).swiftUIColor
    }
}

private extension InstalledAgentRowPresentation.DotColor {
    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .green:
            return .green
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }
}

private extension BossMCPPillPresentation.SemanticColor {
    /// Map the framework-free pill colour class to SwiftUI. `.neutral` reads
    /// `.secondary` — the calm tone for a registered-but-runtime-unverified pill,
    /// distinct from both the confirmed green and the structural red.
    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .green:
            return .green
        case .neutral:
            return .secondary
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }
}

struct SidebarCountBadge: View {
    var count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 16, minHeight: 16)
            .background(.secondary.opacity(0.10), in: Capsule())
            .accessibilityLabel("\(count) active terminals")
    }
}

/// Right-click context menu shown when the user secondary-clicks a sidebar
/// terminal row. Mirrors the in-pane overflow menu so daily actions are
/// reachable with the macOS-native gesture instead of having to focus the
/// session and dig into the header chevron.
struct TerminalRowContextMenu: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        Group {
            Button {
                model.launch(entry)
            } label: {
                Label(
                    model.activeSession(for: entry) == nil ? "Launch" : "Restart",
                    systemImage: "play.fill"
                )
            }
            .disabled(entry.isArchived)
            if model.activeSession(for: entry) != nil {
                Button(role: .destructive) {
                    model.requestStop(entry)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            Divider()
            Button {
                Task { await model.runBossQuestion(about: entry) }
            } label: {
                Label("Ask Boss About This Session", systemImage: "bubble.left.and.text.bubble.right")
            }
            .disabled(model.bossCheckInIsRunning)
            Button {
                model.togglePin(for: entry)
            } label: {
                Label(
                    model.isPinned(entry) ? "Unpin from Top" : "Pin to Top",
                    systemImage: model.isPinned(entry) ? "pin.slash" : "pin"
                )
            }
            .disabled(entry.isArchived)
            Button {
                model.copyLaunchCommand(for: entry)
            } label: {
                Label("Copy Launch Command", systemImage: "doc.on.doc")
            }
            Button {
                model.copyTranscriptTail(for: entry)
            } label: {
                Label("Copy Last 20 Lines", systemImage: "doc.plaintext")
            }
            .disabled(model.latestRun(for: entry)?.transcriptPath == nil)
            Button {
                model.openWorkingDirectory(for: entry)
            } label: {
                Label("Open Working Directory", systemImage: "folder")
            }
            if model.isCustomSession(entry) {
                Divider()
                Button {
                    model.beginEditingSession(entry)
                } label: {
                    Label("Edit Session…", systemImage: "pencil")
                }
                .disabled(model.activeSession(for: entry) != nil)
                Button {
                    model.duplicateCustomSession(entry)
                } label: {
                    Label("Duplicate Session", systemImage: "plus.square.on.square")
                }
                Menu {
                    ForEach(model.state.projects) { project in
                        Button(project.name) {
                            model.moveSession(entry, to: project.id)
                        }
                        .disabled(project.id == entry.projectId)
                    }
                } label: {
                    Label("Move to Workspace", systemImage: "folder")
                }
                .disabled(model.activeSession(for: entry) != nil || model.state.projects.count < 2)
                if entry.isArchived {
                    Button {
                        model.restoreCustomSession(entry)
                    } label: {
                        Label("Restore", systemImage: "tray.and.arrow.up")
                    }
                } else {
                    Button {
                        model.archiveCustomSession(entry)
                    } label: {
                        Label("Archive Session", systemImage: "archivebox")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    model.requestDeleteCustomSession(entry)
                } label: {
                    Label("Delete Session…", systemImage: "trash")
                }
            }
        }
    }
}

struct TerminalAgentRow: View {
    var entry: ProcessEntry
    var isSelected: Bool
    /// Slice ②b — the operator-visible tab name. Defaults to `entry.name`; the
    /// workspace sidebar/tab-strip pass `entry.effectiveTabName` so a revertible
    /// `tabNameOverride` (②a) shows here without the row re-deriving it.
    var displayName: String? = nil
    var cliName: String?
    var health: ExecutableHealth?
    /// Git status of the session's working directory, when it's a repo. Drives
    /// the branch chip under the name. `nil` (or not-a-repo) renders nothing.
    var gitStatus: GitSessionStatus?
    /// When the entry has a currently-running process, the date it started.
    /// Drives the `5m` / `2h` elapsed-time pill in the row. `nil` skips the
    /// pill entirely — keeps the row uncluttered for idle / archived entries.
    var runningSince: Date?
    /// Test-only clock override, threaded into the `ElapsedTimePill` body AND the
    /// `accessibilityLabel` elapsed read so BOTH the pill's `TimelineView`-driven
    /// `Text` and the computed-property label string are deterministic under a
    /// snapshot test. `nil` in production → the live clock (`TimelineView`
    /// `context.date` for the pill; `Date()` for the label). Production behavior
    /// is unchanged.
    var now: Date? = nil
    /// Whether the entry is pinned to the top of its group. Shows a small
    /// pin glyph next to the name.
    var isPinned: Bool = false
    /// Derived activity (todo progress, current step, token/$) from the agent's
    /// structured transcript. `nil` → the chip shows only the free health facet.
    var activity: SessionActivity?
    /// Whether the session looks busy but its output has gone quiet (drives the
    /// chip's amber "stalled" glyph). Derived from `ProcessRun.lastOutputAt`.
    var isStalled: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                // Tail-truncate so 'Codex: hello! please…' beats 'Codex: h…can
                // make'. Middle-truncation hides the part of the name that
                // actually identifies what the session is doing — the
                // distinguishing detail is at the start, not the middle.
                Label {
                    HStack(spacing: 4) {
                        Text(displayName ?? entry.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Pinned to top")
                        }
                        if let badge = entry.owner.sidebarBadge {
                            Label(badge.label, systemImage: badge.symbol)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help("Owned by \(badge.label)")
                        }
                    }
                } icon: {
                    Image(systemName: rowIcon)
                }
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let cliName {
                    Text(cliName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let gitStatus, gitStatus.isRepo {
                    GitBranchChip(status: gitStatus)
                }
                // Glanceable per-session chip: health glyph + todo-progress +
                // token/$. Only rendered when it adds something beyond the
                // trailing StatusDot — i.e. there's derived activity to show or
                // the session is stalled. A plain idle shell shows nothing extra.
                if !entry.isArchived, activity != nil || isStalled {
                    SessionChip(attention: entry.attention, activity: activity, isStalled: isStalled)
                }
            }
            Spacer()
            if let runningSince {
                ElapsedTimePill(startDate: runningSince, now: now)
            }
            if let health, health.status != .available {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(health.detail)
            }
            StatusDot(attention: entry.attention)
        }
        .fontWeight(isSelected ? .semibold : .regular)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rowIcon: String {
        if entry.isArchived {
            return "archivebox"
        }
        return entry.kind == .shell ? "apple.terminal" : "terminal"
    }

    private var accessibilityLabel: String {
        var pieces = [displayName ?? entry.name]
        if let badge = entry.owner.sidebarBadge {
            pieces.append("owned by \(badge.label)")
        }
        if let cliName {
            pieces.append(cliName)
        }
        pieces.append(entry.attention.rawValue)
        pieces.append(entry.isArchived ? "archived" : "active")
        if let runningSince {
            pieces.append("running for \(ElapsedTimePill.coarseDescription(since: runningSince, now: now ?? Date()))")
        }
        if let health, health.status != .available {
            pieces.append(health.detail)
        }
        if let gitStatus, gitStatus.isRepo, let label = gitStatus.branchLabel {
            pieces.append("git \(label)\(gitStatus.dirty ? ", uncommitted changes" : "")")
        }
        return pieces.joined(separator: ", ")
    }
}

/// Compact git chip: branch name, a dirty dot when the tree has uncommitted
/// changes, and an ↑ahead/↓behind suffix. Renders nothing for a non-repo.
struct GitBranchChip: View {
    var status: GitSessionStatus

    var body: some View {
        if let label = status.branchLabel {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if status.dirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
                if let aheadBehind = status.aheadBehindLabel {
                    Text(aheadBehind)
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(helpText)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        parts.append("Branch: \(status.branchLabel ?? "unknown")")
        parts.append(status.dirty ? "uncommitted changes" : "clean")
        if status.ahead > 0 { parts.append("\(status.ahead) ahead") }
        if status.behind > 0 { parts.append("\(status.behind) behind") }
        return parts.joined(separator: " · ")
    }
}

/// Tiny "5m" / "2h 14m" pill rendered next to a running session's name in the
/// sidebar. Backed by a TimelineView so it ticks once a minute without the
/// view model needing a Timer; sub-minute updates would just noise the UI.
struct ElapsedTimePill: View {
    var startDate: Date
    /// Test-only clock override. `nil` in production → the `TimelineView`'s
    /// periodic `context.date` drives the elapsed string (the pill keeps ticking
    /// every 30s). A snapshot test injects a fixed `Date` so the rendered string
    /// is deterministic. The `TimelineView(.periodic)` driver is RETAINED either
    /// way — production behavior is unchanged.
    var now: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(WorkbenchElapsedFormatter.coarseDescription(since: startDate, now: now ?? context.date))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                )
                .help("Running since \(startDate.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    /// Shim re-exposing the Core formatter so the accessibility label code
    /// path in `TerminalAgentRow` doesn't need to import details from Core.
    static func coarseDescription(since start: Date, now: Date = Date()) -> String {
        WorkbenchElapsedFormatter.coarseDescription(since: start, now: now)
    }
}

/// Shared health color/label/glyph for an `AttentionState`, so the sidebar's
/// `StatusDot` and the new `SessionChip` health glyph render from one source of
/// truth (DRY). `Color` is SwiftUI, so this lives App-side rather than on the
/// Core enum.
extension AttentionState {
    var healthColor: SwiftUI.Color {
        switch self {
        case .idle: return .secondary
        case .active: return .green
        case .waitingOnHuman: return .orange
        case .blocked: return .red
        case .needsBossReview: return .blue
        }
    }

    /// SF Symbol that reads at a glance for each health state.
    var healthSymbol: String {
        switch self {
        case .idle: return "moon.zzz.fill"
        case .active: return "bolt.fill"
        case .waitingOnHuman: return "hand.raised.fill"
        case .blocked: return "exclamationmark.octagon.fill"
        case .needsBossReview: return "eye.fill"
        }
    }

    /// Short human label for tooltips / accessibility.
    var healthLabel: String {
        switch self {
        case .idle: return "Idle"
        case .active: return "Active"
        case .waitingOnHuman: return "Waiting on human"
        case .blocked: return "Blocked"
        case .needsBossReview: return "Needs boss review"
        }
    }
}

struct StatusDot: View {
    var attention: AttentionState

    var body: some View {
        Circle()
            .fill(attention.healthColor)
            .frame(width: 8, height: 8)
            .accessibilityLabel(attention.rawValue)
    }
}

/// Glanceable per-session chip distilled from the agent's structured transcript
/// (`SessionActivity`) plus the free `AttentionState` health facet: a health
/// glyph (amber "stalled" when the session looks busy but its output has gone
/// quiet) and a `done/total · current-step` todo mini.
///
/// Composed entirely from existing primitives (the shared
/// `AttentionState.health*` helpers). When there's no `SessionActivity` (a plain
/// shell, or a transcript that doesn't map), it renders just the health glyph
/// (+ "stalled") — never empty or broken.
struct SessionChip: View {
    var attention: AttentionState
    var activity: SessionActivity?
    var isStalled: Bool

    /// A session is "stalled" once its running output has been quiet this long.
    static let stalledThreshold: TimeInterval = 90
    /// Sessions whose latest run hasn't been active within this window are
    /// dormant — `refreshSessionActivity` skips re-tailing them.
    static let dormantThreshold: TimeInterval = 5 * 60
    /// How often the sidebar re-runs the (throttled) activity refresh.
    static let refreshIntervalNanoseconds: UInt64 = 15 * 1_000_000_000

    var body: some View {
        HStack(spacing: 6) {
            healthGlyph
            if let activity, let todoLabel = activity.todoLabel {
                todoMini(label: todoLabel, activeForm: activity.activeForm)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var effectiveColor: SwiftUI.Color {
        isStalled ? .yellow : attention.healthColor
    }

    private var effectiveSymbol: String {
        isStalled ? "zzz" : attention.healthSymbol
    }

    private var healthGlyph: some View {
        Image(systemName: effectiveSymbol)
            .font(.caption2)
            .foregroundStyle(effectiveColor)
            .help(isStalled ? "Stalled — running but output has gone quiet" : attention.healthLabel)
    }

    private func todoMini(label: String, activeForm: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checklist")
            Text(label)
                .monospacedDigit()
            if let activeForm, !activeForm.isEmpty {
                Text("· \(activeForm)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .help(activeForm.map { "\(label) todos · \($0)" } ?? "\(label) todos")
    }

    private var accessibilityLabel: String {
        var pieces: [String] = [isStalled ? "stalled" : attention.healthLabel]
        if let activity {
            if let todoLabel = activity.todoLabel {
                pieces.append("\(todoLabel) todos")
                if let activeForm = activity.activeForm { pieces.append(activeForm) }
            }
        }
        return pieces.joined(separator: ", ")
    }
}

struct HeaderView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            BossSelectorView(model: model)
                .layoutPriority(2)
            // #U31b: on a genuinely quiet machine (nobody waiting, 0 running, 0
            // actionable recovery) the line is just "0 running, nothing to
            // recover" — two information-free zeros that undercut the calm
            // no-boss header (U5). The pure seam hides it then and only renders
            // the informative text when there's something to say.
            let statusLine = model.headerStatusLine
            if statusLine.shouldShow {
                Text(statusLine.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(statusLine.text)
            }
            Spacer(minLength: 8)
            if let badge = model.updateBadgeText {
                Button {
                    model.presentUpdatePrompt()
                } label: {
                    Label(badge, systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("A new version of Ouro Workbench is ready — installs on quit, or click to install now.")
                .fixedSize()
            }
            AutonomyStatusButton(model: model)
                .fixedSize()
            // #U21: Boss Watch — the hands-off on/off master switch — sits next
            // to the TTFA pill so the operator SEES whether autonomy is running
            // and can flip it in one click, without opening the More overflow.
            // The TTFA pill reads readiness; this reads whether autonomy is
            // actually running — together they're the autonomy pair.
            BossWatchHeaderToggle(model: model)
                .fixedSize()
            Button {
                model.setBossPaneCollapsed(!model.state.bossPaneCollapsed)
            } label: {
                Label(
                    model.state.bossPaneCollapsed ? "Show Boss Pane" : "Hide Boss Pane",
                    systemImage: model.state.bossPaneCollapsed
                        ? "chevron.compact.down"
                        : "chevron.compact.up"
                )
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            // #U22: when the pane is collapsed the open-inbox count would vanish
            // entirely — so an escalation is never silently buried, the count
            // rides as a badge on the Show Boss Pane button.
            .overlay(alignment: .topTrailing) {
                if model.state.bossPaneCollapsed, let door = model.inboxDoor {
                    Text(door.badgeText)
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(InboxDoorPill.color(for: door.topSeverity), in: Capsule())
                        .offset(x: 5, y: -5)
                        .help(door.accessibilityLabel)
                }
            }
            .help(model.state.bossPaneCollapsed ? "Show boss dashboard" : "Hide boss dashboard")
            .fixedSize()
            Menu {
                Button {
                    model.presentOnboarding()
                } label: {
                    // U37(c): "Set up a boss" — match the opt-in-boss framing used
                    // by the empty-state CTA and the command palette.
                    Label("\(AgentHomeEmptyStateCopy.setUpBossButton)…", systemImage: "wand.and.stars")
                }
                // U18: create goes to the native "Create your agent" form; clone keeps
                // its own Git-remote sheet. No menu entry opens a raw `ouro hatch` pane.
                Button {
                    model.presentNewAgentProviderConfigForm()
                } label: {
                    Label("Create an Agent…", systemImage: "sparkles")
                }
                Button {
                    model.presentCloneAgentSheet()
                } label: {
                    Label("Clone an Agent from Git…", systemImage: "arrow.down.doc")
                }
                Button {
                    model.presentOpenWorkspacePanel()
                } label: {
                    Label("Open Workspace…", systemImage: "folder.badge.gearshape")
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button {
                    model.presentSaveWorkspacePanel()
                } label: {
                    Label("Save Workspace As…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.selectedProject == nil)
                if !model.recentWorkspacePaths.isEmpty {
                    Menu {
                        ForEach(model.recentWorkspacePaths, id: \.self) { path in
                            Button {
                                model.openWorkspaceConfig(at: path)
                            } label: {
                                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                            }
                            .help(path)
                        }
                        Divider()
                        Button(role: .destructive) {
                            model.recentWorkspacePaths = []
                            UserDefaults.standard.removeObject(
                                forKey: WorkbenchViewModel.recentWorkspacePathsDefaultsKey
                            )
                        } label: {
                            Label("Clear Recent Workspaces", systemImage: "xmark.bin")
                        }
                    } label: {
                        Label("Open Recent Workspace", systemImage: "clock")
                    }
                }
                Divider()
                Toggle(isOn: Binding(
                    get: { model.bossWatchIsEnabled },
                    set: { model.setBossWatchEnabled($0) }
                )) {
                    Label("Boss Watch", systemImage: "eye")
                }
                .disabled(model.bossCheckInIsRunning)
                Button {
                    Task {
                        model.refreshExecutableHealth()
                        model.refreshGitStatus()
                        model.refreshSessionActivity()
                        await model.refreshBossDashboard()
                    }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                Button {
                    model.isHarnessStatusPresented = true
                } label: {
                    Label("Harness Status…", systemImage: "waveform.path.ecg")
                }
                Button {
                    model.stopAllRunningSessions()
                } label: {
                    Label("Stop All Running…", systemImage: "stop.circle")
                }
                .disabled(model.activeSessions.isEmpty)
                Button {
                    model.recoverAllCrashedSessions()
                } label: {
                    Label("Recover All Crashed…", systemImage: "arrow.clockwise.circle")
                }
                .disabled(model.recoverableEntries.isEmpty)
                Divider()
                Button {
                    model.isSettingsSheetPresented = true
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: [.command])
                Button {
                    model.isShortcutHelpPresented = true
                } label: {
                    Label("Keyboard Shortcuts…", systemImage: "keyboard")
                }
                .keyboardShortcut("/", modifiers: [.command])
                Divider()
                Button {
                    model.isReportBugPresented = true
                } label: {
                    Label("Report a Bug…", systemImage: "ladybug")
                }
                // ⇧⌘B is registered as a menu-bar command (see OuroWorkbenchApp
                // .commands) so it fires even when a terminal has focus; the
                // shortcut isn't repeated here to avoid a duplicate binding.
                Button {
                    model.isAboutSheetPresented = true
                } label: {
                    Label("About Ouro Workbench…", systemImage: "info.circle")
                }
                Button {
                    Task { await model.checkForUpdatesAndPromptInstall() }
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.down.app")
                }
                Divider()
                Button(role: .destructive) {
                    model.isResetFirstRunConfirmationPresented = true
                } label: {
                    Label("Reset to Factory Defaults…", systemImage: "arrow.counterclockwise.circle")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More Workbench actions")
            Button {
                model.isCommandPalettePresented = true
            } label: {
                Label("Commands", systemImage: "command")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("k", modifiers: [.command])
            .help("Open the command palette (⌘K)")
            .fixedSize()
            Button {
                model.attemptCheckIn()
            } label: {
                Label(WorkbenchViewModel.checkInActionLabel, systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            // U12: only disabled while a check-in is in flight. With no boss the
            // button stays live and routes the tap to set-up (via attemptCheckIn)
            // rather than being a loud dead click — and it always has a tooltip.
            .disabled(model.bossCheckInIsRunning)
            .keyboardShortcut("i", modifiers: [.command])
            .help(model.checkInHelpText)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

/// #U21: the always-visible Boss Watch master switch. A glanceable pill — eye
/// glyph + "Watch On"/"Watch Off" — that shows whether autonomy is running and
/// flips it in one tap, right next to the TTFA readiness pill. The on/off label,
/// the toggle verb, and the help all come from the pure `BossWatchPresentation`
/// so this surface, the popover, and the dashboard never disagree.
struct BossWatchHeaderToggle: View {
    @ObservedObject var model: WorkbenchViewModel

    private var presentation: BossWatchPresentation { model.bossWatchPresentation }

    private var tint: SwiftUI.Color { presentation.isOn ? .green : .secondary }

    var body: some View {
        // #U31a: before a usable boss exists there's nothing to watch with — the
        // pill is hidden entirely so the no-boss header stays calm (U5).
        if presentation.isVisible {
            pill
        }
    }

    private var pill: some View {
        Button {
            model.setBossWatchEnabled(!model.bossWatchIsEnabled)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: presentation.isOn ? "eye.fill" : "eye.slash")
                    .font(.caption)
                Text(presentation.shortLabel)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.32), lineWidth: 1)
            )
            .foregroundStyle(tint == .green ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        // While a check-in is in flight, flipping the loop mid-run is unsafe —
        // mirror the More-menu toggle's disable.
        .disabled(model.bossCheckInIsRunning)
        .help("\(presentation.help)\nClick to \(presentation.toggleActionTitle.lowercased()).")
        .accessibilityLabel("Boss Watch \(presentation.label)")
    }
}

struct BossSelectorView: View {
    @ObservedObject var model: WorkbenchViewModel
    @State private var customBossIsPresented = false
    @State private var draftAgentName = ""

    private var bossAgent: OuroAgentRecord? {
        model.ouroAgent(named: model.state.boss.agentName)
    }

    /// Calm-vs-loud decision (Core seam). A brand-new first run has no boss chosen yet (empty
    /// `agentName`) — EXPECTED, so this renders calm/neutral. A named-but-missing or invalid boss
    /// is a REAL problem and stays loud red, exactly as before.
    private var presentation: HeaderCalmPresentation.Presentation {
        let installedHelp = bossAgent.map { "\($0.name): \($0.detail)" } ?? ""
        return HeaderCalmPresentation.resolve(
            bossAgentName: model.state.boss.agentName,
            bossAgentStatus: bossAgent?.status,
            autonomyState: model.autonomyReadiness.state,
            installedBossHelp: installedHelp
        )
    }

    private var bossHealthColor: SwiftUI.Color {
        presentation.bossDotColor.swiftUIColor
    }

    private var bossHealthHelp: String {
        presentation.bossHelp
    }

    var body: some View {
        Menu {
            if !model.bossAgentChoices.isEmpty {
                ForEach(model.bossAgentChoices, id: \.self) { agentName in
                    Button {
                        model.selectBoss(agentName: agentName)
                    } label: {
                        if agentName == model.state.boss.agentName {
                            Label(menuLabel(for: agentName), systemImage: "checkmark")
                        } else {
                            Text(menuLabel(for: agentName))
                        }
                    }
                }
                Divider()
            }
            Button {
                draftAgentName = model.state.boss.agentName
                customBossIsPresented = true
            } label: {
                Label("Use Other Boss…", systemImage: "person.badge.plus")
            }
            Divider()
            Button {
                model.selectAgent(model.state.boss.agentName)
            } label: {
                Label("Manage Agents…", systemImage: "person.2.badge.gearshape")
            }
            // U18: create goes native; clone keeps its Git-remote sheet.
            Button {
                model.presentNewAgentProviderConfigForm()
            } label: {
                Label("Create an Agent…", systemImage: "sparkles")
            }
            Button {
                model.presentCloneAgentSheet()
            } label: {
                Label("Clone an Agent from Git…", systemImage: "arrow.down.doc")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(bossHealthColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(presentation.bossLabelText)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if presentation.bossShowsMissingPill {
                    Text("missing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.14), in: Capsule())
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 260, alignment: .leading)
        .help(bossHealthHelp)
        .popover(isPresented: $customBossIsPresented) {
            BossAgentNamePopover(
                agentName: $draftAgentName,
                isPresented: $customBossIsPresented,
                model: model
            )
            .frame(width: 280)
            .padding(14)
        }
    }

    /// Render menu rows with a status suffix so users can see at a glance
    /// which choices are installed and which are remote-only hints. Names
    /// that don't resolve to a bundle pick up "(missing)".
    ///
    /// The config suffixes (disabled / no agent.json / invalid config) survive — they
    /// were already honest. What's NEW: a config-`.ready` agent whose LIVE outward check
    /// CONFIRMED a problem gets an honest "— sign-in needed" (auth-expired) or "— offline"
    /// (unreachable) suffix, so a dead-token boss doesn't read as a bare, pickable name.
    /// CALM: a pending/unverified/ready agent stays a bare name — the Connect step still
    /// verifies on actual selection, so we don't pre-alarm an unconfirmed choice.
    private func menuLabel(for agentName: String) -> String {
        guard let agent = model.ouroAgent(named: agentName) else {
            return "\(agentName) — missing"
        }
        switch agent.status {
        case .ready:
            let readiness = InstalledAgentRowPresentation.liveReadiness(
                status: agent.status,
                verdict: model.agentOutwardVerdicts[agentName],
                isChecking: model.agentChecksInFlight.contains(agentName)
            )
            switch readiness {
            case .authExpired:
                return "\(agentName) — sign-in needed"
            case .unreachable:
                return "\(agentName) — offline"
            case .ready, .checking, .unverified, .vaultLocked,
                 .disabled, .missingConfig, .invalidConfig:
                // Calm: ready/pending stay bare; the config-derived states can't occur
                // for a config-`.ready` agent and are handled by the outer switch anyway.
                return agentName
            }
        case .disabled:
            return "\(agentName) — disabled"
        case .missingConfig:
            return "\(agentName) — no agent.json"
        case .invalidConfig:
            return "\(agentName) — invalid config"
        }
    }
}

struct BossAgentNamePopover: View {
    @Binding var agentName: String
    @Binding var isPresented: Bool
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var fieldIsFocused: Bool

    private var trimmedAgentName: String {
        agentName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canApply: Bool {
        BossWorkbenchMCPRegistrar.isValidAgentBundleName(trimmedAgentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Boss Agent")
                .font(.headline)
            // U18: de-jargoned — "agent name", not "agent bundle name".
            TextField("agent name", text: $agentName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldIsFocused)
                .onSubmit(apply)
            if !trimmedAgentName.isEmpty && !canApply {
                Text("That name can't be used. Avoid slashes, colons, and backslashes.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Use") {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
        }
        .onAppear {
            fieldIsFocused = true
        }
    }

    private func apply() {
        guard canApply else {
            return
        }
        model.selectBoss(agentName: trimmedAgentName)
        isPresented = false
    }
}

struct OnboardingBossChoice: Identifiable {
    var id: String { name }
    var name: String
    var detail: String
    var status: OuroAgentBundleStatus?
    var isSelected: Bool

    var isUsable: Bool {
        status == .ready && BossWorkbenchMCPRegistrar.isValidAgentBundleName(name)
    }

    var statusLabel: String {
        // Honest at Choose Boss: `.ready` reads "installed", not "ready" — the live
        // connection check runs on the next page, so claiming readiness here would be
        // premature truth. The per-status copy lives in Core (OnboardingBossChoiceCopy).
        guard let status else {
            return "needs setup"
        }
        return OnboardingBossChoiceCopy.statusLabel(for: status)
    }

    var statusColor: SwiftUI.Color {
        switch status {
        case .ready?:
            return .green
        case .disabled?, .missingConfig?, .invalidConfig?, nil:
            return .orange
        }
    }

    // #U27: the per-row registration button (Enable Tools / Update Tools / Tools On) is gone —
    // Choose Boss is a pure pick that silently ensures tools on selection, and tool status is
    // shown/fixed in exactly one place (the Connect page). So `registrationActionTitle` /
    // `registrationIsCurrent` have no consumer and were removed with the button.
}

struct AutonomyStatusButton: View {
    @ObservedObject var model: WorkbenchViewModel
    @StateObject private var loginItem: LoginItemController
    @State private var isPresented: Bool

    /// `loginItem`/`initialIsPresented` default to a fresh `LoginItemController()` + `false` —
    /// the prod behavior UNCHANGED (the in-place `@StateObject` + collapsed popover it had
    /// before). The seams let a test inject a controller in a known state (so the
    /// `loginItemCheck` 4-case switch + the pill tint render deterministically) and seed the
    /// popover open (so the `.popover` content renders). Prod byte-identical at every call site.
    init(model: WorkbenchViewModel, loginItem: LoginItemController = LoginItemController(), initialIsPresented: Bool = false) {
        self.model = model
        _loginItem = StateObject(wrappedValue: loginItem)
        _isPresented = State(initialValue: initialIsPresented)
    }

    private var snapshot: AutonomyReadinessSnapshot {
        model.autonomyReadiness.appending(loginItemCheck)
    }

    /// Calm-vs-loud decision (Core seam), fed the SNAPSHOT's state so the loud (boss-is-set) path
    /// renders exactly as today. When no boss is chosen yet the pill goes neutral ("TTFA · off").
    private var presentation: HeaderCalmPresentation.Presentation {
        HeaderCalmPresentation.resolve(
            bossAgentName: model.state.boss.agentName,
            bossAgentStatus: model.ouroAgent(named: model.state.boss.agentName)?.status,
            autonomyState: snapshot.state
        )
    }

    /// Pill tint: gray for the calm no-boss-yet state, the live readiness tint once a boss is set.
    private var pillTint: SwiftUI.Color {
        switch presentation.ttfaStyle {
        case .neutral:
            return .secondary
        case .real:
            return snapshot.state.tint
        }
    }

    private var loginItemCheck: AutonomyReadinessCheck {
        Self.loginItemCheck(for: loginItem.status)
    }

    /// Pure mapping `LaunchAgentLoginItemStatus → AutonomyReadinessCheck`, extracted as a
    /// `static` function so all four arms are directly unit-testable (the view's live
    /// `loginItem.status` reports only one). Behavior-identical to the prior inline switch.
    static func loginItemCheck(for status: LaunchAgentLoginItemStatus) -> AutonomyReadinessCheck {
        switch status {
        case .enabled:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "Workbench will reopen after a computer restart.",
                state: .ok
            )
        case .needsUpdate:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "Login item points at a different app bundle and needs an update.",
                state: .warning
            )
        case .notInstalled:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "Workbench will not reopen automatically after restart.",
                state: .warning
            )
        case .appBundleMissing:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "The installed app bundle is missing.",
                state: .blocker
            )
        }
    }

    var body: some View {
        Button {
            loginItem.refresh()
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(pillTint)
                    .frame(width: 7, height: 7)
                Text(presentation.ttfaText)
                    .font(.caption.monospaced().weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(pillTint.opacity(0.16), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(pillTint.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(presentation.ttfaHelp)
        .popover(isPresented: $isPresented) {
            AutonomyStatusPopover(
                snapshot: snapshot,
                model: model,
                loginItem: loginItem
            )
            .frame(width: 380)
            .padding(14)
        }
        .onAppear {
            loginItem.refresh()
        }
    }
}

struct AutonomyStatusPopover: View {
    var snapshot: AutonomyReadinessSnapshot
    @ObservedObject var model: WorkbenchViewModel
    @ObservedObject var loginItem: LoginItemController

    /// The live availability of each in-app remediation actuator — the SINGLE
    /// source of "does this kind's button have work to do right now". Both the
    /// calm-vs-loud reframe (via `degradedCheckIds`) and the per-row repair button
    /// (`AutonomyStatusCheckRow.remediation`) consult it through
    /// `AutonomyRemediationMapper.hasLiveButton`, so they can never disagree about
    /// whether a blocker has a tappable fix (FIX 1 / U9-1).
    private var remediationAvailability: AutonomyRemediationAvailability {
        AutonomyRemediationAvailability(
            hasUntrustedTerminals: !model.untrustedAutonomyAgentEntries.isEmpty,
            hasResumableDisabledTerminals: !model.resumableDisabledAutonomyAgentEntries.isEmpty,
            mcpRegistrationActionable: model.bossWorkbenchMCPRegistration?.isActionable == true,
            hasRecoverableEntries: !model.recoverableEntries.isEmpty,
            bossWatchDisabled: !model.bossWatchIsEnabled,
            loginItemActionable: loginItem.status != .appBundleMissing
        )
    }

    /// Check ids whose non-green state the App knows to be genuinely degraded, even though the bare
    /// Core state is `.blocker`. Drives the calm-vs-loud reframe so a check with no live in-app fix
    /// keeps the wall copy while genuinely one-tap toggles get the calm framing.
    ///
    /// Two sources, unioned:
    /// 1. App-only degraded sub-states above the Core seam (a missing boss-mcp binary, a missing app
    ///    bundle for open-at-login) — the bare check state can't see these.
    /// 2. Blockers whose abstract remediation exists but whose per-row button the runtime gate
    ///    suppresses (a `recovery` blocker with only `.manualActionNeeded` entries; a `terminal-resume`
    ///    blocker whose agents are `.manual` strategy). Consulting the SAME `remediationAvailability`
    ///    the rows use means the reframe never promises "N things to make this hands-off" over a
    ///    blocker that has no tappable fix (FIX 1 / U9-1).
    private var degradedCheckIds: Set<String> {
        var ids = AutonomyRemediationMapper.runtimeSuppressedDegradedCheckIds(
            checks: snapshot.checks,
            availability: remediationAvailability
        )
        if model.bossWorkbenchMCPRegistration?.isActionable == false,
           snapshot.checks.contains(where: { $0.id == "boss-mcp" && $0.state == .blocker }) {
            ids.insert("boss-mcp")
        }
        if loginItem.status == .appBundleMissing {
            ids.insert("open-at-login")
        }
        return ids
    }

    /// View-level de-alarm (#U9): when the only blockers are one-tap toggles, lead with calm
    /// action-first copy and drop the red octagon; reserve the wall for genuinely degraded states.
    private var reframe: AutonomyReadinessReframedCopy {
        AutonomyReadinessReframe.present(
            state: snapshot.state,
            checks: snapshot.checks,
            degradedCheckIds: degradedCheckIds
        )
    }

    /// The pill/headline tint: red only for a genuinely degraded blocker; a calm one-tap-setup
    /// blocker reads orange ("needs you"), not the red alarm.
    private var headerTint: SwiftUI.Color {
        switch reframe.tone {
        case .degraded:
            return snapshot.state.tint
        case .calm:
            return snapshot.state == .ready ? .green : .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.label)
                    .font(.headline.monospaced())
                StatusPill(text: reframe.pillText, color: headerTint)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(reframe.headline)
                    .font(.subheadline.weight(.semibold))
                Text(reframe.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.checks) { check in
                    AutonomyStatusCheckRow(
                        check: check,
                        model: model,
                        loginItem: loginItem,
                        isDegraded: degradedCheckIds.contains(check.id)
                    )
                }
            }
            Divider()
            HStack(spacing: 8) {
                if model.bossWorkbenchMCPRegistration?.isActionable == true {
                    Button {
                        model.installWorkbenchMCPForBoss()
                    } label: {
                        Label(model.bossWorkbenchMCPActionTitle, systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                // #U21: bidirectional — the popover used to show a one-way
                // "Watch" button ONLY when watch was OFF, so in the default ON
                // state there was no way to pause autonomy from here. Now it
                // toggles both ways, labelled by the result of the tap.
                Button {
                    model.setBossWatchEnabled(!model.bossWatchIsEnabled)
                } label: {
                    Label(
                        model.bossWatchIsEnabled ? "Pause Watch" : "Watch",
                        systemImage: model.bossWatchIsEnabled ? "eye.slash" : "eye"
                    )
                }
                .disabled(model.bossCheckInIsRunning)
                .help(model.bossWatchPresentation.help)
                if !loginItem.isEnabled {
                    Button {
                        loginItem.setEnabled(true)
                    } label: {
                        Label(loginItem.status == .needsUpdate ? "Update Login" : "Login", systemImage: "power")
                    }
                }
                Button {
                    model.attemptCheckIn()
                } label: {
                    // U12: one name — the popover used to label this "Ask", which
                    // collided with the typed-question submit and the Boss Watch
                    // loop. It's the same manual pull as the header "Check In".
                    Label(WorkbenchViewModel.checkInActionLabel, systemImage: "bubble.left.and.text.bubble.right")
                }
                .disabled(model.bossCheckInIsRunning)
                .help(model.checkInHelpText)
            }
            .controlSize(.small)
        }
    }
}

struct AutonomyStatusCheckRow: View {
    var check: AutonomyReadinessCheck
    @ObservedObject var model: WorkbenchViewModel
    @ObservedObject var loginItem: LoginItemController
    /// The App knows this check is genuinely degraded (missing binary / bundle / app) even though its
    /// bare Core state is `.blocker` — keep the stop-sign for it; soften everything else.
    var isDegraded: Bool = false

    /// Glyph + tint for the leading status dot. A one-tap-fixable blocker reads as a soft orange
    /// "needs you", not the red stop-sign — the octagon is reserved for the degraded case (#U9).
    private var indicator: (systemImage: String, tint: SwiftUI.Color) {
        if check.state == .blocker, remediation != nil, !isDegraded {
            return ("exclamationmark.circle.fill", .orange)
        }
        return (check.state.systemImage, check.state.tint)
    }

    /// The live availability of each in-app remediation actuator, built from the
    /// same view-model state the popover's `degradedCheckIds` uses. Routing the
    /// per-row button gate AND the calm-vs-loud reframe through ONE predicate
    /// (`AutonomyRemediationMapper.hasLiveButton`) is what keeps the reframe from
    /// promising a one-tap fix this row would suppress (FIX 1 / U9-1).
    private var remediationAvailability: AutonomyRemediationAvailability {
        AutonomyRemediationAvailability(
            hasUntrustedTerminals: !model.untrustedAutonomyAgentEntries.isEmpty,
            hasResumableDisabledTerminals: !model.resumableDisabledAutonomyAgentEntries.isEmpty,
            mcpRegistrationActionable: model.bossWorkbenchMCPRegistration?.isActionable == true,
            hasRecoverableEntries: !model.recoverableEntries.isEmpty,
            bossWatchDisabled: !model.bossWatchIsEnabled,
            loginItemActionable: loginItem.status != .appBundleMissing
        )
    }

    /// The one-tap fix this check can offer right now (#U9). Pure Core mapping first; then suppress
    /// the button via the shared runtime predicate (`hasLiveButton`) for the App-only degraded
    /// sub-states and no-op cases the Core seam can't see, so a non-green check never shows an
    /// orphaned or do-nothing button — and the reframe agrees, because it consults the same predicate.
    private var remediation: AutonomyRemediation? {
        guard let remediation = AutonomyRemediationMapper.remediation(forCheckId: check.id, state: check.state) else {
            return nil
        }
        return AutonomyRemediationMapper.hasLiveButton(for: remediation.kind, availability: remediationAvailability)
            ? remediation
            : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: indicator.systemImage)
                .foregroundStyle(indicator.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.label)
                    .font(.caption.weight(.semibold))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remediation {
                Spacer(minLength: 8)
                repairButton(remediation)
            }
        }
    }

    /// Inline repair button reusing the OnboardingRepairStepRow vocabulary: a prominent app-runnable
    /// action. Tapping invokes the matching actuator; the readiness snapshot recomputes off the
    /// view model's published state, so the check flips toward green in place — the popover stays open.
    @ViewBuilder
    private func repairButton(_ remediation: AutonomyRemediation) -> some View {
        Button {
            apply(remediation.kind)
        } label: {
            Label(remediation.actionLabel, systemImage: remediation.kind.systemImage)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
    }

    private func apply(_ kind: AutonomyRemediationKind) {
        switch kind {
        case .trustTerminals:
            model.trustUntrustedAutonomyAgentTerminals()
        case .enableResume:
            model.enableAutoResumeForAutonomyAgentTerminals()
        case .connectTools:
            model.installWorkbenchMCPForBoss()
        case .recover:
            model.recoverAllRecoverableSessions()
        case .enableWatch:
            model.setBossWatchEnabled(true)
        case .openAtLogin:
            loginItem.setEnabled(true)
        }
    }
}

// U5 B10: private->internal for the B10 direct logic test (pure presentation, same module).
extension AutonomyRemediationKind {
    /// SF Symbol per repair, matching the OnboardingRepairStepRow / popover-footer icon vocabulary.
    var systemImage: String {
        switch self {
        case .trustTerminals: return "checkmark.shield"
        case .enableResume: return "arrow.clockwise"
        case .connectTools: return "point.3.connected.trianglepath.dotted"
        case .recover: return "arrow.uturn.backward"
        case .enableWatch: return "eye"
        case .openAtLogin: return "power"
        }
    }
}

struct StatusPill: View {
    var text: String
    var color: SwiftUI.Color

    var body: some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct DashboardStatusLine: View {
    var text: String
    var color: SwiftUI.Color = .secondary
    var help: String?
    var truncationMode: Text.TruncationMode = .middle
    // Defaults to leading so the dashboard rows (label + status side-by-side) are
    // unchanged. The standalone update panel passes `.center` so the status line
    // actually centers under its button instead of hugging the leading edge —
    // the full-width `.infinity` frame here is what previously defeated the
    // enclosing VStack's `.center`.
    var alignment: Alignment = .leading

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(truncationMode)
            .frame(maxWidth: .infinity, alignment: alignment)
            .layoutPriority(1)
            .help(help ?? text)
    }
}

// U5 B10: private->internal for the B10 direct logic test (pure presentation, same module).
extension AutonomyReadinessState {
    var tint: SwiftUI.Color {
        switch self {
        case .ready:
            return .green
        case .attention:
            return .orange
        case .blocked:
            return .red
        }
    }

    var displayName: String {
        switch self {
        case .ready:
            return "ready"
        case .attention:
            return "watch"
        case .blocked:
            return "blocked"
        }
    }
}

// U5 B10: private->internal for the B10 direct logic test (pure presentation, same module).
extension HeaderCalmPresentation.BossDotColor {
    /// Map the framework-free Core dot color onto a SwiftUI color. `.neutral` is the calm
    /// no-boss-yet state (`.secondary`), not an alarm.
    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .neutral:
            return .secondary
        case .green:
            return .green
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }
}

private extension AutonomyReadinessCheckState {
    var tint: SwiftUI.Color {
        switch self {
        case .ok:
            return .green
        case .warning:
            return .orange
        case .blocker:
            return .red
        }
    }

    var systemImage: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocker:
            return "xmark.octagon.fill"
        }
    }
}

struct CommandPaletteSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    /// Keyboard-highlighted row. ↑/↓ move it, Return runs it (not just the
    /// first), and clicking a row runs that one directly.
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Run command", text: $model.commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(runSelectedCommand)
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.filteredCommandPaletteItems.isEmpty {
                            ContentUnavailableView(
                                "No Commands",
                                systemImage: "command",
                                description: Text("Try another action, terminal name, or alias.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        }
                        // U37(b): render the flat list grouped into labelled
                        // sections (Session / Boss / Workspace / Agents /
                        // Diagnostics / App) via the pure Core classifier. The
                        // global row index (the position in the FLAT filtered list)
                        // drives the keyboard highlight + scroll, so ↑/↓ and Return
                        // keep working across section breaks.
                        ForEach(sectionedRows, id: \.section) { group in
                            Text(group.section.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                            ForEach(group.rows, id: \.index) { row in
                                paletteRow(row.command, index: row.index, proxy: proxy)
                            }
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 360)
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
        .padding()
        .frame(width: 560)
        .onAppear {
            model.commandPaletteQuery = ""
            selectedIndex = 0
            searchFocused = true
        }
        .onChange(of: model.commandPaletteQuery) { _, _ in
            // Filtering changes the list; reset the highlight to the top.
            selectedIndex = 0
        }
        .onDisappear {
            // Run the chosen command now that the palette is fully gone, so a
            // command that opens another sheet doesn't race the dismiss.
            model.performPendingPaletteCommand()
        }
    }

    /// One palette row carrying its global index in the flat filtered list (the
    /// index the keyboard highlight + scroll use).
    private struct IndexedRow {
        var index: Int
        var command: WorkbenchCommandDescriptor
    }

    /// A labelled section of rows for the grouped palette render.
    private struct SectionedRows: Identifiable {
        var section: WorkbenchCommandSection
        var rows: [IndexedRow]
        var id: WorkbenchCommandSection { section }
    }

    /// The filtered palette in VISUAL (grouped) order — the single source the
    /// keyboard highlight, Return, and the rendered rows all index into, so the
    /// selection can't desync from what's on screen now that grouping reorders the
    /// flat list.
    private var visualOrderedItems: [WorkbenchCommandDescriptor] {
        WorkbenchCommandSection.grouped(model.filteredCommandPaletteItems).flatMap(\.commands)
    }

    /// The filtered palette grouped into labelled sections, each row tagged with
    /// its index in `visualOrderedItems` so the keyboard highlight survives the
    /// section breaks.
    private var sectionedRows: [SectionedRows] {
        var nextIndex = 0
        return WorkbenchCommandSection.grouped(model.filteredCommandPaletteItems).map { group in
            let rows = group.commands.map { command -> IndexedRow in
                defer { nextIndex += 1 }
                return IndexedRow(index: nextIndex, command: command)
            }
            return SectionedRows(section: group.section, rows: rows)
        }
    }

    @ViewBuilder
    private func paletteRow(
        _ command: WorkbenchCommandDescriptor,
        index: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            run(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.systemImage)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.body.weight(.semibold))
                    Text(command.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
    }

    private func moveSelection(by delta: Int) {
        selectedIndex = Self.clampedSelection(current: selectedIndex, delta: delta, count: visualOrderedItems.count)
    }

    /// Pure ↑/↓ keyboard-navigation clamp: `current + delta` clamped to `0..<count`; an empty
    /// list returns `current` unchanged (the no-op). Extracted as a `static func` so the
    /// selection math is directly unit-testable — `moveSelection(by:)` is reached only from the
    /// `.onKeyPress` closures, which ViewInspector 0.10.3 cannot drive. Behavior-identical to the
    /// prior inline `guard count > 0` + clamp (an empty list left `selectedIndex` untouched).
    static func clampedSelection(current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return current }
        return min(max(current + delta, 0), count - 1)
    }

    private func runSelectedCommand() {
        let items = visualOrderedItems
        guard selectedIndex >= 0, selectedIndex < items.count else {
            return
        }
        run(items[selectedIndex])
    }

    private func run(_ command: WorkbenchCommandDescriptor) {
        // Defer execution until the palette has dismissed (see
        // pendingPaletteCommand) so commands that open another sheet present
        // reliably.
        model.pendingPaletteCommand = command
        dismiss()
    }
}

/// Calm, terminal-first boss pane. The "Essentials" section shows the only
/// things you usually need at-a-glance — needs-me / coding counts, watch
/// status, the boss text field, and the latest reply. Everything else
/// (Ouro agent manager, transcript search, machine runtime, release updates,
/// recovery drill, MCP setup, full action log) lives behind an Advanced
/// disclosure so it never eats the screen.
struct BossDashboardView: View {
    @ObservedObject var model: WorkbenchViewModel
    @State private var showsAdvanced: Bool

    /// `initialShowsAdvanced` defaults to `false` — the prod behavior the boss pane presents
    /// UNCHANGED (the collapsed-by-default pane). The seam parameter lets a test seed the
    /// `@State` so the `if showsAdvanced` EXPANDED block (and the "Hide Advanced" label / the
    /// expanded `idealHeight`/`maxHeight` ternary arms) is reachable under ViewInspector —
    /// otherwise unreachable, since `@State` has no other init seam and a post-tap toggle is
    /// not re-inspectable. Prod byte-identical at every call site (the default is `false`).
    init(model: WorkbenchViewModel, initialShowsAdvanced: Bool = false) {
        self.model = model
        _showsAdvanced = State(initialValue: initialShowsAdvanced)
    }

    var body: some View {
        advancedExpandingScrollView
    }

    private var advancedExpandingScrollView: some View {
        scrollBody
            .onChange(of: model.transcriptSearchFocusToken) { _, _ in
                // The ⌘K "Search Transcripts" command lives behind Advanced;
                // reveal it so the focused field is visible.
                showsAdvanced = true
            }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // #U22: the open-inbox door. When the boss has escalated
                // something, a prominent tappable pill at the top of the pane
                // opens the Decision Inbox — no more knowing ⌘K / ⌘J. Calm/absent
                // when nothing's open.
                if let door = model.inboxDoor {
                    InboxDoorPill(door: door) {
                        model.presentDecisionInbox()
                    }
                }
                if model.bossWatchLastError != nil, model.bossWatchConsecutiveFailures >= 2 {
                    // Surface the boss being down prominently (out of the
                    // buried watch-status line). FIX 2: the retry copy is honest —
                    // when Boss Watch is ON it says it keeps trying (true); when OFF
                    // it tells the operator to press Check In (no false promise).
                    // Copy comes from the pure BossCheckInFailureCopy seam.
                    let banner = BossCheckInFailureCopy.persistentBanner(
                        failureCount: model.bossWatchConsecutiveFailures,
                        bossWatchIsEnabled: model.bossWatchIsEnabled
                    )
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(banner.title)
                                .font(.callout.weight(.semibold))
                            // Never interpolate the raw error here — `bossWatchLastError` carries a
                            // daemon-jargon audit line / raw transport error. Fixed, seam-free copy;
                            // the raw detail stays in the audit log.
                            Text(banner.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(banner.guidance)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4)))
                }
                if model.bossCheckInIsRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Asking \(model.state.boss.agentName)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let dashboard = model.bossDashboard {
                    DashboardMetricsStrip(dashboard: dashboard) {
                        Task { await model.refreshBossDashboard() }
                    }
                }
                if let visibility = model.workbenchVisibility {
                    WorkbenchVisibilityStrip(
                        snapshot: visibility,
                        onOpenInbox: { model.presentDecisionInbox() },
                        onRetry: { Task { await model.refreshWorkbenchVisibility() } }
                    )
                }
                if let dashboard = model.bossDashboard,
                   !dashboard.availability.issues.isEmpty {
                    MailboxWarningView(issues: dashboard.availability.issues)
                }
                // Boss-forward: the session STATUS list fronts the boss surface
                // so the operator reads "what's running / waiting on me / done"
                // at a glance before the conversation. Self-hiding when there are
                // no sessions; terminals stay reachable in the sidebar.
                SessionStatusListView(model: model)
                BossConversationView(model: model)
                // The boss's propose-for-approval CAPABILITY surfaces here when —
                // and only when — there are pending proposals. Self-hiding and
                // additive: it never gates the conversation or any other flow.
                BossProposalCardList(model: model)
                if let answer = model.bossCheckInAnswer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Boss Reply")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            MarkdownMessageView(text: answer, font: .callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
                if let dashboard = model.bossDashboard {
                    // #U23c: the boss's highest-intent "these need you" content,
                    // now clickable (each row jumps to its session via the ref it
                    // carries) with a "View all N" instead of silent prefix(3)
                    // truncation.
                    BossNeedsMeCodingColumns(dashboard: dashboard, model: model)
                }
                if let dashboard = model.bossDashboard {
                    HabitHistoryPanelView(model: dashboard.habitHistory)
                }
                // #U21: the boss's recent action receipts, promoted out of
                // Advanced into the default pane — "Recent actions: 3 ok · 1
                // failed" with failed autonomous actions surfaced prominently and
                // an inline expand to the full log. A FAILED action is no longer
                // invisible by default.
                BossActionReceiptStrip(model: model)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsAdvanced.toggle()
                    }
                } label: {
                    Label(showsAdvanced ? "Hide Advanced" : "Show Advanced", systemImage: showsAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Watch, agent manager, transcript search, runtime, release, recovery drill, and the full action log live here.")
                if showsAdvanced {
                    VStack(alignment: .leading, spacing: 10) {
                        BossWatchStatusView(model: model)
                        OuroAgentManagerView(model: model)
                        TranscriptSearchView(model: model)
                        MachineRuntimeView(model: model)
                        ReleaseUpdateView(model: model)
                        RecoveryDrillView(model: model)
                        BossWorkbenchMCPSetupView(model: model)
                        if let prompt = model.bossCheckInPrompt {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.bossMCPCommand)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                ScrollView {
                                    Text(prompt)
                                        .font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 120)
                            }
                        }
                        if !model.bossAppliedActions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Applied Actions")
                                    .font(.caption.weight(.semibold))
                                ForEach(model.bossAppliedActions, id: \.self) { result in
                                    Text(result)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        ActionLogView(entries: model.recentActionLogEntries)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 100, idealHeight: showsAdvanced ? 320 : 160, maxHeight: showsAdvanced ? 380 : 200, alignment: .topLeading)
    }
}

/// #U22: the door into the Decision Inbox. A prominent tappable pill — "N
/// waiting on you →", tinted by the queue's top severity — that opens the
/// inbox without a keyboard shortcut. Rendered only when something's open
/// (the caller guards on `model.inboxDoor != nil`), so it's never a dead
/// zero-count button.
struct InboxDoorPill: View {
    let door: InboxDoorPresentation
    let action: () -> Void

    private var tint: SwiftUI.Color { Self.color(for: door.topSeverity) }

    static func color(for severity: DecisionSeverity) -> SwiftUI.Color {
        switch severity {
        case .critical: return .red
        case .elevated: return .orange
        case .normal: return .blue
        case .low: return .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill")
                    .font(.caption)
                Text(door.label)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 6)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(tint.opacity(0.4), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(door.help)
        .accessibilityLabel(door.accessibilityLabel)
    }
}

/// #U23c: the "Needs Me" and "Coding" columns, made actionable. Each row is a
/// button that jumps to its session via the navigation key it already carries;
/// when there are more than the inline limit, a "View all N" control opens the
/// full session list instead of silently dropping items 4+.
struct BossNeedsMeCodingColumns: View {
    var dashboard: BossDashboardSnapshot
    @ObservedObject var model: WorkbenchViewModel

    private static let visibleLimit = 3

    private var needsMe: BossPaneListPresentation {
        BossPaneListPresentation.make(count: dashboard.needsMeItems.count, visibleLimit: Self.visibleLimit)
    }

    private var coding: BossPaneListPresentation {
        BossPaneListPresentation.make(count: dashboard.codingItems.count, visibleLimit: Self.visibleLimit)
    }

    var body: some View {
        if !dashboard.needsMeItems.isEmpty || !dashboard.codingItems.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                if !dashboard.needsMeItems.isEmpty {
                    column(title: "Needs Me", presentation: needsMe) {
                        ForEach(Array(dashboard.needsMeItems.prefix(needsMe.visibleCount))) { item in
                            itemButton(
                                text: "\(item.label) – \(item.detail)",
                                key: BossPaneListPresentation.navigationKey(for: item)
                            )
                        }
                    }
                }
                if !dashboard.codingItems.isEmpty {
                    column(title: "Coding", presentation: coding) {
                        ForEach(Array(dashboard.codingItems.prefix(coding.visibleCount))) { item in
                            itemButton(
                                text: "\(item.runner) – \(item.status)",
                                // Coding items carry an explicit taskRef; fall
                                // back to the runner name so the jump still tries.
                                key: item.taskRef ?? item.runner
                            )
                        }
                    }
                }
            }
        }
    }

    private func column<Rows: View>(
        title: String,
        presentation: BossPaneListPresentation,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            rows()
            if let viewAll = presentation.viewAllLabel {
                Button {
                    // The full, scrollable, already-clickable list is the
                    // Sessions status list right below — surface it / take the
                    // operator there rather than inventing a second list.
                    model.setBossPaneCollapsed(false)
                } label: {
                    Label(viewAll, systemImage: "list.bullet")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Show all \(presentation.totalCount) in the Sessions list below")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemButton(text: String, key: String) -> some View {
        Button {
            model.selectSession(byNavigationKey: key)
        } label: {
            HStack(spacing: 4) {
                Text(text)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to this session")
    }
}

struct HabitHistoryPanelView: View {
    var model: HabitHistoryPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.rows.isEmpty {
                Text(model.statusMessage ?? "No habit runs yet")
                    .font(.caption)
                    .foregroundStyle(model.isAvailable ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            ForEach(model.rows.prefix(5)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.habitName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(row.outcome)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(row.endedAt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(row.summary)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let operationId = row.operationId {
                            Text(operationId)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(row.receiptLocator)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardMetricsStrip: View {
    var dashboard: BossDashboardSnapshot
    /// #U23b: re-run the dashboard probes when a metric can't report — a
    /// one-click retry for just the strip. `nil` in contexts with no refresh.
    var onRetry: (() -> Void)?

    private var availability: BossDashboardAvailability { dashboard.availability }

    /// The specific probe issue (label-prefixed string from `fetchResult`) for a
    /// metric, so an unavailable chip shows its own reason — not hover-only
    /// guessing.
    private func issue(prefix: String) -> String? {
        availability.issues.first { $0.hasPrefix(prefix) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // The daemon's status/mode come from `/api/machine`'s self-report,
                // gated by the same `availability.machineAvailable` flag the sibling
                // metrics use. Routing through `MetricStateChip` (not the inert
                // `MetricChip`) means a failed/stale machine read collapses to the
                // honest not-a-value state instead of showing the last-known string —
                // a running daemon still shows its real status.
                MetricStateChip(
                    label: "daemon",
                    presentation: MetricValuePresentation.resolve(
                        text: dashboard.daemonStatus,
                        isAvailable: availability.machineAvailable,
                        issue: issue(prefix: "machine:")
                    ),
                    onRetry: onRetry
                )
                MetricStateChip(
                    label: "needs me",
                    presentation: MetricValuePresentation.resolve(
                        value: dashboard.needsMeItems.count,
                        isAvailable: availability.needsMeAvailable,
                        issue: issue(prefix: "needs-me:")
                    ),
                    onRetry: onRetry
                )
                MetricStateChip(
                    label: "coding",
                    presentation: MetricValuePresentation.resolve(
                        value: dashboard.activeCodingAgents,
                        isAvailable: availability.codingAvailable,
                        issue: issue(prefix: "coding:")
                    ),
                    onRetry: onRetry
                )
                MetricStateChip(
                    label: "blocked",
                    presentation: MetricValuePresentation.resolve(
                        value: dashboard.blockedCodingAgents,
                        isAvailable: availability.codingAvailable,
                        issue: issue(prefix: "coding:")
                    ),
                    onRetry: onRetry
                )
                MetricStateChip(
                    label: "habits",
                    presentation: MetricValuePresentation.resolve(
                        value: dashboard.habitHistory.rows.count,
                        isAvailable: dashboard.habitHistory.isAvailable,
                        issue: issue(prefix: "habit-history:")
                    ),
                    onRetry: onRetry
                )
                MetricStateChip(
                    label: "mode",
                    presentation: MetricValuePresentation.resolve(
                        text: dashboard.daemonMode,
                        isAvailable: availability.machineAvailable,
                        issue: issue(prefix: "machine:")
                    ),
                    onRetry: onRetry
                )
            }
        }
    }
}

/// #U23b: a metric chip that renders a `MetricValuePresentation` — a real number,
/// a genuine zero, or the not-a-value state (a muted em dash, never "?", with the
/// specific reason and a one-click retry). The unavailable state is visually
/// distinct from a real value so a transient probe miss no longer reads as
/// "something's broken".
struct MetricStateChip: View {
    var label: String
    var presentation: MetricValuePresentation
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(presentation.text)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(presentation.isUnavailable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if presentation.isUnavailable {
                // The "not a real value" affordance: an info glyph revealing the
                // specific issue, plus a retry that re-runs just this probe set.
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                if let onRetry, presentation.canRetry {
                    Button {
                        onRetry()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Retry this metric")
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            presentation.isUnavailable
                ? AnyShapeStyle(Color.orange.opacity(0.12))
                : AnyShapeStyle(.quaternary.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .help(presentation.isUnavailable ? presentation.reason : label)
    }
}

struct WorkbenchVisibilityStrip: View {
    var snapshot: WorkbenchVisibilitySnapshot
    /// #U22: tapping the "inbox" chip opens the Decision Inbox — the same door
    /// the boss-pane pill and ⌘K / ⌘J reach. Only wired (and only tappable) when
    /// there's actually something open.
    var onOpenInbox: (() -> Void)?
    /// #U23b: re-run the visibility probe when a count can't report.
    var onRetry: (() -> Void)?

    /// The first readiness issue, as a label-prefixed reason string, for the
    /// chips whose count is nil because the probe didn't report.
    private var firstIssue: String? {
        snapshot.readiness.issues.first.map { "\($0.code): \($0.detail)" }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MetricChip(label: "visibility", value: snapshot.readiness.status.rawValue)
                MetricStateChip(
                    label: "owed",
                    presentation: MetricValuePresentation.resolve(
                        value: snapshot.agentWork.counts.owed,
                        isAvailable: snapshot.agentWork.counts.owed != nil,
                        issue: firstIssue
                    ),
                    onRetry: onRetry
                )
                MetricStateChip(
                    label: "returns",
                    presentation: MetricValuePresentation.resolve(
                        value: snapshot.agentWork.counts.returnObligations,
                        isAvailable: snapshot.agentWork.counts.returnObligations != nil,
                        issue: firstIssue
                    ),
                    onRetry: onRetry
                )
                MetricChip(label: "claims", value: snapshot.agentWork.claims.available ? "ok" : "unknown")
                MetricChip(
                    label: "inbox",
                    value: "\(snapshot.decisions.openInbox)",
                    // The chip is a live door only when there's an open item AND a
                    // handler — a zero-count inbox stays a calm, inert chip.
                    tap: (snapshot.decisions.openInbox > 0) ? onOpenInbox : nil
                )
                MetricChip(label: "recover", value: "\(snapshot.workspace.recoverableSessions)")
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        let issueText = snapshot.readiness.issues.map { "\($0.code): \($0.detail)" }.joined(separator: "\n")
        return issueText.isEmpty ? "Workbench visibility is available." : issueText
    }
}

struct MetricChip: View {
    var label: String
    var value: String
    /// #U22: when set, the chip becomes a tappable door (e.g. the "inbox" chip
    /// opens the Decision Inbox). `nil` keeps the classic inert chip.
    var tap: (() -> Void)?

    private var chip: some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if tap != nil {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            tap != nil ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    var body: some View {
        if let tap {
            Button(action: tap) {
                chip.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            chip
        }
    }
}

struct MailboxWarningView: View {
    var issues: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Mailbox warnings: \(issues.joined(separator: "; "))")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(issues.joined(separator: "\n"))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct BossQuickQuestion: Identifiable {
    var id: String
    var title: String
    var question: String
}

private let bossQuickQuestions: [BossQuickQuestion] = [
    BossQuickQuestion(
        id: "status",
        title: "What's Going On?",
        question: "Summarize what is currently going on across the Workbench, including running terminal agents, anything waiting on {{owner}}, and the next useful action."
    ),
    BossQuickQuestion(
        id: "waiting",
        title: "Waiting On Me?",
        question: "Inspect the Workbench and tell {{owner}} whether anything is waiting on them. Be concise, and include what decision or input is needed only if a human decision is genuinely required."
    ),
    BossQuickQuestion(
        id: "move",
        title: "Keep Moving",
        question: "Inspect the Workbench and keep trusted terminal agents moving when the next action is clear. Use auditable Workbench actions for safe obvious next steps."
    ),
    BossQuickQuestion(
        id: "respond",
        title: "Respond For Me",
        question: "Inspect the Workbench and respond on {{owner}}'s behalf when a terminal agent is clearly waiting on routine input. Use Workbench actions for safe obvious replies; escalate only genuinely human-only decisions."
    )
]

struct BossConversationView: View {
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Boss Line", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.semibold))
                TextField("Ask \(model.state.boss.agentName) about the Workbench", text: $model.bossQuestion)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit {
                        Task {
                            await model.runBossQuestion()
                        }
                    }
                Button {
                    Task {
                        await model.runBossQuestion()
                    }
                } label: {
                    Label("Ask", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.bossQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.bossCheckInIsRunning)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bossQuickQuestions) { item in
                        Button(item.title) {
                            Task {
                                await model.runBossQuickQuestion(item.question)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.bossCheckInIsRunning)
                    }
                }
            }
        }
    }
}

struct OuroAgentManagerView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.badge.gearshape")
                        .frame(width: 16)
                    Text("Ouro Agents")
                }
                    .font(.caption.weight(.semibold))
                    .fixedSize()
                Text(model.ouroAgentStatusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Button {
                    model.refreshOuroAgents()
                } label: {
                    Label("Refresh Agents", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh local Ouro agents")
                .fixedSize()
                // U18: create goes to the native form; clone keeps its Git-remote sheet.
                Menu {
                    Button {
                        model.presentNewAgentProviderConfigForm()
                    } label: {
                        Label("Create an Agent…", systemImage: "sparkles")
                    }
                    Button {
                        model.presentCloneAgentSheet()
                    } label: {
                        Label("Clone an Agent from Git…", systemImage: "arrow.down.doc")
                    }
                } label: {
                    Label("Add Agent", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if model.ouroAgents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("No Ouro agents are installed on this machine yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 5) {
                    ForEach(model.ouroAgents) { agent in
                        OuroAgentRowView(agent: agent, model: model)
                    }
                }
            }
        }
        .task {
            model.refreshOuroAgents()
        }
    }
}

struct OuroAgentRowView: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel

    private var registration: BossWorkbenchMCPRegistrationSnapshot? {
        model.workbenchMCPRegistration(for: agent)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: agentStatusImage)
                .foregroundStyle(agentStatusColor)
                .frame(width: 16)
                .help(InstalledAgentRowPresentation.help(for: liveReadiness, detail: agent.detail))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame {
                        StatusPill(text: "boss", color: .blue)
                            .fixedSize()
                    }
                    if let registration {
                        // Fold the on-disk registration STATUS with the live injection
                        // VERDICT through the shared seam — GREEN only on a confirmed-present
                        // probe; a config-only `.registered` reads NEUTRAL, not a false green.
                        let mcpTone = BossMCPPillPresentation.tone(
                            status: registration.status,
                            injection: model.bossWorkbenchToolsInjectionByAgentName[agent.name]
                        )
                        StatusPill(
                            text: BossMCPPillPresentation.label(for: mcpTone),
                            color: BossMCPPillPresentation.color(for: mcpTone).swiftUIColor
                        )
                        .fixedSize()
                    }
                }
                Text(agent.summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button {
                model.selectBoss(agentName: agent.name)
            } label: {
                Label("Use as Boss", systemImage: "person.crop.circle.badge.checkmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Use \(agent.name) as boss")
            .disabled(!agent.isUsableAsBoss || model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame)
            .fixedSize()
            if registration?.isActionable == true {
                Button {
                    model.installWorkbenchMCP(for: agent)
                } label: {
                    Label(registration?.status == .needsUpdate ? "Clean up entry" : "Connect tools", systemImage: "link.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(registration?.detail ?? "Connect Workbench tools at runtime")
                .fixedSize()
            }
            Button {
                model.revealAgentBundle(agent)
            } label: {
                Label("Reveal Bundle", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(agent.bundlePath)
            .fixedSize()
            // F6 — the destructive remove-agent affordance. Taps ARM a confirmation (sets
            // `agentPendingRemoval`); it never deletes on the first tap.
            Button(role: .destructive) {
                model.agentPendingRemoval = agent
            } label: {
                Label("Remove Agent", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove \(agent.name) from this Mac")
            .fixedSize()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.name), \(agent.summaryLine)")
        // F6 — the confirmation gate for this row's removal. Uses the seam-free Core copy, which
        // states the deletion is permanent (and warns when removing the current boss). Only the
        // confirm action calls `removeAgent`, which performs the deletion + re-derives roster state.
        .confirmationDialog(
            removalCopy.title,
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(removalCopy.confirmTitle, role: .destructive) {
                model.removeAgent(agent)
            }
            Button(removalCopy.cancelTitle, role: .cancel) {
                model.agentPendingRemoval = nil
            }
        } message: {
            Text(removalCopy.message)
        }
    }

    /// The seam-free confirmation copy for removing THIS row's agent, flavored when it's the boss.
    private var removalCopy: AgentRemoval.ConfirmationCopy {
        AgentRemoval.confirmationCopy(
            agentName: agent.name,
            isBoss: model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame
        )
    }

    /// Present this row's confirmation only when THIS agent is the one armed for removal, so a single
    /// shared `agentPendingRemoval` doesn't fan a dialog out across every row.
    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.agentPendingRemoval?.id == agent.id },
            set: { presented in
                if !presented, model.agentPendingRemoval?.id == agent.id {
                    model.agentPendingRemoval = nil
                }
            }
        )
    }

    /// The honest, LIVE readiness for this row — the scanner's config-only `agent.status`
    /// folded with the real outward-lane verdict and the in-flight flag (the same maps the
    /// sidebar #261 fix computes). The bug this replaces: this empty-state row rendered the
    /// config-only `.ready` as a green checkmark + "ready" tooltip WITHOUT a live check, so an
    /// expired-token agent read green. Only `.ready`/green when a live check returned `.working`.
    private var liveReadiness: InstalledAgentRowPresentation.LiveReadiness {
        InstalledAgentRowPresentation.liveReadiness(
            status: agent.status,
            verdict: model.agentOutwardVerdicts[agent.name],
            isChecking: model.agentChecksInFlight.contains(agent.name)
        )
    }

    // Route the icon through the shared Core seam so the success glyph is reachable ONLY from
    // a live `.ready` (never config-only). Pending stays calm; only confirmed-bad warns.
    private var agentStatusImage: String {
        InstalledAgentRowPresentation.iconSystemName(for: liveReadiness)
    }

    // Route the dot/icon color through the shared Core seam, live-aware: never green unless the
    // live check confirmed it. Matches the sidebar row + detail-pane title strip.
    private var agentStatusColor: SwiftUI.Color {
        InstalledAgentRowPresentation.dotColor(for: liveReadiness).swiftUIColor
    }

}

/// The native provider-config form — the ONE human touchpoint of the cold-start bootstrap.
///
/// Thin wiring over the pure `ProviderConfigForm` Core type: it collects the provider choice and
/// the credential fields, then hands them to the model. The SECRET never leaves this native form
/// except as `ouro hatch` argv tokens the model builds — it is NEVER routed through the agent's
/// context/MCP. Cohesive-product copy: reads as one product ("your agent"), no `ouro`/CLI seams.
struct ProviderConfigSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: WorkbenchProvider = .anthropic
    @State private var humanName: String
    @State private var newAgentName: String = ""
    @State private var values: [String: String] = [:]
    @State private var message: String?

    /// AN-007 / Q3 — the seed for the `humanName` `@State`, made injectable. Production resolves
    /// the machine owner's full display name through `WorkbenchViewModel.resolvedOwnerName()`;
    /// tests receive that function's XCTest-safe short-name fallback so traversing dormant sheet
    /// builders never wakes Contacts/CoreData/XPC just to snapshot an unrelated surface.
    init(model: WorkbenchViewModel, initialHumanName: String = WorkbenchViewModel.resolvedOwnerName()) {
        self.model = model
        self._humanName = State(initialValue: initialHumanName)
    }

    private var form: ProviderConfigForm {
        ProviderConfigForm(agentName: model.providerConfigAgentName, humanName: humanName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.providerConfigIsNewAgent ? "Create your agent" : form.title)
                .font(.title3.weight(.semibold))
            Text(model.providerConfigIsNewAgent
                 ? "Name your agent, choose a provider, and enter your credentials. This is the only step that needs you."
                 : form.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                if model.providerConfigIsNewAgent {
                    TextField("Agent name", text: $newAgentName)
                }
                Picker("Provider", selection: $provider) {
                    // BUG 2 — offer ONLY providers a brand-new agent can actually be cold-started for.
                    // `coldStartProviders` filters out the hatch-incapable ones (GitHub Copilot has no
                    // `ouro hatch` argv sink), so picking one + Create Agent can't dead-end in
                    // `.unsupportedColdStartSink`. Copilot stays selectable on the reconnect / existing-
                    // agent path (which routes through `presentProviderConfigForm`, not this set), so a
                    // configured github-copilot agent like ouroboros is unaffected.
                    ForEach(model.providerConfigIsNewAgent
                            ? WorkbenchProvider.coldStartProviders
                            : WorkbenchProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("Your name", text: $humanName)
                ForEach(provider.credentialFields) { field in
                    if field.isSecret {
                        SecureField(field.label, text: binding(for: field.key))
                    } else {
                        TextField(field.label, text: binding(for: field.key))
                    }
                }
            }

            // F1 — surface the local validation message OR the async cold-start outcome line
            // (created-but-not-connected / honest failure). The cold-start message comes from the
            // model once the post-hatch probe classifies; until then the form spins in place
            // instead of dismissing-and-claiming-success.
            if let surfaced = message ?? model.providerConfigColdStartMessage {
                Text(surfaced)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.providerConfigColdStartInFlight {
                    ProgressView()
                        .controlSize(.small)
                    // F6 — branch the label on the in-flight flavor: "Creating your agent…" for a
                    // cold-start, reconnect-flavored copy for a rotation. Set by the model at launch.
                    Text(model.providerConfigInFlightLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(model.providerConfigColdStartInFlight)
                // F13 — the honest needs-vault recovery affordance. Shown ONLY when the cold-start
                // landed in `.needsVaultSetup` (the agent exists but the headless hatch couldn't
                // persist the credential). Runs the documented `ouro vault create && auth && refresh`
                // chain in a native terminal where the human re-enters the secret + credential.
                if model.providerConfigNeedsVaultSetup {
                    Button {
                        model.beginVaultOnboarding()
                    } label: {
                        Label("Finish setup", systemImage: "key.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.providerConfigColdStartInFlight)
                } else {
                    Button {
                        submit()
                    } label: {
                        Label(model.providerConfigIsNewAgent ? "Create Agent" : "Connect",
                              systemImage: model.providerConfigIsNewAgent ? "plus.circle" : "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.providerConfigColdStartInFlight)
                }
            }
        }
        .padding()
        .frame(width: 560)
        .onChange(of: provider) {
            // Clearing per-provider field values when the provider changes keeps stale secrets
            // out of the form state.
            values = [:]
            message = nil
            model.providerConfigColdStartMessage = nil
            // BUG 1 — if the previous provider's cold-start landed in `.needsVaultSetup`, the primary
            // button reads "Finish setup" and runs `beginVaultOnboarding()` against the STASHED
            // provider. Switching providers must drop that stale affordance: reset the flag (so the
            // button returns to "Create Agent"/"Connect" for the newly-picked provider) and clear the
            // stashed provider the vault chain would otherwise name. A normal (non-switch) session
            // still sets these in the `.needsVaultSetup` arm, so the legitimate Finish-setup flow is
            // unaffected.
            model.providerConfigNeedsVaultSetup = false
            model.providerConfigColdStartProvider = nil
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func submit() {
        // Clear any prior async outcome line before a fresh attempt.
        message = nil
        model.providerConfigColdStartMessage = nil
        if model.providerConfigIsNewAgent {
            // Validate + commit the new agent's name before the cold-start hatch. A name
            // that collides with an installed agent is rejected here (that would be the
            // existing-agent path, not a fresh hatch).
            if let nameFailure = model.newAgentNameValidationMessage(newAgentName) {
                message = nameFailure
                return
            }
            model.providerConfigAgentName = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let failure = model.submitProviderConfig(provider: provider, humanName: humanName, values: values) {
            message = failure
            return
        }
        // F1 — a nil return means the cold-start hatch + probe is now IN FLIGHT (the model set
        // `providerConfigColdStartInFlight`). Do NOT dismiss here: the old synchronous dismiss is
        // exactly the lie F1 removes. The model dismisses (`isProviderConfigPresented = false`)
        // only on a verified-ready outcome, and otherwise surfaces `providerConfigColdStartMessage`
        // with the form still open. We only clear the entered secrets from the local form state.
        values = [:]
    }
}

/// U18: demoted to its ONLY unique capability — cloning an agent from a Git remote.
/// Creating an agent now goes through the native `ProviderConfigSheet` "Create your
/// agent" form. U35: the clone runs HEADLESSLY with inline progress/result — no literal
/// `ouro clone …` command string is shown, and no terminal pane is spawned for the
/// operator to converse with. Mirrors the cold-start hatch path's inline reporting.
struct OuroAgentInstallSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var agentName: String
    @State private var remote: String
    @State private var cloneState: CloneAgentFlowState

    /// AN-007 — injectable seeds for the form's three `@State` values, each defaulting to the
    /// prior literal (`""`, `""`, `.idle`) so production is BYTE-IDENTICAL: the only call site
    /// (`OuroAgentInstallSheet(model:)`, `:523`) takes all defaults and renders the empty idle
    /// form exactly as before. The `cloneState` / `agentName` arms (`if cloneNameValidation`
    /// `:6332`, `if cloneState.inlineMessage` `:6340`, the busy/error/success icon + button copy)
    /// are otherwise reachable ONLY by firing the in-view "Clone Agent" Button closure
    /// `inspect()` can't fire (the C4 `DecisionLogRow.taught` pattern) — this minimal seam lets a
    /// SNAPSHOT test drive them through the REAL `CloneAgentFlowState` Core values, so the
    /// validation/message/error/success arms are COVERED, not fabricated. Same minimal shape as
    /// the Q3 `ProviderConfigSheet.initialHumanName` seam.
    init(model: WorkbenchViewModel,
         initialAgentName: String = "",
         initialRemote: String = "",
         initialCloneState: CloneAgentFlowState = .idle) {
        self.model = model
        self._agentName = State(initialValue: initialAgentName)
        self._remote = State(initialValue: initialRemote)
        self._cloneState = State(initialValue: initialCloneState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone an Agent from Git")
                .font(.title3.weight(.semibold))
            Text("Bring in an existing Ouro agent from a Git remote. To create a brand-new agent, use Create an Agent instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                TextField("Git Remote", text: $remote)
                    .disabled(cloneState.isBusy)
                // U15: the name is OPTIONAL — blank defaults to the repo name. Say so on
                // the field (no bare "Override"), and validate it inline near the field.
                TextField("Agent name (optional)", text: $agentName)
                    .help("Defaults to the repository name. Leave blank to use it.")
                    .disabled(cloneState.isBusy)
                if cloneNameValidation.isInvalid, let message = cloneNameValidation.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            // U35: inline progress / success / failure — never a raw command string and
            // never a spawned CLI pane.
            if let inlineMessage = cloneState.inlineMessage {
                HStack(spacing: 8) {
                    if cloneState.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else if cloneState.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(inlineMessage)
                        .font(.callout)
                        .foregroundStyle(cloneState.isError ? Color.red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(isFinished ? "Done" : "Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    startClone()
                } label: {
                    if cloneState.isBusy {
                        Label("Cloning…", systemImage: "arrow.down.doc")
                    } else {
                        Label(cloneState.isError ? "Try Again" : "Clone Agent", systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canClone)
            }
        }
        .padding()
        .frame(width: 560)
    }

    /// U15 — the pure validation→(isInvalid, message) mapping for the optional clone name.
    /// Drives both the inline error and `canClone`, so a malformed name disables the
    /// primary button BEFORE click instead of failing afterward.
    private var cloneNameValidation: CloneAgentNameValidation.Result {
        CloneAgentNameValidation.evaluate(agentName)
    }

    /// True once the clone has succeeded — the primary stays disabled and the secondary
    /// reads "Done".
    private var isFinished: Bool {
        if case .succeeded = cloneState { return true }
        return false
    }

    private var canClone: Bool {
        // The flow must allow a start (idle / retry-after-failure), the remote must be
        // present, and the optional name (if typed) must be well-formed.
        cloneState.canStart
            && !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cloneNameValidation.isInvalid
    }

    private func startClone() {
        let remoteLabel = CloneAgentFlowState.remoteLabel(forRemote: remote)
        cloneState = .cloning(remoteLabel: remoteLabel)
        Task {
            let result = await model.cloneAgentHeadless(remote: remote, agentName: agentName)
            await MainActor.run {
                cloneState = result
            }
        }
    }
}

struct WorkbenchOnboardingSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var page: OnboardingPage

    /// U5 B3 — injectable seed for the wizard's `@State page`, defaulting to the prior literal
    /// (`.boss`) so production is BYTE-IDENTICAL: the only prod call site (`presentOnboarding` →
    /// `WorkbenchOnboardingSheet(model:)`) takes the default and opens on Choose Boss exactly as
    /// before. The `.connect` / `.importWork` pages' `primaryActionTitle` / `primaryActionImage` /
    /// `primaryActionIsDisabled` switch arms are otherwise reachable ONLY by firing the in-view
    /// Back/Continue Button closures, whose `@State` write the no-hosting `inspect()` does not
    /// reflect — this minimal seam lets a snapshot drive those pages through the REAL model state.
    /// Same minimal shape as the `OuroAgentInstallSheet` / `ProviderConfigSheet` `@State` seams.
    init(model: WorkbenchViewModel, initialPage: OnboardingPage = .boss) {
        self.model = model
        self._page = State(initialValue: initialPage)
    }

    enum OnboardingPage: Int, CaseIterable {
        // #U26(a): the Welcome splash is gone — the empty-state already oriented the operator (U2)
        // and this wizard opens only after they clicked "Set up a boss", so it lands directly on
        // Choose Boss. Progress dots auto-tighten from `allCases` (now three).
        case boss
        case connect
        case importWork

        var title: String {
            switch self {
            case .boss:
                return "Choose Boss"
            case .connect:
                return "Connect"
            case .importWork:
                // #U26(b): ONE consistent name for the recover-work step — header, progress-dot
                // a11y label, page heading, and button all say "Bring Back Work". The stale
                // "Arrange Work" jargon (from the removed scan/arrange flow) is gone.
                return "Bring Back Work"
            }
        }

        var systemImage: String {
            switch self {
            case .boss:
                return "person.crop.circle.badge.checkmark"
            case .connect:
                return "link"
            case .importWork:
                return "arrow.uturn.backward.circle"
            }
        }

        var next: OnboardingPage? {
            OnboardingPage(rawValue: rawValue + 1)
        }

        var previous: OnboardingPage? {
            OnboardingPage(rawValue: rawValue - 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingFlowHeader(page: page, model: model, dismiss: dismiss)

            Divider()

            OnboardingPageContent(page: page, model: model)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        if let previous = page.previous {
                            page = previous
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(page.previous == nil)

                    Spacer()

                    OnboardingProgressDots(page: page)

                    Spacer()

                    Button {
                        advance()
                    } label: {
                        Label(primaryActionTitle, systemImage: primaryActionImage)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryActionIsDisabled)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 860, height: 680)
        .task {
            // Ensure the login-shell PATH is captured before any provider check
            // shells out to `ouro` (which needs `node`) — guards against the wizard
            // opening before the launch-time capture finished.
            await model.prepareLoginShellEnvironment()
            model.refreshOuroAgents()
            model.refreshWorkbenchMCPRegistration()
            model.refreshOnboardingReadiness()
            model.runOnboardingProviderChecksIfNeeded()
        }
        .onDisappear {
            // Cancel in-flight provider checks so a late completion can't
            // overwrite cleaned state after the sheet closes.
            model.cancelOnboardingProviderChecks()
            // Roll back a boss pick the user made but abandoned without
            // completing onboarding, so a half-finished pick never persists
            // (#227). No-op if onboarding completed or the boss is unchanged.
            model.rollbackOnboardingIfIncomplete()
        }
    }

    private var primaryActionTitle: String {
        switch page {
        case .boss:
            return "Continue"
        case .connect:
            return model.onboardingFlowDecision.primaryActionTitle
        case .importWork:
            return model.onboardingFlowDecision.primaryActionTitle
        }
    }

    private var primaryActionImage: String {
        switch page {
        case .boss:
            return "chevron.right"
        case .connect:
            return model.onboardingFlowDecision.phase == .bossSetupWizard ? "link" : "arrow.uturn.backward.circle"
        case .importWork:
            switch model.onboardingFlowDecision.phase {
            case .bossReconstruct:
                return "arrow.uturn.backward.circle"
            case .duplicateCleanup:
                return "rectangle.stack.badge.minus"
            case .bossSetupWizard:
                return "link"
            }
        }
    }

    private var primaryActionIsDisabled: Bool {
        switch page {
        case .boss:
            return model.onboardingBossChoices.contains { $0.isSelected && $0.isUsable } == false
        case .connect:
            // Disable while the connection checks are still running so the prominent
            // button isn't clickable-but-inert (a press would just re-kick the running
            // checks). The check rows show their own progress; this advances once ready.
            return model.onboardingIsScanning
                || model.onboardingProviderChecks.values.contains { $0.state == .running }
        case .importWork:
            if model.onboardingReadiness?.isReady != true {
                return true
            }
            // The hand-off button kicks the boss-driven reconstruction. Disable only while a boss
            // check-in is already in flight so a double-press can't re-hand-off mid-run; otherwise
            // it's a single, always-actionable "Bring Back My Work" — no selection gate (the boss,
            // not a hardcoded scan, decides what to bring back).
            if model.onboardingFlowDecision.phase == .bossReconstruct {
                return model.bossCheckInIsRunning
            }
            if model.onboardingIsScanning {
                return true
            }
            return false
        }
    }

    private func advance() {
        switch page {
        case .boss:
            page = .connect
        case .connect:
            if model.onboardingFlowDecision.phase == .bossSetupWizard {
                model.refreshOnboardingReadiness()
                model.runOnboardingProviderChecksIfNeeded()
                model.startFirstRunBootstrapIfNeeded()
                return
            }
            // Reaching Bring Back Work with a ready boss means setup is genuinely
            // done — reconstruction is the payoff, not a gate. Mark onboarding
            // completed so the wizard stops re-presenting on launch and the boss
            // pick is now committed (the rollback on dismiss no longer fires).
            // Clear the open snapshot too: once completed, `rollbackOnboardingIfIncomplete`
            // short-circuits on the completed guard and never clears it, so drop it here
            // so a committed pick can't leave a stale snapshot behind.
            model.onboardingHasBeenCompleted = true
            model.onboardingBossSnapshot = nil
            page = .importWork
            // A ready boss hands off to boss-driven reconstruction the moment we land on the
            // recover-work page — no hardcoded scan. The boss does discover → optionally
            // propose → relaunch.
            if model.onboardingFlowDecision.phase == .bossReconstruct {
                model.startBossReconstruction()
            }
        case .importWork:
            switch model.onboardingFlowDecision.phase {
            case .bossReconstruct:
                // Boss-driven hand-off: the boss owns reconstruction. The wizard stays open so
                // the operator can watch the boss work and review any proposal card; they close
                // it with Done.
                model.startBossReconstruction()
            case .duplicateCleanup:
                Task { await model.runBossQuickQuestion(WorkbenchOnboardingNarrative.duplicateCleanup) }
            case .bossSetupWizard:
                page = .connect
            }
        }
    }

}

struct OnboardingFlowHeader: View {
    var page: WorkbenchOnboardingSheet.OnboardingPage
    @ObservedObject var model: WorkbenchViewModel
    var dismiss: DismissAction

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: page.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                Text("Ouro Workbench")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Honest label: until onboarding is genuinely completed, dismissing
            // rolls back any mid-wizard boss pick — that's a Cancel, not a Done.
            // Once completed (boss committed), it's a plain Done. Behavior is the
            // same dismiss in both cases; the rollback fires in `.onDisappear`.
            Button(model.onboardingHasBeenCompleted ? "Done" : "Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

struct OnboardingPageContent: View {
    var page: WorkbenchOnboardingSheet.OnboardingPage
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 26) {
                switch page {
                case .boss:
                    OnboardingBossChoiceView(model: model)
                case .connect:
                    OnboardingReadinessView(model: model)
                case .importWork:
                    // #U26(c): the recover-work page renders ONLY the boss-driven reconstruction
                    // surface now — the dead legacy scan/arrange UI behind it is gone.
                    OnboardingBossReconstructView(model: model)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
        }
    }
}

private struct OnboardingProgressDots: View {
    var page: WorkbenchOnboardingSheet.OnboardingPage

    var body: some View {
        HStack(spacing: 7) {
            ForEach(WorkbenchOnboardingSheet.OnboardingPage.allCases, id: \.self) { candidate in
                Circle()
                    .fill(candidate == page ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: candidate == page ? 9 : 7, height: candidate == page ? 9 : 7)
                    .accessibilityLabel(candidate.title)
            }
        }
    }
}

/// Renders a boss/agent message as proper Markdown — headings, bullets, and
/// inline `**bold**` / `*italic*` / `` `code` `` / links — instead of showing
/// the raw marker characters. Block structure comes from the tested
/// `BossMessageMarkdown` parser; inline marks render via `AttributedString`.
struct MarkdownMessageView: View {
    let text: String
    var font: Font = .callout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(BossMessageMarkdown.blocks(from: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .blank:
                    Color.clear.frame(height: 3)
                case let .heading(level, headingText):
                    inline(headingText)
                        .font(headingFont(level))
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                case let .bullet(indent, bulletText):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(bulletText).font(font)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case let .paragraph(paragraphText):
                    inline(paragraphText)
                        .font(font)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .headline
        case 2: return .subheadline
        default: return .callout
        }
    }
}

private struct OnboardingStatusRow: View {
    var systemImage: String
    var title: String
    var detail: String
    var color: SwiftUI.Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// `internal` (not `private`) so the U3 view-snapshot tests can instantiate this surface
// directly via `@testable import` — the same testable-seam access level the U2/SU-C/SU-D
// surfaces (`RecoverySheet`, `InlineRenameEditor`, `TerminalAgentRow`) already carry. No
// behavior change; access-level-only widening.
struct OnboardingBossChoiceView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(alignment: .center, spacing: 10) {
                Text("Who should watch this Mac?")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Pick the Ouro agent Workbench should ask when you say \"what's going on?\" Desk workers inside terminal sessions are separate.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640)
            }
            Button {
                model.refreshOuroAgents()
                model.refreshWorkbenchMCPRegistration()
                model.refreshOnboardingReadiness()
                model.runOnboardingProviderChecksIfNeeded()
            } label: {
                Label("Refresh Agents", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            if model.onboardingBossChoices.isEmpty {
                OnboardingStatusRow(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: "No local agents found",
                    detail: "Hatch a new agent or clone an existing bundle, then refresh this list.",
                    color: .orange
                )
                HStack(spacing: 8) {
                    Button {
                        model.presentNewAgentProviderConfigForm()
                    } label: {
                        Label("Create Agent", systemImage: "plus.circle")
                    }
                    Button {
                        model.presentCloneAgentSheet()
                    } label: {
                        Label("Clone from Git…", systemImage: "arrow.down.doc")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.onboardingBossChoices) { choice in
                        OnboardingBossChoiceRow(choice: choice, model: model)
                    }
                }
                .frame(maxWidth: 660)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

// U5: private->internal so the per-file-100% gate can drive its boss-pick Button action via a
// direct ViewInspector tap. Same module, pure presentation — no behavior change.
struct OnboardingBossChoiceRow: View {
    var choice: OnboardingBossChoice
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        // Accessibility: this is a real Button (not a bare onTapGesture) so the row is
        // keyboard-focusable (Tab) and VoiceOver-actionable — selecting a boss is the
        // gateway to the whole autonomy feature and must not be mouse-only. SwiftUI does
        // NOT surface an onTapGesture as an accessibility action, which is the bug this
        // fixes. Every other selectable row in the app (e.g. WorkspaceSidebarRow) is a
        // Button, so this matches the app's convention. `.buttonStyle(.plain)` keeps the
        // custom radio/name/pills/detail visual exactly as before.
        Button {
            // #U27: Choose Boss is a pure pick — selecting an agent is the ONLY affordance.
            // Picking it SILENTLY ensures its Workbench tools (registerWorkbenchForBossChoice does
            // select + install + refresh), so there's no competing per-row Enable-Tools button.
            // The Connect page remains the single honest place that shows tool status and offers a
            // fix only when registration isn't current.
            model.registerWorkbenchForBossChoice(choice.name)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: choice.isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice.isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(choice.name)
                            .font(.headline.weight(.semibold))
                        if choice.isSelected {
                            StatusPill(text: "selected", color: .green)
                                .fixedSize()
                        }
                        StatusPill(text: choice.statusLabel, color: choice.statusColor)
                            .fixedSize()
                    }
                    Text(choice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                Spacer()
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(choice.isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(choice.isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        // Preserves the only-usable-choices-select behaviour (the old inline usability
        // gate) while ALSO announcing the control as disabled to VoiceOver — a gate
        // swallowed inside the action would leave it silently inert instead.
        .disabled(!choice.isUsable)
        // Single-select radio group: combine the fragments so VoiceOver reads the row as
        // one element, and announce the selected row so it reads "<name>, selected, …"
        // rather than leaving the selection state visual-only.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(choice.isSelected ? [.isSelected] : [])
    }
}

/// R4b — the first-run cold-start bootstrap surface. While Layer A runs the native bootstrap
/// (S0→S5) it shows live per-step progress with cohesive-product copy; at the S2 gate it surfaces
/// the native provider form (the one human touchpoint); the instant the bootstrap hands off, it
/// switches to the agent-driven (Layer B) framing — the agent inspects + remediates + narrates,
/// and the human is never asked to run anything. Thin wiring over `model.firstRunPresentation`
/// (pure `FirstRunBootstrapDrive` output).
// `internal` (not `private`) so the SU-E2 view-snapshot tests can instantiate this surface
// directly. Access-level-only widening (same as the U2 testable surfaces); no behavior change.
struct FirstRunBootstrapView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        if let presentation = model.firstRunPresentation {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Label(presentation.headline, systemImage: headerIcon(for: presentation.mode))
                        .font(.headline)
                    Spacer()
                    if model.firstRunBootstrapIsRunning {
                        ProgressView().controlSize(.small)
                    }
                    StatusPill(text: modeLabel(for: presentation.mode), color: modeColor(for: presentation.mode))
                        .fixedSize()
                }

                if presentation.mode == .agentDriven {
                    // Layer B: the agent took over. Narrate the handoff; the human is never asked
                    // to run anything. Applied actions land in the dashboard's Applied Actions.
                    if let narration = model.firstRunAgentDrivenNarration {
                        FirstRunNarrationRow(text: narration)
                    }
                } else {
                    // Layer A: live per-step native-bootstrap progress (seam-free copy).
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(presentation.rows) { row in
                            FirstRunStepRow(row: row)
                        }
                    }
                    if presentation.opensProviderGate {
                        Button {
                            model.presentProviderConfigForm(
                                agentName: model.onboardingReadiness?.selectedBossName ?? model.state.boss.agentName
                            )
                        } label: {
                            Label("Connect a provider", systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    // FIX 1 — the actionable cold-start FAILURE surface. The retry control appears
                    // ONLY in `.needsAttention` (the pure `showsRetryButton` gate), so the "you can
                    // try again" copy is no longer dead. The honest copy + the recovery ROUTE both
                    // come from the carried `attentionReason` (pure Core).
                    //
                    // FIX 2 — the route differs per reason: an invalid boss opens the boss-CHOICE
                    // surface (`presentOnboarding()` → Choose Boss), because the real fix for a
                    // stale/invalid boss pointer is PICKING A VALID BOSS, not a provider reconnect;
                    // a failed step re-runs the (re-runnable) bootstrap (`runFirstRunBootstrap()`).
                    if presentation.mode.showsRetryButton, let reason = presentation.attentionReason {
                        Text(reason.humanFacingLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            switch reason.recoveryAction {
                            case .chooseBoss:
                                model.presentOnboarding()
                            case .retry:
                                model.runFirstRunBootstrap()
                            }
                        } label: {
                            Label(
                                reason.actionLabel,
                                systemImage: reason.recoveryAction == .chooseBoss
                                    ? "person.crop.circle.badge.questionmark"
                                    : "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func headerIcon(for mode: FirstRunMode) -> String {
        switch mode {
        case .bootstrapping: return "gauge.with.dots.needle.bottom.50percent"
        case .parkedAwaitingProvider: return "link.badge.plus"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .agentDriven: return "sparkles"
        }
    }

    private func modeLabel(for mode: FirstRunMode) -> String {
        switch mode {
        case .bootstrapping: return "starting"
        case .parkedAwaitingProvider: return "needs you"
        case .needsAttention: return "needs attention"
        case .agentDriven: return "agent driving"
        }
    }

    private func modeColor(for mode: FirstRunMode) -> SwiftUI.Color {
        switch mode {
        case .bootstrapping: return .blue
        case .parkedAwaitingProvider: return .orange
        case .needsAttention: return .red
        case .agentDriven: return .green
        }
    }
}

// `internal` (not `private`) so the AN-R3 view-snapshot tests can instantiate this leaf directly
// via `@testable import` — the same testable-seam access level the sibling onboarding surfaces
// (`FirstRunBootstrapView`, `OnboardingReadinessView`) already carry. No behavior change;
// access-level-only widening.
struct FirstRunStepRow: View {
    var row: BootstrapStepProgress

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
                .frame(width: 18)
            Text(row.humanFacingLine)
                .font(.caption)
                .foregroundStyle(row.isTerminalFailure ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    @ViewBuilder
    private var icon: some View {
        if row.isActive {
            ProgressView().controlSize(.small)
        } else if row.isDone {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if row.isTerminalFailure {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if row.isAwaitingHuman {
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

private struct FirstRunNarrationRow: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.green)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// `internal` (not `private`) so the SU-E4 view-snapshot tests can instantiate this surface
// directly. Access-level-only widening (same as the U2 testable surfaces); no behavior change.
struct OnboardingReadinessView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(alignment: .center, spacing: 10) {
                Text("Connect your agent")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Workbench makes sure your agent's connection and tools are working, then brings your recent work back.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640)
            }
            if let readiness = model.onboardingReadiness {
                // U5 (#230) — confirm WHAT you're connecting before the check results land. Show the
                // selected boss's provider · model prominently above the check rows so the operator
                // can see (and confirm) which provider/model the agent uses, not just watch a
                // connection check run against an unnamed target.
                OnboardingAgentProviderSummary(
                    agent: model.ouroAgent(named: readiness.selectedBossName)
                )
                if readiness.isReady {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(Color.green)
                        Text("\(readiness.selectedBossName) is ready")
                            .font(.title3.weight(.semibold))
                        Text(WorkbenchOnboardingNarrative.scanIntro)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 520)
                    // (Removed: a structurally-DEAD `if !readiness.repairSteps.isEmpty` "Optional
                    // checks" block nested inside this `isReady` arm. The AN-006 invariant —
                    // `isReady ⟺ repairSteps.isEmpty`, asserted by
                    // OnboardingReadinessViewTests.testE4_AN006_readyImpliesEmptyRepairSteps — makes
                    // it unreachable: when ready, repairSteps is always empty. Deleted rather than
                    // carved, per the campaign's dead-code-deletion preference.)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        // R4b — Layer A native cold-start bootstrap drives the not-ready first run:
                        // live per-step progress (seam-free copy), the S2 provider-form gate, and
                        // the seam-free handoff to agent-driven (Layer B) the instant the boss is
                        // reachable. The repair-step list below remains the manual fallback surface
                        // (now app-executed — no CLI panes).
                        FirstRunBootstrapView(model: model)
                        OnboardingStatusRow(
                            systemImage: "exclamationmark.triangle.fill",
                            title: readiness.headline,
                            detail: readiness.detail,
                            color: .orange
                        )
                        ForEach(readiness.repairSteps) { step in
                            OnboardingRepairStepRow(step: step, model: model)
                        }
                        // Set expectations on the connect step (#228): the FIRST connection check
                        // after a factory reset can run cold (~a minute) before it settles, far
                        // past a warm ~12s. Showing this only while a check is in progress keeps a
                        // long spinner from reading as "broken" so the user waits instead of quitting.
                        if readiness.repairSteps.contains(where: { $0.id.hasPrefix("check-") }) {
                            Text("The first connection check after setup can take up to a minute — that's normal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 660)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .onAppear { model.startFirstRunBootstrapIfNeeded() }
    }
}

/// U5 (#230) — the "confirm what you're connecting" surface at the top of the Connect page.
///
/// Renders the selected boss agent's provider · model prominently, BEFORE the auto-running
/// connection checks report their results, so the operator sees which provider/model the agent
/// uses rather than watching a check run against an unnamed target. Collapses to ONE line when
/// both lanes share one connection (the common case), and splits into the outward ("talks with
/// you") and inner ("thinks with") roles when they differ. An unconfigured lane reads "not
/// connected yet".
///
/// Changing the MODEL is OUT OF SCOPE here: the native provider-config form has NO model field. The
/// CREDENTIAL, by contrast, is now rotatable — F6 drives the documented unlock chain
/// (`ouro vault unlock && ouro auth && ouro provider refresh`) in a native `.trusted` terminal from
/// the form's Connect action (there's still no headless non-interactive `ouro` credential-set sink,
/// gap a, so it re-collects the credential in a real TTY rather than persisting silently). So rather
/// than build a new model picker (deferred), this surface points the operator at their agent's
/// provider settings. The proactive "a newer model is available" nudge is also deferred (#237).
// `internal` (not `private`) so the C8 view-snapshot tests can instantiate this leaf
// directly via its typed `OuroAgentRecord?` input — the same testable-seam access level
// the U2/U3/C-cluster surfaces already carry. Access-level-only widening; no behavior change.
struct OnboardingAgentProviderSummary: View {
    var agent: OuroAgentRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent {
                if agent.lanesShareOneConnection {
                    // Both lanes resolve to the same provider+model — one calm line.
                    HStack(spacing: 6) {
                        Text("Your agent uses")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ProviderModelPill(label: agent.humanFacing?.displayLabel)
                    }
                } else {
                    // Lanes diverge — show the outward ("talks with you") and inner ("thinks with")
                    // roles separately, each with its own provider · model.
                    laneRow(role: "Talks with you using", label: agent.humanFacing?.displayLabel)
                    laneRow(role: "Thinks with", label: agent.agentFacing?.displayLabel)
                }
                Text("To change your model, use your agent's provider settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    private func laneRow(role: String, label: String?) -> some View {
        HStack(spacing: 6) {
            Text(role)
                .font(.callout)
                .foregroundStyle(.secondary)
            ProviderModelPill(label: label)
        }
    }
}

/// A subtle pill rendering a lane's `provider · model` display label, or a muted "not connected
/// yet" when the lane has no fully-configured provider/model.
private struct ProviderModelPill: View {
    var label: String?

    var body: some View {
        if let label {
            Text(label)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(.primary)
        } else {
            Text("not connected yet")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }
}

// `internal` (not `private`) so the SU-E1 view-snapshot tests can instantiate this leaf row
// directly via its own typed `OnboardingRepairStep` input. Access-level-only widening (same
// as the U2 testable surfaces); no behavior change.
struct OnboardingRepairStepRow: View {
    var step: OnboardingRepairStep
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusPill(text: actorLabel, color: color)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.caption.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if step.id == "workbench-mcp", model.bossWorkbenchMCPRegistration?.isActionable == true {
                // #F9 — gate the Register button on `isActionable`, matching the autonomy-popover
                // (`installWorkbenchMCPForBoss`) and boss-pane buttons. Registration can only fix a
                // `.notRegistered` / `.needsUpdate` snapshot; a `.toolsNotInjected` blocker
                // (`isActionable == false`) is a too-old-`ouro` strip that a registrar run can't
                // repair, so its row surfaces the "update to alpha.660+" copy WITHOUT a futile
                // Register button. The legitimate needs-registration case (`isActionable == true`)
                // still shows it.
                Button {
                    model.installWorkbenchMCPForBoss()
                    model.refreshOnboardingReadiness()
                    model.runOnboardingProviderChecksIfNeeded()
                } label: {
                    Label("Register", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if step.isProviderSetup {
                // Provider-setup opens the NATIVE provider form (the one human gate) — not a
                // `ouro connect providers` `.trusted` pane. This covers both the cold-start
                // credential gate (`request-provider-config`) and the existing-agent lane steps.
                Button {
                    model.openOnboardingRepair(step)
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if step.id.hasPrefix("check-") {
                // A check-* step carrying a commandLine means the provider check
                // hasn't actually started yet (pending) — show a Run button so
                // the row isn't an indefinite spinner; absent commandLine means
                // it's currently running, so the spinner is genuine.
                if step.commandLine != nil {
                    Button {
                        model.runOnboardingProviderChecksIfNeeded()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if step.commandLine != nil {
                // R4b — APP-EXECUTED (no CLI pane). The button reads as an in-app fix, not "Open a
                // terminal": `openOnboardingRepair` routes through the recovery-truth runners.
                Button {
                    model.openOnboardingRepair(step)
                } label: {
                    Label(commandButtonTitle, systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var actorLabel: String {
        // Legible status words, not internal jargon (#232): a check-* step is mid-verify; an
        // agent-runnable step is something Workbench handles itself; human-required needs the user;
        // human-choice asks the user to pick.
        if step.id.hasPrefix("check-") {
            return "Checking…"
        }
        switch step.actor {
        case .agentRunnable:
            return "Workbench"
        case .humanRequired:
            return "Needs you"
        case .humanChoice:
            return "Choose"
        }
    }

    private var commandButtonTitle: String {
        // App-executed verbs (cohesive-product): a fix action, never "Open a terminal".
        // A failed-check provider step (`repair-<lane>-provider`) only RE-RUNS the live check —
        // labeling it "Fix" overpromises (#233). Say "Try again" to match what it actually does.
        if step.id.hasPrefix("repair-") && step.id.hasSuffix("-provider") {
            return "Try again"
        }
        return step.actor == .humanChoice ? "Choose" : "Fix"
    }

    private var color: SwiftUI.Color {
        switch step.actor {
        case .agentRunnable:
            return .blue
        case .humanRequired:
            return .orange
        case .humanChoice:
            return .purple
        }
    }
}

/// Slice 7 — the boss-driven reconstruction hand-off surface. Workbench does NOT scan or
/// arrange here: it hands the boss the "bring back my work" task and renders the boss's
/// progress. The boss discovers sessions (`workbench_discover_agent_sessions`), optionally
/// proposes them via the editable card (which renders in the boss dashboard), and relaunches
/// the approved ones as terminals — all context-specific intelligence the boss owns. This
/// surface is a clean explanation + a single hand-off affordance, never a hardcoded scan.
struct OnboardingBossReconstructView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(alignment: .center, spacing: 10) {
                Text("Bring back your work")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(WorkbenchOnboardingNarrative.bossReconstructIntro)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640)
            }

            if model.onboardingReadiness?.isReady != true {
                Text("Finish connecting the boss before bringing your work back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.onboardingReconstructionHandedOff {
                Button {
                    model.startBossReconstruction()
                } label: {
                    Label("Bring Back My Work", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.bossCheckInIsRunning)
            } else {
                // Handed off: the boss is doing discover → propose → relaunch. Its progress
                // and reply render in the setup-assistant box below; any proposal card it
                // raises renders in the boss dashboard. The empty case ("nothing to bring
                // back") is whatever the boss reports — a clean message, never a dead step.
                VStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 8) {
                        if model.bossCheckInIsRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                        }
                        Text(model.bossCheckInIsRunning
                             ? "\(model.state.boss.agentName) is looking for your recent work…"
                             : "\(model.state.boss.agentName) has finished — see its reply below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(WorkbenchOnboardingNarrative.bossReconstructEmpty)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 600)
                    Button {
                        model.startBossReconstruction()
                    } label: {
                        Label("Ask Again", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(model.bossCheckInIsRunning)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

/// Native editable card for the boss's `workbench_propose` CAPABILITY. Renders
/// the pending `AgentProposal`s the boss enqueued, lets the operator tick / edit /
/// approve each item, and writes the operator's decision back through the queue
/// for the boss. This is purely OPT-IN — it surfaces only when there ARE pending
/// proposals and NEVER gates any other flow; the boss can also just act without
/// ever proposing.
///
/// All mutation/approval logic lives in Core (`AgentProposal`) and the view model
/// (`toggleProposalItem`/`editProposalItem`/`approveProposal`/`dismissProposal`);
/// this view is thin SwiftUI wiring so the un-clickable surface stays trivial.
struct BossProposalCardList: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        // Surfaces nothing when there are no pending proposals — never intrudes.
        if !model.pendingProposals.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.pendingProposals, id: \.id) { proposal in
                    BossProposalCard(proposal: proposal, model: model)
                }
            }
            .task {
                model.loadPendingProposals()
            }
        }
    }
}

private struct BossProposalCard: View {
    var proposal: AgentProposal
    @ObservedObject var model: WorkbenchViewModel

    private var selectedCount: Int {
        proposal.items.filter(\.selected).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(proposal.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(selectedCount)/\(proposal.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(proposal.items) { item in
                BossProposalItemRow(proposalID: proposal.id, item: item, model: model)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") {
                    model.dismissProposal(proposalID: proposal.id)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Decline this proposal — the boss is told you took none of it.")
                Button("Approve") {
                    model.approveProposal(proposalID: proposal.id)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("Send the ticked (and edited) items back to the boss.")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BossProposalItemRow: View {
    var proposalID: String
    var item: AgentProposalItem
    @ObservedObject var model: WorkbenchViewModel

    private func isEditable(_ field: AgentProposalItem.Field) -> Bool {
        item.editableFields.contains(field)
    }

    /// A binding for one editable field that routes edits through the view model
    /// (and thus the Core model, which rejects non-editable fields). Reads the
    /// current value; non-editable fields are rendered as static text instead, so
    /// this binding is only built for editable ones.
    private func fieldBinding(_ field: AgentProposalItem.Field, current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { model.editProposalItem(proposalID: proposalID, itemID: item.id, field: field, value: $0) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.toggleProposalItem(proposalID: proposalID, itemID: item.id)
            } label: {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(item.selected ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(item.selected ? "Selected" : "Not selected")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                if isEditable(.label) {
                    TextField("Label", text: fieldBinding(.label, current: item.label))
                        .font(.caption.weight(.semibold))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(item.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                if let detail = item.detail, !isEditable(.detail) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if isEditable(.detail) {
                    TextField("Detail", text: fieldBinding(.detail, current: item.detail ?? ""))
                        .font(.caption2)
                        .textFieldStyle(.roundedBorder)
                }
                if let command = item.command, !isEditable(.command) {
                    Text(command)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if isEditable(.command) {
                    TextField("Command", text: fieldBinding(.command, current: item.command ?? ""))
                        .font(.caption2.monospaced())
                        .textFieldStyle(.roundedBorder)
                }
                if let cwd = item.cwd, !isEditable(.cwd) {
                    Text(cwd)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if isEditable(.cwd) {
                    TextField("Working directory", text: fieldBinding(.cwd, current: item.cwd ?? ""))
                        .font(.caption2.monospaced())
                        .textFieldStyle(.roundedBorder)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(item.selected ? Color.accentColor.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Boss-forward session STATUS list: the at-a-glance "what's running / waiting
/// on me / done" surface that fronts the boss dashboard. All classification +
/// ordering lives in Core (`SessionStatusList`); this view is a thin renderer
/// that derives the buckets from `model.state` and lets a row click select the
/// session (so its terminal is one more click away in the detail pane).
///
/// ADDITIVE — the terminal sidebar (`WorkbenchSidebarView`) is untouched and
/// still the canonical way to reach every terminal. This list is a glanceable
/// overview layered on top, not a replacement: each bucket self-hides when
/// empty, and the whole view renders nothing when there are no sessions.
struct SessionStatusListView: View {
    @ObservedObject var model: WorkbenchViewModel

    private var statusList: SessionStatusList {
        SessionStatusList.make(from: model.state)
    }

    var body: some View {
        let list = statusList
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Sessions")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(summaryLine(list))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                SessionStatusBucketSection(
                    title: "Waiting on you",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    accent: SwiftUI.Color.orange,
                    rows: list.waitingOnYou,
                    model: model
                )
                SessionStatusBucketSection(
                    title: "Running",
                    systemImage: "play.circle",
                    accent: SwiftUI.Color.green,
                    rows: list.running,
                    model: model
                )
                SessionStatusBucketSection(
                    title: "Done",
                    systemImage: "checkmark.circle",
                    accent: SwiftUI.Color.secondary,
                    rows: list.done,
                    model: model
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func summaryLine(_ list: SessionStatusList) -> String {
        "\(list.waitingOnYouCount) waiting · \(list.runningCount) running · \(list.doneCount) done"
    }
}

/// One bucket (Waiting on you / Running / Done) of the boss-forward status list.
/// Self-hides when its bucket is empty so the operator only sees the states that
/// actually have sessions.
private struct SessionStatusBucketSection: View {
    var title: String
    var systemImage: String
    var accent: SwiftUI.Color
    var rows: [SessionStatusRow]
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(accent)
                    Text("\(title) (\(rows.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    SessionStatusRowView(row: row, model: model)
                }
            }
        }
    }
}

/// A single clickable status row. Clicking selects the session in the detail
/// pane (reusing `selectEntryAcrossGroups`), from which the operator opens its
/// terminal exactly as before. Pure presentation — no logic beyond formatting.
// U5: private->internal so the per-file-100% gate can drive its jump action + the
// nil-exitCode / nil-pid detail-line fallback arms. Same module, pure presentation.
struct SessionStatusRowView: View {
    var row: SessionStatusRow
    @ObservedObject var model: WorkbenchViewModel

    private var isSelected: Bool {
        model.selectedEntryID == row.id
    }

    var body: some View {
        Button {
            model.selectEntryAcrossGroups(row.id)
        } label: {
            HStack(spacing: 8) {
                StatusDot(attention: row.attention)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if let group = row.group {
                            Text(group)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(row.owner.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(detailLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(row.name) in the detail pane")
    }

    /// Short trailing descriptor — the bucket-relevant fact (exit code for done,
    /// pid for running) falling back to the working directory.
    private var detailLine: String {
        switch row.bucket {
        case .done:
            if let code = row.exitCode { return "exited \(code)" }
            return row.workingDirectory
        case .running:
            if let pid = row.pid { return "pid \(pid)" }
            return row.workingDirectory
        case .waitingOnYou:
            return row.workingDirectory
        }
    }
}

struct ActionLogView: View {
    var entries: [WorkbenchActionLogEntry]
    /// The zone + locale the per-entry timestamp renders in (AN-007). Both default to the
    /// operator's local values (`.autoupdatingCurrent`) so production is byte-identical to the
    /// prior raw `occurredAt.formatted(date:.omitted, time:.standard)`; the clock test injects
    /// `.gmt` + `en_GB` for a snapshot that's byte-identical across CI runner zones AND locales
    /// (the C4 `DecisionLogRow` / `BossWatchStatusView` recipe).
    var timeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent
    @State private var isExpanded: Bool

    /// The seed for the `isExpanded` `@State`, made injectable with a default that equals the prior
    /// behavior (`@State private var isExpanded = false`). Production is BYTE-IDENTICAL: every call
    /// site omits `initialExpanded`, so the disclosure still starts COLLAPSED exactly as before. A
    /// test injects `initialExpanded: true` to render the expanded 6-row arm through the synchronous
    /// `inspect()` seam (the C6 `ProviderConfigSheet(initialHumanName:)` / B4 sheet-`@State` precedent).
    init(
        entries: [WorkbenchActionLogEntry],
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        initialExpanded: Bool = false
    ) {
        self.entries = entries
        self.timeZone = timeZone
        self.locale = locale
        self._isExpanded = State(initialValue: initialExpanded)
    }

    private var displayedEntries: ArraySlice<WorkbenchActionLogEntry> {
        entries.prefix(isExpanded ? 6 : 1)
    }

    var body: some View {
        if !entries.isEmpty {
            if !isExpanded, let entry = entries.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Action Log")
                        .font(.caption.weight(.semibold))
                        .fixedSize()
                    Text("\(entries.count) recent")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    actionLogEntryRow(entry)
                    actionLogToggleButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Action Log")
                            .font(.caption.weight(.semibold))
                        Text("\(entries.count) recent")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        actionLogToggleButton
                    }
                    ForEach(displayedEntries) { entry in
                        actionLogEntryRow(entry)
                    }
                }
            }
        }
    }

    private var actionLogToggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label(isExpanded ? "Show Less" : "Show More", systemImage: isExpanded ? "chevron.up" : "chevron.down")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(isExpanded ? "Show fewer action log entries" : "Show more action log entries")
        .fixedSize()
    }

    private func actionLogEntryRow(_ entry: WorkbenchActionLogEntry) -> some View {
        // Route the icon + color through the honest presentation seam: an in-flight
        // optimistic ack is PENDING (neutral ellipsis), never a green check. A green
        // check / .green appears ONLY for a verified success; a settled failure is
        // orange. See WorkbenchActionOutcomePresentation.
        let tone = WorkbenchActionOutcomePresentation.tone(
            isInFlight: entry.isInFlight,
            succeeded: entry.succeeded
        )
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: WorkbenchActionOutcomePresentation.iconSystemName(for: tone))
                .foregroundStyle(Self.swiftUIColor(for: WorkbenchActionOutcomePresentation.color(for: tone)))
                .fixedSize()
            Text(entry.occurredAt.workbenchTimeText(date: .omitted, time: .standard, timeZone: timeZone, locale: locale))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            Text("\(entry.source) \(entry.action)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let targetName = entry.targetName {
                Text(targetName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(entry.result)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .clipped()
        .help(actionLogEntryHelp(entry))
    }

    private func actionLogEntryHelp(_ entry: WorkbenchActionLogEntry) -> String {
        let target = entry.targetName.map { " \($0)" } ?? ""
        return "\(entry.source) \(entry.action)\(target): \(entry.result)"
    }

    /// Map the framework-free `SemanticColor` the presentation seam returns to a
    /// SwiftUI `Color`: `.neutral → .secondary` (pending), `.green` (verified
    /// success), `.orange` (failure).
    static func swiftUIColor(for color: WorkbenchActionOutcomePresentation.SemanticColor) -> SwiftUI.Color {
        switch color {
        case .neutral:
            return .secondary
        case .green:
            return .green
        case .orange:
            return .orange
        }
    }
}

/// #U21: the boss's recent action receipts in the DEFAULT boss pane. A compact
/// "Recent actions: 3 ok · 1 failed" line — failed count tinted when non-zero so
/// a FAILED autonomous action is visible at a glance — that expands inline to the
/// full action log without sending the operator into the Advanced tooling
/// cluster. The counts come from the pure `BossActionReceiptSummary`.
struct BossActionReceiptStrip: View {
    @ObservedObject var model: WorkbenchViewModel
    /// Zone + locale forwarded to the expanded `ActionLogView`'s per-entry timestamp (AN-007).
    /// Both default to `.autoupdatingCurrent` (operator-local, prod byte-identical); the clock
    /// test injects `.gmt` + `en_GB` for a deterministic snapshot.
    var timeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent
    @State private var isExpanded: Bool

    /// The seed for the `isExpanded` `@State`, injectable with a default that equals the prior
    /// behavior (`@State private var isExpanded = false`). Production is BYTE-IDENTICAL — every call
    /// site omits `initialExpanded`, so the strip still starts COLLAPSED. A test injects
    /// `initialExpanded: true` to render the expanded `ActionLogView` arm through the synchronous
    /// `inspect()` seam (the same minimal-source-seam shape as `ActionLogView(initialExpanded:)`).
    init(
        model: WorkbenchViewModel,
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        initialExpanded: Bool = false
    ) {
        self.model = model
        self.timeZone = timeZone
        self.locale = locale
        self._isExpanded = State(initialValue: initialExpanded)
    }

    private var summary: BossActionReceiptSummary { model.bossActionReceiptSummary }

    var body: some View {
        // Nothing acted yet → stay calm and absent rather than show "0 ok".
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Recent actions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Text("\(summary.okCount) ok")
                                .font(.caption.monospacedDigit())
                        }
                        if summary.hasFailures {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("\(summary.failedCount) failed")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("The boss's executed actions — \(summary.label). Click to see the full log.")
                if isExpanded {
                    ActionLogView(entries: model.recentActionLogEntries, timeZone: timeZone, locale: locale)
                } else if summary.hasFailures {
                    // Surface the failed receipts prominently even when collapsed,
                    // so a failure is never one disclosure away.
                    ForEach(summary.failedReceipts.prefix(2)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("\(entry.action)\(entry.targetName.map { " · \($0)" } ?? "")")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BossWatchStatusView: View {
    @ObservedObject var model: WorkbenchViewModel
    /// The zone + locale the change-row timestamp renders in. Both default to the
    /// operator's local values (`.autoupdatingCurrent`) so production is unchanged; the
    /// clock test injects `.gmt` + `en_US_POSIX` for a snapshot that is byte-identical
    /// across CI runner zones AND locales (C0 recipe — `.standard` time is both
    /// zone- and locale-sensitive).
    var timeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Label("Boss Watch", systemImage: model.bossWatchIsEnabled ? "eye.fill" : "eye")
                    .font(.caption.weight(.semibold))
                    .fixedSize()
                Text(model.bossWatchStatusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(model.bossWatchStatusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .help(model.bossWatchStatusLine)
            }
            if !model.bossWatchChangeSummaries.isEmpty {
                ForEach(model.bossWatchChangeSummaries.prefix(5)) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(change.occurredAt.workbenchTimeText(date: .omitted, time: .standard, timeZone: timeZone, locale: locale))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(change.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(change.detail)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                    .help("\(change.title): \(change.detail)")
                }
            }
        }
    }
}

struct TranscriptSearchView: View {
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Transcript Search", systemImage: "text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                TextField("Search transcripts", text: $model.transcriptSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onChange(of: model.transcriptSearchQuery) {
                        model.transcriptSearchQueryDidChange()
                    }
                    .onChange(of: model.transcriptSearchFocusToken) { _, _ in
                        searchFocused = true
                    }
                    .onSubmit {
                        model.searchTranscripts()
                    }
                Button {
                    searchOrFocus()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                // ⌘F is the menu-bar "Find in Terminal" command; this transcript
                // search has its own button (and the ⌘F here collided with it).
                .fixedSize()
            }
            if !model.transcriptSearchResults.isEmpty {
                ForEach(model.transcriptSearchResults.prefix(6)) { match in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.groupName(for: match).map { "\($0) / \(match.entryName)" } ?? match.entryName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Text("line \(match.lineNumber)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(match.line)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                    .help(match.transcriptPath)
                }
            } else if !model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(model.transcriptSearchStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func searchOrFocus() {
        guard !model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchFocused = true
            return
        }
        model.searchTranscripts()
    }
}

struct BossWorkbenchMCPSetupView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(spacing: 12) {
            DashboardRowLabel(title: "Workbench MCP", systemImage: "point.3.connected.trianglepath.dotted")
            DashboardStatusLine(
                text: model.bossWorkbenchMCPStatusLine,
                color: model.bossWorkbenchMCPStatusColor
            )
            Button {
                model.refreshWorkbenchMCPRegistration()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Refresh Workbench tools status")
            .fixedSize()
            if model.bossWorkbenchMCPRegistration?.isActionable == true {
                Button {
                    model.installWorkbenchMCPForBoss()
                } label: {
                    Label(model.bossWorkbenchMCPActionTitle, systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .task {
            model.refreshWorkbenchMCPRegistration()
        }
    }
}

/// Detail pane for the Agents sidebar. Mirrors the SessionDetailView chrome
/// philosophy: a slim title strip with the essentials, a calm body card with
/// lane info + MCP status, and an inspector disclosure for the bundle paths
/// and detailed status. Lets the user switch boss, repair providers, fix MCP,
/// open agent.json, reveal the bundle, or clone — all without diving into the
/// dashboard's Advanced disclosure.
struct AgentDetailView: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    @State private var showsInspector: Bool

    /// `initialShowsInspector` defaults to `false` — the prod collapsed default UNCHANGED. The
    /// seam lets a test seed `@State` so the `if showsInspector` AgentInspectorPanel arm renders
    /// (otherwise unreachable: a post-tap toggle is not re-inspectable). Prod byte-identical.
    init(agent: OuroAgentRecord, model: WorkbenchViewModel, initialShowsInspector: Bool = false) {
        self.agent = agent
        self.model = model
        _showsInspector = State(initialValue: initialShowsInspector)
    }

    private var isBoss: Bool {
        model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame
    }

    private var registration: BossWorkbenchMCPRegistrationSnapshot? {
        model.workbenchMCPRegistration(for: agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentTitleStrip(
                agent: agent,
                model: model,
                isBoss: isBoss,
                showsInspector: $showsInspector
            )
            Divider()
            if showsInspector {
                AgentInspectorPanel(agent: agent, model: model, registration: registration)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AgentStatusCard(agent: agent, model: model, registration: registration)
                    AgentLanesCard(agent: agent, model: model)
                    AgentActionsCard(agent: agent, model: model)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// Access-widening (C7-2, the SU-E / C0 SU-3 precedent): `private` → `internal` so the
// `@testable import OuroWorkbenchAppViews` agent-title-strip snapshot test can reach this
// leaf. Zero-behavior change (visibility only). Surfaced to the operator per the doing doc.
struct AgentTitleStrip: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    var isBoss: Bool
    @Binding var showsInspector: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: showsInspector ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(showsInspector ? "Hide bundle details" : "Show bundle path and config status")

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(agent.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)

            if isBoss {
                Text("boss")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 6)

            Menu {
                Button {
                    model.openAgentConfig(agent)
                } label: {
                    Label("Open agent.json…", systemImage: "doc.text")
                }
                Button {
                    model.revealAgentBundle(agent)
                } label: {
                    Label("Reveal Bundle in Finder", systemImage: "folder")
                }
                Divider()
                Button {
                    model.repairAgent(agent)
                } label: {
                    Label("Run ouro check…", systemImage: "stethoscope")
                }
                .help("Open a Workbench terminal pre-loaded with `ouro check --agent \(agent.name)`")
                // U18: create goes native; clone keeps its Git-remote sheet.
                Button {
                    model.presentNewAgentProviderConfigForm()
                } label: {
                    Label("Create Another Agent…", systemImage: "plus")
                }
                Button {
                    model.presentCloneAgentSheet()
                } label: {
                    Label("Clone an Agent from Git…", systemImage: "arrow.down.doc")
                }
                Divider()
                Button {
                    model.refreshOuroAgents()
                } label: {
                    Label("Refresh Agents", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More actions for this agent")

            Button {
                model.selectBoss(agentName: agent.name)
            } label: {
                Label(isBoss ? "Boss" : "Use as Boss", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBoss || !agent.isUsableAsBoss)
            .help(isBoss
                  ? "\(agent.name) is already this Mac's boss"
                  : (agent.isUsableAsBoss
                     ? "Make \(agent.name) this Mac's boss"
                     : "Bundle must be ready before it can act as boss"))
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
    }

    /// The honest, LIVE readiness for the detail-pane title dot — `agent.status` folded with
    /// the live outward verdict + in-flight flag (the maps #261 computes). Never green unless a
    /// live check returned `.working`; an expired-token agent no longer shows a green title dot.
    private var liveReadiness: InstalledAgentRowPresentation.LiveReadiness {
        InstalledAgentRowPresentation.liveReadiness(
            status: agent.status,
            verdict: model.agentOutwardVerdicts[agent.name],
            isChecking: model.agentChecksInFlight.contains(agent.name)
        )
    }

    private var statusColor: SwiftUI.Color {
        InstalledAgentRowPresentation.dotColor(for: liveReadiness).swiftUIColor
    }
}

// Access-widening (C0 SU-3, the SU-E precedent): `private` → `internal` so the
// `@testable import OuroWorkbenchAppViews` path-leak snapshot test can reach this leaf.
// Zero-behavior change (visibility only). Surfaced to the operator per the doing doc.
struct AgentInspectorPanel: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    var registration: BossWorkbenchMCPRegistrationSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(agent.bundlePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(agent.configPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(agent.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if let registration {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("MCP: \(registration.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Access-widening (C7-3, the SU-E / C0 SU-3 precedent): `private` → `internal` so the
// `@testable import OuroWorkbenchAppViews` status-card snapshot test can reach this leaf.
// Zero-behavior change (visibility only). Surfaced to the operator per the doing doc.
struct AgentStatusCard: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    var registration: BossWorkbenchMCPRegistrationSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusHeadline)
                        .font(.title3.weight(.semibold))
                    Text(agent.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer()
                if let registration, registration.isActionable {
                    Button {
                        model.installWorkbenchMCP(for: agent)
                    } label: {
                        Label(
                            registration.status == .needsUpdate ? "Clean up Workbench entry" : "Connect Workbench tools",
                            systemImage: "link.badge.plus"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(registration.detail)
                }
            }
            HStack(spacing: 6) {
                StatusPill(
                    text: InstalledAgentRowPresentation.label(for: liveReadiness),
                    color: statusColor
                )
                if let registration {
                    // Fold the on-disk registration STATUS with the live injection
                    // VERDICT through the shared seam: the pill reads GREEN "registered"
                    // ONLY when a confirmed-present `tools/list` probe backs a
                    // `.registered` snapshot. A config-only `.registered` with no (or an
                    // unconfirmed / confirmed-absent) verdict reads NEUTRAL "registered
                    // (unverified)" — never a false runtime-ready green.
                    let mcpTone = BossMCPPillPresentation.tone(
                        status: registration.status,
                        injection: model.bossWorkbenchToolsInjectionByAgentName[agent.name]
                    )
                    StatusPill(
                        text: "mcp \(BossMCPPillPresentation.label(for: mcpTone))",
                        color: BossMCPPillPresentation.color(for: mcpTone).swiftUIColor
                    )
                }
                if !agent.isUsableAsBoss {
                    StatusPill(text: "boss blocked", color: .secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// The honest, LIVE readiness for the detail-pane status card — `agent.status` folded with
    /// the live outward verdict + in-flight flag (the maps #261 computes). The bug this replaces:
    /// the card showed `checkmark.seal.fill` + green + a "ready" pill off config-only `.ready`, so
    /// an expired-token agent read as a confirmed-ready bundle. Now the icon's success seal, the
    /// green color, and the "ready" pill are reachable ONLY when a live check returned `.working`.
    private var liveReadiness: InstalledAgentRowPresentation.LiveReadiness {
        InstalledAgentRowPresentation.liveReadiness(
            status: agent.status,
            verdict: model.agentOutwardVerdicts[agent.name],
            isChecking: model.agentChecksInFlight.contains(agent.name)
        )
    }

    // Route the icon through the shared Core seam: the success seal is reachable ONLY from a live
    // `.ready`; pending stays calm (clock/question), only confirmed-bad verdicts warn.
    private var statusIcon: String {
        InstalledAgentRowPresentation.iconSystemName(for: liveReadiness)
    }

    private var statusColor: SwiftUI.Color {
        InstalledAgentRowPresentation.dotColor(for: liveReadiness).swiftUIColor
    }

    // Route the PROMINENT card title through the shared Core seam off the LIVE readiness
    // (the same `liveReadiness` the icon / color / pill already use), so "Bundle ready"
    // is reachable ONLY when a live check returned `.working`. The bug this replaces: the
    // headline switched on raw config `agent.status` and read "Bundle ready" for a
    // config-`.ready` agent even when its live verdict was `.authExpired` — "Bundle ready"
    // next to an honest "sign-in needed" pill.
    private var statusHeadline: String {
        InstalledAgentRowPresentation.headline(for: liveReadiness, detail: agent.detail)
    }

}

// U5: private->internal so the per-file-100% gate can drive its action button via a
// direct ViewInspector tap. Same module, pure presentation — no behavior change.
struct AgentLanesCard: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Model providers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.openAgentConfig(agent)
                } label: {
                    Label("Edit agent.json", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the agent bundle's agent.json in your default JSON editor")
            }
            LanePanel(title: "Human-facing", systemImage: "person.crop.circle", lane: agent.humanFacing)
            LanePanel(title: "Agent-facing", systemImage: "infinity", lane: agent.agentFacing)
            Text("Workbench edits agent.json out-of-band. Use `ouro check` (in More menu) to verify the new lane after you save.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// Access-widening (C7-4, the SU-E / C0 SU-3 precedent): `private` → `internal` so the
// `@testable import OuroWorkbenchAppViews` lane-panel snapshot test can reach this leaf.
// Zero-behavior change (visibility only). Surfaced to the operator per the doing doc.
struct LanePanel: View {
    var title: String
    var systemImage: String
    var lane: OuroAgentLane?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let lane, lane.summary != nil {
                    HStack(spacing: 6) {
                        if let provider = lane.provider, !provider.isEmpty {
                            StatusPill(text: provider, color: .blue)
                        }
                        if let model = lane.model, !model.isEmpty {
                            Text(model)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } else {
                    Text("Not configured")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// U5: private->internal so the per-file-100% gate can drive its action buttons via a
// direct ViewInspector tap. Same module, pure presentation — no behavior change.
struct AgentActionsCard: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bundle actions")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Button {
                    model.repairAgent(agent)
                } label: {
                    Label("Run ouro check", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .help("Opens a Workbench terminal running `ouro check --agent \(agent.name)`")
                Button {
                    model.openAgentConfig(agent)
                } label: {
                    Label("Open agent.json", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                Button {
                    model.revealAgentBundle(agent)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                Spacer()
                // U18: create goes native; clone keeps its Git-remote sheet.
                Menu {
                    Button {
                        model.presentNewAgentProviderConfigForm()
                    } label: {
                        Label("Create Another Agent…", systemImage: "sparkles")
                    }
                    Button {
                        model.presentCloneAgentSheet()
                    } label: {
                        Label("Clone an Agent from Git…", systemImage: "arrow.down.doc")
                    }
                } label: {
                    Label("Add Another…", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct SessionDetailView: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    @State private var showsInspector: Bool
    @State private var showsTranscriptSheet: Bool

    /// `initialShowsInspector`/`initialShowsTranscriptSheet` default to `false` — the prod
    /// collapsed defaults UNCHANGED. The seam lets a test seed the `@State`s so the
    /// `if showsInspector` SessionInspectorPanel arm and the
    /// `.sheet(isPresented: $showsTranscriptSheet)` arm render (otherwise unreachable: a
    /// post-tap toggle is not re-inspectable). Prod byte-identical.
    init(
        entry: ProcessEntry,
        model: WorkbenchViewModel,
        initialShowsInspector: Bool = false,
        initialShowsTranscriptSheet: Bool = false
    ) {
        self.entry = entry
        self.model = model
        _showsInspector = State(initialValue: initialShowsInspector)
        _showsTranscriptSheet = State(initialValue: initialShowsTranscriptSheet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionTitleStrip(
                entry: entry,
                model: model,
                showsInspector: $showsInspector
            )
            Divider()
            if showsInspector {
                SessionInspectorPanel(
                    entry: entry,
                    model: model,
                    onShowTranscript: { showsTranscriptSheet = true }
                )
                Divider()
            }
            if let session = model.activeSession(for: entry) {
                // U10: a slim one-line attention banner above the terminal when
                // THIS live session is waiting/blocked/needs-review — naming the
                // detected prompt/failure and offering a direct jump to it. No
                // banner for an active/idle session.
                if let banner = attentionBanner {
                    SessionAttentionBanner(banner: banner) {
                        model.jumpToAttentionPrompt(entry)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    Divider()
                }
                ZStack(alignment: .top) {
                    TerminalPane(session: session)
                        .id(session.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The search bar targets the active pane (model.activeEntry),
                    // so render it only over that pane — otherwise a split would
                    // draw two bars, one over a terminal it isn't searching.
                    if model.isTerminalSearchPresented, model.activeEntry?.id == entry.id {
                        TerminalSearchBar(model: model)
                            .padding(.top, 10)
                            .padding(.horizontal, 14)
                    }
                }
            } else {
                InactiveTerminalSurface(
                    entry: entry,
                    model: model,
                    onShowTranscript: { showsTranscriptSheet = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
        }
        .sheet(isPresented: $showsTranscriptSheet) {
            SessionTranscriptSheet(entry: entry, model: model)
        }
    }

    /// The U10 attention banner for this entry, derived from the one shared Core
    /// seam. Only the active-session branch renders it, so `isActiveSession` is
    /// true here; the seam returns nil for active/idle (no banner).
    private var attentionBanner: SessionDetailAttentionPresentation.Banner? {
        SessionDetailAttentionPresentation.resolve(
            attention: entry.attention,
            isActiveSession: model.activeSession(for: entry) != nil,
            canRecover: model.canRecover(entry),
            isArchived: entry.isArchived,
            reason: entry.attentionReason
        ).banner
    }
}

/// U10: the slim one-line attention banner above the terminal pane. Renders the
/// detected "why" (e.g. "Waiting on you · Proceed? (y/N)"), color-coded to the
/// attention state via the shared `AttentionState.health*` helpers, with a
/// direct "Jump to prompt" affordance for the waiting/blocked cases.
// U5: private->internal so the per-file-100% gate can drive this banner's body + the
// `state` switch + both `offersJumpToPrompt` arms via a direct snapshot. Its only prod
// call site is inside `SessionDetailView` (a live-PTY K1 view ViewInspector can't descend),
// so without this seam the banner is unreachable by a test. Same module, pure presentation —
// no behavior change.
struct SessionAttentionBanner: View {
    var banner: SessionDetailAttentionPresentation.Banner
    var onJump: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.healthSymbol)
                .foregroundStyle(state.healthColor)
            Text(banner.text)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer(minLength: 6)
            if banner.offersJumpToPrompt {
                Button(action: onJump) {
                    Label("Jump to prompt", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(state.healthColor)
                .fixedSize()
                .help("Focus the terminal and put your cursor at the prompt")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(state.healthColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(banner.text)
    }

    /// Map the banner kind back onto the shared `AttentionState` so the color +
    /// glyph match the header dot and the sidebar exactly.
    private var state: AttentionState {
        switch banner.kind {
        case .waitingOnHuman: return .waitingOnHuman
        case .blocked: return .blocked
        case .needsBossReview: return .needsBossReview
        }
    }
}

/// Hosts the detail pane's session view, optionally split two-up (W5
/// increment 1). With no split it renders the single `SessionDetailView`,
/// byte-for-byte the pre-W5 behavior. With a split it lays the primary and
/// secondary panes out via `HSplitView` (side-by-side / "Split Right") or
/// `VSplitView` (stacked / "Split Down"), each wrapped in `DetailPaneChrome`
/// for the focus ring + click-to-focus + Close-Pane affordance.
///
/// The same session is never mounted in both panes: the view model guarantees
/// `detailSplit.secondaryEntryID != selectedEntryID`, so the one-NSView-per-
/// session terminal can only ever live in one pane at a time.
struct DetailSplitContainer: View {
    var primaryEntry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        if let split = model.detailSplit {
            switch split.axis {
            case .vertical:
                HSplitView {
                    primaryPane
                    secondaryPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .horizontal:
                VSplitView {
                    primaryPane
                    secondaryPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            SessionDetailView(entry: primaryEntry, model: model)
        }
    }

    private var primaryPane: some View {
        DetailPaneChrome(
            pane: .primary,
            title: primaryEntry.name,
            model: model
        ) {
            SessionDetailView(entry: primaryEntry, model: model)
        }
        .frame(minWidth: 280, minHeight: 160)
    }

    @ViewBuilder
    private var secondaryPane: some View {
        DetailPaneChrome(
            pane: .secondary,
            title: model.secondaryPaneEntry?.name ?? "Pick a session",
            model: model
        ) {
            if let entry = model.secondaryPaneEntry {
                SessionDetailView(entry: entry, model: model)
            } else {
                EmptyPanePicker(excluding: primaryEntry.id, model: model)
            }
        }
        .frame(minWidth: 280, minHeight: 160)
    }
}

/// Wraps a pane's content with the split chrome: a slim header bar (pane label
/// + Close button) and a focus ring that brightens the active pane. The whole
/// pane is a click-to-focus target via a *simultaneous* tap gesture so the
/// click still reaches the SwiftTerm view underneath (which claims keyboard
/// focus itself) — tapping anywhere in the pane sets `activePaneID` for the
/// ring and for retargeting Stop / Redraw / Find to this pane's session.
private struct DetailPaneChrome<Content: View>: View {
    var pane: DetailPaneID
    var title: String
    @ObservedObject var model: WorkbenchViewModel
    @ViewBuilder var content: Content

    private var isActive: Bool { model.activePaneID == pane }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isActive ? .primary : .secondary)
                Spacer(minLength: 6)
                Button {
                    model.focusPane(pane)
                    model.closeActivePane()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close this pane (⌥⌘W)")
                .accessibilityLabel("Close Pane")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.18),
                    lineWidth: isActive ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        // Simultaneous so the tap also reaches the terminal NSView beneath —
        // the terminal claims keyboard focus; this just syncs activePaneID.
        .simultaneousGesture(TapGesture().onEnded {
            model.focusPane(pane)
        })
    }
}

/// Shown in the secondary pane when it has no assigned session. Lists the
/// current group's other sessions (the primary pane's session is excluded so
/// the operator can't pick the same session into both panes) and assigns the
/// tapped one to the secondary pane.
struct EmptyPanePicker: View {
    var excluding: UUID
    @ObservedObject var model: WorkbenchViewModel

    private var candidates: [ProcessEntry] {
        model.sessionEntries.filter { $0.id != excluding }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pick a session for this pane")
                    .font(.headline)
                Text("Choose a terminal to watch alongside the other pane. The same session can't be shown in both panes at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if candidates.isEmpty {
                Text("No other sessions in this group yet. Create another terminal, then pick it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(candidates) { entry in
                            Button {
                                model.assignSecondaryPane(to: entry.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(model.activeSession(for: entry) != nil ? Color.green : Color.secondary.opacity(0.5))
                                        .frame(width: 7, height: 7)
                                    Text(entry.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let cliName = model.cliName(for: entry) {
                                        Text(cliName)
                                            .font(.caption2.monospaced().weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.quaternary.opacity(0.6), in: Capsule())
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(16)
    }
}

/// Slide-in search bar that overlays the active terminal. Mounted only when
/// `model.isTerminalSearchPresented`. Owns its own FocusState so Return /
/// Shift+Return / Esc work even though the terminal underneath would
/// otherwise grab keystrokes.
/// Compact toggle button used inside the terminal search bar to expose the
/// SwiftTerm `SearchOptions` (case-sensitive / regex / whole-word). Lights
/// up the accent color when active so the user always sees which modes are
/// on before re-running the query.
private struct TerminalSearchToggleButton: View {
    var title: String
    var help: String
    @Binding var isOn: Bool
    var onChange: () -> Void

    var body: some View {
        Button {
            isOn.toggle()
            onChange()
        } label: {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .frame(minWidth: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
        .help(help)
    }
}

struct TerminalSearchBar: View {
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in terminal", text: $model.terminalSearchQuery)
                .textFieldStyle(.plain)
                .focused($fieldIsFocused)
                .onSubmit {
                    model.stepTerminalSearch(direction: .next)
                }
                .onChange(of: model.terminalSearchQuery) { _, newValue in
                    if newValue.isEmpty {
                        model.terminalSearchHasResult = true
                    } else {
                        model.stepTerminalSearch(direction: .next)
                    }
                }
            if !model.terminalSearchHasResult && !model.terminalSearchQuery.isEmpty {
                Text("No matches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
            }
            // SearchOptions toggles. Toggling re-issues the current query so
            // the result/no-result state stays in sync with what's visible.
            TerminalSearchToggleButton(
                title: "Aa",
                help: "Case-sensitive match",
                isOn: $model.terminalSearchCaseSensitive,
                onChange: { model.stepTerminalSearch(direction: .next) }
            )
            TerminalSearchToggleButton(
                title: ".*",
                help: "Treat the query as a regular expression",
                isOn: $model.terminalSearchRegex,
                onChange: { model.stepTerminalSearch(direction: .next) }
            )
            TerminalSearchToggleButton(
                title: "Wˌ",
                help: "Match whole words only",
                isOn: $model.terminalSearchWholeWord,
                onChange: { model.stepTerminalSearch(direction: .next) }
            )
            Button {
                model.stepTerminalSearch(direction: .previous)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Previous match (⇧⌘G)")
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button {
                model.stepTerminalSearch(direction: .next)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Next match (⌘G)")
            .keyboardShortcut("g", modifiers: [.command])
            Button("Done") {
                model.dismissTerminalSearch()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
        .frame(maxWidth: 540)
        .onAppear {
            fieldIsFocused = true
        }
    }
}

/// Slim, single-row session title strip. Status pills inline, a tight
/// keyboard-control cluster, and everything else hidden behind an inspector
/// chevron or an overflow menu. The terminal owns the screen.
struct SessionTitleStrip: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    @Binding var showsInspector: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: showsInspector ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(showsInspector ? "Hide session details" : "Show session details, transcripts, and management actions")

            statusDot
                .frame(width: 8, height: 8)

            Text(entry.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)

            // U10: when a LIVE session is non-idle/non-running, name THAT state
            // (glyph + short label, color-coded) right beside the title — the
            // header no longer reads "fine" while the agent is parked on a prompt.
            if let attention = liveAttentionToAnnounce {
                Label(attention.healthLabel, systemImage: attention.healthSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(attention.healthColor)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .help(attention.healthLabel)
                    .accessibilityLabel("Attention: \(attention.healthLabel)")
            }

            if let cliName = model.cliName(for: entry) {
                Text(cliName)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 6)

            if entry.isArchived {
                Label("Archived", systemImage: "archivebox")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button {
                    model.restoreCustomSession(entry)
                } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            } else {
                // #U33: ONE sectioned overflow menu (plus the primary Stop/Launch/
                // Recover), not two adjacent menus. RunningSessionHeaderControls now
                // owns the whole overflow — the standalone "More" menu that lived
                // here (and duplicated Copy Launch / Open Dir with the old "Session
                // Controls" menu) is folded in.
                RunningSessionHeaderControls(entry: entry, model: model)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
    }

    /// The U10 presentation for THIS entry's header, derived from the one shared
    /// Core seam so the header dot can't drift from the sidebar / boss signal.
    private var attentionPresentation: SessionDetailAttentionPresentation.Presentation {
        SessionDetailAttentionPresentation.resolve(
            attention: entry.attention,
            isActiveSession: model.activeSession(for: entry) != nil,
            canRecover: model.canRecover(entry),
            isArchived: entry.isArchived,
            reason: entry.attentionReason
        )
    }

    /// The live attention state to name in the header strip — only when a live
    /// session is non-idle/non-running (the states the operator must see). Active
    /// (green/running) needs no extra label beside the dot; inactive sessions are
    /// owned by the recovery surface.
    private var liveAttentionToAnnounce: AttentionState? {
        guard case let .attention(state) = attentionPresentation.dot else { return nil }
        switch state {
        case .waitingOnHuman, .blocked, .needsBossReview:
            return state
        case .active, .idle:
            return nil
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch attentionPresentation.dot {
        case let .attention(state):
            // The App maps the shared seam onto SwiftUI via the same
            // AttentionState.health* helpers the sidebar StatusDot/SessionChip use.
            Circle().fill(state.healthColor)
        case .recoverable:
            Circle().fill(Color.orange)
        case .inactive:
            Circle().fill(Color.secondary)
        case .archived:
            Circle().fill(Color.secondary.opacity(0.5))
        }
    }
}

/// Disclosure panel that owns everything the title strip dropped: pills,
/// resume command, transcript, notes, and recovery context. Closed by default.
struct SessionInspectorPanel: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    var onShowTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let groupName = model.groupName(for: entry) {
                    StatusPill(text: groupName, color: .secondary)
                }
                if let cliName = model.cliName(for: entry) {
                    StatusPill(text: cliName, color: .purple)
                }
                if let badge = entry.owner.sidebarBadge {
                    StatusPill(text: badge.label, color: .teal)
                }
                StatusPill(
                    text: entry.trust == .trusted ? "trusted" : "untrusted",
                    color: entry.trust == .trusted ? .green : .orange
                )
                StatusPill(
                    text: entry.autoResume ? "auto-resume" : "manual restart",
                    color: entry.autoResume ? .blue : .secondary
                )
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.launchCommand(for: entry))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let notes = entry.trimmedNotes {
                SessionNotesView(notes: notes)
            }
            HStack(spacing: 10) {
                Text(model.recoveryReasonSentence(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("Recovery detail: \(model.recoveryReason(for: entry))")
                if model.transcriptTail(for: entry) != nil {
                    Button {
                        onShowTranscript()
                    } label: {
                        Label("Transcript", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
    }
}

/// Modal sheet for transcript review — keeps the chrome out of the live view.
struct SessionTranscriptSheet: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript")
                        .font(.title3.weight(.semibold))
                    Text(entry.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if let tail = model.transcriptTail(for: entry) {
                TranscriptHistoryView(tail: tail)
                    .padding()
            } else {
                Text("No transcript captured yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(width: 720, height: 540)
    }
}

struct SessionNotesView: View {
    var notes: String

    var body: some View {
        Text(notes)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionStatusBar: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.isArchived ? "Archived" : (entry.lastSummary ?? "Configured"))
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if entry.isArchived {
                    Button {
                        model.restoreCustomSession(entry)
                    } label: {
                        Label("Restore", systemImage: "tray.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else if model.canRecover(entry) {
                    Button {
                        model.recover(entry)
                    } label: {
                        Label(model.recoveryButtonTitle(for: entry), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.isArchived ? "Restore this session before launching it." : model.recoveryReasonSentence(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.isArchived ? "" : "Recovery detail: \(model.recoveryReason(for: entry))")
                if !entry.isArchived, let health = model.executableHealth(for: entry) {
                    Text("Executable: \(health.detail)")
                        .font(.caption)
                        .foregroundStyle(health.status == .available ? SwiftUI.Color.secondary : SwiftUI.Color.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
        }
    }
}

struct CustomSessionManagementBar: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.beginEditingSession(entry)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(isRunning)
            .help(isRunning ? "Stop this session before editing it" : "Edit saved session settings")

            Button {
                model.duplicateCustomSession(entry)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            Menu {
                ForEach(model.state.projects) { project in
                    Button(project.name) {
                        model.moveSession(entry, to: project.id)
                    }
                    .disabled(project.id == entry.projectId)
                }
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(isRunning || model.state.projects.count < 2)
            .help(isRunning ? "Stop this session before moving it" : "Move this session to another workspace")

            if entry.isArchived {
                Button {
                    model.restoreCustomSession(entry)
                } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    model.archiveCustomSession(entry)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(isRunning)
                .help(isRunning ? "Stop this session before archiving it" : "Archive this session")
            }

            Button(role: .destructive) {
                model.requestDeleteCustomSession(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isRunning)
            .help(isRunning ? "Stop this session before deleting it" : "Delete this saved session")

            Spacer()
        }
        .controlSize(.small)
    }

    private var isRunning: Bool {
        model.activeSession(for: entry) != nil
    }
}

/// Calm, single-card view shown when the selected session is not currently
/// running. No fragmented transcript snippets, no embedded mini-terminal — just
/// the headline status, the launch command, and the one button you want.
struct InactiveTerminalSurface: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    var onShowTranscript: () -> Void = {}

    private var isArchived: Bool { entry.isArchived }
    private var canRecover: Bool { !isArchived && model.canRecover(entry) }
    /// U7: latest run needs recovery but there's no resumable session, so the
    /// only path forward is a fresh start that discards the prior conversation.
    private var manualRecoveryNeeded: Bool { model.manualRecoveryNeeded(for: entry) }

    private var statusHeadline: String {
        if isArchived {
            return "Archived"
        }
        if manualRecoveryNeeded {
            // Never present a no-resumable-session state as calmly "ready".
            return "No resumable session"
        }
        if let summary = entry.lastSummary, !summary.isEmpty {
            return summary
        }
        return canRecover ? "Ready to recover" : "Ready to launch"
    }

    /// The subtext under the headline. For a recoverable session it explains the
    /// recovery; for a manual-recovery session it states plainly that starting
    /// begins a new conversation (U7 — never a calm "Recovery: …" under a state
    /// whose only action discards history); otherwise it's empty.
    private var statusSubtext: String? {
        if isArchived {
            return "Restore this session to launch it again."
        }
        if manualRecoveryNeeded {
            return model.recoveryReasonSentence(for: entry)
        }
        if canRecover {
            return model.recoveryReasonSentence(for: entry)
        }
        return nil
    }

    private var statusTint: SwiftUI.Color {
        if isArchived { return .secondary }
        if manualRecoveryNeeded { return .orange }
        if canRecover { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isArchived ? "archivebox" : (manualRecoveryNeeded ? "exclamationmark.arrow.circlepath" : (canRecover ? "arrow.clockwise" : "terminal")))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(statusTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusHeadline)
                        .font(.title3.weight(.semibold))
                    if let subtext = statusSubtext {
                        Text(subtext)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help("Recovery detail: \(model.recoveryReason(for: entry))")
                    }
                }
                Spacer()
                if isArchived {
                    Button {
                        model.restoreCustomSession(entry)
                    } label: {
                        Label("Restore", systemImage: "tray.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                } else if manualRecoveryNeeded {
                    // U7: no resumable session — the action discards history, so
                    // it reads "Start fresh" and is gated behind a confirmation.
                    Button {
                        model.requestStartFresh(entry)
                    } label: {
                        Label("Start fresh", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                } else {
                    Button {
                        if canRecover {
                            model.recover(entry)
                        } else {
                            model.launch(entry)
                        }
                    } label: {
                        Label(canRecover ? model.recoveryButtonTitle(for: entry) : "Launch",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }

            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(model.launchCommand(for: entry))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isArchived ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    model.copyLaunchCommand(for: entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy launch command")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            if !isArchived, let health = model.executableHealth(for: entry), health.status != .available {
                Label("Executable: \(health.detail)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let tail = model.transcriptTail(for: entry) {
                TranscriptRehydrationPreview(tail: tail, onShowTranscript: onShowTranscript)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Compact "where was I" rehydration view for an inactive session — shows
/// the last few lines of the most recent transcript inline so the user
/// gets immediate context without clicking through to the full transcript
/// sheet. The full sheet is still one tap away via the "View full
/// transcript" button.
struct TranscriptRehydrationPreview: View {
    var tail: TranscriptTail
    var onShowTranscript: () -> Void

    /// How many trailing lines from the transcript we replay inline. Picked
    /// for "you can see the last few exchanges with the agent" without
    /// taking over the inactive surface.
    private static let inlineLineLimit = 12

    private var previewText: String {
        let lines = tail.text.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.inlineLineLimit)
        let joined = lines.joined(separator: "\n")
        // Strip ANSI escape sequences so a TUI's cursor-control codes don't
        // pollute the preview. We keep the text content but drop the styling
        // — a small loss vs the full sheet's monospaced raw view.
        return TranscriptRehydrationPreview.strippingAnsiEscapes(in: joined)
    }

    private static func strippingAnsiEscapes(in input: String) -> String {
        // Matches CSI sequences (ESC[…final) and OSC sequences (ESC]…BEL or
        // ESC]…ST). Covers the vast majority of what Codex / Claude emit;
        // anything else just shows as visible bytes which is fine for a
        // best-effort preview.
        let pattern = "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{0007}\u{1B}]*(\u{0007}|\u{1B}\\\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Where you left off", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if tail.truncated {
                    Text("tail")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button {
                    onShowTranscript()
                } label: {
                    Label("View full transcript", systemImage: "doc.text")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            ScrollView {
                Text(previewText.isEmpty ? "No transcript output yet." : previewText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .frame(maxHeight: 180)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct RunningSessionHeaderControls: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    private var isRunning: Bool { model.activeSession(for: entry) != nil }

    var body: some View {
        let controls = WorkbenchSurfacePolicy.sessionControls(
            isRunning: isRunning,
            isArchived: entry.isArchived,
            isRecoverable: model.recoveryPlan(for: entry) != nil
        )
        // #U33: ONE sectioned overflow menu (Ask Boss + Send / Window / This
        // Session) — driven by the pure SessionActionMenu seam so no command is
        // duplicated and no section wears a container-word label. The primary
        // Stop/Launch/Recover stay as their own button(s) beside it.
        let layout = SessionActionMenu.layout(
            isRunning: isRunning,
            isCustomSession: model.isCustomSession(entry)
        )
        HStack(spacing: 8) {
            ForEach(controls.primaryActions, id: \.self) { action in
                primaryButton(for: action)
            }
            Menu {
                menuButton(for: layout.topAction)
                ForEach(Array(layout.sections.enumerated()), id: \.offset) { _, section in
                    Divider()
                    Section(section.title) {
                        ForEach(section.actions, id: \.self) { action in
                            menuButton(for: action)
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions for this terminal")
        }
        .controlSize(.small)
    }

    /// Maps one pure `SessionActionMenu.Action` onto its button + handler. The
    /// labels/handlers/disable conditions are exactly those the two old menus used,
    /// now living in one place so they can't drift or duplicate.
    @ViewBuilder
    private func menuButton(for action: SessionActionMenu.Action) -> some View {
        switch action {
        case .askBoss:
            Button {
                Task { await model.runBossQuestion(about: entry) }
            } label: {
                Label("Ask Boss About This Session", systemImage: "bubble.left.and.text.bubble.right")
            }
            .disabled(model.bossCheckInIsRunning)
        case .controlC:
            Button {
                model.sendControlC(to: entry)
            } label: {
                Label("Ctrl-C", systemImage: "command")
            }
            .help("Send Ctrl-C to this terminal")
        case .escape:
            Button {
                model.sendEscape(to: entry)
            } label: {
                Label("Esc", systemImage: "escape")
            }
            .help("Send Esc to this terminal")
        case .eof:
            Button {
                model.sendEOF(to: entry)
            } label: {
                Label("EOF", systemImage: "eject")
            }
            .help("Send Ctrl-D / EOF to this terminal")
        case .redraw:
            Button {
                model.redrawTerminal(entry)
            } label: {
                Label("Redraw", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("l", modifiers: [.command])
            .help("Send Ctrl-L to redraw the terminal")
        case .focus:
            Button {
                model.focusTerminal(entry)
            } label: {
                Label("Focus", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Focus this terminal")
        case .copyLaunchCommand:
            Button {
                model.copyLaunchCommand(for: entry)
            } label: {
                Label("Copy Launch Command", systemImage: "doc.on.doc")
            }
        case .openWorkingDirectory:
            Button {
                model.openWorkingDirectory(for: entry)
            } label: {
                Label("Open Working Directory", systemImage: "folder")
            }
            .help(entry.workingDirectory)
        case .restart:
            Button {
                model.launch(entry)
            } label: {
                Label("Restart", systemImage: "play.fill")
            }
            .help("Restart this terminal")
        case .edit:
            Button {
                model.beginEditingSession(entry)
            } label: {
                Label("Edit Session…", systemImage: "pencil")
            }
            .disabled(model.activeSession(for: entry) != nil)
        case .duplicate:
            Button {
                model.duplicateCustomSession(entry)
            } label: {
                Label("Duplicate Session", systemImage: "plus.square.on.square")
            }
        case .move:
            Menu {
                ForEach(model.state.projects) { project in
                    Button(project.name) {
                        model.moveSession(entry, to: project.id)
                    }
                    .disabled(project.id == entry.projectId)
                }
            } label: {
                Label("Move to Workspace", systemImage: "folder")
            }
            .disabled(model.activeSession(for: entry) != nil || model.state.projects.count < 2)
        case .archive:
            Button {
                model.archiveCustomSession(entry)
            } label: {
                Label("Archive Session", systemImage: "archivebox")
            }
        case .delete:
            Button(role: .destructive) {
                model.requestDeleteCustomSession(entry)
            } label: {
                Label("Delete Session…", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func primaryButton(for action: WorkbenchSurfacePolicy.SessionAction) -> some View {
        switch action {
        case .stop:
            Button(role: .destructive) {
                model.requestStop(entry)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop this terminal")
        case .launch:
            Button {
                model.launch(entry)
            } label: {
                Label("Launch", systemImage: "play.fill")
            }
            .help("Launch this terminal")
        case .recover:
            Button {
                model.recover(entry)
            } label: {
                Label("Recover", systemImage: "arrow.clockwise.circle")
            }
            .help("Recover this terminal")
        default:
            EmptyView()
        }
    }

}

struct TerminalFocusView: View {
    var entry: ProcessEntry
    var session: TerminalSessionController
    @ObservedObject var model: WorkbenchViewModel
    private let chrome = WorkbenchSurfaceChrome.contract(for: .terminalFocus)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WorkbenchTerminalPalette.swiftUIBackground
                .ignoresSafeArea()
            TerminalPane(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, CGFloat(chrome.terminalContentTopInset))
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Button {
                    model.exitTerminalFocus()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("Return to the split workbench view")
                .accessibilityLabel("Exit Full Screen")
                .frame(width: 28)
                Button {
                    model.redrawTerminal(entry)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Send Ctrl-L to redraw the terminal")
                .keyboardShortcut("l", modifiers: [.command])
                .accessibilityLabel("Redraw")
                .frame(width: 28)
                Button {
                    model.sendControlC(to: entry)
                } label: {
                    Image(systemName: "command")
                }
                .help("Send Ctrl-C to this terminal")
                .accessibilityLabel("Ctrl-C")
                .frame(width: 28)
                Button {
                    model.sendEscape(to: entry)
                } label: {
                    Image(systemName: "escape")
                }
                .help("Send Esc to this terminal")
                .accessibilityLabel("Esc")
                .frame(width: 28)
                Button {
                    model.sendEOF(to: entry)
                } label: {
                    Image(systemName: "eject")
                }
                .help("Send Ctrl-D / EOF to this terminal")
                .accessibilityLabel("EOF")
                .frame(width: 28)
                Button(role: .destructive) {
                    model.requestStop(entry)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
                .help("Stop this terminal")
                .accessibilityLabel("Stop")
                .frame(width: 28)
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, CGFloat(chrome.floatingControlsTopInset))
            .padding(.trailing, 16)
        }
        .background(WorkbenchTerminalPalette.swiftUIBackground)
        .onAppear {
            session.focusInput()
            session.redrawDisplayBurst(after: [0.12, 0.35, 0.75, 1.25])
        }
    }
}

struct TranscriptHistoryView: View {
    var tail: TranscriptTail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Latest Transcript")
                    .font(.caption.weight(.semibold))
                if tail.truncated {
                    Text("tail")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(tail.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ScrollView {
                Text(tail.text.isEmpty ? "No transcript output yet" : tail.text)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        }
    }
}

struct NewTerminalGroupSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var rootPath: String

    /// Seam: resolve a directory URL from the configured "Choose" panel. Defaults to the
    /// real `panel.runModal()` syscall (`.OK ? panel.url : nil`), which blocks on a live GUI
    /// modal and so can't run in-process. A test injects a stub so the post-selection
    /// value-flow (`rootPath = url.path`) is driven without the modal. Only the literal
    /// `runModal()` lives behind the default — the panel configuration runs as prod.
    var chooseDirectory: (NSOpenPanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil }

    // The `@State` seeds default to an empty name + the machine home root (the prod
    // behavior the sidebar's "New Workspace" presents). The seam parameters keep that
    // default UNCHANGED at every production call site while letting a test drive the
    // Create / disabled / autofill logic from a chosen starting state (B4-redo).
    init(
        model: WorkbenchViewModel,
        initialName: String = "",
        initialRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.model = model
        _name = State(initialValue: initialName)
        _rootPath = State(initialValue: initialRootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(WorkbenchSurfacePolicy.newWorkspaceSheetTitle)
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Root Path", text: $rootPath)
                        .font(.body.monospaced())
                        // U34: when a root folder is chosen (or typed) and Name is
                        // still empty, default Name to the folder's basename — porting
                        // the New Terminal sheet's empty-guarded autofill so the single
                        // most common workspace name isn't hand-typed and Create isn't
                        // gratuitously disabled. A name the operator typed first is
                        // never clobbered (the guard lives in autofilledName).
                        .onChange(of: rootPath) {
                            if let autofilled = WorkspaceNameDerivation.autofilledName(currentName: name, chosenPath: rootPath) {
                                name = autofilled
                            }
                        }
                    Button {
                        chooseRootPath()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    guard model.createGroup(name: name, rootPath: rootPath) else {
                        return
                    }
                    dismiss()
                } label: {
                    Label("Create", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func chooseRootPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        if let url = chooseDirectory(panel) {
            rootPath = url.path
        }
    }
}

struct EditTerminalGroupSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    let project: WorkbenchProject
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var rootPath: String

    /// Seam: the "Choose" directory picker. Default = the real `runModal()` syscall; a test
    /// injects a stub to drive the post-selection `rootPath = url.path` value-flow. Only the
    /// literal `runModal()` is behind the default.
    var chooseDirectory: (NSOpenPanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil }

    init(model: WorkbenchViewModel, project: WorkbenchProject) {
        self.model = model
        self.project = project
        _name = State(initialValue: project.name)
        _rootPath = State(initialValue: project.rootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(WorkbenchSurfacePolicy.editWorkspaceSheetTitle)
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Root Path", text: $rootPath)
                        .font(.body.monospaced())
                    Button {
                        chooseRootPath()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    guard model.renameGroup(project, name: name, rootPath: rootPath) else {
                        return
                    }
                    dismiss()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func chooseRootPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        if let url = chooseDirectory(panel) {
            rootPath = url.path
        }
    }
}

struct NewTerminalSessionSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var trusted: Bool
    @State private var autoResume = true
    @State private var notes = ""

    /// Seam: the "Choose" working-directory picker. Default = the real `runModal()` syscall;
    /// a test injects a stub to drive the post-selection `workingDirectory = url.path`
    /// value-flow. Only the literal `runModal()` is behind the default.
    var chooseDirectory: (NSOpenPanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil }

    // `initialName` / `initialCommand` default to empty and `initialTrusted` to true (the
    // prod behavior the ⌘N sheet presents UNCHANGED); the seam params let a test seed the
    // `@State` so the `.onChange(of: command)` autofill guard arms, BOTH `trusted` ternary
    // arms, and the `create()` body are reachable (B4-redo). `workingDirectory` keeps its
    // `selectedProject?.rootPath ?? home` seed.
    init(
        model: WorkbenchViewModel,
        initialName: String = "",
        initialCommand: String = "",
        initialTrusted: Bool = true
    ) {
        self.model = model
        _name = State(initialValue: initialName)
        _command = State(initialValue: initialCommand)
        _trusted = State(initialValue: initialTrusted)
        _workingDirectory = State(initialValue: model.selectedProject?.rootPath ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Terminal")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                    .font(.body.monospaced())
                    .onChange(of: command) {
                        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return
                        }
                        if let parsed = TerminalCommandParser.parse(command),
                           let kind = TerminalAgentDetector.detect(executable: parsed.executable, arguments: parsed.arguments),
                           let displayName = TerminalAgentDetector.displayName(for: kind) {
                            name = displayName
                        }
                    }
                HStack {
                    TextField("Working Directory", text: $workingDirectory)
                        .font(.body.monospaced())
                    Button {
                        chooseWorkingDirectory()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
                Toggle("Trusted", isOn: $trusted)
                Toggle("Auto Resume", isOn: $autoResume)
                SessionNotesEditor(notes: $notes)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    create(launchAfterCreate: false)
                } label: {
                    Label("Create", systemImage: "checkmark")
                }
                .disabled(!canCreate)
                Button {
                    create(launchAfterCreate: true)
                } label: {
                    Label("Create & Launch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding()
        .frame(width: 560)
    }

    // Unit 4 / Slice 3: command and name are OPTIONAL — the factory defaults a
    // blank name to "Terminal" and turns a blank command into a `/bin/zsh -l`
    // login shell. Only a working directory is required (there's no sensible
    // default for where to run). So opening the sheet via the sidebar / ⌘N
    // shows Create & Launch already enabled, and an empty form launches a blank
    // login shell rather than being a dead-end with disabled buttons.
    // U13: the New and Edit sheets share one save-validity rule so they can't
    // drift apart again.
    private var canCreate: Bool {
        CustomTerminalSessionDraft.canSave(workingDirectory: workingDirectory)
    }

    private func create(launchAfterCreate: Bool) {
        let draft = CustomTerminalSessionDraft(
            name: name,
            command: command,
            workingDirectory: workingDirectory,
            trust: trusted ? .trusted : .untrusted,
            autoResume: autoResume,
            notes: notes
        )
        guard model.createCustomSession(draft, launchAfterCreate: launchAfterCreate) != nil else {
            return
        }
        dismiss()
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        if let url = chooseDirectory(panel) {
            workingDirectory = url.path
        }
    }
}

struct EditTerminalSessionSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    let entry: ProcessEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var workingDirectory: String
    @State private var trusted: Bool
    @State private var autoResume: Bool
    @State private var notes: String

    /// Seam: the "Choose" working-directory picker. Default = the real `runModal()` syscall;
    /// a test injects a stub to drive the post-selection `workingDirectory = url.path`
    /// value-flow. Only the literal `runModal()` is behind the default.
    var chooseDirectory: (NSOpenPanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil }

    init(model: WorkbenchViewModel, entry: ProcessEntry) {
        self.model = model
        self.entry = entry
        let draft = model.customSessionDraft(for: entry) ?? CustomTerminalSessionDraft(
            name: entry.name,
            command: "",
            workingDirectory: entry.workingDirectory,
            trust: entry.trust,
            autoResume: entry.autoResume,
            notes: entry.notes ?? ""
        )
        _name = State(initialValue: draft.name)
        _command = State(initialValue: draft.command)
        _workingDirectory = State(initialValue: draft.workingDirectory)
        _trusted = State(initialValue: draft.trust == .trusted)
        _autoResume = State(initialValue: draft.autoResume)
        _notes = State(initialValue: draft.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Terminal")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                    .font(.body.monospaced())
                HStack {
                    TextField("Working Directory", text: $workingDirectory)
                        .font(.body.monospaced())
                    Button {
                        chooseWorkingDirectory()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
                Toggle("Trusted", isOn: $trusted)
                Toggle("Auto Resume", isOn: $autoResume)
                SessionNotesEditor(notes: $notes)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 560)
    }

    // U13: match the New Terminal sheet — require only a working directory. The
    // blank login shell U4 creates round-trips to an empty-command draft, so the
    // old name-AND-command-AND-dir rule wrongly greyed out Save the moment you
    // opened Edit on it. A blank command saves as the login shell and a blank
    // name defaults to "Terminal" via the same factory `makeEntry` the save path
    // already routes through. Shared rule so the two sheets can't drift again.
    private var canSave: Bool {
        CustomTerminalSessionDraft.canSave(workingDirectory: workingDirectory)
    }

    private func save() {
        let draft = CustomTerminalSessionDraft(
            name: name,
            command: command,
            workingDirectory: workingDirectory,
            trust: trusted ? .trusted : .untrusted,
            autoResume: autoResume,
            notes: notes
        )
        guard model.updateCustomSession(entry, draft: draft) else {
            return
        }
        dismiss()
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        if let url = chooseDirectory(panel) {
            workingDirectory = url.path
        }
    }
}

struct SessionNotesEditor: View {
    @Binding var notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }
}

struct MachineRuntimeView: View {
    @ObservedObject var model: WorkbenchViewModel
    @StateObject private var loginItem: LoginItemController

    /// `loginItem` defaults to a fresh production `LoginItemController()` — the prod behavior
    /// UNCHANGED (the in-place `@StateObject` it had before). The seam lets a test inject a
    /// controller in a KNOWN state (a temp-rooted login item, an error preset) so the login-row
    /// Toggle/Refresh/`statusLine`/`lastError` arms render deterministically. Prod byte-identical:
    /// the default constructs the same controller the `@StateObject` previously did.
    init(model: WorkbenchViewModel, loginItem: LoginItemController = LoginItemController()) {
        self.model = model
        _loginItem = StateObject(wrappedValue: loginItem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Native Runtime", systemImage: "macwindow")
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(loginItem.isUpdating)
                .fixedSize()
                DashboardStatusLine(text: loginItem.statusLine)
                Button {
                    loginItem.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh login item status")
                .fixedSize()
            }
            if let lastError = loginItem.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Support Diagnostics", systemImage: "lifepreserver")
                DashboardStatusLine(
                    text: model.supportDiagnosticsStatusLine,
                    color: model.supportDiagnosticsStatusColor,
                    help: model.supportDiagnosticsURL?.path ?? model.supportDiagnosticsStatusLine
                )
                if model.supportDiagnosticsIsCollecting {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                }
                Button {
                    model.collectSupportDiagnostics()
                } label: {
                    Label("Collect", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.supportDiagnosticsIsCollecting)
                .help("Create a support diagnostics zip without transcript contents or raw workspace state")
                .fixedSize()
                if model.supportDiagnosticsURL != nil {
                    Button {
                        model.revealSupportDiagnostics()
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal the latest diagnostics zip in Finder")
                    .fixedSize()
                    Button {
                        model.copySupportDiagnosticsPath()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy the latest diagnostics zip path")
                    .fixedSize()
                }
            }
        }
    }
}

public struct ReleaseUpdateView: View {
    @ObservedObject var model: WorkbenchViewModel

    public init(model: WorkbenchViewModel) {
        self.model = model
    }

    public var body: some View {
        WorkbenchUpdatePanel(model: model, showTitle: true)
    }
}

public struct WorkbenchUpdatePanel: View {
    @ObservedObject var model: WorkbenchViewModel
    var showTitle: Bool

    public init(model: WorkbenchViewModel, showTitle: Bool) {
        self.model = model
        self.showTitle = showTitle
    }

    public var body: some View {
        WorkbenchShellUpdatePanelView(
            state: model.appShellUpdateState,
            actions: model.appShellUpdateActions,
            showTitle: showTitle
        )
    }
}

struct RecoveryDrillView: View {
    @ObservedObject var model: WorkbenchViewModel
    /// Zone + locale the drill's `ranAt` timestamp renders in (AN-007). Default to
    /// `.autoupdatingCurrent` (operator-local, prod byte-identical); the clock test injects
    /// `.gmt` + `en_GB` for a deterministic snapshot.
    var timeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .autoupdatingCurrent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Recovery Drill", systemImage: "arrow.clockwise.circle")
                DashboardStatusLine(text: model.recoveryDrillStatusLine(timeZone: timeZone, locale: locale))
                Button {
                    model.runRecoveryDrill()
                } label: {
                    Label("Run Drill", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
            if let result = model.recoveryDrillResult {
                ForEach(result.items.prefix(5)) { item in
                    // U8c: the operator-facing row reads as one plain sentence;
                    // the raw action / status transition / reason live in the
                    // tooltip for power users, never in the visible copy.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.groupName(forEntryId: item.id).map { "\($0) / \(item.entryName)" } ?? item.entryName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.recoveryDrillItemSentence(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(model.recoveryDrillItemDetail(for: item))
                }
            }
        }
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LaunchAgentLoginItemStatus
    @Published private(set) var isUpdating = false
    @Published var lastError: String?

    private let loginItem: LaunchAgentLoginItem

    /// `loginItem` defaults to the production `LaunchAgentLoginItem` rooted at the real
    /// app bundle + the user's home `LaunchAgents` dir — the prod behavior UNCHANGED. The
    /// seam parameter lets a test inject a `LaunchAgentLoginItem` rooted at a TEMP home so
    /// the controller's state transitions (status lines), the register/unregister flows
    /// (real plist file writes to temp — NO login-item syscall: `LaunchAgentLoginItem` is
    /// FileManager-based, not SMAppService), and the `lastError` error-formatting path are
    /// all driven hermetically. Prod byte-identical: the default constructs the same item.
    init(loginItem: LaunchAgentLoginItem = LaunchAgentLoginItem(appURL: LaunchAgentLoginItem.defaultAppURL())) {
        self.loginItem = loginItem
        self.status = loginItem.status()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var statusLine: String {
        switch status {
        case .enabled:
            return "enabled"
        case .needsUpdate:
            return "update needed"
        case .notInstalled:
            return "not registered"
        case .appBundleMissing:
            return "install app first"
        }
    }

    func refresh() {
        status = loginItem.status()
    }

    func setEnabled(_ enabled: Bool) {
        isUpdating = true
        defer {
            refresh()
            isUpdating = false
        }

        do {
            if enabled {
                try registerIfNeeded()
            } else {
                try unregisterIfNeeded()
            }
            lastError = nil
        } catch {
            lastError = "Open at Login update failed: \(error.localizedDescription)"
        }
    }

    private func registerIfNeeded() throws {
        guard status != .enabled else {
            return
        }
        try loginItem.install()
    }

    private func unregisterIfNeeded() throws {
        switch status {
        case .enabled, .needsUpdate:
            try loginItem.uninstall()
        case .notInstalled, .appBundleMissing:
            return
        }
    }
}

struct WorkbenchImportApplyResult: Equatable {
    var createdCount: Int
    var groupNames: [String]
    var skippedNames: [String]
    /// Terminals skipped because a `(projectId, name)` match was ALREADY in the
    /// workbench (a re-import no-op) — counted SEPARATELY from `skippedNames`
    /// (which is reserved for genuine error-skips like "couldn't create"). Surfaced
    /// in `detail` as "N already present" so a re-import of an edited
    /// `.workbench.json` doesn't SILENTLY drop the already-present terminals; the
    /// operator sees they were recognized, not lost. (Whether a matched terminal's
    /// changed command/cwd/trust should be UPDATED is a deferred product decision —
    /// this only makes the skip visible.) Additive default keeps existing
    /// constructions valid.
    var alreadyPresentCount: Int = 0
    var firstSelectedEntryID: UUID?
    /// Whether the durable `store.save(state)` that backs this import actually
    /// landed. The import-apply paths thread the view-model `save()`'s Bool here
    /// so the banner can render HONESTLY: green only when persisted, an orange
    /// "lost on quit" warning when the write failed. Defaults to `true` so this
    /// stays additive for any construction that doesn't gate on persistence.
    var persisted: Bool = true

    var hasImports: Bool { createdCount > 0 }

    var headline: String {
        // #U26: the recover-work action is "Bring Back Work" everywhere, so the post-import
        // receipt reads "Brought back N terminals" — not the stale "Arranged" verb.
        switch (createdCount, groupNames.count) {
        case (0, _):
            return "Nothing imported"
        case (1, _):
            return "Brought back 1 terminal"
        case (let n, 1):
            return "Brought back \(n) terminals in 1 workspace"
        case (let n, let g):
            return "Brought back \(n) terminals across \(g) workspaces"
        }
    }

    var detail: String? {
        var parts: [String] = []
        if !groupNames.isEmpty {
            parts.append(groupNames.joined(separator: ", "))
        }
        if !skippedNames.isEmpty {
            parts.append("Skipped: \(skippedNames.joined(separator: ", "))")
        }
        // Surface re-import no-ops so an already-present terminal whose entry in the
        // file changed isn't a SILENT drop — the operator sees it was recognized.
        if alreadyPresentCount > 0 {
            parts.append("\(alreadyPresentCount) already present")
        }
        if hasImports {
            parts.append(WorkbenchOnboardingNarrative.duplicateCleanup)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension WorkbenchGroupColor {
    /// Map a stored group color to a concrete SwiftUI Color. Uses the system
    /// semantic colors so each tag tracks light/dark appearance. Qualified
    /// as `SwiftUI.Color` because this file also imports `SwiftTerm.Color`.
    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .gray: return .gray
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .purple: return .purple
        case .pink: return .pink
        case .teal: return .teal
        }
    }
}
#endif
