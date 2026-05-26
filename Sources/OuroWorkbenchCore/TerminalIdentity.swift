import Foundation

public struct TerminalCommandTokens: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum TerminalCommandParser {
    public static func parse(_ command: String) -> TerminalCommandTokens? {
        let tokens = tokenize(command)
        guard let executable = tokens.first else {
            return nil
        }
        return TerminalCommandTokens(executable: executable, arguments: Array(tokens.dropFirst()))
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var tokenStarted = false

        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                tokenStarted = true
                continue
            }
            if character == "\\" {
                escaped = true
                tokenStarted = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                tokenStarted = true
                continue
            }
            if character.isWhitespace {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
                continue
            }
            current.append(character)
            tokenStarted = true
        }
        if escaped {
            current.append("\\")
            tokenStarted = true
        }
        if tokenStarted {
            tokens.append(current)
        }
        return tokens
    }
}

public enum TerminalAgentDetector {
    public static func detect(entry: ProcessEntry) -> TerminalAgentKind? {
        if let agentKind = entry.agentKind {
            return agentKind
        }
        let tokens = canonicalTokens(executable: entry.executable, arguments: entry.arguments)
        return detect(executable: tokens.executable, arguments: tokens.arguments)
    }

    public static func detect(executable: String, arguments: [String]) -> TerminalAgentKind? {
        let tokens = canonicalTokens(executable: executable, arguments: arguments)
        let basename = URL(fileURLWithPath: tokens.executable).lastPathComponent.lowercased()
        switch basename {
        case "claude":
            return .claudeCode
        case "codex":
            return .openAICodex
        case "gh":
            return tokens.arguments.first?.lowercased() == "copilot" ? .githubCopilotCLI : nil
        default:
            return nil
        }
    }

    public static func canonicalTokens(entry: ProcessEntry) -> TerminalCommandTokens {
        canonicalTokens(executable: entry.executable, arguments: entry.arguments)
    }

    public static func canonicalTokens(executable: String, arguments: [String]) -> TerminalCommandTokens {
        if isEnvironmentAssignment(executable), let nestedExecutable = arguments.first {
            return canonicalTokens(executable: nestedExecutable, arguments: Array(arguments.dropFirst()))
        }
        let basename = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        switch basename {
        case "zsh", "bash", "sh":
            guard
                arguments.count >= 2,
                ["-c", "-lc"].contains(arguments[0]),
                let parsed = TerminalCommandParser.parse(arguments[1])
            else {
                return TerminalCommandTokens(executable: executable, arguments: arguments)
            }
            return canonicalTokens(executable: parsed.executable, arguments: parsed.arguments)
        case "env":
            guard let unwrapped = unwrapEnv(arguments: arguments) else {
                return TerminalCommandTokens(executable: executable, arguments: arguments)
            }
            return canonicalTokens(executable: unwrapped.executable, arguments: unwrapped.arguments)
        case "exec", "command":
            guard let nestedExecutable = arguments.first else {
                return TerminalCommandTokens(executable: executable, arguments: arguments)
            }
            return canonicalTokens(executable: nestedExecutable, arguments: Array(arguments.dropFirst()))
        default:
            return TerminalCommandTokens(executable: executable, arguments: arguments)
        }
    }

    public static func displayName(for kind: TerminalAgentKind?) -> String? {
        guard let kind else {
            return nil
        }
        return TerminalAgentPresets.preset(for: kind)?.displayName ?? kind.rawValue
    }

    private static func unwrapEnv(arguments: [String]) -> TerminalCommandTokens? {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if isEnvironmentAssignment(token) {
                index += 1
                continue
            }
            if token == "-u" || token == "--unset" {
                index += min(2, arguments.count - index)
                continue
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            return TerminalCommandTokens(
                executable: token,
                arguments: Array(arguments.dropFirst(index + 1))
            )
        }
        return nil
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator > token.startIndex else {
            return false
        }
        let name = token[..<separator]
        guard let first = name.first, first == "_" || first.isLetter else {
            return false
        }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
