import Foundation

/// A deliberately tiny, dependency-free reader for FLAT `key: value` YAML — the
/// only shape Copilot's `~/.copilot/session-state/<id>/workspace.yaml` uses
/// (grounded against real files: every line is a top-level `key: value`, no
/// nesting, no lists, no block scalars). We do NOT pull in a full YAML SPM
/// dependency for this: the surface is one line format, and a general parser
/// would be a far larger trust+supply-chain footprint than the data warrants.
///
/// Parsing posture mirrors `SessionActivity.parse` — tolerant and lossy-safe:
/// malformed/blank/comment lines are skipped, never thrown on, so one bad line
/// can't sink a whole file. Duplicate keys take the last value (matches how a
/// YAML loader resolves a repeated mapping key).
public enum FlatYAMLReader {
    /// Parse flat `key: value` lines into a dictionary. Behavior:
    /// - Splits on any newline (handles `\n` and `\r\n`; a trailing `\r` is
    ///   trimmed as whitespace).
    /// - A line with no `:` is skipped.
    /// - The key is everything before the FIRST `:`, trimmed; an empty key is
    ///   skipped (e.g. `: value`).
    /// - The value is everything after that first `:`, trimmed; a value may
    ///   itself contain `:` (e.g. ISO8601 timestamps).
    /// - A value wrapped in a matching pair of `"` or `'` quotes has exactly
    ///   that surrounding pair stripped; an unmatched or single-character quote
    ///   is left verbatim.
    /// - Comment-only lines (first non-space char is `#`) and blank lines are
    ///   skipped.
    /// - Duplicate keys: last occurrence wins.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = unquote(rawValue)
        }
        return result
    }

    /// Strip a single surrounding pair of matching `"` or `'` quotes; otherwise
    /// return the value untouched. Requires at least two characters so a lone
    /// quote (`"`) is never mistaken for an empty quoted string.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
