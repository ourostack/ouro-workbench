import Foundation

public enum ShellArgumentEscaper: Sendable {
    public static func quote(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        if value.unicodeScalars.allSatisfy({ safeUnquotedScalars.contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static func commandLine(_ tokens: [String]) -> String {
        tokens.map(quote).joined(separator: " ")
    }

    private static let safeUnquotedScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_./:=@%+"))
}
