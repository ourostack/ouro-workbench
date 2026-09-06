import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteAccountSafetyTests: XCTestCase {
    func testRemoteControlErrorsDescribeEverySafetyBoundary() {
        let cases: [(RemoteControlError, String)] = [
            (.invalidConfiguration("detail"), "Invalid remote configuration: detail"),
            (.unknownProfile("detail"), "Unknown profile: detail"),
            (.dependency("detail"), "detail"),
            (.invalidSessionMap("detail"), "Invalid session map: detail"),
            (.invalidHook("detail"), "Invalid session hook: detail"),
            (.resume("detail"), "Resume failed: detail"),
            (.repository("detail"), "Repository policy failed: detail"),
            (.ledger("detail"), "Resume ledger failed: detail"),
            (.guardian("detail"), "Guardian failed: detail"),
            (.observation("detail"), "Observer failed: detail"),
            (.artifact("detail"), "Runtime artifact failed: detail")
        ]

        for (error, description) in cases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    func testRegistryDecodesStrictCompleteProfiles() throws {
        let registry = try remoteRegistry()

        XCTAssertEqual(registry.profiles.map(\.id), ["personal", "emu"])
        XCTAssertEqual(try registry.profile(id: "personal").githubLogin, "arimendelow")
        assertRemoteErrorContains("unknown profile") { _ = try registry.profile(id: "missing") }
    }

    func testRegistryRejectsUnknownTopLevelAndProfileKeys() throws {
        var top = remoteRegistryObject()
        top["surprise"] = true
        assertInvalid(top, contains: "unknown configuration key")

        var nested = remoteRegistryObject()
        var profiles = try XCTUnwrap(nested["profiles"] as? [[String: Any]])
        profiles[0]["surprise"] = true
        nested["profiles"] = profiles
        assertInvalid(nested, contains: "unknown profile key")
    }

    func testRegistryRejectsSchemaShapeAndUnsafeValuesBeforeMutation() throws {
        var cases: [([String: Any], String)] = []
        var object = remoteRegistryObject()
        object["schemaVersion"] = 2
        cases.append((object, "schema version"))
        object = remoteRegistryObject(profileCount: 0)
        cases.append((object, "at least one profile"))

        let mutations: [(String, Any, String)] = [
            ("id", "../bad", "profile id"),
            ("githubLogin", "-bad", "GitHub login"),
            ("displayLabel", "", "display label"),
            ("displayColor", "purple", "display color"),
            ("copilotHome", "relative", "absolute path"),
            ("ghConfigDir", "", "absolute path"),
            ("gitConfigGlobal", "relative", "absolute path"),
            ("allowedGitHubOwners", ["bad/owner"], "GitHub owner"),
            ("commitName", "\n", "commit name"),
            ("commitEmail", "not-an-email", "commit email"),
            ("copilotExecutable", "copilot", "absolute path"),
            ("ghExecutable", "gh", "absolute path"),
            ("gitExecutable", "git", "absolute path"),
            ("herdrExecutable", "herdr", "absolute path"),
            ("zshExecutable", "zsh", "absolute path"),
            ("deskRoot", "desk", "absolute path"),
            ("workerID", "", "worker id"),
            ("continuationCap", 5, "continuation cap"),
            ("remote", false, "remote"),
            ("autonomy", false, "autonomy")
        ]
        for mutation in mutations {
            object = remoteRegistryObject()
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
            profiles[0][mutation.0] = mutation.1
            object["profiles"] = profiles
            cases.append((object, mutation.2))
        }

        for (candidate, expected) in cases {
            assertInvalid(candidate, contains: expected)
        }
    }

    func testRegistryRejectsParserAndDecoderBoundariesAndUsesDefaultExecutableCheck() throws {
        assertRemoteErrorContains("not valid JSON") {
            _ = try RemoteProfileRegistry.decode(Data("{".utf8), executableExists: { _ in true })
        }
        assertRemoteErrorContains("top level must be an object") {
            _ = try RemoteProfileRegistry.decode(try remoteJSONData(["profile"]), executableExists: { _ in true })
        }

        var wrongType = remoteRegistryObject()
        var profiles = try XCTUnwrap(wrongType["profiles"] as? [[String: Any]])
        profiles[0]["continuationCap"] = "100"
        wrongType["profiles"] = profiles
        assertInvalid(wrongType, contains: "wrong type")

        var noOwners = remoteRegistryObject()
        profiles = try XCTUnwrap(noOwners["profiles"] as? [[String: Any]])
        profiles[0]["allowedGitHubOwners"] = []
        noOwners["profiles"] = profiles
        assertInvalid(noOwners, contains: "at least one GitHub owner")

        var realExecutables = remoteRegistryObject()
        profiles = try XCTUnwrap(realExecutables["profiles"] as? [[String: Any]])
        for index in profiles.indices {
            for key in ["copilotExecutable", "ghExecutable", "gitExecutable", "herdrExecutable", "zshExecutable"] {
                profiles[index][key] = "/bin/sh"
            }
        }
        realExecutables["profiles"] = profiles
        XCTAssertEqual(try RemoteProfileRegistry.decode(remoteJSONData(realExecutables), credentialStoreResolver: remoteFixtureCredentialStore).profiles.count, 2)
    }

    func testRegistryRejectsDuplicateIdentityAndStorageBoundaries() throws {
        let keys = ["id", "githubLogin", "copilotHome", "ghConfigDir", "gitConfigGlobal"]
        for key in keys {
            var object = remoteRegistryObject()
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
            profiles[1][key] = profiles[0][key]
            object["profiles"] = profiles
            assertInvalid(object, contains: "duplicate")
        }

        var owners = remoteRegistryObject()
        var profiles = try XCTUnwrap(owners["profiles"] as? [[String: Any]])
        profiles[0]["allowedGitHubOwners"] = ["ourostack", "OUROSTACK"]
        owners["profiles"] = profiles
        assertInvalid(owners, contains: "duplicate GitHub owner")
    }

    func testRegistryRejectsDuplicateLogicalStoresEvenWhenAResolverReturnsDistinctIdentities() throws {
        let cases = [
            ("copilotHome", "duplicate Copilot home"),
            ("ghConfigDir", "duplicate GitHub config directory"),
            ("gitConfigGlobal", "duplicate Git config")
        ]
        for (key, expected) in cases {
            var object = remoteRegistryObject()
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
            profiles[1][key] = profiles[0][key]
            object["profiles"] = profiles
            var sequence = 0
            assertRemoteErrorContains(expected) {
                _ = try RemoteProfileRegistry.decode(
                    try remoteJSONData(object),
                    executableExists: { _ in true },
                    credentialStoreResolver: { path, _ in
                        sequence += 1
                        return (path, "unique-\(sequence)")
                    }
                )
            }
        }
    }

    func testPhysicalCredentialStoreResolverRejectsEveryUnsafeFilesystemShape() throws {
        let cases = ["non-normalized-path", "missing-directory", "missing-parent", "unsafe-parent-mode", "directory-is-file", "foreign-owner", "unsafe-directory-mode", "config-is-directory"]
        for name in cases {
            let root = try remoteTemporaryDirectory("credential-shape-\(name)")
            defer { try? FileManager.default.removeItem(at: root) }
            let copilotHome = root.appendingPathComponent("copilot", isDirectory: true)
            let ghConfig = root.appendingPathComponent("gh", isDirectory: true)
            let gitParent = root.appendingPathComponent("git", isDirectory: true)
            for directory in [copilotHome, ghConfig, gitParent] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let gitConfig = gitParent.appendingPathComponent("config")
            try Data().write(to: gitConfig)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: gitConfig.path)
            var object = remoteRegistryObject(profileCount: 1)
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
            profiles[0]["copilotHome"] = copilotHome.path
            profiles[0]["ghConfigDir"] = ghConfig.path
            profiles[0]["gitConfigGlobal"] = gitConfig.path
            for key in ["copilotExecutable", "ghExecutable", "gitExecutable", "herdrExecutable", "zshExecutable"] {
                profiles[0][key] = "/bin/sh"
            }
            switch name {
            case "non-normalized-path":
                profiles[0]["copilotHome"] = "\(root.path)/git/../copilot"
            case "missing-directory":
                try FileManager.default.removeItem(at: copilotHome)
            case "missing-parent":
                profiles[0]["gitConfigGlobal"] = root.appendingPathComponent("missing/config").path
            case "unsafe-parent-mode":
                try FileManager.default.removeItem(at: gitConfig)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitParent.path)
            case "directory-is-file":
                try FileManager.default.removeItem(at: copilotHome)
                try Data().write(to: copilotHome)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copilotHome.path)
            case "foreign-owner":
                profiles[0]["gitConfigGlobal"] = "/etc/hosts"
            case "unsafe-directory-mode":
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilotHome.path)
            case "config-is-directory":
                try FileManager.default.removeItem(at: gitConfig)
                try FileManager.default.createDirectory(at: gitConfig, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            default:
                XCTFail("unknown credential shape")
            }
            object["profiles"] = profiles

            assertRemoteErrorContains("credential store") {
                _ = try RemoteProfileRegistry.decode(try remoteJSONData(object), executableExists: { _ in true })
            }
        }
    }

    func testRegistryRejectsDistinctPathsThatAliasOnePhysicalCredentialStore() throws {
        let root = try remoteTemporaryDirectory("profile-storage-alias")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedHome = root.appendingPathComponent("shared-home", isDirectory: true)
        let aliasedHome = root.appendingPathComponent("aliased-home", isDirectory: true)
        let personalGH = root.appendingPathComponent("personal-gh", isDirectory: true)
        let managedGH = root.appendingPathComponent("managed-gh", isDirectory: true)
        let personalGit = root.appendingPathComponent("personal.gitconfig")
        let managedGit = root.appendingPathComponent("managed.gitconfig")
        for directory in [sharedHome, personalGH, managedGH] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.createSymbolicLink(at: aliasedHome, withDestinationURL: sharedHome)
        for file in [personalGit, managedGit] {
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        var object = remoteRegistryObject()
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["copilotHome"] = sharedHome.path
        profiles[0]["ghConfigDir"] = personalGH.path
        profiles[0]["gitConfigGlobal"] = personalGit.path
        profiles[1]["copilotHome"] = aliasedHome.path
        profiles[1]["ghConfigDir"] = managedGH.path
        profiles[1]["gitConfigGlobal"] = managedGit.path
        object["profiles"] = profiles

        assertRemoteErrorContains("physical credential store") {
            _ = try RemoteProfileRegistry.decode(try remoteJSONData(object), executableExists: { _ in true })
        }
    }

    func testRegistryRequiresEveryExactExecutable() throws {
        let data = try remoteJSONData(remoteRegistryObject())
        var checked: [String] = []

        assertRemoteErrorContains("missing executable") {
            _ = try RemoteProfileRegistry.decode(data, executableExists: { path in
                checked.append(path)
                return !path.hasSuffix("/herdr")
            }, credentialStoreResolver: remoteFixtureCredentialStore)
        }
        XCTAssertTrue(checked.contains("/fixtures/bin/herdr"))
    }

    func testRegistryAcceptsExactManagedLoginButRejectsUnsafeLoginShapes() throws {
        XCTAssertEqual(try remoteRegistry().profiles[1].githubLogin, "arimendelow_microsoft")
        for login in ["-managed", "managed/other", "managed\nother", "_managed", "managed_"] {
            var object = remoteRegistryObject()
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
            profiles[1]["githubLogin"] = login
            object["profiles"] = profiles
            assertInvalid(object, contains: "GitHub login")
        }
    }

    func testLaunchSelectsExactAccountAndScrubsCredentialCompetition() throws {
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-personal-token\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0, stdout: Data("origin\n".utf8)),
            .init(exitCode: 0, stdout: Data("https://github.com/arimendelow/desk.git\n".utf8)),
            .init(exitCode: 0, stdout: Data("https://github.com/arimendelow/desk.git\n".utf8))
        ])
        let broker = try makeBroker(recorder: recorder)

        let request = try broker.launch(profileID: "personal", arguments: ["do", "the work"], generation: "g-1", paneID: "desk:p1")

        XCTAssertEqual(recorder.calls.count, 5)
        XCTAssertEqual(recorder.calls[0].arguments, ["auth", "token", "--user", "arimendelow"])
        XCTAssertEqual(recorder.calls[0].environment["GH_CONFIG_DIR"], "/tmp/ouro/gh/personal")
        XCTAssertNil(recorder.calls[0].environment["GH_TOKEN"])
        XCTAssertEqual(recorder.calls[1].arguments, ["api", "/user"])
        XCTAssertEqual(recorder.calls[1].environment["GH_TOKEN"], "fixture-personal-token")
        XCTAssertEqual(recorder.calls[2].arguments, ["remote"])
        XCTAssertEqual(recorder.calls[3].arguments, ["remote", "get-url", "--all", "--", "origin"])
        XCTAssertEqual(recorder.calls[4].arguments, ["remote", "get-url", "--push", "--all", "--", "origin"])
        XCTAssertEqual(request.executable, "/fixtures/bin/copilot")
        XCTAssertEqual(request.arguments, [
            "--agent", "desk:worker", "--allow-all", "--remote", "--mode", "autopilot",
            "--max-autopilot-continues", "100", "--no-auto-update",
            "--secret-env-vars=COPILOT_GITHUB_TOKEN,GH_TOKEN,GITHUB_TOKEN", "do", "the work"
        ])
        XCTAssertEqual(request.environment["COPILOT_GITHUB_TOKEN"], "fixture-personal-token")
        XCTAssertEqual(request.environment["COPILOT_HOME"], "/tmp/ouro/copilot/personal")
        XCTAssertEqual(request.environment["GH_CONFIG_DIR"], "/dev/null")
        XCTAssertEqual(request.environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(request.environment["OURO_PROFILE_ID"], "personal")
        XCTAssertEqual(request.environment["OURO_GENERATION"], "g-1")
        XCTAssertEqual(request.environment["OURO_PANE_ID"], "desk:p1")
        XCTAssertNil(request.environment["GH_TOKEN"])
        XCTAssertNil(request.environment["GITHUB_TOKEN"])
        XCTAssertNil(request.environment["HERDR_GITHUB_TOKEN_FILE"])
        XCTAssertFalse(request.arguments.contains("--no-ask-user"))
        XCTAssertFalse(request.arguments.joined().contains("fixture-personal-token"))
    }

    func testRepositoryInspectionUsesGitEffectiveFetchAndPushURLs() throws {
        let root = try remoteTemporaryDirectory()
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        let runner = RemoteSystemRunner()
        func git(_ arguments: [String]) throws {
            let result = try runner.run(.init(
                executable: "/usr/bin/git",
                arguments: arguments,
                environment: environment,
                workingDirectory: repository.path
            ))
            XCTAssertEqual(result.exitCode, 0, String(decoding: result.stderr, as: UTF8.self))
        }
        try git(["init", "--quiet"])
        try git(["remote", "add", "origin", "https://github.com/arimendelow/desk.git"])
        try git(["config", "url.https://github.com/managed-org/.pushInsteadOf", "https://github.com/arimendelow/"])

        var object = remoteRegistryObject(profileCount: 1)
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["gitExecutable"] = "/usr/bin/git"
        profiles[0]["gitConfigGlobal"] = root.appendingPathComponent("global.gitconfig").path
        for key in ["copilotExecutable", "ghExecutable", "herdrExecutable", "zshExecutable"] {
            profiles[0][key] = "/bin/sh"
        }
        object["profiles"] = profiles
        let registry = try RemoteProfileRegistry.decode(try remoteJSONData(object), credentialStoreResolver: remoteFixtureCredentialStore)
        let broker = RemoteAccountBroker(
            registry: registry,
            environment: environment,
            workingDirectory: repository.path,
            shimDirectory: root.appendingPathComponent("shims").path,
            profileConfigPath: root.appendingPathComponent("profiles.json").path,
            run: runner.run
        )

        let urls = try broker.repositoryRemoteURLs(profileID: "personal")

        XCTAssertEqual(urls, [
            "https://github.com/arimendelow/desk.git",
            "https://github.com/managed-org/desk.git"
        ])
        assertRemoteErrorContains("mixed repository owners") {
            try RemoteRepositoryPolicy.validate(remoteURLs: urls, allowedOwners: ["arimendelow", "ourostack"], mutation: true)
        }
    }

    func testManagedCopilotPolicyArgumentsCannotBeOverriddenBeforeTheArgumentTerminator() throws {
        let conflictingArguments = [
            ["--agent", "other:worker"],
            ["--agent=other:worker"],
            ["--allow-all"],
            ["--remote"],
            ["--mode", "plan"],
            ["--mode=plan"],
            ["--max-autopilot-continues", "1"],
            ["--max-autopilot-continues=1"],
            ["--no-auto-update"],
            ["--no-remote"],
            ["--no-remote-export"],
            ["--no-ask-user"],
            ["--assisted-approval"],
            ["--secret-env-vars", "OTHER_SECRET"],
            ["--secret-env-vars=OTHER_SECRET"]
        ]
        for arguments in conflictingArguments {
            let recorder = RemoteCallRecorder(responses: [
                .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
                .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
                .init(exitCode: 1)
            ])
            assertRemoteErrorContains("managed Copilot policy argument") {
                _ = try makeBroker(recorder: recorder).launch(profileID: "personal", arguments: arguments, generation: "g1", paneID: "desk:p1")
            }
            XCTAssertTrue(recorder.calls.isEmpty)
        }

        let dispatchRecorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 1)
        ])
        let dispatchBroker = try makeBroker(
            recorder: dispatchRecorder,
            environment: ["HERDR_ENV": "1", "OURO_PROFILE_ID": "personal", "OURO_GENERATION": "g1", "OURO_PANE_ID": "desk:p1"]
        )
        assertRemoteErrorContains("managed Copilot policy argument") {
            _ = try dispatchBroker.dispatch(arguments: ["--mode", "plan"], sessionMapURL: URL(fileURLWithPath: "/unused"))
        }
        XCTAssertTrue(dispatchRecorder.calls.isEmpty)

        let safeRecorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0)
        ])
        let safeArguments = ["--prompt", "--remote", "--model", "gpt-5", "--", "--agent", "literal prompt text"]
        let safe = try makeBroker(recorder: safeRecorder).launch(profileID: "personal", arguments: safeArguments, generation: "g1", paneID: "desk:p1")
        XCTAssertEqual(Array(safe.arguments.suffix(safeArguments.count)), safeArguments)

        assertRemoteErrorContains("durable managed dispatch") {
            _ = try makeBroker(recorder: RemoteCallRecorder()).launch(
                profileID: "personal",
                arguments: ["--resume=00000000-0000-4000-8000-000000000001"],
                generation: "g1",
                paneID: "desk:p1"
            )
        }
    }

    func testEveryManagedProcessGetsOnlyOperationalEnvironmentAndExactProfileValues() throws {
        let sentinels = ["AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY", "SSH_AUTH_SOCK", "UNRELATED_SECRET"]
        var ambient = [
            "HOME": "/Users/example", "USER": "example", "LOGNAME": "example", "SHELL": "/bin/zsh",
            "PATH": "/usr/bin", "TMPDIR": "/tmp", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8", "XDG_CONFIG_HOME": "/tmp/xdg-config", "XDG_STATE_HOME": "/tmp/xdg-state",
            "XDG_RUNTIME_DIR": "/tmp/xdg-run", "HERDR_ENV": "1", "OURO_PROFILE_ID": "ambient-wrong",
            "OURO_GENERATION": "ambient-wrong", "GH_TOKEN": "ambient-gh", "GITHUB_TOKEN": "ambient-github",
            "COPILOT_GITHUB_TOKEN": "ambient-copilot", "HERDR_GITHUB_TOKEN_FILE": "/tmp/ambient-token"
        ]
        for key in sentinels { ambient[key] = "sentinel-\(key)" }
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0)
        ])
        let broker = try makeBroker(recorder: recorder, environment: ambient)
        let copilot = try broker.launch(profileID: "personal", arguments: [], generation: "g1", paneID: "desk:p1")
        let gh = try broker.gh(profileID: "personal", arguments: ["api", "/user"], remoteURLs: [])
        let git = try broker.git(profileID: "personal", arguments: ["status"], remoteURLs: [])

        for request in recorder.calls + [copilot, gh, git] {
            for key in sentinels + ["SSH_AUTH_SOCK", "HERDR_GITHUB_TOKEN_FILE"] {
                XCTAssertNil(request.environment[key], "\(key) leaked to \(request)")
            }
            XCTAssertEqual(request.environment["HOME"], "/Users/example")
            XCTAssertEqual(request.environment["LC_ALL"], "en_US.UTF-8")
        }
        XCTAssertEqual(recorder.calls[1].environment["GH_TOKEN"], "fixture-token")
        XCTAssertEqual(copilot.environment["COPILOT_GITHUB_TOKEN"], "fixture-token")
        XCTAssertEqual(copilot.environment["OURO_PROFILE_ID"], "personal")
        XCTAssertEqual(copilot.environment["OURO_GENERATION"], "g1")
        XCTAssertNil(gh.environment["OURO_PROFILE_ID"])
        XCTAssertNil(git.environment["OURO_GENERATION"])
    }

    func testManagedChildPreservesOnlyTheRequiredHerdrRuntimeContext() throws {
        let herdr = [
            "HERDR_ENV": "1",
            "HERDR_SOCKET_PATH": "/tmp/herdr.sock",
            "HERDR_PANE_ID": "desk:p1",
            "HERDR_WORKSPACE_ID": "desk",
            "HERDR_TAB_ID": "desk:t1",
            "HERDR_SESSION": "ouro-g1",
            "HERDR_BIN_PATH": "/fixtures/bin/herdr"
        ]
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0)
        ])
        let broker = try makeBroker(recorder: recorder, environment: herdr.merging(["HERDR_UNTRUSTED": "drop-me"]) { _, new in new })

        let request = try broker.launch(profileID: "personal", arguments: [], generation: "ouro-g1", paneID: "desk:p1")

        for (key, value) in herdr {
            XCTAssertEqual(request.environment[key], value)
        }
        XCTAssertNil(request.environment["HERDR_UNTRUSTED"])
    }

    func testLaunchFailsClosedOnTokenLookupLoginAndRepositoryFailures() throws {
        let tokenFailure = RemoteCallRecorder(responses: [.init(exitCode: 1, stderr: Data("fixture-personal-token".utf8))])
        assertRemoteErrorContains("GitHub token lookup failed") {
            _ = try makeBroker(recorder: tokenFailure).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }
        XCTAssertFalse(tokenFailure.calls.map(\.description).joined().contains("fixture-personal-token"))

        let emptyToken = RemoteCallRecorder(responses: [.init(exitCode: 0, stdout: Data())])
        assertRemoteErrorContains("GitHub token lookup returned no credential") {
            _ = try makeBroker(recorder: emptyToken).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }

        let wrongLogin = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "someone-else"]))
        ])
        assertRemoteErrorContains("account mismatch") {
            _ = try makeBroker(recorder: wrongLogin).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }

        let malformedLogin = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: Data("not-json".utf8))
        ])
        assertRemoteErrorContains("GitHub identity response was invalid") {
            _ = try makeBroker(recorder: malformedLogin).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }

        let disallowed = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0, stdout: Data("origin\n".utf8)),
            .init(exitCode: 0, stdout: Data("git@github.com:managed-org/private.git\n".utf8)),
            .init(exitCode: 0, stdout: Data("git@github.com:managed-org/private.git\n".utf8))
        ])
        assertRemoteErrorContains("repository owner is not allowed") {
            _ = try makeBroker(recorder: disallowed).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }

        let disallowedPushURL = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0, stdout: Data("origin\n".utf8)),
            .init(exitCode: 0, stdout: Data("https://github.com/arimendelow/desk.git\n".utf8)),
            .init(exitCode: 0, stdout: Data("https://github.com/managed-org/private.git\n".utf8))
        ])
        assertRemoteErrorContains("mixed repository owners") {
            _ = try makeBroker(recorder: disallowedPushURL).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }

        let dependency = RemoteCallRecorder()
        dependency.thrownError = RemoteFixtureError.expected
        assertRemoteErrorContains("GitHub token lookup failed") {
            _ = try makeBroker(recorder: dependency).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }
    }

    func testLaunchTranslatesIdentityAndRepositoryDependencyFailures() throws {
        func broker(throwOnCall: Int) throws -> RemoteAccountBroker {
            var call = 0
            return RemoteAccountBroker(
                registry: try remoteRegistry(),
                environment: [:],
                workingDirectory: "/tmp/desk",
                shimDirectory: "/tmp/ouro/shims",
                profileConfigPath: "/tmp/ouro/profiles.json",
                run: { _ in
                    call += 1
                    if call == throwOnCall { throw RemoteFixtureError.expected }
                    if call == 1 { return RemoteProcessResult(exitCode: 0, stdout: Data("fixture-token".utf8)) }
                    if call == 2 { return RemoteProcessResult(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])) }
                    if call == 3 { return RemoteProcessResult(exitCode: 0, stdout: Data("origin\n".utf8)) }
                    return RemoteProcessResult(exitCode: 0, stdout: Data("https://github.com/arimendelow/desk.git\n".utf8))
                }
            )
        }

        assertRemoteErrorContains("identity validation failed") {
            _ = try broker(throwOnCall: 2).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }
        assertRemoteErrorContains("repository inspection failed") {
            _ = try broker(throwOnCall: 3).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
        }
        for call in [4, 5] {
            assertRemoteErrorContains("repository inspection failed") {
                _ = try broker(throwOnCall: call).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
            }
        }

        for failedCall in 3...5 {
            var responses = [
                RemoteProcessResult(exitCode: 0, stdout: Data("fixture-token".utf8)),
                RemoteProcessResult(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
                RemoteProcessResult(exitCode: 0, stdout: Data("origin\n".utf8)),
                RemoteProcessResult(exitCode: 0, stdout: Data("https://github.com/arimendelow/desk.git\n".utf8)),
                RemoteProcessResult(exitCode: 0, stdout: Data("https://github.com/arimendelow/desk.git\n".utf8))
            ]
            responses[failedCall - 1] = RemoteProcessResult(exitCode: 2)
            assertRemoteErrorContains("repository inspection failed") {
                _ = try makeBroker(recorder: RemoteCallRecorder(responses: responses)).launch(profileID: "personal", arguments: [], generation: "g", paneID: "desk:p1")
            }
        }
    }

    func testDispatchBindsNonResumePayloadToExactHerdrProfileInsteadOfFirstOrAmbientAccount() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = root.appendingPathComponent("session-map.json")
        try remoteJSONData(["schemaVersion": 1, "entries": [
            ["sessionID": "8d5177d6-b6d1-4b5f-a546-564ed0ef8748", "profileID": "personal", "paneID": "desk:p-personal", "generation": "g-shared"],
            ["sessionID": "29633c1f-f185-41a7-b628-8f7e54d74422", "profileID": "emu", "paneID": "desk:p-emu", "generation": "g-shared"]
        ]]).write(to: mapURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
        let arguments = ["--model", "gpt 5", "a'b", "--"]

        for (paneID, profileID, login) in [("desk:p-personal", "personal", "arimendelow"), ("desk:p-emu", "emu", "arimendelow_microsoft")] {
            let recorder = RemoteCallRecorder(responses: [
                .init(exitCode: 0, stdout: Data("fixture-managed-token".utf8)),
                .init(exitCode: 0, stdout: try remoteJSONData(["login": login])),
                .init(exitCode: 0)
            ])
            var environment = ["HERDR_ENV": "1", "HERDR_SESSION": "g-shared", "HERDR_PANE_ID": paneID, "PATH": "/wrong"]
            if profileID == "personal" {
                environment["OURO_GENERATION"] = ""
                environment["OURO_PANE_ID"] = ""
            }
            let broker = try makeBroker(recorder: recorder, environment: environment)
            let request = try broker.dispatch(arguments: arguments, sessionMapURL: mapURL)
            XCTAssertEqual(request.executable, "/fixtures/bin/copilot")
            XCTAssertEqual(Array(request.arguments.suffix(arguments.count)), arguments)
            XCTAssertEqual(request.environment["OURO_PROFILE_ID"], profileID)
            XCTAssertEqual(request.environment["OURO_GENERATION"], "g-shared")
            XCTAssertEqual(request.environment["OURO_PANE_ID"], paneID)
            XCTAssertEqual(request.environment["COPILOT_GITHUB_TOKEN"], "fixture-managed-token")
            XCTAssertNil(request.environment["GH_TOKEN"])
            XCTAssertEqual(recorder.calls.first?.arguments, ["auth", "token", "--user", login])
        }

        let outside = try makeBroker(recorder: RemoteCallRecorder(), environment: [:])
        assertRemoteErrorContains("outside Herdr") {
            _ = try outside.dispatch(arguments: arguments, sessionMapURL: mapURL)
        }

        for context in [
            ["HERDR_ENV": "1", "HERDR_SESSION": "g-shared"],
            ["HERDR_ENV": "1", "HERDR_SESSION": "g-shared", "HERDR_PANE_ID": "desk:missing"],
            ["HERDR_ENV": "1", "HERDR_SESSION": "g-shared", "HERDR_PANE_ID": "desk:p-emu", "OURO_PROFILE_ID": "personal"],
            ["HERDR_ENV": "1", "HERDR_SESSION": "g-shared", "OURO_GENERATION": "other", "HERDR_PANE_ID": "desk:p-emu"]
        ] {
            let invalid = try makeBroker(recorder: RemoteCallRecorder(), environment: context)
            assertRemoteErrorContains("context") {
                _ = try invalid.dispatch(arguments: arguments, sessionMapURL: mapURL)
            }
        }

        let ambiguousURL = root.appendingPathComponent("ambiguous.json")
        try remoteJSONData(["schemaVersion": 1, "entries": [
            ["sessionID": "8d5177d6-b6d1-4b5f-a546-564ed0ef8748", "profileID": "personal", "paneID": "desk:p1", "generation": "g"],
            ["sessionID": "29633c1f-f185-41a7-b628-8f7e54d74422", "profileID": "emu", "paneID": "desk:p1", "generation": "g"]
        ]]).write(to: ambiguousURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ambiguousURL.path)
        let ambiguous = try makeBroker(recorder: RemoteCallRecorder(), environment: ["HERDR_ENV": "1", "HERDR_SESSION": "g", "HERDR_PANE_ID": "desk:p1"])
        assertRemoteErrorContains("unique") { _ = try ambiguous.dispatch(arguments: arguments, sessionMapURL: ambiguousURL) }
    }

    func testDispatchUsesOnePaneProfileAcrossSequentialFreshSessionHistory() throws {
        let root = try remoteTemporaryDirectory("sequential-session-history")
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = root.appendingPathComponent("session-map.json")
        try remoteJSONData(["schemaVersion": 1, "entries": [
            ["sessionID": "8d5177d6-b6d1-4b5f-a546-564ed0ef8748", "profileID": "personal", "paneID": "desk:p1", "generation": "g-current"],
            ["sessionID": "29633c1f-f185-41a7-b628-8f7e54d74422", "profileID": "personal", "paneID": "desk:p1", "generation": "g-current"]
        ]]).write(to: mapURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0)
        ])
        let broker = try makeBroker(
            recorder: recorder,
            environment: ["HERDR_ENV": "1", "HERDR_SESSION": "g-current", "HERDR_PANE_ID": "desk:p1"]
        )

        let request = try broker.dispatch(arguments: ["keep-going"], sessionMapURL: mapURL)

        XCTAssertEqual(request.environment["OURO_PROFILE_ID"], "personal")
        XCTAssertEqual(request.environment["OURO_GENERATION"], "g-current")
        XCTAssertEqual(request.environment["OURO_PANE_ID"], "desk:p1")
    }

    func testDispatchResumeRequiresOneCanonicalMappedUUID() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try remoteRegistry()
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil })
        try ledger.prepare(
            attemptID: "launch-1",
            nativeSessionID: nil,
            profileID: "personal",
            generation: "g-1",
            paneID: "desk:p1",
            ownerPID: 42
        )
        try ledger.markSpawnIntent(attemptID: "launch-1")
        try ledger.recordChild(attemptID: "launch-1", identity: remoteProcessIdentity(pid: 43, startIdentity: "birth-43", generation: "g-1"))
        let store = RemoteSessionMapStore(rootURL: root.appendingPathComponent("map"))
        let uuid = "8D5177D6-B6D1-4B5F-A546-564ED0EF8748"
        let report = store.record(
            hookData: try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]),
            profileID: "personal",
            paneID: "desk:p1",
            generation: "g-1",
            registry: registry,
            ledger: ledger,
            officialHook: { _ in nil }
        )
        XCTAssertNil(report.mappingError)
        var responses: [RemoteProcessResult] = []
        for _ in 0..<5 {
            responses += [
                .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
                .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
                .init(exitCode: 0)
            ]
        }
        let recorder = RemoteCallRecorder(responses: responses)
        let broker = RemoteAccountBroker(
            registry: registry,
            environment: ["HERDR_ENV": "1", "HERDR_SESSION": "g-current", "HERDR_PANE_ID": "desk:current"],
            workingDirectory: "/tmp/desk",
            shimDirectory: "/tmp/ouro/shims",
            profileConfigPath: "/tmp/ouro/profiles.json",
            run: recorder.run
        )

        let request = try broker.dispatch(arguments: ["--resume=\(uuid.lowercased())"], sessionMapURL: store.mapURL)

        XCTAssertEqual(request.environment["OURO_PROFILE_ID"], "personal")
        XCTAssertEqual(request.environment["OURO_GENERATION"], "g-current")
        XCTAssertEqual(request.environment["OURO_PANE_ID"], "desk:current")
        XCTAssertEqual(request.arguments.last, "--resume=\(uuid.lowercased())")
        XCTAssertTrue(request.arguments.contains("--remote"))

        let conflictingProfile = RemoteAccountBroker(
            registry: registry,
            environment: ["HERDR_ENV": "1", "HERDR_SESSION": "g-current", "HERDR_PANE_ID": "desk:current", "OURO_PROFILE_ID": "emu"],
            workingDirectory: "/tmp/desk",
            shimDirectory: "/tmp/ouro/shims",
            profileConfigPath: "/tmp/ouro/profiles.json",
            run: recorder.run
        )
        assertRemoteErrorContains("profile context disagrees") {
            _ = try conflictingProfile.dispatch(arguments: ["--resume=\(uuid.lowercased())"], sessionMapURL: store.mapURL)
        }

        for spelling in [["--resume", uuid], ["-r", uuid], ["--session-id", uuid], ["--session-id=\(uuid)"]] {
            let spelled = try broker.dispatch(arguments: spelling, sessionMapURL: store.mapURL)
            XCTAssertEqual(spelled.environment["OURO_PROFILE_ID"], "personal")
            XCTAssertEqual(Array(spelled.arguments.suffix(spelling.count)), spelling)
        }

        for invalid in [["--resume"], ["-r"], ["--resume=not-a-uuid"], ["-r", "not-a-uuid"], ["--resume=\(uuid)", "--resume=\(uuid)"], ["--resume", uuid, "-r", uuid], ["--continue"], ["--connect=\(uuid)"], ["--connect", uuid], ["--session-id"], ["--session-id=not-a-uuid"]] {
            assertRemoteErrorContains("resume") {
                _ = try broker.dispatch(arguments: invalid, sessionMapURL: store.mapURL)
            }
        }

        XCTAssertNil(try RemoteAccountBroker.resumeUUID(in: ["--model", "gpt-5", "--", "-r", uuid]))
        for malformed in [["--resume-latest"], ["-r=\(uuid)"], ["-r\(uuid)"], ["--session-id-latest"], ["--connect-latest"]] {
            assertRemoteErrorContains("resume") { _ = try RemoteAccountBroker.resumeUUID(in: malformed) }
        }
    }

    func testDispatchResumeFailsClosedForMissingMalformedDuplicateAndUnknownMaps() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let broker = try makeBroker(
            recorder: RemoteCallRecorder(),
            environment: ["HERDR_ENV": "1", "HERDR_SESSION": "g-current", "HERDR_PANE_ID": "desk:current"]
        )
        let missing = root.appendingPathComponent("missing.json")
        assertRemoteErrorContains("session map") {
            _ = try broker.dispatch(arguments: ["--resume=\(uuid)"], sessionMapURL: missing)
        }

        let malformed = root.appendingPathComponent("malformed.json")
        try Data("bad".utf8).write(to: malformed)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: malformed.path)
        assertRemoteErrorContains("session map") {
            _ = try broker.dispatch(arguments: ["--resume=\(uuid)"], sessionMapURL: malformed)
        }

        let duplicate = root.appendingPathComponent("duplicate.json")
        let entry: [String: Any] = ["sessionID": uuid, "profileID": "personal", "paneID": "p1", "generation": "g"]
        try remoteJSONData(["schemaVersion": 1, "entries": [entry, entry]]).write(to: duplicate)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: duplicate.path)
        assertRemoteErrorContains("duplicate") {
            _ = try broker.dispatch(arguments: ["--resume=\(uuid)"], sessionMapURL: duplicate)
        }

        let unknown = root.appendingPathComponent("unknown.json")
        try remoteJSONData(["schemaVersion": 1, "entries": [["sessionID": uuid, "profileID": "removed", "paneID": "p1", "generation": "g"]]]).write(to: unknown)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknown.path)
        assertRemoteErrorContains("unknown profile") {
            _ = try broker.dispatch(arguments: ["--resume=\(uuid)"], sessionMapURL: unknown)
        }
    }

    func testResumeRequiresExactPriorOwnershipAndReusesOnlyTheMappedProfileAndPane() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapped = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let other = "5a7e4e97-3caf-4bbb-bf4c-90d415feb81b"
        let mapURL = root.appendingPathComponent("session-map.json")
        try remoteJSONData([
            "schemaVersion": 1,
            "entries": [["sessionID": mapped, "profileID": "personal", "paneID": "desk:p1", "generation": "g-old"]]
        ]).write(to: mapURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0)
        ])
        let broker = RemoteAccountBroker(
            registry: try remoteRegistry(),
            environment: ["HERDR_ENV": "1", "HERDR_SESSION": "g-new", "HERDR_PANE_ID": "desk:p1"],
            workingDirectory: "/tmp/desk",
            shimDirectory: "/tmp/ouro/shims",
            profileConfigPath: "/tmp/ouro/profiles.json",
            run: recorder.run
        )

        for tuple in [
            ("not-a-uuid", "personal", "g-new", "desk:p1"),
            (mapped, "personal", "", "desk:p1"),
            (mapped, "personal", "g-new", ""),
            (other, "personal", "g-new", "desk:p1"),
            (mapped, "emu", "g-new", "desk:p1"),
            (mapped, "personal", "g-new", "desk:p2")
        ] {
            assertRemoteErrorContains("resume") {
                _ = try broker.resume(nativeSessionID: tuple.0, profileID: tuple.1, generation: tuple.2, paneID: tuple.3, sessionMapURL: mapURL)
            }
        }
        assertRemoteErrorContains("no unique session map entry") {
            _ = try broker.dispatch(arguments: ["--resume=\(other)"], sessionMapURL: mapURL)
        }

        let request = try broker.resume(nativeSessionID: mapped.uppercased(), profileID: "personal", generation: "g-new", paneID: "desk:p1", sessionMapURL: mapURL)

        XCTAssertEqual(request.environment["OURO_PROFILE_ID"], "personal")
        XCTAssertEqual(request.environment["OURO_GENERATION"], "g-new")
        XCTAssertEqual(request.environment["OURO_PANE_ID"], "desk:p1")
        XCTAssertEqual(request.arguments.last, "--resume=\(mapped)")
    }

    func testProfileGhAndGitRequestsNeverInheritCopilotCredential() throws {
        let broker = try makeBroker(
            recorder: RemoteCallRecorder(),
            environment: ["COPILOT_GITHUB_TOKEN": "fixture-secret", "GH_TOKEN": "other", "GITHUB_TOKEN": "third"]
        )

        let ghRead = try broker.gh(profileID: "personal", arguments: ["pr", "view"], remoteURLs: [])
        XCTAssertEqual(ghRead.executable, "/fixtures/bin/gh")
        XCTAssertEqual(ghRead.environment["GH_CONFIG_DIR"], "/tmp/ouro/gh/personal")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_GLOBAL"], "/tmp/ouro/git/personal/config")
        XCTAssertEqual(ghRead.environment["GIT_AUTHOR_NAME"], "Ari Mendel")
        XCTAssertEqual(ghRead.environment["GIT_AUTHOR_EMAIL"], "ari@example.test")
        XCTAssertEqual(ghRead.environment["GIT_COMMITTER_NAME"], "Ari Mendel")
        XCTAssertEqual(ghRead.environment["GIT_COMMITTER_EMAIL"], "ari@example.test")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_NOSYSTEM"], "1")
        XCTAssertEqual(ghRead.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_COUNT"], "7")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_KEY_2"], "credential.helper")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_VALUE_2"], "")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_KEY_3"], "credential.https://github.com.helper")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_VALUE_3"], "!'/fixtures/bin/gh' auth git-credential")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_KEY_4"], "url.https://github.com/.insteadOf")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_VALUE_4"], "git@github.com:")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_KEY_5"], "url.https://github.com/.insteadOf")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_VALUE_5"], "ssh://git@github.com/")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_KEY_6"], "url.https://github.com/.insteadOf")
        XCTAssertEqual(ghRead.environment["GIT_CONFIG_VALUE_6"], "github.com:")
        XCTAssertEqual(ghRead.environment["PATH"], "/tmp/ouro/shims:/usr/bin:/bin")
        XCTAssertNil(ghRead.environment["COPILOT_GITHUB_TOKEN"])
        XCTAssertNil(ghRead.environment["GH_TOKEN"])
        XCTAssertNil(ghRead.environment["GITHUB_TOKEN"])

        let gitRead = try broker.git(profileID: "personal", arguments: ["status"], remoteURLs: [])
        XCTAssertEqual(gitRead.executable, "/fixtures/bin/git")
        XCTAssertEqual(gitRead.environment["GIT_CONFIG_GLOBAL"], "/tmp/ouro/git/personal/config")
        XCTAssertEqual(gitRead.environment["GIT_AUTHOR_NAME"], "Ari Mendel")
        XCTAssertNil(gitRead.environment["COPILOT_GITHUB_TOKEN"])

        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/user"], remoteURLs: []))
        XCTAssertNoThrow(try broker.git(profileID: "personal", arguments: ["log", "-1"], remoteURLs: []))
        assertRemoteErrorContains("repository remote is required") {
            _ = try broker.gh(profileID: "personal", arguments: ["pr", "create"], remoteURLs: [])
        }
        assertRemoteErrorContains("repository remote is required") {
            _ = try broker.git(profileID: "personal", arguments: ["push"], remoteURLs: [])
        }
    }

    func testManagedChildCannotReadProfileCredentialThroughGitPlumbing() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let hostileMarker = root.appendingPathComponent("hostile-ran")
        let hostileHelper = root.appendingPathComponent("hostile-helper")
        let profileGh = root.appendingPathComponent("profile-gh")
        try Data("#!/bin/sh\n: > '\(hostileMarker.path)'\nprintf 'username=hostile\\npassword=hostile-token\\n'\n".utf8).write(to: hostileHelper)
        try Data("#!/bin/sh\n/bin/cat >/dev/null\nprintf 'username=profile\\npassword=profile-token\\n'\n".utf8).write(to: profileGh)
        for executable in [hostileHelper, profileGh] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try Data("[core]\n\trepositoryformatversion = 0\n[credential]\n\thelper = !\(hostileHelper.path)\n".utf8).write(to: gitDirectory.appendingPathComponent("config"))
        let isolatedGlobal = root.appendingPathComponent("profile.gitconfig")
        try Data().write(to: isolatedGlobal)
        var object = remoteRegistryObject(profileCount: 1)
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["ghExecutable"] = profileGh.path
        profiles[0]["gitExecutable"] = "/usr/bin/git"
        profiles[0]["gitConfigGlobal"] = isolatedGlobal.path
        profiles[0]["deskRoot"] = repository.path
        for key in ["copilotExecutable", "herdrExecutable", "zshExecutable"] {
            profiles[0][key] = "/bin/sh"
        }
        object["profiles"] = profiles
        let registry = try RemoteProfileRegistry.decode(try remoteJSONData(object), credentialStoreResolver: remoteFixtureCredentialStore)
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("fixture-token".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["login": "arimendelow"])),
            .init(exitCode: 0)
        ])
        let broker = RemoteAccountBroker(
            registry: registry,
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: repository.path,
            shimDirectory: root.appendingPathComponent("shims").path,
            profileConfigPath: root.appendingPathComponent("profiles.json").path,
            run: recorder.run
        )
        assertRemoteErrorContains("credential plumbing") {
            _ = try broker.git(profileID: "personal", arguments: ["credential", "fill"], remoteURLs: [])
        }
        let request = try broker.launch(profileID: "personal", arguments: [], generation: "g1", paneID: "pane-1")

        let result = try RemoteSystemRunner().run(.init(
            executable: "/usr/bin/git",
            arguments: ["credential", "fill"],
            environment: request.environment,
            workingDirectory: repository.path,
            standardInput: Data("protocol=https\nhost=github.com\n\n".utf8)
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: hostileMarker.path))
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains("profile-token"))
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains("hostile-token"))
        XCTAssertEqual(request.environment["GH_CONFIG_DIR"], "/dev/null")
        XCTAssertEqual(request.environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertFalse(request.environment.values.contains(where: { $0.contains(profileGh.path) }))
    }

    func testGhGuardDeniesAuthenticationCommandsAndOppositePositionalTargets() throws {
        let broker = try makeBroker(recorder: RemoteCallRecorder())
        let personalRemote = ["https://github.com/arimendelow/desk.git"]

        for arguments in [
            ["auth", "login"],
            ["auth", "logout"],
            ["auth", "switch", "--user", "someone-else"],
            ["auth", "setup-git"],
            ["auth", "token"],
            ["auth", "status"]
        ] {
            assertRemoteErrorContains("authentication commands are unavailable") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: [])
            }
        }

        for arguments in [
            ["repo", "delete", "managed-org/repo"],
            ["repo", "view", "managed-org/repo"],
            ["repo", "view", "github.com/managed-org/repo"],
            ["api", "/orgs/managed-org/repos"],
            ["api", "https://api.github.com/users/managed-org/repos"],
            ["pr", "view", "https://github.com/managed-org/repo/pull/1"],
            ["repo", "view", "-R=managed-org/repo"],
            ["repo", "view", "-Rmanaged-org/repo"]
        ] {
            assertRemoteErrorContains("explicit GitHub owner") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }

        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["repo", "view", "arimendelow/desk"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/orgs/arimendelow/repos"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["pr", "view", "https://github.com/arimendelow/desk/pull/1"], remoteURLs: personalRemote))

        assertRemoteErrorContains("unsupported GitHub URL") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "https://api.github.com./repos/managed-org/repo", "-X", "DELETE"], remoteURLs: personalRemote)
        }
        for arguments in [
            ["api", "http://api.github.com/repos/arimendelow/desk"],
            ["pr", "view", "http://github.com/arimendelow/desk/pull/1"]
        ] {
            assertRemoteErrorContains("unsupported GitHub URL") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
        assertRemoteErrorContains("hostname") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "/repos/arimendelow/desk", "--hostname", "github.example.test"], remoteURLs: personalRemote)
        }
        assertRemoteErrorContains("hostname is missing") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "/user", "--hostname"], remoteURLs: [])
        }
        assertRemoteErrorContains("ambiguous GitHub API target") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "/repositories/123", "-X", "DELETE"], remoteURLs: personalRemote)
        }
        for arguments in [
            ["api", "/repos/arimendelow/../managed-org/repo", "-XDELETE"],
            ["pr", "view", "https://github.com/arimendelow/../managed-org/repo/pull/1"],
            ["api", "/orgs/-bad/repos"],
            ["repo", "view", "arimendelow/bad!repo"]
        ] {
            assertRemoteErrorContains("unsafe") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
    }

    func testRepositoryPolicyParsesSupportedURLsAndBlocksWrongMixedAndAmbiguousOwners() throws {
        XCTAssertEqual(
            try RemoteRepositoryPolicy.owners(from: [
                "https://github.com/ourostack/workbench.git",
                "git@github.com:arimendelow/desk.git",
                "ssh://git@github.com/OUROSTACK/relay.git"
            ]),
            Set(["ourostack", "arimendelow"])
        )
        assertRemoteErrorContains("unsupported repository remote") {
            _ = try RemoteRepositoryPolicy.owners(from: ["https://example.com/a/b.git"])
        }
        for remote in [
            "http://github.com/arimendelow/desk.git",
            "ssh://git@github.com:22/arimendelow/desk.git",
            "ssh://someone@github.com/arimendelow/desk.git"
        ] {
            assertRemoteErrorContains("unsupported repository remote") {
                _ = try RemoteRepositoryPolicy.owners(from: [remote])
            }
        }
        assertRemoteErrorContains("repository owner is not allowed") {
            try RemoteRepositoryPolicy.validate(remoteURLs: ["git@github.com:managed-org/repo.git"], allowedOwners: ["ourostack"], mutation: true)
        }
        assertRemoteErrorContains("mixed repository owners") {
            try RemoteRepositoryPolicy.validate(
                remoteURLs: ["git@github.com:ourostack/a.git", "git@github.com:arimendelow/b.git"],
                allowedOwners: ["ourostack", "arimendelow"],
                mutation: true
            )
        }
        XCTAssertNoThrow(try RemoteRepositoryPolicy.validate(remoteURLs: [], allowedOwners: ["ourostack"], mutation: false))
    }

    func testGhGuardRejectsImplicitPostGraphQLMutationAndExplicitOppositeOwnerTargets() throws {
        let broker = try makeBroker(recorder: RemoteCallRecorder())
        assertRemoteErrorContains("does not prove an allowed owner") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "/user", "-f", "x=y"], remoteURLs: [])
        }
        assertRemoteErrorContains("GraphQL mutation") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "graphql", "-f", "query=mutation { createIssue(input: {}) { id } }"], remoteURLs: ["https://github.com/arimendelow/desk.git"])
        }
        assertRemoteErrorContains("GraphQL") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "graphql", "-f", "query=query { viewer { login } }"], remoteURLs: ["https://github.com/arimendelow/desk.git"])
        }
        for endpoint in ["/graphql", "https://api.github.com/graphql"] {
            assertRemoteErrorContains("GraphQL") {
                _ = try broker.gh(profileID: "personal", arguments: ["api", endpoint, "-f", "query=mutation { createIssue(input: {}) { id } }"], remoteURLs: ["https://github.com/arimendelow/desk.git"])
            }
        }
        assertRemoteErrorContains("does not prove an allowed owner") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "/user", "--method=POST"], remoteURLs: [])
        }
        for arguments in [
            ["pr", "view", "-R", "managed-org/repo"],
            ["repo", "view", "--repo", "managed-org/repo"],
            ["api", "/repos/managed-org/repo/issues"],
            ["api", "repos/managed-org/repo/issues"],
            ["api", "https://api.github.com/repos/managed-org/repo/issues"]
        ] {
            assertRemoteErrorContains("explicit GitHub owner") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: ["https://github.com/arimendelow/desk.git"])
            }
        }
    }

    func testGhGuardValidatesMatchingExplicitTargetsAndClassifierBoundaryShapes() throws {
        let broker = try makeBroker(recorder: RemoteCallRecorder())
        let personalRemote = ["https://github.com/arimendelow/desk.git"]

        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: [], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", ""], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/user", "--method", "GET"], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/user", "--hostname=github.com"], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/repos/"], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/repos/arimendelow/desk", "-X", "PATCH"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/user", "--method"], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["pr", "view", "--repo=arimendelow/desk"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["pr", "view", "https://github.com"], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["repo", "view", ""], remoteURLs: []))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["api", "/repos/arimendelow"], remoteURLs: []))

        assertRemoteErrorContains("repository remote is required") {
            _ = try broker.gh(profileID: "personal", arguments: ["pr"], remoteURLs: [])
        }
        assertRemoteErrorContains("does not prove an allowed owner") {
            _ = try broker.gh(profileID: "personal", arguments: ["api", "/user", "-X", "PATCH"], remoteURLs: personalRemote)
        }
        for arguments in [
            ["api", "/user", "-XDELETE"],
            ["api", "/user", "-X=DELETE"],
            ["api", "/user", "-fkey=value"],
            ["api", "/user", "-Fkey=@file"],
            ["api", "/user", "--method", "GET", "--method", "DELETE"]
        ] {
            assertRemoteErrorContains("does not prove an allowed owner") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
        assertRemoteErrorContains("does not match the current repository") {
            _ = try broker.gh(profileID: "personal", arguments: ["pr", "view", "--repo=ourostack/workbench"], remoteURLs: personalRemote)
        }
        assertRemoteErrorContains("target is missing") {
            _ = try broker.gh(profileID: "personal", arguments: ["pr", "view", "--repo"], remoteURLs: [])
        }
        assertRemoteErrorContains("target is unsafe") {
            _ = try broker.gh(profileID: "personal", arguments: ["pr", "view", "--repo="], remoteURLs: [])
        }
    }

    func testGhGuardChecksOwnerFlagsAndPositionalTransferTargets() throws {
        let broker = try makeBroker(recorder: RemoteCallRecorder())
        let personalRemote = ["https://github.com/arimendelow/desk.git"]
        for arguments in [
            ["issue", "transfer", "1", "managed-org/repo"],
            ["issue", "transfer", "--repo", "arimendelow/current", "1", "managed-org/repo"],
            ["project", "list", "--owner", "managed-org"],
            ["secret", "set", "TOKEN", "--org=managed-org"],
            ["variable", "delete", "KEY", "-o", "managed-org"],
            ["codespace", "delete", "--repo-owner=managed-org"],
            ["repo", "fork", "arimendelow/source", "--org", "managed-org"],
            ["repo", "list", "managed-org"],
            ["repo", "list", "--limit", "10", "managed-org"],
            ["repo", "ls", "--limit=10", "managed-org"],
            ["label", "clone", "--force", "managed-org/source"],
            ["ruleset", "list", "--org", "managed-org"],
            ["attestation", "verify", "artifact", "-omanaged-org"],
            ["attestation", "verify", "artifact", "-o=managed-org"]
        ] {
            assertRemoteErrorContains("explicit GitHub owner") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }

        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["issue", "transfer", "1", "arimendelow/other"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["issue", "transfer", "--repo=arimendelow/current", "1", "arimendelow/other"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["repo", "list", "arimendelow"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["repo", "list", "--limit", "10", "arimendelow"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["repo", "ls", "--archived", "arimendelow"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["label", "clone", "--force", "arimendelow/source"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["label", "clone", "-f", "arimendelow/source"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["issue", "transfer", "--help"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["label", "clone", "--help"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: ["repo"], remoteURLs: personalRemote))
        for topLevelHelp in ["--help", "--version", "help"] {
            XCTAssertNoThrow(try broker.gh(profileID: "personal", arguments: [topLevelHelp], remoteURLs: personalRemote))
        }
        assertRemoteErrorContains("owner target is missing") {
            _ = try broker.gh(profileID: "personal", arguments: ["secret", "list", "--org"], remoteURLs: personalRemote)
        }
        for arguments in [
            ["repo", "list", "--future-shape", "managed-org"],
            ["repo", "list", "-Z", "managed-org"]
        ] {
            assertRemoteErrorContains("owner-bearing GitHub command option") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
        for arguments in [
            ["repo", "list", "--limit"],
            ["repo", "list", "--limit="],
            ["repo", "list", "-L"]
        ] {
            assertRemoteErrorContains("option value is missing") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
        for arguments in [
            ["issue", "transfer", "1"],
            ["repo", "list", "arimendelow", "other"],
            ["label", "clone", "--force"]
        ] {
            assertRemoteErrorContains("command shape") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
        for arguments in [
            ["repo", "list", "--", "managed-org"],
            ["repo", "list", "-L", "10", "managed-org"],
            ["repo", "list", "-L10", "managed-org"]
        ] {
            assertRemoteErrorContains("explicit GitHub owner") {
                _ = try broker.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
    }

    func testGhGuardFailsClosedForConfiguredAliasesExtensionsAndOpaqueCommands() throws {
        let personalRemote = ["https://github.com/arimendelow/desk.git"]
        let direct = try makeBroker(recorder: RemoteCallRecorder())
        for arguments in [
            ["alias", "set", "danger", "api /user"],
            ["extension", "exec", "danger"],
            ["ext", "exec", "danger"],
            ["configured-alias", "managed-org/repo"]
        ] {
            assertRemoteErrorContains("aliases and extensions") {
                _ = try direct.gh(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }

        let configuredAlias = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("danger: !/opt/homebrew/bin/gh repo delete managed-org/repo\n".utf8))
        ])
        assertRemoteErrorContains("configured GitHub aliases") {
            _ = try makeBroker(recorder: configuredAlias).gh(profileID: "personal", arguments: ["pr", "view"], remoteURLs: personalRemote)
        }
        XCTAssertEqual(configuredAlias.calls.first?.arguments, ["alias", "list"])

        let unavailableInspection = RemoteCallRecorder(responses: [.init(exitCode: 1)])
        assertRemoteErrorContains("could not be verified") {
            _ = try makeBroker(recorder: unavailableInspection).gh(profileID: "personal", arguments: ["pr", "view"], remoteURLs: personalRemote)
        }

        let failedInspection = RemoteCallRecorder()
        failedInspection.thrownError = RemoteFixtureError.expected
        assertRemoteErrorContains("could not be verified") {
            _ = try makeBroker(recorder: failedInspection).gh(profileID: "personal", arguments: ["pr", "view"], remoteURLs: personalRemote)
        }
    }

    func testGitGuardRejectsTargetChangingAndAliasConfigGlobalOptions() throws {
        let broker = try makeBroker(recorder: RemoteCallRecorder())
        for arguments in [
            ["-C", "/tmp/opposite", "push"],
            ["--git-dir=/tmp/opposite/.git", "push"],
            ["--work-tree", "/tmp/opposite", "status"],
            ["-c", "alias.pwn=!echo nope", "pwn"]
        ] {
            assertRemoteErrorContains("target-changing Git option") {
                _ = try broker.git(profileID: "personal", arguments: arguments, remoteURLs: ["https://github.com/arimendelow/desk.git"])
            }
        }
        for arguments in [
            ["remote", "add", "opposite", "https://github.com/managed-org/repo.git"],
            ["remote", "set-url", "origin", "https://github.com/managed-org/repo.git"]
        ] {
            assertRemoteErrorContains("explicit GitHub owner") {
                _ = try broker.git(profileID: "personal", arguments: arguments, remoteURLs: [])
            }
        }
        for arguments in [
            ["remote", "remove", "origin"],
            ["remote", "rename", "origin", "other"]
        ] {
            assertRemoteErrorContains("repository remote is required") {
                _ = try broker.git(profileID: "personal", arguments: arguments, remoteURLs: [])
            }
        }

        XCTAssertNoThrow(try broker.git(profileID: "personal", arguments: [], remoteURLs: []))
        XCTAssertNoThrow(try broker.git(profileID: "personal", arguments: ["remote"], remoteURLs: []))
    }

    func testGitGuardValidatesExplicitRemoteTargetsInsteadOfOnlyTheCurrentRepository() throws {
        let broker = try makeBroker(recorder: RemoteCallRecorder())
        let personalRemote = ["https://github.com/arimendelow/desk.git"]
        for arguments in [
            ["push", "https://github.com/managed-org/repo.git", "HEAD:main"],
            ["push", "git@github.com:managed-org/repo.git", "HEAD:main"],
            ["push", "github.com:managed-org/repo.git", "HEAD:main"],
            ["push", "--repo=https://github.com/managed-org/repo.git", "HEAD:main"],
            ["remote", "add", "managed", "https://github.com/managed-org/repo.git"],
            ["remote", "set-url", "origin", "https://github.com/managed-org/repo.git"]
        ] {
            assertRemoteErrorContains("explicit GitHub owner") {
                _ = try broker.git(profileID: "personal", arguments: arguments, remoteURLs: personalRemote)
            }
        }
        assertRemoteErrorContains("unsupported repository remote") {
            _ = try broker.git(profileID: "personal", arguments: ["push", "https://gitlab.com/managed-org/repo.git", "HEAD:main"], remoteURLs: personalRemote)
        }
        assertRemoteErrorContains("unsupported repository remote") {
            _ = try broker.git(profileID: "personal", arguments: ["push", "gitlab.com:managed-org/repo.git", "HEAD:main"], remoteURLs: personalRemote)
        }
        for target in [
            "https://github.com/arimendelow/../managed-org/repo.git",
            "git@github.com:arimendelow/../managed-org/repo.git"
        ] {
            assertRemoteErrorContains("unsupported repository remote") {
                _ = try broker.git(profileID: "personal", arguments: ["push", target, "HEAD:main"], remoteURLs: personalRemote)
            }
        }
        assertRemoteErrorContains("does not match the current repository") {
            _ = try broker.git(profileID: "personal", arguments: ["push", "https://github.com/ourostack/workbench.git", "HEAD:main"], remoteURLs: personalRemote)
        }

        XCTAssertNoThrow(try broker.git(profileID: "personal", arguments: ["push", "https://github.com/arimendelow/desk.git", "HEAD:main"], remoteURLs: personalRemote))
        XCTAssertNoThrow(try broker.git(profileID: "personal", arguments: ["status"], remoteURLs: personalRemote))
        assertRemoteErrorContains("unsupported repository remote") {
            _ = try broker.git(profileID: "personal", arguments: ["push", "ext::helper managed-org/repo", "HEAD:main"], remoteURLs: personalRemote)
        }

        XCTAssertEqual(try RemoteRepositoryPolicy.owners(from: ["https://github.com/arimendelow/desk"]), ["arimendelow"])
        assertRemoteErrorContains("unsupported repository remote") {
            _ = try RemoteRepositoryPolicy.owners(from: ["https://github.com/arimendelow/bad!repo"])
        }
    }

    private func assertInvalid(_ object: [String: Any], contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        assertRemoteErrorContains(text, file: file, line: line) {
            _ = try RemoteProfileRegistry.decode(
                try remoteJSONData(object),
                executableExists: { _ in true },
                credentialStoreResolver: remoteFixtureCredentialStore
            )
        }
    }

    private func makeBroker(
        recorder: RemoteCallRecorder,
        environment: [String: String] = [
            "PATH": "/usr/bin",
            "GH_TOKEN": "ambient-gh",
            "GITHUB_TOKEN": "ambient-github",
            "COPILOT_GITHUB_TOKEN": "ambient-copilot",
            "HERDR_GITHUB_TOKEN_FILE": "/tmp/ambient-token"
        ]
    ) throws -> RemoteAccountBroker {
        RemoteAccountBroker(
            registry: try remoteRegistry(),
            environment: environment,
            workingDirectory: "/tmp/desk",
            shimDirectory: "/tmp/ouro/shims",
            profileConfigPath: "/tmp/ouro/profiles.json",
            run: recorder.run
        )
    }
}
