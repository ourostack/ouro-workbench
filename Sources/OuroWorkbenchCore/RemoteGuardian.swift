import Darwin
import Foundation

public struct RemoteExpectedPane: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var paneID: String
    public var nativeSessionID: String
    public var profileID: String
    public var githubLogin: String

    public init(workspaceID: String, paneID: String, nativeSessionID: String, profileID: String, githubLogin: String) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.nativeSessionID = nativeSessionID
        self.profileID = profileID
        self.githubLogin = githubLogin
    }
}

public struct RemoteGenerationManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sourceSession: String
    public var herdrVersion: String
    public var expectedPanes: [RemoteExpectedPane]
    public var acknowledgedEmpty: Bool

    public init(schemaVersion: Int, sourceSession: String, herdrVersion: String, expectedPanes: [RemoteExpectedPane], acknowledgedEmpty: Bool = false) {
        self.schemaVersion = schemaVersion
        self.sourceSession = sourceSession
        self.herdrVersion = herdrVersion
        self.expectedPanes = expectedPanes
        self.acknowledgedEmpty = acknowledgedEmpty
    }
}

public struct RemotePaneInventory: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var paneID: String
    public var nativeSessionID: String?
    public var profileID: String?
    public var githubLogin: String?
    public var generation: String
    public var childPresent: Bool
    public var hookObserved: Bool
    public var wrapperReady: Bool
    public var foregroundProcess: RemoteProcessIdentity?

    public init(
        workspaceID: String,
        paneID: String,
        nativeSessionID: String?,
        profileID: String?,
        githubLogin: String?,
        generation: String,
        childPresent: Bool,
        hookObserved: Bool,
        wrapperReady: Bool,
        foregroundProcess: RemoteProcessIdentity?
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.nativeSessionID = nativeSessionID
        self.profileID = profileID
        self.githubLogin = githubLogin
        self.generation = generation
        self.childPresent = childPresent
        self.hookObserved = hookObserved
        self.wrapperReady = wrapperReady
        self.foregroundProcess = foregroundProcess
    }
}

public struct RemoteHerdrInventory: Codable, Equatable, Sendable {
    public var version: String
    public var panes: [RemotePaneInventory]

    public init(version: String, panes: [RemotePaneInventory]) {
        self.version = version
        self.panes = panes
    }
}

public enum RemoteHerdrProbe: Equatable, Sendable {
    case absent
    case running(RemoteHerdrInventory)
    case degraded(String)
}

public struct RemoteHerdrBootRequest: Equatable, Sendable {
    public var sessionName: String
    public var stagedSessionURL: URL
    public var expectedVersion: String
    public var resumeAgentsOnRestore: Bool

    public init(sessionName: String, stagedSessionURL: URL, expectedVersion: String, resumeAgentsOnRestore: Bool) {
        self.sessionName = sessionName
        self.stagedSessionURL = stagedSessionURL
        self.expectedVersion = expectedVersion
        self.resumeAgentsOnRestore = resumeAgentsOnRestore
    }
}

public struct RemotePaneResumeCommand: Equatable, Sendable {
    public var paneID: String
    public var helperPath: String
    public var arguments: [String]

    public init(paneID: String, helperPath: String, arguments: [String]) {
        self.paneID = paneID
        self.helperPath = helperPath
        self.arguments = arguments
    }

    public var shellCommand: String {
        ([RemoteShellBootstrap.quote(helperPath)] + arguments.map(RemoteShellBootstrap.quote)).joined(separator: " ")
    }
}

public enum RemotePaneResumeFailure: Error, LocalizedError, Equatable, Sendable {
    case preSpawn(String)
    case postIntent(String)

    public var errorDescription: String? {
        switch self {
        case let .preSpawn(detail): "Resume queue failed before spawn: \(detail)"
        case let .postIntent(detail): "Resume queue outcome is ambiguous after invocation: \(detail)"
        }
    }
}

