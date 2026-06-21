import Foundation

/// What a session's recent output suggests about whether it needs the human.
public enum AttentionSignal: Equatable, Sendable {
    /// The session appears to be sitting at a prompt that needs a human
    /// decision (approval, y/n, a selection menu, "press enter").
    case waitingOnHuman
    /// The session appears stuck on a terminal error and isn't making progress
    /// (a fatal/unrecoverable failure as the last thing it printed).
    case blocked
    /// No confident signal — leave the session's attention unchanged.
    case unknown
}

/// The classification of a session's tail: the `signal` plus a short, bounded
/// human-readable `reason` line describing *what* the agent is asking or *what*
/// failed (nil when `.unknown`, or when there's no informative line). U10 surfaces
/// this reason in the live detail banner and the boss-facing `SessionSnapshot`
/// so the operator and the boss agree on *why* a session is waiting.
public struct AttentionClassification: Equatable, Sendable {
    public var signal: AttentionSignal
    public var reason: String?

    public init(signal: AttentionSignal, reason: String? = nil) {
        self.signal = signal
        self.reason = reason
    }
}

/// Classifies a session's recent terminal output to decide whether it's
/// *waiting on the human*. This is the signal that turns the workbench from "a
/// launcher with panes" into an attention router: when a coding agent stops to
/// ask "may I run this command?" the session should light up on its own.
///
/// The detector is deliberately conservative — it only fires on confident,
/// well-known prompt shapes, because a false "waiting" is worse than a missed
/// one (it would cry wolf in the sidebar, menubar, and notifications). It is a
/// pure function of the tail text so it can be exhaustively unit-tested and run
/// off the main actor against the already-written transcript.
public enum AttentionSignalDetector {
    /// Upper bound on the length of a derived `reason` line. A pathological
    /// prompt line is clipped (with a trailing ellipsis) so the banner and the
    /// boss snapshot never carry an unbounded blob.
    public static let maxReasonLength = 140

    /// Inspect the tail of a session's output. `tail` should be the last few KB
    /// of decoded terminal output (e.g. from the transcript). Returns
    /// `.waitingOnHuman` only on a confident interactive-prompt match.
    public static func classify(tail: String) -> AttentionSignal {
        classifyWithReason(tail: tail).signal
    }

    /// Like `classify`, but also returns a short "why" line: the question/prompt
    /// the agent is waiting on, or the terminal-error line it's stuck on. The
    /// `reason` is stripped of ANSI, trimmed, and bounded to `maxReasonLength`.
    /// `.unknown` carries a nil reason.
    public static func classifyWithReason(tail: String) -> AttentionClassification {
        // Strip ANSI escape sequences and carriage returns so prompt text is
        // matched on the rendered characters, not the control bytes.
        let cleaned = stripControlSequences(tail)
        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return AttentionClassification(signal: .unknown) }

        // Only the last handful of lines matter for an interactive prompt; a
        // match buried far up the scrollback is stale.
        let recent = Array(lines.suffix(12))
        let recentLower = recent.map { $0.lowercased() }

        // 1. A numbered selection menu with an arrow cursor, e.g. Claude Code /
        //    Codex approval menus: "❯ 1. Yes" / "> 2. No, suggest changes".
        if let menuIndex = recent.firstIndex(where: { isArrowSelectedOption($0) }) {
            return waiting(reason: promptReason(in: recent, matchedAt: menuIndex))
        }

        // 2. Explicit confirmation / yes-no prompts anywhere in the tail end.
        if let promptIndex = recentLower.firstIndex(where: { containsConfirmationPrompt($0) }) {
            return waiting(reason: promptReason(in: recent, matchedAt: promptIndex))
        }

        // 3. The very last line looks like an interactive read prompt that the
        //    process is blocked on (a question or "press enter"), as opposed to
        //    a plain shell prompt (which is merely idle, not waiting-on-human).
        if let last = recentLower.last, isTrailingReadPrompt(last) {
            return waiting(reason: promptReason(in: recent, matchedAt: recent.count - 1))
        }

        // 4. The session ended on a terminal error and isn't at a prompt — it's
        //    stuck. Checked last so a prompt (even after an error) wins:
        //    "error... (y/N)" is waiting, not blocked. Only the final line is
        //    inspected, so an error mid-progress that the agent kept working
        //    past never trips it.
        if let last = recentLower.last, isTerminalError(last) {
            return AttentionClassification(signal: .blocked, reason: boundedReason(recent[recent.count - 1]))
        }

