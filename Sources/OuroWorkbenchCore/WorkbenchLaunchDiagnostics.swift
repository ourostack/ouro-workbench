import Foundation

public struct WorkbenchLaunchDiagnostics: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case factoryResetForE2E
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case missingValue(String)

        public var errorDescription: String? {
            switch self {
            case let .missingValue(flag):
                return "\(flag) requires a value"
            }
        }
    }

    public var appSupportRoot: URL?
    public var autoLaunchResumableForE2E: Bool
    public var action: Action?
    public var passthroughArguments: [String]

    public init(
        appSupportRoot: URL? = nil,
        autoLaunchResumableForE2E: Bool = false,
        action: Action? = nil,
        passthroughArguments: [String] = []
    ) {
        self.appSupportRoot = appSupportRoot
        self.autoLaunchResumableForE2E = autoLaunchResumableForE2E
        self.action = action
        self.passthroughArguments = passthroughArguments
    }

    public static func parse(_ arguments: [String]) throws -> WorkbenchLaunchDiagnostics {
        var diagnostics = WorkbenchLaunchDiagnostics()
        var index = arguments.isEmpty ? 0 : 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--app-support-root":
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw ParseError.missingValue(argument)
                }
                diagnostics.appSupportRoot = URL(fileURLWithPath: arguments[nextIndex], isDirectory: true)
                index += 2
            case "--auto-launch-resumable-for-e2e":
                diagnostics.autoLaunchResumableForE2E = true
                index += 1
            case "--factory-reset-for-e2e":
                diagnostics.action = .factoryResetForE2E
                index += 1
            default:
                diagnostics.passthroughArguments.append(argument)
                index += 1
            }
        }
        return diagnostics
    }
}
