import Foundation

public enum RemoteControlError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case unknownProfile(String)
    case dependency(String)
    case invalidSessionMap(String)
    case invalidHook(String)
    case resume(String)
    case repository(String)
    case ledger(String)
    case guardian(String)
    case observation(String)
    case artifact(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail): "Invalid remote configuration: \(detail)"
        case let .unknownProfile(id): "Unknown profile: \(id)"
        case let .dependency(detail): detail
        case let .invalidSessionMap(detail): "Invalid session map: \(detail)"
        case let .invalidHook(detail): "Invalid session hook: \(detail)"
        case let .resume(detail): "Resume failed: \(detail)"
        case let .repository(detail): "Repository policy failed: \(detail)"
        case let .ledger(detail): "Resume ledger failed: \(detail)"
        case let .guardian(detail): "Guardian failed: \(detail)"
        case let .observation(detail): "Observer failed: \(detail)"
        case let .artifact(detail): "Runtime artifact failed: \(detail)"
        }
    }
}

public struct RemoteProfile: Codable, Equatable, Sendable {
    public var id: String
    public var githubLogin: String
    public var displayLabel: String
    public var displayColor: String
    public var copilotHome: String
    public var ghConfigDir: String
    public var gitConfigGlobal: String
    public var allowedGitHubOwners: [String]
    public var commitName: String
    public var commitEmail: String
    public var copilotExecutable: String
    public var ghExecutable: String
    public var gitExecutable: String
    public var herdrExecutable: String
    public var zshExecutable: String
    public var deskRoot: String
    public var workerID: String
    public var continuationCap: Int
    public var remote: Bool
    public var autonomy: Bool
}

public struct RemoteProfileRegistry: Equatable, Sendable {
    public static let schemaVersion = 1
    public let profiles: [RemoteProfile]

    public static func decode(
        _ data: Data,
        executableExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> RemoteProfileRegistry {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RemoteControlError.invalidConfiguration("configuration is not valid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw RemoteControlError.invalidConfiguration("top level must be an object")
        }
        let topKeys = Set(["schemaVersion", "profiles"])
        if let unknown = Set(root.keys).subtracting(topKeys).sorted().first {
            throw RemoteControlError.invalidConfiguration("unknown configuration key '\(unknown)'")
        }
        guard root["schemaVersion"] as? Int == schemaVersion else {
            throw RemoteControlError.invalidConfiguration("unsupported schema version")
        }
        guard let rawProfiles = root["profiles"] as? [[String: Any]], !rawProfiles.isEmpty else {
            throw RemoteControlError.invalidConfiguration("at least one profile is required")
        }
        let profileKeys = Set([
            "id", "githubLogin", "displayLabel", "displayColor", "copilotHome", "ghConfigDir",
            "gitConfigGlobal", "allowedGitHubOwners", "commitName", "commitEmail", "copilotExecutable",
            "ghExecutable", "gitExecutable", "herdrExecutable", "zshExecutable", "deskRoot", "workerID",
            "continuationCap", "remote", "autonomy"
        ])
        for raw in rawProfiles {
            if let unknown = Set(raw.keys).subtracting(profileKeys).sorted().first {
                throw RemoteControlError.invalidConfiguration("unknown profile key '\(unknown)'")
            }
        }

        struct Payload: Decodable {
            var profiles: [RemoteProfile]
        }
        let decoded: Payload
        do {
            decoded = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw RemoteControlError.invalidConfiguration("profile fields are missing or have the wrong type")
        }
        try validate(decoded.profiles, executableExists: executableExists)
        return RemoteProfileRegistry(profiles: decoded.profiles)
    }

    public func profile(id: String) throws -> RemoteProfile {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw RemoteControlError.unknownProfile("unknown profile '\(id)'")
        }
        return profile
    }

