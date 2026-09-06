import Darwin
import Foundation

@_silgen_name("flock")
private func remoteFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

@_silgen_name("link")
private func remoteLink(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32

private func remoteEnsurePrivateLedgerDirectory(_ url: URL, label: String) throws {
    var value = stat()
    if lstat(url.path, &value) != 0 {
        guard errno == ENOENT else { throw RemoteControlError.ledger("\(label) is unavailable") }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw RemoteControlError.ledger("\(label) is unavailable") }
        guard lstat(url.path, &value) == 0 else { throw RemoteControlError.ledger("\(label) is unavailable") }
    }
    guard value.st_mode & S_IFMT == S_IFDIR else { throw RemoteControlError.ledger("\(label) is not a directory") }
    guard value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.ledger("\(label) permissions must be 0700") }
}

private func remoteValidatePrivateLedgerDirectoryIfPresent(_ url: URL, label: String) throws -> Bool {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
        if errno == ENOENT { return false }
        throw RemoteControlError.ledger("\(label) is unavailable")
    }
    guard value.st_mode & S_IFMT == S_IFDIR else { throw RemoteControlError.ledger("\(label) is not a directory") }
    guard value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.ledger("\(label) permissions must be 0700") }
    return true
}

private func remoteValidatePrivateLedgerFile(_ url: URL, label: String) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
        throw RemoteControlError.ledger("\(label) must be a private regular file")
    }
    guard value.st_mode & mode_t(0o777) == 0o600 else { throw RemoteControlError.ledger("\(label) permissions must be 0600") }
    return value
}

public enum RemoteDurableWriteCheckpoint: String, CaseIterable, Equatable, Sendable {
    case temporaryOpened = "temporary_opened"
    case bytesWritten = "bytes_written"
    case fileSynced = "file_synced"
    case renamed
    case directorySynced = "directory_synced"
}

public enum RemoteDurableFile {
    public static func write(
        _ data: Data,
        to destination: URL,
        mode: mode_t = 0o600,
        checkpoint: (RemoteDurableWriteCheckpoint, URL, Data) throws -> Void = { _, _, _ in },
        directoryOpened: (Int32) throws -> Void = { _ in }
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try remoteEnsurePrivateLedgerDirectory(directory, label: "durable file directory")
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw RemoteControlError.ledger("durable directory could not be opened") }
        defer { Darwin.close(directoryDescriptor) }
        try directoryOpened(directoryDescriptor)
        var anchored = stat()
        var current = stat()
        guard fstat(directoryDescriptor, &anchored) == 0,
              lstat(directory.path, &current) == 0,
              anchored.st_dev == current.st_dev,
              anchored.st_ino == current.st_ino
        else { throw RemoteControlError.ledger("durable directory changed while it was opened") }
        try write(data, named: destination.lastPathComponent, in: directoryDescriptor, directoryURL: directory, mode: mode, checkpoint: checkpoint)
    }

    public static func write(
        _ data: Data,
        named destinationName: String,
        in directoryDescriptor: Int32,
        directoryURL: URL,
        mode: mode_t = 0o600,
        checkpoint: (RemoteDurableWriteCheckpoint, URL, Data) throws -> Void = { _, _, _ in }
    ) throws {
        try write(data, named: destinationName, in: directoryDescriptor, directoryURL: directoryURL, mode: mode, checkpoint: checkpoint, temporaryOpened: { _ in })
    }

    public static func write(
        _ data: Data,
        named destinationName: String,
        in directoryDescriptor: Int32,
        directoryURL: URL,
        mode: mode_t = 0o600,
        checkpoint: (RemoteDurableWriteCheckpoint, URL, Data) throws -> Void,
        temporaryOpened: (Int32) throws -> Void
    ) throws {
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/"),
              !destinationName.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw RemoteControlError.ledger("durable destination name is unsafe") }
        var directoryStat = stat()
        guard fstat(directoryDescriptor, &directoryStat) == 0,
              directoryStat.st_mode & S_IFMT == S_IFDIR,
              directoryStat.st_uid == geteuid(),
              directoryStat.st_mode & mode_t(0o777) == 0o700
        else { throw RemoteControlError.ledger("durable directory descriptor is not private") }
        let destination = directoryURL.appendingPathComponent(destinationName)
        var initialDestination = stat()
        let destinationExisted = destinationName.withCString {
            fstatat(directoryDescriptor, $0, &initialDestination, AT_SYMLINK_NOFOLLOW)
        } == 0
        if destinationExisted {
            guard initialDestination.st_mode & S_IFMT == S_IFREG,
                  initialDestination.st_nlink == 1,
                  initialDestination.st_uid == geteuid(),
                  initialDestination.st_mode & mode_t(0o777) == mode
            else { throw RemoteControlError.ledger("durable destination must be a private regular file") }
        } else if errno != ENOENT {
            throw RemoteControlError.ledger("durable destination is unavailable")
        }
        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            openat(directoryDescriptor, $0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        }
        guard descriptor >= 0 else { throw RemoteControlError.ledger("durable temporary file could not be opened") }
        var openDescriptor = descriptor
        defer {
            if openDescriptor >= 0 { Darwin.close(openDescriptor) }
            _ = temporaryName.withCString { unlinkat(directoryDescriptor, $0, 0) }
        }
        try temporaryOpened(descriptor)
        var temporaryStat = stat()
        guard fstat(descriptor, &temporaryStat) == 0,
              temporaryStat.st_mode & S_IFMT == S_IFREG,
              temporaryStat.st_nlink == 1,
              temporaryStat.st_uid == geteuid(),
              fchmod(descriptor, mode) == 0
        else {
            throw RemoteControlError.ledger("durable temporary file is not private")
        }
        try checkpoint(.temporaryOpened, destination, data)
        let wroteAll = data.isEmpty || data.withUnsafeBytes { raw -> Bool in
            let base = raw.baseAddress!
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard wroteAll else { throw RemoteControlError.ledger("durable file write was incomplete") }
        try checkpoint(.bytesWritten, destination, data)
        guard Darwin.fsync(descriptor) == 0 else { throw RemoteControlError.ledger("durable file fsync failed") }
        try checkpoint(.fileSynced, destination, data)
        guard Darwin.close(descriptor) == 0 else {
            openDescriptor = -1
            throw RemoteControlError.ledger("durable file close failed")
        }
        openDescriptor = -1
        var currentDestination = stat()
        let destinationStillExists = destinationName.withCString {
            fstatat(directoryDescriptor, $0, &currentDestination, AT_SYMLINK_NOFOLLOW)
        } == 0
        if destinationExisted {
            guard destinationStillExists,
                  currentDestination.st_dev == initialDestination.st_dev,
                  currentDestination.st_ino == initialDestination.st_ino
            else { throw RemoteControlError.ledger("durable file rename failed because destination changed") }
        } else {
            guard !destinationStillExists, errno == ENOENT else {
                throw RemoteControlError.ledger("durable file rename failed because destination changed")
            }
        }
        let renamed = temporaryName.withCString { source in
            destinationName.withCString { target in renameat(directoryDescriptor, source, directoryDescriptor, target) }
        }
        guard renamed == 0 else { throw RemoteControlError.ledger("durable file rename failed") }
        try checkpoint(.renamed, destination, data)
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw RemoteControlError.ledger("durable directory fsync failed") }
        try checkpoint(.directorySynced, destination, data)
    }
}

