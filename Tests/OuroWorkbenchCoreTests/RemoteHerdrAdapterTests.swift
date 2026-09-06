import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteHerdrAdapterTests: XCTestCase {
    func testProbeAndSessionRoutesUsePinnedHerdrRequestsAndSanitizedEnvironment() throws {
        let fixture = try AdapterFixture()
        fixture.responses = [
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [
                ["name": "ouro-b", "running": false],
                ["name": "foreign", "running": true],
                ["name": "ouro-a", "running": true]
            ]])),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "missing", "running": false]]]))
        ]

        XCTAssertEqual(try fixture.adapter().listManagedSessions(), ["ouro-b", "ouro-a"])
        XCTAssertEqual(try fixture.adapter().probe(sessionName: "missing"), .absent)
        XCTAssertEqual(fixture.calls.map(\.request.arguments), [["session", "list", "--json"], ["session", "list", "--json"]])
        XCTAssertTrue(fixture.calls.allSatisfy { $0.timeout == 10 })
        XCTAssertTrue(fixture.calls.allSatisfy {
            $0.request.executable == "/fixtures/bin/herdr"
                && $0.request.workingDirectory == fixture.root.path
                && $0.request.environment["XDG_CONFIG_HOME"] == fixture.root.deletingLastPathComponent().path
                && $0.request.environment["OURO_LEDGER_ROOT"] == fixture.ledger.rootURL.path
                && $0.request.environment["SECRET"] == nil
        })

        fixture.serverSessions = ["foreign", "ouro-a"]
        XCTAssertEqual(try fixture.adapter().listHerdrProcessSessions(), ["foreign", "ouro-a"])
        XCTAssertEqual(try fixture.adapter().listManagedProcessSessions(), ["ouro-a"])
    }

    func testProbeFailsClosedWithSpecificBoundaryErrors() throws {
        let fixture = try AdapterFixture()
        fixture.error = RemoteFixtureError.expected
        XCTAssertEqual(try fixture.adapter().probe(sessionName: "ouro-a"), .degraded("session enumeration failed"))
        fixture.error = nil
        fixture.responses = [
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
            .init(exitCode: 1)
        ]
        guard case let .degraded(detail) = try fixture.adapter().probe(sessionName: "ouro-a") else {
            return XCTFail("expected degraded")
        }
        XCTAssertTrue(detail.contains("snapshot request failed"))

        fixture.responses = [
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
            .init(exitCode: 0, stdout: try fixture.snapshot())
        ]
        guard case let .running(inventory) = try fixture.adapter().probe(sessionName: "ouro-a") else {
            return XCTFail("expected running")
        }
        XCTAssertEqual(inventory, .init(version: "0.8.2", panes: []))

        fixture.runHandler = { request, _ in
            if request.arguments.contains("snapshot") { throw RemoteFixtureError.expected }
            return .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]]))
        }
        XCTAssertEqual(try fixture.adapter().probe(sessionName: "ouro-a"), .degraded("inventory probe failed"))
    }

    func testInventoryVerifiesAFreshLaunchUsingItsDurableExactArgvDigest() throws {
        let fixture = try AdapterFixture()
        try fixture.installMapping()
        let profile = try remoteRegistry().profile(id: "personal")
        let freshArguments = RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["start fresh"])
        let identity = remoteProcessIdentity(pid: 200, startIdentity: "birth-200", executable: profile.copilotExecutable, generation: "ouro-a")
        fixture.identities[200] = identity
        fixture.identities[88] = remoteProcessIdentity(pid: 88, executable: "/bin/zsh", generation: "ouro-a")
        try fixture.ledger.prepare(
            attemptID: "fresh",
            nativeSessionID: nil,
            profileID: profile.id,
            generation: "ouro-a",
            paneID: "desk:p1",
            ownerPID: getpid(),
            expectedArgvSHA256: RemoteArgvDigest.sha256([profile.copilotExecutable] + freshArguments)
        )
        try fixture.ledger.markSpawnIntent(attemptID: "fresh")
        try fixture.ledger.recordChild(attemptID: "fresh", identity: identity)
        try fixture.ledger.confirm(nativeSessionID: fixture.nativeSessionID, profileID: profile.id, generation: "ouro-a", paneID: "desk:p1")
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane()])),
            .init(exitCode: 0, stdout: try fixture.processInfo(argv: [profile.copilotExecutable] + freshArguments)),
            .init(exitCode: 0, stdout: Data("arimendelow\n".utf8))
        ]

        let inventory = try fixture.adapter().inventory(sessionName: "ouro-a")

        XCTAssertEqual(inventory.panes.first?.profileID, profile.id)
        XCTAssertEqual(inventory.panes.first?.childPresent, true)
        XCTAssertEqual(inventory.panes.first?.hookObserved, true)
    }

    func testActiveRuntimeHealthRequiresExactExpectedInventoryAndWorkerIdentity() throws {
        let fixture = try AdapterFixture()
        try fixture.installVerifiedPane()
        fixture.expectedInventoryData = try remoteJSONData([
            "version": 1,
            "generation": "ouro-a",
            "acknowledged_empty": false,
            "panes": [["pane_id": "desk:p1", "native_session_id": fixture.nativeSessionID, "profile_id": "personal"]]
        ])
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane()])),
            .init(exitCode: 0, stdout: try fixture.processInfo()),
            .init(exitCode: 0, stdout: Data("arimendelow\n".utf8))
        ]
        let adapter = try fixture.adapter()
        let inventory = try adapter.inventory(sessionName: "ouro-a")

        XCTAssertTrue(try adapter.activeRuntimeIsExact(fixture.runtime(), inventory: inventory))

        var mismatched = inventory
        mismatched.panes[0].githubLogin = "wrong-account"
        XCTAssertFalse(try adapter.activeRuntimeIsExact(fixture.runtime(), inventory: mismatched))
    }

    func testSessionListingRejectsNonzeroAndMalformedResponses() throws {
        let fixture = try AdapterFixture()
        fixture.responses = [.init(exitCode: 4)]
        assertRemoteErrorContains("enumeration failed") { _ = try fixture.adapter().listManagedSessions() }
        fixture.responses = [.init(exitCode: 0, stdout: Data("not json".utf8))]
        assertRemoteErrorContains("response is invalid") { _ = try fixture.adapter().listManagedSessions() }
        fixture.scannerError = RemoteFixtureError.expected
        XCTAssertThrowsError(try fixture.adapter().listHerdrProcessSessions())
    }

    func testResumeTreatsEveryFailureAfterPaneRunInvocationAsPostIntent() throws {
        let fixture = try AdapterFixture()
        let command = fixture.resumeCommand()
        fixture.error = RemoteFixtureError.expected
        assertPostIntent("transport failed") { _ = try fixture.adapter().resume(command) }

        fixture.error = nil
        fixture.responses = [.init(exitCode: 9)]
        assertPostIntent("nonzero") { _ = try fixture.adapter().resume(command) }

        fixture.responses = [
            .init(exitCode: 0),
            .init(exitCode: 1)
        ]
        assertPostIntent("evidence") { _ = try fixture.adapter().resume(command) }
    }

    func testResumeRejectsEveryNonExactCommandBeforeInvocation() throws {
        let fixture = try AdapterFixture()
        let valid = fixture.resumeCommand()
        var invalid: [RemotePaneResumeCommand] = [
            .init(paneID: valid.paneID, helperPath: "/wrong", arguments: valid.arguments),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: Array(valid.arguments.dropLast())),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: ["launch"] + Array(valid.arguments.dropFirst())),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 1, with: "--id")),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 2, with: "not-uuid")),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 2, with: valid.arguments[2].uppercased())),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 3, with: "--account")),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 4, with: "missing")),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 5, with: "--session")),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 6, with: "unsafe/session")),
            .init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: replace(valid.arguments, at: 7, with: "--target")),
            .init(paneID: "other:pane", helperPath: valid.helperPath, arguments: valid.arguments)
        ]
        invalid.append(.init(paneID: valid.paneID, helperPath: valid.helperPath, arguments: valid.arguments + ["extra"]))

        for command in invalid {
            assertRemoteErrorContains("before spawn") { _ = try fixture.adapter().resume(command) }
        }
        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testResumeRunsTheExactQuotedHelperAndReturnsOnlyAfterChildAndHookEvidence() throws {
        let fixture = try AdapterFixture()
        try fixture.installVerifiedPane()
        fixture.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane()])),
            .init(exitCode: 0, stdout: try fixture.processInfo()),
            .init(exitCode: 0, stdout: Data("arimendelow\n".utf8))
        ]

        let inventory = try fixture.adapter().resume(fixture.resumeCommand())

        XCTAssertEqual(inventory.panes.first?.profileID, "personal")
        XCTAssertEqual(inventory.panes.first?.githubLogin, "arimendelow")
        XCTAssertEqual(inventory.panes.first?.childPresent, true)
        XCTAssertEqual(inventory.panes.first?.hookObserved, true)
        XCTAssertEqual(fixture.calls.first?.timeout, 15)
        XCTAssertEqual(fixture.calls.first?.request.arguments, ["--session", "ouro-a", "pane", "run", "desk:p1", "'/runtime/helper' 'resume' '--uuid' '8d5177d6-b6d1-4b5f-a546-564ed0ef8748' '--profile' 'personal' '--generation' 'ouro-a' '--pane' 'desk:p1'"])
    }

    func testResumeTimesOutWhenExactEvidenceNeverAppears() throws {
        let fixture = try AdapterFixture()
        fixture.advancePerSleep = 46
        fixture.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try fixture.snapshot())
        ]
        assertPostIntent("timed out") { _ = try fixture.adapter().resume(fixture.resumeCommand()) }
        XCTAssertEqual(fixture.sleepDurations, [0.1])
    }

    func testBootRequiresAnExactGenerationAndDurablyDisabledAutomaticResume() throws {
        let fixture = try AdapterFixture()
        let valid = fixture.bootRequest()
        let invalid = [
            RemoteHerdrBootRequest(sessionName: valid.sessionName, stagedSessionURL: fixture.root.appendingPathComponent("other"), expectedVersion: valid.expectedVersion, resumeAgentsOnRestore: false),
            RemoteHerdrBootRequest(sessionName: valid.sessionName, stagedSessionURL: valid.stagedSessionURL, expectedVersion: "0.8.1", resumeAgentsOnRestore: false),
            RemoteHerdrBootRequest(sessionName: valid.sessionName, stagedSessionURL: valid.stagedSessionURL, expectedVersion: valid.expectedVersion, resumeAgentsOnRestore: true)
        ]
        for request in invalid {
            assertRemoteErrorContains("before spawn") { _ = try fixture.adapter().boot(request) }
        }
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertTrue(fixture.spawnedRequests.isEmpty)

        for config in ["", "[session]\nresume_agents_on_restore = true\n", "[session]\nresume_agents_on_restore = false\nresume_agents_on_restore = false\n", "[other]\nresume_agents_on_restore = false\n"] {
            fixture.privateFileData = Data(config.utf8)
            assertRemoteErrorContains("durably disabled") { _ = try fixture.adapter().boot(valid) }
        }
        fixture.privateFileError = RemoteFixtureError.expected
        XCTAssertThrowsError(try fixture.adapter().boot(valid))
        fixture.privateFileError = nil
        fixture.privateFileData = Data("#\n[session]\nresume_agents_on_restore = false # required\n[other]\nresume_agents_on_restore = true\n".utf8)
        fixture.responses = [.init(exitCode: 2)]
        assertRemoteErrorContains("config validation failed") { _ = try fixture.adapter().boot(valid) }
    }

    func testBootStartsPinnedHerdrAndClassifiesSpawnExitTimeoutAndSuccess() throws {
        let fixture = try AdapterFixture()
        let request = fixture.bootRequest()
        fixture.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
            .init(exitCode: 0, stdout: try fixture.snapshot())
        ]
        XCTAssertEqual(try fixture.adapter().boot(request), .init(version: "0.8.2", panes: []))
        XCTAssertEqual(fixture.spawnedRequests.first?.executable, "/fixtures/bin/herdr")
        XCTAssertEqual(fixture.spawnedRequests.first?.arguments, ["--session", "ouro-a", "server"])
        XCTAssertEqual(fixture.spawnedRequests.first?.workingDirectory, fixture.root.path)

        let spawnFailure = try AdapterFixture()
        spawnFailure.spawnError = RemoteFixtureError.expected
        spawnFailure.responses = [.init(exitCode: 0)]
        assertRemoteErrorContains("before spawn") { _ = try spawnFailure.adapter().boot(spawnFailure.bootRequest()) }

        let dead = try AdapterFixture()
        dead.serverRunning = false
        dead.responses = [.init(exitCode: 0)]
        assertRemoteErrorContains("exited during boot") { _ = try dead.adapter().boot(dead.bootRequest()) }

        let timeout = try AdapterFixture()
        timeout.advancePerSleep = 16
        timeout.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ]
        assertRemoteErrorContains("boot timed out") { _ = try timeout.adapter().boot(timeout.bootRequest()) }
        XCTAssertEqual(timeout.terminateCount, 1)
        XCTAssertEqual(timeout.waitCount, 1)

        let cleanupFailure = try AdapterFixture()
        cleanupFailure.advancePerSleep = 16
        cleanupFailure.cleanupSucceeds = false
        cleanupFailure.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ]
        assertRemoteErrorContains("cleanup timed out") { _ = try cleanupFailure.adapter().boot(cleanupFailure.bootRequest()) }
    }

    func testStopRequiresCommandSuccessAndProvesSessionSocketAndProcessAbsence() throws {
        let failure = try AdapterFixture()
        failure.responses = [.init(exitCode: 2)]
        XCTAssertEqual(try failure.adapter().stop(sessionName: "ouro-a"), .degraded("session stop failed"))

        let nonexistent = try AdapterFixture()
        nonexistent.responses = [
            .init(exitCode: 1),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ]
        XCTAssertEqual(try nonexistent.adapter().stop(sessionName: "ouro-a"), .absent)

        let success = try AdapterFixture()
        success.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ]
        XCTAssertEqual(try success.adapter().stop(sessionName: "ouro-a"), .absent)
        XCTAssertEqual(success.calls.first?.request.arguments, ["session", "stop", "ouro-a", "--json"])
        XCTAssertEqual(success.calls.first?.timeout, 20)

        for blocker in ["herdr.sock", "herdr-client.sock", "process"] {
            let blocked = try AdapterFixture()
            blocked.advancePerSleep = 6
            blocked.responses = [
                .init(exitCode: 0),
                .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
            ]
            if blocker == "process" { blocked.serverSessions = ["ouro-a"] }
            else { blocked.existingPaths.insert(blocked.root.appendingPathComponent("sessions/ouro-a/\(blocker)").path) }
            XCTAssertEqual(try blocked.adapter().stop(sessionName: "ouro-a"), .degraded("session stop could not prove both socket and process absence"))
        }

        let stillRunning = try AdapterFixture()
        stillRunning.advancePerSleep = 6
        stillRunning.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
            .init(exitCode: 1)
        ]
        XCTAssertEqual(try stillRunning.adapter().stop(sessionName: "ouro-a"), .degraded("session stop could not prove both socket and process absence"))

        let scanFailure = try AdapterFixture()
        scanFailure.scannerError = RemoteFixtureError.expected
        scanFailure.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
        ]
        XCTAssertThrowsError(try scanFailure.adapter().stop(sessionName: "ouro-a"))
    }

    func testReactivateReturnsRunningOrDegradedWithoutLeakingStartErrors() throws {
        let success = try AdapterFixture()
        success.responses = [
            .init(exitCode: 0),
            .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
            .init(exitCode: 0, stdout: try success.snapshot())
        ]
        guard case let .running(inventory) = try success.adapter().reactivate(success.runtime()) else { return XCTFail("expected running") }
        XCTAssertEqual(inventory.version, "0.8.2")
        XCTAssertEqual(success.calls.first?.request.arguments, ["config", "check"])

        let spawnFailure = try AdapterFixture()
        spawnFailure.spawnError = RemoteFixtureError.expected
        spawnFailure.responses = [.init(exitCode: 0)]
        XCTAssertEqual(try spawnFailure.adapter().reactivate(spawnFailure.runtime()), .degraded("prior generation reactivation failed"))

        let dead = try AdapterFixture()
        dead.serverRunning = false
        XCTAssertEqual(try dead.adapter().reactivate(dead.runtime()), .degraded("prior generation reactivation failed"))

        let timeout = try AdapterFixture()
        timeout.advancePerSleep = 16
        timeout.responses = [.init(exitCode: 0), .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))]
        XCTAssertEqual(try timeout.adapter().reactivate(timeout.runtime()), .degraded("prior generation reactivation failed"))
        XCTAssertEqual(timeout.terminateCount, 1)
        XCTAssertEqual(timeout.waitCount, 1)


        let cleanupFailure = try AdapterFixture()
        cleanupFailure.advancePerSleep = 16
        cleanupFailure.cleanupSucceeds = false
        cleanupFailure.responses = [.init(exitCode: 0), .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))]
        XCTAssertEqual(try cleanupFailure.adapter().reactivate(cleanupFailure.runtime()), .degraded("prior generation reactivation failed; possible child ownership remains"))

        let enabled = try AdapterFixture()
        enabled.privateFileData = Data("[session]\nresume_agents_on_restore = true\n".utf8)
        XCTAssertEqual(try enabled.adapter().reactivate(enabled.runtime()), .degraded("prior generation reactivation failed"))
        XCTAssertTrue(enabled.spawnedRequests.isEmpty)

        let invalid = try AdapterFixture()
        invalid.responses = [.init(exitCode: 1)]
        XCTAssertEqual(try invalid.adapter().reactivate(invalid.runtime()), .degraded("prior generation reactivation failed"))
        XCTAssertTrue(invalid.spawnedRequests.isEmpty)
    }

    func testReactivateSequentiallyResumesEveryExpectedPaneToExactInventory() throws {
        let fixture = try AdapterFixture()
        let secondUUID = "2a4dc748-ea21-4b6a-9306-ce6c27c5fb62"
        let panes = [
            (id: "desk:p1", uuid: fixture.nativeSessionID, profile: "personal", shellPID: Int32(88), childPID: Int32(200)),
            (id: "desk:p2", uuid: secondUUID, profile: "emu", shellPID: Int32(89), childPID: Int32(201))
        ]
        fixture.expectedInventoryData = try remoteJSONData([
            "version": 1,
            "generation": "ouro-a",
            "acknowledged_empty": false,
            "panes": panes.map { ["pane_id": $0.id, "native_session_id": $0.uuid, "profile_id": $0.profile] }
        ])
        fixture.mappingFileData = try remoteJSONData([
            "schemaVersion": 1,
            "entries": panes.map { ["sessionID": $0.uuid, "profileID": $0.profile, "paneID": $0.id, "generation": "ouro-a"] }
        ])
        fixture.identities[88] = remoteProcessIdentity(pid: 88, executable: "/bin/zsh", generation: "ouro-a")
        fixture.identities[89] = remoteProcessIdentity(pid: 89, executable: "/bin/zsh", generation: "ouro-a")
        var resumed = Set<String>()
        fixture.runHandler = { request, _ in
            switch request.arguments {
            case ["config", "check"]:
                return .init(exitCode: 0)
            case ["session", "list", "--json"]:
                return .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]]))
            case ["--session", "ouro-a", "api", "snapshot"]:
                return .init(exitCode: 0, stdout: try fixture.snapshot(panes: panes.map { fixture.snapshotPane(paneID: $0.id, agent: ["agent": "copilot", "value": $0.uuid]) }))
            case let arguments where arguments.count == 6 && arguments[0...3] == ["--session", "ouro-a", "pane", "run"]:
                let pane = try XCTUnwrap(panes.first { $0.id == arguments[4] })
                let profile = try remoteRegistry().profile(id: pane.profile)
                let identity = remoteProcessIdentity(pid: pane.childPID, startIdentity: "birth-\(pane.childPID)", executable: profile.copilotExecutable, generation: "ouro-a")
                fixture.identities[pane.childPID] = identity
                let expectedArguments = RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(pane.uuid)"])
                try fixture.ledger.prepare(attemptID: "attempt-\(pane.childPID)", nativeSessionID: pane.uuid, profileID: pane.profile, generation: "ouro-a", paneID: pane.id, ownerPID: getpid(), expectedArgvSHA256: RemoteArgvDigest.sha256([profile.copilotExecutable] + expectedArguments))
                try fixture.ledger.markSpawnIntent(attemptID: "attempt-\(pane.childPID)")
                try fixture.ledger.recordChild(attemptID: "attempt-\(pane.childPID)", identity: identity)
                try fixture.ledger.confirm(nativeSessionID: pane.uuid, profileID: pane.profile, generation: "ouro-a", paneID: pane.id)
                resumed.insert(pane.id)
                return .init(exitCode: 0)
            case let arguments where arguments.count == 6 && arguments[0...4] == ["--session", "ouro-a", "pane", "process-info", "--pane"]:
                let pane = try XCTUnwrap(panes.first { $0.id == arguments[5] })
                let foreground: [[String: Any]]
                if resumed.contains(pane.id) {
                    let profile = try remoteRegistry().profile(id: pane.profile)
                    foreground = [[
                        "pid": pane.childPID,
                        "argv": [profile.copilotExecutable] + RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(pane.uuid)"])
                    ]]
                } else {
                    foreground = []
                }
                return .init(exitCode: 0, stdout: try remoteJSONData(["result": ["process_info": ["shell_pid": pane.shellPID, "foreground_processes": foreground]]]))
            case ["api", "/user", "--jq", ".login"]:
                let login = request.environment["GH_CONFIG_DIR"] == "/tmp/ouro/gh/emu" ? "arimendelow_microsoft" : "arimendelow"
                return .init(exitCode: 0, stdout: Data("\(login)\n".utf8))
            default:
                return .init(exitCode: 3)
            }
        }

        let result = try fixture.adapter().reactivate(fixture.runtime())

        guard case let .running(inventory) = result else { return XCTFail("expected exact reactivation, got \(result)") }
        XCTAssertEqual(inventory.panes.map(\.profileID), ["personal", "emu"])
        XCTAssertEqual(inventory.panes.map(\.childPresent), [true, true])
        let paneRuns = fixture.calls.filter { $0.request.arguments.count > 3 && $0.request.arguments[3] == "run" }
        XCTAssertEqual(paneRuns.map { $0.request.arguments[4] }, ["desk:p1", "desk:p2"])
    }

    func testReactivateStopsCleanlyAfterStructuralMismatchAndContainsStopProofFailure() throws {
        for scanFails in [false, true] {
            let fixture = try AdapterFixture()
            fixture.scannerError = scanFails ? RemoteFixtureError.expected : nil
            fixture.responses = [
                .init(exitCode: 0),
                .init(exitCode: 0, stdout: try remoteJSONData(["sessions": [["name": "ouro-a", "running": true]]])),
                .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane(agent: nil)])),
                .init(exitCode: 0, stdout: try remoteJSONData(["result": ["process_info": ["foreground_processes": []]]])),
                .init(exitCode: 0),
                .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []]))
            ]
            let expected = scanFails
                ? RemoteHerdrProbe.degraded("prior generation reactivation failed; possible child ownership remains")
                : RemoteHerdrProbe.degraded("prior generation reactivation failed; no managed process remains")
            XCTAssertEqual(try fixture.adapter().reactivate(fixture.runtime()), expected)
        }
    }

    func testReactivateRejectsPostResumeInventoryExpansion() throws {
        let fixture = try AdapterFixture()
        fixture.expectedInventoryData = try remoteJSONData([
            "version": 1,
            "generation": "ouro-a",
            "acknowledged_empty": false,
            "panes": [["pane_id": "desk:p1", "native_session_id": fixture.nativeSessionID, "profile_id": "personal"]]
        ])
        try fixture.installMapping()
        fixture.identities[88] = remoteProcessIdentity(pid: 88, executable: "/bin/zsh", generation: "ouro-a")
        var resumed = false
        var stopping = false
        fixture.runHandler = { request, _ in
            switch request.arguments {
            case ["config", "check"]:
                return .init(exitCode: 0)
            case ["session", "list", "--json"]:
                return .init(exitCode: 0, stdout: try remoteJSONData(["sessions": stopping ? [] : [["name": "ouro-a", "running": true]]]))
            case ["session", "stop", "ouro-a", "--json"]:
                stopping = true
                return .init(exitCode: 0)
            case ["--session", "ouro-a", "pane", "run", "desk:p1", fixture.resumeCommand().shellCommand]:
                try fixture.installLedgerOnly()
                resumed = true
                return .init(exitCode: 0)
            case ["--session", "ouro-a", "api", "snapshot"]:
                let panes = resumed ? [fixture.snapshotPane(), fixture.snapshotPane(paneID: "desk:p2", agent: nil)] : [fixture.snapshotPane()]
                return .init(exitCode: 0, stdout: try fixture.snapshot(panes: panes))
            case ["--session", "ouro-a", "pane", "process-info", "--pane", "desk:p1"]:
                return .init(exitCode: 0, stdout: resumed ? try fixture.processInfo() : try remoteJSONData(["result": ["process_info": ["shell_pid": 88, "foreground_processes": []]]]))
            case ["--session", "ouro-a", "pane", "process-info", "--pane", "desk:p2"]:
                return .init(exitCode: 0, stdout: try remoteJSONData(["result": ["process_info": ["foreground_processes": []]]]))
            case ["api", "/user", "--jq", ".login"]:
                return .init(exitCode: 0, stdout: Data("arimendelow\n".utf8))
            default:
                return .init(exitCode: 3)
            }
        }

        XCTAssertEqual(try fixture.adapter().reactivate(fixture.runtime()), .degraded("prior generation reactivation failed; possible child ownership remains"))
    }

    func testReactivateValidatesEveryPersistedRuntimeAndInventoryBoundary() throws {
        let fixture = try AdapterFixture()
        let runtime = fixture.runtime()
        let invalidRuntimes: [RemoteActiveRuntime] = [
            .init(schemaVersion: 2, generation: runtime.generation, sessionName: runtime.sessionName, socketPath: runtime.socketPath, expectedInventoryPath: runtime.expectedInventoryPath),
            .init(schemaVersion: 1, generation: "ouro-other", sessionName: runtime.sessionName, socketPath: runtime.socketPath, expectedInventoryPath: runtime.expectedInventoryPath),
            .init(schemaVersion: 1, generation: "bad", sessionName: "bad", socketPath: runtime.socketPath, expectedInventoryPath: runtime.expectedInventoryPath),
            .init(schemaVersion: 1, generation: runtime.generation, sessionName: runtime.sessionName, socketPath: "/wrong", expectedInventoryPath: runtime.expectedInventoryPath),
            .init(schemaVersion: 1, generation: runtime.generation, sessionName: runtime.sessionName, socketPath: runtime.socketPath, expectedInventoryPath: "/wrong")
        ]
        for invalid in invalidRuntimes {
            XCTAssertEqual(try fixture.adapter().reactivate(invalid), .degraded("prior generation reactivation failed"))
        }

        let invalidInventories: [Data] = [
            try JSONSerialization.data(withJSONObject: []),
            Data("{".utf8),
            try remoteJSONData(["version": 1, "generation": "ouro-a", "acknowledged_empty": true, "panes": [], "extra": true]),
            try remoteJSONData(["version": "one", "generation": "ouro-a", "acknowledged_empty": true, "panes": []]),
            try remoteJSONData(["version": 2, "generation": "ouro-a", "acknowledged_empty": true, "panes": []]),
            try remoteJSONData(["version": 1, "generation": "ouro-a", "acknowledged_empty": false, "panes": [["pane_id": "/bad", "native_session_id": fixture.nativeSessionID, "profile_id": "personal"]]])
        ]
        for data in invalidInventories {
            let invalid = try AdapterFixture()
            invalid.expectedInventoryData = data
            XCTAssertEqual(try invalid.adapter().reactivate(invalid.runtime()), .degraded("prior generation reactivation failed"))
            XCTAssertTrue(invalid.spawnedRequests.isEmpty)
        }
    }

    func testReactivationInventoryDecisionTableRejectsEveryImpossibleIntermediateShape() throws {
        let fixture = try AdapterFixture()
        let adapter = try fixture.adapter()
        let expected = RemoteRelayExpectedInventory(generation: "ouro-a", acknowledgedEmpty: false, panes: [.init(paneID: "desk:p1", nativeSessionID: fixture.nativeSessionID, profileID: "personal")])
        let waiting = RemotePaneInventory(workspaceID: "desk", paneID: "desk:p1", nativeSessionID: fixture.nativeSessionID, profileID: nil, githubLogin: nil, generation: "ouro-a", childPresent: false, hookObserved: false, wrapperReady: true, foregroundProcess: nil)
        XCTAssertTrue(adapter.reactivationInventory(.init(version: "0.8.2", panes: [waiting]), matches: expected, generation: "ouro-a", completedCount: 0))
        XCTAssertFalse(adapter.reactivationInventory(.init(version: "0.8.1", panes: [waiting]), matches: expected, generation: "ouro-a", completedCount: 0))
        XCTAssertFalse(adapter.reactivationInventory(.init(version: "0.8.2", panes: [waiting]), matches: expected, generation: "ouro-a", completedCount: -1))
        XCTAssertFalse(adapter.reactivationInventory(.init(version: "0.8.2", panes: []), matches: expected, generation: "ouro-a", completedCount: 0))
        var wrongPane = waiting
        wrongPane.paneID = "desk:other"
        XCTAssertFalse(adapter.reactivationInventory(.init(version: "0.8.2", panes: [wrongPane]), matches: expected, generation: "ouro-a", completedCount: 0))
        var missingProcess = waiting
        missingProcess.profileID = "personal"
        missingProcess.githubLogin = "arimendelow"
        missingProcess.childPresent = true
        missingProcess.hookObserved = true
        XCTAssertFalse(adapter.reactivationInventory(.init(version: "0.8.2", panes: [missingProcess]), matches: expected, generation: "ouro-a", completedCount: 1))
    }

    func testDefaultShellReadinessFailsClosedWhenProfilesUseDifferentZshExecutables() throws {
        let fixture = try AdapterFixture()
        try fixture.installVerifiedPane()
        var object = remoteRegistryObject()
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[1]["zshExecutable"] = "/bin/bash"
        object["profiles"] = profiles
        fixture.registry = try RemoteProfileRegistry.decode(try remoteJSONData(object), executableExists: { _ in true }, credentialStoreResolver: remoteFixtureCredentialStore)
        fixture.useDefaultShellReadiness = true
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane()])),
            .init(exitCode: 0, stdout: try fixture.processInfo()),
            .init(exitCode: 0, stdout: Data("arimendelow\n".utf8))
        ]

        XCTAssertEqual(try fixture.adapter().inventory(sessionName: "ouro-a").panes.first?.wrapperReady, false)
    }

    func testInventoryRejectsSnapshotAndProcessInfoFailures() throws {
        let fixture = try AdapterFixture()
        fixture.responses = [.init(exitCode: 1)]
        assertRemoteErrorContains("snapshot request failed") { _ = try fixture.adapter().inventory(sessionName: "ouro-a") }
        fixture.responses = [.init(exitCode: 0, stdout: Data("{".utf8))]
        assertRemoteErrorContains("snapshot response is invalid") { _ = try fixture.adapter().inventory(sessionName: "ouro-a") }
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane(agent: nil)])),
            .init(exitCode: 1)
        ]
        assertRemoteErrorContains("process inspection failed") { _ = try fixture.adapter().inventory(sessionName: "ouro-a") }
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane(agent: nil)])),
            .init(exitCode: 0, stdout: Data("[]".utf8))
        ]
        assertRemoteErrorContains("process response is invalid") { _ = try fixture.adapter().inventory(sessionName: "ouro-a") }
    }

    func testInventoryTreatsUntrustedMappingsRecordsAndAgentMetadataAsAbsent() throws {
        let fixture = try AdapterFixture()
        fixture.mappingFileData = Data("bad".utf8)
        fixture.directoryError = RemoteFixtureError.expected
        fixture.identities[77] = remoteProcessIdentity(pid: 77, startIdentity: "birth-77", executable: "/bin/zsh", generation: "ouro-a")
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [
                fixture.snapshotPane(agent: nil),
                fixture.snapshotPane(paneID: "desk:p2", agent: ["agent": "claude", "value": fixture.nativeSessionID]),
                fixture.snapshotPane(paneID: "desk:p3", agent: ["agent": "copilot", "value": "bad"])
            ])),
            .init(exitCode: 0, stdout: try fixture.processInfo(shellPID: 77)),
            .init(exitCode: 0, stdout: try fixture.processInfo()),
            .init(exitCode: 0, stdout: try fixture.processInfo())
        ]
        let inventory = try fixture.adapter().inventory(sessionName: "ouro-a")
        XCTAssertEqual(inventory.panes.map(\.nativeSessionID), [nil, nil, nil])
        XCTAssertTrue(inventory.panes.allSatisfy { $0.profileID == nil && !$0.childPresent && !$0.hookObserved })
        XCTAssertTrue(inventory.panes[0].wrapperReady)
    }

    func testInventoryRequiresExactMappingLedgerProcessArgumentsAndGitHubLogin() throws {
        let fixture = try AdapterFixture()
        try fixture.installVerifiedPane()
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane()])),
            .init(exitCode: 0, stdout: try fixture.processInfo()),
            .init(exitCode: 0, stdout: Data("arimendelow\n".utf8))
        ]
        let inventory = try fixture.adapter().inventory(sessionName: "ouro-a")
        XCTAssertEqual(inventory.panes, [fixture.expectedPane()])
        let loginCall = fixture.calls.last!
        XCTAssertEqual(loginCall.request.executable, "/fixtures/bin/gh")
        XCTAssertEqual(loginCall.request.arguments, ["api", "/user", "--jq", ".login"])
        XCTAssertEqual(loginCall.request.environment["GH_CONFIG_DIR"], "/tmp/ouro/gh/personal")
        XCTAssertEqual(loginCall.request.workingDirectory, "/tmp/desk")

        for result in [RemoteProcessResult(exitCode: 1), .init(exitCode: 0, stdout: Data()), .init(exitCode: 0, stdout: Data("wrong\n".utf8))] {
            let denied = try AdapterFixture()
            try denied.installVerifiedPane()
            denied.responses = [
                .init(exitCode: 0, stdout: try denied.snapshot(panes: [denied.snapshotPane()])),
                .init(exitCode: 0, stdout: try denied.processInfo()),
                result
            ]
            let pane = try denied.adapter().inventory(sessionName: "ouro-a").panes[0]
            XCTAssertFalse(pane.childPresent)
            XCTAssertNil(pane.githubLogin)
            XCTAssertEqual(pane.profileID, "personal")
        }

        let transport = try AdapterFixture()
        try transport.installVerifiedPane()
        transport.runHandler = { request, _ in
            if request.executable == "/fixtures/bin/gh" { throw RemoteFixtureError.expected }
            if request.arguments.contains("snapshot") { return .init(exitCode: 0, stdout: try transport.snapshot(panes: [transport.snapshotPane()])) }
            return .init(exitCode: 0, stdout: try transport.processInfo())
        }
        XCTAssertFalse(try transport.adapter().inventory(sessionName: "ouro-a").panes[0].childPresent)
    }

    func testInventoryIgnoresNonJSONMissingAndExitedLedgerRecords() throws {
        let fixture = try AdapterFixture()
        try fixture.installMapping()
        fixture.directoryURLs = [fixture.ledger.rootURL.appendingPathComponent("attempts/note.txt"), fixture.ledger.rootURL.appendingPathComponent("attempts/missing.json")]
        fixture.responses = [
            .init(exitCode: 0, stdout: try fixture.snapshot(panes: [fixture.snapshotPane()])),
            .init(exitCode: 0, stdout: try fixture.processInfo())
        ]
        XCTAssertFalse(try fixture.adapter().inventory(sessionName: "ouro-a").panes[0].hookObserved)

        let exited = try AdapterFixture()
        try exited.installVerifiedPane(markExited: true)
        exited.responses = [
            .init(exitCode: 0, stdout: try exited.snapshot(panes: [exited.snapshotPane()])),
            .init(exitCode: 0, stdout: try exited.processInfo())
        ]
        XCTAssertFalse(try exited.adapter().inventory(sessionName: "ouro-a").panes[0].hookObserved)

        let missingForeground = try AdapterFixture()
        try missingForeground.installVerifiedPane()
        missingForeground.responses = [
            .init(exitCode: 0, stdout: try missingForeground.snapshot(panes: [missingForeground.snapshotPane()])),
            .init(exitCode: 0, stdout: try remoteJSONData(["result": ["process_info": ["foreground_processes": []]]]))
        ]
        let pane = try missingForeground.adapter().inventory(sessionName: "ouro-a").panes[0]
        XCTAssertTrue(pane.hookObserved)
        XCTAssertEqual(pane.profileID, "personal")
        XCTAssertFalse(pane.childPresent)
        XCTAssertFalse(pane.wrapperReady)
    }

    func testDefaultAdapterDependenciesExecuteAgainstARealPinnedFixture() throws {
        let fixture = try AdapterFixture()
        let executable = fixture.root.appendingPathComponent("herdr-fixture.sh")
        let countFile = fixture.root.appendingPathComponent("list-count")
        let serverPIDFile = fixture.root.appendingPathComponent("server.pid")
        let source = """
        #!/bin/sh
        case "$*" in
          "config check") exit 0 ;;
          "--session ouro-a server") printf '%s' "$$" > '\(serverPIDFile.path)'; sleep 5; exit 0 ;;
          "session list --json")
            count=$(cat '\(countFile.path)' 2>/dev/null || printf 0)
            count=$((count + 1))
            printf '%s' "$count" > '\(countFile.path)'
            if [ "$count" -eq 1 ]; then printf '{"sessions":[]}'; else printf '{"sessions":[{"name":"ouro-a","running":true}]}'; fi
            ;;
          "--session ouro-a api snapshot") printf '{"result":{"snapshot":{"version":"0.8.2","panes":[{"pane_id":"desk:p1","workspace_id":"desk"}]}}}' ;;
          "--session ouro-a pane process-info --pane desk:p1") printf '{"result":{"process_info":{"shell_pid":\(getpid()),"foreground_processes":[]}}}' ;;
          *) exit 3 ;;
        esac
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = fixture.root.appendingPathComponent("config.toml")
        try Data("[session]\nresume_agents_on_restore = false\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let attempts = fixture.ledger.rootURL.appendingPathComponent("attempts", isDirectory: true)
        try FileManager.default.createDirectory(at: attempts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.ledger.rootURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: attempts.path)
        let adapter = RemoteHerdrAdapter(
            rootURL: fixture.root,
            registry: try remoteRegistry(),
            ledger: fixture.ledger,
            sessionMapURL: fixture.root.deletingLastPathComponent().appendingPathComponent("missing-map.json"),
            herdrExecutable: executable.path,
            configPath: "/runtime/profiles.json",
            helperPath: "/runtime/helper",
            shimDirectory: "/runtime/shims",
            zdotdir: "/runtime/zdotdir",
            inheritedEnvironment: ["HOME": "/Users/example", "PATH": "/usr/bin:/bin"],
            shellReadiness: { _, _, _ in true }
        )

        XCTAssertEqual(try adapter.listHerdrProcessSessions(), [])
        let inventory = try adapter.boot(fixture.bootRequest())
        XCTAssertEqual(inventory.panes.first?.wrapperReady, true)
        let serverPIDDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: serverPIDFile.path), Date() < serverPIDDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: serverPIDFile.path))
        let serverPID = Int32((try String(contentsOf: serverPIDFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(kill(serverPID, 0), 0, "successful boot must preserve the owned server")
        XCTAssertEqual(killpg(serverPID, SIGKILL), 0)
    }

    func testDefaultAdapterShellReadinessUsesTheDurableExactMarker() throws {
        let root = try remoteTemporaryDirectory("adapter-default-ready")
        defer { try? FileManager.default.removeItem(at: root) }
        let herdrRoot = root.appendingPathComponent("herdr", isDirectory: true)
        try FileManager.default.createDirectory(at: herdrRoot, withIntermediateDirectories: false)
        let mapURL = root.appendingPathComponent("session-map.json")
        let shellPID = Int32(88)
        let zsh = URL(fileURLWithPath: "/bin/zsh").resolvingSymlinksInPath().standardizedFileURL.path
        let identity = remoteProcessIdentity(pid: shellPID, executable: zsh, generation: "ouro-a")
        let body = RemoteShellReadiness.copilotFunctionBody(helperPath: "/runtime/helper", configPath: "/runtime/profiles.json", sessionMapPath: mapURL.path)
        try RemoteShellReadiness.record(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: shellPID, zshExecutable: "/bin/zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/profiles.json", functionBody: body, environment: ["HERDR_SESSION": "ouro-a", "HERDR_PANE_ID": "desk:p1", "ZDOTDIR": "/runtime/zdotdir"], parentPID: shellPID, processIdentityForPID: { _, _ in identity })
        var responses = [
            RemoteProcessResult(exitCode: 0, stdout: try remoteJSONData(["result": ["snapshot": ["version": "0.8.2", "panes": [["pane_id": "desk:p1", "workspace_id": "desk"]]]]])),
            RemoteProcessResult(exitCode: 0, stdout: try remoteJSONData(["result": ["process_info": ["shell_pid": shellPID, "foreground_processes": []]]]))
        ]
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil })
        let adapter = RemoteHerdrAdapter(rootURL: herdrRoot, registry: try remoteRegistry(), ledger: ledger, sessionMapURL: mapURL, herdrExecutable: "/fixtures/bin/herdr", configPath: "/runtime/profiles.json", helperPath: "/runtime/helper", shimDirectory: "/runtime/shims", zdotdir: "/runtime/zdotdir", inheritedEnvironment: [:], run: { _, _ in responses.removeFirst() }, listHerdrProcessSessions: { [] }, processIdentityForPID: { _, _ in identity })
        XCTAssertTrue(try adapter.inventory(sessionName: "ouro-a").panes[0].wrapperReady)
    }

    func testProductionAdapterTreatsHerdrNonexistentStopAsAbsentOnlyAfterIndependentProof() throws {
        let fixture = try AdapterFixture()
        let executable = fixture.root.appendingPathComponent("herdr-missing-fixture.sh")
        let source = """
        #!/bin/sh
        case "$*" in
          "session stop ouro-missing --json") exit 1 ;;
          "session list --json") printf '{"sessions":[]}' ;;
          *) exit 3 ;;
        esac
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let adapter = RemoteHerdrAdapter(
            rootURL: fixture.root,
            registry: try remoteRegistry(),
            ledger: fixture.ledger,
            sessionMapURL: fixture.root.deletingLastPathComponent().appendingPathComponent("missing-map.json"),
            herdrExecutable: executable.path,
            configPath: "/runtime/profiles.json",
            helperPath: "/runtime/helper",
            shimDirectory: "/runtime/shims",
            zdotdir: "/runtime/zdotdir",
            inheritedEnvironment: ["HOME": "/Users/example", "PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(try adapter.stop(sessionName: "ouro-missing"), .absent)
    }

    func testServerHandleDelegatesAndRealSpawnHonorsEnvironmentAndWorkingDirectory() throws {
        var running = true
        var cleanupTimeout: TimeInterval?
        let handle = RemoteHerdrServerHandle(running: { running }, terminateAndWait: { timeout in cleanupTimeout = timeout; running = false; return true })
        XCTAssertTrue(handle.isRunning)
        XCTAssertTrue(handle.terminateAndWait(timeout: 0.25))
        XCTAssertFalse(handle.isRunning)
        XCTAssertEqual(cleanupTimeout, 0.25)

        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("spawn.txt")
        let process = try RemoteHerdrServerHandle.spawn(.init(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s:%s' \"$TOKEN\" \"$PWD\" > \"$1\"", "sh", output.path],
            environment: ["TOKEN": "value"],
            workingDirectory: root.path
        ))
        XCTAssertTrue(process.wait(timeout: 1))
        XCTAssertTrue(process.terminateAndWait(timeout: 0.25))
        let physicalRoot = root.path.hasPrefix("/var/") ? "/private\(root.path)" : root.path
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "value:\(physicalRoot)")
        XCTAssertThrowsError(try RemoteHerdrServerHandle.spawn(.init(executable: root.appendingPathComponent("missing").path)))

        let sleeper = try RemoteHerdrServerHandle.spawn(.init(executable: "/bin/sleep", arguments: ["5"]))
        XCTAssertTrue(sleeper.isRunning)
        XCTAssertTrue(sleeper.terminateAndWait(timeout: 0.25))
        XCTAssertFalse(sleeper.isRunning)

        let ready = root.appendingPathComponent("ignoring-ready")
        let ignoring = try RemoteHerdrServerHandle.spawn(.init(executable: "/usr/bin/python3", arguments: ["-c", "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(sys.argv[1], 'w').close(); time.sleep(5)", ready.path]))
        let readyDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let cleanupStarted = Date()
        XCTAssertTrue(ignoring.terminateAndWait(timeout: 0.25))
        XCTAssertLessThan(Date().timeIntervalSince(cleanupStarted), 1)
        XCTAssertFalse(ignoring.isRunning)
    }

    private func assertPostIntent(_ detail: String, operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case let RemotePaneResumeFailure.postIntent(message) = error else {
                return XCTFail("expected post-intent, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(detail), message, file: file, line: line)
        }
    }

    private func replace(_ values: [String], at index: Int, with value: String) -> [String] {
        var copy = values
        copy[index] = value
        return copy
    }
}

