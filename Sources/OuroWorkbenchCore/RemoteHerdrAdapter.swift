import Foundation

public struct RemoteHerdrServerHandle {
    private let running: () -> Bool
    private let cleanup: (TimeInterval) -> Bool

    public init(running: @escaping () -> Bool, terminateAndWait: @escaping (TimeInterval) -> Bool) {
        self.running = running
        cleanup = terminateAndWait
    }

    public var isRunning: Bool { running() }
    public func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !isRunning
    }
    public func terminateAndWait(timeout: TimeInterval) -> Bool { cleanup(timeout) }

    public static func spawn(_ request: RemoteProcessRequest) throws -> RemoteHerdrServerHandle {
        let process = try RemoteOwnedProcess.spawn(request, nullOutput: true)
        return RemoteHerdrServerHandle(
            running: { process.isRunning },
            terminateAndWait: { process.terminateAndWait(timeout: $0) }
        )
    }
}

public struct RemoteHerdrAdapter {
    public let rootURL: URL
    public let registry: RemoteProfileRegistry
    public let ledger: RemoteResumeLedger
    public let sessionMapURL: URL
    public let herdrExecutable: String
    public let configPath: String
    public let helperPath: String
    public let shimDirectory: String
    public let zdotdir: String
    public let inheritedEnvironment: [String: String]
    private let runProcess: (RemoteProcessRequest, TimeInterval) throws -> RemoteProcessResult
    private let scanHerdrProcesses: () throws -> [String]
    private let processIdentityForPID: (Int32, String) -> RemoteProcessIdentity?
    private let shellReadiness: (Int32, String, String) -> Bool
    private let fileExists: (String) -> Bool
    private let readPrivateFile: (String, Int) throws -> Data
    private let contentsOfDirectory: (URL) throws -> [URL]
    private let spawnServer: (RemoteProcessRequest) throws -> RemoteHerdrServerHandle
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void

