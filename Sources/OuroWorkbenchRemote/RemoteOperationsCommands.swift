import Foundation
import OuroWorkbenchCore

func remoteRunSnapshot(_ context: RemoteHelperContext, acknowledgeEmpty: Bool) throws {
    let configPath = try context.path("config", environment: "OURO_REMOTE_CONFIG")
    let rootURL = URL(fileURLWithPath: try context.path("root", environment: "OURO_HERDR_ROOT"), isDirectory: true)
    guard rootURL.lastPathComponent == "herdr" else { throw RemoteControlError.guardian("snapshot root must be the exact Herdr config directory") }
    let runtime = try remoteLoadSnapshotRuntime(rootURL: rootURL)
    let acknowledgedGeneration: String?
    if acknowledgeEmpty {
        let generation = try context.value("generation")
        guard generation == runtime.generation else { throw RemoteControlError.guardian("empty-fleet acknowledgement does not match the active generation") }
        acknowledgedGeneration = generation
    } else {
        acknowledgedGeneration = nil
    }
    let registry = try remoteLoadRegistry(configPath: configPath)
    let herdrPaths = Set(registry.profiles.map(\.herdrExecutable))
    guard herdrPaths.count == 1, let herdrExecutable = herdrPaths.first else { throw RemoteControlError.guardian("all profiles must use one exact Herdr executable") }
    let ledger = try RemoteResumeLedgerFactory.make(
        ledgerRootURL: URL(fileURLWithPath: try context.path("ledger", environment: "OURO_LEDGER_ROOT"), isDirectory: true),
        herdrRootURL: rootURL,
        registry: registry,
        inheritedEnvironment: context.environment
    )
    let adapter = RemoteHerdrAdapter(
        rootURL: rootURL,
        registry: registry,
        ledger: ledger,
        sessionMapURL: URL(fileURLWithPath: try context.path("session-map", environment: "OURO_SESSION_MAP")),
        herdrExecutable: herdrExecutable,
        configPath: configPath,
        helperPath: context.helperPath,
        shimDirectory: try context.path("shim-directory", environment: "OURO_SHIM_DIRECTORY"),
        zdotdir: try context.path("zdotdir", environment: "OURO_ZDOTDIR"),
        inheritedEnvironment: context.environment
    )
    let inventory: RemoteHerdrInventory
    switch try adapter.probe(sessionName: runtime.sessionName) {
    case let .running(value): inventory = value
    case .absent: throw RemoteControlError.guardian("active generation is absent; last-known-good capture refused")
    case let .degraded(detail): throw RemoteControlError.guardian("active generation is degraded; last-known-good capture refused: \(detail)")
    }
    let manifest = try RemoteLastKnownGoodStore(rootURL: rootURL).capture(
        sourceGeneration: runtime.generation,
        inventory: inventory,
        acknowledgedEmptyGeneration: acknowledgedGeneration
    )
    try remoteWriteJSON([
        "acknowledged_empty": manifest.generationManifest.acknowledgedEmpty ? "true" : "false",
        "capture": manifest.captureID,
        "generation": manifest.sourceGeneration,
        "snapshot_sha256": manifest.snapshotSHA256
    ])
}

private func remoteLoadSnapshotRuntime(rootURL: URL) throws -> RemoteActiveRuntime {
    let url = rootURL.appendingPathComponent("active-runtime.json")
    let data = try RemotePrivateFile.read(path: url.path, maximumBytes: RemoteGuardian.maximumControlFileBytes)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == Set(["schemaVersion", "generation", "sessionName", "socketPath", "expectedInventoryPath"]),
          let runtime = try? JSONDecoder().decode(RemoteActiveRuntime.self, from: data),
          runtime.schemaVersion == 1,
          runtime.generation == runtime.sessionName
    else { throw RemoteControlError.guardian("active runtime is invalid; last-known-good capture refused") }
    let generationRoot = rootURL.appendingPathComponent("sessions/\(runtime.generation)", isDirectory: true)
    guard runtime.socketPath == generationRoot.appendingPathComponent("herdr.sock").path,
          runtime.expectedInventoryPath == generationRoot.appendingPathComponent("expected-inventory.json").path
    else { throw RemoteControlError.guardian("active runtime paths are invalid; last-known-good capture refused") }
    return runtime
}

