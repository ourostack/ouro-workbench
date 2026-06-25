#if os(macOS)
import AppKit
import OuroAppShellUI
import OuroWorkbenchAppViews
import OuroWorkbenchCore
import OuroWorkbenchShellAdapter
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Minimal app delegate so closing the last window quits the app instead of
/// leaving a headless process behind. Without this, closing the window tears
/// down the SwiftUI scene — deallocating the view model and cancelling the
/// Boss-Watch / external-action loops — while the menu-bar item (a weak ref)
/// lingers pointing at nothing: autonomy silently stops but the UI implies
/// it's still running. Quitting on last-window-close is the honest behavior;
/// `prepareForTermination` (willTerminate) detaches persistent sessions so a
/// relaunch reattaches them. To keep Workbench in the background, minimize
/// (⌘M) rather than close — that preserves the window, model, and loops.
final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct OuroWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("") {
            WorkbenchRootView(diagnostics: workbenchLaunchDiagnostics)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        // Every global/navigation shortcut is registered here as a real
        // menu-bar key equivalent, NOT as a SwiftUI view `.keyboardShortcut`.
        // macOS matches menu key equivalents before the event reaches the first
        // responder, so these fire even while a SwiftTerm terminal has focus —
        // which a view-level shortcut would let the terminal swallow. Each item
        // posts a `WorkbenchMenuCommand`; the root view dispatches it.
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Ouro Workbench…") {
                    NotificationCenter.default.post(name: .workbenchMenuCommand, object: WorkbenchMenuCommand.about)
                }
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .workbenchMenuCommand, object: WorkbenchMenuCommand.checkForUpdates)
                }
            }
            CommandGroup(replacing: .newItem) {
                menuCommand("New Terminal", .newTerminal, "n")
                menuCommand("New Terminal Tab", .newTerminal, "t")
                Divider()
                menuCommand("Open Workspace…", .openWorkspace, "o")
                menuCommand("Save Workspace As…", .saveWorkspace, "s", [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                menuCommand("Toggle Sidebar", .toggleSidebar, "b", [.command, .control])
                menuCommand("Enter / Exit Focus", .toggleFocus, "f", [.command, .shift])
                Divider()
                menuCommand("Increase Terminal Font", .fontIncrease, "=")
                menuCommand("Decrease Terminal Font", .fontDecrease, "-")
                menuCommand("Reset Terminal Font", .fontReset, "0")
            }
            CommandMenu("Terminal") {
                menuCommand("Find in Terminal", .findInTerminal, "f")
                menuCommand("Redraw", .redraw, "l")
                menuCommand("Stop", .stopSelected, ".")
                Divider()
                menuCommand("Previous Terminal", .prevTerminal, "[")
                menuCommand("Next Terminal", .nextTerminal, "]")
                menuCommand("Previous Workspace", .prevGroup, "[", [.command, .shift])
                menuCommand("Next Workspace", .nextGroup, "]", [.command, .shift])
                Divider()
                // Slice ②d — inline-rename chords (D2d-8): ⇧⌘R renames the active
                // workspace, ⌘R renames the selected tab. Wired through the chord
                // dispatcher (the in-repo pattern) so they fire even with no menu open;
                // the context-menu items carry the same labels as cmux affordances.
                menuCommand("Rename Workspace…", .renameWorkspace, "r", [.command, .shift])
                menuCommand("Rename Tab…", .renameTab, "r")
                Divider()
                Menu("Select Terminal") {
                    ForEach(1...9, id: \.self) { index in
                        menuCommand("Terminal \(index)", .selectTerminal(index), KeyEquivalent(Character("\(index)")))
                    }
                }
                Divider()
                // Split-pane (W5 increment 1). ⌥⌘ combos are chosen because
                // nothing else in the app uses the Option modifier (verified by
                // grep), so these compose cleanly with the existing ⌘-key
                // equivalents and don't shadow ⌘F/⌘K/⌘J/⌘1-9/⌘T/⌘W/⇧⌘B etc.
                // They stay menu key equivalents (not view shortcuts) so they
                // fire even while a SwiftTerm terminal holds keyboard focus.
                menuCommand("Split Right", .splitRight, .rightArrow, [.command, .option])
                menuCommand("Split Down", .splitDown, .downArrow, [.command, .option])
                menuCommand("Focus Other Pane", .focusOtherPane, "]", [.command, .option])
                menuCommand("Close Pane", .closePane, "w", [.command, .option])
            }
            CommandMenu("Boss") {
                menuCommand(WorkbenchViewModel.checkInActionLabel, .bossCheckIn, "i")
                menuCommand("Command Palette", .commandPalette, "k")
                menuCommand("Jump to Next Needing Me", .jumpToAttention, "j")
            }
            CommandGroup(after: .appSettings) {
                menuCommand("Settings…", .settings, ",")
            }
            CommandGroup(after: .help) {
                menuCommand("Keyboard Shortcuts", .shortcutsHelp, "/")
                Button("Report a Bug…") {
                    NotificationCenter.default.post(name: .workbenchReportBug, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }

    @ViewBuilder
    private func menuCommand(
        _ title: String,
        _ command: WorkbenchMenuCommand,
        _ key: KeyEquivalent,
        _ modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .workbenchMenuCommand, object: command)
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }
}
#endif
