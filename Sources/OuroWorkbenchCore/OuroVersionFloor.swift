import Foundation

/// Whether the running `ouro` supports `mcp-serve --workbench-mcp` — the flag that
/// injects the `workbench_*` tools, supported only on `alpha.660+`.
public enum OuroWorkbenchMCPSupport: String, Equatable, Sendable {
    /// ouro is `alpha.660` or newer — `--workbench-mcp` is honored.
    case supported
    /// ouro is recognized but below the floor — it silently strips the tools.
    case tooOld
    /// The version string couldn't be parsed — DON'T block on it. The `tools/list`
    /// probe (Seam A) is the authority; this verdict only sharpens copy.
    case unknown
}

/// The ouro version floor for `--workbench-mcp` (#F9 Seam B). A defense-in-depth /
/// operator-messaging seam: the `tools/list` injection probe (Seam A) is the real gate,
/// but knowing the version lets the app turn an `absent` verdict into an actionable
/// "your ouro is too old; update to alpha.660+" message — and, when it has the version,
/// fast-path that message before even spawning a turn.
///
/// Parsing is deliberately narrow: find an `alpha.<N>` token and compare `<N>` to the
/// floor. Anything unparseable is `.unknown`, which NEVER blocks — a parser bug must
/// not lock out a perfectly good ouro.
public enum OuroVersionFloor {
    /// The first `ouro` alpha that honors `mcp-serve --workbench-mcp`.
    public static let minimumAlpha = 660

    /// Parse an `ouro --version` string → support verdict. Tolerant of leading text,
    /// `v` prefixes, and trailing build metadata (`ouro 1.2.3-alpha.660`, `alpha.661`,
    /// `alpha.660+build.5`). Locates the `alpha.<N>` token, reads the leading digits of
    /// `<N>`, and compares to `minimumAlpha`. No token, or a token with no numeric tail,
    /// ⇒ `.unknown`.
    public static func support(forVersionString raw: String) -> OuroWorkbenchMCPSupport {
        let marker = "alpha."
        guard let markerRange = raw.range(of: marker) else {
            return .unknown
        }
        // Read consecutive digits immediately following `alpha.` — tolerates a trailing
        // `+build`, `)`, whitespace, or any other non-digit suffix.
        var digits = ""
        for char in raw[markerRange.upperBound...] {
            guard char.isNumber else { break }
            digits.append(char)
        }
        guard let number = Int(digits) else {
            return .unknown
        }
        return number >= minimumAlpha ? .supported : .tooOld
    }
}
