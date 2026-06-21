import Foundation

/// U33: the single, sectioned overflow menu for a running session's header.
///
/// The header used to carry TWO adjacent overflow menus: a generic "Session
/// Controls" menu (Focus/Redraw/Restart/Ctrl-C/Esc/EOF + Copy Launch / Open Dir)
/// and a "More" menu (Ask Boss + Copy Launch / Open Dir + Edit/Duplicate/Move/
/// Archive/Delete). "Copy Launch Command" and "Open Working Directory" appeared in
/// BOTH, the split was arbitrary (Restart — a relaunch — sat in the send-keys menu
/// while Edit/Duplicate sat in the other), and "Session Controls" is a container
/// word that names no capability. A first-timer couldn't predict which menu held
/// which action and found the same two commands in each.
///
/// This pure seam lays out ONE menu — a top "Ask Boss About This Session" plus
/// labelled sections (Send / Window / This Session) — so the view can't
/// reintroduce the duplication or the container-word label. The decision is
/// unit-testable; the view maps each `Action` onto its button + handler verbatim.
public enum SessionActionMenu {
    /// Every command the single overflow menu can offer. `askBoss` is the top
    /// action (rendered above the sections); the rest live in exactly one section.
    public enum Action: Equatable, Sendable, Hashable {
        case askBoss
        // Send section
        case controlC
        case escape
        case eof
        case redraw
        // Window section
        case focus
        // This Session section
        case copyLaunchCommand
        case openWorkingDirectory
        case restart
        case edit
        case duplicate
        case move
        case archive
        case delete
    }

    public struct Section: Equatable, Sendable {
        public var title: String
        public var actions: [Action]

        public init(title: String, actions: [Action]) {
            self.title = title
            self.actions = actions
        }
    }

    public struct Layout: Equatable, Sendable {
        /// The action shown above the grouped sections (near the top of the menu).
        public var topAction: Action
        public var sections: [Section]

        public init(topAction: Action, sections: [Section]) {
            self.topAction = topAction
            self.sections = sections
        }
    }

    /// - Parameters:
    ///   - isRunning: whether a live process backs the session. Send-key signals,
    ///     Window focus, and Restart only make sense against a live session, so a
    ///     non-running session omits the Send and Window sections and drops Restart
    ///     (the header's primary button already offers Launch/Recover in that case).
    ///   - isCustomSession: whether this is a Workbench-managed custom session (only
    ///     those expose Edit/Duplicate/Move/Archive/Delete). A scanned/imported
    ///     session drops those lifecycle verbs; the always-available launch-command
    ///     and working-directory actions remain.
    public static func layout(isRunning: Bool, isCustomSession: Bool) -> Layout {
        var thisSession: [Action] = [.copyLaunchCommand, .openWorkingDirectory]
        if isRunning {
            thisSession.append(.restart)
        }
        if isCustomSession {
            thisSession.append(contentsOf: [.edit, .duplicate, .move, .archive, .delete])
        }

        var sections: [Section] = []
        if isRunning {
            sections.append(Section(title: "Send", actions: [.controlC, .escape, .eof, .redraw]))
            sections.append(Section(title: "Window", actions: [.focus]))
        }
        sections.append(Section(title: "This Session", actions: thisSession))

        return Layout(topAction: .askBoss, sections: sections)
    }
}
