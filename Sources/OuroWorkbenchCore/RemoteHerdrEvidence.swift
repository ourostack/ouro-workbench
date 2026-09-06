import Foundation

public enum RemoteResumeLedgerFactory {
    public static func make(
        ledgerRootURL: URL,
        herdrRootURL: URL,
        registry: RemoteProfileRegistry,
        inheritedEnvironment: [String: String],
        run: @escaping (RemoteProcessRequest) throws -> RemoteProcessResult = { try RemoteSystemRunner(timeout: 10, maximumOutputBytes: 65_536).run($0) },
        listServerSessions: (() throws -> [String])? = nil,
        processIdentityForPID: @escaping (Int32, String) -> RemoteProcessIdentity? = remoteProcessIdentity,
        listProcessIDs: @escaping () throws -> [Int32] = RemoteNativeProcessIDs.all,
        processSnapshotForPID: @escaping (Int32) -> RemoteProcessSnapshot? = RemoteProcessArguments.readSnapshot
    ) throws -> RemoteResumeLedger {
        let herdrExecutables = Set(registry.profiles.map(\.herdrExecutable))
        guard herdrExecutables.count == 1, let herdrExecutable = herdrExecutables.first else {
            throw RemoteControlError.guardian("all profiles must use one exact Herdr executable")
        }
        let scan = listServerSessions ?? RemoteHerdrProcessScanner(
            herdrExecutable: herdrExecutable,
            processIdentityForPID: processIdentityForPID
        ).listServerSessions
        let evidence = RemoteHerdrForegroundEvidenceProvider(
            rootURL: herdrRootURL,
            registry: registry,
            inheritedEnvironment: inheritedEnvironment,
            run: run,
            listServerSessions: scan,
            processIdentityForPID: processIdentityForPID,
            listProcessIDs: listProcessIDs,
            processSnapshotForPID: processSnapshotForPID
        )
        return RemoteResumeLedger(
            rootURL: ledgerRootURL,
            processIdentityForPID: processIdentityForPID,
            inspectMatchingHerdrForeground: evidence.inspect
        )
    }
}

public struct RemoteHerdrForegroundEvidenceProvider {
    public let rootURL: URL
    public let registry: RemoteProfileRegistry
    private let inheritedEnvironment: [String: String]
    private let run: (RemoteProcessRequest) throws -> RemoteProcessResult
    private let listServerSessions: () throws -> [String]
    private let processIdentityForPID: (Int32, String) -> RemoteProcessIdentity?
    private let listProcessIDs: () throws -> [Int32]
    private let processSnapshotForPID: (Int32) -> RemoteProcessSnapshot?

    public init(
        rootURL: URL,
        registry: RemoteProfileRegistry,
        inheritedEnvironment: [String: String],
        run: @escaping (RemoteProcessRequest) throws -> RemoteProcessResult,
        listServerSessions: @escaping () throws -> [String],
        processIdentityForPID: @escaping (Int32, String) -> RemoteProcessIdentity?,
        listProcessIDs: @escaping () throws -> [Int32] = RemoteNativeProcessIDs.all,
        processSnapshotForPID: @escaping (Int32) -> RemoteProcessSnapshot? = RemoteProcessArguments.readSnapshot
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.registry = registry
        self.inheritedEnvironment = inheritedEnvironment
        self.run = run
        self.listServerSessions = listServerSessions
        self.processIdentityForPID = processIdentityForPID
        self.listProcessIDs = listProcessIDs
        self.processSnapshotForPID = processSnapshotForPID
    }

    public func inspect(_ record: RemoteResumeRecord) -> RemotePresenceEvidence {
        do { return try inspectExactly(record) }
        catch { return .unavailable }
    }