public enum RemoteWorkerIntegrity {
    public static func matches(
        recordedIdentity: RemoteProcessIdentity,
        liveIdentity: RemoteProcessIdentity?,
        herdrPID: Int32,
        herdrArgv: [String]?,
        expectedExecutable: String,
        expectedArguments: [String],
        actualGitHubLogin: String?,
        expectedGitHubLogin: String
    ) -> Bool {
        let resolvedExecutable = URL(fileURLWithPath: expectedExecutable).resolvingSymlinksInPath().standardizedFileURL.path
        return recordedIdentity.pid > 0
            && liveIdentity == recordedIdentity
            && herdrPID == recordedIdentity.pid
            && recordedIdentity.executable == resolvedExecutable
            && herdrArgv == [expectedExecutable] + expectedArguments
            && actualGitHubLogin == expectedGitHubLogin
    }
}

public enum RemoteHerdrServerProcess {
    public static func sessionName(executable: String, argv: [String]?, expectedExecutable: String) -> String? {
        let resolvedExecutable = URL(fileURLWithPath: expectedExecutable).resolvingSymlinksInPath().standardizedFileURL.path
        guard executable == resolvedExecutable,
              let argv,
              argv.count == 4,
              argv[0] == expectedExecutable,
              argv[1] == "--session",
              argv[2].count <= 128,
              argv[2].range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              argv[3] == "server"
        else { return nil }
        return argv[2]
    }
}

public enum RemoteManagedHerdrProcess {
    public static func sessionName(executable: String, argv: [String]?, expectedExecutable: String) -> String? {
        guard let session = RemoteHerdrServerProcess.sessionName(executable: executable, argv: argv, expectedExecutable: expectedExecutable),
              session.hasPrefix("ouro-"),
              session.range(of: "^ouro-[A-Za-z0-9][A-Za-z0-9._-]{0,122}$", options: .regularExpression) != nil
        else { return nil }
        return session
    }
}

public struct RemoteActiveRuntime: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generation: String
    public var sessionName: String
    public var socketPath: String
    public var expectedInventoryPath: String

    public init(schemaVersion: Int, generation: String, sessionName: String, socketPath: String, expectedInventoryPath: String) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.sessionName = sessionName
        self.socketPath = socketPath
        self.expectedInventoryPath = expectedInventoryPath
    }
}

struct RemoteRelayExpectedInventory: Codable, Equatable {
    struct Pane: Codable, Equatable {
        var paneID: String
        var nativeSessionID: String
        var profileID: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case nativeSessionID = "native_session_id"
            case profileID = "profile_id"
        }
    }

    var version = 1
    var generation: String
    var acknowledgedEmpty: Bool
    var panes: [Pane]

    enum CodingKeys: String, CodingKey {
        case version
        case generation
        case acknowledgedEmpty = "acknowledged_empty"
        case panes
    }
}

public enum RemoteGuardianResult: Equatable, Sendable {
    case alreadyRunning(String)
    case promoted(String)
}

public struct RemoteGuardian {
    public static let maximumControlFileBytes = 65_536
    public let rootURL: URL
    public let helperPath: String
    public let ledger: RemoteResumeLedger
    private let probe: (String) throws -> RemoteHerdrProbe
    private let listManagedSessions: () throws -> [String]
    private let listManagedProcessSessions: () throws -> [String]
    private let boot: (RemoteHerdrBootRequest) throws -> RemoteHerdrInventory
    private let resume: (RemotePaneResumeCommand) throws -> RemoteHerdrInventory
    private let stop: (String) throws -> RemoteHerdrProbe
    private let reactivate: (RemoteActiveRuntime) throws -> RemoteHerdrProbe
    private let nativeSessionOwnerExists: (String) -> Bool
    private let makeGenerationName: () -> String
    private let snapshotLstat: (String, UnsafeMutablePointer<stat>) -> Int32

    public init(
        rootURL: URL,
        helperPath: String,
        ledger: RemoteResumeLedger,
        probe: @escaping (String) throws -> RemoteHerdrProbe,
        listManagedSessions: @escaping () throws -> [String],
        listManagedProcessSessions: @escaping () throws -> [String],
        boot: @escaping (RemoteHerdrBootRequest) throws -> RemoteHerdrInventory,
        resume: @escaping (RemotePaneResumeCommand) throws -> RemoteHerdrInventory,
        stop: @escaping (String) throws -> RemoteHerdrProbe,
        reactivate: @escaping (RemoteActiveRuntime) throws -> RemoteHerdrProbe,
        nativeSessionOwnerExists: @escaping (String) -> Bool,
        makeGenerationName: @escaping () -> String
    ) {
        self.init(
            rootURL: rootURL,
            helperPath: helperPath,
            ledger: ledger,
            probe: probe,
            listManagedSessions: listManagedSessions,
            listManagedProcessSessions: listManagedProcessSessions,
            boot: boot,
            resume: resume,
            stop: stop,
            reactivate: reactivate,
            nativeSessionOwnerExists: nativeSessionOwnerExists,
            makeGenerationName: makeGenerationName,
            snapshotLstat: { path, value in path.withCString { Darwin.lstat($0, value) } }
        )
    }

