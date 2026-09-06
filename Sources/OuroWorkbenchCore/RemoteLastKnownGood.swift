import CryptoKit
import Darwin
import Foundation

public struct RemoteLastKnownGoodManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var captureID: String
    public var sourceGeneration: String
    public var snapshotSHA256: String
    public var generationManifest: RemoteGenerationManifest

    public init(schemaVersion: Int, captureID: String, sourceGeneration: String, snapshotSHA256: String, generationManifest: RemoteGenerationManifest) {
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.sourceGeneration = sourceGeneration
        self.snapshotSHA256 = snapshotSHA256
        self.generationManifest = generationManifest
    }
}

public struct RemoteLastKnownGoodSelection: Equatable, Sendable {
    public var manifest: RemoteLastKnownGoodManifest
    public var snapshotURL: URL

    public init(manifest: RemoteLastKnownGoodManifest, snapshotURL: URL) {
        self.manifest = manifest
        self.snapshotURL = snapshotURL
    }

    public func verifyCopiedSnapshot(at url: URL) throws {
        guard try RemoteLastKnownGoodStore.snapshotSHA256(at: url) == manifest.snapshotSHA256 else {
            throw RemoteControlError.guardian("last-known-good snapshot digest does not match its manifest")
        }
    }
}

public enum RemoteLastKnownGoodCheckpoint: String, CaseIterable, Equatable, Sendable {
    case snapshotCopied = "snapshot_copied"
    case manifestWritten = "manifest_written"
    case generationSynchronized = "generation_synchronized"
    case generationPromoted = "generation_promoted"
}

public struct RemoteLastKnownGoodStore {
    public static let maximumManifestBytes = 65_536
    public static let maximumSnapshotBytes = 64 * 1_024 * 1_024

    public let rootURL: URL
    private let makeCaptureID: () -> String

    public init(rootURL: URL, makeCaptureID: @escaping () -> String = { "lkg-\(UUID().uuidString.lowercased())" }) {
        self.rootURL = rootURL.standardizedFileURL
        self.makeCaptureID = makeCaptureID
    }

    public func capture(
        sourceGeneration: String,
        inventory: RemoteHerdrInventory,
        acknowledgedEmptyGeneration: String? = nil,
        checkpoint: (RemoteLastKnownGoodCheckpoint) throws -> Void = { _ in }
    ) throws -> RemoteLastKnownGoodManifest {
        try Self.validateName(sourceGeneration, label: "source generation name")
        let panes = try expectedPanes(inventory: inventory, sourceGeneration: sourceGeneration, acknowledgedEmptyGeneration: acknowledgedEmptyGeneration)
        let captureID = makeCaptureID()
        try Self.validateName(captureID, label: "capture id")
        try Self.validatePrivateDirectory(rootURL, label: "Herdr root")
        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        try Self.validatePrivateDirectory(sessionsURL, label: "Herdr sessions root")
        let sourceURL = sessionsURL.appendingPathComponent(sourceGeneration, isDirectory: true)
        let lastKnownGoodURL = rootURL.appendingPathComponent("last-known-good", isDirectory: true)
        let generationsURL = lastKnownGoodURL.appendingPathComponent("generations", isDirectory: true)
        try Self.ensurePrivateDirectory(lastKnownGoodURL, label: "last-known-good root")
        try Self.ensurePrivateDirectory(generationsURL, label: "last-known-good generations")
        let lock: RemoteAdvisoryLock
        do { lock = try RemoteAdvisoryLock.acquire(url: lastKnownGoodURL.appendingPathComponent("capture.lock")) }
        catch { throw RemoteControlError.guardian("last-known-good capture is already running or unavailable") }
        defer { lock.release() }

        let destinationURL = generationsURL.appendingPathComponent(captureID, isDirectory: true)
        let stageURL = generationsURL.appendingPathComponent(".\(captureID).stage", isDirectory: true)
        guard try Self.missing(destinationURL, label: "last-known-good generation"), try Self.missing(stageURL, label: "last-known-good stage") else {
            throw RemoteControlError.guardian("last-known-good capture id already exists")
        }
        var cleanupStage = true
        defer { if cleanupStage { try? FileManager.default.removeItem(at: stageURL) } }
        try Self.ensurePrivateDirectory(stageURL, label: "last-known-good stage")
        let stagedSnapshotURL = stageURL.appendingPathComponent("session", isDirectory: true)
        try Self.copySnapshot(from: sourceURL, to: stagedSnapshotURL)
        try Self.runCheckpoint(.snapshotCopied, checkpoint)
        let digest = try Self.snapshotSHA256(at: stagedSnapshotURL)
        let generationManifest = RemoteGenerationManifest(
            schemaVersion: 1,
            sourceSession: sourceGeneration,
            herdrVersion: inventory.version,
            expectedPanes: panes,
            acknowledgedEmpty: panes.isEmpty
        )
        let manifest = RemoteLastKnownGoodManifest(
            schemaVersion: 1,
            captureID: captureID,
            sourceGeneration: sourceGeneration,
            snapshotSHA256: digest,
            generationManifest: generationManifest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try RemoteDurableFile.write(encoder.encode(manifest), to: stageURL.appendingPathComponent("manifest.json")) }
        catch { throw RemoteControlError.guardian("last-known-good manifest could not be written") }
        try Self.runCheckpoint(.manifestWritten, checkpoint)
        do { try remoteSynchronizeTree(rootURL: stageURL) }
        catch { throw RemoteControlError.guardian("last-known-good generation could not be synchronized") }
        try Self.runCheckpoint(.generationSynchronized, checkpoint)
        do { try FileManager.default.moveItem(at: stageURL, to: destinationURL) }
        catch { throw RemoteControlError.guardian("last-known-good generation could not be promoted") }
        do { try remoteSynchronizeNode(generationsURL, kind: .directory) }
        catch { throw RemoteControlError.guardian("last-known-good promotion could not be synchronized") }
        cleanupStage = false
        try Self.runCheckpoint(.generationPromoted, checkpoint)
        do { try RemoteDurableFile.write(Data("\(captureID)\n".utf8), to: lastKnownGoodURL.appendingPathComponent("current")) }
        catch { throw RemoteControlError.guardian("last-known-good selection could not be published") }
        return manifest
    }

