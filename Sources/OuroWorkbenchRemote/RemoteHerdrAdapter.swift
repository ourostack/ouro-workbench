import Foundation
import OuroWorkbenchCore

func remoteRunGuardian(_ context: RemoteHelperContext) throws {
    let configPath = try context.path("config", environment: "OURO_REMOTE_CONFIG")
    let rootURL = URL(fileURLWithPath: try context.path("root", environment: "OURO_HERDR_ROOT"), isDirectory: true)
    guard rootURL.lastPathComponent == "herdr" else { throw RemoteControlError.guardian("guardian root must be the exact Herdr config directory") }
    let ledgerURL = URL(fileURLWithPath: try context.path("ledger", environment: "OURO_LEDGER_ROOT"), isDirectory: true)
    let sessionMapURL = URL(fileURLWithPath: try context.path("session-map", environment: "OURO_SESSION_MAP"))
    let helperPath = context.invocation.options["helper"] ?? context.helperPath
    guard helperPath.hasPrefix("/"), URL(fileURLWithPath: helperPath).standardizedFileURL.path == helperPath else {
        throw RemoteControlError.guardian("absolute helper path is required")
    }
    let registry = try remoteLoadRegistry(configPath: configPath)
    let herdrPaths = Set(registry.profiles.map(\.herdrExecutable))
    guard herdrPaths.count == 1, let herdrExecutable = herdrPaths.first else {
        throw RemoteControlError.guardian("all profiles must use one exact Herdr executable")
    }
    let ledger = try RemoteResumeLedgerFactory.make(
        ledgerRootURL: ledgerURL,
        herdrRootURL: rootURL,
        registry: registry,
        inheritedEnvironment: context.environment
    )
    let adapter = RemoteHerdrAdapter(
        rootURL: rootURL,
        registry: registry,
        ledger: ledger,
        sessionMapURL: sessionMapURL,
        herdrExecutable: herdrExecutable,
        configPath: configPath,
        helperPath: helperPath,
        shimDirectory: try context.path("shim-directory", environment: "OURO_SHIM_DIRECTORY"),
        zdotdir: try context.path("zdotdir", environment: "OURO_ZDOTDIR"),
        inheritedEnvironment: context.environment
    )
    let guardian = RemoteGuardian(
        rootURL: rootURL,
        helperPath: helperPath,
        ledger: ledger,
        probe: adapter.probe,
        listManagedSessions: adapter.listManagedSessions,
        listManagedProcessSessions: adapter.listManagedProcessSessions,
        boot: adapter.boot,
        resume: adapter.resume,
        stop: adapter.stop,
        reactivate: adapter.reactivate,
        nativeSessionOwnerExists: ledger.lockExists,
        makeGenerationName: {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            return "ouro-\(stamp)-\(UUID().uuidString.lowercased().prefix(8))"
        }
    )
    let result = try guardian.tick()
    switch result {
    case let .alreadyRunning(generation): try remoteWriteJSON(["generation": generation, "result": "already_running"])
    case let .promoted(generation): try remoteWriteJSON(["generation": generation, "result": "promoted"])
    }
}