public struct RemoteSessionMapping: Codable, Equatable, Sendable {
    public var sessionID: String
    public var profileID: String
    public var paneID: String
    public var generation: String

    public init(sessionID: String, profileID: String, paneID: String, generation: String) {
        self.sessionID = sessionID
        self.profileID = profileID
        self.paneID = paneID
        self.generation = generation
    }
}

public struct RemoteHookReport: Equatable, Sendable {
    public var mappingError: String?
    public var officialHookError: String?

    public init(mappingError: String?, officialHookError: String?) {
        self.mappingError = mappingError
        self.officialHookError = officialHookError
    }
}

public struct RemoteSessionMapStore {
    public static let maximumHookBytes = 65_536
    public static let maximumMapBytes = 1_048_576
    public let rootURL: URL
    public var mapURL: URL { rootURL.appendingPathComponent("session-map.json") }
    public var hasPendingRecovery: Bool { FileManager.default.fileExists(atPath: pendingURL.path) }
    private var lockURL: URL { rootURL.appendingPathComponent("session-map.lock") }
    private var pendingURL: URL { rootURL.appendingPathComponent("session-map.pending.json") }
    private let writer: (Data, URL) throws -> Void

    public init(rootURL: URL, writer: @escaping (Data, URL) throws -> Void = { data, url in try RemoteDurableFile.write(data, to: url) }) {
        self.rootURL = rootURL
        self.writer = writer
    }

    public func record(
        hookData: Data,
        profileID: String,
        paneID: String,
        generation: String,
        registry: RemoteProfileRegistry,
        ledger: RemoteResumeLedger?,
        officialHook: (Data) -> Error?
    ) -> RemoteHookReport {
        var mappingError: String?
        do {
            try writeMapping(hookData: hookData, profileID: profileID, paneID: paneID, generation: generation, registry: registry, ledger: ledger)
        } catch {
            mappingError = error.localizedDescription
        }
        return RemoteHookReport(mappingError: mappingError, officialHookError: officialHook(hookData)?.localizedDescription)
    }

    public func read(registry: RemoteProfileRegistry) throws -> [RemoteSessionMapping] {
        try Self.read(mapURL: mapURL, registry: registry)
    }