    public func loadCurrent(afterPointerRead: () throws -> Void = {}) throws -> RemoteLastKnownGoodSelection {
        try Self.validatePrivateDirectory(rootURL, label: "Herdr root")
        let lastKnownGoodURL = rootURL.appendingPathComponent("last-known-good", isDirectory: true)
        let generationsURL = lastKnownGoodURL.appendingPathComponent("generations", isDirectory: true)
        try Self.validatePrivateDirectory(lastKnownGoodURL, label: "last-known-good root")
        try Self.validatePrivateDirectory(generationsURL, label: "last-known-good generations")
        let pointerURL = lastKnownGoodURL.appendingPathComponent("current")
        try Self.validatePrivateRegularFile(pointerURL, label: "last-known-good selection")
        let pointerData = try Self.readBounded(pointerURL, maximumBytes: 128, label: "last-known-good selection")
        guard let captureID = String(data: pointerData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !captureID.isEmpty,
              (try? Self.validateName(captureID, label: "last-known-good selection")) != nil
        else { throw RemoteControlError.guardian("last-known-good selection is invalid") }
        do { try afterPointerRead() }
        catch { throw RemoteControlError.guardian("last-known-good selection read was interrupted") }

        let captureURL = generationsURL.appendingPathComponent(captureID, isDirectory: true)
        try Self.validatePrivateDirectory(captureURL, label: "last-known-good selection")
        let manifestURL = captureURL.appendingPathComponent("manifest.json")
        try Self.validatePrivateRegularFile(manifestURL, label: "last-known-good snapshot manifest")
        let manifestData = try Self.readBounded(manifestURL, maximumBytes: Self.maximumManifestBytes, label: "last-known-good snapshot manifest")
        let manifest = try Self.decodeManifest(manifestData)
        guard manifest.captureID == captureID else { throw RemoteControlError.guardian("last-known-good manifest does not match its selection") }
        let snapshotURL = captureURL.appendingPathComponent("session", isDirectory: true)
        return RemoteLastKnownGoodSelection(manifest: manifest, snapshotURL: snapshotURL)
    }

    static func snapshotSHA256(at root: URL) throws -> String {
        try validatePrivateDirectory(root, label: "last-known-good snapshot")
        let sessionJSON = root.appendingPathComponent("session.json")
        try validatePrivateRegularFile(sessionJSON, label: "last-known-good snapshot session.json")
        let paths: [String]
        do { paths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() }
        catch { throw RemoteControlError.guardian("last-known-good snapshot is unreadable") }
        var hasher = SHA256()
        var totalBytes = 0
        for relativePath in paths {
            let url = root.appendingPathComponent(relativePath)
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw RemoteControlError.guardian("last-known-good snapshot entry is unreadable") }
            if value.st_mode & S_IFMT == S_IFDIR {
                guard value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.guardian("last-known-good snapshot directory permissions are unsafe") }
                update(&hasher, marker: 0x44, relativePath: relativePath, data: Data())
            } else if value.st_mode & S_IFMT == S_IFREG {
                try validatePrivateRegularFile(url, label: "last-known-good snapshot entry")
                let data: Data
                do { data = try RemotePrivateFile.read(path: url.path, maximumBytes: maximumSnapshotBytes - totalBytes) }
                catch { throw RemoteControlError.guardian("last-known-good snapshot entry is unreadable or exceeds the byte bound") }
                let nextTotal = totalBytes + data.count
                totalBytes = nextTotal
                update(&hasher, marker: 0x46, relativePath: relativePath, data: data)
            } else {
                throw RemoteControlError.guardian("last-known-good snapshot contains a special entry")
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func expectedPanes(inventory: RemoteHerdrInventory, sourceGeneration: String, acknowledgedEmptyGeneration: String?) throws -> [RemoteExpectedPane] {
        guard inventory.version == "0.8.2" else { throw RemoteControlError.guardian("last-known-good Herdr version is unsupported") }
        if inventory.panes.isEmpty {
            guard let acknowledgedEmptyGeneration else { throw RemoteControlError.guardian("an explicit empty-fleet acknowledgement is required") }
            guard acknowledgedEmptyGeneration == sourceGeneration else { throw RemoteControlError.guardian("empty-fleet acknowledgement does not match the active generation") }
            return []
        }
        guard acknowledgedEmptyGeneration == nil else { throw RemoteControlError.guardian("empty-fleet acknowledgement is only valid for an empty fleet") }
        var nativeSessionIDs = Set<String>()
        var paneIDs = Set<String>()
        return try inventory.panes.map { pane in
            guard pane.generation == sourceGeneration else { throw RemoteControlError.guardian("last-known-good pane generation does not match the active generation") }
            guard let nativeSessionID = pane.nativeSessionID,
                  let profileID = pane.profileID,
                  let githubLogin = pane.githubLogin,
                  pane.childPresent,
                  pane.hookObserved,
                  pane.wrapperReady,
                  let process = pane.foregroundProcess,
                  process.pid > 0,
                  !process.startIdentity.isEmpty,
                  process.executable.hasPrefix("/"),
                  process.generation == sourceGeneration
            else { throw RemoteControlError.guardian("last-known-good capture requires complete healthy pane evidence") }
            guard let uuid = UUID(uuidString: nativeSessionID), uuid.uuidString.lowercased() == nativeSessionID else { throw RemoteControlError.guardian("last-known-good native session UUID is invalid") }
            guard Self.safeText(pane.workspaceID), Self.safeText(pane.paneID), Self.safeText(profileID), Self.safeText(githubLogin) else { throw RemoteControlError.guardian("last-known-good pane identity is invalid") }
            guard nativeSessionIDs.insert(nativeSessionID).inserted, paneIDs.insert(pane.paneID).inserted else { throw RemoteControlError.guardian("last-known-good inventory contains a duplicate pane or native session") }
            return RemoteExpectedPane(workspaceID: pane.workspaceID, paneID: pane.paneID, nativeSessionID: nativeSessionID, profileID: profileID, githubLogin: githubLogin)
        }
    }

    private static func copySnapshot(from source: URL, to destination: URL) throws {
        try validatePrivateDirectory(source, label: "source snapshot")
        try validatePrivateRegularFile(source.appendingPathComponent("session.json"), label: "source snapshot session.json")
        let paths: [String]
        do { paths = try FileManager.default.subpathsOfDirectory(atPath: source.path).sorted() }
        catch { throw RemoteControlError.guardian("source snapshot is unreadable") }
        try ensurePrivateDirectory(destination, label: "staged snapshot")
        for relativePath in paths {
            if relativePath == "herdr.sock" || relativePath == "herdr-client.sock" { continue }
            let sourceItem = source.appendingPathComponent(relativePath)
            let destinationItem = destination.appendingPathComponent(relativePath)
            var value = stat()
            guard lstat(sourceItem.path, &value) == 0 else { throw RemoteControlError.guardian("source snapshot entry is unreadable") }
            if value.st_mode & S_IFMT == S_IFDIR {
                guard value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.guardian("source snapshot directory permissions are unsafe") }
                try ensurePrivateDirectory(destinationItem, label: "staged snapshot directory")
            } else if value.st_mode & S_IFMT == S_IFREG {
                try validatePrivateRegularFile(sourceItem, label: "source snapshot entry")
                do { try RemoteDurableFile.write(RemotePrivateFile.read(path: sourceItem.path, maximumBytes: maximumSnapshotBytes), to: destinationItem) }
                catch { throw RemoteControlError.guardian("source snapshot entry could not be copied") }
            } else {
                throw RemoteControlError.guardian("source snapshot contains a special entry")
            }
        }
        _ = try snapshotSHA256(at: destination)
    }

    private static func decodeManifest(_ data: Data) throws -> RemoteLastKnownGoodManifest {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteControlError.guardian("last-known-good snapshot manifest must be an object") }
            object = decoded
        } catch let error as RemoteControlError {
            throw error
        } catch {
            throw RemoteControlError.guardian("last-known-good snapshot manifest is invalid")
        }
        guard Set(object.keys) == Set(["schemaVersion", "captureID", "sourceGeneration", "snapshotSHA256", "generationManifest"]),
              let generation = object["generationManifest"] as? [String: Any],
              Set(generation.keys) == Set(["schemaVersion", "sourceSession", "herdrVersion", "expectedPanes", "acknowledgedEmpty"]),
              let panes = generation["expectedPanes"] as? [[String: Any]],
              panes.allSatisfy({ Set($0.keys) == Set(["workspaceID", "paneID", "nativeSessionID", "profileID", "githubLogin"]) })
        else { throw RemoteControlError.guardian("last-known-good snapshot manifest keys are invalid") }
        let manifest: RemoteLastKnownGoodManifest
        do { manifest = try JSONDecoder().decode(RemoteLastKnownGoodManifest.self, from: data) }
        catch { throw RemoteControlError.guardian("last-known-good snapshot manifest fields are invalid") }
        guard manifest.schemaVersion == 1,
              manifest.generationManifest.schemaVersion == 1,
              manifest.sourceGeneration == manifest.generationManifest.sourceSession,
              manifest.generationManifest.herdrVersion == "0.8.2",
              manifest.generationManifest.acknowledgedEmpty == manifest.generationManifest.expectedPanes.isEmpty,
              manifest.snapshotSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (try? validateName(manifest.captureID, label: "capture id")) != nil,
              (try? validateName(manifest.sourceGeneration, label: "source generation")) != nil
        else { throw RemoteControlError.guardian("last-known-good snapshot manifest identity is invalid") }
        return manifest
    }

    private static func update(_ hasher: inout SHA256, marker: UInt8, relativePath: String, data: Data) {
        hasher.update(data: Data([marker]))
        updateLength(&hasher, relativePath.utf8.count)
        hasher.update(data: Data(relativePath.utf8))
        updateLength(&hasher, data.count)
        hasher.update(data: data)
    }

    private static func updateLength(_ hasher: inout SHA256, _ value: Int) {
        var length = UInt64(value).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
    }

    private static func runCheckpoint(_ point: RemoteLastKnownGoodCheckpoint, _ callback: (RemoteLastKnownGoodCheckpoint) throws -> Void) throws {
        do { try callback(point) }
        catch { throw RemoteControlError.guardian("last-known-good capture was interrupted at \(point.rawValue)") }
    }

    private static func missing(_ url: URL, label: String) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return false }
        guard errno == ENOENT else { throw RemoteControlError.guardian("\(label) is unavailable") }
        return true
    }

    static func ensurePrivateDirectory(
        _ url: URL,
        label: String,
        validationCheckpoint: () throws -> Void = {}
    ) throws {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw RemoteControlError.guardian("\(label) could not be created") }
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RemoteControlError.guardian("\(label) permissions could not be secured") }
        defer { Darwin.close(descriptor) }
        var anchored = stat()
        guard fstat(descriptor, &anchored) == 0,
              anchored.st_mode & S_IFMT == S_IFDIR,
              anchored.st_uid == geteuid()
        else { throw RemoteControlError.guardian("\(label) permissions could not be secured") }
        try validationCheckpoint()
        guard fchmod(descriptor, 0o700) == 0,
              Darwin.fsync(descriptor) == 0
        else { throw RemoteControlError.guardian("\(label) permissions could not be secured") }
        var current = stat()
        guard lstat(url.path, &current) == 0,
              current.st_dev == anchored.st_dev,
              current.st_ino == anchored.st_ino
        else { throw RemoteControlError.guardian("\(label) changed while its permissions were secured") }
    }

    private static func validatePrivateDirectory(_ url: URL, label: String) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw RemoteControlError.guardian("\(label) must be a private directory") }
        guard value.st_uid == getuid(), value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.guardian("\(label) must be owned by the current user with permissions 0700") }
    }

    private static func validatePrivateRegularFile(_ url: URL, label: String) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_uid == getuid() else { throw RemoteControlError.guardian("\(label) must be an owned private regular file") }
        guard value.st_mode & mode_t(0o777) == 0o600 else { throw RemoteControlError.guardian("\(label) permissions must be 0600") }
    }

    private static func readBounded(_ url: URL, maximumBytes: Int, label: String) throws -> Data {
        do { return try RemotePrivateFile.read(path: url.path, maximumBytes: maximumBytes) }
        catch { throw RemoteControlError.guardian("\(label) is unreadable") }
    }

    private static func validateName(_ value: String, label: String) throws {
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else { throw RemoteControlError.guardian("\(label) is unsafe") }
    }

    private static func safeText(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