    private static func validate(_ profiles: [RemoteProfile], executableExists: (String) -> Bool) throws {
        var ids = Set<String>()
        var logins = Set<String>()
        var homes = Set<String>()
        var ghDirs = Set<String>()
        var gitConfigs = Set<String>()
        for profile in profiles {
            guard profile.id.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) != nil else {
                throw RemoteControlError.invalidConfiguration("unsafe profile id")
            }
            guard isGitHubLogin(profile.githubLogin) else {
                throw RemoteControlError.invalidConfiguration("unsafe GitHub login")
            }
            guard isText(profile.displayLabel) else {
                throw RemoteControlError.invalidConfiguration("display label is empty or unsafe")
            }
            guard profile.displayColor.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw RemoteControlError.invalidConfiguration("display color must be a six-digit hex color")
            }
            for path in [profile.copilotHome, profile.ghConfigDir, profile.gitConfigGlobal, profile.deskRoot] {
                guard isAbsoluteNormalized(path) else {
                    throw RemoteControlError.invalidConfiguration("absolute path required: \(path)")
                }
            }
            guard !profile.allowedGitHubOwners.isEmpty else {
                throw RemoteControlError.invalidConfiguration("at least one GitHub owner is required")
            }
            let normalizedOwners = profile.allowedGitHubOwners.map { $0.lowercased() }
            guard profile.allowedGitHubOwners.allSatisfy(isGitHubName) else {
                throw RemoteControlError.invalidConfiguration("unsafe GitHub owner")
            }
            guard Set(normalizedOwners).count == normalizedOwners.count else {
                throw RemoteControlError.invalidConfiguration("duplicate GitHub owner")
            }
            guard isText(profile.commitName) else {
                throw RemoteControlError.invalidConfiguration("commit name is empty or unsafe")
            }
            guard isText(profile.commitEmail), profile.commitEmail.contains("@") else {
                throw RemoteControlError.invalidConfiguration("commit email is invalid")
            }
            for executable in [
                profile.copilotExecutable, profile.ghExecutable, profile.gitExecutable,
                profile.herdrExecutable, profile.zshExecutable
            ] {
                guard isAbsoluteNormalized(executable) else {
                    throw RemoteControlError.invalidConfiguration("absolute path required: \(executable)")
                }
                guard executableExists(executable) else {
                    throw RemoteControlError.invalidConfiguration("missing executable at \(executable)")
                }
            }
            guard profile.workerID.range(of: "^[A-Za-z0-9][A-Za-z0-9:_-]+$", options: .regularExpression) != nil else {
                throw RemoteControlError.invalidConfiguration("worker id is empty or unsafe")
            }
            guard profile.continuationCap == 100 else {
                throw RemoteControlError.invalidConfiguration("continuation cap must be 100")
            }
            guard profile.remote else {
                throw RemoteControlError.invalidConfiguration("remote control must be enabled")
            }
            guard profile.autonomy else {
                throw RemoteControlError.invalidConfiguration("autonomy must be enabled")
            }
            guard ids.insert(profile.id).inserted else {
                throw RemoteControlError.invalidConfiguration("duplicate profile id")
            }
            guard logins.insert(profile.githubLogin.lowercased()).inserted else {
                throw RemoteControlError.invalidConfiguration("duplicate GitHub login")
            }
            guard homes.insert(profile.copilotHome).inserted else {
                throw RemoteControlError.invalidConfiguration("duplicate Copilot home")
            }
            guard ghDirs.insert(profile.ghConfigDir).inserted else {
                throw RemoteControlError.invalidConfiguration("duplicate GitHub config directory")
            }
            guard gitConfigs.insert(profile.gitConfigGlobal).inserted else {
                throw RemoteControlError.invalidConfiguration("duplicate Git config")
            }
        }
    }

    private static func isText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func isGitHubName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil
    }

    private static func isGitHubLogin(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,62}[A-Za-z0-9])?$", options: .regularExpression) != nil
    }

    private static func isAbsoluteNormalized(_ path: String) -> Bool {
        path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
}

public struct RemoteProcessRequest: Equatable, CustomStringConvertible {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var standardInput: Data?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        standardInput: Data? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
    }

    public var description: String {
        "RemoteProcessRequest(executable: \(executable), arguments: \(arguments), environmentKeys: \(environment.keys.sorted()))"
    }
}

public struct RemoteProcessResult: Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct RemoteAccountBroker {
    private static let inheritedEnvironmentKeys = Set([
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "TERM", "LANG",
        "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
        "HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID",
        "HERDR_TAB_ID", "HERDR_SESSION", "HERDR_BIN_PATH"
    ])
    public let registry: RemoteProfileRegistry
    public let environment: [String: String]
    public let workingDirectory: String
    public let shimDirectory: String
    public let profileConfigPath: String
    private let run: (RemoteProcessRequest) throws -> RemoteProcessResult

    public init(
        registry: RemoteProfileRegistry,
        environment: [String: String],
        workingDirectory: String,
        shimDirectory: String,
        profileConfigPath: String,
        run: @escaping (RemoteProcessRequest) throws -> RemoteProcessResult
    ) {
        self.registry = registry
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.shimDirectory = shimDirectory
        self.profileConfigPath = profileConfigPath
        self.run = run
    }

    public func launch(profileID: String, arguments: [String], generation: String, paneID: String) throws -> RemoteProcessRequest {
        guard try Self.resumeUUID(in: arguments) == nil else {
            throw RemoteControlError.resume("session selectors must use durable managed dispatch")
        }
        let profile = try registry.profile(id: profileID)
        return try managedRequest(profile: profile, originalArguments: arguments, generation: generation, paneID: paneID)
    }