private final class AdapterFixture {
    struct Call {
        var request: RemoteProcessRequest
        var timeout: TimeInterval
    }

    let root: URL
    let ledger: RemoteResumeLedger
    let nativeSessionID = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
    var calls: [Call] = []
    var responses: [RemoteProcessResult] = []
    var error: Error?
    var runHandler: ((RemoteProcessRequest, TimeInterval) throws -> RemoteProcessResult)?
    var serverSessions: [String] = []
    var scannerError: Error?
    var identities: [Int32: RemoteProcessIdentity] = [:]
    var existingPaths = Set<String>()
    var privateFileData = Data("[session]\nresume_agents_on_restore = false\n".utf8)
    var expectedInventoryData = try! remoteJSONData(["version": 1, "generation": "ouro-a", "acknowledged_empty": true, "panes": []])
    var privateFileError: Error?
    var mappingFileData: Data?
    var directoryURLs: [URL]?
    var directoryError: Error?
    var spawnError: Error?
    var spawnedRequests: [RemoteProcessRequest] = []
    var serverRunning = true
    var cleanupSucceeds = true
    var terminateCount = 0
    var waitCount = 0
    var currentTime = Date(timeIntervalSince1970: 1_000)
    var advancePerSleep: TimeInterval = 0
    var sleepDurations: [TimeInterval] = []
    var registry: RemoteProfileRegistry?
    var useDefaultShellReadiness = false