    public static func read(mapURL: URL, registry: RemoteProfileRegistry) throws -> [RemoteSessionMapping] {
        let root = mapURL.deletingLastPathComponent()
        try validateRoot(root)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("session-map.pending.json").path) else {
            throw RemoteControlError.invalidSessionMap("recovery required for an interrupted mapping transaction")
        }
        return try readUnlocked(mapURL: mapURL, registry: registry)
    }

    private func writeMapping(
        hookData: Data,
        profileID: String,
        paneID: String,
        generation: String,
        registry: RemoteProfileRegistry,
        ledger: RemoteResumeLedger?
    ) throws {
        let sessionID = try Self.parseHook(hookData)
        _ = try registry.profile(id: profileID)
        try Self.validateContext(paneID: paneID, generation: generation)
        try Self.ensurePrivateRoot(rootURL)
        let lock = try RemoteAdvisoryLock.acquire(url: lockURL, nonBlocking: false)
        defer { lock.release() }
        guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
            throw RemoteControlError.invalidSessionMap("recovery required for an interrupted mapping transaction")
        }
        let existing = FileManager.default.fileExists(atPath: mapURL.path) ? try Self.readUnlocked(mapURL: mapURL, registry: registry) : []
        var updated = existing
        if let index = existing.firstIndex(where: { $0.sessionID == sessionID }) {
            let prior = existing[index]
            if prior.profileID == profileID && prior.paneID == paneID && prior.generation == generation {
                if let ledger { try ledger.confirm(nativeSessionID: sessionID, profileID: profileID, generation: generation, paneID: paneID) }
                return
            }
            guard prior.profileID == profileID, prior.paneID == paneID, ledger != nil else {
                throw RemoteControlError.invalidSessionMap("session id is already mapped to another profile, pane, or generation")
            }
            updated[index] = RemoteSessionMapping(sessionID: sessionID, profileID: profileID, paneID: paneID, generation: generation)
        } else {
            updated.append(RemoteSessionMapping(sessionID: sessionID, profileID: profileID, paneID: paneID, generation: generation))
        }
        updated.sort { $0.sessionID < $1.sessionID }
        let data = try Self.encode(updated)
        do {
            if let ledger { try ledger.validateHookContext(nativeSessionID: sessionID, profileID: profileID, generation: generation, paneID: paneID) }
            try RemoteDurableFile.write(data, to: pendingURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
            if let ledger { try ledger.confirm(nativeSessionID: sessionID, profileID: profileID, generation: generation, paneID: paneID) }
            try writer(data, mapURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
            try FileManager.default.removeItem(at: pendingURL)
        } catch let error as RemoteControlError {
            throw error
        } catch {
            throw RemoteControlError.invalidSessionMap("atomic mapping write failed; recovery required")
        }
    }

    private static func parseHook(_ data: Data) throws -> String {
        guard data.count <= maximumHookBytes else { throw RemoteControlError.invalidHook("hook input is too large") }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteControlError.invalidHook("hook input must be an object") }
            object = decoded
        } catch let error as RemoteControlError {
            throw error
        } catch {
            throw RemoteControlError.invalidHook("hook input is not valid JSON")
        }
        let allowed = Set(["hook_event_name", "hookEventName", "session_id", "sessionId", "timestamp", "cwd", "source", "initial_prompt"])
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first { throw RemoteControlError.invalidHook("unknown hook key '\(unknown)'") }
        guard !(object.keys.contains("session_id") && object.keys.contains("sessionId")) else { throw RemoteControlError.invalidHook("duplicate session id fields") }
        guard !(object.keys.contains("hook_event_name") && object.keys.contains("hookEventName")) else { throw RemoteControlError.invalidHook("duplicate hook event fields") }
        guard let event = (object["hook_event_name"] ?? object["hookEventName"]) as? String, event == "SessionStart" else { throw RemoteControlError.invalidHook("only SessionStart is accepted") }
        guard let raw = (object["session_id"] ?? object["sessionId"]) as? String, let uuid = UUID(uuidString: raw) else {
            throw RemoteControlError.invalidHook("a valid session id is required")
        }
        if let value = object["timestamp"] {
            guard let timestamp = value as? String, timestamp.count <= 64 else { throw RemoteControlError.invalidHook("timestamp must be a bounded ISO 8601 string") }
            let wholeSeconds = ISO8601DateFormatter()
            let fractionalSeconds = ISO8601DateFormatter()
            fractionalSeconds.formatOptions.insert(.withFractionalSeconds)
            guard wholeSeconds.date(from: timestamp) != nil || fractionalSeconds.date(from: timestamp) != nil else { throw RemoteControlError.invalidHook("timestamp must be a bounded ISO 8601 string") }
        }
        if let value = object["cwd"] {
            guard let cwd = value as? String,
                  cwd.utf8.count <= 4_096,
                  cwd.hasPrefix("/"),
                  URL(fileURLWithPath: cwd).standardizedFileURL.path == cwd,
                  cwd.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw RemoteControlError.invalidHook("cwd must be a safe absolute normalized path") }
        }
        if let value = object["source"] {
            guard let source = value as? String, ["startup", "resume", "new"].contains(source) else { throw RemoteControlError.invalidHook("source is invalid") }
        }
        if let value = object["initial_prompt"] {
            guard let prompt = value as? String, prompt.utf8.count <= 32_768 else { throw RemoteControlError.invalidHook("initial prompt must be a bounded string") }
        }
        return uuid.uuidString.lowercased()
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var entries: [RemoteSessionMapping]
    }

    private static func encode(_ entries: [RemoteSessionMapping]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(schemaVersion: 1, entries: entries))
    }

    private static func readUnlocked(mapURL: URL, registry: RemoteProfileRegistry) throws -> [RemoteSessionMapping] {
        try validatePrivateRegularFile(mapURL, label: "session map file")
        let data: Data
        do {
            data = try Data(contentsOf: mapURL)
        } catch {
            throw RemoteControlError.invalidSessionMap("session map is missing or unreadable")
        }
        guard data.count <= maximumMapBytes else { throw RemoteControlError.invalidSessionMap("session map exceeds the byte bound") }
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteControlError.invalidSessionMap("session map must be an object") }
            root = object
        } catch let error as RemoteControlError {
            throw error
        } catch {
            throw RemoteControlError.invalidSessionMap("session map JSON is malformed")
        }
        if let unknown = Set(root.keys).subtracting(["schemaVersion", "entries"]).sorted().first { throw RemoteControlError.invalidSessionMap("unknown session map key '\(unknown)'") }
        guard let entries = root["entries"] as? [[String: Any]] else { throw RemoteControlError.invalidSessionMap("session entries are malformed") }
        let entryKeys = Set(["sessionID", "profileID", "paneID", "generation"])
        for entry in entries {
            if let unknown = Set(entry.keys).subtracting(entryKeys).sorted().first { throw RemoteControlError.invalidSessionMap("unknown session entry key '\(unknown)'") }
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw RemoteControlError.invalidSessionMap("session map JSON is malformed")
        }
        guard envelope.schemaVersion == 1 else { throw RemoteControlError.invalidSessionMap("unsupported schema version") }
        var sessions = Set<String>()
        for entry in envelope.entries {
            guard let uuid = UUID(uuidString: entry.sessionID), uuid.uuidString.lowercased() == entry.sessionID else { throw RemoteControlError.invalidSessionMap("session id is not canonical") }
            guard sessions.insert(entry.sessionID).inserted else { throw RemoteControlError.invalidSessionMap("duplicate session id") }
            _ = try registry.profile(id: entry.profileID)
            try validateContext(paneID: entry.paneID, generation: entry.generation)
        }
        return envelope.entries.sorted { $0.sessionID < $1.sessionID }
    }

    private static func ensurePrivateRoot(_ root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try validateRoot(root)
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        } catch {
            throw RemoteControlError.invalidSessionMap("session map root is unavailable")
        }
    }

    private static func validateRoot(_ root: URL) throws {
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw RemoteControlError.invalidSessionMap("session map root is not a directory") }
        guard value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.invalidSessionMap("session map root permissions must be 0700") }
    }

    private static func validatePrivateRegularFile(_ url: URL, label: String) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
            throw RemoteControlError.invalidSessionMap("\(label) must be a private regular file")
        }
        guard value.st_mode & mode_t(0o777) == 0o600 else { throw RemoteControlError.invalidSessionMap("\(label) permissions must be 0600") }
    }

    private static func validateContext(paneID: String, generation: String) throws {
        let valid: (String) -> Bool = { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 256 && !$0.contains("/") && !$0.contains("\\") && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard valid(paneID) else { throw RemoteControlError.invalidHook("pane id is empty or unsafe") }
        guard valid(generation) else { throw RemoteControlError.invalidHook("generation is empty or unsafe") }
    }
}