    public func dispatch(arguments: [String], sessionMapURL: URL) throws -> RemoteProcessRequest {
        try Self.validateManagedCopilotArguments(arguments)
        guard environment["HERDR_ENV"] == "1" else {
            throw RemoteControlError.resume("managed dispatch is unavailable outside Herdr")
        }
        guard let canonical = try Self.resumeUUID(in: arguments) else {
            let generation = try Self.exactHerdrContext(environment: environment, ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION")
            let paneID = try Self.exactHerdrContext(environment: environment, ouroKey: "OURO_PANE_ID", herdrKey: "HERDR_PANE_ID")
            let entries = try RemoteSessionMapStore.read(mapURL: sessionMapURL, registry: registry)
            let matches = entries.filter { $0.generation == generation && $0.paneID == paneID }
            guard matches.count == 1 else { throw RemoteControlError.resume("Herdr pane has no unique durable session map context") }
            let mapping = matches[0]
            if let ambientProfile = environment["OURO_PROFILE_ID"], ambientProfile != mapping.profileID {
                throw RemoteControlError.resume("Herdr profile context disagrees with durable session ownership")
            }
            return try managedRequest(
                profile: registry.profile(id: mapping.profileID),
                originalArguments: arguments,
                generation: generation,
                paneID: paneID
            )
        }
        let entries = try RemoteSessionMapStore.read(mapURL: sessionMapURL, registry: registry)
        let matches = entries.filter { $0.sessionID == canonical }
        guard matches.count == 1 else {
            throw RemoteControlError.resume("resume UUID has no unique session map entry")
        }
        let mapping = matches[0]
        let profile = try registry.profile(id: mapping.profileID)
        return try managedRequest(profile: profile, originalArguments: arguments, generation: mapping.generation, paneID: mapping.paneID)
    }

    private static func exactHerdrContext(environment: [String: String], ouroKey: String, herdrKey: String) throws -> String {
        let values = [environment[ouroKey], environment[herdrKey]].compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let selected = values.first else { throw RemoteControlError.resume("exact Herdr pane context is required") }
        guard values.allSatisfy({ $0 == selected }) else { throw RemoteControlError.resume("Herdr pane context values disagree") }
        return selected
    }

    public static func resumeUUID(in arguments: [String]) throws -> String? {
        var resumeUUID: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            let raw: String
            if argument == "--continue" || argument.hasPrefix("--continue=") ||
                argument == "--connect" || argument.hasPrefix("--connect=")
            {
                throw RemoteControlError.resume("ambiguous Copilot resume/session selectors are unsupported")
            }
            if argument.hasPrefix("--resume=") {
                raw = String(argument.dropFirst("--resume=".count))
            } else if argument.hasPrefix("--session-id=") {
                raw = String(argument.dropFirst("--session-id=".count))
            } else if argument == "--resume" || argument == "-r" || argument == "--session-id" {
                index += 1
                guard index < arguments.count else { throw RemoteControlError.resume("an exact resume UUID value is required") }
                raw = arguments[index]
            } else {
                guard !argument.hasPrefix("--resume"), !argument.hasPrefix("-r"),
                      !argument.hasPrefix("--session-id"), !argument.hasPrefix("--connect"),
                      !argument.hasPrefix("--continue")
                else { throw RemoteControlError.resume("unsupported resume argument spelling") }
                index += 1
                continue
            }
            guard resumeUUID == nil, let uuid = UUID(uuidString: raw) else { throw RemoteControlError.resume("exactly one valid resume UUID is required") }
            resumeUUID = uuid.uuidString.lowercased()
            index += 1
        }
        return resumeUUID
    }

    public static func managedCopilotArguments(profile: RemoteProfile, originalArguments: [String]) -> [String] {
        [
            "--agent", profile.workerID,
            "--allow-all",
            "--remote",
            "--mode", "autopilot",
            "--max-autopilot-continues", String(profile.continuationCap),
            "--no-auto-update",
            "--secret-env-vars=COPILOT_GITHUB_TOKEN,GH_TOKEN,GITHUB_TOKEN"
        ] + originalArguments
    }

    public func resume(
        nativeSessionID: String,
        profileID: String,
        generation: String,
        paneID: String,
        sessionMapURL: URL
    ) throws -> RemoteProcessRequest {
        guard let uuid = UUID(uuidString: nativeSessionID), !generation.isEmpty, !paneID.isEmpty else {
            throw RemoteControlError.resume("exact resume UUID, generation, and pane are required")
        }
        let canonical = uuid.uuidString.lowercased()
        let entries = try RemoteSessionMapStore.read(mapURL: sessionMapURL, registry: registry)
        let matches = entries.filter { $0.sessionID == canonical }
        guard matches.count == 1, matches[0].profileID == profileID, matches[0].paneID == paneID else {
            throw RemoteControlError.resume("resume tuple does not match durable prior ownership")
        }
        return try managedRequest(
            profile: registry.profile(id: profileID),
            originalArguments: ["--resume=\(canonical)"],
            generation: generation,
            paneID: paneID
        )
    }

    public func gh(profileID: String, arguments: [String], remoteURLs: [String]) throws -> RemoteProcessRequest {
        let profile = try registry.profile(id: profileID)
        guard arguments.first != "auth" else {
            throw RemoteControlError.repository("GitHub authentication commands are unavailable through the managed shim")
        }
        try validateGitHubCommandSurface(arguments, profile: profile)
        try Self.validateGitHubHostname(arguments)
        if arguments.first == "api", arguments.dropFirst().contains(where: Self.isGraphQLEndpoint) {
            throw RemoteControlError.repository("GraphQL mutation and query shapes are unsupported by the managed gh shim")
        }
        if arguments.first == "api", arguments.dropFirst().contains(where: Self.isAmbiguousAPIEndpoint) {
            throw RemoteControlError.repository("ambiguous GitHub API target is unsupported by the managed gh shim")
        }
        let mutation = Self.ghMutates(arguments)
        let explicitOwners = try Self.explicitGitHubOwners(arguments)
        if arguments.first == "api", mutation, explicitOwners.isEmpty {
            throw RemoteControlError.repository("mutating GitHub API target does not prove an allowed owner")
        }
        try Self.validateExplicitOwners(explicitOwners, profile: profile, remoteURLs: remoteURLs)
        try RemoteRepositoryPolicy.validate(
            remoteURLs: remoteURLs,
            allowedOwners: profile.allowedGitHubOwners,
            mutation: mutation
        )
        return RemoteProcessRequest(
            executable: profile.ghExecutable,
            arguments: arguments,
            environment: managedGitEnvironment(profile),
            workingDirectory: workingDirectory
        )
    }

