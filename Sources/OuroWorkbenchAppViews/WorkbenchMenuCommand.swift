#if os(macOS)
import Foundation

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
#endif