    init(
        rootURL: URL,
        helperPath: String,
        ledger: RemoteResumeLedger,
        probe: @escaping (String) throws -> RemoteHerdrProbe,
        listManagedSessions: @escaping () throws -> [String],
        listManagedProcessSessions: @escaping () throws -> [String],
        boot: @escaping (RemoteHerdrBootRequest) throws -> RemoteHerdrInventory,
        resume: @escaping (RemotePaneResumeCommand) throws -> RemoteHerdrInventory,
        stop: @escaping (String) throws -> RemoteHerdrProbe,
        reactivate: @escaping (RemoteActiveRuntime) throws -> RemoteHerdrProbe,
        nativeSessionOwnerExists: @escaping (String) -> Bool,
        makeGenerationName: @escaping () -> String,
        snapshotLstat: @escaping (String, UnsafeMutablePointer<stat>) -> Int32
    ) {
        self.rootURL = rootURL
        self.helperPath = helperPath
        self.ledger = ledger
        self.probe = probe
        self.listManagedSessions = listManagedSessions
        self.listManagedProcessSessions = listManagedProcessSessions
        self.boot = boot
        self.resume = resume
        self.stop = stop
        self.reactivate = reactivate
        self.nativeSessionOwnerExists = nativeSessionOwnerExists
        self.makeGenerationName = makeGenerationName
        self.snapshotLstat = snapshotLstat
    }