public enum RemoteResumePhase: String, Codable, Equatable, Sendable {
    case preSpawn = "prepared"
    case spawnIntent = "spawn_intent"
    case spawnedUnconfirmed = "spawned_unconfirmed"
    case hookObservedAwaitingPID = "hook_observed_awaiting_pid"
    case hookConfirmed = "hook_confirmed"
    case recoveryRequired = "recovery_required"
    case exited
}

public enum RemoteResumeReconcileResolution: String, Codable, Equatable, Sendable {
    case abandon
}

public enum RemotePresenceEvidence: Equatable, Sendable {
    case live
    case absent
    case unavailable
}

public struct RemoteResumeLedgerInspection: Equatable, Sendable {
    public var ownedAttemptIDs: [String]
    public var reconcileRequiredAttemptIDs: [String]
    public var unknownAttemptIDs: [String]

    public init(ownedAttemptIDs: [String], reconcileRequiredAttemptIDs: [String], unknownAttemptIDs: [String]) {
        self.ownedAttemptIDs = ownedAttemptIDs
        self.reconcileRequiredAttemptIDs = reconcileRequiredAttemptIDs
        self.unknownAttemptIDs = unknownAttemptIDs
    }

    public var isClear: Bool {
        ownedAttemptIDs.isEmpty && reconcileRequiredAttemptIDs.isEmpty && unknownAttemptIDs.isEmpty
    }
}

public struct RemoteProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startIdentity: String
    public var executable: String
    public var generation: String

    public init(pid: Int32, startIdentity: String, executable: String, generation: String) {
        self.pid = pid
        self.startIdentity = startIdentity
        self.executable = executable
        self.generation = generation
    }
}

public final class RemoteAdvisoryLock {
    public let url: URL
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit { release() }