    public func git(profileID: String, arguments: [String], remoteURLs: [String]) throws -> RemoteProcessRequest {
        let profile = try registry.profile(id: profileID)
        if arguments.first == "credential" {
            throw RemoteControlError.repository("Git credential plumbing is unavailable through the managed shim")
        }
        if arguments.first?.hasPrefix("-") == true {
            throw RemoteControlError.repository("target-changing Git option is not supported by the managed shim")
        }
        try Self.validateExplicitOwners(
            try Self.explicitGitHubOwners(inGitArguments: arguments),
            profile: profile,
            remoteURLs: remoteURLs
        )
        try RemoteRepositoryPolicy.validate(
            remoteURLs: remoteURLs,
            allowedOwners: profile.allowedGitHubOwners,
            mutation: Self.gitMutates(arguments)
        )
        return RemoteProcessRequest(
            executable: profile.gitExecutable,
            arguments: arguments,
            environment: managedGitEnvironment(profile),
            workingDirectory: workingDirectory
        )
    }

    public func repositoryRemoteURLs(profileID: String) throws -> [String] {
        try repositoryRemoteURLs(profile: registry.profile(id: profileID))
    }

    private func managedRequest(
        profile: RemoteProfile,
        originalArguments: [String],
        generation: String,
        paneID: String
    ) throws -> RemoteProcessRequest {
        try Self.validateManagedCopilotArguments(originalArguments)
        let baseEnvironment = sanitizedEnvironment()
        var ghEnvironment = baseEnvironment
        ghEnvironment["GH_CONFIG_DIR"] = profile.ghConfigDir
        let tokenResult: RemoteProcessResult
        do {
            tokenResult = try run(RemoteProcessRequest(
                executable: profile.ghExecutable,
                arguments: ["auth", "token", "--user", profile.githubLogin],
                environment: ghEnvironment,
                workingDirectory: workingDirectory
            ))
        } catch {
            throw RemoteControlError.dependency("GitHub token lookup failed")
        }
        guard tokenResult.exitCode == 0 else {
            throw RemoteControlError.dependency("GitHub token lookup failed")
        }
        let token = String(decoding: tokenResult.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw RemoteControlError.dependency("GitHub token lookup returned no credential")
        }
        var validationEnvironment = ghEnvironment
        validationEnvironment["GH_TOKEN"] = token
        let identityResult: RemoteProcessResult
        do {
            identityResult = try run(RemoteProcessRequest(
                executable: profile.ghExecutable,
                arguments: ["api", "/user"],
                environment: validationEnvironment,
                workingDirectory: workingDirectory
            ))
        } catch {
            throw RemoteControlError.dependency("GitHub identity validation failed")
        }
        guard identityResult.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: identityResult.stdout) as? [String: Any],
              let actual = object["login"] as? String
        else {
            throw RemoteControlError.dependency("GitHub identity response was invalid")
        }
        guard actual == profile.githubLogin else {
            throw RemoteControlError.dependency("GitHub account mismatch; expected \(profile.githubLogin)")
        }

        let remotes = try repositoryRemoteURLs(profile: profile)
        if !remotes.isEmpty {
            try RemoteRepositoryPolicy.validate(
                remoteURLs: remotes,
                allowedOwners: profile.allowedGitHubOwners,
                mutation: true
            )
        }

