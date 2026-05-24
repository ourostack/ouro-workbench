import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class TranscriptSearchTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testSearchFindsCaseInsensitiveMatchesAcrossTranscriptRunsNewestFirst() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo"
        )
        let olderPath = try writeTranscript(name: "older.log", text: "boot\nNeed Ari for copy\n")
        let newerPath = try writeTranscript(name: "newer.log", text: "status\nneed ari for launch\n")
        let olderRun = ProcessRun(
            entryId: entry.id,
            status: .exited,
            startedAt: Date(timeIntervalSince1970: 1_000),
            transcriptPath: olderPath
        )
        let newerRun = ProcessRun(
            entryId: entry.id,
            status: .exited,
            startedAt: Date(timeIntervalSince1970: 2_000),
            transcriptPath: newerPath
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [entry],
            processRuns: [olderRun, newerRun]
        )

        let matches = TranscriptSearcher().search(query: "Need Ari", state: state)

        XCTAssertEqual(matches.map(\.transcriptPath), [newerPath, olderPath])
        XCTAssertEqual(matches.map(\.entryName), ["Codex", "Codex"])
        XCTAssertEqual(matches.map(\.lineNumber), [2, 2])
    }

    func testSearchHonorsMaxMatchesAndSkipsMissingFiles() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo"
        )
        let transcriptPath = try writeTranscript(name: "shell.log", text: "needle one\nneedle two\nneedle three\n")
        let run = ProcessRun(entryId: entry.id, status: .exited, transcriptPath: transcriptPath)
        let missingRun = ProcessRun(
            entryId: entry.id,
            status: .exited,
            transcriptPath: temporaryDirectory.appendingPathComponent("missing.log").path
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [entry],
            processRuns: [run, missingRun]
        )

        let matches = TranscriptSearcher().search(query: "needle", state: state, maxMatches: 2)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.line), ["needle one", "needle two"])
    }

    func testSearchHandlesCRLFLinesAndDiacriticInsensitiveMatches() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo"
        )
        let transcriptPath = try writeTranscript(name: "unicode.log", text: "café ready\r\nnext\r\n")
        let run = ProcessRun(entryId: entry.id, status: .exited, transcriptPath: transcriptPath)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let matches = TranscriptSearcher().search(query: "cafe", state: state)

        XCTAssertEqual(matches.map(\.line), ["café ready"])
        XCTAssertEqual(matches.map(\.lineNumber), [1])
    }

    func testSearchStripsANSIEscapeCodesFromMatches() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo"
        )
        let transcriptPath = try writeTranscript(
            name: "ansi.log",
            text: "\u{001B}[01;34mouro\u{001B}[00m@\u{001B}[01;36mhost\u{001B}[00m\n"
        )
        let run = ProcessRun(entryId: entry.id, status: .exited, transcriptPath: transcriptPath)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let matches = TranscriptSearcher().search(query: "ouro", state: state)

        XCTAssertEqual(matches.map(\.line), ["ouro@host"])
    }

    func testEmptyQueryReturnsNoMatches() {
        let state = WorkspaceState()

        XCTAssertEqual(TranscriptSearcher().search(query: "  ", state: state), [])
    }

    func testTranscriptSearchLimitClampsCallerProvidedValues() {
        XCTAssertEqual(TranscriptSearchLimit.clamped(nil), 50)
        XCTAssertEqual(TranscriptSearchLimit.clamped(0), 1)
        XCTAssertEqual(TranscriptSearchLimit.clamped(20), 20)
        XCTAssertEqual(TranscriptSearchLimit.clamped(500), 200)
    }

    private func writeTranscript(name: String, text: String) throws -> String {
        let url = temporaryDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