    public static func acquire(url: URL, nonBlocking: Bool = true) throws -> RemoteAdvisoryLock {
        try remoteEnsurePrivateLedgerDirectory(url.deletingLastPathComponent(), label: "lock directory")
        var existing = stat()
        if lstat(url.path, &existing) == 0 { _ = try remoteValidatePrivateLedgerFile(url, label: "lock file") }
        else if errno != ENOENT { throw RemoteControlError.ledger("lock file is unavailable") }
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw RemoteControlError.ledger("advisory lock could not be opened") }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1, opened.st_mode & mode_t(0o777) == 0o600 else {
            Darwin.close(descriptor)
            throw RemoteControlError.ledger("lock file must be a private regular file with 0600 permissions")
        }
        guard remoteFlock(descriptor, LOCK_EX | (nonBlocking ? LOCK_NB : 0)) == 0 else {
            Darwin.close(descriptor)
            throw RemoteControlError.ledger("native session is already owned")
        }
        return RemoteAdvisoryLock(url: url, descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        _ = remoteFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

public struct RemoteResumeRecord: Codable, Equatable, Sendable {
    public var attemptID: String
    public var nativeSessionID: String?
    public var profileID: String
    public var generation: String
    public var paneID: String
    public var ownerPID: Int32
    public var expectedArgvSHA256: String
    public var childIdentity: RemoteProcessIdentity?
    public var hookSessionID: String?
    public var phase: RemoteResumePhase
    public var exitStatus: Int32?

    public init(
        attemptID: String,
        nativeSessionID: String?,
        profileID: String,
        generation: String,
        paneID: String,
        ownerPID: Int32,
        expectedArgvSHA256: String = RemoteArgvDigest.unavailable,
        childIdentity: RemoteProcessIdentity?,
        hookSessionID: String?,
        phase: RemoteResumePhase,
        exitStatus: Int32?
    ) {
        self.attemptID = attemptID
        self.nativeSessionID = nativeSessionID
        self.profileID = profileID
        self.generation = generation
        self.paneID = paneID
        self.ownerPID = ownerPID
        self.expectedArgvSHA256 = expectedArgvSHA256
        self.childIdentity = childIdentity
        self.hookSessionID = hookSessionID
        self.phase = phase
        self.exitStatus = exitStatus
    }
}

public final class RemoteResumeLedger {
    public static let maximumRecordBytes = 1_048_576
    public let rootURL: URL
    private var heldLocks: [String: RemoteAdvisoryLock] = [:]
    private let processIdentityForPID: (Int32, String) -> RemoteProcessIdentity?
    private let inspectMatchingHerdrForeground: (RemoteResumeRecord) throws -> RemotePresenceEvidence
    private let durabilityCheckpoint: (RemoteDurableWriteCheckpoint, URL, Data) throws -> Void
    private var attemptsURL: URL { rootURL.appendingPathComponent("attempts", isDirectory: true) }
    private var locksURL: URL { rootURL.appendingPathComponent("locks", isDirectory: true) }

    public init(
        rootURL: URL,
        processIdentityForPID: @escaping (Int32, String) -> RemoteProcessIdentity?,
        inspectMatchingHerdrForeground: @escaping (RemoteResumeRecord) throws -> RemotePresenceEvidence = { _ in .unavailable },
        durabilityCheckpoint: @escaping (RemoteDurableWriteCheckpoint, URL, Data) throws -> Void = { _, _, _ in }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.processIdentityForPID = processIdentityForPID
        self.inspectMatchingHerdrForeground = inspectMatchingHerdrForeground
        self.durabilityCheckpoint = durabilityCheckpoint
    }

    public func prepare(
        attemptID: String,
        nativeSessionID: String?,
        profileID: String,
        generation: String,
        paneID: String,
        ownerPID: Int32,
        expectedArgvSHA256: String = RemoteArgvDigest.unavailable
    ) throws {
        try withStateMutation {
            try validateIdentifier(attemptID, label: "attempt id")
            try validateIdentifier(profileID, label: "profile id")
            try validateIdentifier(generation, label: "generation")
            try validatePaneID(paneID)
            guard ownerPID > 0 else { throw RemoteControlError.ledger("owner pid is invalid") }
            let canonical = try nativeSessionID.map(canonicalUUID)
            try ensureDirectories()
            if let prior = try readRecord(attemptID) {
                guard prior.phase == .preSpawn else { throw ownershipError(prior) }
                try reclaimPreparedIfUnlocked(prior)
            }
            for prior in try records() where prior.phase != .exited && canonical != nil && prior.nativeSessionID == canonical {
                guard prior.phase == .preSpawn else { throw ownershipError(prior) }
                try reclaimPreparedIfUnlocked(prior)
            }
            let lockURL = lockURL(nativeSessionID: canonical, attemptID: attemptID)
            let lock = try RemoteAdvisoryLock.acquire(url: lockURL)
            let record = RemoteResumeRecord(attemptID: attemptID, nativeSessionID: canonical, profileID: profileID, generation: generation, paneID: paneID, ownerPID: ownerPID, expectedArgvSHA256: expectedArgvSHA256, childIdentity: nil, hookSessionID: nil, phase: .preSpawn, exitStatus: nil)
            do {
                try write(record)
                heldLocks[attemptID] = lock
            } catch {
                lock.release()
                try? FileManager.default.removeItem(at: lockURL)
                throw error
            }
        }
    }

    public func markSpawnIntent(attemptID: String) throws {
        try withStateMutation {
            var value = try requiredRecord(attemptID)
            guard value.phase == .preSpawn else { throw RemoteControlError.ledger("attempt is not prepared for spawn_intent") }
            value.phase = .spawnIntent
            try write(value)
        }
    }

    public func recordChild(attemptID: String, identity: RemoteProcessIdentity) throws {
        try withStateMutation {
            var value = try requiredRecord(attemptID)
            guard value.phase == .spawnIntent || value.phase == .hookObservedAwaitingPID else { throw RemoteControlError.ledger("attempt has no durable spawn_intent") }
            guard identity.pid > 0, !identity.startIdentity.isEmpty, identity.executable.hasPrefix("/"), identity.generation == value.generation else { throw RemoteControlError.ledger("child process identity or generation is invalid") }
            value.childIdentity = identity
            value.phase = value.hookSessionID == nil ? .spawnedUnconfirmed : .hookConfirmed
            try write(value)
        }
    }

    public func confirm(nativeSessionID: String, profileID: String, generation: String, paneID: String) throws {
        try withStateMutation {
            let canonical = try canonicalUUID(nativeSessionID)
            var value = try matchingHookRecord(profileID: profileID, generation: generation, paneID: paneID)
            if let existing = value.nativeSessionID {
                guard existing == canonical else { throw RemoteControlError.ledger("hook does not match the expected native session") }
            } else {
                try migrateLock(value: value, nativeSessionID: canonical)
                value.nativeSessionID = canonical
            }
            value.hookSessionID = canonical
            value.phase = value.childIdentity == nil ? .hookObservedAwaitingPID : .hookConfirmed
            try write(value)
            if lockURL(nativeSessionID: nil, attemptID: value.attemptID).path != lockURL(nativeSessionID: value.nativeSessionID, attemptID: value.attemptID).path {
                try? FileManager.default.removeItem(at: lockURL(nativeSessionID: nil, attemptID: value.attemptID))
            }
        }
    }

    public func validateHookContext(nativeSessionID: String, profileID: String, generation: String, paneID: String) throws {
        try withStateMutation {
            let canonical = try canonicalUUID(nativeSessionID)
            let value = try matchingHookRecord(profileID: profileID, generation: generation, paneID: paneID)
            if let existing = value.nativeSessionID, existing != canonical { throw RemoteControlError.ledger("hook does not match the expected native session") }
        }
    }

    public func markExited(attemptID: String, status: Int32) throws {
        try withStateMutation {
            var value = try requiredRecord(attemptID)
            guard value.phase == .hookConfirmed else { throw RemoteControlError.ledger("only hook_confirmed children can exit cleanly") }
            value.phase = .exited
            value.exitStatus = status
            try write(value)
            releaseOwnership(value)
        }
    }

    public func rollbackPrepared(attemptID: String) throws {
        try withStateMutation {
            let value = try requiredRecord(attemptID)
            guard value.phase == .preSpawn else { throw RemoteControlError.ledger("only prepared state is safely retryable") }
            try remove(value)
        }
    }

    public func cancelSynchronousSpawnFailure(attemptID: String, ownerPID: Int32) throws {
        try withStateMutation {
            let value = try requiredRecord(attemptID)
            guard value.phase == .spawnIntent, value.ownerPID == ownerPID, heldLocks[attemptID] != nil else {
                throw RemoteControlError.ledger("spawn_intent is no longer safely cancelable")
            }
            try remove(value)
        }
    }

    public func markRecoveryRequired(attemptID: String) throws {
        try withStateMutation {
            var value = try requiredRecord(attemptID)
            guard [.spawnIntent, .spawnedUnconfirmed, .hookObservedAwaitingPID, .hookConfirmed, .recoveryRequired].contains(value.phase) else {
                throw RemoteControlError.ledger("only post-intent state can require recovery")
            }
            value.phase = .recoveryRequired
            try write(value)
        }
    }

    public func reconcile(attemptID: String, resolution: RemoteResumeReconcileResolution) throws {
        try withStateMutation {
            var value = try requiredRecord(attemptID)
            guard [.spawnIntent, .spawnedUnconfirmed, .hookObservedAwaitingPID, .hookConfirmed, .recoveryRequired].contains(value.phase), resolution == .abandon else {
                throw RemoteControlError.ledger("only an ambiguous spawned child can be reconciled")
            }
            let exactChildIsLive = value.childIdentity.flatMap { expected in processIdentityForPID(expected.pid, expected.generation).map { $0 == expected } } ?? false
            guard !exactChildIsLive else { throw RemoteControlError.ledger("live child prevents reconcile") }
            let foreground: RemotePresenceEvidence
            do { foreground = try inspectMatchingHerdrForeground(value) }
            catch { throw RemoteControlError.ledger("foreground absence scan is unavailable") }
            guard foreground == .absent else {
                throw RemoteControlError.ledger(foreground == .live ? "live child prevents reconcile" : "foreground absence is unavailable")
            }
            value.phase = .exited
            value.exitStatus = nil
            try write(value)
            releaseOwnership(value)
        }
    }

    public func record(attemptID: String) throws -> RemoteResumeRecord? {
        try validateIdentifier(attemptID, label: "attempt id")
        guard try remoteValidatePrivateLedgerDirectoryIfPresent(rootURL, label: "ledger root") else { return nil }
        return try readRecord(attemptID)
    }

    public func hasAmbiguousAttempt() throws -> Bool {
        guard try remoteValidatePrivateLedgerDirectoryIfPresent(rootURL, label: "ledger root") else { return false }
        return try records().contains { [.spawnIntent, .spawnedUnconfirmed, .hookObservedAwaitingPID, .hookConfirmed, .recoveryRequired].contains($0.phase) }
    }

    public func hasOutstandingOwnership(nativeSessionIDs: [String]) throws -> Bool {
        let expected = Set(try nativeSessionIDs.map(canonicalUUID))
        guard try remoteValidatePrivateLedgerDirectoryIfPresent(rootURL, label: "ledger root") else { return false }
        if try records().contains(where: { $0.phase != .exited && $0.nativeSessionID.map(expected.contains) == true }) { return true }
        return expected.contains { lockExists(nativeSessionID: $0) }
    }

    public func inspectHealth() throws -> RemoteResumeLedgerInspection {
        guard try remoteValidatePrivateLedgerDirectoryIfPresent(rootURL, label: "ledger root") else {
            return RemoteResumeLedgerInspection(ownedAttemptIDs: [], reconcileRequiredAttemptIDs: [], unknownAttemptIDs: [])
        }
        var owned: [String] = []
        var reconcileRequired: [String] = []
        var unknown: [String] = []
        for record in try records().filter({ $0.phase != .exited }).sorted(by: { $0.attemptID < $1.attemptID }) {
            if record.phase == .hookConfirmed,
               let expected = record.childIdentity,
               processIdentityForPID(expected.pid, expected.generation) == expected {
                owned.append(record.attemptID)
                continue
            }
            let foreground: RemotePresenceEvidence
            do { foreground = try inspectMatchingHerdrForeground(record) }
            catch {
                unknown.append(record.attemptID)
                continue
            }
            if foreground == .absent {
                reconcileRequired.append(record.attemptID)
            } else {
                unknown.append(record.attemptID)
            }
        }
        return RemoteResumeLedgerInspection(ownedAttemptIDs: owned, reconcileRequiredAttemptIDs: reconcileRequired, unknownAttemptIDs: unknown)
    }

    public func lockExists(nativeSessionID: String) -> Bool {
        guard let uuid = UUID(uuidString: nativeSessionID) else { return true }
        return lstatExists(locksURL.appendingPathComponent("\(uuid.uuidString.lowercased()).lock"))
    }

    private func readRecord(_ attemptID: String) throws -> RemoteResumeRecord? {
        try validateIdentifier(attemptID, label: "attempt id")
        let url = recordURL(attemptID)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw RemoteControlError.ledger("attempt record is unreadable")
        }
        _ = try remoteValidatePrivateLedgerFile(url, label: "attempt record")
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw RemoteControlError.ledger("attempt record is unreadable") }
        guard data.count <= Self.maximumRecordBytes else { throw RemoteControlError.ledger("attempt record exceeds the byte bound") }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteControlError.ledger("attempt record must be an object") }
            object = decoded
        } catch let error as RemoteControlError { throw error }
        catch { throw RemoteControlError.ledger("attempt record is corrupt") }
        let keys = Set(["attemptID", "nativeSessionID", "profileID", "generation", "paneID", "ownerPID", "expectedArgvSHA256", "childIdentity", "hookSessionID", "phase", "exitStatus"])
        guard Set(object.keys).subtracting(keys).isEmpty else { throw RemoteControlError.ledger("attempt record contains unknown keys") }
        if let child = object["childIdentity"] as? [String: Any], Set(child.keys) != Set(["pid", "startIdentity", "executable", "generation"]) {
            throw RemoteControlError.ledger("attempt record child identity keys are invalid")
        }
        let value: RemoteResumeRecord
        do { value = try JSONDecoder().decode(RemoteResumeRecord.self, from: data) }
        catch { throw RemoteControlError.ledger("attempt record is corrupt") }
        try validateRecord(value, expectedAttemptID: attemptID)
        return value
    }

    private func requiredRecord(_ attemptID: String) throws -> RemoteResumeRecord {
        guard let value = try readRecord(attemptID) else { throw RemoteControlError.ledger("attempt record is missing") }
        return value
    }

    private func matchingHookRecord(profileID: String, generation: String, paneID: String) throws -> RemoteResumeRecord {
        let active = try records().filter { [.spawnIntent, .spawnedUnconfirmed, .hookObservedAwaitingPID, .hookConfirmed].contains($0.phase) }
        let matching = active.filter { $0.profileID == profileID && $0.generation == generation && $0.paneID == paneID }
        guard matching.count == 1 else { throw RemoteControlError.ledger("hook does not match one supervised child") }
        return matching[0]
    }

    private func records() throws -> [RemoteResumeRecord] {
        guard try remoteValidatePrivateLedgerDirectoryIfPresent(attemptsURL, label: "attempt records directory") else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: attemptsURL, includingPropertiesForKeys: nil).map { url in
                guard url.pathExtension == "json" else { throw RemoteControlError.ledger("attempt records contain an unexpected entry") }
                let attemptID = url.deletingPathExtension().lastPathComponent
                guard let value = try readRecord(attemptID) else { throw RemoteControlError.ledger("attempt record disappeared during read") }
                return value
            }
        } catch let error as RemoteControlError { throw error }
        catch { throw RemoteControlError.ledger("attempt records are corrupt") }
    }

    private func ensureDirectories() throws {
        try remoteEnsurePrivateLedgerDirectory(rootURL, label: "ledger root")
        try remoteEnsurePrivateLedgerDirectory(attemptsURL, label: "attempt records directory")
        try remoteEnsurePrivateLedgerDirectory(locksURL, label: "native locks directory")
    }

    private func write(_ value: RemoteResumeRecord) throws {
        do {
            try validateRecord(value, expectedAttemptID: value.attemptID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try RemoteDurableFile.write(encoder.encode(value), to: recordURL(value.attemptID), checkpoint: durabilityCheckpoint)
        } catch { throw RemoteControlError.ledger("attempt state could not be persisted") }
    }

    private func remove(_ value: RemoteResumeRecord) throws {
        do { try FileManager.default.removeItem(at: recordURL(value.attemptID)) }
        catch { throw RemoteControlError.ledger("prepared rollback failed") }
        releaseOwnership(value)
    }

    private func reclaimPreparedIfUnlocked(_ value: RemoteResumeRecord) throws {
        if heldLocks[value.attemptID] != nil { throw RemoteControlError.ledger("native session is already owned") }
        let url = lockURL(nativeSessionID: value.nativeSessionID, attemptID: value.attemptID)
        let reclaimed = try RemoteAdvisoryLock.acquire(url: url)
        reclaimed.release()
        try remove(value)
    }

    private func migrateLock(value: RemoteResumeRecord, nativeSessionID: String) throws {
        let provisional = lockURL(nativeSessionID: nil, attemptID: value.attemptID)
        let native = lockURL(nativeSessionID: nativeSessionID, attemptID: value.attemptID)
        let status = provisional.path.withCString { source in native.path.withCString { destination in remoteLink(source, destination) } }
        guard status == 0 else { throw RemoteControlError.ledger("native session is already owned") }
    }

    private func releaseOwnership(_ value: RemoteResumeRecord) {
        heldLocks.removeValue(forKey: value.attemptID)?.release()
        try? FileManager.default.removeItem(at: lockURL(nativeSessionID: value.nativeSessionID, attemptID: value.attemptID))
        try? FileManager.default.removeItem(at: lockURL(nativeSessionID: nil, attemptID: value.attemptID))
    }

    private func withStateMutation<T>(_ operation: () throws -> T) throws -> T {
        try remoteEnsurePrivateLedgerDirectory(rootURL, label: "ledger root")
        let stateLock = try RemoteAdvisoryLock.acquire(url: rootURL.appendingPathComponent("ledger-state.lock"), nonBlocking: false)
        defer { stateLock.release() }
        return try operation()
    }

    private func recordURL(_ attemptID: String) -> URL { attemptsURL.appendingPathComponent("\(attemptID).json") }
    private func lockURL(nativeSessionID: String?, attemptID: String) -> URL { locksURL.appendingPathComponent("\(nativeSessionID ?? "attempt-\(attemptID)").lock") }

    private func validateIdentifier(_ value: String, label: String) throws {
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else { throw RemoteControlError.ledger("unsafe \(label)") }
    }

    private func validatePaneID(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$", options: .regularExpression) != nil else { throw RemoteControlError.ledger("unsafe pane id") }
    }

    private func validateRecord(_ value: RemoteResumeRecord, expectedAttemptID: String) throws {
        guard value.attemptID == expectedAttemptID else { throw RemoteControlError.ledger("attempt record id does not match its filename") }
        try validateIdentifier(value.attemptID, label: "attempt id")
        try validateIdentifier(value.profileID, label: "profile id")
        try validateIdentifier(value.generation, label: "generation")
        try validatePaneID(value.paneID)
        guard value.ownerPID > 0 else { throw RemoteControlError.ledger("attempt record owner pid is invalid") }
        guard value.expectedArgvSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RemoteControlError.ledger("attempt record argv digest is invalid")
        }
        let native = try value.nativeSessionID.map(canonicalUUID)
        let hook = try value.hookSessionID.map(canonicalUUID)
        guard native == value.nativeSessionID, hook == value.hookSessionID, hook == nil || hook == native else { throw RemoteControlError.ledger("attempt record native session evidence is invalid") }
        if let child = value.childIdentity {
            guard child.pid > 0, safeLedgerText(child.startIdentity, maximum: 512), child.generation == value.generation, child.executable.hasPrefix("/"), URL(fileURLWithPath: child.executable).standardizedFileURL.path == child.executable else {
                throw RemoteControlError.ledger("attempt record child identity is invalid")
            }
        }
        let stateIsValid: Bool
        switch value.phase {
        case .preSpawn, .spawnIntent:
            stateIsValid = value.childIdentity == nil && value.hookSessionID == nil && value.exitStatus == nil
        case .spawnedUnconfirmed:
            stateIsValid = value.childIdentity != nil && value.hookSessionID == nil && value.exitStatus == nil
        case .hookObservedAwaitingPID:
            stateIsValid = value.childIdentity == nil && value.hookSessionID != nil && value.exitStatus == nil
        case .hookConfirmed:
            stateIsValid = value.childIdentity != nil && value.hookSessionID != nil && value.exitStatus == nil
        case .recoveryRequired:
            stateIsValid = value.exitStatus == nil
        case .exited:
            stateIsValid = true
        }
        guard stateIsValid else { throw RemoteControlError.ledger("attempt record phase evidence is invalid") }
    }

    private func safeLedgerText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum && !value.contains("/") && !value.contains("\\") && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func lstatExists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }

    private func canonicalUUID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value) else { throw RemoteControlError.ledger("invalid native session UUID") }
        return uuid.uuidString.lowercased()
    }

    private func ownershipError(_ value: RemoteResumeRecord) -> RemoteControlError {
        [.spawnIntent, .spawnedUnconfirmed, .hookObservedAwaitingPID, .hookConfirmed, .recoveryRequired].contains(value.phase)
            ? .ledger("ambiguous native session requires explicit reconcile")
            : .ledger("native session is already owned")
    }
}

