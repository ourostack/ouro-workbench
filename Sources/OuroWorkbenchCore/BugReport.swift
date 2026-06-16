import Foundation

/// One session as it appears in a bug report — a flattened, render-ready row so
/// the composer doesn't depend on the full `ProcessEntry`/`ProcessRun` graph.
/// The app maps its live state into these (trivial field-copying), keeping the
/// markdown builder pure and exhaustively testable.
public struct BugReportSession: Equatable, Sendable {
    public var name: String
    public var status: String
    public var attention: String
    public var trust: String
    public var friend: String?
    public var workingDirectory: String?
    public var gitBranch: String?

    public init(
        name: String,
        status: String,
        attention: String,
        trust: String,
        friend: String? = nil,
        workingDirectory: String? = nil,
        gitBranch: String? = nil
    ) {
        self.name = name
        self.status = status
        self.attention = attention
        self.trust = trust
        self.friend = friend
        self.workingDirectory = workingDirectory
        self.gitBranch = gitBranch
    }
}

/// Everything that goes into a bug report's `report.md`. Plain values plus a few
/// existing Core records (decisions, action log), so the whole document is built
/// by a pure function the tests can pin byte-for-byte.
public struct BugReportContent: Equatable, Sendable {
    public var note: String
    public var appName: String
    public var appVersion: String
    public var buildHash: String
    public var osVersion: String
    public var generatedAt: Date
    public var bossName: String
    public var bossWatchEnabled: Bool
    public var autoAdvanceEnabled: Bool
    public var sessions: [BugReportSession]
    public var recentDecisions: [BossInboxDecision]
    public var recentActions: [WorkbenchActionLogEntry]
    /// Files that sit next to `report.md` in the bundle (e.g. screenshot.png,
    /// diagnostics.zip). Listed so whoever reads the report knows what's attached.
    public var attachmentNames: [String]
    /// Any non-fatal problems gathering the report (e.g. screenshot or
    /// diagnostics failed) — surfaced so a partial bundle is still honest.
    public var collectionWarnings: [String]

    public init(
        note: String,
        appName: String,
        appVersion: String,
        buildHash: String,
        osVersion: String,
        generatedAt: Date,
        bossName: String,
        bossWatchEnabled: Bool,
        autoAdvanceEnabled: Bool,
        sessions: [BugReportSession],
        recentDecisions: [BossInboxDecision],
        recentActions: [WorkbenchActionLogEntry],
        attachmentNames: [String],
        collectionWarnings: [String] = []
    ) {
        self.note = note
        self.appName = appName
        self.appVersion = appVersion
        self.buildHash = buildHash
        self.osVersion = osVersion
        self.generatedAt = generatedAt
        self.bossName = bossName
        self.bossWatchEnabled = bossWatchEnabled
        self.autoAdvanceEnabled = autoAdvanceEnabled
        self.sessions = sessions
        self.recentDecisions = recentDecisions
        self.recentActions = recentActions
        self.attachmentNames = attachmentNames
        self.collectionWarnings = collectionWarnings
    }
}

/// Builds the human- and Claude-readable `report.md`, a filesystem-safe bundle
/// directory name, and a slug — all pure so the bug-report bundle's contents are
/// unit-tested rather than assembled ad hoc in the view model.
public enum BugReportComposer {
    /// How many decisions / actions to inline before truncating, so a report
    /// stays skimmable even on a long-lived workspace.
    public static let decisionLimit = 20
    public static let actionLimit = 30