        var childEnvironment = managedChildEnvironment(profile)
        childEnvironment["COPILOT_GITHUB_TOKEN"] = token
        childEnvironment["COPILOT_HOME"] = profile.copilotHome
        childEnvironment["OURO_PROFILE_ID"] = profile.id
        childEnvironment["OURO_GENERATION"] = generation
        childEnvironment["OURO_PANE_ID"] = paneID
        childEnvironment["OURO_DESK_ROOT"] = profile.deskRoot
        childEnvironment["OURO_REMOTE_CONFIG"] = profileConfigPath
        return RemoteProcessRequest(
            executable: profile.copilotExecutable,
            arguments: Self.managedCopilotArguments(profile: profile, originalArguments: originalArguments),
            environment: childEnvironment,
            workingDirectory: workingDirectory
        )
    }

    private func repositoryRemoteURLs(profile: RemoteProfile) throws -> [String] {
        let environment = gitEnvironment(profile)
        let namesResult: RemoteProcessResult
        do {
            namesResult = try run(RemoteProcessRequest(
                executable: profile.gitExecutable,
                arguments: ["remote"],
                environment: environment,
                workingDirectory: workingDirectory
            ))
        } catch {
            throw RemoteControlError.repository("repository inspection failed")
        }
        guard namesResult.exitCode == 0 else {
            throw RemoteControlError.repository("repository inspection failed")
        }
        let names = String(decoding: namesResult.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        var urls: [String] = []
        for name in names {
            for arguments in [
                ["remote", "get-url", "--all", "--", name],
                ["remote", "get-url", "--push", "--all", "--", name]
            ] {
                let result: RemoteProcessResult
                do {
                    result = try run(RemoteProcessRequest(
                        executable: profile.gitExecutable,
                        arguments: arguments,
                        environment: environment,
                        workingDirectory: workingDirectory
                    ))
                } catch {
                    throw RemoteControlError.repository("repository inspection failed")
                }
                guard result.exitCode == 0 else {
                    throw RemoteControlError.repository("repository inspection failed")
                }
                urls.append(contentsOf: String(decoding: result.stdout, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map(String.init))
            }
        }
        return urls
    }

    private func sanitizedEnvironment() -> [String: String] {
        environment.filter { key, _ in
            Self.inheritedEnvironmentKeys.contains(key) || key.hasPrefix("LC_")
        }
    }

    private func gitEnvironment(_ profile: RemoteProfile) -> [String: String] {
        var clean = sanitizedEnvironment()
        clean["GH_CONFIG_DIR"] = profile.ghConfigDir
        clean["GIT_CONFIG_GLOBAL"] = profile.gitConfigGlobal
        return clean
    }

    private func managedGitEnvironment(_ profile: RemoteProfile) -> [String: String] {
        var clean = gitEnvironment(profile)
        clean["GIT_CONFIG_NOSYSTEM"] = "1"
        clean["GIT_TERMINAL_PROMPT"] = "0"
        clean["GIT_AUTHOR_NAME"] = profile.commitName
        clean["GIT_AUTHOR_EMAIL"] = profile.commitEmail
        clean["GIT_COMMITTER_NAME"] = profile.commitName
        clean["GIT_COMMITTER_EMAIL"] = profile.commitEmail
        clean["GIT_CONFIG_COUNT"] = "7"
        clean["GIT_CONFIG_KEY_0"] = "user.name"
        clean["GIT_CONFIG_VALUE_0"] = profile.commitName
        clean["GIT_CONFIG_KEY_1"] = "user.email"
        clean["GIT_CONFIG_VALUE_1"] = profile.commitEmail
        clean["GIT_CONFIG_KEY_2"] = "credential.helper"
        clean["GIT_CONFIG_VALUE_2"] = ""
        clean["GIT_CONFIG_KEY_3"] = "credential.https://github.com.helper"
        clean["GIT_CONFIG_VALUE_3"] = "!\(RemoteShellBootstrap.quote(profile.ghExecutable)) auth git-credential"
        clean["GIT_CONFIG_KEY_4"] = "url.https://github.com/.insteadOf"
        clean["GIT_CONFIG_VALUE_4"] = "git@github.com:"
        clean["GIT_CONFIG_KEY_5"] = "url.https://github.com/.insteadOf"
        clean["GIT_CONFIG_VALUE_5"] = "ssh://git@github.com/"
        clean["GIT_CONFIG_KEY_6"] = "url.https://github.com/.insteadOf"
        clean["GIT_CONFIG_VALUE_6"] = "github.com:"
        clean["PATH"] = shimDirectory + ":" + (clean["PATH"] ?? "/usr/bin:/bin")
        return clean
    }

    private func managedChildEnvironment(_ profile: RemoteProfile) -> [String: String] {
        var clean = sanitizedEnvironment()
        clean["GH_CONFIG_DIR"] = "/dev/null"
        clean["GIT_CONFIG_GLOBAL"] = "/dev/null"
        clean["GIT_CONFIG_NOSYSTEM"] = "1"
        clean["GIT_TERMINAL_PROMPT"] = "0"
        clean["GIT_AUTHOR_NAME"] = profile.commitName
        clean["GIT_AUTHOR_EMAIL"] = profile.commitEmail
        clean["GIT_COMMITTER_NAME"] = profile.commitName
        clean["GIT_COMMITTER_EMAIL"] = profile.commitEmail
        clean["GIT_CONFIG_COUNT"] = "4"
        clean["GIT_CONFIG_KEY_0"] = "user.name"
        clean["GIT_CONFIG_VALUE_0"] = profile.commitName
        clean["GIT_CONFIG_KEY_1"] = "user.email"
        clean["GIT_CONFIG_VALUE_1"] = profile.commitEmail
        clean["GIT_CONFIG_KEY_2"] = "credential.helper"
        clean["GIT_CONFIG_VALUE_2"] = ""
        clean["GIT_CONFIG_KEY_3"] = "credential.https://github.com.helper"
        clean["GIT_CONFIG_VALUE_3"] = ""
        clean["PATH"] = shimDirectory + ":" + (clean["PATH"] ?? "/usr/bin:/bin")
        return clean
    }

    private static func ghMutates(_ arguments: [String]) -> Bool {
        guard let command = arguments.first else { return false }
        if command == "api" {
            var hasExplicitMethod = false
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                let method: String?
                if argument == "--method" || argument == "-X" {
                    method = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                    index += method == nil ? 1 : 2
                } else if argument.hasPrefix("--method=") {
                    method = String(argument.dropFirst("--method=".count))
                    index += 1
                } else if argument.hasPrefix("-X"), argument != "-X" {
                    method = String(argument.dropFirst(argument.hasPrefix("-X=") ? 3 : 2))
                    index += 1
                } else {
                    method = nil
                    index += 1
                }
                if let method, !method.isEmpty {
                    hasExplicitMethod = true
                    if method.uppercased() != "GET" { return true }
                }
            }
            if hasExplicitMethod { return false }
            return arguments.contains { argument in
                argument == "-f" || argument == "-F" || argument == "--field" || argument == "--raw-field"
                    || argument == "--input"
                    || (argument.hasPrefix("-f") && argument != "-f")
                    || (argument.hasPrefix("-F") && argument != "-F")
                    || argument.hasPrefix("--field=") || argument.hasPrefix("--raw-field=")
                    || argument.hasPrefix("--input=")
            }
        }
        let subcommand = arguments.dropFirst().first ?? ""
        let reads: Set<String> = ["view", "list", "status", "checks", "diff"]
        return !(["pr", "issue", "repo", "run"].contains(command) && reads.contains(subcommand))
            && command != "auth" && command != "search"
    }

    private static func gitMutates(_ arguments: [String]) -> Bool {
        guard let command = arguments.first else { return false }
        if command == "remote" {
            let subcommand = arguments.dropFirst().first { !$0.hasPrefix("-") }
            return subcommand.map { !["show", "get-url"].contains($0) } ?? false
        }
        return !["status", "log", "diff", "show", "rev-parse", "ls-files"].contains(command)
    }

    private static func validateManagedCopilotArguments(_ arguments: [String]) throws {
        let managed = Set([
            "--agent", "--allow-all", "--remote", "--mode", "--max-autopilot-continues",
            "--no-auto-update", "--secret-env-vars", "--no-remote", "--no-remote-export",
            "--no-ask-user", "--assisted-approval"
        ])
        let valueOptions = Set(["--prompt", "-p", "--interactive", "-i", "--model"])
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return }
            let name = String(argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
            guard !managed.contains(name) else {
                throw RemoteControlError.invalidConfiguration("managed Copilot policy argument '\(name)' cannot be overridden")
            }
            index += valueOptions.contains(name) && !argument.contains("=") ? 2 : 1
        }
    }

    private static func validateExplicitOwners(_ explicitOwners: Set<String>, profile: RemoteProfile, remoteURLs: [String]) throws {
        let allowed = Set(profile.allowedGitHubOwners.map { $0.lowercased() })
        guard explicitOwners.isSubset(of: allowed) else {
            throw RemoteControlError.repository("explicit GitHub owner is not allowed for this profile")
        }
        if !explicitOwners.isEmpty, !remoteURLs.isEmpty {
            let cwdOwners = try RemoteRepositoryPolicy.owners(from: remoteURLs)
            guard cwdOwners == explicitOwners else {
                throw RemoteControlError.repository("explicit GitHub owner does not match the current repository")
            }
        }
    }

    private static func explicitGitHubOwners(inGitArguments arguments: [String]) throws -> Set<String> {
        let targets = arguments.compactMap { argument -> String? in
            let candidate = argument.hasPrefix("--repo=") ? String(argument.dropFirst("--repo=".count)) : argument
            if candidate.hasPrefix("github.com:") { return "git@\(candidate)" }
            if candidate.range(of: "^[^/\\s:]+@[^/\\s:]+:.+$", options: .regularExpression) != nil { return candidate }
            if candidate.range(of: "^[^/\\s:]+\\.[^/\\s:]+:.+/.+$", options: .regularExpression) != nil { return candidate }
            if candidate.range(of: "^[A-Za-z][A-Za-z0-9+.-]*::", options: .regularExpression) != nil { return candidate }
            guard candidate.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil else { return nil }
            return candidate
        }
        return targets.isEmpty ? [] : try RemoteRepositoryPolicy.owners(from: targets)
    }

    private static func explicitGitHubOwners(_ arguments: [String]) throws -> Set<String> {
        var targets: [String] = []
        var index = 0
        let command = arguments.first
        let shortOwnerCommand = ["attestation", "codespace", "ruleset", "secret", "status", "variable"].contains(command)
        while index < arguments.count {
            let argument = arguments[index]
            if ["--owner", "--org", "--repo-owner"].contains(argument) || (argument == "-o" && shortOwnerCommand) {
                guard arguments.indices.contains(index + 1) else {
                    throw RemoteControlError.repository("explicit GitHub owner target is missing")
                }
                targets.append(arguments[index + 1])
                index += 2
                continue
            }
            if ["--owner=", "--org=", "--repo-owner="].contains(where: argument.hasPrefix), let separator = argument.firstIndex(of: "=") {
                targets.append(String(argument[argument.index(after: separator)...]))
            }
            if shortOwnerCommand, argument.hasPrefix("-o"), argument != "-o" {
                targets.append(String(argument.dropFirst(argument.hasPrefix("-o=") ? 3 : 2)))
            }
            if argument == "-R" || argument == "--repo" {
                guard arguments.indices.contains(index + 1) else {
                    throw RemoteControlError.repository("explicit GitHub repository target is missing")
                }
                targets.append(try normalizedRepositoryTarget(arguments[index + 1]))
                index += 2
                continue
            }
            if argument.hasPrefix("--repo=") {
                targets.append(try normalizedRepositoryTarget(String(argument.dropFirst("--repo=".count))))
            }
            if argument.hasPrefix("-R"), argument != "-R" {
                let value = String(argument.dropFirst(argument.hasPrefix("-R=") ? 3 : 2))
                targets.append(try normalizedRepositoryTarget(value))
            }
            if ["/repos/", "repos/", "/orgs/", "orgs/", "/users/", "users/"].contains(where: argument.hasPrefix) {
                targets.append(contentsOf: try ownerTargets(inAPIPath: argument))
            } else if let url = URL(string: argument), url.host?.lowercased() == "api.github.com" {
                guard isSafeGitHubURL(url) else {
                    throw RemoteControlError.repository("unsupported GitHub URL")
                }
                targets.append(contentsOf: try ownerTargets(inAPIPath: url.path))
            } else if let url = URL(string: argument), url.host?.lowercased() == "github.com" {
                guard isSafeGitHubURL(url) else {
                    throw RemoteControlError.repository("unsupported GitHub URL")
                }
                targets.append(contentsOf: try repositoryTargets(inGitHubPath: url.path))
            } else if let url = URL(string: argument), url.scheme != nil, url.host != nil {
                throw RemoteControlError.repository("unsupported GitHub URL")
            }
            index += 1
        }
        if arguments.first == "repo", !["list", "ls"].contains(arguments.dropFirst().first ?? "") {
            for argument in arguments.dropFirst(2) {
                let candidate = argument.split(separator: "=", maxSplits: 1).last.map(String.init) ?? argument
                let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
                if (components.count == 2 || components.count == 3), !candidate.hasPrefix("-") {
                    targets.append(try normalizedRepositoryTarget(candidate))
                }
            }
        }
        targets.append(contentsOf: try ownerBearingPositionalTargets(arguments))
        var owners = Set<String>()
        for target in targets {
            let owner = String(target[..<(target.firstIndex(of: "/") ?? target.endIndex)])
            guard owner.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil else {
                throw RemoteControlError.repository("explicit GitHub repository target is unsafe")
            }
            owners.insert(owner.lowercased())
        }
        return owners
    }

    private static func ownerBearingPositionalTargets(_ arguments: [String]) throws -> [String] {
        let command = Array(arguments.prefix(2))
        let positionals: [String]
        if command == ["issue", "transfer"] {
            positionals = try ghPositionals(
                Array(arguments.dropFirst(2)),
                valueOptions: ["-R", "--repo"],
                flagOptions: ["--help"]
            )
            if arguments.contains("--help") { return [] }
            guard positionals.count == 2 else {
                throw RemoteControlError.repository("owner-bearing GitHub command shape is unsupported by the managed shim")
            }
            return [try normalizedRepositoryTarget(positionals[1])]
        }
        if command == ["repo", "list"] || command == ["repo", "ls"] {
            positionals = try ghPositionals(
                Array(arguments.dropFirst(2)),
                valueOptions: ["-q", "--jq", "--json", "-l", "--language", "-L", "--limit", "-t", "--template", "--topic", "--visibility"],
                flagOptions: ["--archived", "--fork", "--help", "--no-archived", "--source"]
            )
            guard positionals.count <= 1 else {
                throw RemoteControlError.repository("owner-bearing GitHub command shape is unsupported by the managed shim")
            }
            return positionals
        }
        if command == ["label", "clone"] {
            positionals = try ghPositionals(
                Array(arguments.dropFirst(2)),
                valueOptions: ["-R", "--repo"],
                flagOptions: ["-f", "--force", "--help"]
            )
            if arguments.contains("--help") { return [] }
            guard positionals.count == 1 else {
                throw RemoteControlError.repository("owner-bearing GitHub command shape is unsupported by the managed shim")
            }
            return [try normalizedRepositoryTarget(positionals[0])]
        }
        return []
    }

    private static func ghPositionals(
        _ arguments: [String],
        valueOptions: Set<String>,
        flagOptions: Set<String>
    ) throws -> [String] {
        var positionals: [String] = []
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, argument.hasPrefix("--") {
                let option = String(argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                if flagOptions.contains(option), !argument.contains("=") {
                    index += 1
                    continue
                }
                if valueOptions.contains(option) {
                    if argument.contains("=") {
                        guard !argument.hasSuffix("=") else {
                            throw RemoteControlError.repository("owner-bearing GitHub command option value is missing")
                        }
                        index += 1
                    } else {
                        guard arguments.indices.contains(index + 1) else {
                            throw RemoteControlError.repository("owner-bearing GitHub command option value is missing")
                        }
                        index += 2
                    }
                    continue
                }
                throw RemoteControlError.repository("owner-bearing GitHub command option is unsupported by the managed shim")
            }
            if !optionsEnded, argument.hasPrefix("-"), argument != "-" {
                if flagOptions.contains(argument) {
                    index += 1
                    continue
                }
                if valueOptions.contains(argument) {
                    guard arguments.indices.contains(index + 1) else {
                        throw RemoteControlError.repository("owner-bearing GitHub command option value is missing")
                    }
                    index += 2
                    continue
                }
                if valueOptions.contains(where: { $0.count == 2 && argument.hasPrefix($0) }) {
                    index += 1
                    continue
                }
                throw RemoteControlError.repository("owner-bearing GitHub command option is unsupported by the managed shim")
            }
            positionals.append(argument)
            index += 1
        }
        return positionals
    }

    private func validateGitHubCommandSurface(_ arguments: [String], profile: RemoteProfile) throws {
        guard let command = arguments.first else { return }
        if ["--help", "--version", "help"].contains(command) { return }
        let coreCommands = Set([
            "agent-task", "api", "attestation", "browse", "cache", "codespace", "discussion", "gist",
            "gpg-key", "issue", "label", "licenses", "org", "pr", "project", "release", "repo",
            "ruleset", "run", "search", "secret", "ssh-key", "status", "variable", "workflow"
        ])
        guard coreCommands.contains(command) else {
            throw RemoteControlError.repository("opaque GitHub aliases and extensions are unavailable through the managed shim")
        }
        let aliases: RemoteProcessResult
        do {
            aliases = try run(RemoteProcessRequest(
                executable: profile.ghExecutable,
                arguments: ["alias", "list"],
                environment: gitEnvironment(profile),
                workingDirectory: workingDirectory
            ))
        } catch {
            throw RemoteControlError.repository("configured GitHub aliases could not be verified")
        }
        guard aliases.exitCode == 0 else {
            throw RemoteControlError.repository("configured GitHub aliases could not be verified")
        }
        guard String(decoding: aliases.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteControlError.repository("configured GitHub aliases are unavailable through the managed shim")
        }
    }

    private static func ownerTargets(inAPIPath path: String) throws -> [String] {
        let components = try safePathComponents(path)
        guard let namespace = components.first, ["repos", "orgs", "users"].contains(namespace), components.indices.contains(1) else { return [] }
        return [components[1]]
    }

    private static func repositoryTargets(inGitHubPath path: String) throws -> [String] {
        let components = try safePathComponents(path)
        guard components.count >= 2 else { return [] }
        return [try normalizedRepositoryTarget("\(components[0])/\(components[1])")]
    }

    private static func normalizedRepositoryTarget(_ target: String) throws -> String {
        let components = try safePathComponents(target)
        let repository: [String]
        if components.count == 2 {
            repository = components
        } else if components.count == 3, components[0].lowercased() == "github.com" {
            repository = Array(components.dropFirst())
        } else {
            throw RemoteControlError.repository("explicit GitHub repository target is unsafe")
        }
        guard repository[1].range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil,
              repository[1] != ".",
              repository[1] != ".."
        else {
            throw RemoteControlError.repository("explicit GitHub repository target is unsafe")
        }
        return repository.joined(separator: "/")
    }

    private static func safePathComponents(_ value: String) throws -> [String] {
        let path = apiPath(value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { return [] }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RemoteControlError.repository("explicit GitHub repository target path is unsafe")
        }
        return components
    }

    private static func isSafeGitHubURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.port == nil && url.user == nil && url.password == nil
    }

    private static func validateGitHubHostname(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let hostname: String?
            if argument == "--hostname" {
                guard arguments.indices.contains(index + 1) else {
                    throw RemoteControlError.repository("explicit GitHub hostname is missing")
                }
                hostname = arguments[index + 1]
                index += 1
            } else if argument.hasPrefix("--hostname=") {
                hostname = String(argument.dropFirst("--hostname=".count))
            } else {
                hostname = nil
            }
            guard hostname == nil || hostname?.lowercased() == "github.com" else {
                throw RemoteControlError.repository("explicit GitHub hostname is unsupported")
            }
            index += 1
        }
    }

    private static func isGraphQLEndpoint(_ argument: String) -> Bool {
        apiPath(argument).split(separator: "/").map(String.init) == ["graphql"]
    }

    private static func isAmbiguousAPIEndpoint(_ argument: String) -> Bool {
        apiPath(argument).split(separator: "/").first == "repositories"
    }

    private static func apiPath(_ argument: String) -> String {
        if let url = URL(string: argument), !url.path.isEmpty { return url.path }
        return argument
    }
}