    public func tick() throws -> RemoteGuardianResult {
        try validatePrivateDirectory(rootURL, label: "guardian root")
        guard helperPath.hasPrefix("/"), URL(fileURLWithPath: helperPath).standardizedFileURL.path == helperPath else {
            throw RemoteControlError.guardian("absolute normalized helper path is required")
        }
        let guardianLock: RemoteAdvisoryLock
        do { guardianLock = try RemoteAdvisoryLock.acquire(url: rootURL.appendingPathComponent("guardian.lock")) }
        catch { throw RemoteControlError.guardian("guardian is already running") }
        defer { guardianLock.release() }

        let lastKnownGood = try RemoteLastKnownGoodStore(rootURL: rootURL).loadCurrent()
        let manifest = lastKnownGood.manifest.generationManifest
        try validate(manifest)
        let priorRuntime = try loadActiveRuntime()
        if let priorRuntime {
            switch try probe(priorRuntime.sessionName) {
            case .absent:
                break
            case let .degraded(detail):
                throw RemoteControlError.guardian("active generation is degraded: \(detail)")
            case let .running(inventory):
                guard finalInventory(inventory, matches: manifest, generation: priorRuntime.generation) else {
                    throw RemoteControlError.guardian("active generation inventory is not exact")
                }
                try validateExpectedInventory(priorRuntime, matches: manifest)
                return .alreadyRunning(priorRuntime.generation)
            }
        }

        let managed: [String]
        do { managed = try listManagedSessions() }
        catch { throw RemoteControlError.guardian("prior managed session enumeration failed") }
        for name in Set(managed) {
            try validateName(name)
            switch try probe(name) {
            case .absent:
                continue
            case .running, .degraded:
                throw RemoteControlError.guardian("prior managed session '\(name)' is not proven dead")
            }
        }
        let managedProcesses: [String]
        do { managedProcesses = try listManagedProcessSessions() }
        catch { throw RemoteControlError.guardian("prior managed process enumeration failed") }
        for name in Set(managedProcesses) {
            try validateName(name)
            throw RemoteControlError.guardian("prior managed process '\(name)' is not proven dead")
        }
        let nativeIDs = manifest.expectedPanes.map(\.nativeSessionID)
        if try ledger.hasAmbiguousAttempt()
            || ledger.hasOutstandingOwnership(nativeSessionIDs: nativeIDs)
            || nativeIDs.contains(where: nativeSessionOwnerExists) {
            throw RemoteControlError.guardian("native session ownership blocks automatic restore")
        }

        let generation = makeGenerationName()
        try validateName(generation)
        let source = lastKnownGood.snapshotURL
        let staged = rootURL.appendingPathComponent("sessions/\(generation)", isDirectory: true)
        let quarantine = rootURL.appendingPathComponent("quarantine/\(generation)", isDirectory: true)
        try validateSnapshot(source)
        guard !FileManager.default.fileExists(atPath: staged.path), !FileManager.default.fileExists(atPath: quarantine.path) else {
            throw RemoteControlError.guardian("staged generation name already exists")
        }
        do {
            try copySnapshot(source: source, staged: staged)
            try validateSnapshot(staged)
            try lastKnownGood.verifyCopiedSnapshot(at: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }

        let bootInventory: RemoteHerdrInventory
        do {
            bootInventory = try boot(RemoteHerdrBootRequest(sessionName: generation, stagedSessionURL: staged, expectedVersion: manifest.herdrVersion, resumeAgentsOnRestore: false))
            guard structuralInventory(bootInventory, matches: manifest, generation: generation) else {
                throw RemoteControlError.guardian("structural boot inventory is invalid")
            }
        } catch {
            return try failBeforeSpawn(error, generation: generation, staged: staged, quarantine: quarantine, priorRuntime: priorRuntime, manifest: manifest)
        }

        var inventory = bootInventory
        var completed = 0
        for expected in manifest.expectedPanes {
            do {
                inventory = try resume(RemotePaneResumeCommand(
                    paneID: expected.paneID,
                    helperPath: helperPath,
                    arguments: ["resume", "--uuid", expected.nativeSessionID, "--profile", expected.profileID, "--generation", generation, "--pane", expected.paneID]
                ))
            } catch let error as RemotePaneResumeFailure {
                if case .preSpawn = error, completed == 0 {
                    return try failBeforeSpawn(error, generation: generation, staged: staged, quarantine: quarantine, priorRuntime: priorRuntime, manifest: manifest)
                }
                return try failAfterPossibleSpawn(error, generation: generation, staged: staged)
            } catch {
                return try failAfterPossibleSpawn(error, generation: generation, staged: staged)
            }
            guard partialInventory(inventory, matches: manifest, generation: generation, completedCount: completed + 1) else {
                return try failAfterPossibleSpawn(RemoteControlError.guardian("resume verification failed for pane \(expected.paneID)"), generation: generation, staged: staged)
            }
            completed += 1
        }
        let inventoryURL = staged.appendingPathComponent("expected-inventory.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let relayInventory = RemoteRelayExpectedInventory(
                generation: generation,
                acknowledgedEmpty: manifest.acknowledgedEmpty,
                panes: manifest.expectedPanes.map {
                    RemoteRelayExpectedInventory.Pane(
                        paneID: $0.paneID,
                        nativeSessionID: $0.nativeSessionID,
                        profileID: $0.profileID
                    )
                }
            )
            try RemoteDurableFile.write(encoder.encode(relayInventory), to: inventoryURL)
            let runtime = RemoteActiveRuntime(
                schemaVersion: 1,
                generation: generation,
                sessionName: generation,
                socketPath: staged.appendingPathComponent("herdr.sock").path,
                expectedInventoryPath: inventoryURL.path
            )
            try publish(runtime)
        } catch {
            return try failAfterPossibleSpawn(error, generation: generation, staged: staged)
        }
        return .promoted(generation)
    }

