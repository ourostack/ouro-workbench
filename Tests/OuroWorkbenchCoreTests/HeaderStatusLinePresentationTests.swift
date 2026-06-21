import XCTest
@testable import OuroWorkbenchCore

/// U31(b): the in-window header's one-line status text is signal-dense — it stays
/// HIDDEN on a genuinely quiet machine (nobody waiting, 0 running, 0 actionable
/// recovery) instead of printing two information-free zeros ("0 running, nothing
/// to recover"). The boss prompt builder keeps the raw `oneLineStatus`; only the
/// human header gates on this pure should-show/text derivation.
final class HeaderStatusLinePresentationTests: XCTestCase {
    private func project() -> WorkbenchProject {
        WorkbenchProject(name: "Project", rootPath: "/repo")
    }

    // MARK: - Quiet machine → hidden

    func testQuietMachineHidesTheLine() {
        // Nothing running, nothing waiting, nothing to recover: the line adds no
        // information, so it doesn't render.
        let summary = WorkspaceSummarizer().summarize(WorkspaceState(projects: [project()]))
        let presentation = HeaderStatusLinePresentation.resolve(summary: summary)
        XCTAssertFalse(presentation.shouldShow)
        XCTAssertEqual(summary.oneLineStatus, "0 running, nothing to recover", "guards the quiet baseline")
    }

    // MARK: - Something to say → shown, with the existing text

    func testWaitingOnHumanShowsTheLine() {
        let p = project()
        let entry = ProcessEntry(
            projectId: p.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            attention: .waitingOnHuman
        )
        let state = WorkspaceState(
            projects: [p],
            processEntries: [entry],
            processRuns: [ProcessRun(entryId: entry.id, status: .waitingForInput)]
        )
        let summary = WorkspaceSummarizer().summarize(state)
        let presentation = HeaderStatusLinePresentation.resolve(summary: summary)
        XCTAssertTrue(presentation.shouldShow)
        XCTAssertEqual(presentation.text, summary.oneLineStatus)
        XCTAssertEqual(presentation.text, "Codex waiting on human input")
    }

    func testRunningSessionShowsTheLine() {
        let p = project()
        let entry = ProcessEntry(
            projectId: p.id,
            name: "Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo"
        )
        let state = WorkspaceState(
            projects: [p],
            processEntries: [entry],
            processRuns: [ProcessRun(entryId: entry.id, status: .running)]
        )
        let summary = WorkspaceSummarizer().summarize(state)
        let presentation = HeaderStatusLinePresentation.resolve(summary: summary)
        XCTAssertTrue(presentation.shouldShow)
        XCTAssertEqual(presentation.text, summary.oneLineStatus)
        XCTAssertTrue(presentation.text.hasPrefix("1 running"))
    }

    func testActionableRecoveryShowsTheLine() {
        let p = project()
        let entry = ProcessEntry(
            projectId: p.id,
            name: "Claude",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [p], processEntries: [entry], processRuns: [run])
        let summary = WorkspaceSummarizer().summarize(state)
        // A genuinely-lost session needs the operator — surface it even at 0 running.
        XCTAssertEqual(summary.recoveryDigest.actionableCount, 1)
        let presentation = HeaderStatusLinePresentation.resolve(summary: summary)
        XCTAssertTrue(presentation.shouldShow)
        XCTAssertEqual(presentation.text, summary.oneLineStatus)
        // U31(b): no internal "recovery action" jargon leaks (already routed
        // through RecoveryDigest vocabulary).
        XCTAssertFalse(presentation.text.contains("recovery action"), "got: \(presentation.text)")
    }
}
