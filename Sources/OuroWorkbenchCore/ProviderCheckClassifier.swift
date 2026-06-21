import Foundation

/// The classified outcome of a single `ouro check --agent <name> --lane <lane>` run, derived
/// from the command's OUTPUT — never its exit code.
public enum ProviderConnectionVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    case working, vaultLocked, unauthorized, unreachable, indeterminate
}

/// Classifies a Connect health-check (`ouro check`) result into a `ProviderConnectionVerdict`.
///
/// LOAD-BEARING SAFETY PROPERTY: `ouro check` exits 0 in EVERY state — working, vault-locked,
/// 401-unauthorized, network-unreachable. So the verdict is derived ENTIRELY from the output,
/// and only the exact status token `ready` yields `.working`. Any drift or ambiguity — an
/// `unknown (…)` with an unrecognized reason, a `failed (…)` with a 5xx/429, an unparseable
/// status, a missing verdict line, or a shell/PATH error — yields `.indeterminate`. The
/// classifier NEVER false-greens: a non-ready lane is never reported as working. `exitCode` is
/// accepted for parity with the caller's API but is deliberately NOT used to decide `.working`.
public struct ProviderCheckClassifier: Sendable {
    public init() {}

    /// Classify from the command output, NEVER the exit code.
    ///
    /// Operates on the ANSI-stripped `stdout + "\n" + stderr`. The verdict line is the LAST line
    /// containing both ` / ` and `: ` (the `<agent> <lane> <provider> / <model>: <status>`
    /// shape); the status segment is everything after that line's LAST `: `.
    public func classify(exitCode: Int32, stdout: String, stderr: String) -> ProviderConnectionVerdict {
        let combined = stripANSI(stdout + "\n" + stderr)

        guard let status = lastVerdictStatus(in: combined) else {
            return .indeterminate
        }
        let lowered = status.lowercased()

        // Order: ready → unknown ( → failed (. Only the exact token `ready` is working.
        if status == "ready" {
            return .working
        }
        if lowered.hasPrefix("unknown (") {
            return classifyUnknown(parenthetical: lowered)
        }
        if lowered.hasPrefix("failed (") {
            // Within failed(): test AUTH before NETWORK.
            if matchesUnauthorized(lowered) {
                return .unauthorized
            }
            if matchesUnreachable(lowered) {
                return .unreachable
            }
            return .indeterminate
        }
        return .indeterminate
    }

    // MARK: - Verdict-line extraction

    /// The status segment of the LAST verdict line, or nil if there is no verdict line. A verdict
    /// line is one containing both ` / ` and `: `; the status is the segment after its LAST `: `.
    private func lastVerdictStatus(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" / "), let colonRange = trimmed.range(of: ": ", options: .backwards) else {
                continue
            }
            let status = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return status
        }
        return nil
    }

    // MARK: - unknown (…) classification

    private func classifyUnknown(parenthetical lowered: String) -> ProviderConnectionVerdict {
        let vaultPhrases = [
            "locked",
            "vault",
            "no credentials",
            "not configured",
            "could not use the local bitwarden session",
        ]
        if vaultPhrases.contains(where: { lowered.contains($0) }) {
            return .vaultLocked
        }
        return .indeterminate
    }

    // MARK: - failed (…) classification helpers

    /// `lowered` always begins with `failed (` here (the caller gates on `hasPrefix("failed (")`),
    /// so the parenthetical body is everything after that prefix.
    private func matchesUnauthorized(_ lowered: String) -> Bool {
        if lowered.contains("http 401") || lowered.contains("http 403") {
            return true
        }
        if lowered.contains("unauthorized")
            || lowered.contains("not authorized")
            || lowered.contains("authentication token is expired") {
            return true
        }
        // HTTP-auth status code at a word boundary: `failed (401 …)` / `failed (403 …)`.
        return leadingHTTPAuthCodeMatches(lowered.dropFirst("failed (".count))
    }

    /// True when `parenthetical` begins with `401`/`403` at a word boundary (the char right after
    /// the code, if any, is not alphanumeric).
    private func leadingHTTPAuthCodeMatches(_ parenthetical: Substring) -> Bool {
        let codePrefix = parenthetical.prefix { $0.isNumber }
        guard codePrefix == "401" || codePrefix == "403" else { return false }
        let boundaryIndex = parenthetical.index(parenthetical.startIndex, offsetBy: codePrefix.count)
        guard boundaryIndex < parenthetical.endIndex else { return true }
        let next = parenthetical[boundaryIndex]
        return !(next.isNumber || next.isLetter)
    }

    private func matchesUnreachable(_ lowered: String) -> Bool {
        let networkPhrases = [
            "fetch failed",
            "socket hang up",
            "getaddrinfo",
            "enotfound",
            "econnrefused",
            "etimedout",
            "timed out",
            "timeout",
            "connection error",
            "network",
        ]
        return networkPhrases.contains(where: { lowered.contains($0) })
    }

    // MARK: - ANSI stripping

    /// Strips the ANSI CSI introducer the app folds out before classification. The app already
    /// removes the `ESC[` lead-in (`.replacingOccurrences(of: "\u{1B}[", with: "")`), which leaves
    /// bare escape codes like `2K`; this mirrors that so the classifier is robust whether it sees
    /// raw or pre-stripped output. The leading `2K` etc. is harmless: the verdict line still ends
    /// in `: <status>`, and the status segment is taken after the LAST `: `.
    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}[", with: "")
    }
}