    private func failBeforeSpawn(
        _ error: Error,
        generation: String,
        staged: URL,
        quarantine: URL,
        priorRuntime: RemoteActiveRuntime?,
        manifest: RemoteGenerationManifest
    ) throws -> RemoteGuardianResult {
        let stopped: RemoteHerdrProbe
        do { stopped = try stop(generation) }
        catch { return try failAfterPossibleSpawn(RemoteControlError.guardian("staged stop could not be verified"), generation: generation, staged: staged) }
        guard stopped == .absent else {
            return try failAfterPossibleSpawn(RemoteControlError.guardian("staged stop did not prove both sockets and process absent"), generation: generation, staged: staged)
        }
        do {
            try FileManager.default.createDirectory(at: quarantine.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: staged, to: quarantine)
        } catch {
            return try failAfterPossibleSpawn(RemoteControlError.guardian("quarantine failed"), generation: generation, staged: staged)
        }
        guard let priorRuntime else {
            throw RemoteControlError.guardian("staged generation failed before spawn; availability unavailable: \(safeDetail(error))")
        }
        do {
            switch try reactivate(priorRuntime) {
            case let .running(inventory) where finalInventory(inventory, matches: manifest, generation: priorRuntime.generation):
                return try stagedFailure(error)
            case .absent, .degraded, .running:
                try writeRecoveryMarker(at: quarantine, generation: generation, detail: "prior generation reactivation was not exact")
                throw RemoteControlError.guardian("staged generation failed and prior availability requires recovery")
            }
        } catch let control as RemoteControlError {
            throw control
        } catch {
            try? writeRecoveryMarker(at: quarantine, generation: generation, detail: "prior generation reactivation failed")
            throw RemoteControlError.guardian("staged generation failed and prior availability requires recovery")
        }
    }

    private func stagedFailure(_ error: Error) throws -> RemoteGuardianResult {
        throw RemoteControlError.guardian("staged generation failed before spawn; prior generation reactivated: \(safeDetail(error))")
    }

    private func failAfterPossibleSpawn(_ error: Error, generation: String, staged: URL) throws -> RemoteGuardianResult {
        try writeRecoveryMarker(at: staged, generation: generation, detail: safeDetail(error))
        throw RemoteControlError.guardian("staged generation owns possible children; recovery required")
    }

    private func validate(_ manifest: RemoteGenerationManifest) throws {
        var sessions = Set<String>()
        var panes = Set<String>()
        for pane in manifest.expectedPanes {
            guard let uuid = UUID(uuidString: pane.nativeSessionID), uuid.uuidString.lowercased() == pane.nativeSessionID else { throw RemoteControlError.guardian("snapshot contains an invalid native session UUID") }
            guard sessions.insert(pane.nativeSessionID).inserted else { throw RemoteControlError.guardian("snapshot contains a duplicate native session UUID") }
            guard panes.insert(pane.paneID).inserted, safeText(pane.workspaceID), safeText(pane.paneID), safeText(pane.profileID), safeText(pane.githubLogin) else {
                throw RemoteControlError.guardian("snapshot pane identity is invalid")
            }
        }
    }

