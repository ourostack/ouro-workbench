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

private struct ProviderCheckProcessResult: Sendable {
    var timedOut: Bool
    var terminationStatus: Int32
    var output: String
}

private final class ProviderCheckOutputBuffer: @unchecked Sendable {
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

    /// Dispatch a menu-bar command to the model. Centralizes the global/
    /// navigation shortcuts so they're real menu key equivalents (which fire
    /// even when a terminal has keyboard focus) routed to the existing methods.
    private func handleMenuCommand(_ command: WorkbenchMenuCommand) {
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
            toggleSidebarVisibility()
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

    private weak var model: WorkbenchViewModel?
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var watchObservation: NSObjectProtocol?

    override private init() {
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
private struct NeedsYouEntryRow: View {
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
    @State private var isRefreshing = false

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

private struct HarnessAgentRow: View {
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
private struct HarnessActionRow: View {
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
private struct HarnessActionResultBanner: View {
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

private extension HarnessHealthState {
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

private extension BossWorkbenchMCPRegistrationStatus {
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

private extension Optional where Wrapped == BossWorkbenchMCPRegistrationStatus {
    /// Tint for a possibly-unknown registration status; unknown reads as
    /// secondary so the row doesn't imply a problem before the check runs.
    var harnessTint: SwiftUI.Color {
        self?.harnessTint ?? .secondary
    }
}

/// One-screen reference sheet for every keyboard shortcut the Workbench
/// surfaces. Reachable via ⌘? from anywhere in the app. Grouped by intent so
/// you can find what you need at a glance instead of trial-and-erroring the
/// menu.
struct ShortcutHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Single source of truth: the shortcut map lives in WorkbenchGuide so the
    // in-app sheet, the boss `workbench_sense`, and the inner-agent context
    // file can never drift apart. Edit shortcuts there, not here.
    private var groups: [WorkbenchGuide.ShortcutCategory] {
        WorkbenchGuide.shortcutCategories
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts")
                        .font(.title3.weight(.semibold))
                    Text("Press ⌘/ from anywhere to bring this back")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(group.title, systemImage: group.systemImage)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            VStack(spacing: 4) {
                                ForEach(group.shortcuts) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(row.keys)
                                            .font(.callout.monospaced().weight(.semibold))
                                            .frame(minWidth: 170, alignment: .leading)
                                            .textSelection(.enabled)
                                        Text(row.summary)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 10)
                                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 540)
    }
}

/// SwiftUI drop delegate that accepts file-URL items dropped on the
/// workbench window. Filters to directories — every other URL is
/// declined — and dispatches each accepted folder through the standard
/// `openWorkspaceConfig(at:)` path, so the result is identical to using
/// the More menu's "Open Workspace…" panel. Multi-folder drops are
/// allowed; the last one wins for focus and any non-directory items are
/// silently dropped rather than erroring loudly.
struct WorkspaceFolderDropDelegate: DropDelegate {
    let model: WorkbenchViewModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                // FileManager isn't Sendable, so resolve the singleton inside
                // the closure rather than capturing it across the boundary.
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else { return }
                let path = url.path
                Task { @MainActor in
                    _ = model.openWorkspaceConfig(at: path)
                }
            }
        }
        return true
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
            WorkbenchReleaseUpdateControls(model: model, showTitle: false)
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

    public init(model: WorkbenchViewModel) {
        self.model = model
    }

    private var buildHash: String {
        // Bundle CFBundleVersion holds the build number / git short hash
        // wired in by package-app.sh. Fall back to "dev" so a swift run
        // build (no bundle) still renders.
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    private var aboutPresentation: WorkbenchShellAboutPresentation {
        WorkbenchShellAboutPresentation(buildHash: buildHash)
    }

    public var body: some View {
        OuroAppShellUI.AppShellAboutView(
            model: aboutModel,
            updateState: model.appShellUpdateState,
            updateActions: model.appShellUpdateActions,
            aboutActions: AppShellAboutActions(
                openRepository: { NSWorkspace.shared.open(aboutPresentation.repositoryURL) },
                copyVersion: copyVersion,
                dismiss: { dismiss() }
            )
        )
        .frame(width: 520, height: 500)
    }

    private var aboutModel: AppShellAboutModel {
        aboutPresentation.model
    }

    private func copyVersion() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(aboutPresentation.versionLine, forType: .string)
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
    /// the toggle keeps the raw log reachable without a second entry point.
    @State private var showFullLog = false
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
    @State private var taught = false

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
    @StateObject private var loginItem = LoginItemController()
    @State private var isPresented = false

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
        switch loginItem.status {
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

private extension AutonomyRemediationKind {
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

private extension AutonomyReadinessState {
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

private extension HeaderCalmPresentation.BossDotColor {
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
        let count = visualOrderedItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
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
    @State private var showsAdvanced = false

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

    /// AN-007 / Q3 — the seed for the `humanName` `@State`, made injectable with a default
    /// that equals the prior behavior (`@State private var humanName = NSFullUserName()`).
    /// Production is BYTE-IDENTICAL: the default still evaluates to `NSFullUserName()` at the
    /// only call site (`ProviderConfigSheet(model:)`, `:529`), so the rendered "Your name"
    /// field reads the machine full user name exactly as before. A SNAPSHOT test injects a
    /// fixed value (e.g. "Test User") so the committed reference never carries the machine
    /// user name (a P3 determinism leak — the name flows into the bound
    /// `TextField("Your name", text: $humanName)` and the harness captures bound `TextField`
    /// values via AN-002). The same minimal-source-seam shape as the C4 `DecisionLogRow`
    /// `timeZone`/`locale` defaults and `Date.workbenchTimeText`'s `.autoupdatingCurrent`.
    init(model: WorkbenchViewModel, initialHumanName: String = NSFullUserName()) {
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
    @State private var page: OnboardingPage = .boss

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

private struct OnboardingBossChoiceRow: View {
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

private struct FirstRunStepRow: View {
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
                    if !readiness.repairSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Optional checks")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(readiness.repairSteps) { step in
                                OnboardingRepairStepRow(step: step, model: model)
                            }
                        }
                        .frame(maxWidth: 660)
                    }
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
private struct OnboardingBossReconstructView: View {
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
private struct SessionStatusRowView: View {
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
    @State private var isExpanded = false

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
            Text(entry.occurredAt.formatted(date: .omitted, time: .standard))
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
    @State private var isExpanded = false

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
                    ActionLogView(entries: model.recentActionLogEntries)
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
    @State private var showsInspector = false

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

private struct AgentLanesCard: View {
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

private struct AgentActionsCard: View {
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
    @State private var showsInspector = false
    @State private var showsTranscriptSheet = false

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
private struct SessionAttentionBanner: View {
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
private struct EmptyPanePicker: View {
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
private struct SessionTitleStrip: View {
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
private struct SessionInspectorPanel: View {
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
private struct SessionTranscriptSheet: View {
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
    @State private var name = ""
    @State private var rootPath = FileManager.default.homeDirectoryForCurrentUser.path

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
        if panel.runModal() == .OK, let url = panel.url {
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
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
        }
    }
}

struct NewTerminalSessionSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var trusted = true
    @State private var autoResume = true
    @State private var notes = ""

    init(model: WorkbenchViewModel) {
        self.model = model
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
        if panel.runModal() == .OK, let url = panel.url {
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
        if panel.runModal() == .OK, let url = panel.url {
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
    @StateObject private var loginItem = LoginItemController()

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
        WorkbenchReleaseUpdateControls(model: model, showTitle: true)
    }
}

public struct WorkbenchReleaseUpdateControls: View {
    @ObservedObject var model: WorkbenchViewModel
    var showTitle: Bool

    public init(model: WorkbenchViewModel, showTitle: Bool) {
        self.model = model
        self.showTitle = showTitle
    }

    public var body: some View {
        OuroAppShellUI.ReleaseUpdateControls(
            state: model.appShellUpdateState,
            actions: model.appShellUpdateActions,
            labels: ReleaseUpdateActionLabels(
                check: "Check for Updates...",
                review: "Review Update",
                install: "Install & Relaunch",
                openRelease: "View Release Notes"
            ),
            showTitle: showTitle,
            centered: !showTitle
        )
        // Span the full row width so centered settings/about rows stay visually balanced.
        .frame(maxWidth: .infinity)
    }
}

struct RecoveryDrillView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Recovery Drill", systemImage: "arrow.clockwise.circle")
                DashboardStatusLine(text: model.recoveryDrillStatusLine)
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

    init() {
        self.loginItem = LaunchAgentLoginItem(appURL: LaunchAgentLoginItem.defaultAppURL())
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

@MainActor
public final class WorkbenchViewModel: ObservableObject {
    @Published public var state: WorkspaceState
    @Published var selectedProjectID: UUID? {
        didSet {
            guard selectedProjectID != oldValue else {
                return
            }
            state.selectedProjectId = selectedProjectID
            if let selectedEntryID,
               !projectSessionEntries.contains(where: { $0.id == selectedEntryID }) {
                self.selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
            }
            save()
        }
    }
    @Published public var selectedEntryID: UUID? {
        didSet {
            guard selectedEntryID != oldValue else {
                return
            }
            // If ⌘F search is open, switching sessions must clear the
            // outgoing terminal's SwiftTerm highlight (the bar re-targets the
            // new session, so dismissing later would clear the wrong one) and
            // close the bar.
            if isTerminalSearchPresented {
                if let oldValue, let session = activeSessions[oldValue] {
                    session.terminal.clearSearch()
                }
                isTerminalSearchPresented = false
                terminalSearchHasResult = true
            }
            if selectedEntryID != nil {
                // Selecting a terminal pulls focus off the Agents pane so the
                // detail pane switches back to the live SessionDetailView.
                selectedAgentName = nil
            }
            // One-session-per-pane (W5): if the new primary selection is the
            // same session the secondary pane is showing, clear the secondary
            // pane back to an empty picker so the session's single terminal
            // view is never asked to mount in two panes at once. The session
            // "moves" to the primary pane (which the operator just selected).
            if let selectedEntryID, detailSplit?.secondaryEntryID == selectedEntryID {
                detailSplit?.secondaryEntryID = nil
                activePaneID = .primary
            }
            state.selectedEntryId = selectedEntryID
            // Slice ②b — clicking a tab surfaces its workspace in the sidebar/strip
            // (DB2 selection on click). Resolves to a no-op for an entry not in any
            // workspace. Done after the selection settles so the active workspace
            // tracks the chosen tab.
            if let selectedEntryID {
                selectWorkspaceContaining(entryID: selectedEntryID)
            }
            save()
        }
    }
    /// Slice ②b — which named workspace is active in the sidebar / tab-strip. Mirrors
    /// `selectedProjectID` (which stays as the DB1 backing-model selection), but is NOT
    /// persisted: ②b doesn't move state to a dedicated store (②c), so there is no
    /// `WorkspaceState.selectedWorkspaceId` field to bump. The pure
    /// `WorkspaceSidebarPresentation` seam supplies the deterministic fallback (DB2:
    /// nil/stale → first after pinned-first ordering) on every render, so a fresh launch
    /// has a defined active workspace with no extra selection step. Clicking a tab sets
    /// this to the tab's workspace (see `selectWorkspaceContaining`).
    @Published public var selectedWorkspaceID: UUID?
    /// Slice ②d — the inline rename editor's pure state (which target is being renamed +
    /// the draft text). One state serves the workspace menu AND the tab menu; a row/tab
    /// swaps its label for a `TextField` while `inlineRename.isEditing(target)` is true.
    /// Not persisted (a transient editing affordance). See `InlineRenameState`.
    @Published public var inlineRename = InlineRenameState()
    /// Currently focused Ouro agent for the Agents sidebar / detail pane.
    /// Mutually exclusive with `selectedEntryID`: setting either clears the other.
    /// Not persisted — the sidebar restores the natural session selection on
    /// next launch.
    @Published var selectedAgentName: String? {
        didSet {
            guard selectedAgentName != oldValue, selectedAgentName != nil else {
                return
            }
            selectedEntryID = nil
        }
    }
    @Published var activeSessions: [UUID: TerminalSessionController] = [:]
    @Published var terminalFocusEntryID: UUID?
    /// W5 — the detail pane's single split, or `nil` for the classic
    /// single-pane layout. Increment 2 persists this to
    /// `WorkspaceState.detailLayout` (additive, no schema bump): the `didSet`
    /// mirrors it into `state` and saves, so split / unsplit / assign-secondary
    /// and the auto-clear of a colliding secondary all survive relaunch. See
    /// `_planning/w5-split-panes-multiwindow.md`.
    @Published var detailSplit: DetailSplitState? {
        didSet {
            guard detailSplit != oldValue else { return }
            persistDetailLayout()
        }
    }
    /// Which pane currently has logical focus when a split is active. Drives
    /// the focus ring and the retargeting of selected-session commands
    /// (Stop / Redraw / Find) to the focused pane's session. Reset to
    /// `.primary` whenever the split opens or closes. Ignored when
    /// `detailSplit` is `nil` (single pane is always "active"). Persisted with
    /// the split so the focused pane is restored on relaunch.
    @Published var activePaneID: DetailPaneID = .primary {
        didSet {
            guard activePaneID != oldValue else { return }
            persistDetailLayout()
        }
    }
    @Published var errorMessage: String?
    @Published var bossDashboard: BossDashboardSnapshot?
    @Published var workbenchVisibility: WorkbenchVisibilitySnapshot?
    @Published var bossCheckInPrompt: String?
    @Published var bossCheckInAnswer: String?
    @Published var bossCheckInIsRunning = false
    @Published var bossQuestion = ""

    /// Whether the selected boss resolves to an installed, ready bundle that can
    /// actually answer a check-in. A named-but-not-installed/ready boss can't, so
    /// it reads as "no usable boss" for the Check In affordance.
    var currentBossIsUsable: Bool {
        ouroAgent(named: state.boss.agentName)?.isUsableAsBoss ?? false
    }

    /// U12: the single, pure decision behind every manual Check In surface — the
    /// header button + ⌘I, the menubar item, the command palette, and the
    /// autonomy-popover button. So the loudest control never silently no-ops: with
    /// no usable boss the affordance routes to set-up instead of doing nothing.
    var checkInAvailability: CheckInAvailability {
        CheckInAvailability.resolve(
            bossAgentName: state.boss.agentName,
            bossIsUsable: currentBossIsUsable,
            isRunning: bossCheckInIsRunning
        )
    }

    /// The tooltip for the current Check In state — describes the one-shot ask and
    /// its ⌘I shortcut, distinguishes it from the automatic Boss Watch loop, and
    /// (when there's no boss) points at setting one up. Single-sourced so every
    /// surface reads identically.
    var checkInHelpText: String {
        CheckInAvailability.helpText(for: checkInAvailability, bossAgentName: state.boss.agentName)
    }

    /// The verb for the manual check-in, used as the label on every surface so the
    /// action wears ONE name (U12). Distinct from the automatic "Boss Watch" loop
    /// and from the typed-question submit.
    public static let checkInActionLabel = "Check In"

    /// Drive a manual Check In from any surface (button, ⌘I, menubar, palette,
    /// popover). When a usable boss is set this runs the check-in. When NO boss is
    /// set it routes to the set-up-a-boss onboarding so the tap is never a dead
    /// click. FIX 4: when a boss IS configured but currently un-usable (daemon dead
    /// / bundle missing) it routes to the Harness Status sheet — which states "Boss
    /// X is not reachable" honestly and offers the repair/reconnect control — instead
    /// of dumping the operator into the full onboarding pick as if they'd never set
    /// up a boss. A tap while a check-in is already running is a no-op (the in-flight
    /// guard owns it).
    func attemptCheckIn() {
        switch checkInAvailability {
        case .ready:
            Task { await runBossCheckIn() }
        case .noBoss:
            presentOnboarding()
        case .bossUnreachable:
            // The boss exists, it just isn't reachable. Surface the honest
            // reconnect/repair affordance (Harness Status), never re-onboarding.
            isHarnessStatusPresented = true
        case .running:
            break
        }
    }
    @Published var bossWatchIsEnabled = false
    @Published var bossWatchLastRunAt: Date?
    @Published var bossWatchLastError: String?
    /// Consecutive automatic/manual check-in failures, driving exponential
    /// backoff of the automatic Boss Watch loop so a down/misconfigured boss
    /// isn't re-invoked every poll interval forever. Reset on any success.
    @Published var bossWatchConsecutiveFailures = 0
    /// Earliest time the automatic loop may attempt the next check-in after a
    /// failure (nil = no backoff). A manual check-in ignores this.
    private var bossWatchNextRetryAt: Date?
    @Published var bossWatchChangeSummaries: [WorkspaceChangeSummary] = []
    @Published var transcriptSearchQuery = ""
    @Published var transcriptSearchResults: [TranscriptSearchMatch] = []
    /// Bumped to request the transcript-search field expand + take focus (e.g.
    /// from the ⌘K "Search Transcripts" command when there's no query yet, so
    /// it puts the cursor in the field instead of doing nothing).
    @Published var transcriptSearchFocusToken = 0
    @Published var transcriptSearchLastQuery: String?
    @Published var recoveryDrillResult: RecoveryDrillResult?
    @Published var bossAppliedActions: [String] = []
    /// The originating queued-request id for the boss action currently being
    /// applied (#U24), so `recordActionLog` can stamp it onto the audit entry
    /// without threading a parameter through every `finishBossAction` call site.
    /// Set by `applyBossAction` for an externally-queued request and cleared on
    /// exit (via `defer`); nil for an operator-initiated action. Safe as transient
    /// state because the apply runs synchronously on the `@MainActor`.
    private var currentBossActionRequestId: UUID?
    /// R4b first-run cold-start bootstrap (Layer A). The live per-step presentation the Setup
    /// Assistant renders while the native bootstrap (S0→S5) brings the agent online, then the
    /// agent-driven (Layer B) framing once it hands off. Pure `FirstRunBootstrapDrive` output —
    /// the view layer is thin wiring over it.
    @Published var firstRunPresentation: FirstRunBootstrapPresentation?
    /// True while a `runFirstRunBootstrap()` pass is in flight (drives the header spinner and the
    /// re-entrancy guard in `FirstRunBootstrapDrive.shouldStart`).
    @Published var firstRunBootstrapIsRunning = false
    /// The seam-free handoff narration shown the instant Layer A hands off to Layer B (the boss
    /// inspects + remediates + narrates). `nil` until handoff.
    @Published var firstRunAgentDrivenNarration: String?
    @Published var mailboxError: String?
    @Published var isNewSessionSheetPresented = false
    @Published var isCommandPalettePresented = false
    @Published var isShortcutHelpPresented = false
    @Published var isRecoverySheetPresented = false
    /// Per-session ⌘F search state. The bar is mounted as an overlay on the
    /// active session's terminal pane; opening it focuses its text field and
    /// dispatches findNext/Previous against the SwiftTerm view of the
    /// currently-selected session.
    @Published var isTerminalSearchPresented = false
    @Published var terminalSearchQuery: String = ""
    /// Last seen "did the most recent search find anything" status so the
    /// search bar can show "No matches" when the user types something missing.
    @Published var terminalSearchHasResult: Bool = true
    /// User toggles in the in-terminal search bar. SwiftTerm exposes these as
    /// `SearchOptions`; we mirror them as @Published so the bar's UI binds
    /// directly and toggling re-issues the current query.
    @Published var terminalSearchCaseSensitive: Bool = false
    @Published var terminalSearchRegex: Bool = false
    @Published var terminalSearchWholeWord: Bool = false
    /// Persisted terminal font size. Clamped to 9..28pt; ⌘+/⌘-/⌘0 cycle it.
    /// Persisted in UserDefaults so the user's chosen size survives across
    /// launches; loaded once at init.
    @Published var terminalFontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: WorkbenchViewModel.terminalFontSizeDefaultsKey)
        return saved >= 9 ? CGFloat(saved) : 13
    }()
    /// Recently-opened workspace directories surfaced via the More menu's
    /// `Open Recent` submenu and as `Open Recent: …` command palette entries.
    /// Persisted in UserDefaults so they survive across launches.
    @Published var recentWorkspacePaths: [String] = {
        UserDefaults.standard.stringArray(forKey: WorkbenchViewModel.recentWorkspacePathsDefaultsKey) ?? []
    }()
    @Published var isOuroAgentInstallSheetPresented = false
    /// Settings sheet (⌘,) consolidates user prefs previously scattered as
    /// raw UserDefaults reads — terminal font size, theme override, menu-bar
    /// icon visibility, recents limit. Mounted once at the root via .sheet
    /// like every other workbench sheet.
    @Published var isSettingsSheetPresented = false
    /// About sheet — discoverable home for app version, build hash, license
    /// links. Reached from the More menu and the ⌘K palette.
    @Published var isAboutSheetPresented = false
    /// Harness Status sheet — a read-only, consolidated view of ouro daemon
    /// health, the local agent inventory, and boss MCP-registration /
    /// reachability. Reached from the More menu and the ⌘K palette. The first
    /// W3 step toward Workbench being the human control panel for the harness.
    @Published var isHarnessStatusPresented = false
    /// Drives the "Bring your agent back online?" confirmation dialog raised from
    /// the Harness Status sheet's daemon section. The action itself runs the
    /// detached `DaemonManager.ensureRunning()` cycle in-app — no pane, no CLI seam.
    @Published var isRepairHarnessDaemonConfirmationPresented = false
    /// Drives the "Register Workbench MCP?" confirmation dialog raised from the
    /// Harness Status sheet's boss section. Reuses `registerWorkbenchForBossChoice`.
    @Published var isRegisterHarnessMCPConfirmationPresented = false
    /// Last result of a Harness Status control action (daemon repair / MCP
    /// registration), shown as a transient banner in the sheet. Cleared when the
    /// sheet refreshes or the user dismisses it.
    @Published var harnessActionResult: HarnessActionResult?
    /// The decision **inbox** surface — the prioritized triageable queue of
    /// sessions that need the operator, with the full chronological decision log
    /// a toggle away. Reached from the boss pane and the ⌘K palette.
    @Published var isDecisionLogPresented = false
    /// User's terminal-theme override. `.system` follows the macOS appearance
    /// (current default); `.light`/`.dark` pin the terminal palette regardless
    /// of system. Persisted in UserDefaults.
    @Published var terminalThemeOverride: TerminalThemeOverride = {
        let raw = UserDefaults.standard.string(forKey: WorkbenchViewModel.terminalThemeOverrideDefaultsKey) ?? ""
        return TerminalThemeOverride(rawValue: raw) ?? .system
    }()
    /// Show the menubar status item? Defaults to true so existing users see
    /// no change; toggling it off removes the NSStatusItem at the next
    /// settings change. Persisted in UserDefaults.
    @Published var showMenuBarStatusItem: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: WorkbenchViewModel.showMenuBarStatusItemDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: WorkbenchViewModel.showMenuBarStatusItemDefaultsKey)
    }()
    /// Global kill-switch for boss auto-advance. Defaults to **on** (TTFA —
    /// automate what's safe), but even on it only fires on a `trusted` session
    /// (untrusted is the default, so this is the operator's per-session opt-in)
    /// with a trusted friend and a non-destructive prompt. Persisted; flip off
    /// to make the boss escalate everything instead. Every send is audited in
    /// the decision log.
    @Published var bossAutoAdvanceEnabled: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: WorkbenchViewModel.bossAutoAdvanceEnabledDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: WorkbenchViewModel.bossAutoAdvanceEnabledDefaultsKey)
    }() {
        didSet {
            UserDefaults.standard.set(bossAutoAdvanceEnabled, forKey: Self.bossAutoAdvanceEnabledDefaultsKey)
        }
    }
    /// Auto-launch every `autoResume: true` terminal on app startup?
    /// Defaults to **off** — turning this on changes launch behavior, so we
    /// don't surprise existing users. When on, reopening Workbench brings
    /// declared agents up automatically. Persisted in UserDefaults.
    @Published var autoLaunchResumableOnStartup: Bool = {
        UserDefaults.standard.bool(forKey: WorkbenchViewModel.autoLaunchResumableOnStartupDefaultsKey)
    }()
    @Published var commandPaletteQuery = ""
    /// Free-text filter for the sidebar session list (the field at the top of
    /// `WorkbenchSidebarView`). Empty = show everything (current behavior).
    /// Session-scoped only — deliberately not part of the Codable workspace
    /// state, so it resets on relaunch rather than persisting a stale filter.
    /// Distinct from `terminalSearchQuery` (in-terminal ⌘F) and
    /// `commandPaletteQuery` (⌘K launcher); see `SidebarSessionFilter`.
    @Published var sidebarFilter = ""
    /// Command chosen from the ⌘K palette, deferred until the palette sheet
    /// has fully dismissed. Running a command that opens another sheet
    /// (Settings, About, New Terminal) in the same runloop as the palette's
    /// `dismiss()` races SwiftUI's single-presentation context and the target
    /// sheet often never appears. The palette stashes the choice here and
    /// `performPendingPaletteCommand()` runs it from `.onDisappear`.
    @Published var pendingPaletteCommand: WorkbenchCommandDescriptor?
    @Published var editingGroup: WorkbenchProject?
    @Published var pendingDeleteGroup: WorkbenchProject?
    @Published var editingSession: ProcessEntry?
    @Published var pendingDeleteSession: ProcessEntry?
    /// U11: the session whose Stop the operator triggered on a LIVE/holding agent
    /// (via the ⌘. chord or a Stop button). Drives the named confirmation that
    /// guards a reflexive cancel-chord from nuking an in-flight agent. Non-nil ⇒
    /// the confirmation is presented; idle/finished sessions never set it.
    @Published var pendingStopSession: ProcessEntry?
    /// U7: the session whose "Start fresh" the operator tapped on the inactive
    /// surface. Drives the one-line confirmation that names what's lost before
    /// the fresh-launch path runs. Non-nil ⇒ the confirmation is presented.
    @Published var pendingStartFresh: ProcessEntry?
    @Published var ouroAgents: [OuroAgentRecord] = []
    /// Live steady-state readiness overlay for the agent rows. The scanner's `.ready`
    /// only means "agent.json present & enabled" — a config-only fact that the sidebar /
    /// "Installed agents" rows used to render as a green "ready" dot WITHOUT any live
    /// connection check (false green: slugger reads ready while `ouro check` returns
    /// `failed (401 … expired)`). `refreshAgentOutwardReadiness()` runs a real outward-lane
    /// `ouro check` per config-ready agent and records the F2-classified verdict here; the
    /// rows fold it through `InstalledAgentRowPresentation.liveReadiness(...)` so a row is
    /// only green when a live check actually returned `.working`. Absent key ⇒ no live
    /// verdict yet (row reads "checking…" while in-flight, else "not verified").
    @Published var agentOutwardVerdicts: [String: ProviderConnectionVerdict] = [:]
    /// When the outward-readiness overlay was last (re)checked. Set at the START of
    /// `refreshAgentOutwardReadiness()`, so it records freshness AND debounces concurrent
    /// triggers: a refresh already in flight has already stamped this, so the staleness
    /// guard (`refreshOutwardReadinessIfStale`) won't re-fire it. `nil` ⇒ never checked yet.
    @Published private(set) var lastOutwardReadinessCheckAt: Date?
    /// The set of agent names whose outward `ouro check` is currently in flight, so a row
    /// can honestly show "checking…" rather than a premature green or a stale "not verified".
    @Published var agentChecksInFlight: Set<String> = []
    /// F6 — the agent the operator has armed for removal (the destructive remove-agent action sits
    /// behind a confirmation). Non-nil ⇒ the confirmation dialog is presented; `removeAgent` clears it.
    @Published var agentPendingRemoval: OuroAgentRecord?
    @Published var bossWorkbenchMCPRegistration: BossWorkbenchMCPRegistrationSnapshot?
    @Published var bossWorkbenchMCPRegistrationByAgentName: [String: BossWorkbenchMCPRegistrationSnapshot] = [:]
    /// #F9 — the CACHED `tools/list` injection verdict per agent, set ONCE at the handoff edge
    /// (never on every readiness getter — that would spawn an `ouro mcp-serve` per popover
    /// open). `refreshWorkbenchMCPRegistration` overlays it onto the on-disk snapshot so a
    /// present-but-stripped boss reads `.toolsNotInjected`. Re-probed only on explicit refresh
    /// / boss change. Only a CONFIRMED `.absent` here flips the status to the loud blocker; an
    /// `.unconfirmed` (timeout / not-probed) leaves the snapshot alone.
    @Published var bossWorkbenchToolsInjectionByAgentName: [String: WorkbenchToolsInjectionProbeOutcome] = [:]
    /// #F9 — the cross-actor sink the current bootstrap's handoff-edge probe writes to. Drained
    /// into the published map on the main actor in `completeFirstRunBootstrap`.
    var bossWorkbenchToolsInjectionRecorder = WorkbenchToolsInjectionRecorder()
    @Published var executableHealthByEntryID: [UUID: ExecutableHealth] = [:]
    @Published var gitStatusByEntryID: [UUID: GitSessionStatus] = [:]
    /// Per-session activity (todo progress, current step, last tool, token/$)
    /// derived from each agent's structured JSONL transcript. Mirrors
    /// `gitStatusByEntryID`: refreshed off-main by `refreshSessionActivity()`,
    /// read by the sidebar row's `SessionChip`. Absent → the chip shows only the
    /// free facets (health + last-activity).
    @Published var sessionActivityByEntryID: [UUID: SessionActivity] = [:]
    /// Persistent `screen` sessions reported alive (Attached/Detached) at the
    /// last refresh. A session in this set means the agent kept running while
    /// the app was gone, so recovery becomes a lossless reattach rather than a
    /// respawn. Refreshed at startup (before recovery runs) and on demand.
    @Published var liveScreenSessionNames: Set<String> = []
    @Published public var releaseUpdateSnapshot: ReleaseUpdateSnapshot?
    @Published public var releaseUpdateIsChecking = false
    /// In-app one-click update: whether a download/verify/install is in flight,
    /// the current progress line, and any error from the last attempt.
    @Published var releaseUpdateIsInstalling = false
    @Published var releaseUpdateInstallStatus: String?
    @Published public var releaseUpdateInstallError: String?
    /// Drives the "Software Update" confirmation dialog reached from the More
    /// menu / ⌘K: installable → offer Install & Relaunch; otherwise inform.
    @Published var updatePrompt: WorkbenchUpdatePrompt?
    /// Auto-update (Codex/Claude-Code style): quietly check on launch, stage the
    /// download in the background, and apply it on quit. Default on; opt out in
    /// Settings. Persisted.
    @Published var autoUpdateEnabled: Bool = {
        UserDefaults.standard.object(forKey: WorkbenchViewModel.autoUpdateEnabledDefaultsKey) as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(autoUpdateEnabled, forKey: Self.autoUpdateEnabledDefaultsKey)
        }
    }
    /// A background-staged update ready to apply on quit (drives the header
    /// "Update" badge). The downloaded + verified bundle is held in
    /// `pendingStagedUpdate`.
    @Published var stagedUpdateVersion: String?
    private var pendingStagedUpdate: WorkbenchUpdateInstaller.Staged?
    /// Set while a *manual* "Install & Relaunch" is mid-flight so the quit-time
    /// hook doesn't also try to apply (which would double-swap / fight the
    /// relaunch helper).
    private var isApplyingManualUpdate = false
    private var autoUpdateCheckStartedThisSession = false
    @Published var supportDiagnosticsResult: SupportDiagnosticsResult?
    @Published var supportDiagnosticsIsCollecting = false
    @Published var supportDiagnosticsError: String?
    /// The in-app bug reporter. The note the operator types; whether a bundle is
    /// being assembled; the last bundle's folder + any non-fatal warnings (e.g.
    /// screenshot/diagnostics gathering failed but the report was still written);
    /// and any fatal error. Reached from the More menu (⌘⇧B) and the ⌘K palette.
    @Published var isReportBugPresented = false
    /// Drives the "Reset to Factory Defaults" confirmation dialog. Set true by
    /// the More menu / ⌘K command; the dialog calls `resetToFirstRun()` on confirm.
    @Published var isResetFirstRunConfirmationPresented = false
    @Published var bugReportNote = ""
    @Published var bugReportIsSubmitting = false
    @Published var bugReportError: String?
    @Published var lastBugReportURL: URL?
    @Published var lastBugReportWarnings: [String] = []
    /// The note that produced the last bundle, kept after the editor clears so
    /// the GitHub issue title can be derived from it.
    @Published var lastBugReportNote = ""
    /// Filing the last bug report as a GitHub issue (the "good venue" for
    /// tracking): whether a `gh issue create` is in flight, the resulting issue
    /// URL, and any error (e.g. `gh` missing or not authenticated).
    @Published var bugReportIssueIsFiling = false
    @Published var bugReportIssueURL: String?
    @Published var bugReportIssueError: String?
    /// U30(a): durable per-report filed-status store. Writes a `status.json` next to
    /// `report.md` in each bundle so a report's filed/unfiled status + issue URL survive
    /// the sheet (and the app) closing, and a boss can read them back.
    let bugReportStatusStore = BugReportStatusStore()
    @Published var isOnboardingPresented = false
    /// Whether onboarding has been GENUINELY completed (the user reached Arrange
    /// Work with a ready boss). Persisted so the wizard keeps presenting on every
    /// launch until setup is actually finished — picking a boss and then
    /// dismissing the wizard does NOT count as completed, so a half-finished pick
    /// can never lock the user out of onboarding. Reset only by clearing app
    /// defaults (or `resetToFirstRun()`).
    @Published var onboardingHasBeenCompleted: Bool = {
        UserDefaults.standard.bool(forKey: WorkbenchViewModel.onboardingCompletedDefaultsKey)
    }() {
        didSet {
            UserDefaults.standard.set(onboardingHasBeenCompleted, forKey: Self.onboardingCompletedDefaultsKey)
        }
    }
    /// The boss agent name captured when the onboarding wizard opens, BEFORE the
    /// user can change it. If the user picks a different boss mid-wizard and then
    /// dismisses without completing, `rollbackOnboardingIfIncomplete()` restores
    /// this snapshot so the abandoned pick never persists. `nil` when no wizard
    /// session is in flight.
    var onboardingBossSnapshot: String?
    @Published var onboardingReadiness: OnboardingReadiness?
    @Published var onboardingProviderChecks: [String: OnboardingProviderCheckResult] = [:]
    /// Per-lane generation so a late completion from a previous run doesn't
    /// overwrite the state after the user has moved on / dismissed onboarding;
    /// and tracked Tasks so we can cancel them on dismiss.
    private var onboardingProviderCheckGeneration: [String: Int] = [:]
    private var onboardingProviderCheckTasks: [String: Task<Void, Never>] = [:]
    /// Set once `resetToFirstRun()` begins; suppresses all persistence so the
    /// wiped state file isn't rewritten before the relaunch.
    private var isResettingToFirstRun = false
    /// Set for the duration of `load()`'s body; suppresses `save()` so the
    /// `@Published` selection/layout assignments load() makes (which each fire a
    /// `didSet` → `save()`) can't atomically overwrite `stateURL` before the
    /// deliberate, ordered persistence at the end of load(). This is what makes
    /// F5's salvage-before-resave ordering actually hold: without it, restoring
    /// `selectedProjectID` / `selectedEntryID` / the detail layout would re-save
    /// the survivors-only state OVER the original pre-drop bytes BEFORE
    /// `writeSalvageCopy()` ever runs, so the salvage would capture post-drop
    /// bytes and the dropped rows would be lost. The trailing `store.save(state)`
    /// at the end of load() calls the store DIRECTLY (not via `save()`), so it
    /// bypasses this guard and the final survivors-only state is still persisted
    /// — after the salvage.
    private var isLoadingState = false
    /// FIX3 — non-zero while a single boss check-in is applying actions + recording
    /// decisions inside `withBatchedSave`. During that window the per-step `save()`
    /// calls (`recordActionLog`'s trailing save, `recordBossDecisions`'s save) are
    /// suppressed so the action-log rows and their decision/inbox rows persist
    /// ATOMICALLY in one trailing `save()` — a crash mid-check-in (or a zero-change
    /// decisions batch) can no longer leave executed actions without their audit
    /// rows. A counter (not a Bool) so nested batched scopes compose. `save()`'s
    /// existing reset/load suppression guards still win.
    private var bossCheckInSaveBatchDepth = 0
    private var isFirstRunSetupForcedOnLaunch = false
    @Published var onboardingCandidates: [RecentSessionCandidate] = []
    @Published var onboardingProposal: WorkbenchImportProposal?
    @Published var onboardingIsScanning = false
    @Published var onboardingImportSummaryHasImports = false
    @Published var lastImportSummary: WorkbenchImportApplyResult?
    /// Pending boss proposals awaiting the operator's review in the native card.
    /// Populated from `proposalQueue` by `loadPendingProposals()`; the card binds
    /// to it and the mutation/approve methods write back through the queue. OPT-IN
    /// surfacing only — never blocks any other flow.
    @Published var pendingProposals: [AgentProposal] = []
    /// Slice 7: set once the onboarding wizard has handed the reconstruction task to the
    /// boss (boss-driven `see → propose → act`). Drives the hand-off surface's copy from
    /// "Bring back my work" to "your boss is working on it" without re-running the hardcoded
    /// scan. Reset on first-run reset so a fresh wizard starts clean.
    @Published var onboardingReconstructionHandedOff = false
    /// Whether the native provider-config form (the one human gate) is presented. Flipped true
    /// by `requestProviderConfig` (and the native onboarding provider-setup affordance).
    /// NON-SECRET-BEARING: this flag only opens the form; the credential is entered natively in
    /// the form and flows to `ouro hatch` argv — never through the agent's context.
    @Published var isProviderConfigPresented = false
    /// The agent name the provider form is connecting a provider for (label/seed only — never a
    /// credential). Defaults to the selected boss when the request named no explicit agent.
    @Published var providerConfigAgentName: String = ""

    /// True when the provider form is creating a BRAND-NEW agent (the empty-machine /
    /// "create an agent" path) rather than connecting a provider for an existing one.
    /// In new-agent mode the form collects the agent name + provider + credentials and
    /// cold-start-hatches headlessly — no visible `ouro hatch` CLI pane.
    @Published var providerConfigIsNewAgent = false

    /// F1 — true while a cold-start hatch + post-hatch probe is in flight. The form spins on this
    /// instead of dismissing-and-reporting-success synchronously; it clears once the probe
    /// classifies the real outcome.
    @Published var providerConfigColdStartInFlight = false

    /// F6 — the spinner label shown next to `providerConfigColdStartInFlight`'s ProgressView. The
    /// flag is shared by two distinct in-flight flavors (cold-start hatch vs existing-agent
    /// reconnect), so the label must branch on which one is running — "Creating your agent…" is
    /// wrong for a reconnect. The model sets this at launch (where it knows the flavor); the view
    /// just renders it. Seam-free copy (no `ouro`/`vault` leakage). Defaults to the cold-start
    /// wording so the existing cold-start path reads unchanged.
    @Published var providerConfigInFlightLabel = "Creating your agent…"

    /// F1 — the seam-free outcome line surfaced in the form when a cold-start did NOT verify as
    /// ready (created-but-not-connected, or an honest failure). nil while in flight / on success.
    @Published var providerConfigColdStartMessage: String?

    /// F13 — true ONLY for the honest needs-vault cold-start outcome (the agent was created but
    /// its provider isn't connected yet because the headless hatch couldn't persist the credential
    /// into a vault that needs an interactive TTY secret). It gates the "Finish setup" affordance
    /// in the provider-config form, which runs the documented `ouro vault create && auth && refresh`
    /// recovery chain in a native terminal. Stays true across a failed recovery attempt so the user
    /// can retry; cleared only when the re-probe confirms `.working`. NEVER set for a plain
    /// `.failed` cold-start (that path never produced a recoverable bundle).
    @Published var providerConfigNeedsVaultSetup = false

    /// F13 — the provider the user typed in the cold-start form, stashed so the vault-onboarding
    /// recovery chain (`ouro auth --provider <p>`) can name it. The credential itself is NOT stored
    /// here — it's gone after the ephemeral hatch argv, which is exactly why F13 must re-collect it
    /// interactively in the native recovery terminal. Set alongside `providerConfigNeedsVaultSetup`.
    @Published var providerConfigColdStartProvider: WorkbenchProvider?

    private let paths: WorkbenchPaths
    private let store: WorkbenchStore
    private let bootstrapper = WorkbenchBootstrapper()
    private let startupRecoveryReconciler = StartupRecoveryReconciler()
    private let summarizer = WorkspaceSummarizer()
    private let mailboxClient: MailboxClient
    private let bossDashboardBuilder = BossDashboardBuilder()
    private let visibilityBuilder = WorkbenchVisibilityBuilder()
    private let workCardReader: OuroWorkCardReader
    private let bossBridgePlanner = BossAgentBridgePlanner(ownerName: WorkbenchViewModel.resolvedOwnerName())
    private let bossPromptBuilder = BossAgentPromptBuilder(ownerName: WorkbenchViewModel.resolvedOwnerName())
    private let autonomyReadinessBuilder = AutonomyReadinessBuilder()
    private let harnessStatusBuilder = HarnessStatusBuilder()
    private let changeSummarizer = WorkspaceChangeSummarizer()
    private let commandPalette = WorkbenchCommandPalette()
    private let bossMCPClient: BossAgentMCPClient
    private let daemonManager: DaemonManager
    private let bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar
    private let ouroAgentInventory: OuroAgentInventory
    private let ouroAgentInstallCommandBuilder = OuroAgentInstallCommandBuilder()
    private let executableHealthChecker: ExecutableHealthChecker
    private let gitStatusReader = GitStatusReader()
    private let sessionActivityReader = SessionActivityReader()
    private let bossActionParser = BossWorkbenchActionParser()
    private let bossDecisionParser = BossDecisionParser()
    private let bossActionAuthorizer = BossWorkbenchActionAuthorizer()
    private let terminationPolicy = ProcessTerminationPolicy()
    private let customSessionFactory = CustomTerminalSessionFactory()
    private let customSessionManager = CustomTerminalSessionManager()
    private let transcriptTailReader = TranscriptTailReader()
    private let transcriptSearcher = TranscriptSearcher()
    private let recoveryDrill = RecoveryDrill()
    private let recoveryPhrasebook = RecoveryReasonPhrasebook()
    private let terminalCommandPlanPhrasebook = TerminalCommandPlanPhrasebook()
    private let onboardingAdvisor = WorkbenchOnboardingAdvisor()
    private let onboardingProposalBuilder = WorkbenchImportProposalBuilder()
    private let deskBridgePlanner = DeskBridgePlanner()
    /// R4b — the pure first-run presenter. ALL the bootstrap branching / sequencing / copy lives
    /// in this Core type; the App-side methods below are thin wiring that inject the real effects
    /// and publish its output.
    private let firstRunDrive = FirstRunBootstrapDrive()
    private let externalActionQueue: WorkbenchActionRequestQueue
    /// Transport for the boss's `workbench_propose` CAPABILITY. The card reads
    /// pending proposals from here and writes the operator's `result()` back. This
    /// is purely OPT-IN surfacing — it never gates any other flow; an unanswered
    /// proposal just sits pending until the operator (or the boss's own act-anyway
    /// path) moves on.
    private let proposalQueue: AgentProposalQueue
    private let releaseUpdateChecker: ReleaseUpdateChecker
    private var manuallyTerminatedRunIDs = Set<UUID>()
    /// F13 — the entry id + runId of the in-flight vault-onboarding recovery terminal (the one-shot
    /// `ouro vault create && auth && refresh` chain), captured at launch so `markTerminated` can
    /// recognize ITS exit (and only its exit) and re-probe. Both nil when no recovery is in flight.
    /// The agent name is held too so the re-probe + `.ready` log name the right agent.
    private var vaultOnboardingEntryID: UUID?
    private var vaultOnboardingRunID: UUID?
    private var vaultOnboardingAgentName: String?
    /// F6 — which flavor the in-flight vault terminal is (onboarding = F13 first-time setup, or
    /// rotation = an existing agent reconnecting). Captured at launch so `completeVaultOnboarding`
    /// surfaces the correctly-flavored seam-free copy on a failed re-probe. Defaults to onboarding
    /// (F13's behavior) and is reset there so a stale flavor can't leak across attempts.
    private var vaultOnboardingFlavor: VaultOnboardingFlavor = .onboarding
    private var bossWatchBaselineState: WorkspaceState?
    private var bossWatchTickIsRunning = false
    /// FIX4 — the periodic Boss Watch poll loop's lifetime is now owned by the
    /// enable toggle, not an unconditional `.task`. It runs ONLY while Watch is on:
    /// `setBossWatchEnabled(true)` (and `startBossWatchLoopIfEnabled` at launch when
    /// Watch was persisted on) start it; `setBossWatchEnabled(false)` cancels it. So
    /// the loop no longer wakes every 60s just to `continue` while Watch is OFF.
    private var bossWatchLoopTask: Task<Void, Never>?
    private var bossWatchLastPromptAt: Date?
    /// When a session newly needs attention, the boss responds right then
    /// (event-driven) instead of waiting up to a full poll interval. This caps
    /// how often a burst of such events can kick a check-in.
    private var lastEventDrivenCheckInAt: Date?
    private let eventDrivenCheckInCooldown: TimeInterval = 15
    private var didAttemptStartupRecovery = false
    private var didAttemptAutoResumeLaunch = false
    /// F11a Defect 2 — entries with a `start(_:with:)` currently in flight. Now
    /// that `start` is `async` (it may `await` a `screen` quit before the
    /// `-D -RR` relaunch), a second start for the SAME entry could run on the
    /// main actor during the first's await suspension — both would read the same
    /// old `activeSessions[id]`, race two `-D -RR` on one socket, and leak the
    /// first session when the second overwrites it. This in-flight set makes
    /// `start` re-entrancy-safe per entry: a second concurrent start for an entry
    /// already starting is dropped. (The synchronous pre-F11a `start` couldn't
    /// interleave; the await reopened the window.)
    private var startingEntryIDs = Set<UUID>()
    /// F11a — whether the most recent `load()` succeeded (read a real workspace,
    /// not the empty bootstrap a failed/quarantined load falls back to). The
    /// startup orphan-screen reaper GATES on this: a failed load looks identical
    /// to "no entries" (`state.processEntries` is empty either way), and an empty
    /// `knownEntryIds` would make the reaper quit EVERY live `screen` — including
    /// reattachable survivors (F8-class "kill the wrong thing"). `false` until a
    /// load actually restores state.
    private var stateLoadSucceeded = false
    /// Last time we posted an unexpected-exit notification per entry, to
    /// throttle banner spam when a session crash-loops or several are
    /// recovered at once.
    private var lastExitNotificationByEntry: [UUID: Date] = [:]
    private let exitNotificationThrottle: TimeInterval = 30
    /// Retained `willTerminate` observer token so `deinit` can remove it.
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can read it; access
    /// is serialized (written once in init on the main actor, read once in
    /// deinit), so there's no real race.
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    /// Coalesced "last output at" timestamps awaiting a flush to `state`.
    /// Terminal output arrives hundreds of times per second from a busy TUI;
    /// applying each one to `@Published state` (and saving) per chunk thrashed
    /// the UI and the disk. We instead stash the latest timestamp per run here
    /// and flush them in a single batch on a short debounce. Keyed by runId.
    private var pendingOutputTimestamps: [UUID: Date] = [:]
    private var outputFlushTask: Task<Void, Never>?
    /// How long to coalesce output timestamps before flushing to disk. Human
    /// glance-grade freshness; recovery freshness checks tolerate this.
    private let outputFlushIntervalNanoseconds: UInt64 = 2_000_000_000
    private let bossWatchIntervalNanoseconds: UInt64 = 60_000_000_000

    public init(
        paths: WorkbenchPaths = .defaultPaths(),
        mailboxClient: MailboxClient = MailboxClient(),
        bossMCPClient: BossAgentMCPClient = BossAgentMCPClient(),
        daemonManager: DaemonManager = DaemonManager(),
        bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar = BossWorkbenchMCPRegistrar(),
        ouroAgentInventory: OuroAgentInventory = OuroAgentInventory(),
        executableHealthChecker: ExecutableHealthChecker = ExecutableHealthChecker(),
        releaseUpdateChecker: ReleaseUpdateChecker = ReleaseUpdateChecker(),
        workCardReader: OuroWorkCardReader = OuroWorkCardReader(),
        autoLaunchResumableForE2E: Bool = false
    ) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.mailboxClient = mailboxClient
        self.bossMCPClient = bossMCPClient
        self.daemonManager = daemonManager
        self.bossWorkbenchMCPRegistrar = bossWorkbenchMCPRegistrar
        // RUNTIME-INJECTION model: every boss turn Workbench spawns passes `--workbench-mcp
        // <path>` so the `ouro` runtime injects the Workbench MCP into the boss's turn per-turn
        // (boss-aware) — nothing is written to the synced agent bundle. Resolve the installed
        // Workbench MCP binary once and configure the client to pass it; when the binary can't be
        // resolved we pass the flag path-less so the `ouro` side self-discovers it.
        bossMCPClient.workbenchMCPPath = Self.runtimeWorkbenchMCPPath(
            executableURL: bossWorkbenchMCPRegistrar.mcpExecutableURL
        )
        self.ouroAgentInventory = ouroAgentInventory
        self.executableHealthChecker = executableHealthChecker
        self.releaseUpdateChecker = releaseUpdateChecker
        self.workCardReader = workCardReader
        self.externalActionQueue = WorkbenchActionRequestQueue(paths: paths)
        self.proposalQueue = AgentProposalQueue(paths: paths)
        self.state = WorkspaceState()
        self.isFirstRunSetupForcedOnLaunch = WorkbenchFactoryReset.consumeFirstRunSetupRequest(rootURL: paths.rootURL)
        if autoLaunchResumableForE2E {
            self.autoLaunchResumableOnStartup = true
        }
        // Seed the palette's static override from the persisted setting so
        // every terminal view that asks for a theme honors the user's pin
        // even before any view model property gets re-read.
        WorkbenchTerminalPalette.currentOverride = self.terminalThemeOverride
        load()
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        // Migrate EVERY local agent bundle off any stale `ouro_workbench` / `senses.workbench`
        // entry (runtime injection means nothing belongs in a synced bundle). Independent of boss
        // selection so a stale entry on any non-boss agent is cleaned too.
        sweepStaleWorkbenchBundlesOnLaunch()
        refreshExecutableHealth()
        refreshGitStatus()
        refreshSessionActivity()
        refreshOnboardingReadiness()
        registerTerminationObserver()
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        outputFlushTask?.cancel()
    }

    /// Observe app termination so we can record running sessions as cleanly
    /// detached before we go. `queue: .main` runs the block on the main
    /// thread, so hopping to the main actor is safe. The token is retained so
    /// `deinit` can remove it — otherwise each view-model instance (tests,
    /// previews) would leave a permanent observer that keeps firing.
    private func registerTerminationObserver() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForTermination()
            }
        }
    }

    /// Called on app quit. `screen` keeps each persistent session alive after
    /// our client process dies, so the sessions are genuinely reattachable.
    /// Mark every still-running persistent session as cleanly detached now —
    /// otherwise its run stays `.running` in persisted state and the startup
    /// reconciler flips it into an alarming "needs startup recovery" on the
    /// next launch, even though one relaunch would reattach it. Reuses the
    /// same detach framing as the live detach path.
    func prepareForTermination() {
        // During a first-run reset the state file is intentionally gone; don't
        // resurrect it on the way out.
        guard !isResettingToFirstRun else {
            return
        }
        flushPendingOutput()
        for (entryId, session) in activeSessions {
            guard let persistentName = session.plan.persistentSessionName,
                  !persistentName.isEmpty,
                  let runIndex = state.processRuns.firstIndex(where: {
                      $0.id == session.plan.runId && $0.status == .running
                  })
            else {
                continue
            }
            state.processRuns[runIndex].status = .needsRecovery
            state.processRuns[runIndex].pid = nil
            state.processRuns[runIndex].endedAt = nil
            state.processRuns[runIndex].exitCode = nil
            state.processRuns[runIndex].rawExitStatus = nil
            updateEntry(entryId) { entry in
                // U8a: a session we cleanly detached on quit is an expected
                // survivor — it reattaches next launch. Leave it CALM (.idle),
                // never an orange "needs boss review"; the startup reconciler
                // confirms survival via `screen -ls` and sets the final
                // "reconnected" copy.
                entry.attention = .idle
                entry.lastSummary = "\(entry.name) detached on quit; reattaches on next launch"
            }
        }
        save()
        // Quiet "install on quit": if a verified update was staged in the
        // background, swap it in now that we're exiting (no reopen).
        applyStagedUpdateOnQuitIfNeeded()
    }

    /// Reset this machine's Workbench to factory defaults and relaunch into a
    /// pristine first-run (onboarding auto-presents). For iterating on the
    /// first-run experience.
    ///
    /// Scope is deliberately *Workbench's own data only*:
    ///   - Running terminals are stopped cleanly (no invisible orphans left
    ///     burning tokens), and their persistent `screen` sessions are quit.
    ///   - The workspace state file is backed up to a timestamped sibling, then
    ///     removed, and *all* Workbench preferences are cleared.
    ///
    /// What is **not** touched: each agent's own session history — the Claude /
    /// Codex / cmux conversation + resume state — lives with that harness's
    /// storage, never inside Workbench. Stopping a terminal kills the process
    /// but not its history, so you relaunch and resume after the reset.
    func resetToFirstRun() {
        // Suppress all persistence for the rest of this process's life so the
        // wipe below isn't undone by a save (notably prepareForTermination on
        // the NSApp.terminate path).
        isResettingToFirstRun = true
        // 1) Stop live agent terminals + their persistent screen sessions so a
        //    fresh launch starts clean and nothing is left running unattended.
        //    Non-destructive to the agents' histories (those live with their
        //    harness); the process can be relaunched and resumed afterward.
        for entry in state.processEntries where activeSessions[entry.id] != nil {
            terminate(entry)
        }
        Self.killAllPersistentScreens()

        // 2) Back up + remove the workspace state (so the next launch bootstraps
        //    fresh — the bootstrapper treats a missing file as first run) and
        //    clear *all* Workbench preferences for a true factory state, not a
        //    half-reset. This data wipe is unit-tested via `WorkbenchFactoryReset`.
        WorkbenchFactoryReset.resetToFactoryDefaults(
            stateURL: paths.stateURL,
            defaults: .standard,
            defaultsDomain: WorkbenchRelease.bundleIdentifier,
            timestamp: Date()
        )
        UserDefaults.standard.synchronize()

        // 3) Relaunch a fresh instance once this one exits, then quit.
        Self.relaunchAfterExit()
        NSApp.terminate(nil)
    }

    /// Quit every live `ouro-wb-*` persistent screen session (best-effort,
    /// off the reset path's critical correctness — orphans just waste nothing).
    nonisolated private static func killAllPersistentScreens() {
        for name in listLiveScreenSessionNames() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: PersistentTerminalSession.executable)
            process.arguments = PersistentTerminalSession.terminateArguments(sessionName: name)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Spawn a detached shell that waits for this process to exit, then reopens
    /// the app bundle — a clean relaunch with no overlapping instance.
    nonisolated private static func relaunchAfterExit() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(shellQuoted(bundlePath))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var errorIsPresented: Binding<Bool> {
        Binding(
            get: { self.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    self.errorMessage = nil
                }
            }
        )
    }

    var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { self.pendingDeleteSession != nil },
            set: { newValue in
                if !newValue {
                    self.pendingDeleteSession = nil
                }
            }
        )
    }

    var stopConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { self.pendingStopSession != nil },
            set: { newValue in
                if !newValue {
                    self.pendingStopSession = nil
                }
            }
        )
    }

    /// Title for the U11 Stop confirmation, naming the pending session. A plain
    /// `String` so the view's modifier chain stays cheap to type-check.
    var stopConfirmationTitle: String {
        guard let entry = pendingStopSession else { return "Stop?" }
        return WorkbenchSurfacePolicy.stopConfirmationTitle(name: entry.name)
    }

    var deleteGroupConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { self.pendingDeleteGroup != nil },
            set: { newValue in
                if !newValue {
                    self.pendingDeleteGroup = nil
                }
            }
        )
    }

    var sessionEntries: [ProcessEntry] {
        let visible = applySidebarFilter(projectSessionEntries.filter { !$0.isArchived }, archived: false)
        // Pinned entries float to the top, preserving stored order within
        // each partition (stable). Concatenation keeps the partition stable
        // where `sorted(by:)` would not, and keeps ID-based reorder coherent.
        return visible.filter(\.isPinned) + visible.filter { !$0.isPinned }
    }

    /// U19(a): whether the active sidebar filter is a structured `owner:`/`status:`
    /// query, which searches GLOBALLY (across all workspaces) rather than only the
    /// selected workspace. Drives both the scope-of-search and the scope indicator
    /// shown under the field, so scoping is never silent.
    var sidebarFilterIsGlobal: Bool {
        SidebarSessionFilter().isStructuredQuery(sidebarFilter)
    }

    /// U19(b): whether the operator has typed a filter at all (non-blank). Distinguishes
    /// a zero-match filtered result ("No sessions match …") from a genuinely empty
    /// workspace ("No terminals yet").
    var sidebarFilterIsActive: Bool {
        !sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Narrow the session list to the rows matching `sidebarFilter`. An empty filter is
    /// a no-op (returns the input unchanged), so the sidebar's pinned / archived /
    /// reorder behavior is untouched until the operator types. The match is delegated to
    /// the pure `SidebarSessionFilter` helper (tested in Core).
    ///
    /// U19(a): a *structured* `owner:`/`status:` query searches across ALL workspaces, so
    /// a blocked session in an unselected workspace is visible and an empty result truly
    /// means "nothing matches anywhere." A plain free-text query stays scoped to the
    /// passed-in (current-workspace) list as before. In the global case each entry's
    /// group name comes from `groupName(for:)` (its own workspace) rather than the
    /// selected project, so cross-workspace name/group matching stays correct.
    private func applySidebarFilter(_ entries: [ProcessEntry], archived: Bool) -> [ProcessEntry] {
        let query = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return entries
        }
        let filter = SidebarSessionFilter()
        guard filter.isStructuredQuery(query) else {
            let groupName = selectedProject?.name ?? ""
            return entries.filter { filter.matches($0, groupName: groupName, query: query) }
        }
        // Global structured search: scan every workspace's sessions (honoring the
        // caller's archived/non-archived split), each matched against its OWN workspace's
        // group name so cross-workspace name/group matching stays correct.
        return allSessionEntries
            .filter { $0.isArchived == archived }
            .filter { filter.matches($0, groupName: groupName(for: $0) ?? "", query: query) }
    }

    /// SwiftUI `.onMove` handler for the sidebar's non-archived rows. The
    /// `offsets` and `destination` are indices into `sessionEntries`
    /// (the filtered, project-scoped, non-archived view). We delegate the
    /// actual index gymnastics to `WorkbenchEntryReorder` so the algorithm
    /// is testable in isolation; this method just plumbs in the view and
    /// persists the result.
    func moveSessionEntries(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        // Reordering against a filtered view would move rows relative only to
        // their visible neighbors, scrambling the global order in surprising
        // ways. Drag-to-reorder is only meaningful over the full list, so it's
        // a no-op while a sidebar filter is active.
        guard sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        state.processEntries = WorkbenchEntryReorder.move(
            global: state.processEntries,
            visible: sessionEntries,
            fromOffsets: offsets,
            toOffset: destination
        )
        do { try store.save(state) } catch { errorMessage = String(describing: error) }
    }

    /// SwiftUI `.onMove` handler for the Groups section. The Groups section
    /// renders every project in `state.projects`, so the visible/global
    /// distinction collapses; we still go through the helper so the move
    /// algorithm has one canonical implementation.
    func moveGroups(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        state.projects = WorkbenchEntryReorder.move(
            global: state.projects,
            visible: state.projects,
            fromOffsets: offsets,
            toOffset: destination
        )
        do { try store.save(state) } catch { errorMessage = String(describing: error) }
    }

    /// Assign (or clear, when `tag` is nil) a color tag on a group and
    /// persist. The sidebar row tints its folder icon to match.
    func setGroupColorTag(_ tag: String?, for project: WorkbenchProject) {
        guard let index = state.projects.firstIndex(where: { $0.id == project.id }) else {
            return
        }
        state.projects[index].colorTag = tag
        do { try store.save(state) } catch { errorMessage = String(describing: error) }
    }

    /// Toggle the pinned state of a session. Pinned sessions float to the
    /// top of their group in the sidebar (see `sessionEntries`). Persisted.
    func togglePin(for entry: ProcessEntry) {
        guard let index = state.processEntries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        state.processEntries[index].isPinned.toggle()
        do { try store.save(state) } catch { errorMessage = String(describing: error) }
    }

    /// Whether the entry is currently pinned. Convenience for the sidebar
    /// row + context menu, which hold a possibly-stale copy of the entry.
    func isPinned(_ entry: ProcessEntry) -> Bool {
        state.processEntries.first(where: { $0.id == entry.id })?.isPinned ?? entry.isPinned
    }

    // MARK: - Slice ②d — in-app editing wrappers (thin; mutate state then save — D2d-7)

    /// ②d — toggle the workspace's pin (re-sorts pinned-first automatically through the
    /// pure `WorkspaceSidebarPresentation` seam; D2d-4). Persists via `save()`.
    public func toggleWorkspacePin(_ id: UUID) {
        state.toggleWorkspacePin(workspaceId: id)
        save()
    }

    /// ②d — apply an inline-rename input to the workspace. Routes the raw input through
    /// `WorkspaceRenameCommit` (D2d-1: empty/whitespace or unchanged ⇒ no-op, no override
    /// write / no save); a real change sets the trimmed override and persists.
    public func renameWorkspace(_ id: UUID, to input: String) {
        let current = state.workspaces.first(where: { $0.id == id })?.effectiveName ?? ""
        switch WorkspaceRenameCommit.resolve(input: input, current: current) {
        case let .commit(name):
            state.setWorkspaceNameOverride(workspaceId: id, to: name)
            save()
        case .noop:
            break
        }
    }

    /// ②d — clear the workspace's custom name (revert to `autoName`; D2d-2's affordance).
    /// Persists via `save()`.
    public func removeCustomWorkspaceName(_ id: UUID) {
        state.clearWorkspaceNameOverride(workspaceId: id)
        save()
    }

    /// ②d — apply an inline-rename input to a TAB. Same rule as `renameWorkspace`
    /// (D2d-1 via `WorkspaceRenameCommit`): empty/whitespace or unchanged ⇒ no-op; a real
    /// change sets the trimmed `tabNameOverride` and persists. No tab-level revert
    /// affordance this slice (the cmux tab menu only has Rename Tab).
    public func renameTab(_ id: UUID, to input: String) {
        let current = state.processEntries.first(where: { $0.id == id })?.effectiveTabName ?? ""
        switch WorkspaceRenameCommit.resolve(input: input, current: current) {
        case let .commit(name):
            state.setTabNameOverride(tabId: id, to: name)
            save()
        case .noop:
            break
        }
    }

    /// ②d — begin the inline rename for `target`, prefilled with its current name. Used
    /// by the context-menu items and the rename chords (D2d-8).
    public func beginRename(_ target: InlineRenameState.Target, prefill: String) {
        inlineRename.begin(target: target, prefill: prefill)
    }

    /// ②d — ⇧⌘R chord: begin renaming the ACTIVE workspace (no-op when there is none).
    func beginRenameActiveWorkspace() {
        guard let row = activeWorkspaceRow else {
            return
        }
        beginRename(.workspace(row.id), prefill: row.effectiveName)
    }

    /// ②d — ⌘R chord: begin renaming the SELECTED tab (no-op when none is selected or it
    /// resolves to no entry). Prefills with the tab's `effectiveTabName`.
    func beginRenameSelectedTab() {
        guard let id = selectedEntryID,
              let entry = state.processEntries.first(where: { $0.id == id }) else {
            return
        }
        beginRename(.tab(id), prefill: entry.effectiveTabName)
    }

    /// ②d — Enter in the inline editor: pull the pending commit from `InlineRenameState`
    /// (which goes inactive) and dispatch to the per-target wrapper. Each wrapper routes
    /// the raw draft through `WorkspaceRenameCommit` (D2d-1), so an empty/whitespace or
    /// unchanged draft is a no-op (the editor still closes via the `commit()` above).
    public func commitRename() {
        guard let pending = inlineRename.commit() else {
            return
        }
        switch pending.target {
        case let .workspace(id):
            renameWorkspace(id, to: pending.input)
        case let .tab(id):
            renameTab(id, to: pending.input)
        }
    }

    /// ②d — Escape in the inline editor: close it without committing (draft discarded).
    public func cancelRename() {
        inlineRename.cancel()
    }

    /// Slice ②b (DB10, supersedes DB7) — the Archived section is GLOBAL, not scoped to
    /// the active workspace. The independent review BLOCKED merge on a CRITICAL: the
    /// real `migrateToWorkspaceStructure()` folds ONLY non-archived entries into the
    /// "Restored workspace", so archived entries are in NO workspace's `tabIds`; the
    /// previous per-active-workspace scoping (`activeWorkspaceRow?.archivedTabs`) was
    /// therefore ALWAYS empty after upgrade ⇒ the Archived section vanished and the
    /// row's `Restore` menu (the only un-archive UI) vanished with it ⇒ archived
    /// terminals were orphaned. This now reads ALL archived terminal/shell sessions
    /// globally (the pure seam `resolveGlobalArchived`), decoupled from `tabIds`
    /// membership, so no archived terminal is ever invisible/un-restorable. The
    /// sidebar filter still applies so structured/free-text queries narrow the list.
    public var archivedSessionEntries: [ProcessEntry] {
        let archivedIds = Set(
            WorkspaceSidebarPresentation.resolveGlobalArchived(entries: workspaceTabEntries).map(\.id)
        )
        let archived = allSessionEntries.filter { archivedIds.contains($0.id) }
        return applySidebarFilter(archived, archived: true)
    }

    private var allSessionEntries: [ProcessEntry] {
        state.processEntries.filter { $0.kind == .terminalAgent || $0.kind == .shell }
    }

    /// DB9 (Slice ②b) — the entry set the `WorkspaceSidebarPresentation` seam resolves
    /// a workspace's `tabIds` against. `allSessionEntries` is `private` and the sidebar
    /// lives in a separate struct (`WorkbenchSidebarView`), so this non-private accessor
    /// exposes exactly the entries the seam needs (terminal + shell sessions) without
    /// widening any other view-model internals. The seam stays pure — it takes the
    /// entries as a parameter.
    public var workspaceTabEntries: [ProcessEntry] { allSessionEntries }

    /// Slice ②b — the ordered, resolved sidebar/tab-strip view-model derived from the
    /// persisted `state.workspaces` via the pure `WorkspaceSidebarPresentation` seam.
    /// The sidebar rows AND the cmux tab-strip both read THIS, so they can never
    /// disagree about ordering / active workspace / which tabs belong where.
    public var workspaceSidebarModel: WorkspaceSidebarModel {
        WorkspaceSidebarPresentation.resolve(
            workspaces: state.workspaces,
            entries: workspaceTabEntries,
            selectedWorkspaceId: selectedWorkspaceID
        )
    }

    /// The currently-active workspace row (the one whose tabs render in the top strip),
    /// per the seam's active-workspace rule (DB2). `nil` only when there are no
    /// workspaces (empty machine before any session exists).
    public var activeWorkspaceRow: WorkspaceRow? {
        workspaceSidebarModel.rows.first { $0.isActive }
    }

    /// Make the workspace that owns `entryID` the active one (DB2 selection on click):
    /// clicking a tab selects its entry AND surfaces its workspace in the strip. A no-op
    /// for an entry not in any workspace (it stays under whatever workspace is active).
    func selectWorkspaceContaining(entryID: UUID) {
        guard let owning = state.workspaces.first(where: { $0.tabIds.contains(entryID) }) else {
            return
        }
        if selectedWorkspaceID != owning.id {
            selectedWorkspaceID = owning.id
        }
    }

    /// A workspace's active tab paired with its backing `ProcessEntry`, for the
    /// sidebar/tab-strip render. Identifiable by entry id so SwiftUI `ForEach` is stable.
    struct WorkspaceTabRow: Identifiable {
        let resolved: ResolvedTab
        let entry: ProcessEntry
        var id: UUID { resolved.id }
    }

    /// Resolve a workspace row's ACTIVE tabs (the seam already dropped dangling ids and
    /// the archived partition) back to their `ProcessEntry`s, honoring the sidebar
    /// filter. The seam keeps tab order; the filter narrows by name/owner/status.
    func workspaceTabRows(for row: WorkspaceRow) -> [WorkspaceTabRow] {
        let byId = Dictionary(workspaceTabEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = row.tabs.compactMap { tab -> WorkspaceTabRow? in
            guard let entry = byId[tab.id] else { return nil }
            return WorkspaceTabRow(resolved: tab, entry: entry)
        }
        let query = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return resolved
        }
        let filter = SidebarSessionFilter()
        return resolved.filter {
            filter.matches($0.entry, groupName: row.effectiveName, query: query)
        }
    }

    private var projectSessionEntries: [ProcessEntry] {
        guard let selectedProjectID else {
            return allSessionEntries
        }
        return allSessionEntries.filter { $0.projectId == selectedProjectID }
    }

    var selectedProject: WorkbenchProject? {
        guard let selectedProjectID else {
            return state.projects.first
        }
        return state.projects.first { $0.id == selectedProjectID } ?? state.projects.first
    }

    func terminalCount(in project: WorkbenchProject) -> Int {
        allSessionEntries.filter { $0.projectId == project.id && !$0.isArchived }.count
    }

    func totalTerminalCount(in project: WorkbenchProject) -> Int {
        allSessionEntries.filter { $0.projectId == project.id }.count
    }

    func groupName(for entry: ProcessEntry) -> String? {
        state.projects.first { $0.id == entry.projectId }?.name
    }

    func groupName(forEntryId entryId: UUID) -> String? {
        guard let entry = state.processEntries.first(where: { $0.id == entryId }) else {
            return nil
        }
        return groupName(for: entry)
    }

    func groupName(for match: TranscriptSearchMatch) -> String? {
        groupName(forEntryId: match.entryId)
    }

    var selectedEntry: ProcessEntry? {
        guard let selectedEntryID else {
            return sessionEntries.first ?? archivedSessionEntries.first
        }
        return projectSessionEntries.first { $0.id == selectedEntryID }
            ?? sessionEntries.first
            ?? archivedSessionEntries.first
    }

    var terminalFocusEntry: ProcessEntry? {
        guard let terminalFocusEntryID,
              activeSessions[terminalFocusEntryID] != nil else {
            return nil
        }
        return allSessionEntries.first { $0.id == terminalFocusEntryID }
    }

    /// The entry shown in the secondary detail pane while a split is active,
    /// or `nil` when there's no split or the secondary pane is an unassigned
    /// picker / its session no longer resolves to a known entry.
    var secondaryPaneEntry: ProcessEntry? {
        guard let id = detailSplit?.secondaryEntryID else { return nil }
        return allSessionEntries.first { $0.id == id }
    }

    /// The entry that "selected-session" commands (Stop, Redraw, Find) act on.
    ///
    /// FIX 1 (HIGH, destructive): full-screen FOCUS MODE authoritatively defines the
    /// active terminal. macOS menu key-equivalents (⌘. Stop, ⌘L Redraw, ⌘F Find) win
    /// over the focus view's inline buttons, so whatever this returns is what ⌘.
    /// KILLS — it MUST be the terminal on screen. Entering focus mode (a row's Focus
    /// button or `jumpToAttentionPrompt`) used to set only `terminalFocusEntryID`,
    /// leaving this reading the sidebar selection / secondary pane — so ⌘. could stop
    /// a DIFFERENT agent than the one the operator was watching. A live focus session
    /// now wins over both. When focus mode is OFF the pre-fix priority is unchanged:
    /// a focused secondary pane, else the sidebar selection (single-pane untouched).
    ///
    /// The priority order lives in the pure `ActiveEntryResolver` seam so it's
    /// exhaustively unit-tested; this only feeds it the model's resolved inputs and
    /// maps the chosen id back to its entry.
    var activeEntry: ProcessEntry? {
        let resolvedID = ActiveEntryResolver.resolve(
            selectedEntryID: selectedEntry?.id,
            terminalFocusEntryID: terminalFocusEntryID,
            focusEntryResolves: terminalFocusEntry != nil,
            splitIsActive: detailSplit != nil,
            secondaryPaneIsFocused: activePaneID == .secondary,
            secondaryPaneEntryID: secondaryPaneEntry?.id
        )
        guard let resolvedID else { return nil }
        // The resolver returns exactly one of the three already-resolved entries'
        // ids (focus / secondary / sidebar); return whichever it picked. Falls back
        // to a roster lookup so the result is never a stale id.
        if let focus = terminalFocusEntry, focus.id == resolvedID { return focus }
        if let secondary = secondaryPaneEntry, secondary.id == resolvedID { return secondary }
        if let selected = selectedEntry, selected.id == resolvedID { return selected }
        return allSessionEntries.first { $0.id == resolvedID }
    }

    var summary: WorkspaceSummary {
        summarizer.summarize(state, liveSessionNames: liveScreenSessionNames)
    }

    var mailboxStatusLine: String {
        mailboxError ?? "Mailbox status unavailable"
    }

    var bossMCPCommand: String {
        bossBridgePlanner.mcpServePlan(
            for: state.boss,
            workbenchMCPPath: Self.runtimeWorkbenchMCPPath(
                executableURL: bossWorkbenchMCPRegistrar.mcpExecutableURL
            )
        ).displayCommand
    }

    /// The `--workbench-mcp` value for RUNTIME INJECTION. When the installed Workbench MCP binary
    /// exists on disk we pass its explicit path (preferred). When it can't be resolved we pass the
    /// flag path-less (empty string) so the `ouro` side self-discovers the binary. Never returns
    /// `nil` — Workbench always opts into runtime injection so the boss gets the tools per-turn.
    static func runtimeWorkbenchMCPPath(executableURL: URL) -> String {
        FileManager.default.isExecutableFile(atPath: executableURL.path) ? executableURL.path : ""
    }

    var autonomyReadiness: AutonomyReadinessSnapshot {
        autonomyReadinessBuilder.build(
            state: state,
            summary: summary,
            mcpRegistration: bossWorkbenchMCPRegistration,
            executableHealth: executableHealthByEntryID,
            bossWatchIsEnabled: bossWatchIsEnabled
        )
    }

    /// Read-only, consolidated harness status for the Harness Status sheet.
    /// Purely aggregates the snapshots the model already publishes — the boss
    /// dashboard (daemon health, observed-at), the local agent inventory, and
    /// the per-agent MCP-registration map — so it stays live as those refresh.
    /// No IO here; `refreshHarnessStatus()` drives the underlying reads.
    var harnessStatus: HarnessStatus {
        harnessStatusBuilder.build(
            boss: state.boss,
            dashboard: bossDashboard,
            agents: ouroAgents,
            bossRegistration: bossWorkbenchMCPRegistration,
            registrationByAgentName: bossWorkbenchMCPRegistrationByAgentName,
            // Thread the live `tools/list` injection verdicts so the harness MCP pill
            // reads GREEN only on a confirmed-present probe — the SAME verdict map the
            // steady-state agent rows fold in. A missing key = not-probed = unverified
            // (neutral), never a config-only false green. PRESENTATION only: the
            // reachability/rollup axes deliberately ignore this map.
            injectionByAgentName: bossWorkbenchToolsInjectionByAgentName,
            // Reuse the SAME live outward-lane verdicts / in-flight set the
            // steady-state rows compute (`refreshAgentOutwardReadiness`, kicked
            // off by `refreshOuroAgents` → driven by `refreshHarnessStatus`) so
            // the diagnostic sheet's pills + rollups are honest — never a
            // config-only false green. No extra `ouro check` here.
            outwardVerdicts: agentOutwardVerdicts,
            checksInFlight: agentChecksInFlight
        )
    }

    /// Refresh every read the Harness Status sheet consolidates, reusing the
    /// existing refresh paths: the on-disk agent scan + MCP-registration check
    /// (synchronous), then the watchdog-bounded daemon/mailbox read. Bounded by
    /// `MailboxClient`'s per-request timeout so a down daemon can't hang the UI.
    func refreshHarnessStatus() async {
        refreshOuroAgents()
        await refreshBossDashboard()
    }

    var recentActionLogEntries: [WorkbenchActionLogEntry] {
        state.actionLog.sorted { $0.occurredAt > $1.occurredAt }
    }

    /// U31(b): the in-window header's one-line status, gated so a genuinely quiet
    /// machine ("0 running, nothing to recover") renders nothing — the boss prompt
    /// builder still reads the raw `summary.oneLineStatus`.
    var headerStatusLine: HeaderStatusLinePresentation {
        HeaderStatusLinePresentation.resolve(summary: summary)
    }

    /// The always-visible read of Boss Watch (#U21) — the on/off label, the
    /// bidirectional toggle title, and the help string the header pill, the
    /// popover, and the dashboard all share.
    var bossWatchPresentation: BossWatchPresentation {
        // #U31a: the header pill hides entirely when there's no usable boss —
        // Boss Watch watches *via* a boss, so a green "Watch On" before one exists
        // is incoherent and breaks the calm no-boss header (U5). The popover and
        // dashboard controls only render with a boss set, so they read `help` /
        // `toggleActionTitle` off this same presentation and are unaffected.
        BossWatchPresentation.resolve(
            isEnabled: bossWatchIsEnabled,
            hasUsableBoss: currentBossIsUsable
        )
    }

    /// Compact summary of the boss's recent action receipts (#U21) over the most
    /// recent window, so the default boss pane reads "Recent actions: 3 ok · 1
    /// failed" and surfaces failed autonomous actions without opening Advanced.
    var bossActionReceiptSummary: BossActionReceiptSummary {
        BossActionReceiptSummary.summarize(state.actionLog, window: Self.actionReceiptWindow)
    }

    /// How many recent receipts the compact summary counts — small enough to
    /// stay glanceable, large enough to catch a recent failure.
    static let actionReceiptWindow = 10

    /// The open-inbox "door" (#U22): the tappable "N waiting on you" affordance,
    /// or `nil` when nothing is open (so the boss pane renders no dead button).
    /// Drives the boss-pane pill, the tappable "inbox" chip, and the collapsed-
    /// pane count badge — all from one pure derivation.
    var inboxDoor: InboxDoorPresentation? {
        InboxDoorPresentation.resolve(state: state)
    }

    /// Open the Decision Inbox sheet (#U22) — the click target for the boss-pane
    /// "N waiting" pill and the "inbox" chip, the same sheet ⌘K / ⌘J open.
    func presentDecisionInbox() {
        isDecisionLogPresented = true
    }

    var bossWatchStatusLine: String {
        if let bossWatchLastError {
            return "error: \(bossWatchLastError)"
        }
        guard bossWatchIsEnabled else {
            return "paused"
        }
        guard let bossWatchLastRunAt else {
            return "watching"
        }
        return "watching; last \(bossWatchLastRunAt.formatted(date: .omitted, time: .standard))"
    }

    var bossWatchStatusColor: SwiftUI.Color {
        if bossWatchLastError != nil {
            return .orange
        }
        return bossWatchIsEnabled ? .green : .secondary
    }

    var transcriptSearchStatusLine: String {
        let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Enter a query to search saved transcripts."
        }
        guard transcriptSearchLastQuery == query else {
            return "Press Search to search saved transcripts."
        }
        return "No transcript matches for \(query)."
    }

    var recoveryDrillStatusLine: String {
        guard let recoveryDrillResult else {
            return "not run"
        }
        return "\(recoveryDrillResult.oneLineStatus); \(recoveryDrillResult.ranAt.formatted(date: .omitted, time: .standard))"
    }

    var releaseUpdateStatusLine: String {
        // While a check / install is genuinely in flight, say so — never leave a
        // stale "is current" line showing next to the spinner (which reads as a
        // stuck, perpetual load).
        if releaseUpdateIsChecking {
            return "Checking for updates…"
        }
        if releaseUpdateIsInstalling {
            return "Installing update…"
        }
        guard let snapshot = releaseUpdateSnapshot else {
            return "not checked"
        }
        return snapshot.detail
    }

    var releaseUpdateStatusColor: SwiftUI.Color {
        guard let status = releaseUpdateSnapshot?.status else {
            return .secondary
        }
        switch status {
        case .current:
            return .green
        case .updateAvailable:
            return .orange
        case .unavailable:
            return .secondary
        }
    }

    var releaseUpdateURL: URL? {
        appShellUpdatePresentation.releaseURL
    }

    public var appShellUpdateState: ReleaseUpdateViewState {
        appShellUpdatePresentation.state
    }

    var appShellUpdateActions: ReleaseUpdateActions {
        ReleaseUpdateActions(
            checkForUpdates: { Task { await self.checkForUpdatesAndPromptInstall() } },
            reviewUpdate: { self.presentUpdatePrompt() },
            installAndRelaunch: { Task { await self.installReleaseUpdate() } },
            openReleasePage: { self.openReleaseUpdate() }
        )
    }

    private var appShellUpdatePresentation: WorkbenchShellUpdatePresentation {
        WorkbenchShellUpdatePresenter.presentation(
            snapshot: releaseUpdateSnapshot,
            isChecking: releaseUpdateIsChecking,
            isInstalling: releaseUpdateIsInstalling,
            installStatus: releaseUpdateInstallStatus,
            installError: releaseUpdateInstallError,
            stagedUpdateVersion: stagedUpdateVersion
        )
    }

    var supportDiagnosticsStatusLine: String {
        if supportDiagnosticsIsCollecting {
            return "collecting"
        }
        if let supportDiagnosticsError {
            return "failed: \(supportDiagnosticsError)"
        }
        guard let supportDiagnosticsResult else {
            return "not run"
        }
        return "wrote \(supportDiagnosticsResult.archiveURL.lastPathComponent)"
    }

    var supportDiagnosticsStatusColor: SwiftUI.Color {
        if supportDiagnosticsError != nil {
            return .orange
        }
        return supportDiagnosticsResult == nil ? .secondary : .green
    }

    var supportDiagnosticsURL: URL? {
        supportDiagnosticsResult?.archiveURL
    }

    /// Genuine *configuration* gaps (no ready boss, an unconfigured provider
    /// lane, or unregistered Workbench MCP) that warrant the full onboarding
    /// sheet. Provider *liveness* state (`check-*` / `repair-*-provider`) is
    /// deliberately excluded — it's surfaced in the boss pane, so a configured
    /// machine whose live check merely hasn't run (or transiently failed)
    /// doesn't get the onboarding sheet thrown at it on every launch.
    private static let onboardingConfigGapBlockerIDs: Set<String> = [
        "repair-agent-config", "outward-lane", "inner-lane", "workbench-mcp"
    ]

    /// True when readiness is blocked by an actual configuration gap (above),
    /// as opposed to a provider liveness check that simply hasn't run yet.
    var onboardingHasConfigGap: Bool {
        guard let readiness = onboardingReadiness else {
            return false
        }
        return readiness.repairSteps.contains { Self.onboardingConfigGapBlockerIDs.contains($0.id) }
    }

    /// Whether the boss-setup wizard auto-presents on launch. Always `false` now:
    /// the subtractive FRE redesign tore out the forced wizard so first-run lands
    /// on the working terminals-first app, and the wizard is opt-in via
    /// `presentOnboarding()`. The decision lives in the pure Core
    /// `OnboardingPresentationPolicy.shouldAutoPresentOnLaunch` so it's unit-tested
    /// for both first-run cases (fresh and `force-first-run-setup`). The marker
    /// still resets state to a clean first run (`isFirstRunSetupForcedOnLaunch`
    /// drives the state-clearing below) — it just no longer pops the modal.
    var canAutoPresentOnboardingOnLaunch: Bool {
        OnboardingPresentationPolicy.shouldAutoPresentOnLaunch(
            isFirstRunForced: isFirstRunSetupForcedOnLaunch,
            onboardingHasBeenCompleted: onboardingHasBeenCompleted
        )
    }

    var onboardingFlowInput: WorkbenchOnboardingFlowInput {
        WorkbenchOnboardingFlowInput(
            bossIsReady: onboardingReadiness?.isReady == true,
            hasProposal: onboardingProposal != nil,
            selectedTerminalCount: onboardingProposal?.selectedTerminalCount ?? 0,
            ambiguousCandidateCount: onboardingAmbiguousCandidateCount,
            importSummaryHasImports: onboardingImportSummaryHasImports
        )
    }

    var onboardingFlowDecision: WorkbenchOnboardingFlowDecision {
        WorkbenchOnboardingFlowPolicy.decision(for: onboardingFlowInput)
    }

    private var onboardingAmbiguousCandidateCount: Int {
        if let proposal = onboardingProposal {
            return proposal.groups
                .flatMap(\.terminals)
                .filter { $0.candidate.confidence >= 0.50 && $0.candidate.confidence < 0.70 }
                .count
        }
        return onboardingCandidates.filter { $0.confidence >= 0.50 && $0.confidence < 0.70 }.count
    }

    var onboardingBossChoices: [OnboardingBossChoice] {
        bossAgentChoices.map { name in
            let agent = ouroAgents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let isSelected = state.boss.agentName.caseInsensitiveCompare(name) == .orderedSame
            return OnboardingBossChoice(
                name: name,
                // First-grade-simple: a friendly readiness line, never the raw
                // `provider/model · human …/agent …` summary (lane jargon + internal IDs).
                // The live connection health surfaces after selection, via the checks —
                // so `.ready` here only promises that check, it doesn't claim the boss is
                // good to go (the premature-truth fix). Copy lives in Core.
                // #U27: no registrationStatus — the per-row tools button it fed is gone; tool
                // status is shown only on the Connect page now.
                detail: agent.map { OnboardingBossChoiceCopy.detail(for: $0.status) }
                    ?? "We couldn't find this agent on your Mac.",
                status: agent?.status,
                isSelected: isSelected
            )
        }
    }

    var commandPaletteItems: [WorkbenchCommandDescriptor] {
        func command(
            _ id: WorkbenchCommandID,
            _ title: String,
            _ detail: String,
            _ systemImage: String,
            keywords: [String] = []
        ) -> WorkbenchCommandDescriptor {
            WorkbenchCommandDescriptor(
                id: id,
                title: title,
                detail: detail,
                systemImage: systemImage,
                keywords: keywords
            )
        }

        var commands: [WorkbenchCommandDescriptor] = [
            command(
                .newSession,
                "New Terminal",
                "Create a terminal/TUI tab in the selected group",
                "plus",
                keywords: ["session", "tab", "agent", "shell", "cli"]
            ),
            command(
                .toggleBossWatch,
                bossWatchIsEnabled ? "Pause Boss Watch" : "Start Boss Watch",
                "Toggle automatic boss monitoring",
                bossWatchIsEnabled ? "eye.slash" : "eye",
                keywords: ["watch", "monitor", "autonomy", "boss"]
            ),
            command(
                .toggleBossPane,
                state.bossPaneCollapsed ? "Show Boss Pane" : "Hide Boss Pane",
                state.bossPaneCollapsed ? "Reveal boss chat and diagnostics" : "Collapse boss chat and diagnostics",
                "sidebar.leading",
                keywords: ["collapse", "expand", "dashboard", "boss"]
            ),
            command(
                .openOnboarding,
                // U37(c): "Set up a boss" matches the opt-in-boss framing the rest
                // of the app now uses (the empty-state CTA, the header menu) —
                // dropping the pre-subtraction "Set Up Workbench" naming drift.
                AgentHomeEmptyStateCopy.setUpBossButton,
                "Choose a boss to watch the whole Mac, connect its tools, and bring back recent terminals",
                "wand.and.stars",
                keywords: ["onboarding", "setup", "boss", "bootstrap", "import"]
            ),
            command(
                .installOuroAgent,
                "Create an Agent",
                "Create a new Ouro agent — name it, pick a provider, add credentials (no CLI)",
                "square.and.arrow.down",
                keywords: ["hatch", "create", "new", "agent", "install"]
            ),
            command(
                .refreshWorkspace,
                "Refresh Workspace",
                "Refresh dashboard, agents, MCP registration, and executable health",
                "arrow.clockwise",
                keywords: ["reload", "status", "health", "dashboard"]
            ),
            command(
                .refreshOuroAgents,
                "Refresh Ouro Agents",
                "Rescan local agent bundles",
                "person.2.badge.gearshape",
                keywords: ["agent", "bundle", "inventory"]
            ),
            command(
                .refreshWorkbenchMCP,
                "Refresh Workbench tools status",
                "Re-check whether Workbench tools are available to the selected boss at runtime",
                "point.3.connected.trianglepath.dotted",
                keywords: ["mcp", "boss", "registration", "tools", "runtime"]
            ),
            command(
                .searchTranscripts,
                "Search Transcripts",
                "Run the current transcript search query",
                "text.magnifyingglass",
                keywords: ["history", "output", "find"]
            ),
            command(
                .runRecoveryDrill,
                "Run Recovery Drill",
                "Simulate restart recovery planning",
                "arrow.clockwise.circle",
                keywords: ["restart", "resume", "recover", "drill"]
            ),
            command(
                .collectSupportDiagnostics,
                "Collect Support Diagnostics",
                "Create a local diagnostics zip without transcript contents",
                "lifepreserver",
                keywords: ["diag", "diagnostic", "support", "bug", "zip"]
            ),
            command(
                .openSupportDiagnosticsFolder,
                "Open Diagnostics Folder",
                "Open the support diagnostics output folder",
                "folder",
                keywords: ["diag", "diagnostic", "support", "finder"]
            ),
            command(
                .reportBug,
                "Report a Bug…",
                "Bundle a note, screenshot, diagnostics, and logs into a report",
                "ladybug",
                keywords: ["bug", "report", "issue", "feedback", "diagnostic", "screenshot", "broken"]
            ),
            command(
                .revealBugReportsFolder,
                "Open Bug Reports Folder",
                "Open the folder where bug reports are saved",
                "ladybug.fill",
                keywords: ["bug", "report", "folder", "finder", "issue"]
            ),
            command(
                .checkReleaseUpdates,
                "Check for Updates…",
                "Check for a newer release and install it in place (with relaunch)",
                "arrow.down.app",
                keywords: ["version", "update", "upgrade", "release", "install"]
            )
        ]

        if !bossCheckInIsRunning {
            commands.insert(
                command(
                    .bossCheckIn,
                    // U12: one name for the manual pull — "Check In" everywhere
                    // (header, ⌘I menu, menubar, here). Distinct from the
                    // "Ask Boss: …" quick questions below and the Boss Watch loop.
                    WorkbenchViewModel.checkInActionLabel,
                    "Ask \(state.boss.agentName) what's going on across your sessions",
                    "bubble.left.and.text.bubble.right",
                    keywords: ["boss", "ask", "status", "check in"]
                ),
                at: 1
            )
            commands.insert(contentsOf: [
                command(
                    .bossQuickWhatsGoingOn,
                    "Ask Boss: What's Going On?",
                    "Ask \(state.boss.agentName) for the current workspace situation",
                    "questionmark.bubble",
                    keywords: ["boss", "status", "what"]
                ),
                command(
                    .bossQuickWaitingOnMe,
                    "Ask Boss: Waiting On Me?",
                    "Ask \(state.boss.agentName) what needs human input",
                    "person.crop.circle.badge.questionmark",
                    keywords: ["boss", "human", "blocked", "waiting"]
                ),
                command(
                    .bossQuickKeepMoving,
                    "Ask Boss: Keep Moving",
                    "Ask \(state.boss.agentName) to advance trusted work",
                    "forward",
                    keywords: ["boss", "continue", "autonomy", "ttfa"]
                ),
                command(
                    .bossQuickRespondForMe,
                    "Ask Boss: Respond For Me",
                    "Ask \(state.boss.agentName) for response-ready next actions",
                    "arrowshape.turn.up.left",
                    keywords: ["boss", "reply", "respond"]
                )
            ], at: 2)
        }

        // Only offer the action when it would actually do something — the binary is missing
        // (`.notRegistered`) or a stale bundle entry remains (`.needsUpdate`). Mirrors the
        // header/agent buttons.
        if bossWorkbenchMCPRegistration?.isActionable == true {
            commands.append(
                command(
                    .installWorkbenchMCPForBoss,
                    "Connect Workbench tools",
                    "Make Workbench tools available to the selected boss at runtime (cleans any stale bundle entry)",
                    "wrench.and.screwdriver",
                    keywords: ["mcp", "boss", "connect", "tools", "runtime", "bridge"]
                )
            )
        }

        if lastBugReportURL != nil {
            commands.append(
                command(
                    .fileBugReportIssue,
                    "File Bug Report as GitHub Issue",
                    "Open the latest bug report as a GitHub issue",
                    "ladybug",
                    keywords: ["bug", "report", "github", "issue", "file", "venue"]
                )
            )
        }

        if supportDiagnosticsURL != nil {
            commands.append(contentsOf: [
                command(
                    .revealSupportDiagnostics,
                    "Reveal Diagnostics Zip",
                    "Reveal the latest support diagnostics zip in Finder",
                    "folder",
                    keywords: ["diag", "diagnostic", "support", "finder"]
                ),
                command(
                    .copySupportDiagnosticsPath,
                    "Copy Diagnostics Path",
                    "Copy the latest support diagnostics zip path",
                    "doc.on.doc",
                    keywords: ["diag", "diagnostic", "support", "clipboard", "path"]
                )
            ])
        }

        if releaseUpdateURL != nil {
            commands.append(command(
                .openReleaseUpdate,
                "Open Release Page",
                "Open the latest Workbench release page",
                "safari",
                keywords: ["release", "update", "github"]
            ))
        }

        if let selectedEntry, !selectedEntry.isArchived {
            commands.append(contentsOf: [
                command(
                    .launchSelectedSession,
                    activeSession(for: selectedEntry) == nil ? "Launch \(selectedEntry.name)" : "Restart \(selectedEntry.name)",
                    launchCommand(for: selectedEntry),
                    "play.fill",
                    keywords: ["terminal", "session", "start"]
                ),
                command(
                    .askBossAboutSelectedSession,
                    "Ask Boss About \(selectedEntry.name)",
                    "Ask \(state.boss.agentName) what this terminal is doing",
                    "bubble.left.and.text.bubble.right",
                    keywords: ["boss", "terminal", "session", "status"]
                ),
                command(
                    .copySelectedLaunchCommand,
                    "Copy \(selectedEntry.name) Launch Command",
                    launchCommand(for: selectedEntry),
                    "doc.on.doc",
                    keywords: ["clipboard", "copy", "command"]
                ),
                command(
                    .openSelectedWorkingDirectory,
                    "Open \(selectedEntry.name) Directory",
                    selectedEntry.workingDirectory,
                    "folder",
                    keywords: ["finder", "cwd", "working directory", "project"]
                )
            ])
            if latestRun(for: selectedEntry)?.transcriptPath != nil {
                commands.append(command(
                    .revealSelectedTranscript,
                    "Reveal \(selectedEntry.name) Transcript",
                    "Reveal the latest transcript file in Finder",
                    "doc.text.magnifyingglass",
                    keywords: ["history", "output", "transcript", "finder"]
                ))
            }
            if activeSession(for: selectedEntry) != nil {
                commands.append(contentsOf: [
                    command(
                        .focusSelectedSession,
                        "Focus \(selectedEntry.name)",
                        "Open the terminal-only view",
                        "arrow.up.left.and.arrow.down.right",
                        keywords: ["fullscreen", "terminal", "focus"]
                    ),
                    command(
                        .redrawSelectedSession,
                        "Redraw \(selectedEntry.name)",
                        "Send Ctrl-L to refresh the terminal display",
                        "arrow.clockwise",
                        keywords: ["clear", "refresh", "terminal", "screen"]
                    ),
                    command(
                        .sendControlCToSelectedSession,
                        "Send Ctrl-C To \(selectedEntry.name)",
                        "Interrupt the running terminal session",
                        "command",
                        keywords: ["signal", "interrupt", "terminal"]
                    ),
                    command(
                        .sendEscapeToSelectedSession,
                        "Send Esc To \(selectedEntry.name)",
                        "Send Escape to the running terminal session",
                        "escape",
                        keywords: ["signal", "terminal", "cancel"]
                    ),
                    command(
                        .sendEOFToSelectedSession,
                        "Send EOF To \(selectedEntry.name)",
                        "Send Ctrl-D to the running terminal session",
                        "eject",
                        keywords: ["signal", "ctrl-d", "exit", "terminal"]
                    ),
                    command(
                        .stopSelectedSession,
                        "Stop \(selectedEntry.name)",
                        "Terminate the running terminal session",
                        "stop.fill",
                        keywords: ["kill", "terminate", "terminal"]
                    )
                ])
            }
            if canRecover(selectedEntry) {
                commands.append(command(
                    .recoverSelectedSession,
                    "\(recoveryButtonTitle(for: selectedEntry)) \(selectedEntry.name)",
                    recoveryReasonSentence(for: selectedEntry),
                    "arrow.clockwise",
                    keywords: ["resume", "recover", "restart"]
                ))
            }
        }

        commands.append(
            command(
                .showKeyboardShortcutHelp,
                "Show Keyboard Shortcuts",
                "Open the keyboard shortcut reference sheet",
                "keyboard",
                keywords: ["keyboard", "shortcut", "help", "cheat sheet", "key", "binding"]
            )
        )

        commands.append(
            command(
                .openSettings,
                "Open Settings",
                "Adjust terminal font, theme, menubar icon, and other Workbench preferences",
                "gearshape",
                keywords: ["settings", "preferences", "config", "theme", "font", "menubar", "options"]
            )
        )

        commands.append(
            command(
                .openDecisionLog,
                "Decision Inbox",
                "Triage the sessions that need you — prioritized, with the full decision log a toggle away",
                "tray.full",
                keywords: ["decision", "inbox", "triage", "log", "audit", "boss", "why", "advance", "escalate", "snooze", "resolve", "queue"]
            )
        )

        commands.append(
            command(
                .openHarnessStatus,
                "Harness Status",
                "Consolidated read-only view of ouro daemon health, local agents, and boss reachability",
                "waveform.path.ecg",
                keywords: ["harness", "status", "daemon", "ouro", "health", "agents", "inventory", "boss", "reachable", "mcp", "diagnostics"]
            )
        )

        commands.append(
            command(
                .openAbout,
                "About Ouro Workbench",
                "Show the app version, build hash, and links",
                "info.circle",
                keywords: ["about", "version", "build", "info", "credits"]
            )
        )

        commands.append(
            command(
                .resetToFirstRun,
                "Reset to Factory Defaults…",
                "Clear all Workbench data (groups, sessions, preferences — backed up) and relaunch into first-run",
                "arrow.counterclockwise.circle",
                keywords: ["reset", "factory", "factory defaults", "first run", "onboarding", "fresh", "clean", "start over", "wipe", "defaults"]
            )
        )

        if !activeSessions.isEmpty {
            commands.append(
                command(
                    .stopAllRunningSessions,
                    "Stop All Running Terminals",
                    "Terminate every currently-running session in this workbench (\(activeSessions.count))",
                    "stop.circle",
                    keywords: ["stop", "halt", "quit", "kill", "terminate", "all", "everything", "shutdown"]
                )
            )
        }

        if recoveryDigest.shouldShow {
            // The count routes through the SAME `recoveryDigest.actionableCount`
            // the sidebar row, sheet header, and menu-bar item use (U8-2 review
            // fix). `recoverableEntries.count` excluded `.manualActionNeeded`, so
            // the palette read a different number than every other operator-facing
            // recovery surface — two counts disagreeing over the same state.
            commands.append(
                command(
                    .recoverAllCrashedSessions,
                    "Recover All Crashed Terminals",
                    "Re-launch every session currently flagged for recovery (\(recoveryDigest.actionableCount))",
                    "arrow.clockwise.circle",
                    keywords: ["recover", "restart", "relaunch", "all", "crashed", "fix", "resume", "respawn"]
                )
            )
        }

        commands.append(
            command(
                .openWorkspaceConfig,
                "Open Workspace…",
                "Pick a directory containing a .workbench.json to spin up its declared terminals",
                "folder.badge.gearshape",
                keywords: ["workspace", "open", "project", "config", "json", "workbench", "yaml"]
            )
        )

        if let selectedProject {
            commands.append(
                command(
                    .saveWorkspaceConfig,
                    "Save Workspace As…",
                    "Write \(selectedProject.name) to a .workbench.json file",
                    "square.and.arrow.down",
                    keywords: ["workspace", "save", "export", "config", "json", "workbench", selectedProject.name]
                )
            )
        }

        // Agent-management commands. Always-available entry points first,
        // then one Select Agent entry per installed bundle so search like
        // "agent <name>" lands on the right row.
        commands.append(contentsOf: [
            command(
                .manageAgents,
                "Manage Agents",
                "Open the Agents pane focused on the current boss",
                "person.2.badge.gearshape",
                keywords: ["agent", "bundle", "boss", "manage", "ouro"]
            )
        ])

        // U37(a): exactly one Select-Agent row per installed bundle, de-duped by
        // name and EXCLUDING the current boss (already addressable via the boss
        // selector) — the loop here used to emit one row per scanned record, so a
        // duplicate inventory entry produced a byte-identical duplicate row and the
        // boss showed up as a redundant "Select Agent: <boss> (boss)".
        commands.append(contentsOf: AgentSelectCommandList.commands(
            agents: ouroAgents,
            bossAgentName: state.boss.agentName
        ))

        if let agent = focusedAgentForCommand(nil) {
            let isBoss = state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame
            if !isBoss && agent.isUsableAsBoss {
                commands.append(
                    WorkbenchCommandDescriptor(
                        id: .useSelectedAgentAsBoss,
                        title: "Use \(agent.name) As Boss",
                        detail: "Make \(agent.name) this Mac's boss agent",
                        systemImage: "person.crop.circle.badge.checkmark",
                        keywords: ["boss", "switch", "promote", agent.name],
                        payload: agent.name
                    )
                )
            }
            commands.append(contentsOf: [
                WorkbenchCommandDescriptor(
                    id: .repairSelectedAgent,
                    title: "Repair \(agent.name)",
                    detail: "Open a terminal with `ouro check --agent \(agent.name)`",
                    systemImage: "stethoscope",
                    keywords: ["agent", "repair", "ouro", "check", "providers", agent.name],
                    payload: agent.name
                ),
                WorkbenchCommandDescriptor(
                    id: .openSelectedAgentConfig,
                    title: "Open \(agent.name) agent.json",
                    detail: agent.configPath,
                    systemImage: "doc.text",
                    keywords: ["agent", "config", "json", "providers", "model", agent.name],
                    payload: agent.name
                ),
                WorkbenchCommandDescriptor(
                    id: .revealSelectedAgentBundle,
                    title: "Reveal \(agent.name) Bundle",
                    detail: agent.bundlePath,
                    systemImage: "folder",
                    keywords: ["agent", "bundle", "finder", "reveal", agent.name],
                    payload: agent.name
                )
            ])
            if let registration = workbenchMCPRegistration(for: agent), registration.isActionable {
                commands.append(
                    WorkbenchCommandDescriptor(
                        id: .installMCPForSelectedAgent,
                        title: registration.status == .needsUpdate
                            ? "Clean up Workbench entry for \(agent.name)"
                            : "Connect Workbench tools for \(agent.name)",
                        detail: registration.detail,
                        systemImage: "link.badge.plus",
                        keywords: ["agent", "mcp", "register", "tools", agent.name],
                        payload: agent.name
                    )
                )
            }
        }

        return commands
    }

    var filteredCommandPaletteItems: [WorkbenchCommandDescriptor] {
        commandPalette.filter(commandPaletteItems, query: commandPaletteQuery)
    }

    func executableHealth(for entry: ProcessEntry) -> ExecutableHealth? {
        executableHealthByEntryID[entry.id]
    }

    func gitStatus(for entry: ProcessEntry) -> GitSessionStatus? {
        gitStatusByEntryID[entry.id]
    }

    func sessionActivity(for entry: ProcessEntry) -> SessionActivity? {
        sessionActivityByEntryID[entry.id]
    }

    /// "Stalled" = the session is in an `.active` health state but its latest
    /// run hasn't produced output for a while — it looks busy but may be wedged.
    /// Drives the chip's amber "stalled" health glyph. Derived from the free
    /// `ProcessRun.lastOutputAt` facet; idle/non-active sessions are never
    /// stalled.
    func isStalled(_ entry: ProcessEntry) -> Bool {
        guard entry.attention == .active else { return false }
        guard let run = latestRun(for: entry), run.status == .running else { return false }
        guard let lastOutput = run.lastOutputAt else { return false }
        return Date().timeIntervalSince(lastOutput) > SessionChip.stalledThreshold
    }

    func cliName(for entry: ProcessEntry) -> String? {
        guard let cliName = TerminalAgentDetector.displayName(for: TerminalAgentDetector.detect(entry: entry)) else {
            return nil
        }
        return cliName.localizedCaseInsensitiveCompare(entry.name) == .orderedSame ? nil : cliName
    }

    var bossWorkbenchMCPStatusLine: String {
        guard let bossWorkbenchMCPRegistration else {
            return "unknown"
        }
        switch bossWorkbenchMCPRegistration.status {
        case .registered:
            return "available to \(bossWorkbenchMCPRegistration.agentName) at runtime"
        case .notRegistered:
            return "tools binary missing"
        case .needsUpdate:
            return "stale entry to clean"
        case .agentMissing:
            return "agent bundle missing"
        case .executableMissing:
            return "install app first"
        case .invalidConfig:
            return "config issue"
        case .toolsNotInjected:
            return "tools didn't load — update ouro to alpha.660+"
        }
    }

    var bossWorkbenchMCPStatusColor: SwiftUI.Color {
        guard let status = bossWorkbenchMCPRegistration?.status else {
            return .secondary
        }
        switch status {
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

    var bossWorkbenchMCPActionTitle: String {
        bossWorkbenchMCPRegistration?.status == .needsUpdate ? "Clean up" : "Connect"
    }

    var ouroAgentStatusLine: String {
        guard !ouroAgents.isEmpty else {
            return "no local agents"
        }
        // Count LIVE readiness, not config-only `.ready`: an expired-token agent
        // (config-`.ready`, live `.authExpired`) used to inflate the "ready" tally
        // even though no live check confirmed it. Fold each agent's config status
        // with its live outward verdict + in-flight flag — `.ready` (green) only when
        // a `ouro check` returned `.working`, matching the harness #262 readyCount.
        let readyCount = ouroAgents.filter { agent in
            InstalledAgentRowPresentation.liveReadiness(
                status: agent.status,
                verdict: agentOutwardVerdicts[agent.name],
                isChecking: agentChecksInFlight.contains(agent.name)
            ) == .ready
        }.count
        return "\(ouroAgents.count) local, \(readyCount) ready; boss \(state.boss.agentName)"
    }

    var bossAgentChoices: [String] {
        let names = ouroAgents.map(\.name) + (bossDashboard?.knownAgentNames ?? []) + [state.boss.agentName]
        return Array(Set(names))
            .filter { !$0.isEmpty }
            .filter(BossWorkbenchMCPRegistrar.isValidAgentBundleName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func refreshOuroAgents() {
        ouroAgents = ouroAgentInventory.scan()
        resolveBossFromInventoryIfNeeded()
        refreshWorkbenchMCPRegistration()
        // Kick off a live outward-lane `ouro check` per config-ready agent so the steady-state
        // rows show an HONEST dot/label (never a config-only false green). Non-blocking: this
        // fires on launch AND on the "Refresh Agents" button (both call refreshOuroAgents).
        refreshAgentOutwardReadiness()
    }

    /// When the persisted boss is unresolved (a fresh / factory-reset machine, or
    /// a boss naming no installed bundle), adopt the sole installed agent
    /// automatically. With more than one usable agent the human picks (the
    /// onboarding boss-choice surface); with none the onboarding routes to
    /// acquisition. Never hardcodes an agent name. No-ops once a boss resolves, so
    /// it never switches away from a real selection mid-session.
    func resolveBossFromInventoryIfNeeded() {
        guard let name = BossAutoResolution.adoptableBossName(
            persistedBossName: state.boss.agentName,
            agents: ouroAgents
        ) else { return }
        selectBoss(agentName: name)
    }

    func workbenchMCPRegistration(for agent: OuroAgentRecord) -> BossWorkbenchMCPRegistrationSnapshot? {
        bossWorkbenchMCPRegistrationByAgentName[agent.name]
    }

    func revealAgentBundle(_ agent: OuroAgentRecord) {
        let targetPath = FileManager.default.fileExists(atPath: agent.configPath)
            ? agent.configPath
            : agent.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: targetPath)
        ])
    }

    /// F6 — remove an agent. Workbench's roster is a pure filesystem scan of `~/AgentBundles/*.ouro`
    /// (`OuroAgentInventory.scan`), so there is NO Workbench-side registration to deregister from:
    /// the only honest removal is deleting the on-disk `.ouro` bundle directory. The destructive
    /// confirmation copy (`AgentRemoval.confirmationCopy`) says that plainly; this performs the
    /// deletion the operator confirmed, then re-derives all roster-dependent state.
    ///
    /// Risk (b) — leave NO dangling reference to the removed agent: clear the detail-pane selection
    /// if it pointed at this agent, clear a boss name that now resolves to nothing, and
    /// `refreshOuroAgents()` (which re-scans the filesystem AND re-runs boss auto-resolution) so the
    /// removed agent stops appearing in any `@Published`-derived view, selection, or boss pill. Always
    /// clears the armed-removal flag so the confirmation can't re-fire on a deleted agent.
    @discardableResult
    func removeAgent(_ agent: OuroAgentRecord) -> Bool {
        // Clear the armed confirmation up front so a re-render can't re-present it for a now-deleted
        // agent (and a second tap can't double-delete).
        agentPendingRemoval = nil
        // LOW hardening — `agent` was captured when the trash icon armed the confirmation
        // (`agentPendingRemoval`). If the roster re-scanned and the bundle MOVED between arm and
        // confirm, `agent.bundlePath` is a stale snapshot and we'd delete the wrong (or a vanished)
        // path. Re-resolve the LIVE record by name from the current scan; if it's gone, bail
        // honestly instead of deleting a stale path. Delete the re-resolved live bundlePath.
        guard let live = ouroAgents.first(where: {
            $0.name.caseInsensitiveCompare(agent.name) == .orderedSame
        }) else {
            errorMessage = "\(agent.name) is no longer present."
            return false
        }
        let decision = AgentRemoval.decide(for: live)
        guard decision.deletesBundle else { return false }
        do {
            try FileManager.default.removeItem(atPath: decision.bundlePath)
        } catch {
            // Honest failure: surface it and leave the roster untouched (the agent still exists).
            errorMessage = "Couldn't remove \(agent.name): \(error.localizedDescription)"
            return false
        }
        // Risk (b) — drop the detail-pane selection if it pointed at the deleted agent.
        if let selected = selectedAgentName,
           selected.caseInsensitiveCompare(agent.name) == .orderedSame {
            selectedAgentName = nil
        }
        // #F9 — drop the deleted agent's CACHED `tools/list` injection verdict. The bundle is gone;
        // its verdict is meaningless. Without this, re-installing a same-name agent would inherit
        // the stale `.confirmed(.absent)` and show `.toolsNotInjected` on its inventory row until a
        // fresh probe (cosmetic — `selectBoss` clears it before a good boss is ever blocked — but a
        // re-added agent shouldn't wear a deleted predecessor's strip). Keyed to match the cache
        // (the trimmed agent name the bootstrap drain / selectBoss write under).
        bossWorkbenchToolsInjectionByAgentName[live.name] = nil
        // Risk (b) — if the deleted agent was the boss, clear the now-dangling boss name so the
        // refresh's auto-resolution can adopt the sole remaining usable agent (or leave it for the
        // choose path). Without this the boss name would keep pointing at a deleted bundle.
        if state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame {
            state.boss.agentName = ""
            for index in state.projects.indices {
                state.projects[index].boss.agentName = ""
            }
            // The selected boss changed out from under any cached boss-pane state — clear it the same
            // way selectBoss does so a stale dashboard can't reference the removed agent.
            bossDashboard = nil
        }
        save()
        // Re-scan the filesystem roster + re-run boss auto-resolution so every derived view updates.
        refreshOuroAgents()
        refreshOnboardingReadiness()
        recordActionLog(
            source: "native",
            action: "removeAgent",
            targetName: agent.name,
            result: "removed agent bundle for \(agent.name)",
            succeeded: true
        )
        return true
    }

    /// Open `agent.json` in the user's default editor (or whichever app the
    /// finder has bound to .json). Used by the Agents pane "Open Config…"
    /// button so users can flip provider/model without dropping out to a
    /// terminal.
    func openAgentConfig(_ agent: OuroAgentRecord) {
        let url = URL(fileURLWithPath: agent.configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Agent config not found at \(agent.configPath)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Open a Workbench terminal pre-loaded with the `ouro check` invocation
    /// for this agent so the user can repair providers, refresh the daemon,
    /// or fix MCP tools without remembering the CLI shape. The terminal is
    /// trusted and auto-resumable so the user can rerun it after editing.
    @discardableResult
    func repairAgent(_ agent: OuroAgentRecord) -> Bool {
        let workingDirectory = FileManager.default.fileExists(atPath: agent.bundlePath)
            ? agent.bundlePath
            : FileManager.default.homeDirectoryForCurrentUser.path
        let command = ShellArgumentEscaper.commandLine(["ouro", "check", "--agent", agent.name])
        let draft = CustomTerminalSessionDraft(
            name: "Ouro Repair: \(agent.name)",
            command: command,
            workingDirectory: workingDirectory,
            trust: .trusted,
            autoResume: false,
            notes: "Workbench repair shortcut: \(command)"
        )
        let entry = createCustomSession(draft, launchAfterCreate: true)
        if entry != nil {
            recordActionLog(
                source: "native",
                action: "repairAgent",
                targetName: agent.name,
                result: "Opened repair terminal",
                succeeded: true
            )
        }
        return entry != nil
    }

    /// Open the ⌘F search bar over the active session's terminal pane.
    /// If no session is selected the call is a no-op so the shortcut feels
    /// inert rather than launching a useless empty bar.
    func presentTerminalSearch() {
        // Targets the active pane's session so ⌘F finds inside the terminal
        // you're focused on (the focused pane when split, else the selection).
        guard let entry = activeEntry, activeSession(for: entry) != nil else {
            return
        }
        terminalSearchHasResult = true
        if !isTerminalSearchPresented {
            terminalSearchQuery = ""
        }
        isTerminalSearchPresented = true
    }

    /// Hide the search bar and clear any selection highlight SwiftTerm left
    /// behind. Bound to Esc inside the search bar and to the Done button.
    func dismissTerminalSearch() {
        guard let entry = activeEntry, let session = activeSession(for: entry) else {
            isTerminalSearchPresented = false
            return
        }
        session.terminal.clearSearch()
        isTerminalSearchPresented = false
        terminalSearchHasResult = true
    }

    /// SwiftTerm `SearchOptions` reflecting the user's current toggle state.
    var currentSearchOptions: SwiftTerm.SearchOptions {
        SwiftTerm.SearchOptions(
            caseSensitive: terminalSearchCaseSensitive,
            regex: terminalSearchRegex,
            wholeWord: terminalSearchWholeWord
        )
    }

    /// Step the search forward or backward. Returns whether anything matched
    /// so the search bar can render its "No matches" state.
    @discardableResult
    func stepTerminalSearch(direction: WorkbenchCycleDirection) -> Bool {
        guard let entry = activeEntry, let session = activeSession(for: entry) else {
            terminalSearchHasResult = false
            return false
        }
        let query = terminalSearchQuery
        guard !query.isEmpty else {
            session.terminal.clearSearch()
            terminalSearchHasResult = true
            return true
        }
        let hit: Bool
        switch direction {
        case .next:
            hit = session.terminal.findNext(query, options: currentSearchOptions)
        case .previous:
            hit = session.terminal.findPrevious(query, options: currentSearchOptions)
        }
        terminalSearchHasResult = hit
        return hit
    }

    /// Set the terminal font size and propagate it to every currently-active
    /// session. Clamps to `terminalFontSizeBounds`; persists in UserDefaults
    /// so the chosen size survives across launches.
    func setTerminalFontSize(_ requested: CGFloat) {
        let clamped = min(
            Self.terminalFontSizeBounds.upperBound,
            max(Self.terminalFontSizeBounds.lowerBound, requested)
        )
        terminalFontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.terminalFontSizeDefaultsKey)
        let font = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        for session in activeSessions.values {
            session.terminal.font = font
        }
    }

    /// Increment / decrement the persisted terminal font size by 1pt.
    /// ⌘+ uses `delta = 1`, ⌘- uses `delta = -1`.
    func bumpTerminalFontSize(by delta: CGFloat) {
        setTerminalFontSize(terminalFontSize + delta)
    }

    /// Reset the terminal font size to the macOS default. ⌘0.
    func resetTerminalFontSize() {
        setTerminalFontSize(Self.defaultTerminalFontSize)
    }

    /// Update the terminal theme override (system / light / dark), persist it,
    /// and force every active SwiftTerm session to re-paint with the new
    /// palette. Skips work when the value didn't actually change.
    func setTerminalThemeOverride(_ override: TerminalThemeOverride) {
        guard override != terminalThemeOverride else { return }
        terminalThemeOverride = override
        WorkbenchTerminalPalette.currentOverride = override
        UserDefaults.standard.set(override.rawValue, forKey: Self.terminalThemeOverrideDefaultsKey)
        for session in activeSessions.values {
            session.terminal.applyWorkbenchTheme(
                WorkbenchTerminalPalette.theme(for: session.terminal.effectiveAppearance)
            )
            session.terminal.needsDisplay = true
        }
    }

    /// Toggle the menubar status item. When turned off, the controller is
    /// detached and its NSStatusItem hidden; when turned back on, the
    /// controller re-attaches to the live model.
    func setShowMenuBarStatusItem(_ show: Bool) {
        guard show != showMenuBarStatusItem else { return }
        showMenuBarStatusItem = show
        UserDefaults.standard.set(show, forKey: Self.showMenuBarStatusItemDefaultsKey)
        if show {
            WorkbenchMenuBarController.shared.attach(model: self)
            WorkbenchMenuBarController.shared.setVisible(true)
        } else {
            WorkbenchMenuBarController.shared.setVisible(false)
        }
    }

    /// Select the Nth terminal (1-indexed) in the currently-visible session
    /// list. Used by the ⌘1..⌘9 keyboard shortcuts. Returns `true` on success
    /// so callers can decline gracefully when the slot is empty.
    @discardableResult
    func selectTerminal(atOneIndexedPosition position: Int) -> Bool {
        let active = sessionEntries
        guard position >= 1, position <= active.count else {
            return false
        }
        selectedEntryID = active[position - 1].id
        return true
    }

    /// Select the previous or next terminal in the currently-visible session
    /// list, wrapping at the ends. ⌘[ goes backwards, ⌘] goes forwards.
    @discardableResult
    func cycleTerminal(direction: WorkbenchCycleDirection) -> Bool {
        let active = sessionEntries
        guard !active.isEmpty else {
            return false
        }
        let currentIndex = active.firstIndex { $0.id == selectedEntryID } ?? -1
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex <= 0 ? active.count - 1 : currentIndex - 1
        case .next:
            nextIndex = currentIndex < 0 || currentIndex >= active.count - 1
                ? 0
                : currentIndex + 1
        }
        selectedEntryID = active[nextIndex].id
        return true
    }

    /// The ordered list of sessions ⌘J walks: the prioritized open **inbox**
    /// first (the boss's escalations etc., severity-ranked + triage-aware — a
    /// snoozed/resolved item is already filtered out by `openInbox`), then any
    /// live session that needs the operator but has no open decision yet (in
    /// sidebar order), so a freshly-waiting session the boss hasn't weighed in on
    /// is still reachable. De-duplicated, archived sessions excluded.
    func attentionJumpOrder(now: Date = Date()) -> [UUID] {
        var order: [UUID] = []
        var seen = Set<UUID>()
        // Live, non-archived entry ids — the inbox can only land you on a session
        // that still exists in the sidebar.
        let liveIDs = Set(allSessionEntries.filter { !$0.isArchived }.map(\.id))

        // 1) Prioritized inbox order (severity → recency, snoozed/resolved hidden).
        for decision in state.openInbox(now: now) {
            guard let id = decision.entryId, liveIDs.contains(id), seen.insert(id).inserted else {
                continue
            }
            order.append(id)
        }
        // 2) Preserve the original behavior as a superset: any session that needs
        // the human but isn't already queued from a decision, in sidebar order.
        for project in state.projects {
            for entry in allSessionEntries where entry.projectId == project.id
                && !entry.isArchived
                && entry.attention.needsHuman
                && seen.insert(entry.id).inserted {
                order.append(entry.id)
            }
        }
        return order
    }

    /// Jump focus to the next session that needs the operator, in **inbox
    /// priority order** (most severe first), wrapping around — then falling
    /// through to any live session needing a human that the boss hasn't recorded
    /// a decision for yet. Completes the attention loop: detection lights a
    /// session up, this carries you straight to it, prioritized + triage-aware.
    /// No-op (returns false) when nothing needs attention.
    @discardableResult
    func jumpToNextAttentionSession() -> Bool {
        let order = attentionJumpOrder()
        guard !order.isEmpty else {
            return false
        }
        let currentIndex = order.firstIndex(of: selectedEntryID ?? UUID()) ?? -1
        let nextIndex = currentIndex < 0 || currentIndex >= order.count - 1 ? 0 : currentIndex + 1
        selectEntryAcrossGroups(order[nextIndex])
        return true
    }

    /// Select the previous or next group in the sidebar. ⇧⌘[ goes backwards,
    /// ⇧⌘] goes forwards.
    @discardableResult
    func cycleGroup(direction: WorkbenchCycleDirection) -> Bool {
        let groups = state.projects
        guard !groups.isEmpty else {
            return false
        }
        let currentIndex = groups.firstIndex { $0.id == selectedProjectID } ?? -1
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex <= 0 ? groups.count - 1 : currentIndex - 1
        case .next:
            nextIndex = currentIndex < 0 || currentIndex >= groups.count - 1
                ? 0
                : currentIndex + 1
        }
        selectProject(groups[nextIndex].id)
        return true
    }

    /// Helper used by the sidebar / boss menu to set the Agents pane focus.
    /// If `name` doesn't resolve to a known bundle, fall back to the first
    /// available agent so the detail pane never lands on an empty record.
    func selectAgent(_ name: String?) {
        guard let name else {
            selectedAgentName = nil
            return
        }
        if ouroAgent(named: name) != nil {
            selectedAgentName = name
        } else if let first = ouroAgents.first {
            selectedAgentName = first.name
        } else {
            // No agent bundles installed yet — U18: open the native "Create your agent"
            // form (name + provider + credentials, headless) instead of landing on a
            // blank Agents pane or the raw `ouro hatch` CLI pane.
            selectedAgentName = nil
            presentNewAgentProviderConfigForm()
        }
    }

    /// Convenience accessor for the AgentDetailView.
    func ouroAgent(named name: String) -> OuroAgentRecord? {
        ouroAgents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Native "Connect Workbench tools" action. RUNTIME-INJECTION model: nothing is written into
    /// the boss bundle — Workbench injects the tools at runtime via `--workbench-mcp`. This runs
    /// the registrar's stale-entry CLEANUP and re-reads the snapshot; recovery truth is the
    /// POST-cleanup snapshot status (`.registered` once the binary is present + the bundle is
    /// clean), never a hardcoded success.
    func installWorkbenchMCP(for agent: OuroAgentRecord) {
        do {
            let selection = BossAgentSelection(agentName: agent.name)
            let snapshot = try bossWorkbenchMCPRegistrar.install(for: selection)
            // #F9 — DO NOT raw-assign `snapshot` into the published registration vars: that would
            // skip `BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict` and re-open the
            // false-GREEN. A registrar cleanup can't fix a too-old `ouro` (the `workbench_*` strip
            // is upstream of the bundle), so the install snapshot reads `.registered` even when the
            // cached handoff-edge verdict is `.confirmed(.absent)`. Route through the refresh, which
            // re-reads the on-disk snapshot AND overlays the cached injection verdict — so a present-
            // but-stripped boss re-asserts `.toolsNotInjected` no matter which path triggered the
            // install. (`succeeded`/the action-log copy still key off the raw install `snapshot`,
            // which reflects whether the install itself wrote a clean bundle.)
            refreshWorkbenchMCPRegistration()
            let succeeded = snapshot.status == .registered
            // Never surface the raw registrar `snapshot.detail` — for an unparseable bundle it
            // is a raw decoding error (BossAgentBridge `.invalidConfig`). Friendly copy instead.
            let result = succeeded
                ? "\(agent.name) is connected to Workbench and ready."
                : "Workbench couldn't connect \(agent.name) just now. You can try again — reopening Workbench usually clears it up."
            bossAppliedActions = [result] + bossAppliedActions
            recordActionLog(
                source: "native",
                action: "registerWorkbenchMCP",
                targetName: agent.name,
                result: result,
                succeeded: succeeded
            )
        } catch {
            errorMessage = "Workbench couldn't connect \(agent.name) just now. Please try again — reopening Workbench usually clears it up."
            refreshWorkbenchMCPRegistration()
        }
    }

    /// U35: clone an agent from a Git remote HEADLESSLY (no spawned `ouro clone` pane) and
    /// return the terminal inline-progress state the sheet renders. Mirrors the cold-start
    /// hatch path: the remote/name reach `ouro clone` only as natively-built argv tokens,
    /// never through agent context. The sheet shows `.cloning` while this awaits, then this
    /// resolves to `.succeeded` / `.failed`. On success the agent list is re-probed so the
    /// new bundle appears, and a seam-free audit line lands in the action log.
    func cloneAgentHeadless(remote: String, agentName: String) async -> CloneAgentFlowState {
        let remoteLabel = CloneAgentFlowState.remoteLabel(forRemote: remote)
        let plan: OuroAgentInstallPlan
        do {
            plan = try ouroAgentInstallCommandBuilder.clone(remote: remote, agentName: agentName)
        } catch {
            // A bad name is already blocked inline by U15's validation, so this is the
            // empty-remote / defensive path — report it seam-free, never as raw argv. (This is the
            // PRE-RUN throw; the post-run fold below uses the classifier's per-cause copy.)
            return .failed(reason: CloneAgentFlowState.failureReason(forRemoteLabel: remoteLabel))
        }

        let givenName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)

        // F7 cold-review CRITICAL — verify the clone against REALITY, not an assumed derivation. The
        // agent-name field is OPTIONAL and the recommended DEFAULT is BLANK (the clone derives the
        // name from the repo). Snapshot the roster BEFORE the clone so the pure
        // `ClonedAgentResolver` can diff it against the refreshed roster and find what ACTUALLY
        // landed — for both the named and the blank-default paths.
        let rosterNamesBefore = ouroAgents.map(\.name)

        // F7 — STOP THE THREE LIES. The runner no longer throws: it REPORTS the outcome so we can
        // name the real cause. We only inspect the bundle / probe on a CLEAN exit (B-2: a wedged or
        // not-yet-flushed bundle is never probed mid-clone); everything else fails safe with the
        // classifier's per-cause copy. The SAFETY INVARIANT lives in the pure classifier: exit-0
        // alone is NEVER ready — it needs a present agent.json AND a positive `.working` probe.
        let run = await CloneAgentRunner.runHeadless(plan: plan)

        // Always re-probe the roster so the cloned bundle surfaces with its TRUE state (a
        // credential-less / dead clone shows as needs-credentials, not ready — never vanishes). This
        // runs BEFORE the resolver read because the resolver's authority IS this refreshed roster
        // (the on-disk agent.json scan); `refreshOuroAgents()` is synchronous.
        refreshOuroAgents()

        // gap #2 — consult the bundle, but ONLY on a clean exit (otherwise a non-zero / timed-out
        // run hasn't produced a trustworthy bundle to read). The presence + provider both come from
        // the resolver (driven by the refreshed roster) so the BLANK-name default is handled too:
        // the old code gated this whole block on a non-blank name, so a blank name skipped it and a
        // clean SUCCESSFUL clone was reported as the false `.invalidMissingAgentJson`.
        var agentJsonPresent = false
        var checkVerdict: ProviderConnectionVerdict?
        var resolvedClone: ClonedAgentResolution?
        if case .exited(code: 0) = run {
            let resolution = ClonedAgentResolver.resolveClonedAgent(
                givenName: givenName,
                remote: remote,
                rosterNamesBefore: rosterNamesBefore,
                rosterAfter: ouroAgents.map {
                    ClonedRosterEntry(
                        name: $0.name,
                        // The roster reports `.missingConfig` when the bundle dir exists but its
                        // agent.json doesn't — that IS the honest "agent.json absent" signal.
                        agentJsonPresent: $0.status != .missingConfig,
                        provider: $0.humanFacing?.provider
                    )
                }
            )
            resolvedClone = resolution
            agentJsonPresent = resolution.agentJsonPresent
            // Only probe when there's a bundle to probe (a missing agent.json is already a failure).
            if agentJsonPresent {
                // The clone configures the OUTWARD lane (the one onboarding surfaces). Probe the
                // RESOLVED name (the agent that actually landed) on a short budget so a flaky-daemon
                // hang degrades to "couldn't confirm" fast.
                checkVerdict = await runCloneProviderCheck(agentName: resolution.name, lane: "outward")
            }
        }

        // The label the operator sees in audit / human-facing lines: the resolver's name when the
        // clone landed (so even the blank-default path names the real agent), else the typed name,
        // else the friendly remote label.
        let surfaceName = resolvedClone?.name ?? (givenName.isEmpty ? remoteLabel : givenName)
        let auditName = surfaceName
        let humanName = surfaceName

        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: run,
            agentJsonPresent: agentJsonPresent,
            checkVerdict: checkVerdict
        )

        switch outcome {
        case .ready:
            // Verified working — the ONLY arm that logs success.
            recordActionLog(
                source: "native",
                action: "cloneOuroAgent",
                targetName: auditName,
                result: "ran `\(plan.commandLine)` (clone; headless, inline; verified ready)",
                succeeded: true
            )
            return .succeeded(agentName: resolvedClone?.name)
        case .needsVaultUnlock:
            // B-4 — a clone has NO operator-entered provider. The resolver already read the provider
            // from the cloned record's outward (humanFacing) lane in the refreshed roster; map it
            // back to a WorkbenchProvider to drive F6's reconnect chain. If the lane provider is
            // absent/unrecognized we can't run the unlock chain honestly — degrade to "couldn't
            // confirm".
            if let laneProvider = resolvedClone?.provider,
               let provider = WorkbenchProvider(providerFlagValue: laneProvider) {
                recordActionLog(
                    source: "native",
                    action: "cloneOuroAgent",
                    targetName: auditName,
                    result: "ran `\(plan.commandLine)` (clone; outcome: \(outcome.auditReason); routing to reconnect)",
                    succeeded: false
                )
                // B-5 — beginCredentialRotation sets the .rotation flavor + reuses F6's vault markers
                // (vaultOnboardingEntryID/RunID/completeVaultOnboarding) and its in-flight gate. It
                // drives the unlock/reconnect terminal; the sheet shows the honest needs-unlock line
                // while it runs (the re-probe — not this return — is the authority on readiness). Use
                // the RESOLVED name so the blank-default path reconnects the agent that landed.
                beginCredentialRotation(agentName: resolvedClone?.name ?? surfaceName, provider: provider)
                return .failed(reason: outcome.humanFacingLine(agentName: humanName))
            }
            // Couldn't resolve the provider — surface the honest could-not-confirm copy instead of
            // guessing. (Same audit token so the log stays truthful about why.)
            let couldNotConfirm = CloneOutcome.failed(reason: .couldNotConfirm)
            recordActionLog(
                source: "native",
                action: "cloneOuroAgent",
                targetName: auditName,
                result: "ran `\(plan.commandLine)` (clone; outcome: \(outcome.auditReason); provider unresolved)",
                succeeded: false
            )
            return .failed(reason: couldNotConfirm.humanFacingLine(agentName: humanName))
        case .failed:
            // Honest failure: surface the classifier's per-cause seam-free line (the timed-out and
            // missing-agent.json cases get their OWN copy — never "Check the Git remote").
            recordActionLog(
                source: "native",
                action: "cloneOuroAgent",
                targetName: auditName,
                result: "ran `\(plan.commandLine)` (clone; outcome: \(outcome.auditReason))",
                succeeded: false
            )
            return .failed(reason: outcome.humanFacingLine(agentName: humanName))
        }
    }

    nonisolated private static func runProviderCheckProcess(
        agentName: String,
        lane: String,
        timeoutSeconds: TimeInterval
    ) -> ProviderCheckProcessResult? {
        let hostEnvironment = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || hostEnvironment["XCTestConfigurationFilePath"] != nil
        if isRunningUnderXCTest,
           hostEnvironment["OURO_WORKBENCH_LIVE_PROVIDER_CHECKS"] != "1" {
            return nil
        }
        let process = Process()
        let pipe = Pipe()
        let outputBuffer = ProviderCheckOutputBuffer()
        let exitSemaphore = DispatchSemaphore(value: 0)
        let outputEOF = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro", "check", "--agent", agentName, "--lane", lane]
        // Resolve PATH from the user's real login shell so `ouro` + its `node` runtime are
        // found from a Finder-launched app's bare launchd PATH (every other runner does this).
        process.environment = TerminalEnvironment().valuesWithResolvedPath()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outputEOF.signal()
            } else {
                outputBuffer.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            return nil
        }

        var timedOut = false
        if exitSemaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if exitSemaphore.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + 1)
            }
        }

        // Process exit does not guarantee FileHandle already delivered the final stdout/stderr
        // readability callback. Wait briefly for pipe EOF so fast `ouro check` output is not lost,
        // then close the read end so an escaped grandchild cannot hold the runner forever.
        _ = outputEOF.wait(timeout: .now() + 1)
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        let output = String(decoding: outputBuffer.snapshot(), as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}[", with: "")
        return ProviderCheckProcessResult(
            timedOut: timedOut,
            terminationStatus: process.isRunning ? Int32(SIGKILL) : process.terminationStatus,
            output: output
        )
    }

    /// F7 — short-budget post-clone provider probe. Copies `runColdStartProviderCheck` verbatim:
    /// `ouro check --agent <n> --lane outward`, 15s watchdog, classify from the OUTPUT via
    /// `ProviderCheckClassifier` (never the exit code — `ouro check` exits 0 in every state). Returns
    /// `nil` on a timeout / launch failure so the classifier degrades to "couldn't confirm" rather
    /// than false-greening a clean-but-unauthenticated clone (gap #1 / B-3).
    private func runCloneProviderCheck(agentName: String, lane: String) async -> ProviderConnectionVerdict? {
        await Task.detached(priority: .userInitiated) {
            guard let result = Self.runProviderCheckProcess(
                agentName: agentName,
                lane: lane,
                timeoutSeconds: 15
            ) else {
                return nil
            }
            // Past the budget the runner terminated the process — treat as "couldn't confirm"
            // (nil), NOT as a classified verdict from truncated output.
            guard !result.timedOut else { return nil }
            // Classify from the OUTPUT (never the exit code — `ouro check` exits 0 in every
            // state). The classifier never false-greens.
            return ProviderCheckClassifier().classify(
                exitCode: result.terminationStatus,
                stdout: result.output,
                stderr: ""
            )
        }.value
    }

    func selectBoss(agentName: String) {
        let normalizedAgentName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAgentName.isEmpty, normalizedAgentName != state.boss.agentName else {
            return
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(normalizedAgentName) else {
            errorMessage = "That agent can't be used as your boss. Please pick another."
            return
        }
        state.boss.agentName = normalizedAgentName
        // Per-project boss tracks the global selection — otherwise existing
        // groups keep whichever agent was current when they were created, and
        // any consumer reading project.boss diverges from state.boss.
        for index in state.projects.indices {
            state.projects[index].boss.agentName = normalizedAgentName
        }
        bossDashboard = nil
        bossCheckInPrompt = nil
        bossCheckInAnswer = nil
        bossQuestion = ""
        bossAppliedActions = []
        bossWatchBaselineState = state
        bossWatchChangeSummaries = []
        onboardingProposal = nil
        onboardingCandidates = []
        onboardingProviderChecks = [:]
        onboardingReconstructionHandedOff = false
        // #F9 — drop the incoming boss's CACHED `tools/list` injection verdict so a re-selected
        // boss re-probes on its next bootstrap rather than inheriting a stale `.toolsNotInjected`.
        // Without this, re-selecting a boss that was stripped under an OLD ouro would keep
        // reading the blocker even after the operator upgraded ouro (a sticky false-blocker; the
        // cache is otherwise only overwritten by a bootstrap drain). A cleared entry overlays as
        // `nil` ⇒ the on-disk snapshot status stands until a fresh probe confirms otherwise.
        bossWorkbenchToolsInjectionByAgentName[normalizedAgentName] = nil
        save()
        refreshWorkbenchMCPRegistration()
        refreshOnboardingReadiness()
        runOnboardingProviderChecksIfNeeded()
        Task {
            await refreshBossDashboard()
        }
    }

    func registerWorkbenchForBossChoice(_ agentName: String) {
        let previousBoss = state.boss.agentName
        if previousBoss.caseInsensitiveCompare(agentName) != .orderedSame {
            selectBoss(agentName: agentName)
        }
        installWorkbenchMCPForBoss()
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        refreshOnboardingReadiness()
        runOnboardingProviderChecksIfNeeded()
    }

    func selectProject(_ projectId: UUID) {
        guard state.projects.contains(where: { $0.id == projectId }) else {
            return
        }
        selectedProjectID = projectId
        selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
    }

    /// Select a specific session by id, switching the active group to the
    /// session's project first. The menu-bar and recovery lists show sessions
    /// from every group, but `selectedEntry` resolves through the
    /// project-filtered list — so setting `selectedEntryID` alone would land
    /// on the wrong terminal when the target lives in another group. Always
    /// set the project before the entry.
    func selectEntryAcrossGroups(_ entryId: UUID) {
        guard let entry = state.processEntries.first(where: { $0.id == entryId }) else {
            return
        }
        if entry.projectId != selectedProjectID,
           state.projects.contains(where: { $0.id == entry.projectId }) {
            selectedProjectID = entry.projectId
        }
        selectedEntryID = entryId
    }

    /// #U23c: jump to the session a boss-pane "Needs Me" / "Coding" item points
    /// at, via the navigation key (the ref it carries, else its label). Matches a
    /// session by name (case-insensitive); selects it and returns true on a hit.
    /// When nothing matches (the key isn't a live session — e.g. an obligation
    /// id), falls back to opening the Decision Inbox so the click is never dead,
    /// and returns false.
    @discardableResult
    func selectSession(byNavigationKey key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let entry = state.processEntries.first(where: {
                  $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
              })
        else {
            presentDecisionInbox()
            return false
        }
        selectEntryAcrossGroups(entry.id)
        return true
    }

    // MARK: - Detail split (W5 increment 1)

    /// Open (or re-orient) the single detail split. The primary pane keeps the
    /// current sidebar selection; the secondary pane is auto-filled with the
    /// next session in the same group that isn't already the primary (so
    /// "Split Right" on a project's first agent immediately shows its second
    /// agent side-by-side). If there's no such sibling the secondary pane opens
    /// as an empty picker. Re-running while already split just changes the axis
    /// (and re-fills an empty secondary pane if a sibling is now available),
    /// keeping the depth-1 invariant.
    ///
    /// The one-NSView-per-session invariant is preserved by construction here:
    /// the chosen `secondaryEntryID` is always `!= selectedEntryID`.
    func splitDetail(axis: DetailSplitAxis) {
        guard let primary = selectedEntry else {
            // Nothing selected to anchor a split on (e.g. empty workspace or
            // the Agents pane is focused) — splitting would have no primary
            // pane, so it's a no-op.
            return
        }
        // Keep an existing secondary assignment if it's still valid (and not
        // the primary); otherwise pick the next sibling, else leave empty.
        let existing = detailSplit?.secondaryEntryID
        let keepExisting = existing.map { id in
            id != primary.id && allSessionEntries.contains { $0.id == id }
        } ?? false
        let secondary = keepExisting ? existing : nextSiblingEntryID(excluding: primary.id)
        detailSplit = DetailSplitState(axis: axis, secondaryEntryID: secondary)
        activePaneID = .primary
    }

    /// The next session to auto-fill the secondary pane with: the entry after
    /// `primaryID` in the current group's visible session list (wrapping), or
    /// the first other entry if `primaryID` isn't in the list. Returns `nil`
    /// when the group has no other session — the secondary pane then opens as
    /// an empty picker. Never returns `primaryID` (one-session-per-pane).
    private func nextSiblingEntryID(excluding primaryID: UUID) -> UUID? {
        let siblings = sessionEntries
        guard siblings.contains(where: { $0.id != primaryID }) else { return nil }
        if let index = siblings.firstIndex(where: { $0.id == primaryID }) {
            // Start just after the primary and take the first different entry.
            for offset in 1...siblings.count {
                let candidate = siblings[(index + offset) % siblings.count]
                if candidate.id != primaryID { return candidate.id }
            }
        }
        return siblings.first { $0.id != primaryID }?.id
    }

    /// Assign a session to the secondary pane, enforcing one-session-per-pane.
    /// If the session is already the primary (sidebar) selection, this swaps:
    /// the primary becomes what the secondary was showing, so the session the
    /// operator picked for the secondary pane ends up there alone. Passing
    /// `nil` clears the secondary pane back to the empty picker.
    func assignSecondaryPane(to entryID: UUID?) {
        guard detailSplit != nil else { return }
        guard let entryID else {
            detailSplit?.secondaryEntryID = nil
            return
        }
        // Reassigning to the same session is a no-op.
        guard entryID != detailSplit?.secondaryEntryID else { return }
        // Compare against the *displayed* primary (selectedEntry), which is
        // what pane A actually mounts — it can differ from the raw
        // selectedEntryID only in the pre-selection startup state.
        if entryID == selectedEntry?.id {
            // Would duplicate the primary pane's session. Swap the two panes
            // so each still shows a distinct session (the old secondary,
            // possibly nil, moves to the primary).
            let oldSecondary = detailSplit?.secondaryEntryID
            detailSplit?.secondaryEntryID = entryID
            selectedEntryID = oldSecondary
        } else {
            detailSplit?.secondaryEntryID = entryID
        }
    }

    /// Close whichever pane is focused, collapsing back to a single pane.
    /// Closing the secondary pane simply drops the split. Closing the primary
    /// pane promotes the secondary's session into the (single) pane — matching
    /// the tree-collapse behavior the design calls for at depth 1. Closing a
    /// pane never kills the underlying pty (the session and its
    /// `TerminalSessionController` outlive the pane, exactly like deselecting).
    func closeActivePane() {
        guard detailSplit != nil else { return }
        if activePaneID == .primary, let promoted = detailSplit?.secondaryEntryID {
            // The secondary's session becomes the sole pane's selection.
            selectEntryAcrossGroups(promoted)
        }
        detailSplit = nil
        activePaneID = .primary
    }

    /// Toggle logical focus between the two panes (no-op when not split).
    /// Clicking a pane already routes keyboard input via AppKit's first
    /// responder; this command-driven toggle keeps the focus ring and
    /// command-retargeting in sync for keyboard-only navigation.
    func focusOtherPane() {
        guard detailSplit != nil else { return }
        activePaneID = activePaneID == .primary ? .secondary : .primary
    }

    /// Mark a pane as focused (driven by a tap on the pane chrome). Ignored
    /// when not split so single-pane stays trivially "primary."
    func focusPane(_ pane: DetailPaneID) {
        guard detailSplit != nil else { return }
        guard activePaneID != pane else { return }
        activePaneID = pane
    }

    /// The current in-memory split as its persisted shape, or `nil` when not
    /// split (single pane writes no `detailLayout`). Used by
    /// `persistDetailLayout()` to mirror live split state into `WorkspaceState`.
    private var detailLayoutSnapshot: PaneLayoutState? {
        guard let split = detailSplit else { return nil }
        return PaneLayoutState(
            axis: split.axis.persisted,
            secondaryEntryID: split.secondaryEntryID,
            activePane: activePaneID.persisted
        )
    }

    /// Mirror the live split (`detailSplit` + `activePaneID`) into
    /// `state.detailLayout` and persist, so the layout survives relaunch.
    /// Called from the `detailSplit` / `activePaneID` `didSet`s, so every
    /// split / unsplit / assign-secondary / focus change — including the
    /// auto-clear of a secondary that collides with the new primary selection
    /// — is written through the normal `save()` path. A no-op write when the
    /// snapshot already matches `state.detailLayout` (avoids redundant disk
    /// writes when an unrelated change fires the observer with no net effect).
    private func persistDetailLayout() {
        let snapshot = detailLayoutSnapshot
        guard state.detailLayout != snapshot else { return }
        state.detailLayout = snapshot
        save()
    }

    /// Resolve or create the group used by an opened workspace config. If a
    /// group with the same name already exists, reuses it; otherwise creates
    /// a fresh project with the resolved root path.
    private func ensureGroup(name: String, rootPath: String) -> WorkbenchProject {
        if let existing = state.projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let project = WorkbenchProject(name: name, rootPath: rootPath, boss: state.boss)
        state.projects.append(project)
        return project
    }

    /// Apply a parsed `.workbench.json` to the workbench. Reuses existing
    /// sessions that match by name within the resolved group (so re-opening
    /// the same workspace doesn't duplicate). Returns a banner-friendly
    /// summary identical in shape to onboarding's Arrange result.
    @discardableResult
    func openWorkspaceConfig(
        config: WorkbenchWorkspaceConfig,
        configDirectory: String,
        loader: WorkbenchWorkspaceConfigLoader = WorkbenchWorkspaceConfigLoader()
    ) -> WorkbenchImportApplyResult {
        let rootPath = loader.resolvedRootPath(for: config, configDirectory: configDirectory)
        let groupName = loader.resolvedGroupName(for: config, rootPath: rootPath)
        let project = ensureGroup(name: groupName, rootPath: rootPath)
        selectedProjectID = project.id

        var createdEntries: [ProcessEntry] = []
        var skippedNames: [String] = []
        // Re-import no-ops (a (projectId,name) match already in the workbench) are
        // tallied here, distinct from `skippedNames` error-skips, so the summary can
        // say "N already present" instead of silently dropping them.
        var alreadyPresentCount = 0
        for terminal in config.terminals {
            let workingDirectory = loader.resolvedWorkingDirectory(for: terminal, rootPath: rootPath)
            let trust: ProcessTrust = (terminal.trust ?? "").lowercased() == "trusted"
                ? .trusted
                : .untrusted
            let autoResume = terminal.autoResume ?? false
            let alreadyPresent = state.processEntries.contains { existing in
                existing.projectId == project.id && existing.name == terminal.name
            }
            if alreadyPresent {
                // Already in the workbench — count it (surfaced as "N already
                // present") and skip. We do NOT update the existing entry from the
                // file's (possibly edited) command/cwd/trust/autoResume: whether a
                // matched terminal should be updated is a deferred product decision.
                alreadyPresentCount += 1
                continue
            }
            let draft = CustomTerminalSessionDraft(
                name: terminal.name,
                command: terminal.command,
                workingDirectory: workingDirectory,
                trust: trust,
                autoResume: autoResume,
                notes: terminal.notes ?? "Opened from \(configDirectory)/\(WorkbenchWorkspaceConfigLoader.configFileName)"
            )
            do {
                let entry = try customSessionFactory.makeEntry(projectId: project.id, draft: draft)
                state.processEntries.append(entry)
                createdEntries.append(entry)
            } catch {
                skippedNames.append(terminal.name)
                recordActionLog(
                    source: "native",
                    action: "openWorkspaceConfig",
                    result: "Skipped \(terminal.name): \(error.localizedDescription)",
                    succeeded: false
                )
            }
        }

        // Capture whether the durable write landed; the green banner + the
        // succeeded:true action log gate on this. A swallowed write failure used
        // to surface as a false green over an in-memory-only import.
        let persisted = save()
        refreshExecutableHealth()
        // Auto-resume the entries the config explicitly marked autoResume so
        // the workspace boots up the way the file promised.
        for entry in createdEntries where entry.autoResume {
            launch(entry)
        }
        selectedEntryID = createdEntries.first?.id ?? selectedEntryID
        let result = WorkbenchImportApplyResult(
            createdCount: createdEntries.count,
            groupNames: createdEntries.isEmpty ? [] : [groupName],
            skippedNames: skippedNames,
            alreadyPresentCount: alreadyPresentCount,
            firstSelectedEntryID: createdEntries.first?.id,
            persisted: persisted
        )
        lastImportSummary = result
        let saveNote = persisted ? "" : " (not saved to disk — will be lost on quit)"
        let alreadyPresentNote = alreadyPresentCount > 0
            ? ", \(alreadyPresentCount) already present"
            : ""
        recordActionLog(
            source: "native",
            action: "openWorkspaceConfig",
            targetName: groupName,
            result: "Workspace \(groupName) created \(createdEntries.count) terminals (skipped \(skippedNames.count)\(alreadyPresentNote))\(saveNote)",
            succeeded: persisted
        )
        return result
    }

    /// Load + apply a workspace config from a directory path. Surfaces parser
    /// errors via `errorMessage` so the user sees what went wrong.
    /// Push a workspace path to the front of the recent list, dedupe, and
    /// persist. Trims to `maxRecentWorkspaces` entries.
    func recordRecentWorkspace(path: String) {
        var entries = recentWorkspacePaths.filter { $0 != path }
        entries.insert(path, at: 0)
        if entries.count > Self.maxRecentWorkspaces {
            entries = Array(entries.prefix(Self.maxRecentWorkspaces))
        }
        recentWorkspacePaths = entries
        UserDefaults.standard.set(entries, forKey: Self.recentWorkspacePathsDefaultsKey)
    }

    /// Drop a path from the recent list (used when opening a workspace that
    /// no longer has `.workbench.json` — keeps the menu honest).
    func forgetRecentWorkspace(path: String) {
        let entries = recentWorkspacePaths.filter { $0 != path }
        recentWorkspacePaths = entries
        UserDefaults.standard.set(entries, forKey: Self.recentWorkspacePathsDefaultsKey)
    }

    @discardableResult
    func openWorkspaceConfig(at directoryPath: String) -> WorkbenchImportApplyResult? {
        let loader = WorkbenchWorkspaceConfigLoader()
        let config: WorkbenchWorkspaceConfig
        do {
            config = try loader.load(directoryPath: directoryPath)
        } catch let configError as WorkbenchWorkspaceConfigError {
            switch configError {
            case .configFileMissing(let path):
                errorMessage = "No .workbench.json found at \(path)"
            case .fileUnreadable(let detail):
                // A file-READ blip (lock / EACCES / volume hiccup / EIO): surface an
                // honest message but do NOT prune — a retry may clear it (the Core
                // decision classifies this `.transient`, so the gated prune keeps it).
                errorMessage = "Couldn't read .workbench.json (try again): \(detail)"
            case .malformedJSON(let detail):
                errorMessage = "Couldn't parse .workbench.json: \(detail)"
            case .noTerminals:
                errorMessage = ".workbench.json must declare at least one terminal"
            }
            // FIX 3: a recent that failed to load STRUCTURALLY (gone / malformed /
            // empty) is dead and re-errors on every click — drop it so the menu
            // stays honest. A file-READ blip (`.fileUnreadable`) is recoverable, so
            // the pure Core decision classifies it `.transient` and KEEPS the recent
            // — only structural failures forget. The decision is exhaustively tested
            // in WorkbenchRecentWorkspacePruningTests; previously only
            // `configFileMissing` pruned, and a read blip was wrongly lumped with
            // malformed JSON (pruning a good workspace on a transient hiccup).
            if WorkbenchRecentWorkspacePruning.shouldForget(
                after: WorkbenchRecentWorkspacePruning.classify(configError)
            ) {
                forgetRecentWorkspace(path: directoryPath)
            }
            return nil
        } catch {
            errorMessage = "Couldn't open workspace: \(error.localizedDescription)"
            // A transient / unknown failure may clear on retry — KEEP the recent
            // (classified `.transient`, which the pure decision keeps). Deliberately
            // no prune here: we must not silently drop a recent on a blip.
            return nil
        }
        let result = openWorkspaceConfig(config: config, configDirectory: directoryPath, loader: loader)
        recordRecentWorkspace(path: directoryPath)
        return result
    }

    /// Build a `.workbench.json`-compatible config representing the currently
    /// selected project. Each non-archived session in the project becomes a
    /// terminal entry. Working directories under the project root are
    /// rewritten as relative paths so the resulting file is portable.
    func exportWorkspaceConfig(for project: WorkbenchProject) -> WorkbenchWorkspaceConfig {
        let projectSessions = state.processEntries.filter {
            $0.projectId == project.id && !$0.isArchived
        }
        let rootPath = (project.rootPath as NSString).expandingTildeInPath
        let terminals: [WorkbenchWorkspaceConfig.TerminalConfig] = projectSessions.map { entry in
            let workingDirectory: String?
            if entry.workingDirectory == rootPath {
                workingDirectory = nil
            } else if entry.workingDirectory.hasPrefix(rootPath + "/") {
                workingDirectory = String(entry.workingDirectory.dropFirst(rootPath.count + 1))
            } else {
                workingDirectory = entry.workingDirectory
            }
            return WorkbenchWorkspaceConfig.TerminalConfig(
                name: entry.name,
                command: launchCommand(for: entry),
                workingDirectory: workingDirectory,
                trust: entry.trust == .trusted ? "trusted" : "untrusted",
                autoResume: entry.autoResume,
                notes: entry.trimmedNotes
            )
        }
        return WorkbenchWorkspaceConfig(
            group: project.name,
            rootPath: project.rootPath,
            terminals: terminals
        )
    }

    /// Present an NSSavePanel pre-populated with the resolved root path and
    /// the canonical `.workbench.json` filename, then write a pretty-printed
    /// JSON file on confirm. Surfaces parse / write errors via the existing
    /// alert path.
    func presentSaveWorkspacePanel() {
        guard let project = selectedProject else {
            errorMessage = WorkbenchSurfacePolicy.noWorkspaceSelectedToSaveMessage
            return
        }
        let config = exportWorkspaceConfig(for: project)
        guard !config.terminals.isEmpty else {
            errorMessage = "\(project.name) has no terminals to save"
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Workspace"
        panel.message = "Write \(project.name) to .workbench.json"
        panel.nameFieldStringValue = WorkbenchWorkspaceConfigLoader.configFileName
        panel.canCreateDirectories = true
        if !project.rootPath.isEmpty {
            let expandedRoot = (project.rootPath as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedRoot) {
                panel.directoryURL = URL(fileURLWithPath: expandedRoot)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            // Atomic so an interrupted overwrite (crash / disk-full / kill) never
            // truncates the operator's PRIOR `.workbench.json` — the atomic write
            // lands in a temp file and renames into place, so a partial write can't
            // clobber the existing file and break the next "Open Workspace…".
            // Matches the durable `WorkbenchStore.save` writer, which is already atomic.
            try data.write(to: url, options: [.atomic])
            // Save target is the directory containing the .workbench.json so
            // the recent workspaces menu reopens the directory, matching the
            // Open Workspace… flow.
            recordRecentWorkspace(path: url.deletingLastPathComponent().path)
            recordActionLog(
                source: "native",
                action: "saveWorkspaceConfig",
                targetName: project.name,
                result: "Wrote \(config.terminals.count) terminals to \(url.path)",
                succeeded: true
            )
        } catch {
            errorMessage = "Couldn't save workspace: \(error.localizedDescription)"
        }
    }

    /// Present an NSOpenPanel to pick a directory, then open its config. Used
    /// by the command-palette "Open Workspace…" entry and the More menu.
    func presentOpenWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Workbench Workspace"
        panel.message = "Choose a directory containing a .workbench.json file."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        openWorkspaceConfig(at: url.path)
    }

    func createGroup(name: String, rootPath: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = WorkbenchSurfacePolicy.workspaceNameRequiredMessage
            return false
        }
        // U14: reject a non-existent root at create time — for the operator AND the
        // boss (the MCP `createGroup` action lands here too), instead of acking a bad
        // path and failing later when a terminal tries to launch in it. Persist the
        // tilde-expanded path so a `~` root resolves identically everywhere.
        let rootValidation = WorkspaceRootValidation.validateOnDisk(trimmedRoot)
        guard rootValidation.isUsable else {
            errorMessage = rootValidation.errorMessage
            return false
        }
        let project = WorkbenchProject(
            name: trimmedName,
            rootPath: rootValidation.expandedPath,
            boss: state.boss
        )
        state.projects.append(project)
        selectedProjectID = project.id
        selectedEntryID = nil
        save()
        return true
    }

    func beginEditingGroup(_ project: WorkbenchProject) {
        guard state.projects.contains(where: { $0.id == project.id }) else {
            errorMessage = WorkbenchSurfacePolicy.workspaceNoLongerExistsMessage(name: project.name)
            return
        }
        editingGroup = project
    }

    @discardableResult
    func renameGroup(_ project: WorkbenchProject, name: String, rootPath: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = WorkbenchSurfacePolicy.workspaceNameRequiredMessage
            return false
        }
        // U14: editing a workspace to a non-existent root is rejected the same way as
        // creating one — keep the sheet open on a path-specific error rather than
        // saving a bad root that breaks every terminal later.
        let rootValidation = WorkspaceRootValidation.validateOnDisk(trimmedRoot)
        guard rootValidation.isUsable else {
            errorMessage = rootValidation.errorMessage
            return false
        }
        guard let index = state.projects.firstIndex(where: { $0.id == project.id }) else {
            errorMessage = WorkbenchSurfacePolicy.workspaceNoLongerExistsMessage(name: project.name)
            return false
        }
        state.projects[index].name = trimmedName
        state.projects[index].rootPath = rootValidation.expandedPath
        editingGroup = nil
        recordActionLog(
            source: "native",
            action: "editGroup",
            targetName: trimmedName,
            result: "Edited workspace \(trimmedName)",
            succeeded: true
        )
        return true
    }

    func requestDeleteGroup(_ project: WorkbenchProject) {
        guard state.projects.count > 1 else {
            errorMessage = WorkbenchSurfacePolicy.keepAtLeastOneWorkspaceMessage
            return
        }
        guard totalTerminalCount(in: project) == 0 else {
            errorMessage = "Move or delete terminals before deleting \(project.name)"
            return
        }
        pendingDeleteGroup = project
    }

    func deleteGroup(_ project: WorkbenchProject) {
        guard state.projects.count > 1 else {
            errorMessage = WorkbenchSurfacePolicy.keepAtLeastOneWorkspaceMessage
            return
        }
        guard totalTerminalCount(in: project) == 0 else {
            errorMessage = WorkbenchSurfacePolicy.moveOrDeleteTerminalsBeforeDeletingMessage(name: project.name)
            pendingDeleteGroup = nil
            return
        }
        state.projects.removeAll { $0.id == project.id }
        pendingDeleteGroup = nil
        if selectedProjectID == project.id {
            selectedProjectID = state.projects.first?.id
            selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
        }
        recordActionLog(
            source: "native",
            action: "deleteGroup",
            targetName: project.name,
            result: "Deleted empty workspace \(project.name)",
            succeeded: true
        )
    }

    func moveSession(_ entry: ProcessEntry, to projectId: UUID, recordNativeAction: Bool = true) {
        guard let project = state.projects.first(where: { $0.id == projectId }) else {
            errorMessage = WorkbenchSurfacePolicy.targetWorkspaceNoLongerExistsMessage
            return
        }
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before moving it"
            return
        }
        guard let index = state.processEntries.firstIndex(where: { $0.id == entry.id }) else {
            errorMessage = "Terminal no longer exists: \(entry.name)"
            return
        }
        state.processEntries[index].projectId = projectId
        state.processEntries[index].workingDirectory = project.rootPath
        selectedProjectID = projectId
        selectedEntryID = entry.id
        if recordNativeAction {
            recordActionLog(
                source: "native",
                action: "moveSession",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: "Moved \(entry.name) to \(project.name)",
                succeeded: true
            )
        } else {
            save()
        }
    }

    func setBossPaneCollapsed(_ collapsed: Bool) {
        guard state.bossPaneCollapsed != collapsed else {
            return
        }
        state.bossPaneCollapsed = collapsed
        save()
    }

    func setBossWatchEnabled(_ enabled: Bool) {
        guard bossWatchIsEnabled != enabled else {
            return
        }
        bossWatchIsEnabled = enabled
        state.bossWatchEnabled = enabled
        bossWatchLastError = nil
        if enabled {
            bossWatchBaselineState = state
            bossWatchChangeSummaries = []
            bossWatchLastPromptAt = nil
            save()
            Task {
                await runBossWatchTick(force: true)
            }
            // FIX4 — start the periodic poll loop on enable. Cancel any prior handle
            // first so a rapid off→on can't leak a second loop. The loop itself only
            // exists while Watch is on, so it no longer wakes every 60s while OFF.
            bossWatchLoopTask?.cancel()
            bossWatchLoopTask = Task {
                await runBossWatchLoop()
            }
        } else {
            bossWatchBaselineState = nil
            bossWatchChangeSummaries = []
            bossWatchLastRunAt = nil
            bossWatchLastPromptAt = nil
            // FIX4 — cancel the poll loop on disable so it stops waking entirely
            // (the true "no idle wakeups while OFF" guarantee).
            bossWatchLoopTask?.cancel()
            bossWatchLoopTask = nil
            save()
        }
    }

    /// FIX4 — launch-time entry: start the poll loop only if Boss Watch was
    /// persisted ON (state restored by `load()` sets `bossWatchIsEnabled` directly,
    /// bypassing `setBossWatchEnabled`, so the loop must be (re)started here). When
    /// Watch is OFF at launch this is a no-op — no loop, no idle wakeups. Replaces
    /// the old unconditional `.task { runBossWatchLoop() }` at the view root.
    func startBossWatchLoopIfEnabled() {
        guard bossWatchIsEnabled, bossWatchLoopTask == nil else {
            return
        }
        bossWatchLoopTask = Task {
            await runBossWatchLoop()
        }
    }

    /// The periodic Boss Watch poll. FIX4 — this loop is now created ONLY while
    /// Watch is on (by `setBossWatchEnabled` / `startBossWatchLoopIfEnabled`) and
    /// cancelled on disable, so it no longer wakes every interval just to `continue`
    /// while OFF. It still re-checks `bossWatchIsEnabled` before a tick as a cheap
    /// race guard (a cancel mid-sleep also breaks the loop via `Task.isCancelled`).
    func runBossWatchLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: bossWatchIntervalNanoseconds)
            if Task.isCancelled || !bossWatchIsEnabled {
                return
            }
            await runBossWatchTick(force: false)
        }
    }

    /// React to a session newly needing attention by asking the boss right
    /// away, instead of waiting up to a full poll interval — the responsive,
    /// only-when-there's-something-to-do path. Respects Boss Watch being on,
    /// never overlaps a running check-in, and is rate-limited so a burst of
    /// events coalesces into one ask.
    private func triggerEventDrivenBossCheckIn() {
        let now = Date()
        guard BossWatchEventPolicy.shouldTriggerCheckIn(
            watchEnabled: bossWatchIsEnabled,
            busy: bossCheckInIsRunning || bossWatchTickIsRunning,
            lastTriggerAt: lastEventDrivenCheckInAt,
            now: now,
            cooldown: eventDrivenCheckInCooldown
        ) else {
            return
        }
        lastEventDrivenCheckInAt = now
        Task { await runBossWatchTick(force: true) }
    }

    func runBossWatchTick(force: Bool) async {
        guard bossWatchIsEnabled, !bossCheckInIsRunning, !bossWatchTickIsRunning else {
            return
        }
        // Back off the automatic loop while the boss keeps failing, so a down
        // boss isn't re-invoked every interval. A manual check-in (the Check In
        // button) calls runBossCheckIn directly and is never gated here.
        guard BossWatchBackoff.mayAttempt(now: Date(), nextRetryAt: bossWatchNextRetryAt) else {
            return
        }
        bossWatchTickIsRunning = true
        defer {
            bossWatchTickIsRunning = false
        }
        let observedAt = Date()
        let previousState = bossWatchBaselineState ?? state
        let changes = changeSummarizer.summarize(previous: previousState, current: state, occurredAt: observedAt)

        // Gate on the SHARED `RecoveryDigest` needs-action signal (U42) — the same
        // derivation the recovery drill (U39) and the sidebar read — so the wake
        // decision can't drift. `hasNeedsAction` is auto-recoverable + needs-you and
        // excludes lossless `.reattach` survivors, so a pure-reconnect workspace
        // (nothing to actually do) never wakes the boss.
        let hasActionableState = !summary.waitingOnHuman.isEmpty || recoveryDigest.hasNeedsAction
        let shouldAskBoss = force || !changes.isEmpty || (hasActionableState && bossWatchLastPromptAt == nil)
        bossWatchLastRunAt = observedAt
        guard shouldAskBoss else {
            recordBossWatchChanges(changes)
            bossWatchBaselineState = state
            return
        }

        await runBossCheckIn(
            question: bossBridgePlanner.watchQuestion(),
            recentChanges: changes
        )
        bossWatchLastPromptAt = Date()
        let finalChanges = changeSummarizer.summarize(previous: previousState, current: state, occurredAt: Date())
        recordBossWatchChanges(finalChanges.isEmpty ? changes : finalChanges)
        bossWatchBaselineState = state
    }

    func refreshWorkbenchMCPRegistration() {
        // #F9 — overlay the cached handoff-edge injection verdict onto each on-disk snapshot,
        // so a boss whose binary is present but whose `workbench_*` tools were silently
        // stripped (old `ouro`) reads `.toolsNotInjected` instead of a false `.registered`.
        func overlaid(_ snapshot: BossWorkbenchMCPRegistrationSnapshot, agentName: String) -> BossWorkbenchMCPRegistrationSnapshot {
            BossWorkbenchMCPRegistrationSnapshot.applyingInjectionVerdict(
                bossWorkbenchToolsInjectionByAgentName[agentName],
                to: snapshot
            )
        }

        let selectedSnapshot = overlaid(
            bossWorkbenchMCPRegistrar.snapshot(for: state.boss),
            agentName: state.boss.agentName
        )
        bossWorkbenchMCPRegistration = selectedSnapshot
        var snapshots = Dictionary(
            uniqueKeysWithValues: ouroAgents.map { agent in
                (
                    agent.name,
                    overlaid(
                        bossWorkbenchMCPRegistrar.snapshot(for: BossAgentSelection(agentName: agent.name)),
                        agentName: agent.name
                    )
                )
            }
        )
        snapshots[state.boss.agentName] = selectedSnapshot
        bossWorkbenchMCPRegistrationByAgentName = snapshots
    }

    /// One-time launch migration: sweep EVERY local agent bundle clean of stale `ouro_workbench`
    /// servers and `senses.workbench` entries. Under runtime injection the boss gets the Workbench
    /// MCP per-turn from `--workbench-mcp` (see `BossAgentBridgePlanner.mcpServePlan`), so nothing
    /// belongs in any agent's git-synced bundle. `install(for:)` only cleans the boss, which leaves
    /// a stale entry on any NON-boss agent to pollute git-sync to other machines and remain
    /// over-permissive. This sweeps all of them.
    ///
    /// Runs off the main actor (per-agent file edit) and BEFORE/independent of boss selection — a
    /// stale entry on any agent is cleaned regardless of who's boss. Idempotent: a clean machine
    /// produces no writes. When something was cleaned we re-snapshot so the Agents pane reflects
    /// the now-clean bundles.
    func sweepStaleWorkbenchBundlesOnLaunch() {
        let registrar = bossWorkbenchMCPRegistrar
        Task.detached(priority: .utility) {
            let changed = registrar.cleanupAllAgents()
            guard !changed.isEmpty else {
                return
            }
            await MainActor.run {
                self.refreshWorkbenchMCPRegistration()
            }
        }
    }

    func refreshExecutableHealth() {
        executableHealthByEntryID = Dictionary(
            uniqueKeysWithValues: allSessionEntries.map { entry in
                let executable = ExecutableHealthTarget.executable(for: entry)
                return (entry.id, executableHealthChecker.health(for: executable))
            }
        )
    }

    /// Refresh per-session git status off the main actor. Each session's
    /// working directory is probed with a watchdog-bounded `git` call (see
    /// `GitStatusReader`), so a slow or locked repo can't stall the UI. Results
    /// are applied back on the main actor. Mirrors `executableHealth`, but async
    /// because it shells out. Stale entries are pruned so a deleted session
    /// never leaves a dangling chip.
    func refreshGitStatus() {
        let targets: [(UUID, String)] = allSessionEntries.map { ($0.id, $0.workingDirectory) }
        let reader = gitStatusReader
        Task.detached(priority: .utility) {
            var results: [UUID: GitSessionStatus] = [:]
            for (id, dir) in targets {
                results[id] = reader.status(forDirectory: dir)
            }
            await MainActor.run { [results] in
                self.gitStatusByEntryID = results
            }
        }
    }

    /// Refresh per-session activity (todo/step/tool/token-$) off the main actor,
    /// mirroring `refreshGitStatus`'s posture: snapshot the targets on the main
    /// actor, do all disk I/O on a detached utility task, publish back on main.
    ///
    /// Tuned for ~10 mostly-dormant sessions: only sessions with *recent* output
    /// are re-read (a dormant terminal's chip stays put rather than paying a
    /// disk tail every tick). Existing activity for skipped sessions is carried
    /// forward so the chip doesn't flicker empty. The reader itself is bounded
    /// (byte-tail), so even the refreshed set is cheap.
    func refreshSessionActivity() {
        let reader = sessionActivityReader
        let now = Date()
        let previous = sessionActivityByEntryID
        // (id, dir, agentKind, shouldRefresh). Skip shells with no agent kind
        // and sessions whose latest run hasn't been active recently.
        let targets: [(id: UUID, dir: String, kind: TerminalAgentKind?, refresh: Bool)] =
            allSessionEntries.map { entry in
                let kind = entry.agentKind
                let refresh = kind != nil && isSessionRecentlyActive(entry, now: now)
                return (entry.id, entry.workingDirectory, kind, refresh)
            }
        Task.detached(priority: .utility) {
            var results: [UUID: SessionActivity] = [:]
            for target in targets {
                if target.refresh {
                    results[target.id] = reader.activity(forDirectory: target.dir, agentKind: target.kind)
                } else {
                    // Carry forward the last known value for dormant/non-agent
                    // sessions instead of re-reading or dropping it.
                    results[target.id] = previous[target.id]
                }
            }
            await MainActor.run { [results] in
                self.sessionActivityByEntryID = results
            }
        }
    }

    /// Whether an entry's latest run produced output (or started) recently
    /// enough to warrant re-tailing its transcript. Dormant sessions fall out of
    /// this window so the timer doesn't hammer the disk for them.
    private func isSessionRecentlyActive(_ entry: ProcessEntry, now: Date) -> Bool {
        guard let run = latestRun(for: entry) else { return false }
        if run.status == .running { return true }
        let reference = run.lastOutputAt ?? run.endedAt ?? run.startedAt
        return now.timeIntervalSince(reference) < SessionChip.dormantThreshold
    }

    func installWorkbenchMCPForBoss() {
        let selectedAgent = ouroAgents.first {
            $0.name.caseInsensitiveCompare(state.boss.agentName) == .orderedSame
        } ?? OuroAgentRecord(
            name: state.boss.agentName,
            bundlePath: "",
            configPath: bossWorkbenchMCPRegistration?.agentConfigPath ?? "",
            status: .ready,
            detail: "selected boss"
        )
        installWorkbenchMCP(for: selectedAgent)
    }

    /// Bring the local runtime online at app launch. The daemon is managed-but-
    /// independent infrastructure — it should be online whenever Workbench is, not
    /// only after the first check-in or while Boss Watch happens to be on. Without
    /// this, a daemon that died between sessions stays down on relaunch until a
    /// manual check-in. Runs the SAME idempotent detect-reuse-else-start cycle as
    /// the check-in, but QUIETLY: records the outcome to the audit log and never
    /// shows a startup banner (a real check-in surfaces "waking" when it matters).
    /// Skipped before a boss is resolved — a fresh machine has no agent yet and the
    /// first-run bootstrap (S0) owns its own bringup.
    /// Capture the user's real login-shell PATH once at launch and hand it to
    /// `TerminalEnvironment`, so every `ouro` shellout resolves `node` + `ouro` the
    /// way the user's shell does (nvm/asdf/brew — wherever they live). Without this,
    /// `ouro` (a `node` script) dies with "node: not found" and the whole onboarding
    /// reads as broken. Off-main, idempotent.
    func prepareLoginShellEnvironment() async {
        guard TerminalEnvironment.loginShellPath == nil else { return }
        let captured = await Task.detached(priority: .userInitiated) {
            WorkbenchViewModel.readLoginShellPath()
        }.value
        if let captured, !captured.isEmpty {
            TerminalEnvironment.loginShellPath = captured
        }
    }

    /// Run `$SHELL -lc 'printf %s "$PATH"'` to read the PATH the user's interactive
    /// shell actually exposes (profile-sourced: version managers, brew, ouro). Returns
    /// nil on any failure so callers fall back to the synthesized PATH.
    nonisolated public static func readLoginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // INTERACTIVE login shell (`-ilc`), not `-lc`. THE root-cause fix — see
        // `TerminalEnvironment.loginShellCaptureArguments` for the full why (nvm/node/ouro live in
        // `.zshrc`, which only an interactive shell sources; a `-lc` capture silently drops them).
        process.arguments = TerminalEnvironment.loginShellCaptureArguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            // CRITICAL: this runs on the launch-blocking path (the launch task awaits
            // this before showing onboarding). A login shell that hangs sourcing its
            // profile (network-mounted rc, a blocking nvm/MDM hook, a profile that waits
            // on input) would otherwise hang `waitUntilExit` forever and the wizard would
            // never appear. Bound it: terminate past the deadline so the read unwinds and
            // we fall back to the synthesized PATH. 10s (not 5s) — an interactive shell sources
            // a heavier `.zshrc` (plugin frameworks, completions) and must not be killed mid-source.
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10, execute: watchdog)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    func ensureDaemonRunningOnLaunch() async {
        guard !state.boss.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let outcome = await daemonManager.ensureRunning()
        recordActionLog(
            source: "native",
            action: "ensureDaemon",
            targetName: "launch",
            result: outcome.auditDetail,
            succeeded: !outcome.needsManualRecovery
        )
    }

    // MARK: - Harness Status control actions

    /// Bring the agent's background runtime back online from the Harness Status
    /// sheet. Runs the SAME detached detect-reuse-else-start cycle as the boss
    /// check-in (`DaemonManager.ensureRunning()`): the app executes it directly —
    /// no Workbench terminal pane, no CLI seam, no confirmation theater — and the
    /// daemon is started DETACHED so it survives Workbench quitting. Recovery truth
    /// comes from the POST-start verify probe, never an exit code. Non-destructive
    /// and idempotent: an already-up daemon is reused without a respawn.
    ///
    /// The human-facing banner is product voice only; the raw CLI-level recovery
    /// detail is recorded in the audit log surface, never shown to the human.
    func repairHarnessDaemon() async {
        let bossName = state.boss.agentName
        let outcome = await daemonManager.ensureRunning()
        let message: String
        switch outcome.recovery {
        case .resumed:
            message = "Your agent's runtime is already online."
        case .respawned:
            message = "Brought your agent's runtime back online."
        case .needsManual:
            message = "Workbench couldn't bring your agent back online automatically. You can try again — and if it keeps happening, reconnecting your provider usually clears it up."
        }
        harnessActionResult = HarnessActionResult(
            kind: .repairDaemon,
            succeeded: !outcome.needsManualRecovery,
            message: message
        )
        // Audit/debug surface — the ONE place the raw `ouro` recovery detail belongs.
        recordActionLog(
            source: "native",
            action: "repairHarnessDaemon",
            targetName: bossName,
            result: outcome.auditDetail,
            succeeded: !outcome.needsManualRecovery
        )
    }

    /// Connect Workbench's tools to the selected boss from the Harness Status sheet. RUNTIME
    /// INJECTION: nothing is written to the bundle — Workbench injects the tools at runtime via
    /// `--workbench-mcp`. Reuses the `registerWorkbenchForBossChoice` path (which runs the
    /// registrar's stale-entry cleanup + refreshes the snapshot), then reads back the resulting
    /// status to report success/failure into the sheet banner.
    ///
    /// Called only behind the "Connect Workbench tools?" confirmation.
    func registerHarnessWorkbenchMCP() {
        let bossName = state.boss.agentName
        registerWorkbenchForBossChoice(bossName)
        let status = bossWorkbenchMCPRegistration?.status
        let succeeded = status == .registered
        let message: String
        if succeeded {
            message = "\(bossName) is connected to Workbench and ready."
        } else if let detail = bossWorkbenchMCPRegistration?.detail, !detail.isEmpty {
            message = "Couldn't connect \(bossName) to Workbench: \(detail)"
        } else {
            message = "Couldn't connect \(bossName) to Workbench."
        }
        harnessActionResult = HarnessActionResult(
            kind: .registerWorkbenchMCP,
            succeeded: succeeded,
            message: message
        )
    }

    func launchCommand(for entry: ProcessEntry) -> String {
        do {
            return try WorkbenchCommandPlanner(paths: paths).launchPlan(for: entry).displayCommand
        } catch {
            return entry.executable
        }
    }

    /// The raw planner reason, kept for the on-demand tooltip / disclosure.
    /// Operator-facing surfaces should render `recoveryReasonSentence(for:)`
    /// instead; this stays the auditable detail behind it.
    func recoveryReason(for entry: ProcessEntry) -> String {
        recoveryPlan(for: entry)?.reason ?? "no action"
    }

    /// One plain operator-facing sentence for an entry's recovery plan (U8c).
    /// Falls back to the "nothing to recover" phrasing when no plan exists.
    func recoveryReasonSentence(for entry: ProcessEntry) -> String {
        guard let plan = recoveryPlan(for: entry) else {
            return recoveryPhrasebook.operatorSentence(for: .noAction, rawReason: "no action")
        }
        return recoveryPhrasebook.operatorSentence(for: plan.action, rawReason: plan.reason)
    }

    /// One plain operator-facing sentence for a recovery-DRILL row (U8c). The
    /// raw action / status transition / reason stay available via the row's
    /// tooltip (see `recoveryDrillItemDetail`).
    func recoveryDrillItemSentence(for item: RecoveryDrillItem) -> String {
        recoveryPhrasebook.operatorSentence(for: item.action, rawReason: item.reason)
    }

    /// The raw, auditable detail for a recovery-drill row — the internal action,
    /// the status transition, and the planner's exact reason — shown on demand
    /// in the row's tooltip rather than verbatim in the operator-facing copy.
    func recoveryDrillItemDetail(for item: RecoveryDrillItem) -> String {
        let before = item.beforeStatus?.rawValue ?? "none"
        let after = item.afterStatus?.rawValue ?? "none"
        return "\(item.action.rawValue): \(before) → \(after) — \(item.reason)"
    }

    /// True when the entry's latest run needs recovery but the planner classified
    /// it `.manualActionNeeded` — i.e. there's NO resumable session, so the only
    /// path forward is a fresh start that discards the prior conversation. U7
    /// uses this to label the inactive-surface button "Start fresh" (not the calm
    /// "Launch") and gate it behind a confirmation. A genuinely never-run entry
    /// (`.noAction`, "Ready to launch") is NOT manual-recovery — "Launch" is
    /// honest there because there's no history to lose.
    func manualRecoveryNeeded(for entry: ProcessEntry) -> Bool {
        guard !entry.isArchived else { return false }
        return recoveryPlan(for: entry)?.action == .manualActionNeeded
    }

    /// The one-line confirmation copy shown before a fresh start that discards an
    /// agent's prior conversation (U7). Names what's lost and what's preserved.
    func startFreshConfirmationMessage(for entry: ProcessEntry) -> String {
        "\(entry.name) has no resumable session — starting begins a new conversation. The previous transcript stays viewable."
    }

    /// Present the U7 "Start fresh" confirmation for an entry. The actual
    /// fresh launch only runs from `confirmStartFresh()` once the operator
    /// confirms.
    func requestStartFresh(_ entry: ProcessEntry) {
        pendingStartFresh = entry
    }

    /// Run the fresh-launch path for the pending entry after the operator
    /// confirmed the one-line warning. Clears the pending state.
    func confirmStartFresh() {
        guard let entry = pendingStartFresh else { return }
        pendingStartFresh = nil
        launch(entry)
    }

    var startFreshConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { self.pendingStartFresh != nil },
            set: { newValue in
                if !newValue {
                    self.pendingStartFresh = nil
                }
            }
        )
    }

    func recoveryPlan(for entry: ProcessEntry) -> RecoveryPlan? {
        summary.recoveryPlans.first { $0.entryId == entry.id }
    }

    func canRecover(_ entry: ProcessEntry) -> Bool {
        guard !entry.isArchived else {
            return false
        }
        guard let plan = recoveryPlan(for: entry) else {
            return false
        }
        return plan.action == .reattach || plan.action == .autoResume || plan.action == .respawn
    }

    /// Title shown in the Dock window list, ⌘\` window switcher, and Mission
    /// Control. Title bar itself is hidden, so this string is what macOS
    /// shows when there's no visible title strip — making it dynamic means
    /// the user can tell which boss / surface a window points at from those
    /// system surfaces. Shape: "Ouro Workbench — <boss> — <focused surface>".
    var windowTitle: String {
        let appName = "Ouro Workbench"
        let boss = state.boss.agentName
        let focus: String
        if let agentName = selectedAgentName, ouroAgent(named: agentName) != nil {
            focus = "Agent: \(agentName)"
        } else if let entry = selectedEntry {
            if let groupName = groupName(for: entry) {
                focus = "\(groupName) — \(entry.name)"
            } else {
                focus = entry.name
            }
        } else if let group = selectedProject?.name {
            focus = group
        } else {
            focus = ""
        }
        if boss.isEmpty && focus.isEmpty {
            return appName
        }
        if focus.isEmpty {
            return "\(appName) — \(boss)"
        }
        return "\(appName) — \(boss) — \(focus)"
    }

    /// All sessions that the recovery planner considers actionable right now.
    /// Used by the sidebar Recovery row to know whether to highlight itself,
    /// by the Recovery sheet to render the list, and by `recoverAll`.
    var recoverableEntries: [ProcessEntry] {
        allSessionEntries.filter { canRecover($0) }
    }

    /// The single shared recovery derivation (U8b). The sidebar row text, its
    /// help, the sheet header, the sheet's row count, and `shouldShowRecovery`
    /// all read from this one value so they can never disagree. Built from the
    /// same `summary.recoveryPlans` (which already reflect live `screen`
    /// survival via `liveScreenSessionNames`).
    var recoveryDigest: RecoveryDigest {
        RecoveryDigest(plans: summary.recoveryPlans)
    }

    /// Resolve a digest's entry-id list back to the actual entries, preserving
    /// the digest's order and skipping any id that no longer maps to a session.
    private func entries(forIDs ids: [UUID]) -> [ProcessEntry] {
        let byID = Dictionary(allSessionEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Lossless reconnects + auto-recoverable sessions — the rows the Recovery
    /// sheet can act on automatically (no history loss for reattach; resume /
    /// respawn for the rest). Same membership as `recoverableEntries`, but
    /// ordered by the digest so the sheet groups match the count.
    var autoRecoverableEntries: [ProcessEntry] {
        entries(forIDs: recoveryDigest.reattachEntryIDs + recoveryDigest.autoRecoverableEntryIDs)
    }

    /// Sessions that can't be auto-resumed and need the operator (the U7 "Needs
    /// you" group): a fresh start, or a one-click fix when the blocker is fixable.
    var needsYouEntries: [ProcessEntry] {
        entries(forIDs: recoveryDigest.needsYouEntryIDs)
    }

    /// True when an entry's recovery is a lossless live reattach — its `screen`
    /// session kept running, so reconnecting loses nothing (U8b). The Recovery
    /// sheet labels these distinctly ("Reconnect — no loss") so a calm reconnect
    /// is never shown as an alarming recovery action.
    func isLosslessReattach(for entry: ProcessEntry) -> Bool {
        recoveryPlan(for: entry)?.action == .reattach
    }

    /// True when an entry's manual-recovery blocker is the untrusted gate — a
    /// one-click fix: trusting it lets recovery auto-resume instead of forcing a
    /// fresh start (U7). The planner's untrusted path is the only manual blocker
    /// that flipping a single toggle clears.
    func recoveryTrustFixAvailable(for entry: ProcessEntry) -> Bool {
        guard manualRecoveryNeeded(for: entry) else { return false }
        guard entry.trust != .trusted else { return false }
        // Key off the TYPED blocker, not the planner's prose (U38). A reworded
        // reason string used to silently disable this one-click fix with no test
        // catching it; the typed `.untrusted` signal survives any wording change.
        return recoveryPlan(for: entry)?.blocker == .untrusted
    }

    /// Trust an entry whose manual-recovery blocker was the untrusted gate, then
    /// recover it — the inline one-click fix the "Needs you" row offers (U7).
    /// After trusting, the planner reclassifies it to a real recovery action, so
    /// `recover` resumes/respawns instead of forcing a fresh start.
    func trustAndRecover(_ entry: ProcessEntry) {
        guard recoveryTrustFixAvailable(for: entry) else { return }
        updateEntry(entry.id) { mutable in
            mutable.trust = .trusted
            mutable.lastSummary = "\(mutable.name) trusted — recovering"
        }
        save()
        recordActionLog(
            source: "native",
            action: "trustAndRecover",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Trusted \(entry.name) and recovered",
            succeeded: true
        )
        // Re-read the entry: trust changed, so the planner now yields a real
        // recovery action.
        if let refreshed = allSessionEntries.first(where: { $0.id == entry.id }) {
            recover(refreshed)
        }
    }

    /// Trigger recovery for every entry the planner currently considers
    /// recoverable. Used by the Recovery sheet's "Recover all" button.
    /// Records a single action log entry summarising the batch so the log
    /// doesn't get flooded with N near-identical lines.
    func recoverAllRecoverableSessions() {
        let entries = recoverableEntries
        guard !entries.isEmpty else {
            return
        }
        for entry in entries {
            recover(entry)
        }
        recordActionLog(
            source: "native",
            action: "recoverAll",
            result: "Recovered \(entries.count) session\(entries.count == 1 ? "" : "s")",
            succeeded: true
        )
    }

    // MARK: - TTFA inline repairs (#U9)
    //
    // One-tap actuators the TTFA readiness popover calls per non-green check. Each mirrors the
    // exact slice of entries the Core `AutonomyReadinessBuilder` flagged, so tapping the button
    // flips that check toward green in place (the snapshot recomputes off `state`). The popover
    // gates each button on the matching `*NeedsTrust`/`*Toggle` predicate below so it never renders
    // an orphaned or no-op button.

    /// Active, non-archived terminal-agent entries — the same set the readiness builder evaluates
    /// for trust and resume.
    private var autonomyAgentEntries: [ProcessEntry] {
        state.processEntries.filter { !$0.isArchived && $0.kind == .terminalAgent }
    }

    /// Agent terminals the trust check flagged as not trusted.
    var untrustedAutonomyAgentEntries: [ProcessEntry] {
        autonomyAgentEntries.filter { $0.trust != .trusted }
    }

    /// Agent terminals where flipping auto-resume on would actually help: they have an automatic
    /// resume strategy but it's currently disabled. An agent with only a `.manual` strategy is not
    /// counted — toggling auto-resume can't give it one, so it's a degraded state, not a one-tap fix.
    var resumableDisabledAutonomyAgentEntries: [ProcessEntry] {
        autonomyAgentEntries.filter { entry in
            guard !entry.autoResume else { return false }
            guard let agentKind = TerminalAgentDetector.detect(entry: entry),
                  let preset = TerminalAgentPresets.preset(for: agentKind) else {
                return false
            }
            return preset.resumeStrategy.kind != .manual
        }
    }

    /// Trust every untrusted agent terminal so the readiness trust check turns green. Records one
    /// batched action-log line. No-op (and no log) when nothing is untrusted.
    func trustUntrustedAutonomyAgentTerminals() {
        let entries = untrustedAutonomyAgentEntries
        guard !entries.isEmpty else { return }
        for entry in entries {
            // Only flip the trust state. Don't repurpose the operator-visible
            // `lastSummary` (the session status line, which also feeds the boss
            // prompt) for a settings-toggle confirmation — that belongs in the
            // action log below, not the session's status (U41).
            updateEntry(entry.id) { entry in
                entry.trust = .trusted
            }
        }
        save()
        recordActionLog(
            source: "native",
            action: "trustAll",
            result: "Trusted \(entries.count) agent terminal\(entries.count == 1 ? "" : "s")",
            succeeded: true
        )
    }

    /// Enable auto-resume on every agent terminal that has an automatic strategy but it's off, so
    /// the readiness resume check turns green. No-op (and no log) when nothing is toggleable.
    func enableAutoResumeForAutonomyAgentTerminals() {
        let entries = resumableDisabledAutonomyAgentEntries
        guard !entries.isEmpty else { return }
        for entry in entries {
            // Only flip the auto-resume setting. Don't rewrite the
            // operator-visible `lastSummary` (session status line + boss prompt)
            // for a settings-toggle confirmation — the action log below is the
            // right home for that (U41).
            updateEntry(entry.id) { entry in
                entry.autoResume = true
            }
        }
        save()
        recordActionLog(
            source: "native",
            action: "enableAutoResumeAll",
            result: "Enabled auto-resume on \(entries.count) agent terminal\(entries.count == 1 ? "" : "s")",
            succeeded: true
        )
    }

    func recoveryButtonTitle(for entry: ProcessEntry) -> String {
        guard let plan = recoveryPlan(for: entry) else {
            return "Recover"
        }
        switch plan.action {
        case .reattach:
            return "Reconnect"
        case .autoResume:
            return "Resume"
        case .respawn:
            return "Respawn"
        case .manualActionNeeded:
            return "Manual Recovery"
        case .noAction:
            return "Recover"
        }
    }

    func activeSession(for entry: ProcessEntry) -> TerminalSessionController? {
        activeSessions[entry.id]
    }

    func latestRun(for entry: ProcessEntry) -> ProcessRun? {
        state.processRuns
            .filter { $0.entryId == entry.id }
            .sorted(by: ProcessRun.isMoreRecent)
            .first
    }

    /// `Date` the entry's currently-running process started, or `nil` when
    /// the entry isn't running. Used by the sidebar elapsed-time pill so the
    /// row can show "3m" / "1h 12m" / "running" without the row needing to
    /// dig into ProcessRun internals itself.
    func runningStartDate(for entry: ProcessEntry) -> Date? {
        guard let run = latestRun(for: entry), run.status == .running else {
            return nil
        }
        return run.startedAt
    }

    func transcriptTail(for entry: ProcessEntry) -> TranscriptTail? {
        transcriptTailReader.read(path: latestRun(for: entry)?.transcriptPath)
    }

    func searchTranscripts() {
        let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptSearchLastQuery = query.isEmpty ? nil : query
        guard !query.isEmpty else {
            transcriptSearchResults = []
            return
        }
        // The searcher opens + reads every transcript file. Run it off the
        // main actor so a workspace with many / large transcripts (or a slow
        // volume) can't freeze the UI; publish results back on the main actor.
        let snapshot = state
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                TranscriptSearcher().search(
                    query: query,
                    state: snapshot,
                    maxMatches: TranscriptSearchLimit.defaultMatches
                )
            }.value
            // Drop stale results if the query changed while we searched.
            guard let self, self.transcriptSearchLastQuery == query else {
                return
            }
            self.transcriptSearchResults = results
        }
    }

    func transcriptSearchQueryDidChange() {
        let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != transcriptSearchLastQuery else {
            return
        }
        transcriptSearchResults = []
        transcriptSearchLastQuery = nil
    }

    func runRecoveryDrill() {
        recoveryDrillResult = recoveryDrill.run(state: state)
    }

    func checkForReleaseUpdate() async {
        guard !releaseUpdateIsChecking else {
            return
        }
        releaseUpdateInstallError = nil
        releaseUpdateIsChecking = true
        defer {
            releaseUpdateIsChecking = false
        }
        let snapshot = await releaseUpdateChecker.check()
        releaseUpdateSnapshot = snapshot
        recordActionLog(
            source: "native",
            action: "checkReleaseUpdates",
            result: snapshot.detail,
            succeeded: snapshot.status != .unavailable
        )
    }

    func openReleaseUpdate() {
        guard let releaseUpdateURL else {
            return
        }
        NSWorkspace.shared.open(releaseUpdateURL)
    }

    var updatePromptIsPresented: Binding<Bool> {
        Binding(
            get: { self.updatePrompt != nil },
            set: { newValue in
                if !newValue {
                    self.updatePrompt = nil
                }
            }
        )
    }

    /// Reachable from the More menu / ⌘K: check GitHub for a newer release and
    /// drive the "Software Update" dialog — offering Install & Relaunch when an
    /// installable update exists, or telling the user they're current / why the
    /// check failed otherwise.
    func checkForUpdatesAndPromptInstall() async {
        await checkForReleaseUpdate()
        guard let snapshot = releaseUpdateSnapshot else {
            updatePrompt = .failed(detail: "Could not check for updates right now.")
            return
        }
        switch snapshot.status {
        case .updateAvailable:
            if snapshot.hasInstallableAssets, let release = snapshot.latestReleaseLabelForPrompt {
                updatePrompt = .installable(release: release)
            } else {
                updatePrompt = .failed(detail: "A newer version is published but has no installable assets yet — try the release page.")
            }
        case .current:
            updatePrompt = .upToDate(release: snapshot.currentReleaseLabelForPrompt)
        case .unavailable:
            updatePrompt = .failed(detail: snapshot.detail)
        }
    }

    /// One-click in-app update: download the latest release's app archive +
    /// manifest, verify SHA-256 / byte count / bundle id / signature, then swap
    /// the running bundle in place and relaunch. Running `screen` sessions are
    /// left alive (this is a normal quit, not a teardown), so agents survive the
    /// update and reattach on the new version.
    func installReleaseUpdate() async {
        guard !releaseUpdateIsInstalling else {
            return
        }
        // Fast path: the background auto-updater already downloaded + verified
        // this version, so installing is just the swap + relaunch.
        if let staged = pendingStagedUpdate {
            releaseUpdateInstallStatus = "Installing \(staged.releaseLabel) and relaunching…"
            applyReleaseUpdateAndTerminate(
                staged: staged,
                successLog: "Applying staged \(staged.releaseLabel); relaunching"
            )
            return
        }

        guard let snapshot = releaseUpdateSnapshot else {
            releaseUpdateInstallError = "Check for an update first."
            return
        }
        let plan: WorkbenchUpdatePlan
        switch WorkbenchUpdatePlanner.plan(from: snapshot) {
        case let .success(value):
            plan = value
        case let .failure(error):
            releaseUpdateInstallError = error.errorDescription
            return
        }

        releaseUpdateIsInstalling = true
        releaseUpdateInstallError = nil
        releaseUpdateInstallStatus = "Starting…"

        let installer = WorkbenchUpdateInstaller(
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            currentVersion: WorkbenchRelease.version,
            currentBuild: Self.buildHashString()
        )
        do {
            let staged = try await installer.stage(plan: plan) { [weak self] line in
                await MainActor.run { self?.releaseUpdateInstallStatus = line }
            }
            releaseUpdateInstallStatus = "Installing \(staged.releaseLabel) and relaunching…"
            applyReleaseUpdateAndTerminate(
                staged: staged,
                successLog: "Staged \(staged.releaseLabel); swapping bundle and relaunching"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            releaseUpdateInstallError = message
            releaseUpdateInstallStatus = nil
            releaseUpdateIsInstalling = false
            recordActionLog(
                source: "native",
                action: "installReleaseUpdate",
                result: message,
                succeeded: false
            )
        }
    }

    private func applyReleaseUpdateAndTerminate(
        staged: WorkbenchUpdateInstaller.Staged,
        successLog: String
    ) {
        releaseUpdateIsInstalling = true
        switch WorkbenchUpdateInstaller.applyAndRelaunch(
            staged: staged,
            destinationBundle: Bundle.main.bundleURL
        ) {
        case .launched:
            isApplyingManualUpdate = true
            recordActionLog(
                source: "native",
                action: "installReleaseUpdate",
                result: successLog,
                succeeded: true
            )
            NSApp.terminate(nil)
        case let .failedToLaunch(message):
            pendingStagedUpdate = staged
            stagedUpdateVersion = staged.releaseLabel
            releaseUpdateInstallError = "Could not start the update helper: \(message)"
            releaseUpdateInstallStatus = nil
            releaseUpdateIsInstalling = false
            isApplyingManualUpdate = false
            recordActionLog(
                source: "native",
                action: "installReleaseUpdate",
                result: releaseUpdateInstallError ?? message,
                succeeded: false
            )
        }
    }

    func setAutoUpdateEnabled(_ enabled: Bool) {
        autoUpdateEnabled = enabled
    }

    /// The header "Update" badge label, or `nil` when there's nothing to offer.
    /// Prefers a fully-staged version (ready to install instantly) but also
    /// shows as soon as an installable update is merely *known*.
    var updateBadgeText: String? {
        appShellUpdatePresentation.badgeText
    }

    /// Badge tap / "review update" → reuse the Software Update dialog.
    func presentUpdatePrompt() {
        if let release = appShellUpdatePresentation.promptRelease {
            updatePrompt = .installable(release: release)
        }
    }

    /// Launch-time auto-update: if enabled and not throttled, check GitHub and
    /// (when an installable update exists) stage it in the background so it's
    /// ready to apply on quit. Runs at most once per session.
    func runAutoUpdateCheckIfDue() async {
        guard !autoUpdateCheckStartedThisSession else { return }
        autoUpdateCheckStartedThisSession = true
        let now = Date()
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastUpdateCheckAtDefaultsKey) as? Date
        guard WorkbenchAutoUpdatePolicy.shouldCheck(
            now: now,
            lastCheck: lastCheck,
            minimumInterval: 3600,
            enabled: autoUpdateEnabled
        ) else {
            return
        }
        UserDefaults.standard.set(now, forKey: Self.lastUpdateCheckAtDefaultsKey)
        await checkForReleaseUpdate()
        guard autoUpdateEnabled,
              let snapshot = releaseUpdateSnapshot,
              snapshot.status == .updateAvailable,
              snapshot.hasInstallableAssets else {
            return
        }
        await stagePendingUpdate(from: snapshot)
    }

    /// Download + verify the update in the background and hold it for apply-on-
    /// quit. Failures are intentionally quiet — the manual "Check for Updates…"
    /// flow surfaces errors; the badge just won't appear.
    private func stagePendingUpdate(from snapshot: ReleaseUpdateSnapshot) async {
        guard pendingStagedUpdate == nil else { return }
        guard case let .success(plan) = WorkbenchUpdatePlanner.plan(from: snapshot) else { return }
        let installer = WorkbenchUpdateInstaller(
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            currentVersion: WorkbenchRelease.version,
            currentBuild: Self.buildHashString()
        )
        do {
            let staged = try await installer.stage(plan: plan) { _ in }
            pendingStagedUpdate = staged
            stagedUpdateVersion = staged.releaseLabel
            recordActionLog(
                source: "native",
                action: "autoStageUpdate",
                result: "Staged \(staged.releaseLabel) in background; will install on quit",
                succeeded: true
            )
        } catch {
            // Quiet: leave the badge off; manual check still reports the reason.
        }
    }

    /// Apply a background-staged update during quit — the quiet "install on
    /// quit" path. Skipped during a factory reset (the early return in
    /// `prepareForTermination`) and when a manual Install & Relaunch is already
    /// applying.
    private func applyStagedUpdateOnQuitIfNeeded() {
        guard autoUpdateEnabled, !isApplyingManualUpdate, let staged = pendingStagedUpdate else {
            return
        }
        pendingStagedUpdate = nil
        let result = WorkbenchUpdateInstaller.applyOnQuit(
            staged: staged,
            destinationBundle: Bundle.main.bundleURL
        )
        if case let .failedToLaunch(message) = result {
            pendingStagedUpdate = staged
            stagedUpdateVersion = staged.releaseLabel
            recordActionLog(
                source: "native",
                action: "autoApplyUpdateOnQuit",
                result: "Could not start the update helper: \(message)",
                succeeded: false
            )
        }
    }

    func collectSupportDiagnostics() {
        guard !supportDiagnosticsIsCollecting else {
            return
        }
        supportDiagnosticsIsCollecting = true
        supportDiagnosticsError = nil

        let runner = SupportDiagnosticsRunner(resourceDirectory: Bundle.main.resourceURL)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<SupportDiagnosticsResult, Error>.success(try runner.run())
                } catch {
                    return Result<SupportDiagnosticsResult, Error>.failure(error)
                }
            }.value

            supportDiagnosticsIsCollecting = false
            switch outcome {
            case let .success(result):
                supportDiagnosticsResult = result
                recordActionLog(
                    source: "native",
                    action: "collectSupportDiagnostics",
                    result: "Wrote \(result.archiveURL.lastPathComponent)",
                    succeeded: true
                )
            case let .failure(error):
                supportDiagnosticsError = error.localizedDescription
                recordActionLog(
                    source: "native",
                    action: "collectSupportDiagnostics",
                    result: "Failed: \(error.localizedDescription)",
                    succeeded: false
                )
            }
        }
    }

    func revealSupportDiagnostics() {
        guard let supportDiagnosticsURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([supportDiagnosticsURL])
        recordActionLog(
            source: "native",
            action: "revealSupportDiagnostics",
            result: "Revealed \(supportDiagnosticsURL.lastPathComponent)",
            succeeded: true
        )
    }

    func copySupportDiagnosticsPath() {
        guard let supportDiagnosticsURL else {
            errorMessage = "No support diagnostics zip has been collected yet"
            return
        }
        copyToPasteboard(supportDiagnosticsURL.path)
        recordActionLog(
            source: "native",
            action: "copySupportDiagnosticsPath",
            result: "Copied diagnostics path",
            succeeded: true
        )
    }

    func openSupportDiagnosticsFolder() {
        let folder = supportDiagnosticsURL?.deletingLastPathComponent()
            ?? SupportDiagnosticsRunner.defaultOutputDirectory()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            recordActionLog(
                source: "native",
                action: "openSupportDiagnosticsFolder",
                result: "Opened diagnostics folder",
                succeeded: true
            )
        } catch {
            errorMessage = "Diagnostics folder could not be opened: \(error.localizedDescription)"
            recordActionLog(
                source: "native",
                action: "openSupportDiagnosticsFolder",
                result: "Failed: \(error.localizedDescription)",
                succeeded: false
            )
        }
    }

    /// Assemble a self-contained bug report bundle: the operator's note, a
    /// window screenshot (captured in-process, so no screen-recording prompt),
    /// the support diagnostics zip, and a `report.md` summarizing app version,
    /// OS, sessions, recent boss decisions, and recent actions. Lands in a
    /// stable, timestamped folder under the app-support root so it's trivial to
    /// open — and for the boss/Claude to read.
    /// Submit the in-app Report a Bug form. The boss's `workbench_report_bug` path
    /// (`startReportBug`) reuses this same method (with an explicit note + source) so the
    /// boss-created bundle goes through the EXACT same `BugReportWriter` + redactor the
    /// human path uses — never a parallel, un-anonymized path.
    func submitBugReport(note explicitNote: String? = nil, source: String = "native") {
        guard !bugReportIsSubmitting else {
            return
        }
        bugReportIsSubmitting = true
        bugReportError = nil

        // Gather everything that needs the main actor / live window up front,
        // then do subprocess + file IO off-main.
        let note = explicitNote ?? bugReportNote
        let screenshotPNG = captureKeyWindowPNG()
        let sessions = bugReportSessions()
        let decisions = state.decisionLog
        let actions = state.actionLog
        let bossName = state.boss.agentName
        let bossWatchEnabled = state.bossWatchEnabled
        let autoAdvanceEnabled = bossAutoAdvanceEnabled
        let osVersion = Self.osVersionString()
        let buildHash = Self.buildHashString()
        // Anonymization inputs (#236): the real agent names, username, and home
        // path so the redactor can strip every identifying token from the report
        // BEFORE it touches disk. Agent names = all local agents + the selected
        // boss, deduped and non-empty.
        let redactor = WorkbenchBugReportRedactor()
        let agentNames = bugReportAgentNames()
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let username = NSUserName()
        let extraSections = bugReportExtraSections()
        // The folder name is derived from the note, which can itself carry a path
        // or username — redact the note first so the directory name can't leak.
        let directoryNote = redactor.redact(note, agentNames: agentNames, homePath: homePath, username: username)
        let directory = paths.bugReportsURL.appendingPathComponent(
            BugReportComposer.directoryName(date: Date(), note: directoryNote),
            isDirectory: true
        )
        let runner = SupportDiagnosticsRunner(resourceDirectory: Bundle.main.resourceURL)

        Task {
            let bundle = await Task.detached(priority: .userInitiated) { () -> Result<BugReportBundle, Error> in
                // Best-effort diagnostics: a failure becomes a warning in the
                // report rather than sinking the whole submission.
                var diagnosticsArchive: URL?
                var diagnosticsError: String?
                do {
                    diagnosticsArchive = try runner.run().archiveURL
                } catch {
                    diagnosticsError = error.localizedDescription
                }

                do {
                    let bundle = try BugReportWriter.write(
                        into: directory,
                        note: note,
                        appName: WorkbenchRelease.appName,
                        appVersion: WorkbenchRelease.version,
                        buildHash: buildHash,
                        osVersion: osVersion,
                        generatedAt: Date(),
                        bossName: bossName,
                        bossWatchEnabled: bossWatchEnabled,
                        autoAdvanceEnabled: autoAdvanceEnabled,
                        sessions: sessions,
                        recentDecisions: decisions,
                        recentActions: actions,
                        screenshotPNG: screenshotPNG,
                        diagnosticsArchiveURL: diagnosticsArchive,
                        diagnosticsError: diagnosticsError,
                        extraSections: extraSections,
                        redactor: redactor,
                        agentNames: agentNames,
                        homePath: homePath,
                        username: username
                    )
                    return .success(bundle)
                } catch {
                    return .failure(error)
                }
            }.value

            bugReportIsSubmitting = false
            switch bundle {
            case let .success(bundle):
                lastBugReportURL = bundle.directoryURL
                lastBugReportWarnings = bundle.warnings
                lastBugReportNote = note
                bugReportNote = ""
                // A new bundle invalidates any prior issue link.
                bugReportIssueURL = nil
                bugReportIssueError = nil
                // U30(a): persist the durable filed-status (unfiled, with the note + any
                // collection warnings) next to the bundle, so "was this filed? where?"
                // survives the sheet/app closing and a boss can read it back.
                try? bugReportStatusStore.write(
                    .unfiled(note: note, warnings: bundle.warnings),
                    into: bundle.directoryURL
                )
                recordActionLog(
                    source: source,
                    action: "submitBugReport",
                    result: "Wrote \(bundle.directoryURL.lastPathComponent) (unfiled)",
                    succeeded: true
                )
            case let .failure(error):
                bugReportError = error.localizedDescription
                recordActionLog(
                    source: source,
                    action: "submitBugReport",
                    result: "Failed: \(error.localizedDescription)",
                    succeeded: false
                )
            }
        }
    }

    func revealLastBugReport() {
        guard let lastBugReportURL else {
            revealBugReportsFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastBugReportURL])
    }

    func copyBugReportPath() {
        guard let lastBugReportURL else {
            return
        }
        copyToPasteboard(lastBugReportURL.path)
    }

    /// File the last bug report as a GitHub issue — a durable, searchable venue
    /// the boss/Claude can read from anywhere via `gh`. Uses `report.md` as the
    /// body (the screenshot + zip stay in the local bundle, referenced by path,
    /// since `gh issue create` can't upload them). Degrades gracefully when `gh`
    /// is missing or unauthenticated.
    func fileLastBugReportAsGitHubIssue() {
        guard !bugReportIssueIsFiling else {
            return
        }
        guard let directory = lastBugReportURL else {
            bugReportIssueError = "Create a bug report first."
            return
        }
        bugReportIssueIsFiling = true
        bugReportIssueError = nil
        bugReportIssueURL = nil

        let reportURL = directory.appendingPathComponent("report.md")
        let bundlePath = directory.path
        let note = lastBugReportNote
        let repo = WorkbenchRelease.issueRepo
        // report.md is already anonymized at write time; the title (from the note)
        // and the bundle-path footer are redacted here so the whole issue stays
        // clean from one source of truth (#236).
        let redactor = WorkbenchBugReportRedactor()
        let agentNames = bugReportAgentNames()
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let username = NSUserName()

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, GitHubIssueFilingError> in
                GitHubIssueFiler.file(
                    reportURL: reportURL,
                    bundlePath: bundlePath,
                    note: note,
                    repo: repo,
                    redactor: redactor,
                    agentNames: agentNames,
                    homePath: homePath,
                    username: username
                )
            }.value

            bugReportIssueIsFiling = false
            switch outcome {
            case let .success(url):
                bugReportIssueURL = url
                // U30(a): stamp the filed outcome (issue URL + time) into the bundle's
                // durable status, so the filed status survives the sheet closing and a
                // boss read can answer "filed? where?" — not just an action-log one-liner
                // that can roll off the bounded log.
                let priorNote = lastBugReportNote
                let existing = bugReportStatusStore.read(from: directory)
                    ?? .unfiled(note: priorNote, warnings: lastBugReportWarnings)
                try? bugReportStatusStore.write(
                    existing.markedFiled(issueURL: url, at: Date()),
                    into: directory
                )
                recordActionLog(
                    source: "native",
                    action: "fileBugReportIssue",
                    result: "Filed \(directory.lastPathComponent) as \(url)",
                    succeeded: true
                )
            case let .failure(error):
                bugReportIssueError = error.localizedDescription
                recordActionLog(
                    source: "native",
                    action: "fileBugReportIssue",
                    result: "Failed: \(error.localizedDescription)",
                    succeeded: false
                )
            }
        }
    }

    func openLastBugReportIssue() {
        guard let bugReportIssueURL, let url = URL(string: bugReportIssueURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealBugReportsFolder() {
        let folder = paths.bugReportsURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            errorMessage = "Bug reports folder could not be opened: \(error.localizedDescription)"
        }
    }

    /// Flatten the live workspace into render-ready report rows. Skips archived
    /// sessions; status comes from the latest run, attention/trust/friend from
    /// the entry, and the branch from the cached git status.
    private func bugReportSessions() -> [BugReportSession] {
        state.processEntries
            .filter { !$0.isArchived }
            .map { entry in
                BugReportSession(
                    name: entry.name,
                    status: latestRun(for: entry)?.status.rawValue ?? ProcessStatus.configured.rawValue,
                    attention: entry.attention.rawValue,
                    trust: entry.trust.rawValue,
                    friend: entry.friend?.name,
                    workingDirectory: entry.workingDirectory,
                    gitBranch: gitStatus(for: entry)?.branchLabel
                )
            }
    }

    /// Every agent name the redactor must scrub from the report (#236): all local
    /// agents plus the selected boss, deduped (case-insensitively) and stripped of
    /// blanks. Longer names are handled first inside the redactor, so order here is
    /// only about completeness, not precedence.
    func bugReportAgentNames() -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for raw in ouroAgents.map(\.name) + [state.boss.agentName] {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }
        return names
    }

    /// The U6 auto-attached context blocks layered on top of the existing report
    /// (#236): which screen the user was on and the live onboarding-readiness
    /// snapshot. Version + recent activity already live in the structured report
    /// fields, so they aren't duplicated here. Blank-bodied sections are dropped by
    /// the composer, so an absent readiness snapshot simply leaves no heading.
    func bugReportExtraSections() -> [WorkbenchBugReportSection] {
        var sections: [WorkbenchBugReportSection] = []

        let currentScreen: String
        if isOnboardingPresented {
            let readinessState = onboardingReadiness?.state.rawValue ?? "unknown"
            currentScreen = "Onboarding wizard (readiness: \(readinessState))"
        } else {
            currentScreen = "Main workspace"
        }
        sections.append(WorkbenchBugReportSection(title: "Current screen", body: currentScreen))

        if let readiness = onboardingReadiness {
            let rendered = OnboardingReadinessReportRenderer().render(readiness)
            sections.append(WorkbenchBugReportSection(title: "Readiness", body: rendered))
        }

        return sections
    }

    /// Snapshot the main app window into PNG data using the view's own backing
    /// store (`cacheDisplay`), which renders in-process and needs no
    /// screen-recording permission. Returns nil if there's no visible window.
    ///
    /// The Report a Bug sheet is itself a (key) window while open, so capturing
    /// `keyWindow` would screenshot the report form, not the app being reported
    /// on. Resolve through `sheetParent` so we always capture the window the
    /// sheet is attached to — the actual workbench state.
    private func captureKeyWindowPNG() -> Data? {
        let candidate = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        // Walk up any chain of attached sheets to the underlying app window.
        var window = candidate
        while let parent = window?.sheetParent {
            window = parent
        }
        guard let view = window?.contentView else {
            return nil
        }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func osVersionString() -> String {
        "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static func buildHashString() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    func refreshWorkspace() async {
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        refreshExecutableHealth()
        refreshOnboardingReadiness()
        await refreshBossDashboard()
        recordActionLog(
            source: "native",
            action: "refreshWorkspace",
            result: "Refreshed workspace status",
            succeeded: true
        )
    }

    func refreshOnboardingReadiness() {
        onboardingReadiness = onboardingAdvisor.readiness(
            boss: state.boss,
            agents: ouroAgents,
            mcpRegistration: bossWorkbenchMCPRegistration,
            providerChecks: onboardingProviderChecks
        )
    }

    func presentOnboarding() {
        // Snapshot the boss before the wizard can mutate it so an abandoned
        // mid-wizard pick rolls back on dismiss (#227).
        onboardingBossSnapshot = state.boss.agentName
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        // Discard any stale provider-check entries that aren't a confirmed
        // pass. `.running` entries get stuck when the sheet was dismissed
        // mid-check (so the lane keeps showing "Checking..." or "did not
        // finish" forever); `.failed` entries shouldn't pin the UI to a
        // repair prompt from a prior config that may have since been fixed.
        // Confirmed `.passed` results are kept so we don't waste cycles
        // re-running a check the user knows works.
        onboardingProviderChecks = onboardingProviderChecks.filter { _, result in
            result.state == .passed
        }
        refreshOnboardingReadiness()
        runOnboardingProviderChecksIfNeeded()
        isOnboardingPresented = true
    }

    func runOnboardingProviderChecksIfNeeded() {
        let selectedAgent = ouroAgents.first {
            $0.name.caseInsensitiveCompare(state.boss.agentName) == .orderedSame
        }
        guard let selectedAgent, selectedAgent.status == .ready else {
            return
        }
        // When both lanes resolve to the SAME provider+model (U1's lane collapse), the inner check
        // is redundant — readiness only surfaces the ONE outward connection step in that case, so
        // checking inner would spin a lane the user never sees. Run just outward; this also halves
        // the wait. When the lanes diverge, check both.
        let laneConfigurations: [(lane: String, configured: Bool)]
        if selectedAgent.lanesShareOneConnection {
            laneConfigurations = [
                ("outward", true)
            ]
            // Only the outward lane is checked in the collapsed case. Drop any stale `inner`
            // entry — a divergent→collapsed mid-session reconfigure can leave `inner == .running`
            // behind, and the Connect-page advance button is disabled while ANY check is
            // `.running` (it never sees the inner lane), so it would stay pinned disabled forever.
            onboardingProviderChecks["inner"] = nil
        } else {
            laneConfigurations = [
                ("outward", selectedAgent.humanFacing?.provider != nil && selectedAgent.humanFacing?.model != nil),
                ("inner", selectedAgent.agentFacing?.provider != nil && selectedAgent.agentFacing?.model != nil)
            ]
        }
        let agentName = selectedAgent.name
        // Collect the lanes that actually need a (re)check.
        var lanesToCheck: [String] = []
        for laneConfiguration in laneConfigurations where laneConfiguration.configured {
            let existingState = onboardingProviderChecks[laneConfiguration.lane]?.state
            guard existingState != .running, existingState != .passed else { continue }
            lanesToCheck.append(laneConfiguration.lane)
        }
        guard !lanesToCheck.isEmpty else { return }

        // Mark every pending lane running up front + stamp a per-lane generation so a
        // dismiss/cancel or a superseding run can't let a stale completion overwrite
        // freshly-cleaned state.
        var generations: [String: Int] = [:]
        for lane in lanesToCheck {
            onboardingProviderChecks[lane] = OnboardingProviderCheckResult(
                lane: lane,
                state: .running,
                detail: "Checking your agent's connection…"
            )
            let generation = (onboardingProviderCheckGeneration[lane] ?? 0) + 1
            onboardingProviderCheckGeneration[lane] = generation
            generations[lane] = generation
            onboardingProviderCheckTasks[lane]?.cancel()
        }
        refreshOnboardingReadiness()

        // Run the lane checks SEQUENTIALLY, not concurrently. `ouro check`'s credential
        // read contends on the single bitwarden vault lock (held by the ouro daemon), so
        // two concurrent checks starve each other past the watchdog and BOTH spuriously
        // fail — even when the providers are perfectly ready (observed: a lone check ~11s,
        // two at once time out). One at a time, each check acquires the lock cleanly. A
        // single shared task drives them in order; it's registered under each lane key so
        // a dismiss-cancel still cancels it.
        let serialTask = Task {
            for lane in lanesToCheck {
                guard !Task.isCancelled,
                      onboardingProviderCheckGeneration[lane] == generations[lane] else {
                    continue
                }
                let result = await runOnboardingProviderCheck(agentName: agentName, lane: lane)
                guard !Task.isCancelled,
                      onboardingProviderCheckGeneration[lane] == generations[lane] else {
                    continue
                }
                onboardingProviderChecks[lane] = result
                refreshOuroAgents()
                refreshWorkbenchMCPRegistration()
                refreshOnboardingReadiness()
            }
        }
        for lane in lanesToCheck {
            onboardingProviderCheckTasks[lane] = serialTask
        }
    }

    /// Cancel in-flight onboarding provider checks (called when the onboarding
    /// sheet dismisses). Bumping the generation also ensures any completion
    /// that races the cancel is discarded.
    func cancelOnboardingProviderChecks() {
        for (lane, task) in onboardingProviderCheckTasks {
            task.cancel()
            onboardingProviderCheckGeneration[lane, default: 0] += 1
        }
        onboardingProviderCheckTasks.removeAll()
    }

    /// Roll back a boss pick that the user made mid-wizard but abandoned by
    /// dismissing before genuinely completing onboarding (#227). Without this, a
    /// half-finished pick stays persisted on disk and, combined with the present-
    /// until-completed logic, would lock the user into re-opening the wizard with
    /// a boss they never confirmed. No-op once onboarding is completed, when no
    /// snapshot is in flight, or when the boss is unchanged from the snapshot.
    func rollbackOnboardingIfIncomplete() {
        guard !onboardingHasBeenCompleted,
              let snapshot = onboardingBossSnapshot,
              state.boss.agentName != snapshot else {
            return
        }
        state.boss.agentName = snapshot
        for index in state.projects.indices {
            state.projects[index].boss.agentName = snapshot
        }
        save()
        refreshOnboardingReadiness()
        onboardingBossSnapshot = nil
    }

    /// Run a live outward-lane `ouro check` for every config-ready agent with a configured
    /// outward lane, recording each F2-classified verdict so the steady-state rows can show an
    /// HONEST dot/label instead of the scanner's config-only false green.
    ///
    /// Non-blocking: the per-agent checks run concurrently in a detached `Task` + `TaskGroup`, so
    /// one slow / wedged agent can't stall the others or the UI. All `@Published` mutations
    /// (`agentChecksInFlight`, `agentOutwardVerdicts`) happen on the main actor. A `nil` probe
    /// result (couldn't confirm) leaves no verdict — the row degrades to "not verified", never a
    /// false green. Called at the end of `refreshOuroAgents()`, so it fires on launch AND on the
    /// "Refresh Agents" button.
    /// Re-run the outward-readiness overlay ONLY if it has gone stale, per the pure
    /// `AgentReadinessRefreshPolicy`. Both new idle-driver triggers — the scene-phase
    /// "became active" re-check (60s) and the periodic backstop (300s) — route through here
    /// so they share one debounce: a check that ran within `staleAfter` (or one already in
    /// flight, which stamped `lastOutwardReadinessCheckAt` at its start) is left alone, so the
    /// two paths can't double-fire and rapid app-switching can't hammer the daemon.
    func refreshOutwardReadinessIfStale(now: Date = Date(), staleAfter: TimeInterval) {
        guard AgentReadinessRefreshPolicy.shouldRefresh(
            lastCheckedAt: lastOutwardReadinessCheckAt,
            now: now,
            staleAfter: staleAfter
        ) else { return }
        refreshAgentOutwardReadiness()
    }

    func refreshAgentOutwardReadiness() {
        // Record freshness up front — BEFORE the target snapshot/guard and the TaskGroup. This
        // both timestamps this check (so the staleness guard knows when we last ran) AND debounces
        // concurrent triggers: a refresh already in flight has stamped this, so a near-simultaneous
        // scene-phase + periodic IfStale check sees it as fresh and won't duplicate the work.
        lastOutwardReadinessCheckAt = Date()
        // Snapshot, on the main actor, the agents worth probing: config-ready bundles whose
        // OUTWARD (humanFacing) lane is fully configured. A disabled / missing / invalid bundle
        // can't connect, and an unconfigured outward lane has nothing to check.
        let targets = ouroAgents.filter { agent in
            agent.status == .ready
                && agent.humanFacing?.provider != nil
                && agent.humanFacing?.model != nil
        }
        guard !targets.isEmpty else { return }

        let names = targets.map(\.name)
        // Mark every target in-flight up front so the rows immediately read "checking…" rather
        // than flickering through a stale "not verified".
        agentChecksInFlight.formUnion(names)

        Task { [weak self] in
            await withTaskGroup(of: (String, ProviderConnectionVerdict?).self) { group in
                for name in names {
                    group.addTask { [weak self] in
                        guard let self else { return (name, nil) }
                        let verdict = await self.runColdStartProviderCheck(agentName: name, lane: "outward")
                        return (name, verdict)
                    }
                }
                for await (name, verdict) in group {
                    guard let self else { continue }
                    // Store the verdict (or leave it absent on nil → "not verified") and clear the
                    // in-flight flag, both on the main actor.
                    if let verdict {
                        self.agentOutwardVerdicts[name] = verdict
                    }
                    self.agentChecksInFlight.remove(name)
                }
            }
        }
    }

    /// F1 — the post-hatch credential probe for a freshly cold-started agent. Runs `ouro check`
    /// for the configured lane and returns the F2-classified verdict, or `nil` when the probe
    /// times out / couldn't run.
    ///
    /// SHORT BUDGET (15s, vs. the onboarding check's 90s): this runs DURING agent creation, so a
    /// flaky-daemon hang must degrade to "couldn't confirm" fast rather than freeze the form. We
    /// deliberately do NOT use `ouro vault status` here — it HANGS under a flaky daemon (observed:
    /// never returned). `ouro check` is responsive and we already own its classifier. A nil verdict
    /// folds into `.failed(.couldNotConfirm)` (never a false green).
    private func runColdStartProviderCheck(agentName: String, lane: String) async -> ProviderConnectionVerdict? {
        await Task.detached(priority: .userInitiated) {
            guard let result = Self.runProviderCheckProcess(
                agentName: agentName,
                lane: lane,
                timeoutSeconds: 15
            ) else {
                return nil
            }
            // Past the budget the runner terminated the process — treat as "couldn't confirm"
            // (nil), NOT as a classified verdict from truncated output.
            guard !result.timedOut else { return nil }
            // Classify from the OUTPUT (never the exit code — `ouro check` exits 0 in every
            // state; that was the F2 bug). The classifier never false-greens.
            return ProviderCheckClassifier().classify(
                exitCode: result.terminationStatus,
                stdout: result.output,
                stderr: ""
            )
        }.value
    }

    private func runOnboardingProviderCheck(agentName: String, lane: String) async -> OnboardingProviderCheckResult {
        await Task.detached(priority: .userInitiated) {
            guard let result = Self.runProviderCheckProcess(
                agentName: agentName,
                lane: lane,
                timeoutSeconds: 90
            ) else {
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: "Workbench is still setting this up. It clears once your provider is connected."
                )
            }
            // Lane-agnostic copy: U1's repair-step TITLE now carries the connection identity
            // (provider · model + plain-English role), so these details no longer need the
            // opaque "main"/"background" lane label (#234).
            if result.timedOut {
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: "This is taking longer than usual. Try again, or reconnect your provider."
                )
            }
            // F2 FIX: `ouro check` exits 0 in EVERY state (working, vault-locked, 401,
            // network-down), so deriving readiness from `terminationStatus == 0` handed off
            // UNAUTHENTICATED bosses as green. Classify from the OUTPUT instead. ONLY a
            // `.working` verdict is `.passed`; every other verdict is `.failed` with a
            // distinct, seam-free detail (NEVER raw `ouro check` output — lane jargon,
            // provider IDs, or a `node`/PATH shell error read as gibberish to a new user; the
            // Connect step is the fix in every failure case, so the copy points there).
            let verdict = ProviderCheckClassifier().classify(
                exitCode: result.terminationStatus,
                stdout: result.output,
                stderr: ""
            )
            switch verdict {
            case .working:
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .passed,
                    detail: "This connection is working."
                )
            case .vaultLocked:
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: "Workbench couldn't unlock your saved credentials for this connection. "
                        + "Reconnect your provider to continue."
                )
            case .unauthorized:
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: "This connection's credentials were rejected. Reconnect your provider to continue."
                )
            case .unreachable:
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: "Workbench couldn't reach this connection's provider. "
                        + "Check your network, then try again."
                )
            case .indeterminate:
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: "Workbench couldn't confirm this connection yet. Try again, or reconnect your provider."
                )
            }
        }.value
    }

    func scanForOnboardingSessions() {
        guard !onboardingIsScanning else {
            return
        }
        guard onboardingReadiness?.isReady == true else {
            refreshOnboardingReadiness()
            runOnboardingProviderChecksIfNeeded()
            return
        }
        onboardingIsScanning = true
        onboardingImportSummaryHasImports = false
        let currentState = state
        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                let scanner = RecentSessionScanner()
                let discovered = scanner.scan()
                let existing = scanner.scanWorkbench(state: currentState)
                return discovered + existing
            }.value
            onboardingCandidates = candidates
            onboardingProposal = onboardingProposalBuilder.build(candidates: candidates)
            onboardingIsScanning = false
            recordActionLog(
                source: "native",
                action: "scanOnboardingSessions",
                result: "Found \(candidates.count) recent session candidates",
                succeeded: true
            )
        }
    }

    /// Slice 7 — onboarding hand-off. Instead of Workbench running the hardcoded
    /// `RecentSessionScanner` scan + arrange, hand the boss the reconstruction task and let
    /// it own the context-specific work: discover via `workbench_discover_agent_sessions`,
    /// optionally propose via the card, relaunch the approved sessions as terminals. The boss
    /// does which-agent / exact-resume-command intelligence; Workbench only provides the
    /// hand-off + the surfaces (this conversation + the proposal card) where the boss's work
    /// renders. This is the boss-driven replacement for `scanForOnboardingSessions()` /
    /// `applyOnboardingProposal()` as the wizard's import path — those remain for any other
    /// callers but the wizard no longer drives them.
    func startBossReconstruction() {
        guard onboardingReadiness?.isReady == true else {
            refreshOnboardingReadiness()
            runOnboardingProviderChecksIfNeeded()
            return
        }
        guard !bossCheckInIsRunning else {
            return
        }
        onboardingReconstructionHandedOff = true
        // The boss reads any operator-approved edits back through `workbench_proposal_result`;
        // refresh the pending list so a card the boss enqueues surfaces in the dashboard.
        loadPendingProposals()
        recordActionLog(
            source: "native",
            action: "startBossReconstruction",
            result: "Handed reconstruction to \(state.boss.agentName)",
            succeeded: true
        )
        Task {
            await runBossQuickQuestion(WorkbenchOnboardingNarrative.bossReconstructTask)
        }
    }

    // MARK: - Boss proposals (workbench_propose CAPABILITY — never a gate)

    /// Refresh the pending-proposal list from the queue. Pure read; safe to call
    /// whenever the operator opens the proposal surface. Best-effort — a malformed
    /// pending file is skipped by the queue, never surfaced as an error.
    func loadPendingProposals() {
        pendingProposals = proposalQueue.pendingProposals()
    }

    /// Flip an item's selection in the in-memory proposal (the card binds to
    /// `pendingProposals`). Nothing is written back until the operator approves.
    func toggleProposalItem(proposalID: String, itemID: String) {
        guard let index = pendingProposals.firstIndex(where: { $0.id == proposalID }) else { return }
        pendingProposals[index].toggle(itemID: itemID)
    }

    /// Edit one editable field of a proposal item in memory. The Core model
    /// rejects fields the boss didn't expose, so the card can offer inputs freely.
    func editProposalItem(proposalID: String, itemID: String, field: AgentProposalItem.Field, value: String) {
        guard let index = pendingProposals.firstIndex(where: { $0.id == proposalID }) else { return }
        pendingProposals[index].edit(itemID: itemID, field: field, value: value)
    }

    /// Approve a proposal: write the operator's `result()` (selected, edited items)
    /// back through the queue for the boss, drop it from pending, and refresh.
    func approveProposal(proposalID: String) {
        guard let proposal = pendingProposals.first(where: { $0.id == proposalID }) else { return }
        try? proposalQueue.writeResult(proposal.result())
        proposalQueue.removePending(id: proposalID)
        loadPendingProposals()
    }

    /// Dismiss a proposal without approving (the operator chose not to act on it).
    /// Writes an EMPTY result so the polling boss learns the operator declined,
    /// rather than waiting forever, then drops it from pending.
    func dismissProposal(proposalID: String) {
        try? proposalQueue.writeResult(AgentProposalResult(id: proposalID, items: []))
        proposalQueue.removePending(id: proposalID)
        loadPendingProposals()
    }

    @discardableResult
    func applyOnboardingProposal() -> WorkbenchImportApplyResult? {
        guard onboardingReadiness?.isReady == true else {
            refreshOnboardingReadiness()
            runOnboardingProviderChecksIfNeeded()
            return nil
        }
        guard let proposal = onboardingProposal else {
            scanForOnboardingSessions()
            return nil
        }
        var createdEntries: [ProcessEntry] = []
        var firstImportedProjectID: UUID?
        var importedGroupNames: [String] = []
        var skipped: [String] = []
        for group in proposal.groups {
            let project = ensureProject(for: group)
            firstImportedProjectID = firstImportedProjectID ?? project.id
            var groupCreated = false
            for terminal in group.terminals where terminal.selectedByDefault {
                guard !state.processEntries.contains(where: { $0.name == terminal.name && $0.projectId == project.id }) else {
                    continue
                }
                let draft = CustomTerminalSessionDraft(
                    name: terminal.name,
                    command: terminal.candidate.resumeCommandLine,
                    workingDirectory: terminal.candidate.workingDirectory,
                    trust: .trusted,
                    autoResume: true,
                    notes: onboardingNotes(for: terminal)
                )
                do {
                    let entry = try customSessionFactory.makeEntry(projectId: project.id, draft: draft)
                    state.processEntries.append(entry)
                    createdEntries.append(entry)
                    groupCreated = true
                } catch {
                    skipped.append(terminal.name)
                    recordActionLog(
                        source: "native",
                        action: "applyOnboardingProposal",
                        result: "Skipped \(terminal.name): \(error.localizedDescription)",
                        succeeded: false
                    )
                }
            }
            if groupCreated {
                importedGroupNames.append(group.name)
            }
        }

        selectedProjectID = firstImportedProjectID ?? state.projects.first?.id
        selectedEntryID = createdEntries.first?.id ?? selectedEntryID
        // Gate the green success on the durable write actually landing — a
        // swallowed write failure used to surface as a false-green onboarding
        // import that's lost on quit.
        let persisted = save()
        refreshExecutableHealth()
        for entry in createdEntries {
            launch(entry)
        }
        let saveNote = persisted ? "" : " (not saved to disk — will be lost on quit)"
        recordActionLog(
            source: "native",
            action: "applyOnboardingProposal",
            result: "Created \(createdEntries.count) terminals\(saveNote)",
            succeeded: persisted
        )
        let result = WorkbenchImportApplyResult(
            createdCount: createdEntries.count,
            groupNames: importedGroupNames,
            skippedNames: skipped,
            firstSelectedEntryID: createdEntries.first?.id,
            persisted: persisted
        )
        onboardingImportSummaryHasImports = result.hasImports
        lastImportSummary = result
        return result
    }

    func openOnboardingRepair(_ step: OnboardingRepairStep) {
        // Provider-setup steps open the NATIVE provider form (the one human gate) — never a
        // `ouro connect providers` `.trusted` pane. That interactive pane was the TTFA violation
        // R3 deleted: the human is never handed a CLI, not even in an app-opened pane. The
        // cold-start gate (`request-provider-config`) carries no command at all; the existing-
        // agent lane-completion steps (`outward-lane` / `inner-lane`) still carry an audit-lane
        // command in Core, but here they route to the native form — where an existing agent's
        // Connect now drives a real credential rotation (F6) in a native TTY rather than spawning a
        // pane or dead-ending on a gap-a "not available" message.
        if step.isProviderSetup {
            presentProviderConfigForm(agentName: onboardingReadiness?.selectedBossName ?? state.boss.agentName)
            return
        }
        // R4b — every remaining repair step is APP-EXECUTED (no spawned CLI pane). The Setup
        // Assistant never hands raw `ouro …` to the human. The last human-as-hands panes
        // (`repair-agent-config` → `AgentRepairRunner`; `check-outward` / `check-inner` →
        // `ProviderVerifyRunner`) run headlessly through the same recovery-truth runners the
        // agent-driven onboarding actions use, surfacing a seam-free line into Applied Actions.
        runOnboardingRepairStepNatively(step)
    }

    func deskBridgePlan(for kind: TerminalAgentKind) -> DeskBridgePlan? {
        deskBridgePlanner.plan(agentName: state.boss.agentName, terminalKind: kind)
    }

    func openDeskBridgeSetup(_ bridge: DeskBridgePlan) {
        guard let commandLine = bridge.commandLine else {
            errorMessage = bridge.detail
            return
        }
        let draft = CustomTerminalSessionDraft(
            name: "Desk Bridge: \(bridge.terminalKind.rawValue)",
            command: commandLine,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            trust: .trusted,
            autoResume: false,
            notes: bridge.detail
        )
        _ = createCustomSession(draft, launchAfterCreate: true)
    }

    private func ensureProject(for group: ProposedWorkbenchGroup) -> WorkbenchProject {
        if let existing = state.projects.first(where: { $0.rootPath == group.rootPath || $0.name == group.name }) {
            return existing
        }
        let project = WorkbenchProject(
            name: group.name,
            rootPath: group.rootPath,
            boss: state.boss
        )
        state.projects.append(project)
        return project
    }

    private func onboardingNotes(for terminal: ProposedTerminalImport) -> String {
        let candidate = terminal.candidate
        var lines = [
            "Imported by Workbench onboarding.",
            "Source: \(candidate.source.rawValue)",
            "Confidence: \(Int(candidate.confidence * 100))%",
            "Summary: \(candidate.summary)"
        ]
        if !candidate.evidencePaths.isEmpty {
            lines.append("Evidence: \(candidate.evidencePaths.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Dispatch a command palette item with full payload support. Routes
    /// payload-bearing commands (e.g. per-agent select / repair) through this
    /// path and falls back to the ID-only dispatcher for the rest.
    /// Run the command stashed by the ⌘K palette, if any. Called from the
    /// palette sheet's `.onDisappear` so any sheet the command opens presents
    /// cleanly after the palette is gone.
    func performPendingPaletteCommand() {
        guard let pending = pendingPaletteCommand else { return }
        pendingPaletteCommand = nil
        performCommand(pending)
    }

    func performCommand(_ descriptor: WorkbenchCommandDescriptor) {
        switch descriptor.id {
        case .selectAgent:
            selectAgent(descriptor.payload)
        case .useSelectedAgentAsBoss:
            if let name = descriptor.payload ?? selectedAgentName {
                selectBoss(agentName: name)
            } else {
                errorMessage = "No agent is selected"
            }
        case .openSelectedAgentConfig:
            if let agent = focusedAgentForCommand(descriptor.payload) {
                openAgentConfig(agent)
            } else {
                errorMessage = "No agent is selected"
            }
        case .revealSelectedAgentBundle:
            if let agent = focusedAgentForCommand(descriptor.payload) {
                revealAgentBundle(agent)
            } else {
                errorMessage = "No agent is selected"
            }
        case .repairSelectedAgent:
            if let agent = focusedAgentForCommand(descriptor.payload) {
                repairAgent(agent)
            } else {
                errorMessage = "No agent is selected"
            }
        case .installMCPForSelectedAgent:
            if let agent = focusedAgentForCommand(descriptor.payload) {
                installWorkbenchMCP(for: agent)
            } else {
                errorMessage = "No agent is selected"
            }
        case .manageAgents:
            selectAgent(descriptor.payload ?? selectedAgentName ?? state.boss.agentName)
        default:
            performCommand(descriptor.id)
        }
    }

    /// Resolve which agent a payload-bearing command should act on. Prefers
    /// the explicit payload, falls back to the currently-focused agent, then
    /// to the boss agent if it is installed.
    private func focusedAgentForCommand(_ payload: String?) -> OuroAgentRecord? {
        if let payload, let agent = ouroAgent(named: payload) {
            return agent
        }
        if let name = selectedAgentName, let agent = ouroAgent(named: name) {
            return agent
        }
        return ouroAgent(named: state.boss.agentName)
    }

    func performCommand(_ command: WorkbenchCommandID) {
        switch command {
        case .newSession:
            isNewSessionSheetPresented = true
        case .bossCheckIn:
            // U12: route through the shared affordance so a no-boss palette
            // invocation opens set-up rather than silently no-opping.
            attemptCheckIn()
        case .bossQuickWhatsGoingOn:
            Task {
                await runBossQuickQuestion("What's going on?")
            }
        case .bossQuickWaitingOnMe:
            Task {
                await runBossQuickQuestion("Is anything waiting on me?")
            }
        case .bossQuickKeepMoving:
            Task {
                await runBossQuickQuestion("Keep trusted work moving. If there is an obvious safe next step, take it through Workbench actions.")
            }
        case .bossQuickRespondForMe:
            Task {
                await runBossQuickQuestion("Respond for me where appropriate. Tell me what you did or what draft response you recommend.")
            }
        case .toggleBossWatch:
            setBossWatchEnabled(!bossWatchIsEnabled)
        case .toggleBossPane:
            setBossPaneCollapsed(!state.bossPaneCollapsed)
        case .openOnboarding:
            presentOnboarding()
        case .installOuroAgent:
            // U18: the command-palette create action opens the native form, not the
            // raw `ouro hatch` CLI pane.
            presentNewAgentProviderConfigForm()
        case .refreshWorkspace:
            Task {
                await refreshWorkspace()
            }
        case .refreshOuroAgents:
            refreshOuroAgents()
            recordActionLog(
                source: "native",
                action: "refreshOuroAgents",
                result: "Refreshed local Ouro agents",
                succeeded: true
            )
        case .refreshWorkbenchMCP:
            refreshWorkbenchMCPRegistration()
            recordActionLog(
                source: "native",
                action: "refreshWorkbenchMCP",
                result: "Refreshed Workbench MCP registration",
                succeeded: true
            )
        case .installWorkbenchMCPForBoss:
            installWorkbenchMCPForBoss()
        case .launchSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            launch(selectedEntry)
        case .askBossAboutSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            Task {
                await runBossQuestion(about: selectedEntry)
            }
        case .focusSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            focusTerminal(selectedEntry)
        case .redrawSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            redrawTerminal(selectedEntry)
        case .sendControlCToSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            sendControlC(to: selectedEntry)
        case .sendEscapeToSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            sendEscape(to: selectedEntry)
        case .sendEOFToSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            sendEOF(to: selectedEntry)
        case .copySelectedLaunchCommand:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            copyLaunchCommand(for: selectedEntry)
        case .openSelectedWorkingDirectory:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            openWorkingDirectory(for: selectedEntry)
        case .revealSelectedTranscript:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            revealLatestTranscript(for: selectedEntry)
        case .stopSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            // U11: the menubar/palette Stop honors the same consequence gate.
            requestStop(selectedEntry)
        case .recoverSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            recover(selectedEntry)
        case .searchTranscripts:
            setBossPaneCollapsed(false)
            // Expand Advanced + focus the field so an empty query isn't a no-op;
            // run the search when there's already a query to run.
            transcriptSearchFocusToken += 1
            if !transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchTranscripts()
            }
        case .runRecoveryDrill:
            runRecoveryDrill()
        case .collectSupportDiagnostics:
            collectSupportDiagnostics()
        case .revealSupportDiagnostics:
            revealSupportDiagnostics()
        case .copySupportDiagnosticsPath:
            copySupportDiagnosticsPath()
        case .openSupportDiagnosticsFolder:
            openSupportDiagnosticsFolder()
        case .reportBug:
            isReportBugPresented = true
        case .fileBugReportIssue:
            fileLastBugReportAsGitHubIssue()
        case .revealBugReportsFolder:
            revealBugReportsFolder()
        case .checkReleaseUpdates:
            Task {
                await checkForUpdatesAndPromptInstall()
            }
        case .openReleaseUpdate:
            openReleaseUpdate()
        case .manageAgents:
            selectAgent(selectedAgentName ?? state.boss.agentName)
        case .showKeyboardShortcutHelp:
            isShortcutHelpPresented = true
        case .openWorkspaceConfig:
            presentOpenWorkspacePanel()
        case .saveWorkspaceConfig:
            presentSaveWorkspacePanel()
        case .openSettings:
            isSettingsSheetPresented = true
        case .openAbout:
            isAboutSheetPresented = true
        case .openHarnessStatus:
            isHarnessStatusPresented = true
        case .openDecisionLog:
            isDecisionLogPresented = true
        case .stopAllRunningSessions:
            stopAllRunningSessions()
        case .recoverAllCrashedSessions:
            recoverAllCrashedSessions()
        case .resetToFirstRun:
            isResetFirstRunConfirmationPresented = true
        case .selectAgent,
             .useSelectedAgentAsBoss,
             .openSelectedAgentConfig,
             .revealSelectedAgentBundle,
             .repairSelectedAgent,
             .installMCPForSelectedAgent:
            // These commands carry a payload and must be dispatched through
            // performCommand(_: descriptor). If they reach here without a
            // payload-aware dispatch, fall back to the currently-focused agent.
            performCommand(WorkbenchCommandDescriptor(
                id: command,
                title: "",
                detail: "",
                systemImage: "",
                payload: selectedAgentName
            ))
        }
    }

    func refreshBossDashboard() async {
        async let machineResult = fetchResult(.machine, as: MailboxMachineView.self, label: "machine")
        async let needsMeResult = fetchResult(.needsMe(state.boss.agentName), as: MailboxNeedsMeView.self, label: "needs-me")
        async let codingResult = fetchResult(.coding(state.boss.agentName), as: MailboxCodingSummary.self, label: "coding")
        async let habitHistoryResult = fetchResult(.habitRunSummaries(state.boss.agentName, limit: 5), as: MailboxHabitSessionSummaryView.self, label: "habit-history")

        let (machine, needsMe, coding, habitHistory) = await (machineResult, needsMeResult, codingResult, habitHistoryResult)
        let issues = [machine.issue, needsMe.issue, coding.issue, habitHistory.issue].compactMap(\.self)

        let snapshot = bossDashboardBuilder.build(
            boss: state.boss,
            machine: machine.value,
            needsMe: needsMe.value,
            coding: coding.value,
            habitHistory: habitHistory.value,
            availability: .mailbox(
                machineIssue: machine.issue,
                needsMeIssue: needsMe.issue,
                codingIssue: coding.issue,
                habitHistoryIssue: habitHistory.issue
            )
        )
        let previousDashboard = bossDashboard
        bossDashboard = snapshot
        mailboxError = issues.isEmpty ? nil : "Mailbox warnings: \(issues.joined(separator: "; "))"
        notifyAboutNewNeedsMeItems(previous: previousDashboard, current: snapshot)
        await refreshWorkbenchVisibility()
    }

    func refreshWorkbenchVisibility() async {
        let snapshotState = state
        let agentName = snapshotState.boss.agentName
        let reader = workCardReader
        let workCard = await Task.detached(priority: .utility) {
            reader.read(agent: agentName)
        }.value
        workbenchVisibility = visibilityBuilder.build(
            state: snapshotState,
            workCard: workCard,
            // #U28: feed the live screen survival signal so the recovery breakdown
            // classifies reattaches the same way the rest of recovery does.
            liveSessionNames: liveScreenSessionNames
        )
    }

    /// IDs of needs-me items we've already notified the user about. We never
    /// notify on the very first dashboard refresh of a process — otherwise
    /// every launch dumps the entire stale backlog as banners.
    private var seenNeedsMeIDs: Set<String> = []
    private var seenNeedsMeBaselineEstablished = false

    /// Detect newly-arrived needs-me items and post a macOS user notification
    /// so the user can leave Workbench in the background and trust it to
    /// ping them when something needs human input. Only runs while Boss Watch
    /// is enabled — without Watch the user isn't in autonomous mode and
    /// notifications would be unsolicited.
    private func notifyAboutNewNeedsMeItems(
        previous: BossDashboardSnapshot?,
        current: BossDashboardSnapshot?
    ) {
        guard bossWatchIsEnabled else {
            // Reset the baseline when Watch is off so a re-enable starts fresh.
            seenNeedsMeIDs = []
            seenNeedsMeBaselineEstablished = false
            return
        }
        guard let current, current.availability.needsMeAvailable else {
            return
        }
        let currentIDs = Set(current.needsMeItems.map(\.id))
        // First successful refresh after Watch turns on: mark every existing
        // item as seen so we don't blast notifications for prior backlog.
        guard seenNeedsMeBaselineEstablished else {
            seenNeedsMeIDs = currentIDs
            seenNeedsMeBaselineEstablished = true
            return
        }
        let newItems = current.needsMeItems.filter { !seenNeedsMeIDs.contains($0.id) }
        seenNeedsMeIDs = currentIDs
        guard !newItems.isEmpty else {
            return
        }
        postNeedsMeNotification(for: newItems, total: current.needsMeItems.count)
    }

    private func postNeedsMeNotification(
        for newItems: [MailboxNeedsMeItem],
        total: Int
    ) {
        // Compose primitives outside the closure; UNNotificationRequest isn't
        // Sendable so we build the request inside the auth callback.
        let bossName = state.boss.agentName
        let title: String
        let body: String
        if newItems.count == 1, let item = newItems.first {
            title = "Needs you: \(item.label)"
            body = item.detail.isEmpty ? "\(bossName) flagged something for you." : item.detail
        } else {
            title = "\(newItems.count) items need you"
            body = newItems.prefix(3).map(\.label).joined(separator: " · ")
        }
        let subtitle = total > newItems.count
            ? "\(total) total waiting on you"
            : ""
        let identifier = "ouro.workbench.needsme.\(UUID().uuidString)"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if !subtitle.isEmpty {
                content.subtitle = subtitle
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    func prepareBossCheckIn(
        question: String? = nil,
        recentChanges: [WorkspaceChangeSummary] = []
    ) {
        let question = question ?? bossBridgePlanner.checkInQuestion()
        bossCheckInPrompt = bossPromptBuilder.checkInTrigger(question: question, summary: summary)
    }

    func runBossCheckIn() async {
        setBossPaneCollapsed(false)
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(), recentChanges: [])
    }

    func runBossQuestion() async {
        let question = bossQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return
        }
        setBossPaneCollapsed(false)
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(userQuestion: question), recentChanges: [])
    }

    func runBossQuickQuestion(_ question: String) async {
        let resolved = question.replacingOccurrences(of: "{{owner}}", with: ownerDisplayName)
        bossQuestion = resolved
        setBossPaneCollapsed(false)
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(userQuestion: resolved), recentChanges: [])
    }

    func runBossQuestion(about entry: ProcessEntry) async {
        let shortQuestion = "What is going on with \(entry.name)?"
        bossQuestion = shortQuestion
        setBossPaneCollapsed(false)
        let question = """
        Focus on \(entry.name) (id=\(entry.id.uuidString)). Tell \(ownerDisplayName) what this session is doing, whether it is waiting on them, and what should happen next. If the next step is obvious for a trusted session, use auditable Workbench actions.
        """
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(userQuestion: question), recentChanges: [])
    }

    /// One automatic-loop check-in FAILURE: bump the consecutive-failure count and arm
    /// `bossWatchNextRetryAt` via the pure `BossWatchBackoff.registerFailure` seam. BOTH the
    /// daemon-down early-return AND the transport/empty catch path call this, so the backoff
    /// escalation can't drift between them. (F8 — the daemon-down path previously bailed WITHOUT
    /// arming the retry, so a dead daemon hot-looped every poll forever.) A *manual* check-in is
    /// never gated by the backoff; only the automatic loop/event triggers consult `mayAttempt`.
    private func registerBossWatchFailure(auditDetail: String) {
        let result = BossWatchBackoff.registerFailure(
            consecutiveFailures: bossWatchConsecutiveFailures,
            now: Date()
        )
        bossWatchConsecutiveFailures = result.consecutiveFailures
        bossWatchNextRetryAt = result.nextRetryAt
        if bossWatchIsEnabled {
            bossWatchLastError = auditDetail
        }
    }

    private func runBossCheckIn(
        question: String,
        recentChanges: [WorkspaceChangeSummary]
    ) async {
        guard !bossCheckInIsRunning else {
            return
        }
        // No boss resolved yet (fresh / factory-reset machine, or >1 agent awaiting
        // an explicit choice). There's no agent to check in with — skip rather than
        // spawn `ouro mcp-serve --agent ""`, which would fail and trip the watch
        // backoff while the human is still on the boss-choice screen. Every check-in
        // entry point (manual, questions, the watch tick) funnels through here.
        guard !state.boss.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let requestedBoss = state.boss.agentName
        bossCheckInIsRunning = true
        bossCheckInAnswer = nil
        defer {
            bossCheckInIsRunning = false
        }
        refreshExecutableHealth()

        // Workbench manages the daemon as invisible infrastructure: detect-reuse-else-start
        // BEFORE asking the agent. The mailbox overview collapses to "unknown" when the
        // daemon is down, so we run a
        // dedicated liveness probe + detached start here. Recovery truth comes from the
        // POST-start verify probe, never an exit code. If the agent genuinely can't be
        // brought online, surface an honest, seam-free line instead of asking a dead daemon;
        // the precise CLI-level detail stays in the audit log + debug surface only.
        let daemonOutcome = await daemonManager.ensureRunning()
        recordActionLog(
            source: "boss:\(requestedBoss)",
            action: "ensureDaemon",
            targetName: requestedBoss,
            result: daemonOutcome.auditDetail,
            succeeded: !daemonOutcome.needsManualRecovery
        )
        if let startupLine = daemonOutcome.humanFacingStartupLine {
            bossCheckInAnswer = startupLine
        }
        if daemonOutcome.needsManualRecovery {
            bossAppliedActions = []
            // F8 — a dead/unrecoverable daemon is a genuine automatic-loop FAILURE: bump the
            // backoff (arming bossWatchNextRetryAt) so runBossWatchTick's mayAttempt gate defers
            // the next tick, instead of hot-looping `ouro mcp-serve` every poll forever. Routes
            // through the SAME helper as the catch path so the two escalations can't drift.
            registerBossWatchFailure(auditDetail: daemonOutcome.auditDetail)
            return
        }
        guard state.boss.agentName == requestedBoss else {
            return
        }
        await refreshBossDashboard()
        guard state.boss.agentName == requestedBoss else {
            return
        }

        prepareBossCheckIn(question: question, recentChanges: recentChanges)
        guard let bossCheckInPrompt else {
            return
        }
        do {
            // Reasoning-model bosses intermittently return an empty final
            // answer; one fresh retry almost always succeeds, so a transient
            // empty no longer fails the check-in and trips Boss Watch backoff.
            //
            // BUT a reasoning boss may emit an empty FINAL reply *after* it
            // already called its Workbench MCP tools during that turn — e.g.
            // `workbench_request_action`, which enqueues a request file. A fresh
            // retry would run another turn that re-enqueues the same actions.
            // The core queue de-dups identical pending requests, but as
            // defense-in-depth we also refuse to retry an empty turn that grew
            // the queue: snapshot the pending depth before the ask and only
            // retry when the turn queued nothing.
            let queueDepthBeforeAsk = externalActionQueue.pendingCount()
            // Re-read the depth through a fresh queue built from the directory
            // URL (a Sendable value), mirroring the off-main drain, so this
            // guard crosses the isolation boundary without capturing the
            // non-Sendable queue instance.
            let actionRequestsURL = externalActionQueue.directoryURL
            let answer = try await BossAgentMCPClient.retryingOnEmpty(
                canRetry: {
                    WorkbenchActionRequestQueue(directoryURL: actionRequestsURL)
                        .pendingCount() <= queueDepthBeforeAsk
                }
            ) {
                try await bossMCPClient.ask(
                    agentName: requestedBoss,
                    question: bossCheckInPrompt
                )
            }
            guard state.boss.agentName == requestedBoss else {
                return
            }
            bossCheckInAnswer = answer
            // F12a gap 3a — persist the boss's prose. `bossCheckInAnswer` is a
            // transient @Published the next tick overwrites, so without this the
            // operator's record of what the boss SAID is lost. Only the SUCCESS
            // path records (the catch's product-voice fallback line is not prose);
            // gated on a non-empty answer so an empty turn doesn't persist noise.
            // Routed through the model's `save()` (which already suppresses
            // isLoadingState / isResettingToFirstRun), not a bespoke write.
            if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.recordProse(BossProseEntry(source: "boss:\(requestedBoss)", text: answer))
                save()
            }
            // FIX3 — a single check-in applies actions + records decisions, then
            // save()s ONCE. `applyBossActions` (per action → recordActionLog) and
            // `recordBossDecisions` each used to save() independently, so a crash
            // mid-check-in (or a zero-change decisions batch) could leave executed
            // actions WITHOUT their decision/audit rows. Wrapping both in
            // `withBatchedSave` suppresses the per-step saves and flushes one
            // trailing save() so the action-log rows + decision/inbox rows persist
            // atomically together.
            withBatchedSave {
                applyBossActions(from: answer)
                recordBossDecisions(from: answer)
            }
            // F12a gap 3b — after recording the boss's own decisions, escalate any
            // waiting session the boss DIDN'T decide on, so it can't fall silently
            // out of triage.
            reconcileWaitingSessionsIntoInbox()
            bossWatchLastError = nil
            // Boss responded — clear any backoff so the automatic loop resumes
            // its normal cadence immediately.
            bossWatchConsecutiveFailures = 0
            bossWatchNextRetryAt = nil
        } catch {
            // Product voice only — never leak the raw transport/CLI error to the human.
            // The precise detail stays in the audit/debug surface (`bossWatchLastError`).
            // FIX 2: the failure line must not promise an auto-retry that won't happen.
            // With Boss Watch OFF nothing retries (the only retry driver is
            // runBossWatchLoop), so the copy tells the operator to press Check In; with
            // Watch ON the truthful "will try again" copy is kept. Pure seam.
            bossCheckInAnswer = BossCheckInFailureCopy.failureLine(
                failureCount: bossWatchConsecutiveFailures,
                bossWatchIsEnabled: bossWatchIsEnabled
            )
            bossAppliedActions = []
            // F8 — route through the SAME shared helper as the daemon-down early-return so the
            // backoff bump (count + nextRetryAt) is computed in exactly one place and can't drift.
            registerBossWatchFailure(auditDetail: error.localizedDescription)
        }
    }

    func applyBossActions(from answer: String) {
        do {
            let actions = try bossActionParser.parse(answer)
            bossAppliedActions = actions.map { action in
                applyBossAction(action, source: "boss:\(state.boss.agentName)")
            }
        } catch {
            bossAppliedActions = ["Failed to parse boss actions: \(error)"]
        }
    }

    /// Record the boss's decisions about waiting sessions into the durable
    /// decision log AND, for an `autoAdvance` that clears the defense-in-depth
    /// gate (`resolveAutoAdvanceOutcome`), send the proposed input to the live
    /// session. Every decision — sent, blocked, escalated, or held — is logged
    /// with its reason for audit. Deduped per session so repeated Boss Watch
    /// ticks over a still-waiting prompt don't flood the log or re-send input.
    func recordBossDecisions(from answer: String) {
        let inputs = (try? bossDecisionParser.parse(answer)) ?? []
        guard !inputs.isEmpty else {
            return
        }
        let machineOwner = SessionFriend.machineOwner()
        for input in inputs {
            let entry = input.entry.flatMap { processEntry(matching: $0) }
            let friend = entry.flatMap { state.effectiveFriend(for: $0, fallback: machineOwner) }
            // Canonical prompt = the session's live waiting prompt (transcript
            // tail), the SAME source the actions channel keys on, so a reply that
            // emits both a sendInput action and an autoAdvance decision for this
            // entry shares one dedup key and the keystroke is sent at most once.
            // Fall back to the boss's quoted prompt / last summary when there's
            // no live transcript (e.g. an entry that isn't running). Capped so a
            // verbose reply can't bloat the saved workspace state.
            let livePrompt = entry.map { bossActionLivePrompt(for: $0) } ?? ""
            let prompt = String((livePrompt.isEmpty ? (input.prompt ?? entry?.lastSummary ?? "") : livePrompt).prefix(2000))
            // Idempotency: never act on (or re-log) a prompt we already decided.
            guard state.isNewDecision(entryId: entry?.id, prompt: prompt, kind: input.kind) else {
                continue
            }

            var reasoning = String((input.reasoning ?? "").prefix(2000))
            // Preserve the boss's own quoted prompt for the audit trail when it
            // differs from the live terminal text we keyed/classified on.
            if let quoted = input.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !quoted.isEmpty,
               quoted != prompt {
                let note = "[boss-quoted prompt: \(String(quoted.prefix(500)))]"
                reasoning += reasoning.isEmpty ? note : " \(note)"
            }

            // Execute only a fresh autoAdvance that clears the full gate; every
            // other case is recorded as the boss's judgment without acting. The
            // gate re-checks the *live* session (still running + still waiting)
            // so a prompt that changed during the boss round-trip is never
            // answered blindly. The execute/status/reason decision is the pure,
            // tested resolveAutoAdvanceOutcome.
            let gate: AutoAdvanceGate
            if input.kind == .autoAdvance, let entry {
                let live = state.processEntries.first(where: { $0.id == entry.id })
                gate = evaluateAutoAdvanceGate(
                    enabled: bossAutoAdvanceEnabled,
                    sessionRunning: activeSessions[entry.id] != nil,
                    sessionWaiting: (live ?? entry).attention == .waitingOnHuman,
                    sessionTrusted: (live ?? entry).trust == .trusted,
                    friend: friend,
                    prompt: prompt,
                    proposedInput: input.proposedInput
                )
            } else {
                gate = .block("not an auto-advance")
            }
            let outcome = resolveAutoAdvanceOutcome(kind: input.kind, gate: gate)
            if outcome.execute, let entry {
                sendInput(input.proposedInput ?? "", to: entry, appendNewline: true)
            }
            if !outcome.reasoningNote.isEmpty {
                reasoning += reasoning.isEmpty ? "" : " "
                reasoning += outcome.reasoningNote
            }
            let status = outcome.status

            state.recordDecision(
                BossInboxDecision(
                    source: "boss:\(state.boss.agentName)",
                    entryId: entry?.id,
                    sessionName: entry?.name,
                    friendName: friend?.name,
                    friendId: friend?.id,
                    prompt: prompt,
                    kind: input.kind,
                    proposedInput: input.proposedInput.map { String($0.prefix(500)) },
                    preferenceCited: input.preferenceCited.map { String($0.prefix(500)) },
                    confidence: input.confidence,
                    reasoning: reasoning,
                    status: status
                )
            )
        }
        // FIX3 — no inline save() here anymore. This runs INSIDE the single
        // check-in's `withBatchedSave` scope (the only caller), which performs one
        // trailing save() so these decision/inbox rows persist atomically with the
        // action-log rows `applyBossActions` just wrote. (The decisions are recorded
        // into in-memory state via `recordDecision`; the batch flush is what makes
        // them durable — together with the actions, never apart.)
    }

    /// F12a gap 3b — escalate any waiting-on-human session the boss DIDN'T already
    /// triage, so it can't fall silently out of the inbox. A waiting session enters
    /// the inbox only via a boss decision; if the boss emitted no decisions block
    /// (or a decision whose entry couldn't be resolved), the session was stranded.
    /// The pure `WaitingSessionReconciler` finds the uncovered waiting ids against
    /// the LIVE entries + the open inbox; each is recorded as a synthesized
    /// `.escalate` via `recordDecisionIfNew` — the prompt+kind dedup that prevents
    /// re-escalating a still-waiting session every tick (inbox flooding). Saves only
    /// when something was added, and rides the model's `save()` (which already
    /// suppresses isLoadingState / isResettingToFirstRun), so a startup reconcile
    /// can't fire a premature save during a lossy load.
    func reconcileWaitingSessionsIntoInbox() {
        let untriaged = WaitingSessionReconciler.untriagedWaitingEntryIds(
            entries: state.processEntries,
            openInbox: state.openInbox()
        )
        guard !untriaged.isEmpty else {
            return
        }
        var changed = 0
        for entryId in untriaged {
            guard let entry = state.processEntries.first(where: { $0.id == entryId }) else {
                continue
            }
            let prompt = String((bossActionLivePrompt(for: entry).isEmpty
                ? (entry.attentionReason ?? entry.lastSummary ?? "Waiting on you")
                : bossActionLivePrompt(for: entry)).prefix(2000))
            let recorded = state.recordDecisionIfNew(
                BossInboxDecision(
                    source: "workbench:reconcile",
                    entryId: entry.id,
                    sessionName: entry.name,
                    prompt: prompt,
                    kind: .escalate,
                    reasoning: "Waiting on a human with no boss decision yet — surfaced for triage."
                )
            )
            if recorded {
                changed += 1
            }
        }
        if changed > 0 {
            save()
        }
    }

    /// The learning loop: tell the boss to remember a standing preference for a
    /// decision's friend, so future inbox decisions improve. `autoAdvance == true`
    /// reinforces ("do this automatically next time"); `false` corrects ("always
    /// ask me"). The boss owns its memory, so this hands it a directive to persist
    /// via its own notes tools (same conversation plane as check-ins). Both the
    /// request and the boss's acknowledgement are written to the action log.
    func teachBoss(from decision: BossInboxDecision, autoAdvance: Bool) async {
        let teaching = FriendPreferenceTeaching.reinforcement(for: decision, autoAdvance: autoAdvance)
        let agent = state.boss.agentName
        recordActionLog(
            source: "operator",
            action: "teachBoss",
            targetName: teaching.friendName,
            result: teaching.preference,
            succeeded: true
        )
        do {
            let reply = try await bossMCPClient.ask(agentName: agent, question: teaching.bossDirective())
            recordActionLog(
                source: "boss:\(agent)",
                action: "teachBossAck",
                targetName: teaching.friendName,
                result: String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
                succeeded: true
            )
        } catch {
            recordActionLog(
                source: "boss:\(agent)",
                action: "teachBossAck",
                targetName: teaching.friendName,
                result: "failed: \(error.localizedDescription)",
                succeeded: false
            )
        }
    }

    // MARK: - Inbox triage (read-side; the boss's recording paths are untouched)

    /// Acknowledge an inbox item — the operator has seen it and parks it out of
    /// the open queue. Pure Core mutation + audit log + save.
    func acknowledgeDecision(_ decision: BossInboxDecision) {
        state.acknowledge(decisionID: decision.id)
        recordTriageAction("acknowledge", decision)
        save()
    }

    /// Snooze an inbox item for `interval` (e.g. 1h, or "until I'm done" via a
    /// long interval). It leaves the open queue and resurfaces once the snooze
    /// elapses. Pure Core mutation + audit log + save.
    func snoozeDecision(_ decision: BossInboxDecision, for interval: TimeInterval) {
        let until = Date().addingTimeInterval(interval)
        state.snooze(decisionID: decision.id, until: until)
        recordTriageAction("snooze until \(until.formatted(date: .omitted, time: .shortened))", decision)
        save()
    }

    /// Resolve an inbox item — dealt with, permanently out of the open queue.
    /// Pure Core mutation + audit log + save.
    func resolveDecision(_ decision: BossInboxDecision) {
        state.resolve(decisionID: decision.id)
        recordTriageAction("resolve", decision)
        save()
    }

    /// One audit line per triage action, mirroring `teachBoss`'s logging so the
    /// operator's inbox actions are as traceable as the boss's decisions.
    private func recordTriageAction(_ action: String, _ decision: BossInboxDecision) {
        recordActionLog(
            source: "operator",
            action: "inbox:\(action)",
            targetName: decision.sessionName,
            result: String(decision.prompt.prefix(200)),
            succeeded: true
        )
    }

    func runExternalActionPump() async {
        // Before the steady-state drain loop, replay any requests a previous
        // run drained but crashed before confirming applied. `drain()` moves
        // request files into `processing/` and they're deleted only after the
        // app confirms it applied them (at-least-once), so anything still in
        // `processing/` at launch is a crashed-mid-apply action to recover.
        await recoverUnconfirmedExternalActionRequests()
        // F11b Defect 3 — clear `applied/` markers orphaned by a crash AFTER
        // confirm-but-BEFORE-clear (their `processing/` file is gone, so recovery
        // above won't replay them, but the marker would otherwise linger forever).
        await sweepOrphanedAppliedMarkers()
        while !Task.isCancelled {
            // FIX1 — "Pause Boss Watch" is a TRUE kill-switch. While paused the pump
            // must NOT drain+apply queued requests: gate the drain on the switch
            // BEFORE calling it. `drainExternalActionRequests` MOVES request files
            // into `processing/`, so skipping the drain (rather than draining then
            // discarding) is what keeps the queued requests HELD on disk, lossless,
            // until the watch resumes. An apply already mid-execution finishes — we
            // only refuse to start NEW applies while paused. Re-enabling resumes the
            // drain on the next tick and the held queue is applied. (Boss Watch ON →
            // applies as before; manual one-shot Check-In is a separate path,
            // unaffected.)
            if BossAutonomyGating.shouldApplyQueuedActions(bossWatchEnabled: bossWatchIsEnabled) {
                await drainExternalActionRequests()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Sendable result of an off-main queue drain.
    private struct ExternalDrainOutcome: Sendable {
        var requests: [WorkbenchActionRequest]
        var errorText: String?
    }

    func drainExternalActionRequests() async {
        // The drain does directory listing + per-file reads + moves into
        // `processing/`. Run it off the main actor so the every-2s pump never
        // janks the UI (and so a large queue backlog can't block the main
        // thread). Apply the decoded requests back on the main actor, then
        // confirm each applied request so its `processing/` file is deleted.
        let directoryURL = externalActionQueue.directoryURL
        let outcome = await Task.detached(priority: .utility) { () -> ExternalDrainOutcome in
            do {
                let queue = WorkbenchActionRequestQueue(directoryURL: directoryURL)
                return ExternalDrainOutcome(requests: try queue.drain(), errorText: nil)
            } catch {
                return ExternalDrainOutcome(requests: [], errorText: error.localizedDescription)
            }
        }.value
        if let errorText = outcome.errorText {
            errorMessage = "External Workbench action queue failed: \(errorText)"
            return
        }
        guard !outcome.requests.isEmpty else {
            return
        }
        applyExternalActionRequests(outcome.requests)
    }

    /// Replay requests left unconfirmed in `processing/` by a prior crash. Same
    /// apply + confirm path as a fresh drain; the core queue's de-dup already
    /// kept the originals distinct, and confirming deletes the `processing/`
    /// file so a recovered action isn't replayed again on the next launch.
    private func recoverUnconfirmedExternalActionRequests() async {
        let directoryURL = externalActionQueue.directoryURL
        let requests = await Task.detached(priority: .utility) { () -> [WorkbenchActionRequest] in
            WorkbenchActionRequestQueue(directoryURL: directoryURL).recoverUnconfirmed()
        }.value
        guard !requests.isEmpty else {
            return
        }
        applyExternalActionRequests(requests)
    }

    /// Apply each drained/recovered request on the main actor, mark each APPLIED
    /// in the durable ledger, surface the results in the boss activity feed, then
    /// confirm + clear them off-main.
    ///
    /// F11b ORDERING CONTRACT (THE key invariant): per request,
    ///   side-effect (`applyBossAction`) → `markApplied` (durable, main-actor SYNC)
    ///   → `confirmApplied` (delete `processing/`) → `clearApplied` (delete marker).
    /// `markApplied` MUST land BEFORE the detached confirm task — that detached
    /// task opens the crash window (apply done, `processing/` file still present),
    /// and the durable marker is what lets `ReplayDedupDecider` skip a replay if
    /// the app crashes before `confirmApplied` deletes the `processing/` file.
    /// Moving `markApplied` after the confirm — or dropping it — reopens the
    /// double-execute bug, which is why `ReplayDedupWiringTests` index-pins this.
    private func applyExternalActionRequests(_ requests: [WorkbenchActionRequest]) {
        let results = requests.map { request -> String in
            // Stamp the originating requestId onto the action-log entry this
            // apply writes (#U24), so the boss's queued request and the
            // operator's audit entry share one key — and workbench_action_result
            // can resolve the requestId to its applied/failed outcome.
            let result = applyBossAction(request.action, source: "external:\(request.source)", requestId: request.id)
            // Land the durable applied marker on the MAIN actor SYNCHRONOUSLY, right
            // after the side effect and BEFORE the detached confirm opens the crash
            // window. If we crash now, the `processing/` file remains (recovery
            // replays it) but the marker makes the decider skip the replay.
            externalActionQueue.markApplied(request.id)
            return "External \(request.source): \(result)"
        }
        bossAppliedActions = Array((results + bossAppliedActions).prefix(12))
        let appliedIDs = requests.map(\.id)
        let directoryURL = externalActionQueue.directoryURL
        Task.detached(priority: .utility) {
            let queue = WorkbenchActionRequestQueue(directoryURL: directoryURL)
            for id in appliedIDs {
                // confirm (delete processing/) THEN clear the marker — keeping the
                // applied ledger empty in steady state. A crash between the two
                // leaves an orphan marker the startup sweep clears.
                queue.confirmApplied(id)
                queue.clearApplied(id)
            }
        }
    }

    /// F11b Defect 3 — startup sweep for crash-orphaned `applied/` markers. The
    /// steady-state path clears a marker inline right after `confirmApplied`
    /// deletes its `processing/` file, so the ledger stays empty. But a crash
    /// AFTER `confirmApplied` and BEFORE `clearApplied` orphans the marker (its
    /// `processing/` file is gone, so recovery won't replay it, but the marker
    /// lingers). Run this once at startup, AFTER
    /// `recoverUnconfirmedExternalActionRequests` (which re-marks anything it
    /// replays), and clear every marker whose request is no longer in flight —
    /// bounding `applied/` growth.
    private func sweepOrphanedAppliedMarkers() async {
        let directoryURL = externalActionQueue.directoryURL
        await Task.detached(priority: .utility) {
            let queue = WorkbenchActionRequestQueue(directoryURL: directoryURL)
            for id in queue.appliedRequestIds() where !queue.isPendingOrProcessing(requestId: id) {
                queue.clearApplied(id)
            }
        }.value
    }

    /// Refresh the set of live persistent `screen` sessions so recovery can
    /// reattach to still-running agents losslessly. Runs `screen -ls` off-main
    /// with a watchdog; on any failure the set is left empty and recovery falls
    /// back to the gated respawn path.
    func refreshLiveScreenSessions() async {
        let names = await Task.detached(priority: .userInitiated) { () -> Set<String> in
            Self.listLiveScreenSessionNames()
        }.value
        liveScreenSessionNames = names
    }

    /// F11a Defect 1 — spawn a single `screen -X quit` off the main thread with a
    /// bounded 1.5s watchdog. Shared by the per-entry leak fix
    /// (`quitPersistentScreenIfNeeded`), the startup reaper
    /// (`reapOrphanedScreenSessions`), and the controller's
    /// `terminatePersistentSessionIfNeeded`, so the watchdog isn't copy-pasted
    /// and every quit site is equally protected from a wedged `screen` socket
    /// (e.g. an NFS home dir) hanging a worker thread forever. Fire-and-forget:
    /// the caller doesn't await the quit (use `terminatePersistentSessionAwaiting`
    /// when a quit must complete before a relaunch).
    nonisolated static func spawnScreenQuit(arguments: [String], environment: [String: String]) {
        let executable = PersistentTerminalSession.executable
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            do {
                try process.run()
            } catch {
                // The screen session / socket may already be gone.
                return
            }
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                finished.signal()
            }
            if finished.wait(timeout: .now() + .milliseconds(1500)) == .timedOut {
                // FIX2 — SIGTERM, then escalate to SIGKILL. A `screen` that ignores
                // SIGTERM (wedged socket / NFS home) would otherwise survive the
                // terminate() forever; mirror the BossAgentMCPClient terminate+forceKill
                // backstop so the quit can't leak a SIGTERM-deaf process.
                process.terminate()
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// F11a Defect 1 — quit the `ouro-wb-<id>` screen for one entry,
    /// UNCONDITIONALLY. `archiveCustomSession` / `deleteCustomSession` only ever
    /// guarded `activeSessions[id] == nil` and then mutated state — they never
    /// quit the screen, so a detached-but-alive session (after `markTerminated`
    /// cleared `activeSessions` without quitting via the
    /// `detachedPersistentSession` branch) leaked its screen + child process
    /// forever.
    ///
    /// The quit MUST NOT be gated on the cached `liveScreenSessionNames`: that
    /// cache is populated EXACTLY once (`refreshLiveScreenSessions` at launch) and
    /// never refreshed, so a session created THIS run is never in it. Gating on it
    /// made the quit a silent no-op for within-run sessions — and for archive (the
    /// archived entry keeps its id and stays in `state.processEntries`, so the
    /// startup reaper later treats the still-live screen as owned and spares it
    /// FOREVER) that gate leaked the screen PERMANENTLY. We instead issue the quit
    /// directly for `sessionName(for: entryId)`, matching the Stop path
    /// (`terminatePersistentSessionIfNeeded`), which already quits unconditionally.
    /// A quit against an absent socket just prints "No screen session found" to the
    /// discarded pipe (harmless); the liveness gate was only cosmetic. Spawn keeps
    /// the shared off-main + 1.5s-watchdog `spawnScreenQuit` (a wedged socket can't
    /// hang a worker thread).
    func quitPersistentScreenIfNeeded(forEntryId entryId: UUID) {
        let sessionName = PersistentTerminalSession.sessionName(for: entryId)
        Self.spawnScreenQuit(
            arguments: PersistentTerminalSession.terminateArguments(sessionName: sessionName),
            environment: TerminalEnvironment().valuesWithResolvedPath()
        )
    }

    /// F11a Defect 1 — at startup, quit every live `ouro-wb-<id>` screen that no
    /// known workbench entry owns. Past crashes (and detached-but-alive sessions
    /// that were deleted/archived in a prior run before this fix) leave orphan
    /// screens running their child processes forever; this is the catch-up sweep.
    ///
    /// ORDERING IS LOAD-BEARING. This MUST run AFTER `refreshLiveScreenSessions`
    /// (so `liveScreenSessionNames` is the real, current set — it reuses that
    /// cache, no second probe) AND only when state-load SUCCEEDED. The
    /// `stateLoadSucceeded` gate is the critical no-kill guard: a failed/empty
    /// load is indistinguishable from "no entries" by `state.processEntries`
    /// alone, and an empty `knownEntryIds` would make the reaper treat EVERY live
    /// session as an orphan — quitting reattachable survivors (F8-class). Forward
    /// derivation in the seam means a session a known id hashes to is spared by
    /// construction.
    func reapOrphanedScreenSessions() async {
        guard stateLoadSucceeded else {
            return
        }
        let knownEntryIds = Set(state.processEntries.map(\.id))
        let orphans = ScreenSessionReaper.orphanedSessionNames(
            liveSessionNames: liveScreenSessionNames,
            knownEntryIds: knownEntryIds
        )
        guard !orphans.isEmpty else {
            return
        }
        let environment = TerminalEnvironment().valuesWithResolvedPath()
        for name in orphans {
            Self.spawnScreenQuit(
                arguments: PersistentTerminalSession.terminateArguments(sessionName: name),
                environment: environment
            )
        }
    }

    /// U8a: re-derive startup attention now that the live-`screen` survival
    /// signal is known. The synchronous `load()` reconcile ran before the
    /// `screen -ls` probe, so it couldn't tell survivors from losses and used
    /// the safe degrade (treat as lost). Once the probe populates
    /// `liveScreenSessionNames`, re-run the survival-aware reconciler so a
    /// session whose terminal is still alive flips from a lost-state flag to a
    /// calm "reconnected" — BEFORE the reattach runs, so the post-reboot screen
    /// never shows a false orange alarm for an agent that just kept running.
    ///
    /// Only entries whose latest run is still `.needsRecovery` are touched (the
    /// reconciler guards on that), so a session the reattach already brought
    /// back to `.running` is left alone. Persisted so the calmer truth survives.
    func reconcileStartupAttentionWithLiveSessions() {
        let reconciled = startupRecoveryReconciler.rederiveAttention(
            state,
            liveSessionNames: liveScreenSessionNames
        )
        // Only attention/summary on recovering entries can have changed; assign
        // the whole reconciled state (runs are idempotent for already-needs-
        // recovery runs) and persist the calmer truth.
        guard reconciled.processEntries != state.processEntries else {
            return
        }
        state = reconciled
        save()
    }

    nonisolated private static func listLiveScreenSessionNames() -> Set<String> {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: PersistentTerminalSession.executable)
        process.arguments = PersistentTerminalSession.listArguments()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return []
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + .milliseconds(1500)) == .timedOut {
            // FIX2 — SIGTERM, then escalate to SIGKILL so a SIGTERM-ignoring
            // `screen -ls` (wedged socket) can't survive past the watchdog.
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return PersistentTerminalSession.liveSessionNames(fromListOutput: output)
    }

    func recoverEligibleSessionsOnStartup() {
        guard !didAttemptStartupRecovery else {
            return
        }
        didAttemptStartupRecovery = true
        // Reattach first (lossless reconnect to live agents), then the gated
        // respawn/auto-resume paths for sessions that didn't survive.
        for plan in summary.recoveryPlans where plan.action == .reattach {
            guard let entry = state.processEntries.first(where: { $0.id == plan.entryId }) else {
                continue
            }
            recover(entry, recoveryPlan: plan)
        }
        for plan in summary.recoveryPlans where plan.action == .autoResume || plan.action == .respawn {
            guard let entry = state.processEntries.first(where: { $0.id == plan.entryId }) else {
                continue
            }
            recover(entry, recoveryPlan: plan)
        }
    }

    /// When the "auto-launch autoResume terminals on startup" preference is
    /// on, launch every `autoResume` entry that isn't already running and
    /// has no pending recovery plan (so we don't double-launch what
    /// `recoverEligibleSessionsOnStartup` already handled). Off by default;
    /// must run *after* startup recovery so the recovery path wins for
    /// crashed sessions. Fires at most once per launch.
    func launchAutoResumeSessionsOnStartup() {
        guard !didAttemptAutoResumeLaunch else {
            return
        }
        didAttemptAutoResumeLaunch = true
        guard autoLaunchResumableOnStartup else {
            return
        }
        // Dedup only against entries startup recovery actually *launches*
        // (reattach / auto-resume / respawn). Recovery returns a plan per
        // entry — including inert `.noAction` / `.manualActionNeeded` ones — so
        // deduping against every plan would exclude every entry and never
        // launch anything, including a fresh `autoResume` shell/agent with no
        // prior run. See `RecoveryPlanner.autoLaunchEligibleEntries`.
        let candidates = RecoveryPlanner.autoLaunchEligibleEntries(
            entries: state.processEntries,
            recoveryPlans: summary.recoveryPlans,
            activeEntryIDs: Set(activeSessions.keys)
        )
        guard !candidates.isEmpty else { return }
        for entry in candidates {
            launch(entry)
        }
        recordActionLog(
            source: "native",
            action: "launchAutoResumeSessionsOnStartup",
            targetName: WorkbenchRelease.appName,
            result: "Auto-launched \(candidates.count) resumable session\(candidates.count == 1 ? "" : "s")",
            succeeded: true
        )
    }

    /// Persist the auto-launch-on-startup preference. The actual launching
    /// happens on the next app launch via `launchAutoResumeSessionsOnStartup`.
    func setAutoLaunchResumableOnStartup(_ enabled: Bool) {
        guard enabled != autoLaunchResumableOnStartup else { return }
        autoLaunchResumableOnStartup = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoLaunchResumableOnStartupDefaultsKey)
    }

    func recover(_ entry: ProcessEntry) {
        guard !entry.isArchived else {
            errorMessage = "\(entry.name) is archived. Restore it before recovery."
            return
        }
        guard let plan = recoveryPlan(for: entry) else {
            errorMessage = "No recovery plan is available for \(entry.name)"
            return
        }
        recover(entry, recoveryPlan: plan)
    }

    /// Run `recover(_:)` against every currently-recoverable session in one
    /// pass. Mirrors `stopAllRunningSessions()`: useful after the user has
    /// stepped away and several agents crashed; one click to relaunch them
    /// all. Returns the count of sessions actually recovered.
    @discardableResult
    func recoverAllCrashedSessions() -> Int {
        let candidates = recoverableEntries
        guard !candidates.isEmpty else { return 0 }
        for entry in candidates {
            recover(entry)
        }
        recordActionLog(
            source: "native",
            action: "recoverAllCrashedSessions",
            targetName: selectedProject?.name ?? WorkbenchRelease.appName,
            result: "Recovered \(candidates.count) crashed session\(candidates.count == 1 ? "" : "s")",
            succeeded: true
        )
        return candidates.count
    }

    func launch(_ entry: ProcessEntry) {
        guard !entry.isArchived else {
            errorMessage = "\(entry.name) is archived. Restore it before launching."
            return
        }
        do {
            let plan = try WorkbenchCommandPlanner(paths: paths).launchPlan(for: entry)
            // F11a Defect 2 — start is async (it may await a screen quit before
            // relaunching). Keep launch's sync signature (it's called from many
            // SwiftUI button closures) by driving the async start on the main
            // actor; the only suspension is the quit-await on a relaunch.
            Task { @MainActor in
                await start(entry, with: plan)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func focusTerminal(_ entry: ProcessEntry) {
        guard activeSessions[entry.id] != nil else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        terminalFocusEntryID = entry.id
    }

    func exitTerminalFocus() {
        terminalFocusEntryID = nil
    }

    /// U10: the detail banner's "Jump to prompt" action — select the waiting
    /// session and put the keyboard cursor in its live terminal (redrawing to the
    /// latest output) so the operator can answer the prompt the agent is parked
    /// on without hunting for the pane. No-op (with a message) if it isn't live.
    func jumpToAttentionPrompt(_ entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        selectedEntryID = entry.id
        session.redrawDisplay()
        session.focusInput()
    }

    /// Toggle full-screen focus for the ⇧⌘F menu command: exit if focused,
    /// otherwise focus the selected running terminal.
    func toggleTerminalFocus() {
        if terminalFocusEntryID != nil {
            exitTerminalFocus()
        } else if let entry = selectedEntry {
            focusTerminal(entry)
        }
    }

    func sendInput(_ text: String, to entry: ProcessEntry, appendNewline: Bool) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendInput(appendNewline ? "\(text)\n" : text)
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent input to \(entry.name)"
        }
        save()
    }

    func sendControlC(to entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendBytes([0x03])
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent Ctrl-C to \(entry.name)"
        }
        recordActionLog(
            source: "native",
            action: "sendControlC",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Sent Ctrl-C to \(entry.name)",
            succeeded: true
        )
        save()
    }

    func redrawTerminal(_ entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.redrawDisplay()
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Redrew \(entry.name)"
        }
        recordActionLog(
            source: "native",
            action: "redrawTerminal",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Redrew \(entry.name)",
            succeeded: true
        )
        save()
    }

    func sendEscape(to entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendBytes([0x1b])
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent Esc to \(entry.name)"
        }
        recordActionLog(
            source: "native",
            action: "sendEscape",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Sent Esc to \(entry.name)",
            succeeded: true
        )
        save()
    }

    func sendEOF(to entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendBytes([0x04])
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent EOF to \(entry.name)"
        }
        recordActionLog(
            source: "native",
            action: "sendEOF",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Sent Ctrl-D / EOF to \(entry.name)",
            succeeded: true
        )
        save()
    }

    func copyLaunchCommand(for entry: ProcessEntry) {
        let command = launchCommand(for: entry)
        copyToPasteboard(command)
        recordActionLog(
            source: "native",
            action: "copyLaunchCommand",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Copied launch command for \(entry.name)",
            succeeded: true
        )
    }

    /// Copy the last ~20 lines of the entry's most recent transcript to the
    /// pasteboard. Handy when the user wants to paste the tail into Slack /
    /// Linear without opening the transcript sheet. Records action log so
    /// the source-of-output is auditable. No-op (with an error message)
    /// when there's no transcript on disk for the entry yet.
    func copyTranscriptTail(for entry: ProcessEntry) {
        guard let tail = transcriptTail(for: entry) else {
            errorMessage = "No transcript on disk for \(entry.name)"
            return
        }
        let lines = tail.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let chosen = lines.suffix(20).joined(separator: "\n")
        copyToPasteboard(chosen)
        recordActionLog(
            source: "native",
            action: "copyTranscriptTail",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Copied \(min(20, lines.count)) lines from \(entry.name)",
            succeeded: true
        )
    }

    func openWorkingDirectory(for entry: ProcessEntry) {
        let directoryURL = URL(fileURLWithPath: entry.workingDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            errorMessage = "Working directory does not exist: \(entry.workingDirectory)"
            recordActionLog(
                source: "native",
                action: "openWorkingDirectory",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: "Missing directory: \(entry.workingDirectory)",
                succeeded: false
            )
            return
        }
        NSWorkspace.shared.open(directoryURL)
        recordActionLog(
            source: "native",
            action: "openWorkingDirectory",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Opened \(entry.workingDirectory)",
            succeeded: true
        )
    }

    func revealLatestTranscript(for entry: ProcessEntry) {
        guard let transcriptPath = latestRun(for: entry)?.transcriptPath else {
            errorMessage = "No transcript has been recorded for \(entry.name)"
            return
        }
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            errorMessage = "Transcript file is missing: \(transcriptPath)"
            recordActionLog(
                source: "native",
                action: "revealTranscript",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: "Missing transcript: \(transcriptPath)",
                succeeded: false
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([transcriptURL])
        recordActionLog(
            source: "native",
            action: "revealTranscript",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Revealed latest transcript",
            succeeded: true
        )
    }

    /// U11: the consequence-gated Stop entry point used by BOTH the ⌘. chord and
    /// every Stop button. When the session is a live agent holding context
    /// (`WorkbenchSurfacePolicy.stopNeedsConfirmation`), present the named
    /// confirmation instead of killing it outright — so a reflexive cancel-chord
    /// or a misclick can't nuke an in-flight agent. Idle/finished/never-started
    /// sessions terminate immediately (no friction where nothing's lost).
    func requestStop(_ entry: ProcessEntry) {
        let isLiveProcess = activeSessions[entry.id] != nil
        if WorkbenchSurfacePolicy.stopNeedsConfirmation(isLiveProcess: isLiveProcess, attention: entry.attention) {
            pendingStopSession = entry
        } else {
            terminate(entry)
        }
    }

    /// Confirm a pending Stop (the operator pressed the destructive button in the
    /// U11 confirmation dialog).
    func confirmStop() {
        guard let entry = pendingStopSession else { return }
        pendingStopSession = nil
        terminate(entry)
    }

    func terminate(_ entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        manuallyTerminatedRunIDs.insert(session.plan.runId)
        session.terminate()
        markTerminated(entryId: entry.id, runId: session.plan.runId, rawStatus: nil)
        // U11: record the stop so it's auditable in the action log alongside the
        // other native actions (who/what/when).
        recordActionLog(
            source: "native",
            action: "stopSession",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Stopped \(entry.name)",
            succeeded: true
        )
    }

    /// Terminate every currently-running session. Useful at end-of-day to
    /// clean up Codex/Claude processes the user no longer needs. Returns the
    /// number of sessions that were actually stopped so callers can render
    /// confirmation ("Stopped 4 terminals"). Skipped silently when nothing
    /// was running.
    @discardableResult
    func stopAllRunningSessions() -> Int {
        let entries = activeSessions.compactMap { (entryId, _) -> ProcessEntry? in
            state.processEntries.first { $0.id == entryId }
        }
        guard !entries.isEmpty else { return 0 }
        for entry in entries {
            terminate(entry)
        }
        recordActionLog(
            source: "native",
            action: "stopAllRunningSessions",
            targetName: selectedProject?.name ?? WorkbenchRelease.appName,
            result: "Stopped \(entries.count) running session\(entries.count == 1 ? "" : "s")",
            succeeded: true
        )
        return entries.count
    }

    @discardableResult
    func createCustomSession(_ draft: CustomTerminalSessionDraft, launchAfterCreate: Bool) -> ProcessEntry? {
        let projectId = selectedProject?.id ?? state.projects.first?.id
        return createCustomSession(draft, in: projectId, launchAfterCreate: launchAfterCreate)
    }

    /// Unit 4 / Slice 2: the empty-state "New Terminal" primary action — open a
    /// blank login-shell terminal instantly, zero required typing, no sheet.
    /// Builds a blank draft (empty command → `/bin/zsh -l` in the factory,
    /// default name) rooted at the selected project's path — the same working-
    /// directory default `NewTerminalSessionSheet` uses — and launches it.
    @discardableResult
    func createBlankTerminal() -> ProcessEntry? {
        let workingDirectory = selectedProject?.rootPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let draft = CustomTerminalSessionDraft(
            name: "",
            command: "",
            workingDirectory: workingDirectory,
            trust: .trusted,
            autoResume: true
        )
        return createCustomSession(draft, launchAfterCreate: true)
    }

    @discardableResult
    private func createCustomSession(
        _ draft: CustomTerminalSessionDraft,
        in projectId: UUID?,
        launchAfterCreate: Bool,
        owner: SessionOwner = .human
    ) -> ProcessEntry? {
        do {
            if state.projects.isEmpty {
                state = bootstrapper.bootstrappedState(from: state)
            }
            guard let project = projectId.flatMap({ id in state.projects.first { $0.id == id } }) ?? selectedProject ?? state.projects.first else {
                errorMessage = "No workbench project is available"
                return nil
            }
            var entry = try customSessionFactory.makeEntry(projectId: project.id, draft: draft)
            // Stamp ownership: human-created sessions stay `.human` (the factory
            // default); an agent-initiated session through `createSession`
            // carries `owner: .agent(<name>)` so it's a first-class, attributed
            // Workbench session.
            entry.owner = owner
            state.processEntries.append(entry)
            selectedProjectID = project.id
            selectedEntryID = entry.id
            save()
            refreshExecutableHealth()
            if launchAfterCreate {
                launch(entry)
            }
            return entry
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func isCustomSession(_ entry: ProcessEntry) -> Bool {
        customSessionManager.isCustomSession(entry)
    }

    func customSessionDraft(for entry: ProcessEntry) -> CustomTerminalSessionDraft? {
        try? customSessionManager.draft(from: entry)
    }

    func beginEditingSession(_ entry: ProcessEntry) {
        guard customSessionManager.isCustomSession(entry) else {
            errorMessage = "\(entry.name) is not a managed terminal session"
            return
        }
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before editing it"
            return
        }
        editingSession = entry
    }

    @discardableResult
    func updateCustomSession(_ entry: ProcessEntry, draft: CustomTerminalSessionDraft) -> Bool {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before editing it"
            return false
        }
        do {
            let updated = try customSessionManager.updatedEntry(entry, draft: draft)
            replaceEntry(updated)
            selectedEntryID = updated.id
            recordActionLog(
                source: "native",
                action: "editSession",
                targetEntryId: updated.id,
                targetName: updated.name,
                result: "Edited \(updated.name)",
                succeeded: true
            )
            refreshExecutableHealth()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func duplicateCustomSession(_ entry: ProcessEntry) -> ProcessEntry? {
        do {
            let duplicate = try customSessionManager.duplicateEntry(
                entry,
                name: uniqueCopyName(for: entry.name)
            )
            state.processEntries.append(duplicate)
            selectedEntryID = duplicate.id
            recordActionLog(
                source: "native",
                action: "duplicateSession",
                targetEntryId: duplicate.id,
                targetName: duplicate.name,
                result: "Duplicated \(entry.name) as \(duplicate.name)",
                succeeded: true
            )
            refreshExecutableHealth()
            return duplicate
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func archiveCustomSession(_ entry: ProcessEntry, recordNativeAction: Bool = true) {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before archiving it"
            return
        }
        // F11a Defect 1 — quit the persistent `ouro-wb-<id>` screen BEFORE we
        // replace the entry with its archived form. A detached-but-alive session
        // would otherwise keep its screen + child process running forever. No-op
        // when its screen isn't live.
        quitPersistentScreenIfNeeded(forEntryId: entry.id)
        do {
            let archived = try customSessionManager.archivedEntry(entry)
            replaceEntry(archived)
            selectedEntryID = archived.id
            if recordNativeAction {
                recordActionLog(
                    source: "native",
                    action: "archiveSession",
                    targetEntryId: archived.id,
                    targetName: archived.name,
                    result: "Archived \(archived.name)",
                    succeeded: true
                )
            } else {
                save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreCustomSession(_ entry: ProcessEntry, recordNativeAction: Bool = true) {
        do {
            let restored = try customSessionManager.restoredEntry(entry)
            replaceEntry(restored)
            selectedEntryID = restored.id
            if recordNativeAction {
                recordActionLog(
                    source: "native",
                    action: "restoreSession",
                    targetEntryId: restored.id,
                    targetName: restored.name,
                    result: "Restored \(restored.name)",
                    succeeded: true
                )
            } else {
                save()
            }
            refreshExecutableHealth()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestDeleteCustomSession(_ entry: ProcessEntry) {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before deleting it"
            return
        }
        guard customSessionManager.isCustomSession(entry) else {
            errorMessage = "\(entry.name) is not a managed terminal session"
            return
        }
        pendingDeleteSession = entry
    }

    func deleteCustomSession(_ entry: ProcessEntry) {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before deleting it"
            return
        }
        guard customSessionManager.isCustomSession(entry) else {
            errorMessage = "\(entry.name) is not a managed terminal session"
            return
        }
        // F11a Defect 1 — quit the persistent `ouro-wb-<id>` screen BEFORE we
        // remove the entry (and lose the id needed to derive the session name).
        // A detached-but-alive session would otherwise leak its screen + process
        // forever. No-op when its screen isn't live.
        quitPersistentScreenIfNeeded(forEntryId: entry.id)
        state.processEntries.removeAll { $0.id == entry.id }
        state.processRuns.removeAll { $0.entryId == entry.id }
        pendingDeleteSession = nil
        if selectedEntryID == entry.id {
            selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
        }
        recordActionLog(
            source: "native",
            action: "deleteSession",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Deleted \(entry.name)",
            succeeded: true
        )
        refreshExecutableHealth()
    }

    private func recover(_ entry: ProcessEntry, recoveryPlan: RecoveryPlan) {
        do {
            guard recoveryPlan.action == .reattach || recoveryPlan.action == .autoResume || recoveryPlan.action == .respawn else {
                errorMessage = "\(entry.name) is not eligible for automatic recovery: \(recoveryPlan.reason)"
                return
            }
            let latestRun = state.processRuns
                .filter { $0.entryId == entry.id }
                .sorted(by: ProcessRun.isMoreRecent)
                .first
            let plan = try WorkbenchCommandPlanner(paths: paths).recoveryPlan(
                for: entry,
                latestRun: latestRun,
                action: recoveryPlan.action
            )
            // F11a Defect 2 — route through the async start (it awaits a screen
            // quit before relaunching when a session is live). The recovery
            // reattach path usually has no live local session (activeSessions ==
            // nil → .launchImmediately, nothing to await); the await only bites
            // when a relaunch must first quit a still-attached client.
            Task { @MainActor in
                await start(entry, with: plan)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func applyBossAction(_ action: BossWorkbenchAction, source: String, requestId: UUID? = nil) -> String {
        // Make the originating requestId available to every action-log write this
        // apply triggers (#U24), then clear it so an operator action that runs
        // next never inherits a stale id.
        currentBossActionRequestId = requestId
        defer { currentBossActionRequestId = nil }
        do {
            try action.validateForQueueing()
        } catch {
            return finishBossAction(
                source: source,
                action: action,
                entry: nil,
                result: "Skipped \(action.action.rawValue): \(error.localizedDescription)"
            )
        }

        // F11b Defect 3 — UNIVERSAL replay guard. The action queue is at-least-once:
        // `applyExternalActionRequests` runs this apply SYNCHRONOUSLY then confirms
        // (deletes the `processing/` file) OFF-MAIN in a detached task, so a crash
        // in that window leaves the `processing/` file and `recoverUnconfirmed()`
        // replays an ALREADY-applied request. Before any handler runs, consult the
        // durable `applied/` id-ledger: if this request's id is already applied,
        // skip it — covering EVERY kind (launch / createSession / createTerminal /
        // createGroup / sendInput / …), not just the `isNewDecision`-guarded
        // sendInput. Gated on `requestId != nil`: operator-issued actions carry no
        // requestId, are never replayed from the queue, and so are never deduped
        // here. The id-keyed ledger never false-skips a DELIBERATE re-issue: a boss
        // that repeats the same effect with a NEW requestId gets a fresh id → applies.
        if let requestId,
           ReplayDedupDecider().decide(
               requestId: requestId,
               appliedRequestIds: externalActionQueue.appliedRequestIds()
           ) == .skipAlreadyApplied {
            return finishBossAction(
                source: source,
                action: action,
                entry: nil,
                result: "Skipped \(action.action.rawValue): already applied (replay)"
            )
        }

        // Close the entry-less auth bypass: entry-less actions used to reach their handlers in
        // the first switch WITHOUT any authorization (they returned before the entry-scoped
        // authorizer below). Authorize the genuinely entry-less actions explicitly here, BEFORE
        // any handler runs. Known callers (createGroup / createTerminal / createSession) stay
        // allowed under `knownEntryless`; repairAgent runs under `trustedOnboarding`; anything
        // else reaching the entry-less path is denied. The entry-scoped second switch — and its
        // `authorize(_:for:livePrompt:)` sendInput safety floor + escalateWithheldBossInput
        // path — is left UNTOUCHED.
        switch action.action {
        case .createGroup, .createTerminal, .createSession, .repairAgent, .requestProviderConfig,
             .verifyProvider, .refreshProvider, .selectLane, .registerWorkbenchMCP, .ensureDaemon,
             .reportBug:
            let authorization = bossActionAuthorizer.authorizeEntryless(action)
            guard authorization.isAllowed else {
                return finishBossAction(
                    source: source,
                    action: action,
                    entry: nil,
                    result: "Skipped \(action.action.rawValue): \(authorization.reason ?? "not authorized")"
                )
            }
        case .launch, .recover, .terminate, .sendInput, .moveSession, .setTrust, .setAutoResume, .archive, .restore:
            break
        }

        switch action.action {
        case .createGroup:
            guard createGroup(name: action.name ?? "", rootPath: action.workingDirectory ?? "") else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Failed createGroup: \(errorMessage ?? "invalid group")")
            }
            return finishBossAction(source: source, action: action, entry: nil, result: "Created group \(action.name ?? "unnamed")")
        case .createTerminal:
            guard let project = project(matching: action.group) else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Skipped createTerminal: no unique group matches \(action.group ?? "selected group")")
            }
            let draft = CustomTerminalSessionDraft(
                name: action.name ?? "",
                command: action.command ?? "",
                workingDirectory: nonEmpty(action.workingDirectory) ?? project.rootPath,
                trust: action.trust ?? .untrusted,
                autoResume: action.autoResume ?? false,
                notes: action.text ?? "Created by \(source)",
                // Forward memory (Slice 6): carry the boss's discovery provenance
                // (nil for an ordinary create) so a relaunched discovered session
                // is stamped + natively rediscoverable by the next scan().
                discoveredHarness: action.discoveredHarness,
                discoveredSessionId: nonEmpty(action.discoveredSessionId)
            )
            guard let entry = createCustomSession(draft, in: project.id, launchAfterCreate: false) else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Failed createTerminal: \(errorMessage ?? "invalid terminal")")
            }
            return finishBossAction(source: source, action: action, entry: entry, result: "Created terminal \(entry.name) in \(project.name)")
        case .createSession:
            // Agent-initiated unified session: create a first-class Workbench
            // session attributed to the calling agent and launch it. Same
            // trust/validation path as a human-created terminal — the launch
            // runs through `launch(...)`, which applies `launchPreflightProblem`
            // (working-dir + explicit-path executable checks). Trust gating is
            // unchanged: an untrusted session is created but the boss won't
            // auto-drive it.
            guard let ownerName = nonEmpty(action.owner) else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Skipped createSession: missing owner (agent name)")
            }
            guard let project = project(matching: action.group) else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Skipped createSession: no unique group matches \(action.group ?? "selected group")")
            }
            let draft = CustomTerminalSessionDraft(
                name: action.name ?? "",
                command: action.command ?? "",
                workingDirectory: nonEmpty(action.workingDirectory) ?? project.rootPath,
                trust: action.trust ?? .untrusted,
                autoResume: action.autoResume ?? false,
                notes: nonEmpty(action.text) ?? "Created by \(source)",
                // Forward memory (Slice 6): carry the boss's discovery provenance
                // (nil for an ordinary create) so a relaunched discovered session
                // is stamped + natively rediscoverable by the next scan().
                discoveredHarness: action.discoveredHarness,
                discoveredSessionId: nonEmpty(action.discoveredSessionId)
            )
            guard let entry = createCustomSession(draft, in: project.id, launchAfterCreate: true, owner: .agent(name: ownerName)) else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Failed createSession: \(errorMessage ?? "invalid session")")
            }
            return finishBossAction(source: source, action: action, entry: entry, result: "Created session \(entry.name) in \(project.name) owned by \(ownerName)")
        case .repairAgent:
            return startRepairAgent(action: action, source: source)
        case .requestProviderConfig:
            return openProviderConfig(action: action, source: source)
        case .verifyProvider:
            return startVerifyProvider(action: action, source: source)
        case .refreshProvider:
            return startRefreshProvider(action: action, source: source)
        case .selectLane:
            return startSelectLane(action: action, source: source)
        case .registerWorkbenchMCP:
            return startRegisterWorkbenchMCP(action: action, source: source)
        case .ensureDaemon:
            return startEnsureDaemon(action: action, source: source)
        case .reportBug:
            return startReportBug(action: action, source: source)
        case .launch, .recover, .terminate, .sendInput, .moveSession, .setTrust, .setAutoResume, .archive, .restore:
            break
        }

        guard let entryValue = action.entry,
              let entry = processEntry(matching: entryValue) else {
            return finishBossAction(
                source: source,
                action: action,
                entry: nil,
                result: "Skipped \(action.action.rawValue): no unique process entry matches \(action.entry ?? "missing entry")"
            )
        }
        // For `sendInput`, the danger is in the PROMPT the session is showing,
        // not the bare input — so the safety floor must classify the live
        // waiting prompt (the same transcript-tail source the decisions /
        // auto-advance gate reads), not just the input text. Read it once here
        // and reuse it for both the authorization floor and the cross-channel
        // dedup below. (Empty for non-sendInput actions, where it's ignored.)
        let livePrompt = action.action == .sendInput
            ? bossActionLivePrompt(for: entry)
            : ""
        // F3 — feed the authorizer the operator's auto-advance kill-switch + the
        // session's effective friend, built the SAME way the decisions channel
        // (`recordBossDecisions`) builds it. This is what makes the folded-in
        // injection gate fire on the authoritative actions channel: a `sendInput`
        // is now refused when the kill-switch is OFF or the friend is untrusted,
        // so the operator's "turn this off to make the boss escalate everything
        // instead" toggle is honored here, not just on the decisions path. The
        // existing denial handling below escalates a withheld sendInput to the
        // inbox + logs "Skipped" — a kill-switch denial flows through it for free.
        let machineOwner = SessionFriend.machineOwner()
        let effectiveFriend = state.effectiveFriend(for: entry, fallback: machineOwner)
        let autoAdvanceContext = BossAutoAdvanceContext(
            autoAdvanceEnabled: bossAutoAdvanceEnabled,
            friend: effectiveFriend
        )
        let authorization = bossActionAuthorizer.authorize(
            action,
            for: entry,
            livePrompt: livePrompt,
            autoAdvanceContext: autoAdvanceContext
        )
        guard authorization.isAllowed else {
            // An unsafe sendInput is withheld AND escalated to a human, mirroring
            // the decisions channel: record an `escalate` decision so the held
            // prompt surfaces in the same inbox the operator already reviews —
            // not just buried in the action log.
            if action.action == .sendInput {
                escalateWithheldBossInput(
                    entry: entry,
                    source: source,
                    prompt: livePrompt,
                    proposedInput: action.text,
                    reason: authorization.reason ?? "withheld unsafe input — escalated to a human"
                )
            }
            return finishBossAction(
                source: source,
                action: action,
                entry: entry,
                result: "Skipped \(action.action.rawValue) for \(entry.name): \(authorization.reason ?? "not authorized")"
            )
        }

        switch action.action {
        case .launch:
            guard activeSessions[entry.id] == nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped launch for \(entry.name): already running")
            }
            launch(entry)
            return finishBossAction(source: source, action: action, entry: entry, result: "Launched \(entry.name)")
        case .recover:
            guard canRecover(entry) else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped recover for \(entry.name): \(recoveryReason(for: entry))")
            }
            recover(entry)
            // #U28: record WHICH recovery class the boss acted on (reattach /
            // auto_resume / respawn / needs_human) so the operator can audit which
            // sessions the boss resumed vs escalated — from the same plan source.
            let recoveryClass = summary.recoveryPlans
                .first { $0.entryId == entry.id }
                .flatMap { RecoveryBreakdown.bossActionClass(for: $0.action) }
            let classSuffix = recoveryClass.map { " (\($0))" } ?? ""
            return finishBossAction(source: source, action: action, entry: entry, result: "Recovered \(entry.name)\(classSuffix)")
        case .terminate:
            guard activeSessions[entry.id] != nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped terminate for \(entry.name): not running")
            }
            terminate(entry)
            return finishBossAction(source: source, action: action, entry: entry, result: "Stopped \(entry.name)")
        case .sendInput:
            guard activeSessions[entry.id] != nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped sendInput for \(entry.name): not running")
            }
            guard let text = action.text, !text.isEmpty else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped sendInput for \(entry.name): missing text")
            }
            // Single per-(entry, prompt) guard shared with the decisions channel.
            // A boss reply commonly emits BOTH a `sendInput` action and an
            // `autoAdvance` decision for the same waiting prompt ("act and log");
            // without a shared guard the keystroke is sent twice (here, then
            // again in `recordBossDecisions`). We record this send as an
            // `autoAdvance` decision keyed on the *live prompt*, and skip if the
            // decisions channel (or a duplicate action) already handled it — so
            // each (entry, prompt) is acted on at most once per reply.
            guard state.isNewDecision(entryId: entry.id, prompt: livePrompt, kind: .autoAdvance) else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped sendInput for \(entry.name): already handled this prompt")
            }
            sendInput(text, to: entry, appendNewline: action.appendNewline)
            state.recordDecision(
                BossInboxDecision(
                    source: source,
                    entryId: entry.id,
                    sessionName: entry.name,
                    prompt: livePrompt,
                    kind: .autoAdvance,
                    proposedInput: String(text.prefix(500)),
                    reasoning: "boss sendInput action (actions channel)",
                    status: .applied
                )
            )
            save()
            return finishBossAction(source: source, action: action, entry: entry, result: "Sent input to \(entry.name)")
        case .moveSession:
            guard let project = project(matching: action.group) else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped moveSession for \(entry.name): no unique group matches \(action.group ?? "missing group")")
            }
            guard activeSessions[entry.id] == nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped moveSession for \(entry.name): stop it first")
            }
            moveSession(entry, to: project.id, recordNativeAction: false)
            return finishBossAction(source: source, action: action, entry: entry, result: "Moved \(entry.name) to \(project.name)")
        case .setTrust:
            guard let trust = action.trust else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped setTrust for \(entry.name): missing trust")
            }
            updateEntry(entry.id) { entry in
                entry.trust = trust
                entry.lastSummary = "\(entry.name) trust set to \(trust.rawValue)"
            }
            save()
            return finishBossAction(source: source, action: action, entry: entry, result: "Set \(entry.name) trust to \(trust.rawValue)")
        case .setAutoResume:
            guard let autoResume = action.autoResume else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped setAutoResume for \(entry.name): missing autoResume")
            }
            updateEntry(entry.id) { entry in
                entry.autoResume = autoResume
                entry.lastSummary = "\(entry.name) auto-resume \(autoResume ? "enabled" : "disabled")"
            }
            save()
            return finishBossAction(source: source, action: action, entry: entry, result: "\(autoResume ? "Enabled" : "Disabled") auto-resume for \(entry.name)")
        case .archive:
            guard activeSessions[entry.id] == nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped archive for \(entry.name): stop it first")
            }
            archiveCustomSession(entry, recordNativeAction: false)
            guard state.processEntries.first(where: { $0.id == entry.id })?.isArchived == true else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Failed archive for \(entry.name): \(errorMessage ?? "not archivable")")
            }
            return finishBossAction(source: source, action: action, entry: entry, result: "Archived \(entry.name)")
        case .restore:
            restoreCustomSession(entry, recordNativeAction: false)
            guard state.processEntries.first(where: { $0.id == entry.id })?.isArchived == false else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Failed restore for \(entry.name): \(errorMessage ?? "not restorable")")
            }
            return finishBossAction(source: source, action: action, entry: entry, result: "Restored \(entry.name)")
        case .createGroup, .createTerminal, .createSession, .repairAgent, .requestProviderConfig,
             .verifyProvider, .refreshProvider, .selectLane, .registerWorkbenchMCP, .ensureDaemon,
             .reportBug:
            return finishBossAction(source: source, action: action, entry: entry, result: "Skipped \(action.action.rawValue): already handled")
        }
    }

    /// The target session's current waiting-prompt text, for the boss-driven
    /// `sendInput` safety floor and the cross-channel dedup key. Sourced from the
    /// live transcript tail — the same place the decisions / auto-advance gate
    /// looks — so the actions path classifies (and dedups against) exactly the
    /// terminal text the operator would see, not the bare input. Returns the
    /// last ~20 non-empty lines (bounded) so the key stays stable and small.
    func bossActionLivePrompt(for entry: ProcessEntry) -> String {
        guard let tail = transcriptTail(for: entry)?.text else {
            return ""
        }
        let lines = tail
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.suffix(20).joined(separator: "\n").prefix(2000))
    }

    /// Withhold + escalate an unsafe boss `sendInput` from the actions channel,
    /// mirroring how the decisions channel surfaces a blocked auto-advance:
    /// record an `escalate` decision into the same inbox the operator reviews
    /// (the action log already captured the "Skipped" line via `finishBossAction`).
    private func escalateWithheldBossInput(
        entry: ProcessEntry,
        source: String,
        prompt: String,
        proposedInput: String?,
        reason: String
    ) {
        let machineOwner = SessionFriend.machineOwner()
        let friend = state.effectiveFriend(for: entry, fallback: machineOwner)
        // Deduped like the decisions channel: a repeated boss-watch tick over the
        // same still-unanswered prompt re-proposes the same withheld input, so
        // don't flood the inbox with identical escalations.
        let recorded = state.recordDecisionIfNew(
            BossInboxDecision(
                source: source,
                entryId: entry.id,
                sessionName: entry.name,
                friendName: friend?.name,
                friendId: friend?.id,
                prompt: String(prompt.prefix(2000)),
                kind: .escalate,
                proposedInput: proposedInput.map { String($0.prefix(500)) },
                reasoning: "[withheld: \(reason)]",
                status: .recorded
            )
        )
        if recorded {
            save()
        }
    }

    /// Present the native provider-config form for `agentName`. The single place the form is
    /// opened — from the `requestProviderConfig` action OR a native onboarding provider-setup
    /// affordance. Sets only the label/seed and the presentation flag; carries no credential.
    func presentProviderConfigForm(agentName: String) {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        providerConfigIsNewAgent = false
        // Start each form session clean: the cold-start vault-onboarding flags are otherwise
        // cleared ONLY on a verified-ready completion, so without this reset opening the form
        // for a DIFFERENT agent would carry a prior agent's stale `.needsVaultSetup` + stashed
        // provider — wrongly offering "Finish setup" for the new target.
        providerConfigNeedsVaultSetup = false
        providerConfigColdStartProvider = nil
        providerConfigColdStartMessage = nil
        providerConfigAgentName = trimmed.isEmpty ? state.boss.agentName : trimmed
        isProviderConfigPresented = true
    }

    /// Present the provider form to CREATE A NEW AGENT (the empty-machine first-agent
    /// path, and the "create another" path). The form collects the agent name +
    /// provider + credentials and cold-start-hatches headlessly — replacing the
    /// visible `ouro hatch` CLI pane the old install sheet spawned.
    func presentNewAgentProviderConfigForm() {
        providerConfigIsNewAgent = true
        // Start each form session clean (see presentProviderConfigForm): never let a prior agent's
        // stale `.needsVaultSetup` + stashed provider leak into this fresh form session.
        providerConfigNeedsVaultSetup = false
        providerConfigColdStartProvider = nil
        providerConfigColdStartMessage = nil
        providerConfigAgentName = ""
        isProviderConfigPresented = true
    }

    /// U18: the install sheet is demoted to its only unique capability — cloning an agent
    /// from a Git remote. Creating an agent goes through the native form above; this opens
    /// the (now clone-only) `OuroAgentInstallSheet`.
    func presentCloneAgentSheet() {
        isOuroAgentInstallSheetPresented = true
    }

    /// Seam-free validation for a new agent's name, or nil if valid. Surfaced inline in
    /// the new-agent form before any hatch is attempted.
    func newAgentNameValidationMessage(_ name: String) -> String? {
        ProviderConfigForm.newAgentNameValidationMessage(name, existingNames: ouroAgents.map(\.name))
    }

    /// Whether a usable agent bundle already exists for the provider-config target. Drives the
    /// cold-start vs. existing-agent branch in `submitProviderConfig`.
    func providerConfigAgentAlreadyExists(named agentName: String) -> Bool {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ouroAgents.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Submit the native provider-config form. Returns the seam-free message to surface in the
    /// form, or nil when there is nothing to surface SYNCHRONOUSLY. The SECRET reaches `ouro hatch`
    /// only here, native-form → hatch argv — it NEVER passes through the agent's context/MCP.
    ///
    /// COLD-START path (the deliverable): no usable agent yet → build + run a headless
    /// `ouro hatch …` with the matching credential flags, then probe + classify the outcome.
    /// F1: a nil return on the cold-start path means the hatch + probe is now IN FLIGHT — the form
    /// does NOT dismiss synchronously. The async outcome dismisses on `.ready`, or surfaces
    /// `providerConfigColdStartMessage` (and keeps the form open) on a created-but-not-connected /
    /// failed outcome. The old code lied here: it dismissed + logged success before the hatch ran.
    @discardableResult
    func submitProviderConfig(
        provider: WorkbenchProvider,
        humanName: String,
        values: [String: String]
    ) -> String? {
        let agentName = providerConfigAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAgent = agentName.isEmpty ? state.boss.agentName : agentName

        // F6 — EXISTING-AGENT credential ROTATION. There is still no headless `ouro` non-interactive
        // credential-set sink (the documented gap a), so we DON'T pretend to set it silently: we drive
        // the documented unlock chain (`ouro vault unlock && ouro auth && ouro provider refresh`) in a
        // native `.trusted` terminal (a real TTY) and gate the `.ready` outcome on a positive
        // `.working` re-probe (F1's invariant, reused via completeVaultOnboarding). This REPLACES the
        // old dead-end that returned `existingAgentRefreshUnavailableMessage` and did nothing.
        //
        // Risk (c): this branch fires ONLY when the bundle already exists; a brand-new agent's name
        // is rejected upstream as a collision and never reaches here, so rotation can't fire for a
        // new agent. Returning nil (no synchronous message) keeps the form open with the in-flight
        // status `beginCredentialRotation` surfaces; the result follows from the re-probe.
        if providerConfigAgentAlreadyExists(named: resolvedAgent) {
            beginCredentialRotation(agentName: resolvedAgent, provider: provider)
            return nil
        }

        let form = ProviderConfigForm(agentName: resolvedAgent, humanName: humanName)
        let outcome = form.submit(provider: provider, values: values)

        switch outcome {
        case let .invalid(message):
            return message
        case let .unsupportedColdStartSink(message):
            // github-copilot cold-start (gap b): no `ouro hatch` argv flag. Honest report — no
            // fabricated command, no CLI pane. The Core form built this seam-free message.
            return message
        case let .coldStartHatch(plan):
            // F1 — STOP THE LIE. This used to dismiss the form + log success SYNCHRONOUSLY (before
            // the detached hatch even ran), then ignore the hatch's `try?` error. But `ouro hatch`
            // FAILS on a fresh agent — it writes agent.json's provider lanes BEFORE the credential
            // step, then the headless credential step throws (a brand-new agent has no vault, and
            // creating one needs an interactive TTY secret). So agent.json existed (read "ready")
            // while no credential was persisted — a dead bundle reporting success.
            //
            // Now: set an in-flight flag, run the hatch FOR ITS EXIT, probe the configured lane
            // with a SHORT-budget `ouro check` (classified via F2's ProviderCheckClassifier), and
            // classify honestly. Only a positively-`.working` probe reports success; everything
            // else keeps the form open with the seam-free outcome line and surfaces the bundle as
            // needs-credentials, NOT ready.
            providerConfigColdStartInFlight = true
            // F6 — the spinner label is shared with the reconnect flavor; reset it to the
            // cold-start wording so a prior rotation can't leave a stale "Reconnecting…" label here.
            providerConfigInFlightLabel = "Creating your agent…"
            Task { [weak self] in
                let run = await ColdStartHatchRunner.runHeadless(plan: plan)
                // `.launchFailed` → nil (never ran); `.exited` → its real code.
                let exit = run.exitCode
                // The cold-start configures the OUTWARD lane (the one onboarding surfaces; for a
                // fresh agent both lanes collapse to the same provider). Probe it on a short budget
                // so a flaky-daemon hang degrades to "couldn't confirm" fast — not a 90s freeze.
                let verdict = await self?.runColdStartProviderCheck(agentName: resolvedAgent, lane: "outward")
                let outcome = ProviderConfigForm.classifyColdStart(hatchExitCode: exit, checkVerdict: verdict)
                await MainActor.run {
                    guard let self else { return }
                    self.providerConfigColdStartInFlight = false
                    // Always refresh inventory/readiness so the just-created bundle surfaces with
                    // its TRUE state (a credential-less hatch shows as needs-credentials, not ready).
                    self.refreshOuroAgents()
                    self.refreshOnboardingReadiness()
                    self.runOnboardingProviderChecksIfNeeded()
                    switch outcome {
                    case .ready:
                        // Verified working — the existing success side-effects + dismiss + success log.
                        // R4b — re-run the parked first-run bootstrap. S2's gate now reads
                        // `credentialsPresent` (the agent was hatched WITH a usable credential), so
                        // the re-run crosses S2 → S3→S5 → the handoff probe, flipping to agent-driven
                        // mode. `runFirstRunBootstrap` no-ops if a run is already in flight or already
                        // handed off, so this is safe even outside the parked first-run path.
                        self.runFirstRunBootstrap()
                        self.recordActionLog(
                            source: "native",
                            action: "providerConfigColdStart",
                            targetName: resolvedAgent,
                            // Audit lane only — carries the raw `ouro hatch` verb (NOT the credential).
                            result: "ran `ouro hatch --agent \(resolvedAgent) --provider \(provider.providerFlagValue)` (cold-start; verified ready)",
                            succeeded: true
                        )
                        self.isProviderConfigPresented = false
                    case .needsVaultSetup:
                        // F13 — the agent EXISTS but the headless hatch couldn't persist the
                        // credential (a fresh agent has no vault, and creating one needs an
                        // interactive TTY secret). This is the recoverable case: keep the form open,
                        // surface the seam-free outcome line, AND offer "Finish setup" — which runs
                        // the documented `ouro vault create && auth && refresh` recovery chain in a
                        // native terminal. Stash the provider so the chain can name it; the
                        // credential itself is gone (ephemeral hatch argv) and is re-collected
                        // interactively in that terminal.
                        self.providerConfigColdStartMessage = outcome.humanFacingLine(agentName: resolvedAgent)
                        self.providerConfigNeedsVaultSetup = true
                        self.providerConfigColdStartProvider = provider
                        self.recordActionLog(
                            source: "native",
                            action: "providerConfigColdStart",
                            targetName: resolvedAgent,
                            result: "ran `ouro hatch --agent \(resolvedAgent) --provider \(provider.providerFlagValue)` (cold-start; outcome: \(outcome.auditReason))",
                            succeeded: false
                        )
                    case .failed:
                        // Honest failure: keep the form open, surface the seam-free outcome line,
                        // and route to the onboarding readiness surface (which owns the
                        // .needsCredentials repair step). Do NOT dismiss and do NOT log success.
                        // NOT recoverable via finish-setup: a `.failed` cold-start never produced a
                        // usable bundle, so the vault flag stays false.
                        self.providerConfigColdStartMessage = outcome.humanFacingLine(agentName: resolvedAgent)
                        self.recordActionLog(
                            source: "native",
                            action: "providerConfigColdStart",
                            targetName: resolvedAgent,
                            result: "ran `ouro hatch --agent \(resolvedAgent) --provider \(provider.providerFlagValue)` (cold-start; outcome: \(outcome.auditReason))",
                            succeeded: false
                        )
                    }
                }
            }
            // No synchronous dismiss / success-log: the truth is only known after the probe above.
            return nil
        }
    }

    /// F13 — "Finish setup": the in-app recovery for the honest `.needsVaultSetup` cold-start.
    ///
    /// The credential the user typed is GONE and un-replayable (it reached `ouro hatch` only as
    /// ephemeral argv; re-running hatch hard-errors "bundle already exists"; `ouro auth` re-prompts
    /// AND needs the vault to exist first). So we cannot persist silently — we run the CLI's
    /// documented recovery chain (`ouro vault create && ouro auth && ouro provider refresh`) in a
    /// NATIVE Workbench terminal (a real TTY), where the human enters the unlock secret (twice) and
    /// re-enters the provider credential. The terminal is `.trusted` so F3's autonomy gate doesn't
    /// block those legitimate human prompts. We capture the launched entry id + runId so
    /// `markTerminated` recognizes its exit and re-probes; the re-probe (not the exit) is the sole
    /// authority on `.ready` (the chain can exit 0 with a wedged daemon — the F1 safety invariant).
    func beginVaultOnboarding() {
        let agentName = providerConfigAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Without a resolved agent name + stashed provider there's nothing to recover.
        guard !agentName.isEmpty, let provider = providerConfigColdStartProvider else {
            return
        }
        // RE-ENTRANCY GATE — same latent double-fire shape as F6's beginCredentialRotation. The
        // "Finish setup" button is `.disabled(model.providerConfigColdStartInFlight)`, but this path
        // never sets that flag, so the disable never engages during its OWN run: a second tap would
        // re-enter and overwrite vaultOnboardingEntryID/RunID to a second terminal, orphaning the
        // first (its exit would fail the entryId/runId match in markTerminated, so its re-probe fold
        // never runs). Setting it true gates the button until `completeVaultOnboarding` clears it on
        // EVERY exit path (the unconditional clear before its switch — success AND failure — so a
        // failed finish-setup re-enables the button for retry). Clean mirror of the F6 gate.
        providerConfigColdStartInFlight = true
        // F6/F13 — flavor the spinner label for this onboarding-flavored finish-setup (the shared
        // flag's default "Creating your agent…" reads fine here, but the running-state copy is more
        // accurate). Seam-free copy from the Core seam.
        providerConfigInFlightLabel =
            VaultOnboardingMachine.humanLine(for: .runningVaultTerminal, agentName: agentName, flavor: .onboarding)
            ?? "Creating your agent…"
        // Build the chained recovery command from the PURE Core seam (single source of truth for
        // the command shape + shell-quoting). Default email is `<name>@ouro.bot`.
        let command = VaultOnboardingCommand.finishSetupCommandLine(
            agentName: agentName,
            providerFlag: provider.providerFlagValue,
            email: nil
        )
        let draft = CustomTerminalSessionDraft(
            name: "Finish setup: \(agentName)",
            command: command,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            trust: .trusted,
            autoResume: false,
            notes: "Workbench vault onboarding (finish setup) for \(agentName)"
        )
        guard let entry = createCustomSession(draft, launchAfterCreate: true) else {
            // The terminal couldn't even be created/launched — surface a launch failure honestly
            // (re-probe never runs; the machine folds a nil exit to .vaultCommandLaunchError).
            completeVaultOnboarding(vaultExitCode: nil)
            return
        }
        // Capture the run for exit-matching. `launch` populates `activeSessions[entry.id]`
        // synchronously, so its plan's runId is available now.
        vaultOnboardingEntryID = entry.id
        vaultOnboardingRunID = activeSessions[entry.id]?.plan.runId
        vaultOnboardingAgentName = agentName
        // F13's flow is the onboarding flavor (first-time setup); F6's rotation captures `.rotation`.
        vaultOnboardingFlavor = .onboarding
        recordActionLog(
            source: "native",
            action: "beginVaultOnboarding",
            targetName: agentName,
            // Audit lane only — the raw recovery verbs (no credential; the human types that in the TTY).
            result: "opened finish-setup terminal: \(command)",
            succeeded: true
        )
    }

    /// F6 — "Reconnect": rotate an EXISTING agent's credential. Unlike F13's cold-start finish-setup
    /// (a brand-new agent whose vault doesn't exist yet), an existing agent's vault ALREADY exists,
    /// so this runs the UNLOCK chain (`ouro vault unlock && ouro auth && ouro provider refresh`) — no
    /// `vault create`, no `--email`. There is still NO non-interactive `ouro` credential-set sink (the
    /// documented gap a), so we cannot rotate silently: the chain runs in a NATIVE `.trusted` terminal
    /// (a real TTY) where the human enters the unlock secret + re-enters the provider credential.
    ///
    /// This REUSES F13's exit-matching markers + `completeVaultOnboarding` (so the re-probe-gated fold
    /// — `VaultOnboardingMachine.afterVaultTerminal`, which carries F1's `.working` invariant — is the
    /// SAME single fold, never duplicated). It records `.rotation` so a failed re-probe surfaces
    /// reconnect-flavored copy. The credential never routes through any agent context — only the TTY.
    func beginCredentialRotation(agentName: String, provider: WorkbenchProvider) {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        // RE-ENTRANCY GATE — mirror the cold-start hatch branch (which sets this flag synchronously
        // at ~submitProviderConfig before launching). Without it, Connect/Cancel stay fully enabled
        // with no spinner while the reconnect terminal is live, so a second Connect click re-enters
        // submitProviderConfig → beginCredentialRotation and OVERWRITES vaultOnboardingEntryID/RunID
        // to a SECOND terminal. The first terminal's exit then fails the entryId/runId match in
        // markTerminated, so its completion fold (the re-probe) never runs — the first terminal is
        // silently orphaned and two reconnect terminals race on the same vault. Setting this true
        // disables Connect/Cancel (the `.disabled(model.providerConfigColdStartInFlight)` modifiers
        // on those buttons) until `completeVaultOnboarding` clears it on EVERY exit path (the
        // unconditional `self.providerConfigColdStartInFlight = false` before its switch — success
        // AND failure — so a failed rotation re-enables the form for retry).
        providerConfigColdStartInFlight = true
        // F6 — flavor the spinner label for a reconnect (the shared flag's default copy reads
        // "Creating your agent…", which is wrong here). Reuse the rotation-flavored running line
        // from the Core seam so it stays seam-free and consistent with the secondary status text.
        providerConfigInFlightLabel =
            VaultOnboardingMachine.humanLine(for: .runningVaultTerminal, agentName: trimmed, flavor: .rotation)
            ?? "Reconnecting…"
        // Build the unlock chain from the PURE Core seam (single source of truth for the command
        // shape + shell-quoting). No `--email`: the existing agent's vault account already exists.
        let command = VaultOnboardingCommand.rotateCredentialCommandLine(
            agentName: trimmed,
            providerFlag: provider.providerFlagValue
        )
        let draft = CustomTerminalSessionDraft(
            name: "Reconnect: \(trimmed)",
            command: command,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            trust: .trusted,
            autoResume: false,
            notes: "Workbench credential rotation (reconnect) for \(trimmed)"
        )
        guard let entry = createCustomSession(draft, launchAfterCreate: true) else {
            // The terminal couldn't even launch — surface a launch failure honestly (the machine
            // folds a nil exit to .vaultCommandLaunchError). Set the flavor first so the failure copy
            // reads as a reconnect, then drive the SAME completion path.
            vaultOnboardingAgentName = trimmed
            vaultOnboardingFlavor = .rotation
            completeVaultOnboarding(vaultExitCode: nil)
            return
        }
        // Reuse the SAME exit-matching markers so markTerminated → completeVaultOnboarding handles
        // this terminal's exit with F13's re-probe-gated fold (no duplicated fold).
        vaultOnboardingEntryID = entry.id
        vaultOnboardingRunID = activeSessions[entry.id]?.plan.runId
        vaultOnboardingAgentName = trimmed
        vaultOnboardingFlavor = .rotation
        // F6 — show the form's honest in-flight/read-only status while the reconnect runs; the result
        // is only known after the re-probe (never from the terminal exit alone).
        providerConfigColdStartMessage =
            VaultOnboardingMachine.humanLine(for: .runningVaultTerminal, agentName: trimmed, flavor: .rotation)
        recordActionLog(
            source: "native",
            action: "beginCredentialRotation",
            targetName: trimmed,
            // Audit lane only — the raw recovery verbs (no credential; the human types that in the TTY).
            result: "opened reconnect terminal: \(command)",
            succeeded: true
        )
    }

    /// F13 — fold the finish-setup terminal's exit into the next state, gating `.ready` on a
    /// positive re-probe (the F1 safety invariant: NEVER `.ready` on a bare clean exit — the chain
    /// can exit 0 with a wedged daemon, so the re-probe is the sole authority on readiness).
    ///
    /// Called from `markTerminated` when the onboarding session ends. `vaultExitCode` is the decoded
    /// process exit, or `nil` when the terminal never launched. (When the one-shot screen session is
    /// still detached at terminate time we pass `0` — the chain DID launch and we observed no
    /// non-zero failure, so the decision falls entirely to the re-probe, which can only yield
    /// `.ready` on a real `.working`.)
    func completeVaultOnboarding(vaultExitCode: Int32?) {
        let agentName = (vaultOnboardingAgentName
            ?? providerConfigAgentName).trimmingCharacters(in: .whitespacesAndNewlines)
        // F6 — capture the flavor (onboarding vs rotation) BEFORE clearing markers, so a failed
        // re-probe surfaces the correctly-flavored seam-free copy.
        let flavor = vaultOnboardingFlavor
        // Clear the in-flight markers up front so a second termination event can't double-fire.
        vaultOnboardingEntryID = nil
        vaultOnboardingRunID = nil
        vaultOnboardingAgentName = nil
        providerConfigColdStartInFlight = true
        Task { [weak self] in
            // Only re-probe when the chain exited cleanly; a non-zero / never-launched exit is a
            // command failure the machine classifies WITHOUT a verdict (and re-probing a known
            // failure just burns 15s).
            let verdict: ProviderConnectionVerdict?
            if vaultExitCode == 0 {
                verdict = await self?.runColdStartProviderCheck(agentName: agentName, lane: "outward")
            } else {
                verdict = nil
            }
            let state = VaultOnboardingMachine.afterVaultTerminal(
                vaultExitCode: vaultExitCode,
                reprobeVerdict: verdict
            )
            await MainActor.run {
                guard let self else { return }
                self.providerConfigColdStartInFlight = false
                // Always refresh inventory/readiness so the bundle surfaces with its TRUE state.
                self.refreshOuroAgents()
                self.refreshOnboardingReadiness()
                self.runOnboardingProviderChecksIfNeeded()
                switch state {
                case .ready:
                    // Verified working — reuse F1's EXACT cold-start `.ready` side-effects, and
                    // clear the needs-vault flag so the form stops offering "Finish setup".
                    self.providerConfigNeedsVaultSetup = false
                    self.providerConfigColdStartProvider = nil
                    self.providerConfigColdStartMessage = nil
                    // Reset to the default flavor so a later onboarding attempt isn't mis-flavored.
                    self.vaultOnboardingFlavor = .onboarding
                    self.runFirstRunBootstrap()
                    self.recordActionLog(
                        source: "native",
                        action: "completeVaultOnboarding",
                        targetName: agentName,
                        result: "finish-setup recovery verified ready",
                        succeeded: true
                    )
                    self.isProviderConfigPresented = false
                case let .failed(reason):
                    // Honest failure: surface the seam-free Core human line and KEEP "Finish setup"
                    // available for retry (do NOT dismiss, do NOT clear the flag, do NOT log success).
                    // F6 — flavor the copy so an existing-agent ROTATION failure reads as a reconnect,
                    // not first-time setup.
                    self.providerConfigColdStartMessage =
                        VaultOnboardingMachine.humanLine(for: state, agentName: agentName, flavor: flavor)
                    self.recordActionLog(
                        source: "native",
                        action: "completeVaultOnboarding",
                        targetName: agentName,
                        result: "finish-setup recovery did not verify (outcome: \(reason.rawValue))",
                        succeeded: false
                    )
                default:
                    // afterVaultTerminal only ever returns .ready or .failed; this is unreachable.
                    break
                }
            }
        }
    }

    /// Open the native provider-config form in response to a non-secret-bearing
    /// `requestProviderConfig` onboarding action.
    ///
    /// NON-EXECUTING by contract: this runs NO command and carries NO credential. The agent can
    /// only ASK the app to open the form; the human supplies the credential inside the native
    /// form, which never routes through the agent's context/transcript. The effect here is a
    /// single published flag flip that presents the form — the one human touchpoint.
    private func openProviderConfig(action: BossWorkbenchAction, source: String) -> String {
        // Seed the form with the explicit agent name if the action named one (never relied on
        // for credentials — only to label which agent the form is connecting a provider for).
        let agentName = (action.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target = agentName.isEmpty ? state.boss.agentName : agentName
        presentProviderConfigForm(agentName: target)
        return finishBossAction(
            source: source,
            action: action,
            entry: nil,
            result: "Opened the provider setup form for \(target)."
        )
    }

    /// Kick off a headless `repairAgent` remediation.
    ///
    /// The remediation is async (spawn `ouro repair --agent <name>` headlessly → POST-command
    /// verify probe → classify), but `applyBossAction` is synchronous and the 2s pump narrates
    /// from the NEXT `workbench_onboarding_status` read, not this ack. So this returns an
    /// immediate seam-free "working on it" line, then surfaces the recovery-truth audit line
    /// into `bossAppliedActions` (and the action log) once the verify probe classifies — NEVER
    /// from the command's exit code.
    ///
    /// The agent name is taken EXPLICITLY from the action (validated non-empty at queueing and
    /// re-authorized via `authorizeEntryless` under `trustedOnboarding`); it never relies on
    /// `ouro` default-agent resolution. We re-guard here so a code path that skipped validation
    /// still can't run an agent-less repair (which could repair the wrong agent).
    private func startRepairAgent(action: BossWorkbenchAction, source: String) -> String {
        let agentName = (action.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty else {
            return finishBossAction(
                source: source,
                action: action,
                entry: nil,
                result: "Skipped repairAgent: missing explicit agent name"
            )
        }

        let runner = makeAgentRepairRunner()
        Task { [weak self] in
            let outcome = await runner.repair(agentName: agentName)
            await MainActor.run {
                self?.completeRepairAgent(action: action, source: source, outcome: outcome)
            }
        }

        // Immediate, seam-free ack. Recovery truth follows asynchronously via
        // completeRepairAgent — so this ack is in-flight (pending), not a green check.
        return finishBossAction(
            source: source,
            action: action,
            entry: nil,
            result: "Working on getting \(agentName) ready…",
            isInFlight: true
        )
    }

    /// Surface the recovery-truth outcome of a completed `repairAgent` cycle.
    ///
    /// Writes the human-facing (seam-free) line to `bossAppliedActions` for the UI and records
    /// the raw audit detail (carrying `ouro repair --agent <name>`) to the action log. The
    /// `succeeded` flag is the recovery truth — true ONLY when the post-command probe reads
    /// healthy (`repaired`), never off the exit code.
    private func completeRepairAgent(
        action: BossWorkbenchAction,
        source: String,
        outcome: AgentRepairOutcome
    ) {
        bossAppliedActions = Array(([outcome.humanFacingLine] + bossAppliedActions).prefix(12))
        recordActionLog(
            source: source,
            action: action.action.rawValue,
            targetName: outcome.agentName,
            result: outcome.auditDetail,
            succeeded: outcome.truth == .repaired
        )
        if bossWatchIsEnabled, outcome.needsManualRecovery {
            bossWatchLastError = outcome.auditDetail
        }
    }

    // MARK: - R4b first-run cold-start bootstrap (Layer A drive + handoff)

    /// Start the first-run bootstrap when conditions warrant it: a fresh / not-ready setup, an
    /// explicitly-resolved boss to target, not already running, and not already handed off. Safe
    /// to call from `onAppear` — it no-ops when those conditions aren't met (already agent-driven,
    /// already ready, mid-run). The pure run/skip decision is `FirstRunBootstrapDrive.shouldStart`.
    func startFirstRunBootstrapIfNeeded() {
        let bossName = (onboardingReadiness?.selectedBossName ?? state.boss.agentName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip the cold-start bootstrap for an agent that's ALREADY configured (it exists with
        // both provider lanes set). The bootstrap exists to bring a COLD-START agent online; for
        // a configured agent it only re-runs verify/refresh, piling more concurrent `ouro`
        // credential reads onto the daemon's bitwarden vault lock — which starves the wizard's
        // own lane checks and surfaces a confusing "setting up your agent" list for an agent that
        // is already set up. The serialized lane checks are the authority on its readiness.
        if let selectedAgent = ouroAgents.first(where: { $0.name.caseInsensitiveCompare(bossName) == .orderedSame }) {
            let outwardConfigured = selectedAgent.humanFacing?.provider != nil && selectedAgent.humanFacing?.model != nil
            let innerConfigured = selectedAgent.agentFacing?.provider != nil && selectedAgent.agentFacing?.model != nil
            if outwardConfigured && innerConfigured {
                return
            }
        }
        let decision = FirstRunBootstrapDrive.shouldStart(
            isReady: onboardingReadiness?.isReady ?? false,
            hasResolvedBoss: !bossName.isEmpty,
            isRunning: firstRunBootstrapIsRunning,
            currentMode: firstRunPresentation?.mode
        )
        guard decision else { return }
        runFirstRunBootstrap()
    }

    /// Drive the native cold-start bootstrap S0→S5 with the REAL injected effects, publishing the
    /// live per-step presentation (seam-free copy) and switching to agent-driven (Layer B) mode on
    /// the first successful `status` round-trip. The branching/sequencing/copy is all pure Core
    /// (`AgentReadinessBootstrap` + `FirstRunBootstrapDrive` + `FirstRunBootstrapEffectsResolver`);
    /// this is the thin app-side wiring that injects the real effects and publishes the result.
    func runFirstRunBootstrap() {
        guard !firstRunBootstrapIsRunning else { return }
        // #F9 — fresh recorder for THIS run's handoff-edge injection probe. The @Sendable
        // statusPing closure (off-main) writes the confirmed verdict here; `completeFirstRun‐
        // Bootstrap` (on main) drains it into `bossWorkbenchToolsInjectionByAgentName`. One
        // probe per bringup — never per readiness getter.
        bossWorkbenchToolsInjectionRecorder = WorkbenchToolsInjectionRecorder()
        let bossName = (onboardingReadiness?.selectedBossName ?? state.boss.agentName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Without an explicitly-resolved boss name there's nothing to bootstrap against; the
        // boss-choice surface handles that case. (The machine would also guard it, but we avoid
        // spinning up effects for an empty name.)
        guard !bossName.isEmpty else { return }

        firstRunBootstrapIsRunning = true
        // Seed the live presentation with all-pending steps so the UI shows progress immediately.
        firstRunPresentation = firstRunDrive.presentIdle()

        // The context's human/provider are only load-bearing for an S1 hatch; this app's S1 effect
        // defers cold-start agent creation to the S2 native form (which carries the provider +
        // credential), so they're best-effort here. The agent NAME is the load-bearing field —
        // explicitly resolved, never `ouro` default-agent resolution.
        let context = BootstrapAgentContext(
            agentName: bossName,
            humanName: deskHumanName(),
            provider: ""
        )
        let effects = makeFirstRunBootstrapEffects(agentName: bossName)
        let bootstrap = AgentReadinessBootstrap(context: context, effects: effects)

        Task { [weak self] in
            let result = await bootstrap.run()
            await MainActor.run {
                self?.completeFirstRunBootstrap(result: result, agentName: bossName)
            }
        }
    }

    /// Build the REAL `BootstrapStepEffects` from the existing slice pieces, each carrying the
    /// EXPLICIT resolved boss name (never `ouro` default-agent resolution) and classifying recovery
    /// truth from a POST-effect probe, never an exit code. This is the R4b composition seam: every
    /// prior slice's runner traces to a shipped implementation here —
    ///   S0 `DaemonManager.ensureRunning` (the shared `daemonManager`),
    ///   S1 cold-start agent existence (deferring creation to the gate),
    ///   S2 the native provider form as the ONE human gate (parks if creds absent),
    ///   S3 `ProviderRefreshRunner`, S4 `ProviderVerifyRunner`, S5 `WorkbenchMCPRegistrationRunner`,
    ///   and the handoff edge = the first successful `BossAgentMCPClient.status` round-trip.
    private func makeFirstRunBootstrapEffects(agentName: String) -> BootstrapStepEffects {
        let manager = daemonManager
        // Capture the bundles URL (Sendable) and rebuild a fresh inventory inside the @Sendable
        // closures — `OuroAgentInventory` holds a non-Sendable `FileManager`, so we don't capture
        // the instance. A fresh `.default`-FileManager inventory scans identically.
        let bundlesURL = ouroAgentInventory.agentBundlesURL
        let registrar = bossWorkbenchMCPRegistrar
        let client = bossMCPClient
        // #F9 — the handoff-edge probe writes the per-agent injection verdict here (off-main);
        // drained into the published cache on the main actor after the run finishes.
        let injectionRecorder = bossWorkbenchToolsInjectionRecorder

        // S3/S4 post-command verify probes reuse the SAME readiness signal as the handoff edge:
        // a `BossAgentMCPClient.status` round-trip (usable answer = healthy; any failure =
        // unreachable). A successful probe genuinely proves the agent is serving.
        let nameProbe: @Sendable (String) async -> AgentRepairProbe = { name in
            do { _ = try await client.status(agentName: name); return .healthy }
            catch { return .unreachable }
        }
        let laneProbe: @Sendable (String, ProviderLane?) async -> AgentRepairProbe = { name, _ in
            do { _ = try await client.status(agentName: name); return .healthy }
            catch { return .unreachable }
        }

        let refreshRunner = ProviderRefreshRunner(verifyProbe: nameProbe)
        let verifyRunner = ProviderVerifyRunner(verifyProbe: laneProbe)
        let mcpRunner = WorkbenchMCPRegistrationRunner(
            runRegister: { name in _ = try registrar.install(for: BossAgentSelection(agentName: name)) },
            snapshotProbe: { name in registrar.snapshot(for: BossAgentSelection(agentName: name)).status }
        )

        return BootstrapStepEffects(
            // S0 — ensure the daemon (detect-reuse-else-start). Recovery truth from the post-start
            // verify probe, classified inside `DaemonManager`, mapped here to StepHealth.
            ensureDaemon: {
                let outcome = await manager.ensureRunning()
                return outcome.liveness == .up ? .healthy : .needsManual
            },
            // S1 — ensure a usable agent exists. Cold-start defers agent creation to the S2 form,
            // so this reads `.healthy` from a freshly-scanned inventory (existing agent verifies;
            // absent agent lets the run REACH the gate, which then parks). Pure resolver decides.
            ensureAgentExists: { name in
                let agents = OuroAgentInventory(agentBundlesURL: bundlesURL).scan()
                return FirstRunBootstrapEffectsResolver.ensureAgentExistsHealth(named: name, in: agents)
            },
            // S2 — the ONE human gate. Reads the creds signal from a freshly-scanned inventory:
            // `credentialsPresent` advances; `absent` PARKS (the only exit is the human supplying
            // creds via the native form, which the UI surfaces in the parked mode). Checked once.
            providerConfig: {
                let agents = OuroAgentInventory(agentBundlesURL: bundlesURL).scan()
                return FirstRunBootstrapEffectsResolver.providerGateStatus(named: agentName, in: agents)
            },
            // S3 — vault/provider sync: push the agent's stored vault creds into the running
            // daemon (`ouro provider refresh`). Recovery truth from the post-command probe.
            vaultSync: { name in
                let outcome = await refreshRunner.refresh(agentName: name)
                switch outcome.truth {
                case .refreshed: return .healthy
                case .stillDegraded: return .stillDegraded
                case .needsManual: return .needsManual
                }
            },
            // S4 — verify the configured credentials actually work (`ouro auth verify`, lane-less).
            verifyCredentials: { name in
                let outcome = await verifyRunner.verify(agentName: name, lane: nil)
                switch outcome.truth {
                case .verified: return .healthy
                case .stillUnverified: return .stillDegraded
                case .needsManual: return .needsManual
                }
            },
            // S5 — make the Workbench tools available to the boss at RUNTIME. Under runtime
            // injection nothing is written to the synced bundle: Workbench passes `--workbench-mcp`
            // when it launches the boss. This effect verifies the binary is present (runtime
            // injection available) and CLEANS any stale bundle entry an older Workbench left. The
            // registrar's cleanup + snapshot are wrapped as the bootstrap effect; recovery truth is
            // the post-cleanup snapshot.
            registerWorkbenchMCP: { name in
                let outcome = await mcpRunner.register(agentName: name)
                switch outcome.truth {
                case .registered: return .healthy
                case .stillUnregistered: return .stillDegraded
                case .needsManual: return .needsManual
                }
            },
            // Handoff edge (#F9) — the boss-native `status` round-trip ALONE no longer ends
            // Layer A: an old `ouro` answers `status` fine after silently stripping every
            // `workbench_*` tool. So we AND it with a live `tools/list` injection probe and
            // hand off only when the boss can actually drive Workbench (`WorkbenchHandoffGate`):
            //   • status fails              → not handed off (awaiting).
            //   • status ok + CONFIRMED present → handed off.
            //   • status ok + CONFIRMED absent  → tools stripped: stay awaiting AND record
            //                                     the verdict so the registration flips to the
            //                                     `.toolsNotInjected` blocker.
            //   • status ok + probe couldn't answer (timeout / spawn error) → stay awaiting,
            //                                     UNCONFIRMED — never a false "your ouro is too
            //                                     old" on a slow cold start.
            statusPing: { name in
                let statusOK: Bool
                do { _ = try await client.status(agentName: name); statusOK = true }
                catch { statusOK = false }

                // Only probe injection once status answered — a dead boss is awaiting, not
                // stripped. A probe that throws (timeout / spawn error) is UNCONFIRMED.
                var injection: WorkbenchToolsInjectionProbeOutcome = .unconfirmed
                if statusOK {
                    do {
                        let names = try await client.listToolNames(agentName: name)
                        injection = .confirmed(WorkbenchToolsInjectionProbe.verdict(fromToolNames: names))
                    } catch {
                        injection = .unconfirmed
                    }
                }
                injectionRecorder.record(agentName: name, outcome: injection)

                let decision = WorkbenchHandoffGate.decide(statusPingSucceeded: statusOK, injectionProbe: injection)
                return decision.isHandedOff
            }
        )
    }

    /// Apply a finished bootstrap run to the UI: publish the live presentation and, on handoff,
    /// switch to agent-driven (Layer B) mode — surface the seam-free handoff narration and let the
    /// boss inspect (`workbench_onboarding_status`) + remediate (issue onboarding actions) +
    /// narrate. From here the human is never asked to run anything; applied actions land in
    /// `bossAppliedActions`. On a S2 park, surface the native provider form (the one touchpoint).
    private func completeFirstRunBootstrap(result: BootstrapResult, agentName: String) {
        firstRunBootstrapIsRunning = false
        let presentation = firstRunDrive.present(result: result, activeStep: nil)
        firstRunPresentation = presentation
        // #F9 — drain the handoff-edge injection verdict BEFORE refreshing the registration, so
        // the overlay flips a present-but-stripped boss to `.toolsNotInjected` in the same pass.
        let injectionVerdicts = bossWorkbenchToolsInjectionRecorder.snapshot()
        for (agent, outcome) in injectionVerdicts {
            bossWorkbenchToolsInjectionByAgentName[agent] = outcome
        }
        // Keep the readiness snapshot coherent with whatever the bootstrap just changed.
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        refreshOnboardingReadiness()

        // #F9 — audit a confirmed tool-strip in the action-log / debug lane (raw verbs allowed
        // here only — the human-facing copy lives in `BossBridgeContract.bridgeVerdict`).
        if case .confirmed(.absent) = injectionVerdicts[agentName] {
            recordActionLog(
                source: "native",
                action: "workbenchToolsInjectionProbe",
                targetName: agentName,
                result: "tools/list returned no workbench_* tools — `ouro mcp-serve --workbench-mcp` likely ignored by an ouro below alpha.\(OuroVersionFloor.minimumAlpha); registration flipped to toolsNotInjected.",
                succeeded: false
            )
        }

        // Audit the settled phase (raw verbs allowed in the action log / debug lane only).
        recordActionLog(
            source: "native",
            action: "firstRunBootstrap",
            targetName: result.didHandOff ? "handed-off" : "layer-a",
            result: result.stepOutcomes.map(\.auditDetail).joined(separator: " | "),
            succeeded: result.didHandOff
        )

        if presentation.didHandOff {
            // HANDOFF: Layer A guaranteed {daemon ∧ boss bundle ∧ creds ∧ MCP}; the first
            // `status` round-trip succeeded. Layer B takes the wheel — surface the agent-driven
            // narration; the boss's applied actions land in `bossAppliedActions` from here on.
            firstRunAgentDrivenNarration = FirstRunBootstrapDrive.agentDrivenHandoffNarration
            bossAppliedActions = Array(
                ([FirstRunBootstrapDrive.agentDrivenHandoffNarration] + bossAppliedActions).prefix(12)
            )
        } else if presentation.opensProviderGate {
            // PARKED at the S2 gate — surface the native provider form (the one human touchpoint).
            // The form, on submit, runs the cold-start hatch with the credential and re-runs the
            // parked bootstrap (`submitProviderConfig` → `runFirstRunBootstrap`), crossing S2.
            firstRunAgentDrivenNarration = nil
            presentProviderConfigForm(agentName: agentName)
        } else {
            firstRunAgentDrivenNarration = nil
        }
    }

    /// The human name the bootstrap context carries for a cold-start hatch. Best-effort: the
    /// current macOS short user name (the native provider form itself collects the human name).
    private func deskHumanName() -> String {
        NSUserName()
    }

    /// The machine owner's display name (full name, username fallback) — woven into
    /// the boss's check-in questions and quick-question chips so the agent reports on
    /// the ACTUAL operator, never a hardcoded name. Static so property initializers
    /// (the prompt builders) can resolve it before `self` exists.
    static func resolvedOwnerName() -> String {
        SessionFriend.machineOwner()?.name ?? NSUserName()
    }

    /// Instance accessor for `resolvedOwnerName()`, used to substitute the `{{owner}}`
    /// token in the quick-question chips and per-session questions.
    private var ownerDisplayName: String { Self.resolvedOwnerName() }

    /// Run an onboarding repair step APP-EXECUTED (headless, no pane), classifying from a
    /// post-command verify probe — the human-as-hands path is gone. Maps the step id to the
    /// existing recovery-truth runner: `repair-agent-config` → `AgentRepairRunner`;
    /// `check-outward` / `check-inner` → `ProviderVerifyRunner` (lane-scoped). The Setup Assistant
    /// never hands a raw `ouro …` command to the human; the seam-free ack copy is pure Core.
    private func runOnboardingRepairStepNatively(_ step: OnboardingRepairStep) {
        let agentName = (onboardingReadiness?.selectedBossName ?? state.boss.agentName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty else { return }

        switch step.id {
        case "repair-agent-config":
            let runner = makeAgentRepairRunner()
            if let ack = NativeOnboardingRepairCopy.inProgressLine(forStepID: step.id) {
                bossAppliedActions = Array(([ack] + bossAppliedActions).prefix(12))
            }
            Task { [weak self] in
                let outcome = await runner.repair(agentName: agentName)
                await MainActor.run {
                    self?.surfaceNativeRepairLine(
                        humanFacingLine: outcome.humanFacingLine,
                        auditDetail: outcome.auditDetail,
                        targetName: outcome.agentName,
                        action: "repairAgent",
                        succeeded: outcome.truth == .repaired,
                        needsManual: outcome.needsManualRecovery
                    )
                }
            }
        case "check-outward", "check-inner":
            let lane: ProviderLane = (step.id == "check-outward") ? .outward : .inner
            let runner = ProviderVerifyRunner(verifyProbe: makeProbe())
            if let ack = NativeOnboardingRepairCopy.inProgressLine(forStepID: step.id) {
                bossAppliedActions = Array(([ack] + bossAppliedActions).prefix(12))
            }
            Task { [weak self] in
                let outcome = await runner.verify(agentName: agentName, lane: lane)
                await MainActor.run {
                    self?.surfaceNativeRepairLine(
                        humanFacingLine: outcome.humanFacingLine,
                        auditDetail: outcome.auditDetail,
                        targetName: outcome.agentName,
                        action: "verifyProvider",
                        succeeded: outcome.truth == .verified,
                        needsManual: outcome.needsManualRecovery
                    )
                }
            }
        case "repair-outward-provider", "repair-inner-provider":
            // A configured lane whose LIVE check failed. The form can't refresh an existing
            // agent's creds (gap a), so the useful action is a RE-CHECK: it self-heals a
            // transient failure (a lock-contended vault, a network blip — exactly the kind that
            // previously left this as a dead no-op button) and honestly re-reports a real one.
            // `runOnboardingProviderChecksIfNeeded` re-runs any non-passed lane (a `.failed` lane
            // qualifies), flipping the row to a live "Checking…" spinner for immediate feedback.
            runOnboardingProviderChecksIfNeeded()
        default:
            // No other step reaches here (provider-setup short-circuits in `openOnboardingRepair`;
            // workbench-mcp has its own button; check-* in `running` state render a spinner).
            // Re-probe readiness so the surface stays coherent.
            refreshOnboardingReadiness()
        }
    }

    /// Surface a natively-run onboarding repair step's recovery truth: seam-free line →
    /// `bossAppliedActions`; raw audit detail → action log; `succeeded` is the post-command probe
    /// truth, never an exit code. Then re-probe readiness so the surface reflects the new state.
    private func surfaceNativeRepairLine(
        humanFacingLine: String,
        auditDetail: String,
        targetName: String,
        action: String,
        succeeded: Bool,
        needsManual: Bool
    ) {
        bossAppliedActions = Array(([humanFacingLine] + bossAppliedActions).prefix(12))
        recordActionLog(
            source: "native",
            action: action,
            targetName: targetName,
            result: auditDetail,
            succeeded: succeeded
        )
        if bossWatchIsEnabled, needsManual {
            bossWatchLastError = auditDetail
        }
        refreshOuroAgents()
        refreshOnboardingReadiness()
    }

    /// Build the headless repair runner. The default verify probe is a post-command
    /// `BossAgentMCPClient.status(agentName:)` round-trip: a usable answer = healthy; any
    /// failure (no answer / transport) = unreachable. This is the SAME readiness signal as the
    /// boss check-in's MCP round-trip, so a successful probe genuinely proves the agent is
    /// serving. The repair command spawns headlessly (no pane) via `AgentRepairRunner`'s
    /// daemon-spawn env pattern (`/usr/bin/env ouro …` + resolved PATH).
    private func makeAgentRepairRunner() -> AgentRepairRunner {
        let client = bossMCPClient
        return AgentRepairRunner(
            runRepair: AgentRepairRunner.headlessRepair,
            verifyProbe: { name in
                do {
                    _ = try await client.status(agentName: name)
                    return .healthy
                } catch {
                    return .unreachable
                }
            }
        )
    }

    /// Kick off a headless `verifyProvider` remediation (`ouro auth verify` / `ouro check
    /// --lane`). Async like `repairAgent`: returns an immediate seam-free ack, then surfaces the
    /// recovery-truth (from the POST-command verify probe, never the exit code) once it lands.
    ///
    /// The agent name is taken EXPLICITLY from the action (validated non-empty at queueing and
    /// re-authorized via `authorizeEntryless` under `trustedOnboarding`); it never relies on
    /// `ouro` default-agent resolution. We re-guard here so a path that skipped validation can't
    /// verify the wrong agent.
    private func startVerifyProvider(action: BossWorkbenchAction, source: String) -> String {
        let agentName = (action.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty else {
            return finishBossAction(
                source: source, action: action, entry: nil,
                result: "Skipped verifyProvider: missing explicit agent name"
            )
        }
        let lane = action.lane
        let runner = ProviderVerifyRunner(verifyProbe: makeProbe())
        Task { [weak self] in
            let outcome = await runner.verify(agentName: agentName, lane: lane)
            await MainActor.run {
                self?.completeOnboardingAction(
                    action: action, source: source, targetName: outcome.agentName,
                    humanFacingLine: outcome.humanFacingLine, auditDetail: outcome.auditDetail,
                    succeeded: outcome.truth == .verified, needsManual: outcome.needsManualRecovery
                )
            }
        }
        // In-flight ack — the verified outcome lands later via completeOnboardingAction.
        return finishBossAction(
            source: source, action: action, entry: nil,
            result: "Checking \(agentName)'s provider connection…",
            isInFlight: true
        )
    }

    /// Kick off a headless `refreshProvider` remediation (`ouro provider refresh --agent`). Same
    /// shape as `verifyProvider`: explicit agent name, immediate ack, recovery truth from the
    /// POST-command probe. Carries no secret — it re-pushes already-stored vault creds.
    private func startRefreshProvider(action: BossWorkbenchAction, source: String) -> String {
        let agentName = (action.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty else {
            return finishBossAction(
                source: source, action: action, entry: nil,
                result: "Skipped refreshProvider: missing explicit agent name"
            )
        }
        let runner = ProviderRefreshRunner(verifyProbe: makeProbe())
        Task { [weak self] in
            let outcome = await runner.refresh(agentName: agentName)
            await MainActor.run {
                self?.completeOnboardingAction(
                    action: action, source: source, targetName: outcome.agentName,
                    humanFacingLine: outcome.humanFacingLine, auditDetail: outcome.auditDetail,
                    succeeded: outcome.truth == .refreshed, needsManual: outcome.needsManualRecovery
                )
            }
        }
        // In-flight ack — the verified outcome lands later via completeOnboardingAction.
        return finishBossAction(
            source: source, action: action, entry: nil,
            result: "Refreshing \(agentName)'s connection…",
            isInFlight: true
        )
    }

    /// Kick off a headless `selectLane` remediation (`ouro use --agent --lane --provider
    /// --model`). CONFIG-ONLY — carries no secret. Re-guards the fully-specified payload (agent
    /// name + lane + provider + model); any missing piece skips before any command runs.
    private func startSelectLane(action: BossWorkbenchAction, source: String) -> String {
        let agentName = (action.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty,
              let lane = action.lane,
              let provider = nonEmpty(action.provider),
              let model = nonEmpty(action.model) else {
            return finishBossAction(
                source: source, action: action, entry: nil,
                result: "Skipped selectLane: missing explicit agent name, lane, provider, or model"
            )
        }
        let selection = LaneSelection(agentName: agentName, lane: lane, provider: provider, model: model)
        let runner = LaneSelectionRunner(verifyProbe: makeProbe())
        Task { [weak self] in
            let outcome = await runner.select(selection)
            await MainActor.run {
                self?.completeOnboardingAction(
                    action: action, source: source, targetName: outcome.selection.agentName,
                    humanFacingLine: outcome.humanFacingLine, auditDetail: outcome.auditDetail,
                    succeeded: outcome.truth == .selected, needsManual: outcome.needsManualRecovery
                )
            }
        }
        // In-flight ack — the verified outcome lands later via completeOnboardingAction.
        return finishBossAction(
            source: source, action: action, entry: nil,
            result: "Setting up \(agentName) with \(provider)…",
            isInFlight: true
        )
    }

    /// Kick off a `registerWorkbenchMCP` remediation. RUNTIME-INJECTION model: there is nothing to
    /// "register" into the bundle — Workbench injects the tools at runtime via `--workbench-mcp`.
    /// This WRAPS the registrar's cleanup (`bossWorkbenchMCPRegistrar.install`, now a stale-entry
    /// cleanup) + snapshot (binary-present + bundle-clean) as an agent-issuable action; recovery
    /// truth comes from the POST-command registrar SNAPSHOT, never the cleanup throw.
    private func startRegisterWorkbenchMCP(action: BossWorkbenchAction, source: String) -> String {
        let agentName = (action.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty else {
            return finishBossAction(
                source: source, action: action, entry: nil,
                result: "Skipped registerWorkbenchMCP: missing explicit agent name"
            )
        }
        let registrar = bossWorkbenchMCPRegistrar
        let runner = WorkbenchMCPRegistrationRunner(
            runRegister: { name in
                _ = try registrar.install(for: BossAgentSelection(agentName: name))
            },
            snapshotProbe: { name in
                registrar.snapshot(for: BossAgentSelection(agentName: name)).status
            }
        )
        Task { [weak self] in
            let outcome = await runner.register(agentName: agentName)
            await MainActor.run {
                // Keep the native registration cache coherent with what the action just wrote.
                self?.refreshWorkbenchMCPRegistration()
                self?.completeOnboardingAction(
                    action: action, source: source, targetName: outcome.agentName,
                    humanFacingLine: outcome.humanFacingLine, auditDetail: outcome.auditDetail,
                    succeeded: outcome.truth == .registered, needsManual: outcome.needsManualRecovery
                )
            }
        }
        // In-flight ack — the verified outcome lands later via completeOnboardingAction.
        return finishBossAction(
            source: source, action: action, entry: nil,
            result: "Connecting \(agentName) to Workbench…",
            isInFlight: true
        )
    }

    /// Kick off an `ensureDaemon` remediation. WRAPS Slice 0's `DaemonManager.ensureRunning()`
    /// (detect-reuse-else-start) as an agent-issuable action; recovery truth comes from its
    /// existing post-start verify-probe classification, never an exit code. No agent name — the
    /// daemon is machine-scoped infrastructure. Reuses the SAME `daemonManager` the check-in
    /// path uses so the agent-issued ensure and the implicit check-in ensure share one config.
    private func startEnsureDaemon(action: BossWorkbenchAction, source: String) -> String {
        let manager = daemonManager
        Task { [weak self] in
            let start = await manager.ensureRunning()
            let outcome = DaemonEnsureActionOutcome(start: start)
            await MainActor.run {
                self?.completeOnboardingAction(
                    action: action, source: source, targetName: "daemon",
                    humanFacingLine: outcome.humanFacingLine, auditDetail: outcome.auditDetail,
                    succeeded: outcome.succeeded, needsManual: outcome.needsManualRecovery
                )
            }
        }
        // In-flight ack — the verified outcome lands later via completeOnboardingAction.
        return finishBossAction(
            source: source, action: action, entry: nil,
            result: "Bringing your agent's connection online…",
            isInFlight: true
        )
    }

    /// U30(b): the boss's `workbench_report_bug` drain. Captures the defect (carried in
    /// `action.text`) into the SAME anonymized bug-report bundle a human creates — it reuses
    /// `submitBugReport(note:source:)`, so the bundle flows through the identical
    /// `BugReportWriter` + `WorkbenchBugReportRedactor` path (live state: sessions, decisions,
    /// the action log, a window screenshot) and lands a durable unfiled status. The resulting
    /// bundle is revealable + File-as-Issue-able exactly like a human-created one; filing to
    /// GitHub stays human-gated.
    private func startReportBug(action: BossWorkbenchAction, source: String) -> String {
        let note = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else {
            return finishBossAction(
                source: source, action: action, entry: nil,
                result: "Skipped reportBug: missing note"
            )
        }
        submitBugReport(note: note, source: source)
        // In-flight ack — `submitBugReport` writes the bundle off-main and records the
        // VERIFIED outcome later via `recordActionLog(action: "submitBugReport", …)`.
        // That settled row logs under a different `action` than this optimistic ack,
        // so the two never supersede each other: marking this pending keeps a failed
        // write from leaving a green "Writing…" row standing beside the orange "Failed".
        return finishBossAction(
            source: source, action: action, entry: nil,
            result: "Writing an anonymized bug report for \"\(note)\"…",
            isInFlight: true
        )
    }

    /// Surface the recovery-truth outcome of a completed onboarding action. Mirrors
    /// `completeRepairAgent`: human-facing (seam-free) line → `bossAppliedActions`; raw audit
    /// detail → action log; `succeeded` is the recovery truth (from the post-command probe).
    private func completeOnboardingAction(
        action: BossWorkbenchAction,
        source: String,
        targetName: String,
        humanFacingLine: String,
        auditDetail: String,
        succeeded: Bool,
        needsManual: Bool
    ) {
        bossAppliedActions = Array(([humanFacingLine] + bossAppliedActions).prefix(12))
        recordActionLog(
            source: source,
            action: action.action.rawValue,
            targetName: targetName,
            result: auditDetail,
            succeeded: succeeded
        )
        if bossWatchIsEnabled, needsManual {
            bossWatchLastError = auditDetail
        }
    }

    /// The shared POST-command verify probe for the agent-targeted onboarding actions: a
    /// `BossAgentMCPClient.status(agentName:)` round-trip (a usable answer = healthy; any failure
    /// = unreachable). This is the SAME readiness signal as the boss check-in's MCP round-trip,
    /// so a successful probe genuinely proves the agent is serving. Returned in the
    /// `(name, lane?)` shape `ProviderVerifyRunner` expects; the lane never affects the probe (it
    /// classifies the whole agent's readiness).
    private func makeProbe() -> @Sendable (String, ProviderLane?) async -> AgentRepairProbe {
        let client = bossMCPClient
        return { name, _ in
            do {
                _ = try await client.status(agentName: name)
                return .healthy
            } catch {
                return .unreachable
            }
        }
    }

    /// The name-only verify-probe variant for runners that don't carry a lane
    /// (`refreshProvider`, `selectLane`).
    private func makeProbe() -> @Sendable (String) async -> AgentRepairProbe {
        let client = bossMCPClient
        return { name in
            do {
                _ = try await client.status(agentName: name)
                return .healthy
            } catch {
                return .unreachable
            }
        }
    }

    /// `isInFlight: true` ONLY for an async "start" handler's optimistic ack — the
    /// background work has been kicked off but its VERIFIED outcome (recorded later
    /// by the matching `complete*` handler) isn't known yet. Such an ack renders
    /// neutral/pending, never a green check. A synchronous guard-skip or a final
    /// result stays `false` so its `succeeded` flag drives green/orange honestly.
    private func finishBossAction(
        source: String,
        action: BossWorkbenchAction,
        entry: ProcessEntry?,
        result: String,
        isInFlight: Bool = false
    ) -> String {
        recordActionLog(
            source: source,
            action: action.action.rawValue,
            targetEntryId: entry?.id,
            targetName: entry?.name ?? action.entry ?? action.name ?? action.group,
            result: result,
            succeeded: !result.hasPrefix("Skipped") && !result.hasPrefix("Failed"),
            isInFlight: isInFlight
        )
        return result
    }

    private func recordActionLog(
        source: String,
        action: String,
        targetEntryId: UUID? = nil,
        targetName: String? = nil,
        result: String,
        succeeded: Bool,
        isInFlight: Bool = false
    ) {
        state.actionLog.insert(
            WorkbenchActionLogEntry(
                source: source,
                action: action,
                targetEntryId: targetEntryId,
                targetName: targetName,
                result: result,
                succeeded: succeeded,
                requestId: currentBossActionRequestId,
                isInFlight: isInFlight
            ),
            at: 0
        )
        if state.actionLog.count > 200 {
            state.actionLog.removeLast(state.actionLog.count - 200)
        }
        save()
    }

    private func processEntry(matching value: String) -> ProcessEntry? {
        if let id = UUID(uuidString: value), let entry = state.processEntries.first(where: { $0.id == id }) {
            return entry
        }
        let nameMatches = state.processEntries.filter { entry in
            entry.name.caseInsensitiveCompare(value) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func project(matching value: String?) -> WorkbenchProject? {
        guard let value = nonEmpty(value) else {
            return selectedProject ?? state.projects.first
        }
        if let id = UUID(uuidString: value), let project = state.projects.first(where: { $0.id == id }) {
            return project
        }
        let nameMatches = state.projects.filter { project in
            project.name.caseInsensitiveCompare(value) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Pre-launch validation. Returns a human-readable problem ONLY for
    /// unambiguously-broken *fresh spawns* — a deleted working directory or a
    /// command given as a concrete path that's missing / not executable.
    ///
    /// Deliberately conservative to avoid false-blocks:
    /// - Recover / auto-resume plans (`recoveryAction != nil`) are skipped:
    ///   `screen -D -RR` reattaches to a still-live session, where neither the
    ///   original cwd nor a freshly-resolvable command is required.
    /// - Bare-name commands (resolved via PATH) and shell-wrapped commands
    ///   (`zsh -lc "agent …"`) are NOT blocked on a PATH miss, because the
    ///   health checker can't see shell functions / aliases / login-shell PATH
    ///   that the real launch would. We only hard-block a command that is an
    ///   explicit path (`contains "/"`), which is unambiguous.
    private func launchPreflightProblem(for entry: ProcessEntry, plan: TerminalCommandPlan) -> String? {
        // A reattach/recover doesn't need the original cwd or command.
        guard plan.recoveryAction == nil else {
            return nil
        }
        let workingDirectory = entry.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workingDirectory.isEmpty {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory)
            if !exists || !isDirectory.boolValue {
                return "\(entry.name): working directory doesn't exist — \(workingDirectory)"
            }
        }
        // F12a gap 2 — the OUTER `screen` multiplexer every persistent session is
        // wrapped in (PersistentTerminalSession.executable). If it's missing or not
        // runnable the wrapped command exits 127 with a dead-end message; catch that
        // BEFORE the spawn (the primary fix; markTerminated is the TOCTOU backstop).
        // GATED on `plan.persistentSessionName != nil`: a direct spawn (cold-start /
        // provider probe runs `ouro`/`gh` without a screen wrapper) has no
        // multiplexer to blame, so its 127 must never be misattributed here.
        if plan.persistentSessionName != nil {
            let screenHealth = executableHealthChecker.health(for: PersistentTerminalSession.executable)
            switch screenHealth.status {
            case .missing, .notExecutable:
                return "\(entry.name): the terminal multiplexer (screen) is missing or not runnable — \(screenHealth.detail)"
            case .available:
                break
            }
        }
        // Only validate a command that's an explicit path; bare names and
        // shell-wrapped commands resolve through PATH / the shell at launch in
        // ways the checker can't fully model, so blocking them risks false
        // negatives (e.g. agents defined as shell functions).
        let resolved = ExecutableHealthTarget.executable(for: entry)
        guard resolved.contains("/") else {
            return nil
        }
        let health = executableHealthChecker.health(for: resolved)
        switch health.status {
        case .available:
            return nil
        case .missing, .notExecutable:
            return "\(entry.name): \(health.detail)"
        }
    }

    /// Build the per-session Workbench context handed to a launching terminal
    /// so the agent inside can detect and describe its host. Refreshes the
    /// on-disk inner-agent context file (cheap, atomic) so the boss name stays
    /// current; a write failure never blocks the launch.
    private func workbenchSessionContext(for entry: ProcessEntry) -> WorkbenchSessionContext {
        let bossName = state.boss.agentName
        let contextURL = try? WorkbenchContextFile.write(
            to: WorkbenchContextFile.defaultURL(paths: paths),
            boss: bossName
        )
        let groupName = state.projects.first { $0.id == entry.projectId }?.name
        return WorkbenchSessionContext(
            contextFilePath: contextURL?.path,
            group: groupName,
            session: entry.name,
            boss: bossName
        )
    }

    private func start(_ entry: ProcessEntry, with plan: TerminalCommandPlan) async {
        // F11a Defect 2 — re-entrancy guard. `start` now suspends on an awaited
        // `screen` quit (the `.quitThenAwait` arm below), so a second start for
        // this same entry could run on the main actor during that suspension —
        // both reading the same stale `activeSessions[id]`, racing two `-D -RR`
        // on one socket and leaking the first session. Drop a concurrent start
        // for an entry already starting; clear on every exit path.
        guard !startingEntryIDs.contains(entry.id) else {
            return
        }
        startingEntryIDs.insert(entry.id)
        defer { startingEntryIDs.remove(entry.id) }
        // Validate before we tear down any existing session or spawn a new
        // one, so a misconfigured launch surfaces a clear error instead of a
        // silent dead session or one running in the wrong directory.
        if let problem = launchPreflightProblem(for: entry, plan: plan) {
            errorMessage = problem
            updateEntry(entry.id) { mutable in
                mutable.attention = .needsBossReview
                mutable.lastSummary = problem
            }
            recordActionLog(
                source: "native",
                action: "launchPreflightFailed",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: problem,
                succeeded: false
            )
            return
        }
        do {
            // F11a Defect 2 — when a session is already live on this entry's
            // `screen` socket, the old path fire-and-forget `screen -X quit`'d it
            // and then SYNCHRONOUSLY launched `screen -D -RR` on the SAME socket:
            // the reattach got yanked mid-attach, or -RR forked a fresh daemon and
            // lost scrollback. The pure `StartSequencer` decides the typed step;
            // on `.quitThenAwait` we AWAIT the quit to completion BEFORE the
            // relaunch so they never race. `.launchImmediately` (no live session)
            // has no quit to await.
            let step = StartSequencer().step(
                forEntryId: entry.id,
                hasActiveSessionOnSocket: activeSessions[entry.id] != nil
            )
            switch step {
            case .quitThenAwait:
                if let existingSession = activeSessions[entry.id] {
                    manuallyTerminatedRunIDs.insert(existingSession.plan.runId)
                    // Await the screen quit so the socket is free before -D -RR,
                    // then tear down the local client and record the manual end.
                    await existingSession.terminatePersistentSessionAwaiting()
                    existingSession.terminateLocalClient()
                    markTerminated(entryId: entry.id, runId: existingSession.plan.runId, rawStatus: nil)
                }
            case .launchImmediately:
                break
            }
            let session = try TerminalSessionController(
                plan: plan,
                workbenchContext: workbenchSessionContext(for: entry),
                onStarted: { [weak self] pid in
                    self?.markStarted(plan: plan, pid: pid)
                },
                onOutput: { [weak self] in
                    self?.markOutput(entryId: entry.id, runId: plan.runId)
                },
                onTerminated: { [weak self] rawStatus in
                    self?.markTerminated(entryId: entry.id, runId: plan.runId, rawStatus: rawStatus)
                }
            )
            // Apply the persisted font size before the session paints anything
            // so the user's chosen ⌘+/⌘-/⌘0 size is honored from the first
            // frame instead of springing from the hardcoded 13pt default.
            session.terminal.font = NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
            activeSessions[entry.id] = session
            session.start()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func markStarted(plan: TerminalCommandPlan, pid: Int32?) {
        updateEntry(plan.entryId) { entry in
            entry.attention = .active
            // The operator-visible status (and the boss prompt) read a plain
            // sentence keyed off the plan's typed `kind` (U40), not the planner's
            // technical raw `reason` ("respawn X from persisted workbench
            // context"). The raw reason stays in the plan for logs / disclosure.
            entry.lastSummary = terminalCommandPlanPhrasebook.operatorSentence(
                for: plan.kind,
                entryName: entry.name
            )
        }
        state.processRuns.removeAll { $0.id == plan.runId }
        state.processRuns.append(
            ProcessRun(
                id: plan.runId,
                entryId: plan.entryId,
                pid: pid,
                status: .running,
                transcriptPath: plan.transcriptPath
            )
        )
        // Cap retained runs per entry so processRuns can't grow without bound
        // across relaunches/recoveries (and bloat every synchronous save).
        state.pruneProcessRuns()
        save()
    }

    /// Record that a run produced output. Coalesced: instead of mutating
    /// `@Published state` and rewriting the full state JSON on every PTY
    /// chunk (which thrashed the UI and disk), we stash the latest timestamp
    /// and flush the batch on a short debounce.
    func markOutput(entryId: UUID, runId: UUID) {
        pendingOutputTimestamps[runId] = Date()
        scheduleOutputFlush()
    }

    /// Arm a single coalescing flush if one isn't already pending. The Task
    /// inherits the main actor, so `flushPendingOutput` runs main-isolated.
    private func scheduleOutputFlush() {
        guard outputFlushTask == nil else { return }
        outputFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.outputFlushIntervalNanoseconds ?? 2_000_000_000)
            self?.flushPendingOutput()
        }
    }

    /// Apply all coalesced output timestamps to `state` in one mutation and
    /// persist once. Called on the debounce and eagerly before a run
    /// terminates so the final freshness isn't lost.
    private func flushPendingOutput() {
        outputFlushTask = nil
        guard !pendingOutputTimestamps.isEmpty else { return }
        var didMutate = false
        let flushedRunIds = Array(pendingOutputTimestamps.keys)
        for (runId, date) in pendingOutputTimestamps {
            if let runIndex = state.processRuns.firstIndex(where: { $0.id == runId }) {
                state.processRuns[runIndex].lastOutputAt = date
                didMutate = true
            }
        }
        pendingOutputTimestamps.removeAll()
        if didMutate {
            save()
        }
        // Output for these runs has settled (the flush only fires after the
        // debounce). Re-classify each session's transcript tail to detect a
        // session now sitting at a human prompt — runs off the main actor and
        // never touches the output hot path.
        reclassifyAttentionForFlushedRuns(flushedRunIds)
    }

    /// For each run whose output just settled, read a bounded transcript tail
    /// off the main actor and let `AttentionSignalDetector` decide whether the
    /// session is waiting on the human. Conservatively transitions only
    /// active/idle → waitingOnHuman and waitingOnHuman → active (when the agent
    /// resumed), never disturbing `.needsBossReview` / `.blocked`.
    private func reclassifyAttentionForFlushedRuns(_ runIds: [UUID]) {
        for runId in runIds {
            guard let session = activeSessions.values.first(where: { $0.plan.runId == runId }),
                  let transcriptPath = session.plan.transcriptPath else {
                continue
            }
            let entryId = session.plan.entryId
            // `Task` (not `.detached`) inherits this @MainActor context, so the
            // result is applied main-isolated without sending `self` across an
            // isolation boundary. The blocking read + classify happen in a
            // nonisolated helper that captures only Sendable values.
            Task { [weak self] in
                let classification = await Self.classifyTranscriptTail(path: transcriptPath)
                self?.applyAttentionSignal(classification, entryId: entryId, runId: runId)
            }
        }
        // F4: a run's output has settled, so the agent has had time to write its
        // native session file. This is the moment to back-fill the native session
        // id onto the still-id-less RUNNING run, reviving native-id resume (the
        // planner's `--resume <id>` branch is dead until this writes the id).
        backfillSessionIdsForFlushedRuns(runIds)
    }

    /// F4 — back-fill the native agent session id onto still-id-less RUNNING runs.
    /// `markStarted` builds the run the instant the PTY child reports its shell pid,
    /// BEFORE the agent has written `~/.claude/projects/<dir>/<id>.jsonl` /
    /// `~/.copilot/session-state/<id>/`, so it can't know the id (it STAYS AS-IS).
    /// This sibling of the attention reclassify fires once output has settled —
    /// late enough that the session file exists. It runs the same `ps`-backed scan
    /// the MCP discovery path uses, asks the pure `SessionIdBackfill` seam which
    /// `(runId → sessionId)` writes are safe (never clobbering a non-empty id,
    /// never handing two same-cwd runs the same id), and applies them on the main
    /// actor — each guarded by `== nil` so a concurrent write can't be overwritten.
    private func backfillSessionIdsForFlushedRuns(_ runIds: [UUID]) {
        // Only do the (cheap) scan when at least one flushed run is a live,
        // still-id-less terminal-agent run — otherwise there's nothing to fill.
        let candidateRunIds = Set(runIds)
        let hasCandidate = state.processRuns.contains { run in
            candidateRunIds.contains(run.id)
                && run.status == .running
                && (run.terminalSessionId ?? "").isEmpty
        }
        guard hasCandidate else { return }

        // Snapshot the Sendable state for the off-main scan; the blocking `ps`
        // shell + FS scan run on a detached utility task, then the resulting
        // back-fills are applied main-isolated.
        let snapshot = state
        Task { [weak self] in
            let records = await Self.scanAgentSessions(state: snapshot)
            let backfills = SessionIdBackfill.sessionIdBackfills(
                runs: snapshot.processRuns,
                entries: snapshot.processEntries,
                records: records
            )
            self?.applySessionIdBackfills(backfills)
        }
    }

    /// Apply the seam's `(runId → sessionId)` writes. Each is guarded by
    /// `terminalSessionId == nil` against the CURRENT state (not the snapshot the
    /// scan ran on) so a concurrent recovery/relaunch that already set an id is
    /// never clobbered. Persists once if anything changed.
    private func applySessionIdBackfills(_ backfills: [UUID: String]) {
        guard !backfills.isEmpty else { return }
        var didMutate = false
        for (runId, sessionId) in backfills {
            guard let index = state.processRuns.firstIndex(where: { $0.id == runId }) else { continue }
            if state.processRuns[index].terminalSessionId == nil {
                state.processRuns[index].terminalSessionId = sessionId
                didMutate = true
            }
        }
        if didMutate {
            save()
        }
    }

    /// Run the agent-session scan off the main actor for the back-fill seam, using
    /// the same `ps`-backed `processLister` + `AgentSessionScanner` the MCP
    /// discovery path uses — but via `backfillRecords`, NOT `scan`. The display
    /// `scan` `merge`-collapses same-`harness|cwd` records; the App's `ps` lister
    /// reports no cwd, so EVERY running record lands at `cwd:""` and a merge would
    /// fold ALL same-harness live pids into ONE survivor — handing the seam at most
    /// one pid per harness and silently breaking multi-agent (and even single-run)
    /// recovery. `backfillRecords` returns the UN-MERGED union (all live pids + the
    /// un-collapsed recent native ids) so `SessionIdBackfill` sees every pid it must
    /// pin. nonisolated + capturing only the Sendable state snapshot so it satisfies
    /// strict concurrency.
    nonisolated private static func scanAgentSessions(state: WorkspaceState) async -> [AgentSessionRecord] {
        await Task.detached(priority: .utility) {
            AgentSessionScanner().backfillRecords(
                state: state,
                processLister: Self.psBackedProcessLines
            )
        }.value
    }

    /// The App's `ps`-backed process lister — a thin `Process` shell around
    /// `ps -axww -o pid=,command=` whose stdout feeds the pure, covered
    /// `RunningProcessLine.parsePS`. Mirrors the MCP target's `RunningProcessLister`
    /// (which is internal to that target). `cwd` is left nil on every line — `ps`
    /// can't report a working directory, and the back-fill seam disambiguates
    /// same-cwd runs by pid rather than by the running record's cwd, so an
    /// unresolved cwd here costs nothing. Returns [] on any failure so discovery
    /// degrades to recent-only.
    nonisolated private static func psBackedProcessLines() -> [RunningProcessLine] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,command="]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        // Drain BEFORE waiting so a large process table can't fill the pipe buffer
        // and deadlock `ps` (the standard drain-then-wait idiom).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: 10)
        guard process.terminationStatus == 0 else { return [] }
        return RunningProcessLine.parsePS(String(decoding: data, as: UTF8.self))
    }

    /// Read a bounded transcript tail and classify it off the main actor.
    /// Nonisolated and capturing only a `Sendable` path so it satisfies strict
    /// concurrency; returns the `Sendable` `AttentionClassification` (signal +
    /// the short "why" line U10 surfaces on the header banner and in the boss
    /// snapshot).
    nonisolated private static func classifyTranscriptTail(path: String) async -> AttentionClassification {
        await Task.detached(priority: .utility) {
            guard let tail = TranscriptTailReader(maxBytes: 4096).read(path: path) else {
                return AttentionClassification(signal: .unknown)
            }
            return AttentionSignalDetector.classifyWithReason(tail: tail.text)
        }.value
    }

    /// Apply a detected attention signal, guarding that the run is still the
    /// entry's live session so a stale classification can't reanimate a session
    /// that already moved on. The detected `reason` is persisted onto the entry
    /// (and cleared when the signal clears) so the header banner and the boss
    /// snapshot read the SAME "why" line.
    private func applyAttentionSignal(_ classification: AttentionClassification, entryId: UUID, runId: UUID) {
        guard activeSessions[entryId]?.plan.runId == runId,
              let entry = state.processEntries.first(where: { $0.id == entryId }),
              !entry.isArchived else {
            return
        }
        let reason = classification.reason
        switch classification.signal {
        case .waitingOnHuman:
            guard entry.attention == .active || entry.attention == .idle else { return }
            updateEntry(entryId) {
                $0.attention = .waitingOnHuman
                $0.attentionReason = reason
            }
            save()
            triggerEventDrivenBossCheckIn()
        case .blocked:
            // Stuck on a terminal error. Only escalate from active/idle; don't
            // override a waiting prompt or a boss-set review state.
            guard entry.attention == .active || entry.attention == .idle else { return }
            updateEntry(entryId) {
                $0.attention = .blocked
                $0.attentionReason = reason
            }
            save()
            triggerEventDrivenBossCheckIn()
        case .unknown:
            // The agent produced output that's neither a prompt nor a terminal
            // error: clear a stale detector-set wait/blocked back to active and
            // drop the now-stale reason.
            guard entry.attention == .waitingOnHuman || entry.attention == .blocked else { return }
            updateEntry(entryId) {
                $0.attention = .active
                $0.attentionReason = nil
            }
            save()
        }
    }

    /// Apply (and clear) any pending output timestamp for a single run
    /// without a standalone save — callers that are about to save anyway
    /// (e.g. `markTerminated`) use this so the terminating run's last
    /// output time is preserved in the same write.
    private func applyPendingOutput(forRun runId: UUID) {
        guard let date = pendingOutputTimestamps.removeValue(forKey: runId) else {
            return
        }
        if let runIndex = state.processRuns.firstIndex(where: { $0.id == runId }) {
            state.processRuns[runIndex].lastOutputAt = date
        }
    }

    func markTerminated(entryId: UUID, runId: UUID, rawStatus: Int32?) {
        // Fold any coalesced output timestamp for this run into state before
        // we rewrite its status, so the last-output time isn't lost to the
        // debounce. markTerminated saves below, so no standalone write here.
        applyPendingOutput(forRun: runId)
        guard let runIndex = state.processRuns.firstIndex(where: { $0.id == runId && $0.entryId == entryId }),
              state.processRuns[runIndex].status == .running
        else {
            return
        }
        let status = ProcessExitStatus(rawWaitStatus: rawStatus)
        let currentPlan = activeSessions[entryId]?.plan
        let isCurrentSession = currentPlan?.runId == runId
        let manuallyTerminated = manuallyTerminatedRunIDs.remove(runId) != nil
        // F13 — is this the in-flight finish-setup recovery terminal? Every custom session is
        // wrapped in `screen`, so this one-shot chain can route through EITHER the detached-
        // persistent branch (the screen session is still alive when the local client ends) OR the
        // normal branch (the chain finished and screen exited). Hook both — the re-probe inside
        // `completeVaultOnboarding` is the authoritative `.ready` gate regardless of which branch.
        let isVaultOnboardingSession = entryId == vaultOnboardingEntryID && runId == vaultOnboardingRunID
        let detachedPersistentSession = isCurrentSession
            && !manuallyTerminated
            && currentPlan?.persistentSessionName.map(persistentSessionIsListed) == true
        if detachedPersistentSession {
            activeSessions[entryId] = nil
            if terminalFocusEntryID == entryId {
                terminalFocusEntryID = nil
            }
            updateEntry(entryId) { entry in
                entry.attention = .needsBossReview
                entry.lastSummary = "\(entry.name) detached; recovery can reattach the persistent terminal session"
            }
            state.processRuns[runIndex].status = .needsRecovery
            state.processRuns[runIndex].pid = nil
            state.processRuns[runIndex].endedAt = nil
            state.processRuns[runIndex].exitCode = nil
            state.processRuns[runIndex].rawExitStatus = nil
            save()
            if isVaultOnboardingSession {
                // The chain DID launch and we observed no non-zero failure (the screen session is
                // merely still detached). Pass 0 so the decision falls entirely to the re-probe —
                // which can only return `.ready` on a real `.working`.
                completeVaultOnboarding(vaultExitCode: 0)
            }
            return
        }
        let nextRunStatus = terminationPolicy.statusAfterTermination(
            recoveryAction: isCurrentSession ? currentPlan?.recoveryAction : nil,
            manuallyTerminated: manuallyTerminated
        )
        if isCurrentSession {
            activeSessions[entryId] = nil
            if terminalFocusEntryID == entryId {
                terminalFocusEntryID = nil
            }
            // F12a gap 2 — TOCTOU backstop. The preflight catches a missing `screen`
            // before launch, but it can vanish between preflight and exit; a
            // screen-wrapped session that exits 127 then renders a dead-end "exited
            // with code 127". Replace that with the honest TerminalExitDiagnosis.
            // GATED on the screen wrapper (currentPlan?.persistentSessionName != nil)
            // so a direct-spawn 127 is never misattributed to a missing multiplexer.
            let screenDiagnosis: String? = currentPlan?.persistentSessionName != nil
                ? TerminalExitDiagnosis.screenWrappedExit(
                    exitCode: status.exitCode,
                    screenHealth: executableHealthChecker.health(for: PersistentTerminalSession.executable).status
                )
                : nil
            updateEntry(entryId) { entry in
                entry.attention = nextRunStatus == .manualActionNeeded ? .needsBossReview : .idle
                if let screenDiagnosis {
                    entry.lastSummary = "\(entry.name): \(screenDiagnosis)"
                } else if nextRunStatus == .manualActionNeeded {
                    entry.lastSummary = "\(entry.name) recovery attempt exited with code \(status.exitCode.map(String.init) ?? "unknown")"
                } else {
                    entry.lastSummary = "\(entry.name) exited with code \(status.exitCode.map(String.init) ?? "unknown")"
                }
            }
            // Surface unexpected exits to the user via a macOS notification
            // so they don't have to be watching the Workbench window to know
            // a Codex / Claude session crashed. Skip clean exits (code 0) and
            // anything the user deliberately stopped.
            if !manuallyTerminated {
                let exitedCleanly = status.exitCode == 0
                if !exitedCleanly, shouldPostExitNotification(for: entryId) {
                    let entryName = state.processEntries.first(where: { $0.id == entryId })?.name
                        ?? "Terminal"
                    let needsAttention = nextRunStatus == .manualActionNeeded
                    postUnexpectedExitNotification(
                        entryName: entryName,
                        exitCode: status.exitCode,
                        needsAttention: needsAttention
                    )
                }
            }
        }
        state.processRuns[runIndex].status = nextRunStatus
        state.processRuns[runIndex].endedAt = Date()
        state.processRuns[runIndex].exitCode = status.exitCode
        state.processRuns[runIndex].rawExitStatus = status.rawWaitStatus
        save()
        if isVaultOnboardingSession {
            // The recovery chain finished and its `screen` session exited (the common, happy path).
            // Decode + hand the real exit to the fold; `completeVaultOnboarding` re-probes on a
            // clean exit and gates `.ready` on the verdict.
            completeVaultOnboarding(vaultExitCode: status.exitCode)
        }
    }

    /// Whether enough time has passed since the last unexpected-exit
    /// notification for this entry to post another. Throttles per-entry so a
    /// crash-looping session (or a "Recover All" over several flaky sessions)
    /// can't stack a banner per exit.
    private func shouldPostExitNotification(for entryId: UUID) -> Bool {
        let now = Date()
        if let last = lastExitNotificationByEntry[entryId],
           now.timeIntervalSince(last) < exitNotificationThrottle {
            return false
        }
        lastExitNotificationByEntry[entryId] = now
        return true
    }

    /// Post a macOS user notification when a terminal session ends with a
    /// non-zero exit (or no exit code, e.g. SIGKILL). First call lazily
    /// requests authorization; thereafter the system handles permission
    /// state. We never block on the auth request — if it's denied the post
    /// silently fails, which is the correct macOS behavior.
    private func postUnexpectedExitNotification(
        entryName: String,
        exitCode: Int32?,
        needsAttention: Bool
    ) {
        // Capture only primitives in the closure so UNNotificationRequest
        // (non-Sendable) is constructed inside the authorization callback's
        // execution context, not transferred across it. Mirrors the macOS
        // recommendation for sandbox / strict-concurrency builds.
        let title = needsAttention ? "\(entryName) needs attention" : "\(entryName) exited"
        let body: String
        if let code = exitCode {
            body = "Process exited with code \(code)."
        } else {
            body = "Process ended without an exit code (likely a signal)."
        }
        let subtitle = needsAttention
            ? "Recovery couldn't auto-resume — open the Recovery sheet."
            : ""
        let identifier = "ouro.workbench.exit.\(UUID().uuidString)"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if !subtitle.isEmpty {
                content.subtitle = subtitle
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Whether a detached `screen` session with this name is currently
    /// listed. Used on the session-exit path to decide detach-vs-crash.
    ///
    /// `screen -ls` normally returns in milliseconds, but a stuck socket
    /// (e.g. NFS home dir) could hang `waitUntilExit()` forever — and this
    /// runs on the main actor from `markTerminated`. We bound the wait with
    /// a watchdog: if `screen` doesn't finish within the deadline we kill it
    /// and treat the session as not-listed rather than freezing the app.
    private func persistentSessionIsListed(_ sessionName: String) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: PersistentTerminalSession.executable)
        process.arguments = PersistentTerminalSession.listArguments()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        // `screen -ls` output is a handful of lines, well under the pipe
        // buffer, so reading after exit can't deadlock.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + .milliseconds(1500)) == .timedOut {
            // FIX2 — SIGTERM, then escalate to SIGKILL so a SIGTERM-ignoring
            // `screen -ls` (wedged socket) can't survive past the watchdog.
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return PersistentTerminalSession.listOutput(output, contains: sessionName)
    }

    private static let collapsedChromeMigrationKey = "ouro.workbench.collapsedChromeMigration.v17"
    private static let automaticBossMigrationKey = "ouro.workbench.automaticBossDefaults.v1"
    static let terminalFontSizeDefaultsKey = "ouro.workbench.terminalFontSize"
    static let recentWorkspacePathsDefaultsKey = "ouro.workbench.recentWorkspacePaths"
    static let terminalThemeOverrideDefaultsKey = "ouro.workbench.terminalThemeOverride"
    static let showMenuBarStatusItemDefaultsKey = "ouro.workbench.showMenuBarStatusItem"
    static let bossAutoAdvanceEnabledDefaultsKey = "ouro.workbench.bossAutoAdvanceEnabled"
    static let autoLaunchResumableOnStartupDefaultsKey = "ouro.workbench.autoLaunchResumableOnStartup"
    static let autoUpdateEnabledDefaultsKey = "ouro.workbench.autoUpdateEnabled"
    static let lastUpdateCheckAtDefaultsKey = "ouro.workbench.lastUpdateCheckAt"
    static let onboardingCompletedDefaultsKey = "ouro.workbench.onboardingCompleted"
    static let maxRecentWorkspaces = 8
    /// Default terminal font size. Matches macOS Terminal's default.
    static let defaultTerminalFontSize: CGFloat = 13
    /// Allowed terminal font-size range. Below 9pt cells become unreadable;
    /// above 28pt the layout starts crowding the chrome.
    static let terminalFontSizeBounds: ClosedRange<CGFloat> = 9...28

    private func load() {
        // F11a — assume failure until a path proves otherwise. The startup
        // orphan-screen reaper gates on this; never let a partially-applied or
        // thrown load leave a stale `true` that would let the reaper run with an
        // untrustworthy (possibly empty) entry set.
        stateLoadSucceeded = false
        if isFirstRunSetupForcedOnLaunch {
            state = bootstrapper.bootstrappedState(
                from: WorkspaceState(),
                defaults: .firstRunSetup()
            )
            bossWatchIsEnabled = state.bossWatchEnabled
            bossWatchBaselineState = nil
            selectedProjectID = state.projects.first?.id
            selectedEntryID = nil
            detailSplit = nil
            activePaneID = .primary
            do {
                try store.save(state)
            } catch {
                errorMessage = String(describing: error)
            }
            // A forced first-run setup IS a successful load: state.processEntries
            // is the trustworthy first-run default set, so the reaper's
            // knownEntryIds derivation is safe.
            stateLoadSucceeded = true
            return
        }
        do {
            let loaded = try store.load()
            // Suppress the implicit save()s that the selection/layout
            // assignments below trigger via their `didSet` observers. Without
            // this, on a lossy load those saves would atomically overwrite
            // `stateURL` with the survivors-only state BEFORE writeSalvageCopy()
            // copies the original pre-drop bytes — permanently losing the
            // dropped rows. Cleared via `defer` so saves resume the moment
            // load() returns; the trailing `store.save(state)` below calls the
            // store DIRECTLY (not via save()), so it bypasses this guard and the
            // final survivors-only state is still persisted — after the salvage.
            isLoadingState = true
            defer { isLoadingState = false }
            state = startupRecoveryReconciler.reconcile(bootstrapper.bootstrappedState(from: loaded))
            applyCollapsedChromeMigrationIfNeeded()
            applyAutomaticBossDefaultsMigrationIfNeeded()
            // Slice ②a: non-destructively map the flat processEntries into the durable
            // workspace structure (single "Restored workspace" for a pre-②a file).
            // Idempotent (DA3) — converges on every load, so NO run-once gate (unlike
            // the boss-defaults trust flip above). Mutates only `state.workspaces`.
            state.migrateToWorkspaceStructure()
            bossWatchIsEnabled = state.bossWatchEnabled
            bossWatchBaselineState = bossWatchIsEnabled ? state : nil
            selectedProjectID = state.selectedProjectId.flatMap { id in
                state.projects.contains(where: { $0.id == id }) ? id : nil
            } ?? state.projects.first?.id
            selectedEntryID = state.selectedEntryId.flatMap { id in
                projectSessionEntries.contains(where: { $0.id == id }) ? id : nil
            } ?? sessionEntries.first?.id ?? archivedSessionEntries.first?.id
            // W5 increment 2: rebuild the detail split from the persisted
            // layout, degrading gracefully (see `restoreDetailLayout`). Done
            // after `selectedEntryID` is finalized so the one-session-per-pane
            // check resolves against the actual restored primary selection.
            restoreDetailLayout()
            // F5: lenient decode silently drops rows it can't decode (so one
            // corrupt row doesn't sink the whole workspace), and the re-save
            // below would then atomically overwrite the original WITHOUT those
            // rows — permanently. Read the loaded state's decodeReport (the RAW
            // `loaded`, before bootstrap/reconcile transforms) and, on a lossy
            // load, salvage the ORIGINAL pre-drop bytes FIRST.
            //
            // ORDERING IS LOAD-BEARING: writeSalvageCopy() copies the live file
            // (still the pre-drop original at this point), so it must run BEFORE
            // the trailing store.save(state) that rewrites the file with the
            // survivors-only state. The `isLoadingState` guard set at the top of
            // this `do` block neutralizes the OTHER way the original could be
            // clobbered first: the selection/layout assignments above (and
            // recordActionLog below) each call save() via their observers, and
            // without the guard one of those implicit saves would overwrite the
            // original BEFORE this salvage ever ran. With the guard, the only
            // write to stateURL during load is the deliberate trailing
            // store.save(state) — which runs after the salvage.
            if case let .salvageBeforeResave(reason) = postLoadDecision(for: loaded.decodeReport) {
                let salvageURL = try? store.writeSalvageCopy()
                if let salvageURL {
                    errorMessage = """
                    Some saved items couldn't be read (\(reason)) and were left out of your \
                    workspace. The original was copied to:
                    \(salvageURL.path)

                    Loaded everything else. Recover the skipped items from that copy if you need them.
                    """
                    recordActionLog(
                        source: "store",
                        action: "loadSalvage",
                        result: "Skipped \(loaded.decodeReport.skippedRowCount) rows; original copied to \(salvageURL.path)",
                        succeeded: false
                    )
                } else {
                    // Salvage copy failed — do NOT misreport a recovery file we
                    // couldn't write. Still surface the loss honestly.
                    errorMessage = """
                    Some saved items couldn't be read (\(reason)) and were left out of your workspace. \
                    A backup copy of the original couldn't be written.
                    """
                    recordActionLog(
                        source: "store",
                        action: "loadSalvage",
                        result: "Skipped \(loaded.decodeReport.skippedRowCount) rows; salvage copy failed",
                        succeeded: false
                    )
                }
            }
            try store.save(state)
            // The load read a real workspace (a lossy-but-salvaged load still
            // counts: the survivors in state.processEntries are real entries the
            // reaper must spare). Mark success so the startup reaper can run.
            stateLoadSucceeded = true
        } catch {
            // The store tries to quarantine an unreadable file before we get
            // here. Whether that move SUCCEEDED is now a checked value, so we
            // can only reset-to-empty + save when the original was actually
            // moved aside — otherwise the original is still live at stateURL and
            // resetting + saving would clobber it.
            if case let WorkbenchStoreError.unreadableState(preserved, reason) = error {
                switch preserved {
                case let .moved(quarantineURL):
                    errorMessage = """
                    Your workspace couldn't be read (\(reason)) and was set aside at:
                    \(quarantineURL.path)

                    Starting with a fresh workspace. Your previous data is preserved in that file if you need to recover it.
                    """
                case .moveFailed(_, _):
                    // The move FAILED: the original is STILL at stateURL. Do NOT
                    // reset to empty and do NOT save — an atomic overwrite would
                    // destroy the only surviving copy. Tell the operator exactly
                    // where their data still is, and bail before any save.
                    errorMessage = """
                    Your workspace couldn't be read (\(reason)) and could NOT be set aside. \
                    Your original data was NOT moved — it remains at:
                    \(store.stateURL.path)

                    The workbench won't overwrite it. Move or fix that file, then relaunch.
                    """
                    return
                }
            } else {
                errorMessage = "Couldn't load workspace: \(error.localizedDescription)"
            }
            state = bootstrapper.bootstrappedState(from: WorkspaceState())
            bossWatchIsEnabled = state.bossWatchEnabled
            bossWatchBaselineState = nil
            selectedProjectID = state.projects.first?.id
            selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
            // No persisted layout survives a failed/quarantined load; stay
            // single-pane (the published defaults already are).
        }
    }

    /// Rebuild the in-memory detail split from `state.detailLayout` on launch,
    /// degrading gracefully so a stale layout never crashes or mounts a
    /// dangling/duplicate pane. Layout restore is orthogonal to pty lifetime:
    /// it only re-establishes which pane shows which *entry id*; the recovery
    /// reconciler independently reattaches live `screen` sessions by id, and a
    /// restored pane whose session isn't running renders the existing inactive
    /// surface exactly as single-pane does.
    ///
    /// The pure `PaneLayoutState.resolved(...)` decides validity: a secondary
    /// that no longer exists, is archived, or collides with the restored
    /// primary selection is dropped to an empty picker (and focus falls back to
    /// the primary). The split itself is preserved when present — the operator
    /// chose it — so they relaunch into their two-up layout and re-pick the
    /// secondary if its agent is gone.
    private func restoreDetailLayout() {
        guard let layout = state.detailLayout else {
            // No persisted split → classic single pane (the defaults).
            detailSplit = nil
            activePaneID = .primary
            return
        }
        // Sessions eligible to mount in a pane: terminal/shell entries that
        // exist and aren't archived, across all groups (the secondary pane can
        // show a cross-group session, mirroring `secondaryPaneEntry`).
        let liveEntryIDs = Set(allSessionEntries.filter { !$0.isArchived }.map(\.id))
        let resolved = layout.resolved(
            selectedEntryId: selectedEntryID,
            liveEntryIDs: liveEntryIDs
        )
        detailSplit = DetailSplitState(
            axis: DetailSplitAxis(resolved.axis),
            secondaryEntryID: resolved.secondaryEntryID
        )
        activePaneID = DetailPaneID(resolved.activePane)
    }

    /// One-time migration: the Workbench 0.1.17 redesign defaults the boss
    /// dashboard to collapsed. Existing users had it expanded; flip them to
    /// collapsed on first launch of this version. They can still re-open it
    /// from the header chevron at any time.
    private func applyCollapsedChromeMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.collapsedChromeMigrationKey) else {
            return
        }
        state.bossPaneCollapsed = true
        defaults.set(true, forKey: Self.collapsedChromeMigrationKey)
    }

    /// One-time migration to the automate-first posture (opt-out): trust the
    /// existing sessions the boss should manage and turn on Boss Watch, so the
    /// inbox just works without per-session setup. Runs once; the operator can
    /// mark any session hands-off (untrusted) or turn Boss Watch back off
    /// afterward and that sticks.
    private func applyAutomaticBossDefaultsMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.automaticBossMigrationKey) else {
            return
        }
        state.applyAutomaticBossDefaults()
        defaults.set(true, forKey: Self.automaticBossMigrationKey)
    }

    private func updateEntry(_ entryId: UUID, mutate: (inout ProcessEntry) -> Void) {
        guard let index = state.processEntries.firstIndex(where: { $0.id == entryId }) else {
            return
        }
        mutate(&state.processEntries[index])
    }

    private func replaceEntry(_ entry: ProcessEntry) {
        guard let index = state.processEntries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        state.processEntries[index] = entry
    }

    private func recordBossWatchChanges(_ changes: [WorkspaceChangeSummary]) {
        guard !changes.isEmpty else {
            return
        }
        var seen = Set<UUID>()
        bossWatchChangeSummaries = Array((changes + bossWatchChangeSummaries).filter { change in
            seen.insert(change.id).inserted
        }.prefix(25))
    }

    private func uniqueCopyName(for name: String) -> String {
        let baseName = "Copy of \(name)"
        let existingNames = Set(state.processEntries.map(\.name))
        guard existingNames.contains(baseName) else {
            return baseName
        }
        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    /// Persist the current state to disk. Returns `true` when the durable write
    /// succeeded, `false` when it threw (and `errorMessage` was set).
    ///
    /// The Bool exists so callers that must report success HONESTLY (the
    /// workspace-import and onboarding-apply paths) can gate their green
    /// "Imported N terminals" banner + `succeeded:true` action log on the write
    /// actually landing — a swallowed write failure used to surface as a false
    /// green over an in-memory-only import that's lost on quit.
    ///
    /// `@discardableResult` keeps the ~30 fire-and-forget callers (the `didSet`
    /// observers and the implicit selection/layout saves) compiling unchanged —
    /// they don't care whether the write landed.
    ///
    /// The two suppression guards return `true`: they don't represent a write
    /// FAILURE. The state is in-memory consistent and the durable write is
    /// deferred to a direct trailing `store.save(state)` (reset/load own their
    /// persistence). The import paths never trip these guards, so a `false` from
    /// `save()` always means a real `store.save` throw.
    @discardableResult
    private func save() -> Bool {
        // While resetting to first run we've deliberately removed the state
        // file; any save here (including the one in prepareForTermination at
        // quit) would re-create it with the old in-memory state and undo the
        // wipe. Suppress saves for the brief reset-then-relaunch window.
        guard !isResettingToFirstRun else {
            return true
        }
        // While load() is restoring state, the selection/layout assignments it
        // makes each fire a `didSet` → save(). On a LOSSY load that premature,
        // implicit save would atomically overwrite `stateURL` with the
        // survivors-only state BEFORE writeSalvageCopy() copies the original —
        // so the salvage would capture post-drop bytes and the dropped rows
        // would be lost. Suppress those implicit saves; load()'s own trailing
        // `store.save(state)` persists the final state directly (bypassing this
        // guard), AFTER the salvage. See `isLoadingState`.
        guard !isLoadingState else {
            return true
        }
        // FIX3 — inside a single check-in's `withBatchedSave` scope, suppress the
        // per-step saves (recordActionLog's trailing save, recordBossDecisions's
        // save) so the apply + record rows land in ONE trailing store.save(). The
        // batch's flush clears this depth BEFORE its own save(), so that final
        // write goes through here normally (and still honors the guards above).
        guard bossCheckInSaveBatchDepth == 0 else {
            return true
        }
        do {
            try store.save(state)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// FIX3 — run `body` (a single check-in's apply-actions + record-decisions) with
    /// the per-step `save()` calls suppressed, then perform exactly ONE trailing
    /// `save()` so the action-log rows and their decision/inbox rows persist
    /// atomically. The depth counter is restored before the flush (so the flush's
    /// own `save()` isn't suppressed), and on any throw the depth is still restored
    /// (the catch decrements before rethrowing) — so a throwing body can't leave the
    /// batch wedged-suppressed. The trailing `save()` honors the existing reset/load
    /// suppression guards exactly as a normal save would.
    @discardableResult
    private func withBatchedSave<T>(_ body: () throws -> T) rethrows -> T {
        bossCheckInSaveBatchDepth += 1
        let result: T
        do {
            result = try body()
        } catch {
            bossCheckInSaveBatchDepth -= 1
            throw error
        }
        bossCheckInSaveBatchDepth -= 1
        save()
        return result
    }

    private func fetchResult<T: Decodable & Sendable>(
        _ endpoint: MailboxEndpoint,
        as type: T.Type,
        label: String
    ) async -> MailboxFetchResult<T> {
        do {
            let value = try await mailboxClient.fetch(endpoint, as: type)
            return MailboxFetchResult(value: value, issue: nil)
        } catch {
            return MailboxFetchResult(value: nil, issue: "\(label): \(error.localizedDescription)")
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MailboxFetchResult<Value: Sendable>: Sendable {
    var value: Value?
    var issue: String?
}

/// Single source of truth for the Workbench terminal palette. Each `Theme`
/// owns the four "chrome" colors (background / foreground / selection / caret)
/// AND a 16-entry ANSI palette so colored TUI output (Claude Code, Codex,
/// `ls --color`) renders correctly. Without an installed palette SwiftTerm
/// falls back to a black-and-white interpretation of SGR codes and reverse-
/// video lands as a pure-white block ("white-highlighted text") which is the
/// artifact Ari reported.
/// User's chosen terminal theme. `.system` follows macOS appearance so the
/// terminal palette flips with light/dark mode; `.light` and `.dark` pin
/// the palette regardless of system. Stored as a raw string in UserDefaults.
public enum TerminalThemeOverride: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
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

enum WorkbenchTerminalPalette {
    /// A complete terminal theme. Builds dynamic NSColors so the SwiftUI
    /// host inset / focus mode pick up the right shade automatically when
    /// system appearance changes; the SwiftTerm palette is re-installed
    /// per-view via `applyWorkbenchTheme`.
    struct Theme {
        var name: String
        var background: NSColor
        var foreground: NSColor
        var caret: NSColor
        var caretText: NSColor
        var selection: NSColor
        /// 16-entry ANSI palette in xterm order: 0-7 normal, 8-15 bright.
        /// Index 7 is the "default-bright" / reverse-video paint color — keep
        /// it a muted gray, not pure white, so reverse video doesn't blast.
        var ansiPalette: [SwiftTerm.Color]
    }

    /// User's theme override read from the view model on every theme lookup.
    /// `.system` falls through to the appearance-driven choice; `.light` /
    /// `.dark` pin the palette. Stored statically so even SwiftTerm subviews
    /// that don't see the view model can pick it up. The Settings sheet
    /// updates this through `WorkbenchViewModel.setTerminalThemeOverride`.
    ///
    /// `nonisolated(unsafe)` because dynamic NSColor providers may run off
    /// the main actor (AppKit's appearance resolver), but in practice all
    /// writers (view model setters, init) and the AppKit draw path are
    /// main-actor-only. A stray non-main read still gets a valid enum value
    /// and only races on which palette is in effect for a single frame.
    nonisolated(unsafe) static var currentOverride: TerminalThemeOverride = .system

    /// Pick the right theme for the current effective appearance. Defaults to
    /// dark when the appearance is `nil` (no window yet). A non-`.system`
    /// `currentOverride` short-circuits the appearance lookup.
    static func theme(for appearance: NSAppearance?) -> Theme {
        switch currentOverride {
        case .light: return lightTheme
        case .dark: return darkTheme
        case .system:
            let isLight = appearance?
                .bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) == .aqua
                || appearance?
                .bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) == .vibrantLight
            return isLight ? lightTheme : darkTheme
        }
    }

    /// SwiftUI background color that auto-resolves to the dark or light theme
    /// based on the current colorScheme. Used by the focus-mode wash and the
    /// host inset so they never flash a hardcoded near-black behind a light
    /// terminal.
    static var swiftUIBackground: SwiftUI.Color {
        SwiftUI.Color(nsColor: dynamicBackground)
    }

    static let dynamicBackground = NSColor(name: "WorkbenchTerminalBackground") { appearance in
        theme(for: appearance).background
    }

    // Convenience accessors used by header chrome before a terminal has been
    // attached. These resolve via NSApp.effectiveAppearance at use time.
    static var background: NSColor { dynamicBackground }

    // MARK: - Themes

    private static var darkTheme: Theme { _darkTheme() }
    private static var lightTheme: Theme { _lightTheme() }

    private static func _darkTheme() -> Theme { Theme(
        name: "Workbench Dark",
        background: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1.0),
        foreground: NSColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1.0),
        caret: NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.85),
        caretText: .white,
        selection: NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.32),
        ansiPalette: ansi([
            // Normal 0-7
            (0x1c, 0x1c, 0x20), // 0  black
            (0xff, 0x6b, 0x6b), // 1  red
            (0x98, 0xc3, 0x79), // 2  green
            (0xe5, 0xc0, 0x7b), // 3  yellow
            (0x61, 0xaf, 0xef), // 4  blue
            (0xc6, 0x78, 0xdd), // 5  magenta
            (0x56, 0xb6, 0xc2), // 6  cyan
            (0xc8, 0xcc, 0xd0), // 7  white  (muted — reverse-video paint)
            // Bright 8-15
            (0x5c, 0x63, 0x70), // 8  bright black
            (0xff, 0x8d, 0x8d), // 9  bright red
            (0xb0, 0xd4, 0x9f), // 10 bright green
            (0xf0, 0xd1, 0x91), // 11 bright yellow
            (0x84, 0xc1, 0xf5), // 12 bright blue
            (0xd3, 0x9b, 0xef), // 13 bright magenta
            (0x8c, 0xc4, 0xcd), // 14 bright cyan
            (0xeb, 0xeb, 0xed)  // 15 bright white
        ])
    ) }

    private static func _lightTheme() -> Theme { Theme(
        name: "Workbench Light",
        background: NSColor(srgbRed: 0.985, green: 0.985, blue: 0.995, alpha: 1.0),
        foreground: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0),
        caret: NSColor(srgbRed: 0.20, green: 0.40, blue: 0.85, alpha: 0.85),
        caretText: .white,
        selection: NSColor(srgbRed: 0.25, green: 0.50, blue: 0.95, alpha: 0.22),
        ansiPalette: ansi([
            // Normal 0-7 (tuned for white background)
            (0x1d, 0x1d, 0x1f), // 0  black
            (0xc9, 0x1b, 0x1b), // 1  red
            (0x00, 0x80, 0x5a), // 2  green
            (0x9b, 0x7b, 0x00), // 3  yellow
            (0x24, 0x5b, 0xc4), // 4  blue
            (0xa3, 0x47, 0xba), // 5  magenta
            (0x1a, 0x8a, 0x9d), // 6  cyan
            (0xc8, 0xc8, 0xca), // 7  white  (muted — reverse-video paint)
            // Bright 8-15
            (0x5c, 0x5c, 0x60), // 8  bright black
            (0xd8, 0x39, 0x39), // 9  bright red
            (0x1d, 0xa8, 0x78), // 10 bright green
            (0xb3, 0x8e, 0x00), // 11 bright yellow
            (0x35, 0x71, 0xd6), // 12 bright blue
            (0xb8, 0x5e, 0xc8), // 13 bright magenta
            (0x20, 0xa0, 0xb6), // 14 bright cyan
            (0xe0, 0xe0, 0xe2)  // 15 bright white
        ])
    ) }

    /// Convert an array of 8-bit RGB tuples to SwiftTerm 16-bit Color values.
    /// SwiftTerm's `Color` uses UInt16 channels (0..65535); 8-bit → 16-bit is
    /// a multiply-by-0x0101 (a.k.a. 257), which expands `0xab` to `0xabab`
    /// instead of `0xab00`.
    private static func ansi(_ tuples: [(UInt8, UInt8, UInt8)]) -> [SwiftTerm.Color] {
        tuples.map { rgb in
            SwiftTerm.Color(
                red: UInt16(rgb.0) * 0x0101,
                green: UInt16(rgb.1) * 0x0101,
                blue: UInt16(rgb.2) * 0x0101
            )
        }
    }
}

struct TerminalPane: NSViewRepresentable {
    var session: TerminalSessionController

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(session.terminal)
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.attach(session.terminal)
    }
}

final class TerminalHostView: NSView {
    private weak var terminal: CapturingLocalProcessTerminalView?
    private var lastLaidOutSize: NSSize = .zero
    private var pendingRedrawWorkItems: [DispatchWorkItem] = []
    private static let contentInset = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 2)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureBacking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureBacking()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        terminal?.claimKeyboardFocus()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        terminal?.claimKeyboardFocus()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let terminal else {
            super.keyDown(with: event)
            return
        }
        terminal.keyDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        if let terminal,
           hitView === terminal || hitView?.isDescendant(of: terminal) == true {
            terminal.claimKeyboardFocus()
        }
        return hitView
    }

    func attach(_ terminal: CapturingLocalProcessTerminalView) {
        guard self.terminal !== terminal else {
            focusTerminal()
            return
        }
        self.terminal?.removeFromSuperview()
        self.terminal = terminal
        cancelPendingRedraws()
        lastLaidOutSize = .zero
        terminal.removeFromSuperview()
        terminal.frame = terminalContentFrame
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        // The attached SwiftTerm view may have been themed for a previous
        // system appearance (e.g. session was created while dark, user
        // switched to light, then switched back to this terminal). Re-apply
        // the current theme so it always matches the live appearance.
        terminal.applyWorkbenchTheme(
            WorkbenchTerminalPalette.theme(for: effectiveAppearance)
        )
        needsLayout = true
        focusTerminal()
        scheduleTerminalRedraws(after: [0.08, 0.22, 0.55, 1.0])
    }

    override func layout() {
        super.layout()
        guard let terminal else {
            return
        }
        terminal.frame = terminalContentFrame
        let size = bounds.size
        guard size.width > 20, size.height > 20 else {
            return
        }
        if abs(size.width - lastLaidOutSize.width) > 1 || abs(size.height - lastLaidOutSize.height) > 1 {
            lastLaidOutSize = size
            scheduleTerminalRedraws(after: [0.05, 0.18, 0.55, 1.0])
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTerminal()
    }

    private var terminalContentFrame: NSRect {
        let inset = Self.contentInset
        return NSRect(
            x: bounds.minX + inset.left,
            y: bounds.minY + inset.bottom,
            width: max(0, bounds.width - inset.left - inset.right),
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
    }

    private func configureBacking() {
        wantsLayer = true
        applyThemeBacking()
    }

    /// Repaint our inset background to the current theme so the user never
    /// sees a stale black or white sliver around the terminal pane when the
    /// system flips light/dark.
    private func applyThemeBacking() {
        let theme = WorkbenchTerminalPalette.theme(for: effectiveAppearance)
        layer?.backgroundColor = theme.background.cgColor
    }

    /// AppKit calls this when the user toggles system light/dark, or when the
    /// host window moves to a display with a different appearance. Re-apply
    /// our theme to the attached terminal and to our own backing layer.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeBacking()
        let theme = WorkbenchTerminalPalette.theme(for: effectiveAppearance)
        terminal?.applyWorkbenchTheme(theme)
        // Trigger a redraw burst so ANSI cells get repainted with the new
        // foreground / palette values; without this the visible buffer keeps
        // the old colors until the underlying TUI emits new output.
        scheduleTerminalRedraws(after: [0.05, 0.2, 0.5])
    }

    private func focusTerminal() {
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else {
                return
            }
            terminal.claimKeyboardFocus()
        }
    }

    private func cancelPendingRedraws() {
        pendingRedrawWorkItems.forEach { $0.cancel() }
        pendingRedrawWorkItems.removeAll()
    }

    private func scheduleTerminalRedraws(after delays: [TimeInterval]) {
        cancelPendingRedraws()
        pendingRedrawWorkItems = delays.map { delay in
            let workItem = DispatchWorkItem { [weak self, weak terminal] in
                guard let self,
                      let terminal,
                      terminal.superview === self else {
                    return
                }
                // Only nudge a redraw with Ctrl-L (form-feed) when the session
                // is in the alternate-screen buffer — i.e. a full-screen TUI
                // (Claude Code, Codex, vim) where Ctrl-L means "repaint" and
                // is harmless. In the normal buffer (a plain shell sitting at
                // a prompt) Ctrl-L *clears the visible scrollback*, so we must
                // not inject it just because the user resized or re-selected
                // the terminal. SwiftTerm repaints the normal buffer on its
                // own via reflow / SIGWINCH.
                if terminal.getTerminal().isCurrentBufferAlternate {
                    terminal.send([0x0c])
                }
                terminal.claimKeyboardFocus()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }
}

/// F11a Defect 2 — a single-shot wrapper around a `CheckedContinuation` so two
/// racing resume sites (the quit process's `terminationHandler` and the 1.5s
/// watchdog) resume it EXACTLY once. A checked continuation resumed twice traps;
/// resumed zero times hangs. The `NSLock` makes the check-and-set atomic across
/// the two background closures; whichever fires first wins, the loser no-ops.
private final class SingleShotContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

@MainActor
final class TerminalSessionController: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let plan: TerminalCommandPlan
    let terminal: CapturingLocalProcessTerminalView
    private static let initialTerminalFrame = CGRect(x: 0, y: 0, width: 960, height: 520)
    private let environmentValues: [String: String]
    private let environment: [String]
    private let onStarted: (Int32?) -> Void
    private let onOutput: () -> Void
    private let onTerminated: (Int32?) -> Void
    private var recorder: TranscriptRecorder?
    private var hasStarted = false
    /// F12a gap 5 — one-shot guard so a `.sendAfterLaunch` checkpoint prompt is typed
    /// EXACTLY once, on the first output (the interactive signal), not on every PTY
    /// chunk.
    private var hasDeliveredCheckpointPrompt = false

    init(
        plan: TerminalCommandPlan,
        workbenchContext: WorkbenchSessionContext? = nil,
        onStarted: @escaping (Int32?) -> Void,
        onOutput: @escaping () -> Void,
        onTerminated: @escaping (Int32?) -> Void
    ) throws {
        self.plan = plan
        self.onStarted = onStarted
        self.onOutput = onOutput
        self.onTerminated = onTerminated
        self.terminal = CapturingLocalProcessTerminalView(frame: Self.initialTerminalFrame)
        self.environmentValues = TerminalEnvironment(workbenchContext: workbenchContext).valuesWithResolvedPath()
        self.environment = environmentValues
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        if let transcriptPath = plan.transcriptPath {
            self.recorder = try TranscriptRecorder(url: URL(fileURLWithPath: transcriptPath))
        }
        super.init()
        terminal.processDelegate = self
        terminal.onOutput = recordOutput
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.configureNativeFeel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        let invocation = plan.launchInvocation
        terminal.startProcess(
            executable: invocation.executable,
            args: invocation.arguments,
            environment: environment,
            execName: invocation.execName,
            currentDirectory: plan.workingDirectory
        )
        onStarted(terminal.process?.shellPid)
    }

    func sendInput(_ text: String) {
        terminal.send(txt: text)
    }

    func sendBytes(_ bytes: [UInt8]) {
        terminal.send(bytes)
    }

    func redrawDisplay() {
        sendBytes([0x0c])
    }

    func redrawDisplayBurst(after delays: [TimeInterval]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.redrawDisplay()
                self?.focusInput()
            }
        }
    }

    func focusInput() {
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else {
                return
            }
            terminal.claimKeyboardFocus()
        }
    }

    func terminate() {
        terminatePersistentSessionIfNeeded()
        terminal.terminate()
    }

    /// Tear down only the local PTY client, leaving the persistent `screen` quit
    /// to the caller. Used by the F11a Defect 2 await path in
    /// `WorkbenchViewModel.start(_:with:)`: there the screen quit is awaited
    /// FIRST (`terminatePersistentSessionAwaiting`) so the socket is free before
    /// the relaunch, then this finishes off the old local client.
    func terminateLocalClient() {
        terminal.terminate()
    }

    private func terminatePersistentSessionIfNeeded() {
        guard let sessionName = plan.persistentSessionName else {
            return
        }
        // Run `screen -X quit` off the main thread so stopping a session never
        // blocks the UI on an external process (a hung `screen` socket would
        // otherwise beachball the whole app). Fire-and-forget via the shared
        // `spawnScreenQuit` (off-main + 1.5s watchdog so a wedged socket can't
        // park a worker thread for the app's life): the caller also terminates
        // the local client right after, and the run is recorded as manually
        // ended regardless of whether the quit raced ahead. App-exit and the
        // standalone Stop path use THIS non-awaiting quit deliberately — they
        // must NOT block the main actor (the awaiting variant is only for the
        // start-race fix, where one quit must finish before the relaunch).
        WorkbenchViewModel.spawnScreenQuit(
            arguments: PersistentTerminalSession.terminateArguments(sessionName: sessionName),
            environment: environmentValues
        )
    }

    /// F11a Defect 2 — quit the persistent `screen` and AWAIT it to completion.
    /// Unlike the fire-and-forget `terminatePersistentSessionIfNeeded`, the
    /// caller (`start(_:with:)`'s `.quitThenAwait` arm) must know the socket is
    /// free before launching `screen -D -RR` on it, so the relaunch never races
    /// the quit.
    ///
    /// The continuation is resumed from EITHER the process `terminationHandler`
    /// (the quit finished) OR a 1.5s watchdog (a wedged `screen` socket — e.g. an
    /// NFS home dir — that never terminates; we must not hang the launch
    /// forever). Both paths funnel through a SINGLE-SHOT guard
    /// (`SingleShotContinuation`): a checked continuation resumed twice traps,
    /// and resumed zero times hangs — so exactly-once is mandatory. No live
    /// `screen` (no `persistentSessionName`) resumes immediately.
    func terminatePersistentSessionAwaiting() async {
        guard let sessionName = plan.persistentSessionName else {
            return
        }
        let executable = PersistentTerminalSession.executable
        let arguments = PersistentTerminalSession.terminateArguments(sessionName: sessionName)
        let environment = environmentValues
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = SingleShotContinuation(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                // Resume the moment the quit process exits.
                process.terminationHandler = { _ in
                    gate.resume()
                }
                do {
                    try process.run()
                } catch {
                    // The screen / socket is already gone — nothing to await.
                    gate.resume()
                    return
                }
                // Watchdog: a wedged socket can leave the process never
                // terminating (so terminationHandler never fires). Resume after
                // 1.5s and kill the stuck process so the launch can proceed.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(1500)) {
                    if process.isRunning {
                        process.terminate()
                    }
                    gate.resume()
                }
            }
        }
    }

    private func recordOutput(_ bytes: ArraySlice<UInt8>) {
        recorder?.append(bytes)
        // F12a gap 5 — the first output is the post-start INTERACTIVE signal: the
        // TUI has painted and is ready for input. Deliver a `.sendAfterLaunch`
        // checkpoint prompt here (NOT in start()/onStarted — typing before the TUI is
        // ready loses the prompt). The one-shot guard fires it exactly once.
        deliverCheckpointPromptIfNeeded()
        onOutput()
    }

    /// F12a gap 5 — type a Copilot respawn's checkpoint recovery prompt once the TUI
    /// is interactive. Copilot ignores an argv prompt after `--`, so the planner
    /// carries the prompt in `plan.checkpointPromptDelivery == .sendAfterLaunch`
    /// rather than appending it; here we type it (with a trailing newline to submit)
    /// on the first output. Gated on the one-shot `hasDeliveredCheckpointPrompt` so a
    /// later output chunk never re-types it. `.positional` plans deliver nothing here
    /// (the prompt is already in argv — the generic-TUI path is untouched).
    private func deliverCheckpointPromptIfNeeded() {
        guard !hasDeliveredCheckpointPrompt else {
            return
        }
        guard case let .sendAfterLaunch(text) = plan.checkpointPromptDelivery else {
            return
        }
        hasDeliveredCheckpointPrompt = true
        sendInput("\(text)\n")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        recorder?.close()
        onTerminated(exitCode)
    }

    /// SwiftTerm calls this when the user activates a link in the terminal —
    /// either an OSC 8 hyperlink emitted by the TUI, or an implicit URL the
    /// emulator auto-detected in the buffer. Default impl is a no-op; we want
    /// the user's default app to open the URL the way macOS Terminal.app does.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), url.scheme != nil else {
            return
        }
        // Only open http(s) / file / mailto schemes by default; refuse anything
        // weirder a TUI might embed (e.g. `javascript:`) so a hostile process
        // can't navigate the user's machine.
        let safeSchemes: Set<String> = ["http", "https", "mailto", "file"]
        guard let scheme = url.scheme?.lowercased(), safeSchemes.contains(scheme) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

final class CapturingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?(slice)
        super.dataReceived(slice: slice)
    }

    func claimKeyboardFocus() {
        window?.makeFirstResponder(self)
    }
}

private extension LocalProcessTerminalView {
    /// Configure the terminal to feel like a native macOS terminal pane —
    /// canonical near-black background, a soft off-white foreground, and a
    /// calm translucent-accent selection color. The default SwiftTerm
    /// selection color is `NSColor.selectedTextBackgroundColor`, which is
    /// tuned for white-paper text fields; on a black terminal it lands as
    /// a glaring near-white block ("white-highlighted text") that looks
    /// like a rendering glitch.
    func configureNativeFeel() {
        metalBufferingMode = .perFrameAggregated
        try? setUseMetal(true)
        getTerminal().setCursorStyle(.steadyBlock)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        wantsLayer = true
        applyWorkbenchTheme(WorkbenchTerminalPalette.theme(for: effectiveAppearance))
    }

    /// Install a complete Workbench theme on this SwiftTerm view: the four
    /// chrome colors plus the 16-entry ANSI palette. Called from
    /// `configureNativeFeel` at init and again whenever the host view notices
    /// the system appearance flipped between light and dark.
    func applyWorkbenchTheme(_ theme: WorkbenchTerminalPalette.Theme) {
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        // Calm translucent accent for selections. The direct fix for the
        // "white-highlighted text" artifact on a dark terminal.
        selectedTextBackgroundColor = theme.selection
        caretColor = theme.caret
        caretTextColor = theme.caretText
        // Install the 16-entry ANSI palette. Without this, SGR color codes
        // collapse to a monochrome interpretation — which is why Claude Code
        // and other TUIs were rendering black-and-white in 0.1.25.
        installColors(theme.ansiPalette)
        layer?.backgroundColor = theme.background.cgColor
    }
}

private extension String {
    var looksLikeOnboardingQuestion: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if trimmed.contains("?") {
            return true
        }
        let questionPrefixes = [
            "what ",
            "why ",
            "how ",
            "which ",
            "when ",
            "where ",
            "who ",
            "should ",
            "do i ",
            "does ",
            "can you tell",
            "help me understand"
        ]
        return questionPrefixes.contains { trimmed.hasPrefix($0) }
    }
}
#endif