func remoteRunPackage(_ context: RemoteHelperContext) throws {
    let outputRoot = URL(fileURLWithPath: try context.path("output"), isDirectory: true)
    let manifest = try RemoteArtifactBuilder.build(
        helperURL: URL(fileURLWithPath: context.helperPath),
        outputURL: outputRoot,
        sourceRootURL: URL(fileURLWithPath: context.workingDirectory, isDirectory: true),
        revision: try context.value("revision"),
        expectedHelperSHA256: try context.value("expected-helper-sha256")
    )
    try remoteWriteJSON(manifest)
}

func remoteRunShellBootstrap(_ context: RemoteHelperContext) throws {
    let outputRoot = URL(fileURLWithPath: try context.path("output"), isDirectory: true)
    try remoteEnsurePrivateDirectory(outputRoot)
    let files = try RemoteShellBootstrap.render(
        zshExecutable: try context.path("zsh"),
        realZDOTDIR: try context.path("real-zdotdir"),
        ouroZDOTDIR: outputRoot.path,
        helperPath: try context.path("helper"),
        configPath: try context.path("config"),
        sessionMapPath: try context.path("session-map")
    )
    for (name, data) in files {
        try RemoteDurableFile.write(data, to: outputRoot.appendingPathComponent(name), mode: 0o600)
    }
}

func remoteRunWrapperHandshake(_ context: RemoteHelperContext) throws {
    let rawShellPID = try context.value("shell-pid")
    let wrapperHelperPath = try context.path("helper")
    guard let shellPID = Int32(rawShellPID), shellPID > 0, String(shellPID) == rawShellPID else {
        throw RemoteControlError.invalidConfiguration("wrapper handshake shell pid is invalid")
    }
    guard URL(fileURLWithPath: wrapperHelperPath).resolvingSymlinksInPath().standardizedFileURL.path == context.helperPath else {
        throw RemoteControlError.invalidConfiguration("wrapper handshake helper does not resolve to this runtime")
    }
    try RemoteShellReadiness.record(
        sessionMapURL: URL(fileURLWithPath: try context.path("session-map")),
        generation: try context.value("generation"),
        paneID: try context.value("pane"),
        shellPID: shellPID,
        zshExecutable: try context.path("zsh"),
        zdotdir: try context.path("zdotdir"),
        helperPath: wrapperHelperPath,
        configPath: try context.path("config"),
        functionBody: try context.value("function-body"),
        environment: context.environment
    )
}

func remoteRunInstall(_ context: RemoteHelperContext) throws {
    let runtimeRoot = URL(fileURLWithPath: try context.path("runtime-root"), isDirectory: true)
    let artifactRoot = URL(fileURLWithPath: try context.path("artifact-root"), isDirectory: true)
    let revision = try context.value("revision")
    let provenance = try RemoteRuntimeInstaller(rootURL: runtimeRoot).install(
        artifactRoot: artifactRoot,
        expectedRevision: revision,
        expectedHelperSHA256: try context.value("expected-helper-sha256")
    )
    try remoteWriteJSON(provenance)
}

func remoteRunRollback(_ context: RemoteHelperContext) throws {
    let runtimeRoot = URL(fileURLWithPath: try context.path("runtime-root"), isDirectory: true)
    let revision = try context.value("revision")
    let manifestPath = runtimeRoot.appendingPathComponent("versions/\(revision)/install-manifest.json").path
    let provenance: RemoteProvenanceManifest
    do { provenance = try JSONDecoder().decode(RemoteProvenanceManifest.self, from: RemotePrivateFile.read(path: manifestPath)) }
    catch let error as RemoteControlError { throw error }
    catch { throw RemoteControlError.artifact("install provenance is invalid") }
    guard provenance.revision == revision else { throw RemoteControlError.artifact("install provenance revision mismatch") }
    let result = try RemoteRuntimeInstaller(rootURL: runtimeRoot).rollback(
        provenance: provenance,
        nativeSessionReferencesRemain: true
    )
    try remoteWriteJSON(["result": String(describing: result), "revision": revision])
}

func remoteEnsurePrivateDirectory(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw RemoteControlError.invalidConfiguration("private directory could not be created") }
    }
    do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    catch { throw RemoteControlError.invalidConfiguration("private directory permissions could not be set") }
}

func remoteWriteJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(value)
    data.append(0x0a)
    FileHandle.standardOutput.write(data)
}