public enum RemoteSupervisedSpawnFailure: Error, Equatable, Sendable {
    case beforeKernel
    case afterKernel
}

public struct RemoteSupervisedChild {
    public var identity: RemoteProcessIdentity
    public var wait: () throws -> Int32
    public var terminate: () -> Void
    public var finish: () -> Void

    public init(identity: RemoteProcessIdentity, wait: @escaping () throws -> Int32, terminate: @escaping () -> Void, finish: @escaping () -> Void = {}) {
        self.identity = identity
        self.wait = wait
        self.terminate = terminate
        self.finish = finish
    }
}

public struct RemoteChildSupervisor {
    public let ledger: RemoteResumeLedger
    private let spawn: (RemoteProcessRequest) throws -> RemoteSupervisedChild

    public init(ledger: RemoteResumeLedger, spawn: @escaping (RemoteProcessRequest) throws -> RemoteSupervisedChild) {
        self.ledger = ledger
        self.spawn = spawn
    }

    public func run(request: RemoteProcessRequest, attemptID: String, nativeSessionID: String?, profileID: String, generation: String, paneID: String, ownerPID: Int32) throws -> Int32 {
        try ledger.prepare(
            attemptID: attemptID,
            nativeSessionID: nativeSessionID,
            profileID: profileID,
            generation: generation,
            paneID: paneID,
            ownerPID: ownerPID,
            expectedArgvSHA256: RemoteArgvDigest.sha256([request.executable] + request.arguments)
        )
        try ledger.markSpawnIntent(attemptID: attemptID)
        let child: RemoteSupervisedChild
        do {
            child = try spawn(request)
        } catch RemoteSupervisedSpawnFailure.beforeKernel {
            do { try ledger.cancelSynchronousSpawnFailure(attemptID: attemptID, ownerPID: ownerPID) }
            catch { throw RemoteControlError.resume("spawn failed and durable intent remains ambiguous") }
            throw RemoteControlError.resume("child spawn failed before a kernel child existed")
        } catch {
            try? ledger.markRecoveryRequired(attemptID: attemptID)
            throw RemoteControlError.resume("kernel child may exist; durable intent remains ambiguous")
        }
        defer { child.finish() }
        do { try ledger.recordChild(attemptID: attemptID, identity: child.identity) }
        catch {
            try? ledger.markRecoveryRequired(attemptID: attemptID)
            throw RemoteControlError.resume("child spawned but its exact process identity is ambiguous")
        }
        let status: Int32
        do { status = try child.wait() }
        catch {
            try? ledger.markRecoveryRequired(attemptID: attemptID)
            throw RemoteControlError.resume("child wait failed; spawned state remains ambiguous")
        }
        guard try ledger.record(attemptID: attemptID)?.phase == .hookConfirmed else {
            try? ledger.markRecoveryRequired(attemptID: attemptID)
            throw RemoteControlError.resume("child exited without hook confirmation; state is ambiguous")
        }
        do { try ledger.markExited(attemptID: attemptID, status: status) }
        catch {
            try? ledger.markRecoveryRequired(attemptID: attemptID)
            throw RemoteControlError.resume("confirmed child exited but durable ownership requires recovery")
        }
        return status
    }
}

