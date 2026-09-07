import Foundation

public struct RemoteHelperInvocation: Equatable, Sendable {
    public enum Command: String, CaseIterable, Equatable, Sendable {
        case help
        case version
        case launch
        case dispatch
        case resume
        case reconcile
        case snapshot
        case acknowledgeEmpty = "acknowledge-empty"
        case sessionMapHook = "session-map-hook"
        case guardian
        case observe
        case doctor
        case package
        case install
        case rollback
        case shellBootstrap = "shell-bootstrap"
        case wrapperHandshake = "wrapper-handshake"
    }

    public let command: Command
    public let options: [String: String]
    public let flags: Set<String>
    public let passthrough: [String]

    public init(command: Command, options: [String: String], flags: Set<String>, passthrough: [String]) {
        self.command = command
        self.options = options
        self.flags = flags
        self.passthrough = passthrough
    }

    public static func parse(_ arguments: [String]) throws -> RemoteHelperInvocation {
        guard let first = arguments.first else {
            return RemoteHelperInvocation(command: .help, options: [:], flags: [], passthrough: [])
        }
        if arguments == ["--help"] || arguments == ["-h"] {
            return RemoteHelperInvocation(command: .help, options: [:], flags: [], passthrough: [])
        }
        if arguments == ["--version"] {
            return RemoteHelperInvocation(command: .version, options: [:], flags: [], passthrough: [])
        }
        guard let command = Command(rawValue: first) else {
            throw RemoteControlError.invalidConfiguration("unknown command '\(first)'")
        }

        var options: [String: String] = [:]
        var flags = Set<String>()
        var passthrough: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                passthrough = Array(arguments.dropFirst(index + 1))
                break
            }
            guard argument.hasPrefix("--"), argument.count > 2 else {
                throw RemoteControlError.invalidConfiguration("unexpected argument '\(argument)'")
            }

            let body = String(argument.dropFirst(2))
            if let equals = body.firstIndex(of: "=") {
                let key = String(body[..<equals])
                let value = String(body[body.index(after: equals)...])
                try validateKey(key)
                try insertOption(key: key, value: value, options: &options, flags: flags)
                index += 1
                continue
            }

            try validateKey(body)
            if Self.booleanFlags.contains(body) {
                guard options[body] == nil, flags.insert(body).inserted else {
                    throw RemoteControlError.invalidConfiguration("duplicate option '--\(body)'")
                }
                index += 1
                continue
            }
            guard index + 1 < arguments.count, arguments[index + 1] != "--", !arguments[index + 1].hasPrefix("--") else {
                throw RemoteControlError.invalidConfiguration("missing value for '--\(body)'")
            }
            try insertOption(key: body, value: arguments[index + 1], options: &options, flags: flags)
            index += 2
        }
        try validateShape(command: command, options: options, flags: flags, passthrough: passthrough)
        return RemoteHelperInvocation(command: command, options: options, flags: flags, passthrough: passthrough)
    }

    public func requiredValue(_ name: String) throws -> String {
        guard let value = options[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteControlError.invalidConfiguration("required option '--\(name)' is empty or missing")
        }
        return value
    }

    public func requiredPath(_ name: String) throws -> String {
        let value = try requiredValue(name)
        guard value.hasPrefix("/"), URL(fileURLWithPath: value).standardizedFileURL.path == value else {
            throw RemoteControlError.invalidConfiguration("absolute path required for '--\(name)'")
        }
        return value
    }

    public func hasFlag(_ name: String) -> Bool {
        flags.contains(name)
    }

    private static let booleanFlags: Set<String> = ["fresh-sessions", "json", "native-refs-remain"]

    private static let allowedOptions: [Command: Set<String>] = [
        .help: [],
        .version: [],
        .launch: ["config", "ledger", "profile", "generation", "pane", "shim-directory"],
        .dispatch: ["config", "ledger", "session-map", "shim-directory"],
        .resume: ["config", "ledger", "session-map", "uuid", "profile", "generation", "pane", "shim-directory"],
        .reconcile: ["config", "root", "ledger", "attempt"],
        .snapshot: ["config", "root", "ledger", "session-map", "shim-directory", "zdotdir"],
        .acknowledgeEmpty: ["config", "root", "ledger", "session-map", "shim-directory", "zdotdir", "generation"],
        .sessionMapHook: ["config", "ledger", "session-map", "profile", "generation", "pane", "official-hook"],
        .guardian: ["config", "root", "ledger", "session-map", "helper", "shim-directory", "zdotdir"],
        .observe: ["config", "root", "ledger", "session-map", "relay-state", "observer-root"],
        .doctor: ["config", "root", "ledger", "session-map", "relay-state"],
        .package: ["output", "revision", "expected-helper-sha256"],
        .install: ["runtime-root", "artifact-root", "revision", "expected-helper-sha256"],
        .rollback: ["runtime-root", "revision"],
        .shellBootstrap: ["output", "zsh", "real-zdotdir", "helper", "config", "session-map"],
        .wrapperHandshake: ["helper", "config", "session-map", "zsh", "zdotdir", "generation", "pane", "shell-pid", "function-body"]
    ]

    private static let allowedFlags: [Command: Set<String>] = [
        .launch: ["json"],
        .guardian: ["fresh-sessions"],
        .doctor: ["json"]
    ]

    private static func validateKey(_ key: String) throws {
        guard key.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw RemoteControlError.invalidConfiguration("unsafe option name")
        }
    }

    private static func insertOption(key: String, value: String, options: inout [String: String], flags: Set<String>) throws {
        guard options[key] == nil, !flags.contains(key) else {
            throw RemoteControlError.invalidConfiguration("duplicate option '--\(key)'")
        }
        options[key] = value
    }

    private static func validateShape(command: Command, options: [String: String], flags: Set<String>, passthrough: [String]) throws {
        let allowedOptions = allowedOptions[command]!
        if let unknown = Set(options.keys).subtracting(allowedOptions).sorted().first {
            throw RemoteControlError.invalidConfiguration("unknown option '--\(unknown)' for \(command.rawValue)")
        }
        let allowedFlags = allowedFlags[command] ?? []
        if let unknown = flags.subtracting(allowedFlags).sorted().first {
            throw RemoteControlError.invalidConfiguration("unknown flag '--\(unknown)' for \(command.rawValue)")
        }
        guard passthrough.isEmpty || command == .launch || command == .dispatch else {
            throw RemoteControlError.invalidConfiguration("unexpected passthrough arguments for \(command.rawValue)")
        }
    }
}
