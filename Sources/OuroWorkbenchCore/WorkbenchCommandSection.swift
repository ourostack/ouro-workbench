import Foundation

/// U37(b): the labelled sections the ~34-item command palette is grouped into, so
/// the flat list stops scrolling far past the window and is scannable.
///
/// Every `WorkbenchCommandID` is classified into exactly one section (Session /
/// Boss / Workspace / Agents / Diagnostics / App), and `grouped(_:)` buckets a
/// descriptor list into ordered, non-empty sections preserving each command's
/// original order within its section. Pure so the classification is unit-tested;
/// the `CommandPaletteSheet` renders the section headers verbatim.
public enum WorkbenchCommandSection: String, CaseIterable, Sendable {
    case session
    case boss
    case workspace
    case agents
    case diagnostics
    case app

    public var title: String {
        switch self {
        case .session:
            return "Session"
        case .boss:
            return "Boss"
        case .workspace:
            return "Workspace"
        case .agents:
            return "Agents"
        case .diagnostics:
            return "Diagnostics"
        case .app:
            return "App"
        }
    }

    /// The order sections render in the palette.
    public static let displayOrder: [WorkbenchCommandSection] =
        [.session, .boss, .workspace, .agents, .diagnostics, .app]

    /// One grouped section of palette commands.
    public struct Group: Equatable, Sendable {
        public var section: WorkbenchCommandSection
        public var commands: [WorkbenchCommandDescriptor]

        public init(section: WorkbenchCommandSection, commands: [WorkbenchCommandDescriptor]) {
            self.section = section
            self.commands = commands
        }
    }

    /// The section a command ID belongs to. Exhaustive over `WorkbenchCommandID`
    /// (no `default` bucket) so a newly-added command can't silently fall into the
    /// wrong group — the switch fails to compile until it's classified.
    public static func section(for id: WorkbenchCommandID) -> WorkbenchCommandSection {
        switch id {
        // Session — terminal lifecycle + the selected session's actions.
        case .newSession,
             .launchSelectedSession,
             .focusSelectedSession,
             .redrawSelectedSession,
             .sendControlCToSelectedSession,
             .sendEscapeToSelectedSession,
             .sendEOFToSelectedSession,
             .copySelectedLaunchCommand,
             .openSelectedWorkingDirectory,
             .revealSelectedTranscript,
             .stopSelectedSession,
             .recoverSelectedSession,
             .searchTranscripts,
             .stopAllRunningSessions,
             .recoverAllCrashedSessions:
            return .session

        // Boss — check-in, the quick asks, watch/pane toggles, the boss bridge,
        // the decision inbox, and the opt-in boss setup wizard.
        case .bossCheckIn,
             .bossQuickWhatsGoingOn,
             .bossQuickWaitingOnMe,
             .bossQuickKeepMoving,
             .bossQuickRespondForMe,
             .toggleBossWatch,
             .toggleBossPane,
             .installWorkbenchMCPForBoss,
             .refreshWorkbenchMCP,
             .openDecisionLog,
             .askBossAboutSelectedSession,
             .openOnboarding:
            return .boss

        // Workspace — open/save the .workbench.json workspace.
        case .openWorkspaceConfig,
             .saveWorkspaceConfig:
            return .workspace

        // Agents — manage / install / select / repair agent bundles.
        case .manageAgents,
             .selectAgent,
             .useSelectedAgentAsBoss,
             .openSelectedAgentConfig,
             .revealSelectedAgentBundle,
             .repairSelectedAgent,
             .installMCPForSelectedAgent,
             .installOuroAgent,
             .refreshOuroAgents:
            return .agents

        // Diagnostics — support zip, bug reports, recovery drill, refresh.
        case .collectSupportDiagnostics,
             .revealSupportDiagnostics,
             .copySupportDiagnosticsPath,
             .openSupportDiagnosticsFolder,
             .reportBug,
             .fileBugReportIssue,
             .revealBugReportsFolder,
             .runRecoveryDrill,
             .refreshWorkspace,
             .openHarnessStatus:
            return .diagnostics

        // App — settings, updates, help, about, factory reset.
        case .openSettings,
             .showKeyboardShortcutHelp,
             .openAbout,
             .checkReleaseUpdates,
             .openReleaseUpdate,
             .resetToFirstRun:
            return .app
        }
    }

    /// Bucket a descriptor list into ordered, non-empty sections. Sections render
    /// in `displayOrder`; within a section the commands keep their original order.
    public static func grouped(_ commands: [WorkbenchCommandDescriptor]) -> [Group] {
        displayOrder.compactMap { section in
            let matching = commands.filter { self.section(for: $0.id) == section }
            return matching.isEmpty ? nil : Group(section: section, commands: matching)
        }
    }
}