public enum RemoteShellBootstrap {
    public static func render(zshExecutable: String, realZDOTDIR: String, ouroZDOTDIR: String, helperPath: String, configPath: String, sessionMapPath: String) throws -> [String: Data] {
        for path in [zshExecutable, realZDOTDIR, ouroZDOTDIR, helperPath, configPath, sessionMapPath] where !path.hasPrefix("/") { throw RemoteControlError.invalidConfiguration("absolute path required: \(path)") }
        let zshenv = "source \(quote(realZDOTDIR + "/.zshenv")) 2>/dev/null || true\n"
        let zshrc = """
        source \(quote(realZDOTDIR + "/.zprofile")) 2>/dev/null || true
        source \(quote(realZDOTDIR + "/.zshrc")) 2>/dev/null || true
        function copilot {
          \(quote(helperPath)) dispatch --config \(quote(configPath)) --session-map \(quote(sessionMapPath)) -- "$@"
        }
        \(quote(helperPath)) wrapper-handshake --helper \(quote(helperPath)) --config \(quote(configPath)) --session-map \(quote(sessionMapPath)) --zsh \(quote(zshExecutable)) --zdotdir \(quote(ouroZDOTDIR)) --generation "${HERDR_SESSION:-}" --pane "${HERDR_PANE_ID:-}" --shell-pid "$$" --function-body "${functions[copilot]}" >/dev/null 2>&1 || true

        """
        return [".zshenv": Data(zshenv.utf8), ".zshrc": Data(zshrc.utf8)]
    }

    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
