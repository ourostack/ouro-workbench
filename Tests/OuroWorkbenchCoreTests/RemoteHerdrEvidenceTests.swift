import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteHerdrEvidenceTests: XCTestCase {
    func testProductionLedgerFactoryRoutesReconcileThroughPinnedHerdrEvidence() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ])
        let ledger = try RemoteResumeLedgerFactory.make(
            ledgerRootURL: root.appendingPathComponent("ledger"),
            herdrRootURL: root.appendingPathComponent("herdr"),
            registry: remoteRegistry(),
            inheritedEnvironment: ["GH_TOKEN": "drop-me"],
            run: recorder.run,
            listServerSessions: { [] },
            processIdentityForPID: { _, _ in nil }
        )
        let record = resumeRecord()
        try ledger.prepare(attemptID: "run-1", nativeSessionID: record.nativeSessionID, profileID: "personal", generation: "ouro-a", paneID: "desk:p1", ownerPID: getpid(), expectedArgvSHA256: record.expectedArgvSHA256)
        try ledger.markSpawnIntent(attemptID: "run-1")

        try ledger.reconcile(attemptID: "run-1", resolution: .abandon)

        XCTAssertEqual(try ledger.record(attemptID: "run-1")?.phase, .exited)
        XCTAssertEqual(recorder.calls.map(\.arguments), [["--version"], ["session", "list", "--json"]])

        var mismatched = remoteRegistryObject()
        var profiles = mismatched["profiles"] as! [[String: Any]]
        profiles[1]["herdrExecutable"] = "/fixtures/bin/other-herdr"
        mismatched["profiles"] = profiles
        let mismatchedRegistry = try RemoteProfileRegistry.decode(try remoteJSONData(mismatched), executableExists: { _ in true }, credentialStoreResolver: remoteFixtureCredentialStore)
        assertRemoteErrorContains("one exact Herdr executable") {
            _ = try RemoteResumeLedgerFactory.make(ledgerRootURL: root, herdrRootURL: root, registry: mismatchedRegistry, inheritedEnvironment: [:])
        }
    }

    func testProductionReconcileRetainsOwnershipWhenHerdrDiedButExactCopilotOrphanLives() throws {
        let root = try remoteTemporaryDirectory("global-copilot-orphan")
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeSessionID = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        var object = remoteRegistryObject(profileCount: 1)
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["copilotExecutable"] = "/usr/bin/tail"
        object["profiles"] = profiles
        let registry = try RemoteProfileRegistry.decode(
            try remoteJSONData(object),
            executableExists: { _ in true },
            credentialStoreResolver: remoteFixtureCredentialStore
        )
        let profile = try registry.profile(id: "personal")
        let expectedArguments = ["-f", "/dev/null"]
        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: profile.copilotExecutable)
        orphan.arguments = expectedArguments
        orphan.environment = [
            "OURO_PROFILE_ID": profile.id,
            "OURO_GENERATION": "ouro-a",
            "OURO_PANE_ID": "desk:p1"
        ]
        orphan.standardOutput = FileHandle.nullDevice
        orphan.standardError = FileHandle.nullDevice
        try orphan.run()
        defer {
            orphan.terminate()
            orphan.waitUntilExit()
        }
        XCTAssertTrue(orphan.isRunning)
        let orphanIdentity = try XCTUnwrap(remoteProcessIdentity(pid: orphan.processIdentifier, generation: "ouro-a"))
        XCTAssertEqual(orphanIdentity.executable, URL(fileURLWithPath: profile.copilotExecutable).resolvingSymlinksInPath().standardizedFileURL.path)
        let orphanSnapshot = try XCTUnwrap(RemoteProcessArguments.readSnapshot(pid: orphan.processIdentifier))
        XCTAssertEqual(orphanSnapshot.arguments, [profile.copilotExecutable] + expectedArguments)
        XCTAssertEqual(orphanSnapshot.environment["OURO_PROFILE_ID"], profile.id)
        XCTAssertEqual(orphanSnapshot.environment["OURO_GENERATION"], "ouro-a")
        XCTAssertEqual(orphanSnapshot.environment["OURO_PANE_ID"], "desk:p1")
        XCTAssertTrue(try RemoteNativeProcessIDs.all().contains(orphan.processIdentifier))
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ])
        let ledger = try RemoteResumeLedgerFactory.make(
            ledgerRootURL: root.appendingPathComponent("ledger"),
            herdrRootURL: root.appendingPathComponent("herdr"),
            registry: registry,
            inheritedEnvironment: [:],
            run: recorder.run,
            listServerSessions: { [] }
        )
        try ledger.prepare(
            attemptID: "orphan",
            nativeSessionID: nativeSessionID,
            profileID: profile.id,
            generation: "ouro-a",
            paneID: "desk:p1",
            ownerPID: getpid(),
            expectedArgvSHA256: RemoteArgvDigest.sha256([profile.copilotExecutable] + expectedArguments)
        )
        try ledger.markSpawnIntent(attemptID: "orphan")
        let saved = try XCTUnwrap(ledger.record(attemptID: "orphan"))
        XCTAssertEqual(saved.expectedArgvSHA256, RemoteArgvDigest.sha256(orphanSnapshot.arguments))
        XCTAssertEqual(saved.profileID, orphanSnapshot.environment["OURO_PROFILE_ID"])
        XCTAssertEqual(saved.generation, orphanSnapshot.environment["OURO_GENERATION"])
        XCTAssertEqual(saved.paneID, orphanSnapshot.environment["OURO_PANE_ID"])
        let directRecorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ])
        let provider = RemoteHerdrForegroundEvidenceProvider(
            rootURL: root.appendingPathComponent("herdr"),
            registry: registry,
            inheritedEnvironment: [:],
            run: directRecorder.run,
            listServerSessions: { [] },
            processIdentityForPID: { pid, generation in OuroWorkbenchCore.remoteProcessIdentity(pid: pid, generation: generation) }
        )
        XCTAssertEqual(provider.inspect(saved), .live)

        assertRemoteErrorContains("live child") {
            try ledger.reconcile(attemptID: "orphan", resolution: .abandon)
        }
        XCTAssertEqual(try ledger.record(attemptID: "orphan")?.phase, .spawnIntent)
        XCTAssertTrue(ledger.lockExists(nativeSessionID: nativeSessionID))
    }

    func testForegroundEvidenceProvesAbsenceAcrossEveryRunningHerdrPane() throws {
        let record = resumeRecord()
        let recorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [
                ["name": "ouro-a", "running": true],
                ["name": "stopped-copy", "running": false]
            ]])),
            .init(exitCode: 0, stdout: snapshot(session: "ouro-a", panes: ["desk:p1", "desk:p2"])),
            .init(exitCode: 0, stdout: processInfo(pane: "desk:p1", processes: [
                ["pid": 201, "name": "zsh", "argv0": "zsh", "argv": ["/bin/zsh"], "cmdline": "/bin/zsh", "cwd": "/tmp"]
            ])),
            .init(exitCode: 0, stdout: processInfo(pane: "desk:p2", processes: []))
        ])
        let provider = try makeProvider(recorder: recorder, serverSessions: ["ouro-a"], identities: [
            201: remoteProcessIdentity(pid: 201, executable: "/bin/zsh", generation: "ouro-a")
        ])

        XCTAssertEqual(provider.inspect(record), .absent)
        XCTAssertEqual(recorder.calls.map(\.arguments), [
            ["--version"],
            ["session", "list", "--json"],
            ["--session", "ouro-a", "api", "snapshot"],
            ["--session", "ouro-a", "pane", "process-info", "--pane", "desk:p1"],
            ["--session", "ouro-a", "pane", "process-info", "--pane", "desk:p2"]
        ])
        XCTAssertTrue(recorder.calls.allSatisfy { $0.executable == "/fixtures/bin/herdr" && $0.workingDirectory == "/tmp/herdr" })
        XCTAssertTrue(recorder.calls.allSatisfy { $0.environment["XDG_CONFIG_HOME"] == "/tmp" && $0.environment["GH_TOKEN"] == nil })
    }

    func testForegroundEvidenceFindsRecordedPIDOrExactResumeArgvAnywhere() throws {
        let record = resumeRecord(childIdentity: remoteProcessIdentity(pid: 200, executable: "/fixtures/bin/copilot", generation: "ouro-original"))
        for mode in ["pid", "argv"] {
            let profile = try remoteRegistry().profile(id: "personal")
            let argv = RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=8d5177d6-b6d1-4b5f-a546-564ed0ef8748"])
            let pid: Int32 = mode == "pid" ? 200 : 300
            let process: [String: Any] = [
                "pid": pid,
                "name": "copilot",
                "argv0": "copilot",
                "argv": [profile.copilotExecutable] + (mode == "argv" ? argv : ["different"]),
                "cmdline": "copilot",
                "cwd": "/tmp"
            ]
            let recorder = RemoteCallRecorder(responses: [
                .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
                .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-original", "running": true]]])),
                .init(exitCode: 0, stdout: snapshot(session: "ouro-original", panes: ["other:pane"])),
                .init(exitCode: 0, stdout: processInfo(pane: "other:pane", processes: [process]))
            ])
            let provider = try makeProvider(recorder: recorder, serverSessions: ["ouro-original"], identities: [
                pid: remoteProcessIdentity(pid: pid, executable: "/fixtures/bin/copilot", generation: "ouro-original")
            ])

            XCTAssertEqual(provider.inspect(record), .live, mode)
        }
    }

    func testForegroundEvidenceFailsClosedWhenAnyGlobalProofIsMissing() throws {
        let record = resumeRecord()
        let malformedOrIncomplete: [[RemoteProcessResult]] = [
            [.init(exitCode: 1)],
            [.init(exitCode: 0, stdout: Data("herdr 0.8.3\n".utf8))],
            [.init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)), .init(exitCode: 1)],
            [.init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)), .init(exitCode: 0, stdout: Data("not-json".utf8))]
        ]
        for responses in malformedOrIncomplete {
            let provider = try makeProvider(recorder: RemoteCallRecorder(responses: responses), serverSessions: [])
            XCTAssertEqual(provider.inspect(record), .unavailable)
        }

        let missingNative = resumeRecord(nativeSessionID: nil)
        XCTAssertEqual(try makeProvider(recorder: RemoteCallRecorder(), serverSessions: []).inspect(missingNative), .unavailable)

        let serverMismatch = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]]))
        ])
        XCTAssertEqual(try makeProvider(recorder: serverMismatch, serverSessions: []).inspect(record), .unavailable)

        let incompleteProcess = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
            .init(exitCode: 0, stdout: snapshot(session: "ouro-a", panes: ["desk:p1"])),
            .init(exitCode: 0, stdout: processInfo(pane: "desk:p1", processes: [["pid": 400, "name": "copilot"]]))
        ])
        XCTAssertEqual(try makeProvider(recorder: incompleteProcess, serverSessions: ["ouro-a"]).inspect(record), .unavailable)
    }

    func testForegroundEvidenceFailsClosedAcrossThrownMalformedAndMismatchedPaneProofs() throws {
        let record = resumeRecord()
        let throwing = RemoteCallRecorder()
        throwing.thrownError = RemoteFixtureError.expected
        XCTAssertEqual(try makeProvider(recorder: throwing, serverSessions: []).inspect(record), .unavailable)

        var mismatched = remoteRegistryObject()
        var profiles = mismatched["profiles"] as! [[String: Any]]
        profiles[1]["herdrExecutable"] = "/fixtures/bin/other-herdr"
        mismatched["profiles"] = profiles
        let mismatchedRegistry = try RemoteProfileRegistry.decode(try remoteJSONData(mismatched), executableExists: { _ in true }, credentialStoreResolver: remoteFixtureCredentialStore)
        let mismatchedProvider = RemoteHerdrForegroundEvidenceProvider(
            rootURL: URL(fileURLWithPath: "/tmp/herdr", isDirectory: true),
            registry: mismatchedRegistry,
            inheritedEnvironment: [:],
            run: RemoteCallRecorder().run,
            listServerSessions: { [] },
            processIdentityForPID: { _, _ in nil }
        )
        XCTAssertEqual(mismatchedProvider.inspect(record), .unavailable)

        let invalidSnapshots: [RemoteProcessResult] = [
            .init(exitCode: 1),
            .init(exitCode: 0, stdout: Data("{".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["result": ["snapshot": ["version": "0.8.1", "panes": []]]])),
            .init(exitCode: 0, stdout: snapshot(session: "ouro-a", panes: ["desk:p1", "desk:p1"]))
        ]
        for snapshotResult in invalidSnapshots {
            let recorder = RemoteCallRecorder(responses: [
                .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
                .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
                snapshotResult
            ])
            XCTAssertEqual(try makeProvider(recorder: recorder, serverSessions: ["ouro-a"]).inspect(record), .unavailable)
        }

        let invalidProcessResults: [RemoteProcessResult] = [
            .init(exitCode: 1),
            .init(exitCode: 0, stdout: Data("{".utf8)),
            .init(exitCode: 0, stdout: processInfo(pane: "other:pane", processes: []))
        ]
        for processResult in invalidProcessResults {
            let recorder = RemoteCallRecorder(responses: [
                .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
                .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
                .init(exitCode: 0, stdout: snapshot(session: "ouro-a", panes: ["desk:p1"])),
                processResult
            ])
            XCTAssertEqual(try makeProvider(recorder: recorder, serverSessions: ["ouro-a"]).inspect(record), .unavailable)
        }

        let profile = try remoteRegistry().profile(id: "personal")
        let exactArguments = [profile.copilotExecutable] + RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(record.nativeSessionID!)"])
        let wrongIdentity = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
            .init(exitCode: 0, stdout: snapshot(session: "ouro-a", panes: ["desk:p1"])),
            .init(exitCode: 0, stdout: processInfo(pane: "desk:p1", processes: [["pid": 401, "argv": exactArguments]]))
        ])
        XCTAssertEqual(try makeProvider(recorder: wrongIdentity, serverSessions: ["ouro-a"], identities: [401: remoteProcessIdentity(pid: 401, executable: "/wrong")]).inspect(record), .unavailable)
    }

    func testForegroundEvidenceRejectsMissingDigestsAndUnstableNativeProcessProof() throws {
        var unavailableDigest = resumeRecord()
        unavailableDigest.expectedArgvSHA256 = RemoteArgvDigest.unavailable
        XCTAssertEqual(try makeProvider(recorder: RemoteCallRecorder(), serverSessions: []).inspect(unavailableDigest), .unavailable)
        var unknownProfile = resumeRecord()
        unknownProfile.profileID = "missing"
        XCTAssertEqual(try makeProvider(recorder: RemoteCallRecorder(), serverSessions: []).inspect(unknownProfile), .unavailable)

        let profile = try remoteRegistry().profile(id: "personal")
        let child = remoteProcessIdentity(pid: 401, executable: profile.copilotExecutable, generation: "ouro-original")
        let childRecord = resumeRecord(childIdentity: child)
        let expectedArguments = [profile.copilotExecutable] + RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(childRecord.nativeSessionID!)"])
        let unstableChild = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-original", "running": true]]])),
            .init(exitCode: 0, stdout: snapshot(session: "ouro-original", panes: ["desk:p1"])),
            .init(exitCode: 0, stdout: processInfo(pane: "desk:p1", processes: [["pid": 401, "argv": expectedArguments]]))
        ])
        let childProvider = RemoteHerdrForegroundEvidenceProvider(
            rootURL: URL(fileURLWithPath: "/tmp/herdr", isDirectory: true),
            registry: try remoteRegistry(),
            inheritedEnvironment: [:],
            run: unstableChild.run,
            listServerSessions: { ["ouro-original"] },
            processIdentityForPID: { _, _ in remoteProcessIdentity(pid: 401, startIdentity: "changed", executable: profile.copilotExecutable, generation: "ouro-original") },
            listProcessIDs: { [] }
        )
        XCTAssertEqual(childProvider.inspect(childRecord), .unavailable)

        let globalIdentity = remoteProcessIdentity(pid: 402, executable: profile.copilotExecutable, generation: "ouro-original")
        let missingSnapshot = RemoteHerdrForegroundEvidenceProvider(
            rootURL: URL(fileURLWithPath: "/tmp/herdr", isDirectory: true),
            registry: try remoteRegistry(),
            inheritedEnvironment: [:],
            run: RemoteCallRecorder().run,
            listServerSessions: { [] },
            processIdentityForPID: { _, _ in globalIdentity },
            listProcessIDs: { [402] },
            processSnapshotForPID: { _ in nil }
        )
        XCTAssertEqual(missingSnapshot.inspect(resumeRecord()), .unavailable)

        var identityReads = 0
        let changedAfterSnapshot = RemoteHerdrForegroundEvidenceProvider(
            rootURL: URL(fileURLWithPath: "/tmp/herdr", isDirectory: true),
            registry: try remoteRegistry(),
            inheritedEnvironment: [:],
            run: RemoteCallRecorder().run,
            listServerSessions: { [] },
            processIdentityForPID: { _, _ in
                identityReads += 1
                return identityReads == 1 ? globalIdentity : remoteProcessIdentity(pid: 402, startIdentity: "changed", executable: profile.copilotExecutable, generation: "ouro-original")
            },
            listProcessIDs: { [402] },
            processSnapshotForPID: { _ in RemoteProcessSnapshot(arguments: expectedArguments, environment: [:]) }
        )
        XCTAssertEqual(changedAfterSnapshot.inspect(resumeRecord()), .unavailable)

        let mismatchedEnvironmentRecorder = RemoteCallRecorder(responses: [
            .init(exitCode: 0, stdout: Data("herdr 0.8.2\n".utf8)),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ])
        let mismatchedEnvironment = RemoteHerdrForegroundEvidenceProvider(
            rootURL: URL(fileURLWithPath: "/tmp/herdr", isDirectory: true),
            registry: try remoteRegistry(),
            inheritedEnvironment: [:],
            run: mismatchedEnvironmentRecorder.run,
            listServerSessions: { [] },
            processIdentityForPID: { _, _ in globalIdentity },
            listProcessIDs: { [402] },
            processSnapshotForPID: { _ in RemoteProcessSnapshot(arguments: expectedArguments, environment: ["OURO_PROFILE_ID": "wrong"]) }
        )
        XCTAssertEqual(mismatchedEnvironment.inspect(resumeRecord()), .absent)
    }

    func testProductionLedgerFactoryDefaultRunnerAndProcessScannerExecuteAgainstPinnedFixture() throws {
        let root = try remoteTemporaryDirectory("evidence-defaults")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("herdr")
        let script = """
        #!/bin/sh
        case "$*" in
          "--version") printf 'herdr 0.8.2\n' ;;
          "session list --json") printf '{"sessions":[]}' ;;
          *) exit 3 ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("herdr-root"), withIntermediateDirectories: false)
        var object = remoteRegistryObject()
        var profiles = object["profiles"] as! [[String: Any]]
        for index in profiles.indices { profiles[index]["herdrExecutable"] = executable.path }
        object["profiles"] = profiles
        let registry = try RemoteProfileRegistry.decode(try remoteJSONData(object), executableExists: { _ in true }, credentialStoreResolver: remoteFixtureCredentialStore)
        let ledger = try RemoteResumeLedgerFactory.make(
            ledgerRootURL: root.appendingPathComponent("ledger"),
            herdrRootURL: root.appendingPathComponent("herdr-root"),
            registry: registry,
            inheritedEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        let record = resumeRecord()
        try ledger.prepare(attemptID: "run-defaults", nativeSessionID: record.nativeSessionID, profileID: "personal", generation: "ouro-a", paneID: "desk:p1", ownerPID: getpid(), expectedArgvSHA256: record.expectedArgvSHA256)
        try ledger.markSpawnIntent(attemptID: "run-defaults")
        try ledger.reconcile(attemptID: "run-defaults", resolution: .abandon)
        XCTAssertEqual(try ledger.record(attemptID: "run-defaults")?.phase, .exited)
    }

    private func makeProvider(
        recorder: RemoteCallRecorder,
        serverSessions: [String],
        identities: [Int32: RemoteProcessIdentity] = [:]
    ) throws -> RemoteHerdrForegroundEvidenceProvider {
        RemoteHerdrForegroundEvidenceProvider(
            rootURL: URL(fileURLWithPath: "/tmp/herdr", isDirectory: true),
            registry: try remoteRegistry(),
            inheritedEnvironment: ["HOME": "/Users/example", "GH_TOKEN": "drop-me"],
            run: recorder.run,
            listServerSessions: { serverSessions },
            processIdentityForPID: { pid, generation in identities[pid].map { RemoteProcessIdentity(pid: $0.pid, startIdentity: $0.startIdentity, executable: $0.executable, generation: generation) } },
            listProcessIDs: { [] }
        )
    }

    private func resumeRecord(nativeSessionID: String? = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748", childIdentity: RemoteProcessIdentity? = nil) -> RemoteResumeRecord {
        let profile = try! remoteRegistry().profile(id: "personal")
        let arguments = nativeSessionID.map { RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\($0)"]) } ?? []
        return RemoteResumeRecord(
            attemptID: "run-1",
            nativeSessionID: nativeSessionID,
            profileID: "personal",
            generation: "ouro-original",
            paneID: "desk:p1",
            ownerPID: 10,
            expectedArgvSHA256: RemoteArgvDigest.sha256([profile.copilotExecutable] + arguments),
            childIdentity: childIdentity,
            hookSessionID: nativeSessionID,
            phase: .recoveryRequired,
            exitStatus: nil
        )
    }

    private func snapshot(session: String, panes: [String]) -> Data {
        try! remoteJSONData(["result": ["snapshot": [
            "version": "0.8.2",
            "panes": panes.map { ["pane_id": $0, "workspace_id": session] }
        ]]])
    }

    private func processInfo(pane: String, processes: [[String: Any]]) -> Data {
        try! remoteJSONData(["result": ["process_info": [
            "pane_id": pane,
            "shell_pid": 100,
            "foreground_processes": processes
        ]]])
    }
}