    private func inspectExactly(_ record: RemoteResumeRecord) throws -> RemotePresenceEvidence {
        guard let profile = try? registry.profile(id: record.profileID), record.expectedArgvSHA256 != RemoteArgvDigest.unavailable else { return .unavailable }
        let global = try inspectGlobalProcesses(record, profile: profile)
        guard global == .absent else { return global }
        let herdrExecutables = Set(registry.profiles.map(\.herdrExecutable))
        guard herdrExecutables.count == 1, let herdrExecutable = herdrExecutables.first else { return .unavailable }
        let version = try execute(herdrExecutable, arguments: ["--version"])
        guard version.exitCode == 0,
              String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "herdr 0.8.2"
        else { return .unavailable }

        let listed = try execute(herdrExecutable, arguments: ["session", "list", "--json"])
        guard listed.exitCode == 0,
              let sessions = try? JSONDecoder().decode(RemoteEvidenceSessionEnvelope.self, from: listed.stdout).sessions,
              sessions.allSatisfy({ Self.safeSessionName($0.name) })
        else { return .unavailable }
        let runningSessions = Set(sessions.filter(\.running).map(\.name))
        let processSessions = Set(try listServerSessions())
        guard processSessions == runningSessions else { return .unavailable }

        let resolvedExecutable = URL(fileURLWithPath: profile.copilotExecutable).resolvingSymlinksInPath().standardizedFileURL.path
        for session in runningSessions.sorted() {
            let snapshotResult = try execute(herdrExecutable, arguments: ["--session", session, "api", "snapshot"])
            guard snapshotResult.exitCode == 0,
                  let snapshot = try? JSONDecoder().decode(RemoteEvidenceSnapshotEnvelope.self, from: snapshotResult.stdout).result.snapshot,
                  snapshot.version == "0.8.2",
                  Set(snapshot.panes.map(\.paneID)).count == snapshot.panes.count
            else { return .unavailable }
            for pane in snapshot.panes {
                let processResult = try execute(herdrExecutable, arguments: ["--session", session, "pane", "process-info", "--pane", pane.paneID])
                guard processResult.exitCode == 0,
                      let processInfo = try? JSONDecoder().decode(RemoteEvidenceProcessEnvelope.self, from: processResult.stdout).result.processInfo,
                      processInfo.paneID == pane.paneID
                else { return .unavailable }
                for process in processInfo.foregroundProcesses {
                    if let child = record.childIdentity, process.pid == child.pid {
                        guard processIdentityForPID(process.pid, session) == child else { return .unavailable }
                        return .live
                    }
                    guard let argv = process.argv else { return .unavailable }
                    if RemoteArgvDigest.sha256(argv) == record.expectedArgvSHA256 {
                        guard processIdentityForPID(process.pid, session)?.executable == resolvedExecutable else { return .unavailable }
                        return .live
                    }
                }
            }
        }
        return .absent
    }

    private func inspectGlobalProcesses(_ record: RemoteResumeRecord, profile: RemoteProfile) throws -> RemotePresenceEvidence {
        let resolvedExecutable = URL(fileURLWithPath: profile.copilotExecutable).resolvingSymlinksInPath().standardizedFileURL.path
        for pid in try listProcessIDs() where pid > 0 {
            guard let before = processIdentityForPID(pid, record.generation), before.executable == resolvedExecutable else { continue }
            guard let snapshot = processSnapshotForPID(pid), processIdentityForPID(pid, record.generation) == before else { return .unavailable }
            guard snapshot.environment["OURO_PROFILE_ID"] == record.profileID,
                  snapshot.environment["OURO_GENERATION"] == record.generation,
                  snapshot.environment["OURO_PANE_ID"] == record.paneID
            else { continue }
            if RemoteArgvDigest.sha256(snapshot.arguments) == record.expectedArgvSHA256 { return .live }
        }
        return .absent
    }

    private func execute(_ executable: String, arguments: [String]) throws -> RemoteProcessResult {
        try run(RemoteProcessRequest(executable: executable, arguments: arguments, environment: environment(), workingDirectory: rootURL.path))
    }

    private func environment() -> [String: String] {
        let allowed = Set(["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "TERM", "LANG"])
        var clean = inheritedEnvironment.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
        clean["XDG_CONFIG_HOME"] = rootURL.deletingLastPathComponent().path
        return clean
    }

    private static func safeSessionName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }
}

private struct RemoteEvidenceSessionEnvelope: Decodable {
    struct Session: Decodable {
        var name: String
        var running: Bool
    }
    var sessions: [Session]
}

private struct RemoteEvidenceSnapshotEnvelope: Decodable {
    struct Result: Decodable {
        struct Snapshot: Decodable {
            struct Pane: Decodable {
                var paneID: String
                enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
            }
            var version: String
            var panes: [Pane]
        }
        var snapshot: Snapshot
    }
    var result: Result
}

private struct RemoteEvidenceProcessEnvelope: Decodable {
    struct Result: Decodable {
        struct ProcessInfo: Decodable {
            struct Process: Decodable {
                var pid: Int32
                var argv: [String]?
            }
            var paneID: String
            var foregroundProcesses: [Process]
            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case foregroundProcesses = "foreground_processes"
            }
        }
        var processInfo: ProcessInfo
        enum CodingKeys: String, CodingKey { case processInfo = "process_info" }
    }
    var result: Result
}