    private func loadActiveRuntime() throws -> RemoteActiveRuntime? {
        let url = rootURL.appendingPathComponent("active-runtime.json")
        var value = stat()
        if lstat(url.path, &value) != 0 {
            if errno == ENOENT { return nil }
            throw RemoteControlError.guardian("active runtime is unreadable")
        }
        try validatePrivateRegularFile(url, label: "active runtime")
        let data = try boundedData(url, label: "active runtime")
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteControlError.guardian("active runtime must be an object") }
            object = decoded
        } catch let error as RemoteControlError { throw error }
        catch { throw RemoteControlError.guardian("active runtime is invalid") }
        let keys = Set(["schemaVersion", "generation", "sessionName", "socketPath", "expectedInventoryPath"])
        guard Set(object.keys) == keys else { throw RemoteControlError.guardian("active runtime keys are invalid") }
        let runtime: RemoteActiveRuntime
        do { runtime = try JSONDecoder().decode(RemoteActiveRuntime.self, from: data) }
        catch { throw RemoteControlError.guardian("active runtime fields are invalid") }
        try validate(runtime)
        return runtime
    }

    private func validate(_ runtime: RemoteActiveRuntime) throws {
        guard runtime.schemaVersion == 1, runtime.generation == runtime.sessionName else { throw RemoteControlError.guardian("active runtime identity is invalid") }
        try validateName(runtime.generation)
        let generationRoot = rootURL.appendingPathComponent("sessions/\(runtime.generation)", isDirectory: true).standardizedFileURL
        guard runtime.socketPath == generationRoot.appendingPathComponent("herdr.sock").path,
              runtime.expectedInventoryPath == generationRoot.appendingPathComponent("expected-inventory.json").path,
              URL(fileURLWithPath: runtime.socketPath).standardizedFileURL.path == runtime.socketPath,
              URL(fileURLWithPath: runtime.expectedInventoryPath).standardizedFileURL.path == runtime.expectedInventoryPath
        else { throw RemoteControlError.guardian("active runtime paths are invalid") }
    }

    private func validateExpectedInventory(_ runtime: RemoteActiveRuntime, matches manifest: RemoteGenerationManifest) throws {
        let url = URL(fileURLWithPath: runtime.expectedInventoryPath)
        try validatePrivateRegularFile(url, label: "expected inventory")
        let data = try boundedData(url, label: "expected inventory")
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteControlError.guardian("expected inventory must be an object") }
            object = decoded
        } catch let error as RemoteControlError { throw error }
        catch { throw RemoteControlError.guardian("expected inventory is invalid") }
        guard Set(object.keys) == Set(["version", "generation", "acknowledged_empty", "panes"]), let panes = object["panes"] as? [[String: Any]], panes.allSatisfy({ Set($0.keys) == Set(["pane_id", "native_session_id", "profile_id"]) }) else {
            throw RemoteControlError.guardian("expected inventory keys are invalid")
        }
        let expected: RemoteRelayExpectedInventory
        do { expected = try JSONDecoder().decode(RemoteRelayExpectedInventory.self, from: data) }
        catch { throw RemoteControlError.guardian("expected inventory fields are invalid") }
        let livePanes = manifest.expectedPanes.map { pane in
            RemoteRelayExpectedInventory.Pane(paneID: pane.paneID, nativeSessionID: pane.nativeSessionID, profileID: pane.profileID)
        }
        let order: (RemoteRelayExpectedInventory.Pane, RemoteRelayExpectedInventory.Pane) -> Bool = {
            ($0.paneID, $0.nativeSessionID, $0.profileID) < ($1.paneID, $1.nativeSessionID, $1.profileID)
        }
        guard expected.version == 1, expected.generation == runtime.generation, expected.acknowledgedEmpty == manifest.acknowledgedEmpty, expected.panes.sorted(by: order) == livePanes.sorted(by: order) else {
            throw RemoteControlError.guardian("expected inventory does not match the live generation")
        }
    }

    private func publish(_ runtime: RemoteActiveRuntime) throws {
        try validate(runtime)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try RemoteDurableFile.write(encoder.encode(runtime), to: rootURL.appendingPathComponent("active-runtime.json")) }
        catch { throw RemoteControlError.guardian("active runtime promotion was not durable") }
    }

    private func validateSnapshot(_ source: URL) throws {
        try validateNoSymlinkComponents(source)
        try validatePrivateDirectory(source, label: "snapshot source")
        let sessionJSON = source.appendingPathComponent("session.json")
        try validatePrivateRegularFile(sessionJSON, label: "snapshot session.json")
        let relativePaths: [String]
        do { relativePaths = try FileManager.default.subpathsOfDirectory(atPath: source.path) }
        catch { throw RemoteControlError.guardian("snapshot source is unreadable") }
        for relativePath in relativePaths {
            let item = source.appendingPathComponent(relativePath)
            var value = stat()
            guard snapshotLstat(item.path, &value) == 0 else { throw RemoteControlError.guardian("snapshot entry is unreadable") }
            if value.st_mode & S_IFMT == S_IFDIR {
                guard value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.guardian("snapshot directory permissions are unsafe") }
            } else {
                try validatePrivateRegularFile(item, label: "snapshot entry")
            }
        }
    }

    private func copySnapshot(source: URL, staged: URL) throws {
        do {
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.deletingLastPathComponent().path)
            try FileManager.default.copyItem(at: source, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
            let sourceSession = source.appendingPathComponent("session.json")
            let stagedSession = staged.appendingPathComponent("session.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedSession.path)
            var sourceStat = stat()
            var stagedStat = stat()
            guard snapshotLstat(sourceSession.path, &sourceStat) == 0, snapshotLstat(stagedSession.path, &stagedStat) == 0, sourceStat.st_ino != stagedStat.st_ino else {
                throw RemoteControlError.guardian("snapshot copy did not create an isolated inode")
            }
        } catch let error as RemoteControlError { throw error }
        catch { throw RemoteControlError.guardian("snapshot could not be copied into an isolated generation") }
    }

    private func writeRecoveryMarker(at directory: URL, generation: String, detail: String) throws {
        let safe = ["schemaVersion": 1, "generation": generation, "state": "recovery_required", "detail": detail] as [String: Any]
        do { try RemoteDurableFile.write(try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), to: directory.appendingPathComponent("recovery-required.json")) }
        catch { throw RemoteControlError.guardian("recovery required but its durable marker failed") }
    }

    private func validateNoSymlinkComponents(_ url: URL) throws {
        let targetPath = url.standardizedFileURL.path
        var current = rootURL
        let relative = targetPath.dropFirst(rootURL.standardizedFileURL.path.count).split(separator: "/")
        for component in relative {
            current.appendPathComponent(String(component))
            var value = stat()
            if lstat(current.path, &value) == 0, value.st_mode & S_IFMT == S_IFLNK { throw RemoteControlError.guardian("snapshot path contains a symbolic link") }
        }
    }

    private func validatePrivateDirectory(_ url: URL, label: String) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw RemoteControlError.guardian("\(label) is not a directory") }
        guard value.st_mode & mode_t(0o777) == 0o700 else { throw RemoteControlError.guardian("\(label) permissions must be 0700") }
    }

    private func validatePrivateRegularFile(_ url: URL, label: String) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw RemoteControlError.guardian("\(label) must be a private regular file") }
        guard value.st_mode & mode_t(0o777) == 0o600 else { throw RemoteControlError.guardian("\(label) permissions must be 0600") }
    }

    private func boundedData(_ url: URL, label: String) throws -> Data {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw RemoteControlError.guardian("\(label) is unreadable") }
        guard data.count <= Self.maximumControlFileBytes else { throw RemoteControlError.guardian("\(label) exceeds the byte bound") }
        return data
    }

    private func validateName(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else { throw RemoteControlError.guardian("snapshot session name is unsafe") }
    }

    private func safeText(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func structuralInventory(_ inventory: RemoteHerdrInventory, matches manifest: RemoteGenerationManifest, generation: String) -> Bool {
        partialInventory(inventory, matches: manifest, generation: generation, completedCount: 0)
    }

    private func resumedPane(_ inventory: RemoteHerdrInventory, matches expected: RemoteExpectedPane, generation: String) -> Bool {
        inventory.version == "0.8.2" && inventory.panes.contains {
            guard let process = $0.foregroundProcess else { return false }
            return $0.workspaceID == expected.workspaceID && $0.paneID == expected.paneID
                && $0.nativeSessionID == expected.nativeSessionID && $0.profileID == expected.profileID
                && $0.githubLogin == expected.githubLogin && $0.generation == generation
                && $0.childPresent && $0.hookObserved && $0.wrapperReady
                && process.generation == generation && process.pid > 0
                && !process.startIdentity.isEmpty && process.executable.hasPrefix("/")
        }
    }

    private func finalInventory(_ inventory: RemoteHerdrInventory, matches manifest: RemoteGenerationManifest, generation: String) -> Bool {
        partialInventory(inventory, matches: manifest, generation: generation, completedCount: manifest.expectedPanes.count)
    }

    private func partialInventory(_ inventory: RemoteHerdrInventory, matches manifest: RemoteGenerationManifest, generation: String, completedCount: Int) -> Bool {
        guard completedCount >= 0, completedCount <= manifest.expectedPanes.count, inventory.version == manifest.herdrVersion, inventory.panes.count == manifest.expectedPanes.count, Set(inventory.panes.map(\.paneID)).count == inventory.panes.count else { return false }
        return manifest.expectedPanes.enumerated().allSatisfy { index, expected in
            if index < completedCount { return resumedPane(inventory, matches: expected, generation: generation) }
            return inventory.panes.contains {
                $0.workspaceID == expected.workspaceID && $0.paneID == expected.paneID
                    && $0.nativeSessionID == expected.nativeSessionID && $0.generation == generation
                    && $0.profileID == nil && $0.githubLogin == nil && !$0.childPresent && !$0.hookObserved
                    && $0.wrapperReady && $0.foregroundProcess == nil
            }
        }
    }

    private func safeDetail(_ error: Error) -> String {
        error is RemoteControlError || error is RemotePaneResumeFailure ? error.localizedDescription : "dependency error"
    }
}
