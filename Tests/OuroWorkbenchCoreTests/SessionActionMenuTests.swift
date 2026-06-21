import XCTest
@testable import OuroWorkbenchCore

/// U33: the running-session header carried TWO adjacent overflow menus — a generic
/// "Session Controls" menu (send-keys + Copy Launch / Open Dir) and a "More" menu
/// (Ask Boss + Copy Launch / Open Dir + Edit/Duplicate/Move/Archive/Delete) — with
/// "Copy Launch Command" and "Open Working Directory" duplicated across both and an
/// arbitrary split (Restart in the send-keys menu, Edit/Duplicate in the other).
/// This pure seam lays out ONE sectioned menu so the view can't reintroduce the
/// duplication or the container-word label.
final class SessionActionMenuTests: XCTestCase {

    // MARK: - Single menu, labelled sections (running custom session)

    func testRunningSessionHasAskBossThenLabelledSections() {
        let layout = SessionActionMenu.layout(isRunning: true, isCustomSession: true)
        // "Ask Boss About This Session" sits at the top, outside the grouped sections.
        XCTAssertEqual(layout.topAction, .askBoss)
        XCTAssertEqual(
            layout.sections.map(\.title),
            ["Send", "Window", "This Session"]
        )
    }

    func testSendSectionCarriesTheKeySignalsAndRedraw() {
        let send = section(titled: "Send", isRunning: true, isCustomSession: true)
        XCTAssertEqual(send.actions, [.controlC, .escape, .eof, .redraw])
    }

    func testWindowSectionCarriesFocus() {
        let window = section(titled: "Window", isRunning: true, isCustomSession: true)
        XCTAssertEqual(window.actions, [.focus])
    }

    func testThisSessionSectionCarriesLifecycleAndRestartInOrder() {
        // Restart (a relaunch) now lives WITH the other lifecycle actions, not
        // orphaned in the send-keys menu; Copy Launch / Open Dir appear here once.
        let thisSession = section(titled: "This Session", isRunning: true, isCustomSession: true)
        XCTAssertEqual(
            thisSession.actions,
            [.copyLaunchCommand, .openWorkingDirectory, .restart, .edit, .duplicate, .move, .archive, .delete]
        )
    }

    // MARK: - No command is duplicated

    func testNoCommandAppearsInMoreThanOneSection() {
        let layout = SessionActionMenu.layout(isRunning: true, isCustomSession: true)
        let all = layout.sections.flatMap(\.actions)
        XCTAssertEqual(all.count, Set(all).count, "a command must appear in exactly one section")
        // Specifically the two that used to be in BOTH old menus:
        XCTAssertEqual(all.filter { $0 == .copyLaunchCommand }.count, 1)
        XCTAssertEqual(all.filter { $0 == .openWorkingDirectory }.count, 1)
    }

    func testTopActionIsNotRepeatedInAnySection() {
        let layout = SessionActionMenu.layout(isRunning: true, isCustomSession: true)
        XCTAssertFalse(layout.sections.flatMap(\.actions).contains(.askBoss))
    }

    // MARK: - Non-custom session (no Edit/Duplicate/Move/Archive/Delete)

    func testNonCustomRunningSessionDropsTheCustomLifecycleActions() {
        // A non-custom (scanned/imported) session has no Edit/Duplicate/Move/
        // Archive/Delete, so "This Session" carries only the always-available
        // launch-command + working-directory + restart.
        let thisSession = section(titled: "This Session", isRunning: true, isCustomSession: false)
        XCTAssertEqual(thisSession.actions, [.copyLaunchCommand, .openWorkingDirectory, .restart])
        // The Send and Window sections are unaffected.
        XCTAssertEqual(section(titled: "Send", isRunning: true, isCustomSession: false).actions, [.controlC, .escape, .eof, .redraw])
        XCTAssertEqual(section(titled: "Window", isRunning: true, isCustomSession: false).actions, [.focus])
    }

    // MARK: - Non-running session: no Send/Window/Restart

    func testNonRunningCustomSessionOmitsSendWindowAndRestart() {
        let layout = SessionActionMenu.layout(isRunning: false, isCustomSession: true)
        XCTAssertEqual(layout.sections.map(\.title), ["This Session"])
        let thisSession = section(titled: "This Session", isRunning: false, isCustomSession: true)
        // No Restart (nothing live to restart — primary button offers Launch),
        // and no send-key/window actions anywhere.
        XCTAssertEqual(
            thisSession.actions,
            [.copyLaunchCommand, .openWorkingDirectory, .edit, .duplicate, .move, .archive, .delete]
        )
        XCTAssertFalse(layout.sections.flatMap(\.actions).contains(.restart))
        XCTAssertFalse(layout.sections.flatMap(\.actions).contains(.focus))
    }

    func testNonRunningNonCustomSessionHasOnlyLaunchCommandAndDir() {
        let thisSession = section(titled: "This Session", isRunning: false, isCustomSession: false)
        XCTAssertEqual(thisSession.actions, [.copyLaunchCommand, .openWorkingDirectory])
    }

    func testNoContainerWordLabelInAnyConfiguration() {
        // U33: drop the generic "Session Controls" container label — no section is
        // named with a container word, in any configuration.
        for running in [true, false] {
            for custom in [true, false] {
                let layout = SessionActionMenu.layout(isRunning: running, isCustomSession: custom)
                for section in layout.sections {
                    XCTAssertFalse(
                        section.title.localizedCaseInsensitiveContains("controls"),
                        "container word leaked: \(section.title)"
                    )
                }
            }
        }
    }

    // MARK: - Helper

    private func section(titled title: String, isRunning: Bool, isCustomSession: Bool) -> SessionActionMenu.Section {
        let layout = SessionActionMenu.layout(isRunning: isRunning, isCustomSession: isCustomSession)
        guard let match = layout.sections.first(where: { $0.title == title }) else {
            XCTFail("no section titled \(title)")
            return SessionActionMenu.Section(title: title, actions: [])
        }
        return match
    }
}