    init() throws {
        root = try remoteTemporaryDirectory().appendingPathComponent("herdr", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        ledger = RemoteResumeLedger(rootURL: root.deletingLastPathComponent().appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil })
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func adapter() throws -> RemoteHerdrAdapter {
        if let mappingFileData {
            try mappingFileData.write(to: root.deletingLastPathComponent().appendingPathComponent("session-map.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.deletingLastPathComponent().appendingPathComponent("session-map.json").path)
        }
        let injectedShellReadiness: ((Int32, String, String) -> Bool)? = useDefaultShellReadiness ? nil : { [unowned self] pid, generation, _ in
            identities[pid]?.generation == generation && identities[pid]?.executable == "/bin/zsh"
        }
        return RemoteHerdrAdapter(
            rootURL: root,
            registry: try registry ?? remoteRegistry(),
            ledger: ledger,
            sessionMapURL: root.deletingLastPathComponent().appendingPathComponent("session-map.json"),
            herdrExecutable: "/fixtures/bin/herdr",
            configPath: "/runtime/profiles.json",
            helperPath: "/runtime/helper",
            shimDirectory: "/runtime/shims",
            zdotdir: "/runtime/zdotdir",
            inheritedEnvironment: ["HOME": "/Users/example", "LC_ALL": "C", "SECRET": "drop"],
            run: { [unowned self] request, timeout in
                calls.append(.init(request: request, timeout: timeout))
                if let runHandler { return try runHandler(request, timeout) }
                if let error { throw error }
                return responses.isEmpty ? .init(exitCode: 0) : responses.removeFirst()
            },
            listHerdrProcessSessions: { [unowned self] in
                if let scannerError { throw scannerError }
                return serverSessions
            },
            processIdentityForPID: { [unowned self] pid, _ in identities[pid] },
            shellReadiness: injectedShellReadiness,
            fileExists: { [unowned self] path in existingPaths.contains(path) || FileManager.default.fileExists(atPath: path) },
            readPrivateFile: { [unowned self] path, _ in
                if let privateFileError { throw privateFileError }
                return path == runtime().expectedInventoryPath ? expectedInventoryData : privateFileData
            },
            contentsOfDirectory: { [unowned self] url in
                if let directoryError { throw directoryError }
                if let directoryURLs { return directoryURLs }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            },
            spawnServer: { [unowned self] request in
                spawnedRequests.append(request)
                if let spawnError { throw spawnError }
                return RemoteHerdrServerHandle(running: { [unowned self] in serverRunning }, terminateAndWait: { [unowned self] _ in terminateCount += 1; waitCount += 1; serverRunning = false; return cleanupSucceeds })
            },
            now: { [unowned self] in currentTime },
            sleep: { [unowned self] duration in
                sleepDurations.append(duration)
                currentTime = currentTime.addingTimeInterval(advancePerSleep)
            }
        )
    }

    func resumeCommand() -> RemotePaneResumeCommand {
        RemotePaneResumeCommand(
            paneID: "desk:p1",
            helperPath: "/runtime/helper",
            arguments: [
                "resume", "--uuid", nativeSessionID,
                "--profile", "personal", "--generation", "ouro-a", "--pane", "desk:p1"
            ]
        )
    }

    func bootRequest() -> RemoteHerdrBootRequest {
        .init(sessionName: "ouro-a", stagedSessionURL: root.appendingPathComponent("sessions/ouro-a", isDirectory: true), expectedVersion: "0.8.2", resumeAgentsOnRestore: false)
    }

    func runtime() -> RemoteActiveRuntime {
        .init(schemaVersion: 1, generation: "ouro-a", sessionName: "ouro-a", socketPath: root.appendingPathComponent("sessions/ouro-a/herdr.sock").path, expectedInventoryPath: root.appendingPathComponent("sessions/ouro-a/expected-inventory.json").path)
    }

    func snapshot(panes: [[String: Any]] = []) throws -> Data {
        try remoteJSONData(["result": ["snapshot": ["version": "0.8.2", "panes": panes]]])
    }

    func snapshotPane(paneID: String = "desk:p1", agent: [String: Any]? = ["agent": "copilot", "value": "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"]) -> [String: Any] {
        var pane: [String: Any] = ["pane_id": paneID, "workspace_id": "desk"]
        if let agent { pane["agent_session"] = agent }
        return pane
    }

    func processInfo(shellPID: Int32? = 88, foregroundPID: Int32 = 200, argv: [String]? = nil) throws -> Data {
        let profile = try remoteRegistry().profile(id: "personal")
        var foreground: [String: Any] = ["pid": foregroundPID]
        foreground["argv"] = argv ?? [profile.copilotExecutable] + RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(nativeSessionID)"])
        var process: [String: Any] = ["foreground_processes": [foreground]]
        if let shellPID { process["shell_pid"] = shellPID }
        return try remoteJSONData(["result": ["process_info": process]])
    }

    func installMapping() throws {
        mappingFileData = try remoteJSONData(["schemaVersion": 1, "entries": [["sessionID": nativeSessionID, "profileID": "personal", "paneID": "desk:p1", "generation": "ouro-a"]]])
    }

    func installVerifiedPane(markExited: Bool = false) throws {
        try installMapping()
        try installLedgerOnly(markExited: markExited)
    }

    func installLedgerOnly(markExited: Bool = false) throws {
        let profile = try remoteRegistry().profile(id: "personal")
        let expectedArguments = RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(nativeSessionID)"])
        let identity = remoteProcessIdentity(pid: 200, startIdentity: "birth-200", executable: "/fixtures/bin/copilot", generation: "ouro-a")
        identities[200] = identity
        identities[88] = remoteProcessIdentity(pid: 88, executable: "/bin/zsh", generation: "ouro-a")
        try ledger.prepare(attemptID: "attempt-a", nativeSessionID: nativeSessionID, profileID: "personal", generation: "ouro-a", paneID: "desk:p1", ownerPID: getpid(), expectedArgvSHA256: RemoteArgvDigest.sha256([profile.copilotExecutable] + expectedArguments))
        try ledger.markSpawnIntent(attemptID: "attempt-a")
        try ledger.recordChild(attemptID: "attempt-a", identity: identity)
        try ledger.confirm(nativeSessionID: nativeSessionID, profileID: "personal", generation: "ouro-a", paneID: "desk:p1")
        if markExited { try ledger.markExited(attemptID: "attempt-a", status: 0) }
    }

    func expectedPane() -> RemotePaneInventory {
        .init(workspaceID: "desk", paneID: "desk:p1", nativeSessionID: nativeSessionID, profileID: "personal", githubLogin: "arimendelow", generation: "ouro-a", childPresent: true, hookObserved: true, wrapperReady: true, foregroundProcess: identities[200])
    }
}