    public init(
        rootURL: URL,
        registry: RemoteProfileRegistry,
        ledger: RemoteResumeLedger,
        sessionMapURL: URL,
        herdrExecutable: String,
        configPath: String,
        helperPath: String,
        shimDirectory: String,
        zdotdir: String,
        inheritedEnvironment: [String: String],
        run: @escaping (RemoteProcessRequest, TimeInterval) throws -> RemoteProcessResult = { request, timeout in try RemoteSystemRunner(timeout: timeout).run(request) },
        listHerdrProcessSessions: (() throws -> [String])? = nil,
        processIdentityForPID: @escaping (Int32, String) -> RemoteProcessIdentity? = remoteProcessIdentity,
        shellReadiness: ((Int32, String, String) -> Bool)? = nil,
        fileExists: @escaping (String) -> Bool = FileManager.default.fileExists,
        readPrivateFile: @escaping (String, Int) throws -> Data = { try RemotePrivateFile.read(path: $0, maximumBytes: $1) },
        contentsOfDirectory: @escaping (URL) throws -> [URL] = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) },
        spawnServer: @escaping (RemoteProcessRequest) throws -> RemoteHerdrServerHandle = RemoteHerdrServerHandle.spawn,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.registry = registry
        self.ledger = ledger
        self.sessionMapURL = sessionMapURL.standardizedFileURL
        self.herdrExecutable = herdrExecutable
        self.configPath = configPath
        self.helperPath = helperPath
        self.shimDirectory = shimDirectory
        self.zdotdir = zdotdir
        self.inheritedEnvironment = inheritedEnvironment
        runProcess = run
        scanHerdrProcesses = listHerdrProcessSessions ?? RemoteHerdrProcessScanner(herdrExecutable: herdrExecutable, processIdentityForPID: processIdentityForPID).listServerSessions
        self.processIdentityForPID = processIdentityForPID
        let zshExecutables = Set(registry.profiles.map(\.zshExecutable))
        self.shellReadiness = shellReadiness ?? { shellPID, generation, paneID in
            guard zshExecutables.count == 1, let zshExecutable = zshExecutables.first else { return false }
            return RemoteShellReadiness.isReady(
                sessionMapURL: sessionMapURL,
                generation: generation,
                paneID: paneID,
                shellPID: shellPID,
                zshExecutable: zshExecutable,
                zdotdir: zdotdir,
                helperPath: helperPath,
                configPath: configPath,
                processIdentityForPID: processIdentityForPID
            )
        }
        self.fileExists = fileExists
        self.readPrivateFile = readPrivateFile
        self.contentsOfDirectory = contentsOfDirectory
        self.spawnServer = spawnServer
        self.now = now
        self.sleep = sleep
    }

    public func probe(sessionName: String) throws -> RemoteHerdrProbe {
        let sessions: [RemoteHerdrSession]
        do { sessions = try listSessions() }
        catch { return .degraded("session enumeration failed") }
        guard let session = sessions.first(where: { $0.name == sessionName }), session.running else { return .absent }
        do { return .running(try inventory(sessionName: sessionName)) }
        catch { return .degraded(error is RemoteControlError ? error.localizedDescription : "inventory probe failed") }
    }

    public func listManagedSessions() throws -> [String] {
        try listSessions().map(\.name).filter { $0.hasPrefix("ouro-") }
    }

    public func listManagedProcessSessions() throws -> [String] {
        try listHerdrProcessSessions().filter { $0.hasPrefix("ouro-") }
    }

    public func listHerdrProcessSessions() throws -> [String] {
        try scanHerdrProcesses()
    }

    public func boot(_ request: RemoteHerdrBootRequest) throws -> RemoteHerdrInventory {
        guard request.stagedSessionURL.standardizedFileURL == rootURL.appendingPathComponent("sessions/\(request.sessionName)", isDirectory: true).standardizedFileURL,
              request.expectedVersion == "0.8.2",
              request.resumeAgentsOnRestore == false
        else {
            throw RemotePaneResumeFailure.preSpawn("boot request is not an exact managed generation")
        }
        try verifyAutomaticResumeDisabled()
        return try startServer(sessionName: request.sessionName, preSpawnFailure: true)
    }

    public func resume(_ command: RemotePaneResumeCommand) throws -> RemoteHerdrInventory {
        let arguments = command.arguments
        guard command.helperPath == helperPath,
              arguments.count == 9,
              arguments[0] == "resume",
              arguments[1] == "--uuid",
              let uuid = UUID(uuidString: arguments[2]),
              uuid.uuidString.lowercased() == arguments[2],
              arguments[3] == "--profile",
              registry.profiles.contains(where: { $0.id == arguments[4] }),
              arguments[5] == "--generation",
              arguments[6].range(of: "^ouro-[A-Za-z0-9][A-Za-z0-9._-]{0,122}$", options: .regularExpression) != nil,
              arguments[7] == "--pane",
              arguments[8] == command.paneID
        else { throw RemotePaneResumeFailure.preSpawn("resume request is not exact") }
        let generation = arguments[6]
        let result: RemoteProcessResult
        do {
            result = try runHerdr(["--session", generation, "pane", "run", command.paneID, command.shellCommand], timeout: 15)
        } catch {
            throw RemotePaneResumeFailure.postIntent("Herdr pane.run transport failed")
        }
        guard result.exitCode == 0 else { throw RemotePaneResumeFailure.postIntent("Herdr pane.run returned a nonzero status") }
        let deadline = now().addingTimeInterval(45)
        repeat {
            let current: RemoteHerdrInventory
            do { current = try inventory(sessionName: generation) }
            catch { throw RemotePaneResumeFailure.postIntent("resume evidence could not be proven after pane.run") }
            if current.panes.contains(where: { $0.paneID == command.paneID && $0.childPresent && $0.hookObserved }) { return current }
            sleep(0.1)
        } while now() < deadline
        throw RemotePaneResumeFailure.postIntent("resume evidence timed out after pane.run")
    }

    public func stop(sessionName: String) throws -> RemoteHerdrProbe {
        let result = try runHerdr(["session", "stop", sessionName, "--json"], timeout: 20)
        guard result.exitCode == 0 || result.exitCode == 1 else { return .degraded("session stop failed") }
        let deadline = now().addingTimeInterval(5)
        repeat {
            let status = try probe(sessionName: sessionName)
            if status == .absent {
                let sessionRoot = rootURL.appendingPathComponent("sessions/\(sessionName)", isDirectory: true)
                guard !fileExists(sessionRoot.appendingPathComponent("herdr.sock").path),
                      !fileExists(sessionRoot.appendingPathComponent("herdr-client.sock").path),
                      try !listManagedProcessSessions().contains(sessionName)
                else {
                    sleep(0.05)
                    continue
                }
                return .absent
            }
            sleep(0.05)
        } while now() < deadline
        return .degraded("session stop could not prove both socket and process absence")
    }

    public func reactivate(_ runtime: RemoteActiveRuntime) throws -> RemoteHerdrProbe {
        var serverMayExist = false
        var expectedNativeSessionIDs: [String] = []
        do {
            let expected = try loadExpectedInventory(for: runtime)
            expectedNativeSessionIDs = expected.panes.map(\.nativeSessionID)
            try verifyAutomaticResumeDisabled()
            var inventory = try startServer(sessionName: runtime.sessionName, preSpawnFailure: false)
            serverMayExist = true
            guard reactivationInventory(inventory, matches: expected, generation: runtime.generation, completedCount: 0) else {
                throw RemoteControlError.guardian("prior generation structural inventory is not exact")
            }
            for (index, pane) in expected.panes.enumerated() {
                inventory = try resume(RemotePaneResumeCommand(
                    paneID: pane.paneID,
                    helperPath: helperPath,
                    arguments: ["resume", "--uuid", pane.nativeSessionID, "--profile", pane.profileID, "--generation", runtime.generation, "--pane", pane.paneID]
                ))
                guard reactivationInventory(inventory, matches: expected, generation: runtime.generation, completedCount: index + 1) else {
                    throw RemoteControlError.guardian("prior generation resume inventory is not exact")
                }
            }
            return .running(inventory)
        }
        catch {
            if error is RemoteHerdrStartFailure { serverMayExist = true }
            guard serverMayExist else { return .degraded("prior generation reactivation failed") }
            do {
                let stopped = try stop(sessionName: runtime.sessionName)
                let outstanding = try ledger.hasOutstandingOwnership(nativeSessionIDs: expectedNativeSessionIDs)
                if stopped == .absent, !outstanding {
                    return .degraded("prior generation reactivation failed; no managed process remains")
                }
            } catch {}
            return .degraded("prior generation reactivation failed; possible child ownership remains")
        }
    }

    public func inventory(sessionName: String) throws -> RemoteHerdrInventory {
        let snapshotResult = try runHerdr(["--session", sessionName, "api", "snapshot"], timeout: 10)
        guard snapshotResult.exitCode == 0 else { throw RemoteControlError.guardian("Herdr snapshot request failed") }
        let snapshot: RemoteHerdrSnapshotEnvelope
        do { snapshot = try JSONDecoder().decode(RemoteHerdrSnapshotEnvelope.self, from: snapshotResult.stdout) }
        catch { throw RemoteControlError.guardian("Herdr snapshot response is invalid") }
        let mappings = mappingsIfAvailable()
        let records = ledgerRecordsIfAvailable()
        let panes = try snapshot.result.snapshot.panes.map { pane -> RemotePaneInventory in
            let processInfo = try paneProcessInfo(sessionName: sessionName, paneID: pane.paneID)
            let nativeSessionID = pane.agentSession.flatMap { session -> String? in
                guard session.agent.lowercased() == "copilot", let uuid = UUID(uuidString: session.value) else { return nil }
                return uuid.uuidString.lowercased()
            }
            let mapping = nativeSessionID.flatMap { native in
                mappings.first { $0.sessionID == native && $0.paneID == pane.paneID && $0.generation == sessionName }
            }
            let record = records.first { candidate in
                candidate.generation == sessionName && candidate.paneID == pane.paneID
                    && candidate.profileID == mapping?.profileID && candidate.nativeSessionID == nativeSessionID
                    && candidate.phase != .exited
            }
            var verifiedLogin: String?
            let exactChild = record?.childIdentity.flatMap { expected -> RemoteProcessIdentity? in
                guard let nativeSessionID,
                      let mapping,
                      let profile = try? registry.profile(id: mapping.profileID),
                      let foreground = processInfo.foregroundProcesses.first(where: { $0.pid == expected.pid })
                else { return nil }
                let actualLogin = verifiedGitHubLogin(profile)
                guard RemoteWorkerIntegrity.matches(
                    recordedIdentity: expected,
                    liveIdentity: processIdentityForPID(expected.pid, sessionName),
                    herdrPID: foreground.pid,
                    herdrArgv: foreground.argv,
                    expectedExecutable: profile.copilotExecutable,
                    expectedArguments: RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(nativeSessionID)"]),
                    actualGitHubLogin: actualLogin,
                    expectedGitHubLogin: profile.githubLogin
                ) else { return nil }
                verifiedLogin = actualLogin
                return expected
            }
            let hookObserved = record?.hookSessionID == nativeSessionID
                && [.hookObservedAwaitingPID, .hookConfirmed].contains(record?.phase)
            let profileID = hookObserved ? mapping?.profileID : nil
            let githubLogin = hookObserved && exactChild != nil ? verifiedLogin : nil
            let shellReady = processInfo.shellPID.map { shellReadiness($0, sessionName, pane.paneID) } ?? false
            return RemotePaneInventory(
                workspaceID: pane.workspaceID,
                paneID: pane.paneID,
                nativeSessionID: nativeSessionID,
                profileID: profileID,
                githubLogin: githubLogin,
                generation: sessionName,
                childPresent: exactChild != nil,
                hookObserved: hookObserved,
                wrapperReady: shellReady,
                foregroundProcess: exactChild
            )
        }
        return RemoteHerdrInventory(version: snapshot.result.snapshot.version, panes: panes)
    }

    private func startServer(sessionName: String, preSpawnFailure: Bool) throws -> RemoteHerdrInventory {
        let process: RemoteHerdrServerHandle
        do {
            process = try spawnServer(RemoteProcessRequest(
                executable: herdrExecutable,
                arguments: ["--session", sessionName, "server"],
                environment: processEnvironment(),
                workingDirectory: rootURL.path
            ))
        } catch {
            if preSpawnFailure { throw RemotePaneResumeFailure.preSpawn("Herdr server spawn failed") }
            throw RemoteControlError.guardian("Herdr server spawn failed")
        }
        let deadline = now().addingTimeInterval(15)
        repeat {
            if !process.isRunning {
                if preSpawnFailure { throw RemotePaneResumeFailure.preSpawn("Herdr server exited during boot") }
                throw RemoteControlError.guardian("Herdr server exited during boot")
            }
            if case let .running(inventory) = try probe(sessionName: sessionName) { return inventory }
            sleep(0.1)
        } while now() < deadline
        guard process.terminateAndWait(timeout: 2) else {
            if preSpawnFailure { throw RemotePaneResumeFailure.preSpawn("Herdr server cleanup timed out") }
            throw RemoteHerdrStartFailure.possibleProcess
        }
        if preSpawnFailure { throw RemotePaneResumeFailure.preSpawn("Herdr server boot timed out") }
        throw RemoteControlError.guardian("Herdr server boot timed out")
    }

    private func verifyAutomaticResumeDisabled() throws {
        let configURL = rootURL.appendingPathComponent("config.toml")
        let text = String(decoding: try readPrivateFile(configURL.path, 65_536), as: UTF8.self)
        var inSession = false
        var values: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inSession = line == "[session]"
            } else if inSession, line.hasPrefix("resume_agents_on_restore") {
                values.append(line.replacingOccurrences(of: " ", with: ""))
            }
        }
        guard values == ["resume_agents_on_restore=false"] else {
            throw RemotePaneResumeFailure.preSpawn("automatic native resume is not durably disabled")
        }
        let check = try runHerdr(["config", "check"], timeout: 10)
        guard check.exitCode == 0 else { throw RemotePaneResumeFailure.preSpawn("Herdr config validation failed") }
    }

    private func loadExpectedInventory(for runtime: RemoteActiveRuntime) throws -> RemoteRelayExpectedInventory {
        guard runtime.schemaVersion == 1,
              runtime.generation == runtime.sessionName,
              runtime.generation.range(of: "^ouro-[A-Za-z0-9][A-Za-z0-9._-]{0,122}$", options: .regularExpression) != nil
        else { throw RemoteControlError.guardian("prior active runtime identity is invalid") }
        let generationRoot = rootURL.appendingPathComponent("sessions/\(runtime.generation)", isDirectory: true).standardizedFileURL
        guard runtime.socketPath == generationRoot.appendingPathComponent("herdr.sock").path,
              runtime.expectedInventoryPath == generationRoot.appendingPathComponent("expected-inventory.json").path
        else { throw RemoteControlError.guardian("prior active runtime paths are invalid") }
        let data = try readPrivateFile(runtime.expectedInventoryPath, RemoteGuardian.maximumControlFileBytes)
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RemoteControlError.guardian("prior expected inventory must be an object")
            }
            object = decoded
        } catch let error as RemoteControlError { throw error }
        catch { throw RemoteControlError.guardian("prior expected inventory is invalid") }
        guard Set(object.keys) == Set(["version", "generation", "acknowledged_empty", "panes"]),
              let panes = object["panes"] as? [[String: Any]],
              panes.allSatisfy({ Set($0.keys) == Set(["pane_id", "native_session_id", "profile_id"]) })
        else { throw RemoteControlError.guardian("prior expected inventory keys are invalid") }
        let expected: RemoteRelayExpectedInventory
        do { expected = try JSONDecoder().decode(RemoteRelayExpectedInventory.self, from: data) }
        catch { throw RemoteControlError.guardian("prior expected inventory fields are invalid") }
        guard expected.version == 1,
              expected.generation == runtime.generation,
              expected.acknowledgedEmpty == expected.panes.isEmpty,
              Set(expected.panes.map(\.paneID)).count == expected.panes.count,
              Set(expected.panes.map(\.nativeSessionID)).count == expected.panes.count
        else { throw RemoteControlError.guardian("prior expected inventory identity is invalid") }
        for pane in expected.panes {
            guard pane.paneID.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$", options: .regularExpression) != nil,
                  let uuid = UUID(uuidString: pane.nativeSessionID),
                  uuid.uuidString.lowercased() == pane.nativeSessionID,
                  registry.profiles.contains(where: { $0.id == pane.profileID })
            else { throw RemoteControlError.guardian("prior expected pane identity is invalid") }
        }
        return expected
    }

    func reactivationInventory(_ inventory: RemoteHerdrInventory, matches expected: RemoteRelayExpectedInventory, generation: String, completedCount: Int) -> Bool {
        guard inventory.version == "0.8.2",
              completedCount >= 0,
              completedCount <= expected.panes.count,
              inventory.panes.count == expected.panes.count,
              Set(inventory.panes.map(\.paneID)).count == inventory.panes.count
        else { return false }
        return expected.panes.enumerated().allSatisfy { index, pane in
            guard let live = inventory.panes.first(where: { $0.paneID == pane.paneID }),
                  live.nativeSessionID == pane.nativeSessionID,
                  live.generation == generation,
                  live.wrapperReady
            else { return false }
            if index >= completedCount {
                return live.profileID == nil && live.githubLogin == nil && !live.childPresent && !live.hookObserved && live.foregroundProcess == nil
            }
            guard let profile = try? registry.profile(id: pane.profileID), let process = live.foregroundProcess else { return false }
            return live.profileID == pane.profileID && live.githubLogin == profile.githubLogin
                && live.childPresent && live.hookObserved && process.generation == generation
                && process.pid > 0 && !process.startIdentity.isEmpty && process.executable.hasPrefix("/")
        }
    }

    private func listSessions() throws -> [RemoteHerdrSession] {
        let result = try runHerdr(["session", "list", "--json"], timeout: 10)
        guard result.exitCode == 0 else { throw RemoteControlError.guardian("Herdr session enumeration failed") }
        do { return try JSONDecoder().decode(RemoteHerdrSessionEnvelope.self, from: result.stdout).sessions }
        catch { throw RemoteControlError.guardian("Herdr session enumeration response is invalid") }
    }

    private func paneProcessInfo(sessionName: String, paneID: String) throws -> RemoteHerdrProcessInfo {
        let result = try runHerdr(["--session", sessionName, "pane", "process-info", "--pane", paneID], timeout: 10)
        guard result.exitCode == 0 else { throw RemoteControlError.guardian("Herdr process inspection failed") }
        do { return try JSONDecoder().decode(RemoteHerdrProcessEnvelope.self, from: result.stdout).result.processInfo }
        catch { throw RemoteControlError.guardian("Herdr process response is invalid") }
    }

    private func mappingsIfAvailable() -> [RemoteSessionMapping] {
        guard fileExists(sessionMapURL.path) else { return [] }
        return (try? RemoteSessionMapStore.read(mapURL: sessionMapURL, registry: registry)) ?? []
    }

    private func ledgerRecordsIfAvailable() -> [RemoteResumeRecord] {
        let attempts = ledger.rootURL.appendingPathComponent("attempts", isDirectory: true)
        guard let urls = try? contentsOfDirectory(attempts) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { try? ledger.record(attemptID: $0.deletingPathExtension().lastPathComponent) }
    }

    private func runHerdr(_ arguments: [String], timeout: TimeInterval) throws -> RemoteProcessResult {
        try runProcess(RemoteProcessRequest(
            executable: herdrExecutable,
            arguments: arguments,
            environment: processEnvironment(),
            workingDirectory: rootURL.path
        ), timeout)
    }

    private func verifiedGitHubLogin(_ profile: RemoteProfile) -> String? {
        var environment = processEnvironment()
        environment["GH_CONFIG_DIR"] = profile.ghConfigDir
        guard let result = try? runProcess(RemoteProcessRequest(
            executable: profile.ghExecutable,
            arguments: ["api", "/user", "--jq", ".login"],
            environment: environment,
            workingDirectory: profile.deskRoot
        ), 10), result.exitCode == 0 else { return nil }
        let login = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }

    private func processEnvironment() -> [String: String] {
        let allowed = Set(["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "TERM", "LANG"])
        var clean = inheritedEnvironment.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
        clean["XDG_CONFIG_HOME"] = rootURL.deletingLastPathComponent().path
        clean["ZDOTDIR"] = zdotdir
        clean["OURO_REMOTE_CONFIG"] = configPath
        clean["OURO_LEDGER_ROOT"] = ledger.rootURL.path
        clean["OURO_SESSION_MAP"] = sessionMapURL.path
        clean["OURO_HELPER_PATH"] = helperPath
        clean["OURO_SHIM_DIRECTORY"] = shimDirectory
        return clean
    }
}

private enum RemoteHerdrStartFailure: Error {
    case possibleProcess
}

private struct RemoteHerdrSessionEnvelope: Decodable {
    var sessions: [RemoteHerdrSession]
}

private struct RemoteHerdrSession: Decodable {
    var name: String
    var running: Bool
}

private struct RemoteHerdrSnapshotEnvelope: Decodable {
    struct Result: Decodable {
        struct Snapshot: Decodable {
            var version: String
            var panes: [Pane]
        }
        var snapshot: Snapshot
    }
    struct Pane: Decodable {
        struct AgentSession: Decodable {
            var agent: String
            var value: String
        }
        var paneID: String
        var workspaceID: String
        var agentSession: AgentSession?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case agentSession = "agent_session"
        }
    }
    var result: Result
}

private struct RemoteHerdrProcessEnvelope: Decodable {
    struct Result: Decodable {
        var processInfo: RemoteHerdrProcessInfo
        enum CodingKeys: String, CodingKey { case processInfo = "process_info" }
    }
    var result: Result
}

private struct RemoteHerdrProcessInfo: Decodable {
    struct ProcessInfo: Decodable {
        var pid: Int32
        var argv: [String]?
    }
    var shellPID: Int32?
    var foregroundProcesses: [ProcessInfo]

    enum CodingKeys: String, CodingKey {
        case shellPID = "shell_pid"
        case foregroundProcesses = "foreground_processes"
    }
}