        return AttentionClassification(signal: .unknown)
    }

    // MARK: - Reason derivation

    private static func waiting(reason: String?) -> AttentionClassification {
        AttentionClassification(signal: .waitingOnHuman, reason: reason)
    }

    /// The best "why" line for a waiting prompt matched at `matchedAt`. An arrow
    /// menu's own line ("❯ 1. Yes") is uninformative, so prefer the nearest
    /// question line at or above the match; otherwise fall back to the matched
    /// line itself.
    static func promptReason(in lines: [String], matchedAt index: Int) -> String? {
        for i in stride(from: index, through: 0, by: -1) where looksLikeQuestion(lines[i]) {
            return boundedReason(lines[i])
        }
        return boundedReason(lines[index])
    }

    /// A line that reads like a direct question / prompt to the operator: ends
    /// with "?" or a recognized confirmation needle. Used to pick the human-
    /// meaningful line out of a multi-line prompt block.
    static func looksLikeQuestion(_ line: String) -> Bool {
        let lower = line.lowercased()
        if line.hasSuffix("?") { return true }
        return containsConfirmationPrompt(lower)
    }

    /// Trim a candidate reason line and clip it to `maxReasonLength` with a
    /// trailing ellipsis. Returns nil for an empty line.
    static func boundedReason(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxReasonLength { return trimmed }
        let clipped = trimmed.prefix(maxReasonLength - 1)
        return String(clipped) + "…"
    }

    // MARK: - Patterns

    /// "❯ 1. Yes", "> 2. No", "▶ 3. …" — an arrow cursor pointing at a numbered
    /// option. Requires the digit so a bare shell prompt (`❯ `) never matches.
    static func isArrowSelectedOption(_ line: String) -> Bool {
        let arrows: Set<Character> = ["❯", "›", "▶", "→", "»"]
        var chars = Array(line)
        guard let first = chars.first, arrows.contains(first) else { return false }
        chars.removeFirst()
        // Drop spaces after the arrow.
        while chars.first == " " { chars.removeFirst() }
        guard let digit = chars.first, digit.isNumber else { return false }
        chars.removeFirst()
        // Expect "." or ")" or " " right after the number, e.g. "1." / "1)".
        guard let sep = chars.first else { return false }
        return sep == "." || sep == ")" || sep == " "
    }

    /// y/n-style confirmations and common approval phrasings (already lowercased).
    static func containsConfirmationPrompt(_ lower: String) -> Bool {
        let needles = [
            "(y/n)", "(y/n/", "[y/n]", "(yes/no)", "[yes/no]",
            "y/n?", " (y)es", "do you want to proceed", "do you want to make this",
            "allow this command", "allow command", "approve this",
            "press enter to continue", "press any key to continue",
            "overwrite?", "are you sure", "continue? "
        ]
        for needle in needles where lower.contains(needle) {
            return true
        }
        // "[Y/n]" / "[y/N]" style with either case as the default.
        if lower.contains("[y/n]") || lower.contains("[y/n/a]") {
            return true
        }
        return false
    }

    /// A trailing line that is itself an interactive read prompt. Conservative:
    /// must end with "? " or be a recognized credential/continue prompt, and is
    /// NOT a bare shell prompt.
    static func isTrailingReadPrompt(_ lower: String) -> Bool {
        if lower.hasSuffix("password:") || lower.hasSuffix("passphrase:")
            || lower.contains("enter passphrase") {
            return true
        }
        // A question ending in "?" with a trailing prompt indicator.
        if (lower.hasSuffix("? ") || lower.hasSuffix("?")) && lower.count > 8 {
            // Avoid matching log lines that merely contain a "?" — require it to
            // read like a direct question to the user.
            let starts = ["do ", "would ", "should ", "are ", "is ", "shall ", "continue", "proceed", "ready"]
            return starts.contains { lower.hasPrefix($0) }
        }
        return false
    }

    /// A final line that reads like a terminal/unrecoverable failure — high
    /// confidence only, because it's checked as the *last* thing the session
    /// printed (an error mid-progress that the agent worked past never reaches
    /// here). Bare "error" is deliberately excluded as too noisy.
    static func isTerminalError(_ lower: String) -> Bool {
        let needles = [
            "command not found",
            "permission denied",
            "no such file or directory",
            "fatal:",
            "fatal error",
            "panic:",
            "segmentation fault",
            "core dumped",
            "cannot find module",
            "module not found",
            "could not resolve host",
            "connection refused",
            "build failed",
            "compilation failed",
            "npm err!",
            "killed: 9",
            "traceback (most recent call last)"
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Remove ANSI CSI/OSC escape sequences and carriage returns so matching
    /// works on visible text. Keeps it cheap — single pass, no regex engine.
    static func stripControlSequences(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.unicodeScalars.count)
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        while let scalar = pending {
            pending = iterator.next()
            if scalar == "\u{1B}" { // ESC
                // CSI: ESC [ ... letter ;  OSC: ESC ] ... BEL/ST
                if pending == "[" {
                    pending = iterator.next()
                    while let s = pending {
                        pending = iterator.next()
                        if (s.value >= 0x40 && s.value <= 0x7E) { break } // final byte
                    }
                } else if pending == "]" {
                    pending = iterator.next()
                    while let s = pending {
                        pending = iterator.next()
                        if s == "\u{07}" { break } // BEL terminates OSC
                        if s == "\u{1B}" { pending = iterator.next(); break } // ST
                    }
                } else {
                    // Lone ESC or two-char sequence: skip the next scalar.
                    pending = iterator.next()
                }
                continue
            }
            if scalar == "\r" { continue }
            result.append(scalar)
        }
        return String(result)
    }
}
