import Foundation

/// Anonymizes free-text + gathered context before it leaves the user's machine in a
/// "Report a Bug" GitHub issue (#236).
///
/// The operator requirement is hard: NOTHING that identifies the machine or its owner may
/// reach the issue. This redactor strips, in a deliberate longest-match-first order so
/// partials cannot leak:
///   1. the home path (e.g. `/Users/microsoft` → `~`)
///   2. the username token (whole-word, case-insensitive → `<user>`)
///   3. each agent name (whole-word, case-insensitive, longer names first → `<agent>`)
///   4. token / secret shapes (`vault_…`, `gh[pousr]_…`, `Bearer …`, 32+ char blobs → `<redacted>`)
///   5. email addresses (`…@….…` → `<email>`)
///
/// Home path is replaced before the username so that the username embedded *inside* the path
/// is consumed by `~` and never double-handled. The whole flow is deterministic — same input,
/// same output — so the formatted issue body is reproducible and testable.
public struct WorkbenchBugReportRedactor: Sendable {
    public init() {}

    /// Apply every redaction pass, in order, to `text`. Empty `homePath` / `username` are
    /// no-ops (we never replace the empty string).
    public func redact(_ text: String, agentNames: [String], homePath: String, username: String) -> String {
        var result = text

        // 1. Home path → "~". Longest, most specific replacement first. Plain substring
        //    replacement (a path is not a word-bounded token).
        if !homePath.isEmpty {
            result = result.replacingOccurrences(of: homePath, with: "~")
        }

        // 2. Username → "<user>", whole-word, case-insensitive.
        if !username.isEmpty {
            result = Self.replaceWholeWord(in: result, word: username, with: "<user>")
        }

        // 3. Agent names → "<agent>", whole-word, case-insensitive. Process longer names
        //    first so a multi-word name is consumed before its component words.
        let orderedAgents = agentNames
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.count > $1.count }
        for name in orderedAgents {
            result = Self.replaceWholeWord(in: result, word: name, with: "<agent>")
        }

        // 4. Token / secret shapes → "<redacted>".
        for pattern in Self.secretPatterns {
            result = Self.replaceRegex(in: result, pattern: pattern, with: "<redacted>")
        }

        // 5. Email addresses → "<email>".
        result = Self.replaceRegex(in: result, pattern: Self.emailPattern, with: "<email>")

        return result
    }

    // MARK: - Patterns

    /// Secret-shaped patterns, redacted in order. The trailing 32+ char rule is a catch-all
    /// for opaque token blobs; the named prefixes catch shorter, recognisably-secret tokens
    /// the length floor would otherwise miss.
    private static let secretPatterns: [String] = [
        "vault_[A-Za-z0-9]+",
        "gh[pousr]_[A-Za-z0-9]+",
        "Bearer\\s+\\S+",
        "[A-Za-z0-9._\\-]{32,}"
    ]

    private static let emailPattern = "\\S+@\\S+\\.\\S+"

    // MARK: - Regex helpers

    /// Replace a whole-word, case-insensitive occurrence of `word` with `replacement`.
    /// `word` is treated as a literal (regex-escaped) and bounded by `\b…\b`, so a username
    /// like "microsoft" matches "microsoft" but never "microsoftware".
    private static func replaceWholeWord(in text: String, word: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return replaceRegex(in: text, pattern: "\\b\(escaped)\\b", with: replacement, caseInsensitive: true)
    }

    /// Apply a single NSRegularExpression replacement across the whole string.
    ///
    /// Every call site passes a pattern that is valid by construction — a static literal
    /// pattern, or a regex-escaped user token wrapped in `\b…\b`. `try!` is therefore total
    /// here (it can only trap on a programmer error in this file, not on any input), which is
    /// why there is no unreachable malformed-pattern fallback branch.
    private static func replaceRegex(
        in text: String,
        pattern: String,
        with replacement: String,
        caseInsensitive: Bool = false
    ) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // Template "$" / "\" are escaped so a literal replacement is inserted verbatim.
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

/// One titled block of auto-attached, anonymized context (e.g. "Workbench version", "PATH").
///
/// Modelled as a struct (rather than a bare tuple) so it is `Codable` for the App-side
/// gathering layer and `Equatable` for tests.
public struct WorkbenchBugReportSection: Codable, Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// A pure, App-framework-free bug report: the user's free-text plus the gathered context
/// sections. Knows how to derive a GitHub issue title and a fully-anonymized Markdown body.
///
/// The screenshot, context-gathering, and actual issue filing are App-side; this Core type is
/// the testable seam that decides *what text* goes into the issue.
public struct WorkbenchBugReport: Sendable {
    public var userText: String
    public var contextSections: [WorkbenchBugReportSection]

    public init(userText: String, contextSections: [WorkbenchBugReportSection]) {
        self.userText = userText
        self.contextSections = contextSections
    }

    /// Maximum issue-title length before we truncate and append an ellipsis.
    private static let titleLimit = 70

    /// The issue title: the first non-blank line of `userText`, trimmed and capped at
    /// ~70 chars (with a trailing "…" when truncated). Falls back to a generic title when
    /// `userText` has no usable line.
    public func issueTitle() -> String {
        let firstLine = userText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })

        guard let line = firstLine, !line.isEmpty else {
            return "Workbench bug report"
        }

        if line.count > Self.titleLimit {
            let prefix = line.prefix(Self.titleLimit)
            return "\(prefix)…"
        }
        return line
    }

    /// The Markdown issue body: redacted `userText`, an anonymized-context divider, then each
    /// section (title + redacted body). Both the user text and every section body are
    /// redacted. Sections whose body is blank (after trimming) are omitted entirely.
    public func issueBody(
        redactor: WorkbenchBugReportRedactor,
        agentNames: [String],
        homePath: String,
        username: String
    ) -> String {
        func redact(_ text: String) -> String {
            redactor.redact(text, agentNames: agentNames, homePath: homePath, username: username)
        }

        var body = redact(userText)
        body += "\n\n---\n_Auto-attached context (anonymized):_\n"

        for section in contextSections {
            guard !section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            body += "\n**\(section.title):**\n\(redact(section.body))"
        }

        return body
    }
}
