import Darwin
import Foundation

struct RemoteShellReadyMarker: Codable, Equatable {
    var schemaVersion: Int
    var generation: String
    var paneID: String
    var shellIdentity: RemoteProcessIdentity
    var zshExecutable: String
    var zdotdir: String
    var helperPath: String
    var configPath: String
    var sessionMapPath: String
    var functionSHA256: String
}

public enum RemoteShellReadiness {
    public static let maximumMarkerBytes = 65_536

    public static func copilotFunctionBody(helperPath: String, configPath: String, sessionMapPath: String) -> String {
        "\t\(RemoteShellBootstrap.quote(helperPath)) dispatch --config \(RemoteShellBootstrap.quote(configPath)) --session-map \(RemoteShellBootstrap.quote(sessionMapPath)) -- \"$@\""
    }

    public static func record(
        sessionMapURL: URL,
        generation: String,
        paneID: String,
        shellPID: Int32,
        zshExecutable: String,
        zdotdir: String,
        helperPath: String,
        configPath: String,
        functionBody: String,
        environment: [String: String],
        parentPID: Int32 = getppid(),
        processIdentityForPID: (Int32, String) -> RemoteProcessIdentity? = remoteProcessIdentity
    ) throws {
        let paths = [sessionMapURL.path, zshExecutable, zdotdir, helperPath, configPath]
        guard paths.allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 }) else {
            throw RemoteControlError.invalidConfiguration("wrapper handshake requires absolute normalized paths")
        }
        guard validGeneration(generation), validPaneID(paneID), shellPID > 0, parentPID == shellPID else {
            throw RemoteControlError.invalidConfiguration("wrapper handshake process context is invalid")
        }
        guard exactContext(environment, keys: ["OURO_GENERATION", "HERDR_SESSION"], expected: generation, requiredKey: "HERDR_SESSION"),
              exactContext(environment, keys: ["OURO_PANE_ID", "HERDR_PANE_ID"], expected: paneID, requiredKey: "HERDR_PANE_ID"),
              environment["ZDOTDIR"] == zdotdir
        else { throw RemoteControlError.invalidConfiguration("wrapper handshake environment disagrees with Herdr") }
        let resolvedZsh = URL(fileURLWithPath: zshExecutable).resolvingSymlinksInPath().standardizedFileURL.path
        guard let shellIdentity = processIdentityForPID(shellPID, generation),
              shellIdentity.pid == shellPID,
              shellIdentity.generation == generation,
              shellIdentity.executable == resolvedZsh,
              functionBody == copilotFunctionBody(helperPath: helperPath, configPath: configPath, sessionMapPath: sessionMapURL.path)
        else { throw RemoteControlError.invalidConfiguration("wrapper handshake did not prove the final zsh dispatcher") }
        let marker = RemoteShellReadyMarker(
            schemaVersion: 1,
            generation: generation,
            paneID: paneID,
            shellIdentity: shellIdentity,
            zshExecutable: resolvedZsh,
            zdotdir: zdotdir,
            helperPath: helperPath,
            configPath: configPath,
            sessionMapPath: sessionMapURL.path,
            functionSHA256: RemoteArtifactVerifier.sha256(Data(functionBody.utf8))
        )
        let markerURL = try prepareMarkerURL(sessionMapURL: sessionMapURL, generation: generation, paneID: paneID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try RemoteDurableFile.write(encoder.encode(marker), to: markerURL)
    }

    public static func isReady(
        sessionMapURL: URL,
        generation: String,
        paneID: String,
        shellPID: Int32,
        zshExecutable: String,
        zdotdir: String,
        helperPath: String,
        configPath: String,
        processIdentityForPID: (Int32, String) -> RemoteProcessIdentity? = remoteProcessIdentity
    ) -> Bool {
        guard validGeneration(generation), validPaneID(paneID), shellPID > 0 else { return false }
        let paths = [sessionMapURL.path, zshExecutable, zdotdir, helperPath, configPath]
        guard paths.allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 }) else { return false }
        let markerRoot = sessionMapURL.deletingLastPathComponent().appendingPathComponent("wrapper-ready", isDirectory: true)
        let generationRoot = markerRoot.appendingPathComponent(generation, isDirectory: true)
        guard privateDirectory(markerRoot), privateDirectory(generationRoot) else { return false }
        let markerURL = generationRoot.appendingPathComponent("\(paneID).json")
        guard let data = try? RemotePrivateFile.read(path: markerURL.path, maximumBytes: maximumMarkerBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "generation", "paneID", "shellIdentity", "zshExecutable", "zdotdir", "helperPath", "configPath", "sessionMapPath", "functionSHA256"]),
              let identity = object["shellIdentity"] as? [String: Any],
              Set(identity.keys) == Set(["pid", "startIdentity", "executable", "generation"]),
              let marker = try? JSONDecoder().decode(RemoteShellReadyMarker.self, from: data)
        else { return false }
        let resolvedZsh = URL(fileURLWithPath: zshExecutable).resolvingSymlinksInPath().standardizedFileURL.path
        let expectedBody = copilotFunctionBody(helperPath: helperPath, configPath: configPath, sessionMapPath: sessionMapURL.path)
        return marker.schemaVersion == 1
            && marker.generation == generation
            && marker.paneID == paneID
            && marker.shellIdentity.pid == shellPID
            && marker.shellIdentity.generation == generation
            && marker.zshExecutable == resolvedZsh
            && marker.zdotdir == zdotdir
            && marker.helperPath == helperPath
            && marker.configPath == configPath
            && marker.sessionMapPath == sessionMapURL.path
            && marker.functionSHA256 == RemoteArtifactVerifier.sha256(Data(expectedBody.utf8))
            && processIdentityForPID(shellPID, generation) == marker.shellIdentity
    }

    private static func exactContext(_ environment: [String: String], keys: [String], expected: String, requiredKey: String) -> Bool {
        guard environment[requiredKey] == expected else { return false }
        return keys.compactMap { environment[$0] }.filter { !$0.isEmpty }.allSatisfy { $0 == expected }
    }

    private static func prepareMarkerURL(sessionMapURL: URL, generation: String, paneID: String) throws -> URL {
        let mapRoot = sessionMapURL.deletingLastPathComponent()
        try ensurePrivateDirectory(mapRoot)
        let markerRoot = mapRoot.appendingPathComponent("wrapper-ready", isDirectory: true)
        try ensurePrivateDirectory(markerRoot)
        let generationRoot = markerRoot.appendingPathComponent(generation, isDirectory: true)
        try ensurePrivateDirectory(generationRoot)
        return generationRoot.appendingPathComponent("\(paneID).json")
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            guard errno == ENOENT else { throw RemoteControlError.invalidConfiguration("wrapper readiness directory is unavailable") }
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw RemoteControlError.invalidConfiguration("wrapper readiness directory is unavailable") }
        }
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == getuid(),
              value.st_mode & mode_t(0o777) == 0o700
        else {
            throw RemoteControlError.invalidConfiguration("wrapper readiness directory must be owned with 0700 permissions")
        }
    }

    private static func privateDirectory(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
            && value.st_mode & S_IFMT == S_IFDIR
            && value.st_uid == getuid()
            && value.st_mode & mode_t(0o777) == 0o700
    }

    private static func validGeneration(_ value: String) -> Bool {
        value.range(of: "^ouro-[A-Za-z0-9][A-Za-z0-9._-]{0,122}$", options: .regularExpression) != nil
    }

    private static func validPaneID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$", options: .regularExpression) != nil
    }
}
