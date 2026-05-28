import Foundation

/// What a session's recent output suggests about whether it needs the human.
public enum AttentionSignal: Equatable, Sendable {
    /// The session appears to be sitting at a prompt that needs a human
    /// decision (approval, y/n, a selection menu, "press enter").
    case waitingOnHuman
    /// No confident signal — leave the session's attention unchanged.
    case unknown
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
    /// Inspect the tail of a session's output. `tail` should be the last few KB
    /// of decoded terminal output (e.g. from the transcript). Returns
    /// `.waitingOnHuman` only on a confident interactive-prompt match.
    public static func classify(tail: String) -> AttentionSignal {
        // Strip ANSI escape sequences and carriage returns so prompt text is
        // matched on the rendered characters, not the control bytes.
        let cleaned = stripControlSequences(tail)
        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .unknown }

        // Only the last handful of lines matter for an interactive prompt; a
        // match buried far up the scrollback is stale.
        let recent = lines.suffix(12)
        let recentLower = recent.map { $0.lowercased() }

        // 1. A numbered selection menu with an arrow cursor, e.g. Claude Code /
        //    Codex approval menus: "❯ 1. Yes" / "> 2. No, suggest changes".
        for line in recent where isArrowSelectedOption(line) {
            return .waitingOnHuman
        }

        // 2. Explicit confirmation / yes-no prompts anywhere in the tail end.
        for line in recentLower where containsConfirmationPrompt(line) {
            return .waitingOnHuman
        }

        // 3. The very last line looks like an interactive read prompt that the
        //    process is blocked on (a question or "press enter"), as opposed to
        //    a plain shell prompt (which is merely idle, not waiting-on-human).
        if let last = recentLower.last, isTrailingReadPrompt(last) {
            return .waitingOnHuman
        }

        return .unknown
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
