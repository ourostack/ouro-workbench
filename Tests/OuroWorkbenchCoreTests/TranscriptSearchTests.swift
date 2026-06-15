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

    func testSearchSkipsExistingPathThatCannotBeOpenedAsTranscriptAndKeepsFirstDuplicateEntry() throws {
        let entryId = UUID()
        let first = ProcessEntry(id: entryId, projectId: UUID(), name: "First", kind: .shell, executable: "/bin/zsh", workingDirectory: "/repo")
        let duplicate = ProcessEntry(id: entryId, projectId: UUID(), name: "Duplicate", kind: .shell, executable: "/bin/zsh", workingDirectory: "/repo")
        let directoryPath = temporaryDirectory.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryPath, withIntermediateDirectories: true)
        let transcriptPath = try writeTranscript(name: "duplicate.log", text: "needle\n")
        let directoryRun = ProcessRun(entryId: entryId, status: .exited, transcriptPath: directoryPath.path)
        let realRun = ProcessRun(entryId: entryId, status: .exited, transcriptPath: transcriptPath)
        let state = WorkspaceState(processEntries: [first, duplicate], processRuns: [directoryRun, realRun])

        let matches = TranscriptSearcher().search(query: "needle", state: state)

        XCTAssertEqual(matches.map(\.entryName), ["First"])
        XCTAssertEqual(matches.map(\.transcriptPath), [transcriptPath])
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

    func testSearchClipsVeryLongNoNewlineMatches() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "TUI",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo"
        )
        let longPrefix = String(repeating: "x", count: TranscriptSearchLimit.maximumBufferedLineBytes + 1)
        let transcriptPath = try writeTranscript(
            name: "long.log",
            text: "\(longPrefix)needle\(String(repeating: "y", count: 1_000))"
        )
        let run = ProcessRun(entryId: entry.id, status: .exited, transcriptPath: transcriptPath)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let matches = TranscriptSearcher().search(query: "needle", state: state)

        XCTAssertEqual(matches.count, 1)
        XCTAssertLessThanOrEqual(matches[0].line.count, TranscriptSearchLimit.maximumLineCharacters + 6)
        XCTAssertTrue(matches[0].line.contains("needle"))
    }

    func testEmptyQueryReturnsNoMatches() {
        let state = WorkspaceState()

        XCTAssertEqual(TranscriptSearcher().search(query: "  ", state: state), [])
        XCTAssertEqual(TranscriptSearcher().search(query: "needle", state: state, maxMatches: 0), [])
    }

    func testMatchIdCombinesRunAndLineNumber() {
        let runId = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let match = TranscriptSearchMatch(
            entryId: UUID(),
            entryName: "Shell",
            runId: runId,
            transcriptPath: "/Users/example/transcript.log",
            lineNumber: 42,
            line: "needle"
        )

        XCTAssertEqual(match.id, "\(runId.uuidString):42")
    }

    func testSearchHandlesShortFinalLineWithoutTrailingNewlineAndMissingEntryFallback() throws {
        let entryId = UUID(uuidString: "00000000-0000-0000-0000-00000000feed")!
        let transcriptPath = try writeTranscript(name: "final-line.log", text: "final needle")
        let run = ProcessRun(entryId: entryId, status: .exited, transcriptPath: transcriptPath)
        let state = WorkspaceState(processRuns: [run])

        let matches = TranscriptSearcher().search(query: "needle", state: state)

        XCTAssertEqual(matches.map(\.lineNumber), [1])
        XCTAssertEqual(matches.map(\.entryName), [entryId.uuidString])
        XCTAssertEqual(matches.map(\.line), ["final needle"])
    }

    func testClippedLineDefensiveFallbackWhenQueryIsAbsent() {
        let longLine = String(repeating: "a", count: TranscriptSearchLimit.maximumLineCharacters + 10)

        let clipped = TranscriptSearcher().clippedLine(longLine, query: "needle")

        XCTAssertEqual(clipped, "\(longLine.prefix(TranscriptSearchLimit.maximumLineCharacters))...")
    }

    func testClippedLineOmitsPrefixOrSuffixWhenMatchTouchesBoundary() {
        let longAfter = "needle" + String(repeating: "a", count: TranscriptSearchLimit.maximumLineCharacters + 10)
        let longBefore = String(repeating: "a", count: TranscriptSearchLimit.maximumLineCharacters + 10) + "needle"

        XCTAssertFalse(TranscriptSearcher().clippedLine(longAfter, query: "needle").hasPrefix("..."))
        XCTAssertFalse(TranscriptSearcher().clippedLine(longBefore, query: "needle").hasSuffix("..."))
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