    public static func markdown(_ content: BugReportContent) -> String {
        var lines: [String] = []

        lines.append("# \(content.appName) bug report")
        lines.append("")
        lines.append("- **When:** \(timestamp(content.generatedAt))")
        lines.append("- **App:** \(content.appName) \(content.appVersion) (build \(content.buildHash))")
        lines.append("- **macOS:** \(content.osVersion)")
        lines.append(
            "- **Boss:** \(content.bossName) · Boss Watch \(onOff(content.bossWatchEnabled))"
            + " · Auto-advance \(onOff(content.autoAdvanceEnabled))"
        )
        lines.append("")

        lines.append("## What happened")
        lines.append("")
        let trimmedNote = content.note.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(trimmedNote.isEmpty ? "_(no description provided)_" : trimmedNote)
        lines.append("")

        if !content.collectionWarnings.isEmpty {
            lines.append("## Collection warnings")
            lines.append("")
            for warning in content.collectionWarnings {
                lines.append("- \(inlineSafe(warning))")
            }
            lines.append("")
        }

        lines.append("## Attachments")
        lines.append("")
        if content.attachmentNames.isEmpty {
            lines.append("_(none)_")
        } else {
            for name in content.attachmentNames {
                lines.append("- `\(name)`")
            }
        }
        lines.append("")

        lines.append("## Sessions (\(content.sessions.count))")
        lines.append("")
        if content.sessions.isEmpty {
            lines.append("_(no sessions)_")
        } else {
            lines.append("| Session | Status | Attention | Trust | Friend | Branch | Directory |")
            lines.append("|---|---|---|---|---|---|---|")
            for session in content.sessions {
                let row = [
                    session.name,
                    session.status,
                    session.attention,
                    session.trust,
                    session.friend ?? "—",
                    session.gitBranch ?? "—",
                    session.workingDirectory ?? "—"
                ].map(cellSafe).joined(separator: " | ")
                lines.append("| \(row) |")
            }
        }
        lines.append("")

        appendDecisions(content.recentDecisions, to: &lines)
        appendActions(content.recentActions, to: &lines)

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendDecisions(_ decisions: [BossInboxDecision], to lines: inout [String]) {
        lines.append("## Recent boss decisions (\(decisions.count))")
        lines.append("")
        if decisions.isEmpty {
            lines.append("_(none)_")
            lines.append("")
            return
        }
        for decision in decisions.prefix(decisionLimit) {
            var head = "- **\(timestamp(decision.occurredAt))** · \(decision.sessionName ?? "—")"
            head += " · `\(decision.kind.rawValue)` (\(decision.status.rawValue))"
            if let input = nonEmpty(decision.proposedInput) {
                head += " · sent `\(inlineSafe(input))`"
            }
            lines.append(head)
            lines.append("  - prompt: \(inlineSafe(decision.prompt))")
            if let friend = nonEmpty(decision.friendName) {
                lines.append("  - friend: \(inlineSafe(friend))")
            }
            if let cited = nonEmpty(decision.preferenceCited) {
                lines.append("  - why: \(inlineSafe(cited))")
            }
            if let confidence = decision.confidence {
                lines.append("  - confidence: \(String(format: "%.2f", confidence))")
            }
            let reasoning = inlineSafe(decision.reasoning)
            if !reasoning.isEmpty {
                lines.append("  - reasoning: \(reasoning)")
            }
        }
        if decisions.count > decisionLimit {
            lines.append("- _…and \(decisions.count - decisionLimit) older_")
        }
        lines.append("")
    }

    private static func appendActions(_ actions: [WorkbenchActionLogEntry], to lines: inout [String]) {
        lines.append("## Recent actions (\(actions.count))")
        lines.append("")
        if actions.isEmpty {
            lines.append("_(none)_")
            lines.append("")
            return
        }
        lines.append("| When | Source | Action | Target | Result | OK |")
        lines.append("|---|---|---|---|---|---|")
        for action in actions.prefix(actionLimit) {
            let row = [
                timestamp(action.occurredAt),
                action.source,
                action.action,
                action.targetName ?? "—",
                action.result,
                action.succeeded ? "✓" : "✗"
            ].map(cellSafe).joined(separator: " | ")
            lines.append("| \(row) |")
        }
        if actions.count > actionLimit {
            lines.append("")
            lines.append("_…and \(actions.count - actionLimit) older_")
        }
        lines.append("")
    }

    /// `20260528-140322-terminal-rendering-glitch` — sortable, filesystem-safe,
    /// and self-describing so a folder of reports reads at a glance.
    public static func directoryName(date: Date, note: String, timeZone: TimeZone = .current) -> String {
        let stamp = compactTimestamp(date, timeZone: timeZone)
        let body = slug(from: note)
        return body.isEmpty ? stamp : "\(stamp)-\(body)"
    }

    /// Lowercase, hyphen-joined, alphanumeric slug of the note (capped). Empty
    /// when the note has nothing usable — the caller falls back to the timestamp.
    public static func slug(from note: String, maxLength: Int = 40) -> String {
        let lowered = note.lowercased()
        var result = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen && !result.isEmpty {
                result.append("-")
                lastWasHyphen = true
            }
            if result.count >= maxLength {
                break
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }

    // MARK: - Formatting helpers

    private static func onOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Collapse newlines/tabs and clamp length so a value stays on one line.
    private static func inlineSafe(_ value: String, maxLength: Int = 240) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let squeezed = collapsed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if squeezed.count <= maxLength {
            return squeezed
        }
        return String(squeezed.prefix(maxLength)) + "…"
    }

    /// As `inlineSafe`, but also escapes `|` so it can't break a Markdown table.
    private static func cellSafe(_ value: String) -> String {
        inlineSafe(value, maxLength: 120).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func compactTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

public extension WorkbenchPaths {
    /// Where in-app bug reports live: one timestamped subfolder per report under
    /// the Workbench app-support root, so the path is stable and easy to open.
    var bugReportsURL: URL {
        rootURL.appendingPathComponent("bug-reports", isDirectory: true)
    }
}

/// The on-disk result of writing a bug report bundle.
public struct BugReportBundle: Equatable, Sendable {
    public var directoryURL: URL
    public var reportURL: URL
    public var attachmentNames: [String]
    public var warnings: [String]

    public init(directoryURL: URL, reportURL: URL, attachmentNames: [String], warnings: [String]) {
        self.directoryURL = directoryURL
        self.reportURL = reportURL
        self.attachmentNames = attachmentNames
        self.warnings = warnings
    }
}

/// Assembles a self-contained bug report bundle on disk: `report.md` plus an
/// optional `screenshot.png` and `diagnostics.zip`. Every input is a value, so
/// the bundle's layout is testable against a temp directory rather than relying
/// on the live app. A missing screenshot or failed diagnostics run is recorded
/// as a warning instead of aborting — a partial-but-honest report still ships.
public enum BugReportWriter {
    public static func write(
        into directory: URL,
        note: String,
        appName: String,
        appVersion: String,
        buildHash: String,
        osVersion: String,
        generatedAt: Date,
        bossName: String,
        bossWatchEnabled: Bool,
        autoAdvanceEnabled: Bool,
        sessions: [BugReportSession],
        recentDecisions: [BossInboxDecision],
        recentActions: [WorkbenchActionLogEntry],
        screenshotPNG: Data?,
        diagnosticsArchiveURL: URL?,
        diagnosticsError: String?,
        fileManager: FileManager = .default
    ) throws -> BugReportBundle {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var attachments: [String] = []
        var warnings: [String] = []

        if let screenshotPNG {
            let url = directory.appendingPathComponent("screenshot.png")
            try screenshotPNG.write(to: url)
            attachments.append("screenshot.png")
        } else {
            warnings.append("Window screenshot could not be captured.")
        }

        if let diagnosticsArchiveURL {
            let dest = directory.appendingPathComponent("diagnostics.zip")
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: diagnosticsArchiveURL, to: dest)
            attachments.append("diagnostics.zip")
        } else if let diagnosticsError {
            warnings.append("Support diagnostics failed: \(diagnosticsError)")
        }

        let content = BugReportContent(
            note: note,
            appName: appName,
            appVersion: appVersion,
            buildHash: buildHash,
            osVersion: osVersion,
            generatedAt: generatedAt,
            bossName: bossName,
            bossWatchEnabled: bossWatchEnabled,
            autoAdvanceEnabled: autoAdvanceEnabled,
            sessions: sessions,
            recentDecisions: recentDecisions,
            recentActions: recentActions,
            attachmentNames: attachments,
            collectionWarnings: warnings
        )
        let reportURL = directory.appendingPathComponent("report.md")
        try BugReportComposer.markdown(content).write(to: reportURL, atomically: true, encoding: .utf8)

        return BugReportBundle(
            directoryURL: directory,
            reportURL: reportURL,
            attachmentNames: attachments,
            warnings: warnings
        )
    }
}

/// A GitHub issue ready to file: a one-line title and a Markdown body.
public struct GitHubIssueDraft: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Turns a bug report into a GitHub issue draft. Pure so the title derivation
/// (which has to stay on one line and within GitHub's limits) and the body
/// footer (which points back at the local bundle, since `gh issue create` can't
/// upload the screenshot/zip) are unit-tested.
public enum GitHubIssueComposer {
    public static func draft(
        note: String,
        reportMarkdown: String,
        bundlePath: String?,
        titlePrefix: String = "Bug:"
    ) -> GitHubIssueDraft {
        GitHubIssueDraft(
            title: title(note: note, prefix: titlePrefix),
            body: body(reportMarkdown: reportMarkdown, bundlePath: bundlePath)
        )
    }

    /// `Bug: <first meaningful line of the note>`, collapsed and length-capped;
    /// falls back to a generic title when the note has nothing usable.
    public static func title(note: String, prefix: String = "Bug:", maxLength: Int = 80) -> String {
        let firstLine = note
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let collapsed = firstLine
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let summary = collapsed.isEmpty ? "report from Ouro Workbench" : collapsed

        let prefixed = "\(prefix) \(summary)"
        if prefixed.count <= maxLength {
            return prefixed
        }
        // Truncate the summary, not the prefix, and add an ellipsis.
        let room = max(0, maxLength - prefix.count - 2) // space + ellipsis
        return "\(prefix) \(summary.prefix(room))…"
    }

    public static func body(reportMarkdown: String, bundlePath: String?) -> String {
        guard let bundlePath, !bundlePath.isEmpty else {
            return reportMarkdown
        }
        let trimmed = reportMarkdown.hasSuffix("\n") ? String(reportMarkdown.dropLast()) : reportMarkdown
        return trimmed
            + "\n\n---\n"
            + "The screenshot and diagnostics zip are in the local report bundle "
            + "(not uploaded here): `\(bundlePath)`\n"
    }
}

/// Failures specific to filing a bug report as a GitHub issue, with operator-
/// readable guidance. The venue is best-effort — the local bundle always wins.
public enum GitHubIssueFilingError: Error, Equatable, LocalizedError, Sendable {
    case cliMissing
    case readReportFailed(String)
    case launchFailed(String)
    case commandFailed(String)
    case noURL(String)

    public var errorDescription: String? {
        switch self {
        case .cliMissing:
            return "GitHub CLI (gh) not found. Install it (brew install gh) and run gh auth login, then try again. Your local report is still saved."
        case let .readReportFailed(message):
            return "Could not read the report: \(message)"
        case let .launchFailed(message):
            return "Could not start gh: \(message)"
        case let .commandFailed(output):
            return "gh issue create failed: \(output)"
        case let .noURL(output):
            return "gh did not report an issue URL: \(output)"
        }
    }
}

/// Files a bug report bundle as a GitHub issue via the `gh` CLI. Lives in Core
/// (not the app) so the exact production path — locate `gh`, build the issue,
/// run `gh issue create`, parse the URL — is reused by any caller and is
/// integration-testable. Pure helpers (`resolveCLI`, `parseIssueURL`) are unit
/// tested; `file` performs the real subprocess.
public enum GitHubIssueFiler {
    /// Find the GitHub CLI without relying on a GUI app's minimal PATH: probe
    /// common install locations, then fall back to anything on PATH.
    public static func resolveCLI(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
            "/run/current-system/sw/bin/gh"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let pathEnv = environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("gh")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The created issue URL is the last `https://…` token in `gh`'s output.
    public static func parseIssueURL(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline).reversed() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("https://") {
                return line
            }
        }
        return nil
    }

    /// File the report at `reportURL` as an issue on `repo`. The body is the
    /// report markdown plus a footer pointing at the local bundle (the CLI can't
    /// upload the screenshot/zip). A missing `bug` label transparently retries
    /// without it. Returns the created issue URL.
    public static func file(
        reportURL: URL,
        bundlePath: String,
        note: String,
        repo: String,
        cliURL: URL? = nil,
        bodyDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Result<String, GitHubIssueFilingError> {
        guard let gh = cliURL ?? resolveCLI(fileManager: fileManager) else {
            return .failure(.cliMissing)
        }

        let markdown: String
        do {
            markdown = try String(contentsOf: reportURL, encoding: .utf8)
        } catch {
            return .failure(.readReportFailed(error.localizedDescription))
        }

        let draft = GitHubIssueComposer.draft(note: note, reportMarkdown: markdown, bundlePath: bundlePath)
        return run(gh: gh, draft: draft, repo: repo, withBugLabel: true, bodyDirectory: bodyDirectory, fileManager: fileManager)
    }

    private static func run(
        gh: URL,
        draft: GitHubIssueDraft,
        repo: String,
        withBugLabel: Bool,
        bodyDirectory: URL?,
        fileManager: FileManager
    ) -> Result<String, GitHubIssueFilingError> {
        let bodyURL = (bodyDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("ouro-workbench-issue-\(UUID().uuidString).md")
        do {
            try draft.body.write(to: bodyURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        defer { try? fileManager.removeItem(at: bodyURL) }

        var arguments = [
            "issue", "create",
            "--repo", repo,
            "--title", draft.title,
            "--body-file", bodyURL.path
        ]
        if withBugLabel {
            arguments.append(contentsOf: ["--label", "bug"])
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = gh
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            // A missing `bug` label fails the whole call; retry once without it
            // rather than make the venue depend on a label existing in the repo.
            if withBugLabel, output.lowercased().contains("label") {
                return run(gh: gh, draft: draft, repo: repo, withBugLabel: false, bodyDirectory: bodyDirectory, fileManager: fileManager)
            }
            return .failure(.commandFailed(output.isEmpty ? "gh exited with status \(process.terminationStatus)" : output))
        }
        guard let url = parseIssueURL(from: output) else {
            return .failure(.noURL(output))
        }
        return .success(url)
    }
}