public enum RemoteRepositoryPolicy {
    public static func owners(from remoteURLs: [String]) throws -> Set<String> {
        var owners = Set<String>()
        for remote in remoteURLs {
            let owner: String?
            if remote.hasPrefix("git@github.com:") {
                owner = repositoryOwner(in: String(remote.dropFirst("git@github.com:".count)))
            } else if let url = URL(string: remote), isSupportedGitHubRemote(url) {
                owner = repositoryOwner(in: url.path)
            } else {
                owner = nil
            }
            guard let owner, !owner.isEmpty else {
                throw RemoteControlError.repository("unsupported repository remote")
            }
            owners.insert(owner.lowercased())
        }
        return owners
    }

    private static func isSupportedGitHubRemote(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "github.com",
              url.port == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return false
        }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || (scheme == "ssh" && url.user == "git")
    }

    private static func repositoryOwner(in path: String) -> String? {
        let components = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 2,
              components[0].range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil
        else {
            return nil
        }
        let repository = components[1].hasSuffix(".git") ? String(components[1].dropLast(4)) : components[1]
        guard repository.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil,
              repository != ".",
              repository != ".."
        else {
            return nil
        }
        return components[0]
    }

    public static func validate(remoteURLs: [String], allowedOwners: [String], mutation: Bool) throws {
        guard !remoteURLs.isEmpty else {
            if mutation {
                throw RemoteControlError.repository("repository remote is required for mutation")
            }
            return
        }
        let found = try owners(from: remoteURLs)
        guard found.count == 1 else {
            throw RemoteControlError.repository("mixed repository owners are ambiguous")
        }
        let allowed = Set(allowedOwners.map { $0.lowercased() })
        guard found.isSubset(of: allowed) else {
            throw RemoteControlError.repository("repository owner is not allowed for this profile")
        }
    }
}
