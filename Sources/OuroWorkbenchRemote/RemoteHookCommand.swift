import Foundation
import OuroWorkbenchCore

func remoteRunSessionMapHook(_ context: RemoteHelperContext) throws {
    guard context.environment["HERDR_ENV"] == "1" else {
        throw RemoteControlError.invalidHook("managed session hook is unavailable outside Herdr")
    }
    let configPath = try context.path("config", environment: "OURO_REMOTE_CONFIG")
    let sessionMapPath = try context.path("session-map", environment: "OURO_SESSION_MAP")
    let ledgerPath = try context.path("ledger", environment: "OURO_LEDGER_ROOT")
    let registry = try remoteLoadRegistry(configPath: configPath)
    let profileID = try context.value("profile", environment: "OURO_PROFILE_ID")
    let generation = try context.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION")
    let paneID = try context.herdrValue("pane", ouroKey: "OURO_PANE_ID", herdrKey: "HERDR_PANE_ID")
    let profile = try registry.profile(id: profileID)
    let hookData = try remoteReadHookInput(maximumBytes: RemoteSessionMapStore.maximumHookBytes)
    let officialHook = context.invocation.options["official-hook"] ?? profile.copilotHome + "/hooks/herdr-agent-state.sh"
    guard officialHook.hasPrefix("/"), URL(fileURLWithPath: officialHook).standardizedFileURL.path == officialHook else {
        throw RemoteControlError.invalidHook("official hook path is not absolute and normalized")
    }
    let ledger = try RemoteResumeLedgerFactory.make(
        ledgerRootURL: URL(fileURLWithPath: ledgerPath, isDirectory: true),
        herdrRootURL: RemoteHerdrRootLocator.locate(environment: context.environment),
        registry: registry,
        inheritedEnvironment: context.environment
    )
    let store = RemoteSessionMapStore(rootURL: URL(fileURLWithPath: sessionMapPath).deletingLastPathComponent())
    let report = store.record(
        hookData: hookData,
        profileID: profileID,
        paneID: paneID,
        generation: generation,
        registry: registry,
        ledger: ledger,
        officialHook: { data in
            do {
                guard FileManager.default.isExecutableFile(atPath: officialHook) else {
                    throw RemoteControlError.dependency("official Herdr hook is unavailable")
                }
                let result = try RemoteSystemRunner(timeout: 10, maximumOutputBytes: 65_536).run(RemoteProcessRequest(
                    executable: officialHook,
                    environment: remoteOfficialHookEnvironment(context.environment, copilotHome: profile.copilotHome),
                    workingDirectory: context.workingDirectory,
                    standardInput: data
                ))
                guard result.exitCode == 0 else { throw RemoteControlError.dependency("official Herdr hook failed") }
                return nil
            } catch {
                return error
            }
        }
    )
    if report.mappingError != nil || report.officialHookError != nil {
        let mapping = report.mappingError == nil ? "ok" : "failed"
        let official = report.officialHookError == nil ? "ok" : "failed"
        throw RemoteControlError.invalidHook("ownership mapping \(mapping); official Herdr hook \(official)")
    }
}

private func remoteReadHookInput(maximumBytes: Int) throws -> Data {
    var data = Data()
    while true {
        let chunk: Data
        do { chunk = try FileHandle.standardInput.read(upToCount: min(16_384, maximumBytes + 1 - data.count)) ?? Data() }
        catch { throw RemoteControlError.invalidHook("hook input could not be read") }
        if chunk.isEmpty { break }
        data.append(chunk)
        guard data.count <= maximumBytes else { throw RemoteControlError.invalidHook("hook input is too large") }
    }
    return data
}

private func remoteOfficialHookEnvironment(_ environment: [String: String], copilotHome: String) -> [String: String] {
    let allowed = Set([
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "TERM", "LANG",
        "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "HERDR_ENV",
        "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID",
        "HERDR_SESSION", "HERDR_BIN_PATH"
    ])
    var clean = environment.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
    clean["COPILOT_HOME"] = copilotHome
    return clean
}
