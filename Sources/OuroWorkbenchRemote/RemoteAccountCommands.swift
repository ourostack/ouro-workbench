import Darwin
import Foundation
import OuroWorkbenchCore

func remoteRunManagedCommand(_ context: RemoteHelperContext) throws -> Never {
    guard context.environment["HERDR_ENV"] == "1" else {
        throw RemoteControlError.resume("managed Copilot launch is unavailable outside Herdr")
    }
    let configPath = try context.path("config", environment: "OURO_REMOTE_CONFIG")
    let ledgerPath = try context.path("ledger", environment: "OURO_LEDGER_ROOT")
    let registry = try remoteLoadRegistry(configPath: configPath)
    let runner = RemoteSystemRunner()
    let shimDirectory = try remoteShimDirectory(context)
    let brokerWorkingDirectory: String
    if context.invocation.command == .launch {
        let profileID = try context.value("profile", environment: "OURO_PROFILE_ID")
        brokerWorkingDirectory = try registry.profile(id: profileID).deskRoot
    } else {
        brokerWorkingDirectory = context.workingDirectory
    }
    let broker = RemoteAccountBroker(
        registry: registry,
        environment: context.environment,
        workingDirectory: brokerWorkingDirectory,
        shimDirectory: shimDirectory,
        profileConfigPath: configPath,
        run: runner.run
    )

    let request: RemoteProcessRequest
    let nativeSessionID: String?
    switch context.invocation.command {
    case .launch:
        let profileID = try context.value("profile", environment: "OURO_PROFILE_ID")
        let generation = try context.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION")
        let paneID = try context.herdrValue("pane", ouroKey: "OURO_PANE_ID", herdrKey: "HERDR_PANE_ID")
        request = try broker.launch(profileID: profileID, arguments: context.invocation.passthrough, generation: generation, paneID: paneID)
        nativeSessionID = nil
    case .dispatch:
        let sessionMapPath = try context.path("session-map", environment: "OURO_SESSION_MAP")
        request = try broker.dispatch(arguments: context.invocation.passthrough, sessionMapURL: URL(fileURLWithPath: sessionMapPath))
        nativeSessionID = try RemoteAccountBroker.resumeUUID(in: context.invocation.passthrough)
    case .resume:
        let sessionMapPath = try context.path("session-map", environment: "OURO_SESSION_MAP")
        let rawUUID = try context.value("uuid")
        guard let uuid = UUID(uuidString: rawUUID) else { throw RemoteControlError.resume("exact resume UUID is required") }
        nativeSessionID = uuid.uuidString.lowercased()
        request = try broker.resume(
            nativeSessionID: nativeSessionID!,
            profileID: try context.value("profile", environment: "OURO_PROFILE_ID"),
            generation: try context.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION"),
            paneID: try context.herdrValue("pane", ouroKey: "OURO_PANE_ID", herdrKey: "HERDR_PANE_ID"),
            sessionMapURL: URL(fileURLWithPath: sessionMapPath)
        )
    default:
        throw RemoteControlError.invalidConfiguration("managed command routing is invalid")
    }

    guard let profileID = request.environment["OURO_PROFILE_ID"],
          let generation = request.environment["OURO_GENERATION"],
          let paneID = request.environment["OURO_PANE_ID"]
    else {
        throw RemoteControlError.resume("managed child context is incomplete")
    }
    let ledger = try RemoteResumeLedgerFactory.make(
        ledgerRootURL: URL(fileURLWithPath: ledgerPath, isDirectory: true),
        herdrRootURL: RemoteHerdrRootLocator.locate(environment: context.environment),
        registry: registry,
        inheritedEnvironment: context.environment
    )
    let supervisor = RemoteChildSupervisor(ledger: ledger, spawn: remoteSpawnSupervised)
    let status = try supervisor.run(
        request: request,
        attemptID: "run-\(UUID().uuidString.lowercased())",
        nativeSessionID: nativeSessionID,
        profileID: profileID,
        generation: generation,
        paneID: paneID,
        ownerPID: getpid()
    )
    remoteExitStatus(status)
}

func remoteRunShim(named name: String, arguments: [String], environment: [String: String], workingDirectory: String, helperPath: String) throws -> Never {
    guard name == "gh" || name == "git" else { throw RemoteControlError.invalidConfiguration("unknown managed shim") }
    let synthetic = RemoteHelperInvocation(command: .help, options: [:], flags: [], passthrough: [])
    let context = RemoteHelperContext(invocation: synthetic, environment: environment, workingDirectory: workingDirectory, helperPath: helperPath)
    let configPath = try context.path("config", environment: "OURO_REMOTE_CONFIG")
    let profileID = try context.value("profile", environment: "OURO_PROFILE_ID")
    let registry = try remoteLoadRegistry(configPath: configPath)
    let broker = RemoteAccountBroker(
        registry: registry,
        environment: environment,
        workingDirectory: workingDirectory,
        shimDirectory: URL(fileURLWithPath: helperPath).deletingLastPathComponent().path,
        profileConfigPath: configPath,
        run: RemoteSystemRunner().run
    )
    let remoteURLs = try broker.repositoryRemoteURLs(profileID: profileID)
    let request = try name == "gh"
        ? broker.gh(profileID: profileID, arguments: arguments, remoteURLs: remoteURLs)
        : broker.git(profileID: profileID, arguments: arguments, remoteURLs: remoteURLs)
    try remoteExec(request)
}

private func remoteShimDirectory(_ context: RemoteHelperContext) throws -> String {
    if let configured = context.invocation.options["shim-directory"] {
        guard configured.hasPrefix("/"), URL(fileURLWithPath: configured).standardizedFileURL.path == configured else {
            throw RemoteControlError.invalidConfiguration("absolute path required for '--shim-directory'")
        }
        return configured
    }
    if let configured = context.environment["OURO_SHIM_DIRECTORY"], !configured.isEmpty {
        guard configured.hasPrefix("/"), URL(fileURLWithPath: configured).standardizedFileURL.path == configured else {
            throw RemoteControlError.invalidConfiguration("absolute shim directory is required")
        }
        return configured
    }
    return URL(fileURLWithPath: context.helperPath).deletingLastPathComponent().appendingPathComponent("shims", isDirectory: true).path
}
