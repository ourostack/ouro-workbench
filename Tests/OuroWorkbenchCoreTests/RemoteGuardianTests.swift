import Darwin
import Foundation
import XCTest
@testable import OuroWorkbenchCore

@_silgen_name("flock")
private func guardianTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class RemoteGuardianTests: XCTestCase {
    func testGuardianPromotesAndRevalidatesAnExplicitAcknowledgedEmptyGeneration() throws {
        let fixture = try GuardianFixture(acknowledgedEmpty: true)
        defer { fixture.remove() }
        var resumeCount = 0
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { request in
                XCTAssertFalse(request.resumeAgentsOnRestore)
                return fixture.structuralInventory
            },
            resume: { _ in resumeCount += 1; return fixture.structuralInventory },
            stop: { _ in XCTFail("an empty successful generation must not stop"); return .absent }
        )

        XCTAssertEqual(try guardian.tick(), .promoted("stage-1"))
        XCTAssertEqual(resumeCount, 0)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stagedSessionURL.appendingPathComponent("expected-inventory.json"))) as? [String: Any])
        XCTAssertEqual(Set(document.keys), Set(["version", "generation", "acknowledged_empty", "panes"]))
        XCTAssertEqual(document["acknowledged_empty"] as? Bool, true)
        XCTAssertEqual((document["panes"] as? [Any])?.count, 0)

        let restarted = fixture.guardian(
            probe: { _ in .running(fixture.finalInventory(generation: "stage-1")) },
            boot: { _ in XCTFail("an exact empty generation must not boot again"); return fixture.structuralInventory },
            resume: { _ in XCTFail("an exact empty generation must not resume"); return fixture.structuralInventory },
            stop: { _ in XCTFail("an exact empty generation must not stop"); return .absent }
        )
        XCTAssertEqual(try restarted.tick(), .alreadyRunning("stage-1"))
    }

    func testGuardianPerformsOneStructuralBootThenSequentialExactResumesAndPromotes() throws {
        let fixture = try GuardianFixture()
        defer { fixture.remove() }
        let nested = fixture.sourceSnapshotURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fixture.writePrivateData(Data("nested-state".utf8), to: nested.appendingPathComponent("state.json"))
        var bootRequests: [RemoteHerdrBootRequest] = []
        var resumeCommands: [RemotePaneResumeCommand] = []
        var livePanes = fixture.structuralInventory.panes
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { request in
                bootRequests.append(request)
                let copied = request.stagedSessionURL.appendingPathComponent("session.json")
                XCTAssertEqual(self.mode(at: request.stagedSessionURL), 0o700)
                XCTAssertEqual(self.mode(at: copied), 0o600)
                XCTAssertNotEqual(self.inode(at: copied), self.inode(at: fixture.sourceSessionJSONURL))
                return fixture.structuralInventory
            },
            resume: { command in
                resumeCommands.append(command)
                let expected = fixture.manifest.expectedPanes[resumeCommands.count - 1]
                let index = try XCTUnwrap(livePanes.firstIndex(where: { $0.paneID == expected.paneID }))
                livePanes[index] = fixture.resumedInventory(for: expected)
                return RemoteHerdrInventory(version: "0.8.2", panes: livePanes)
            },
            stop: { _ in XCTFail("successful generation must not stop"); return .absent }
        )

        XCTAssertEqual(try guardian.tick(), .promoted("stage-1"))
        XCTAssertEqual(bootRequests.count, 1)
        XCTAssertEqual(bootRequests[0].expectedPaneCount, fixture.manifest.expectedPanes.count)
        XCTAssertFalse(bootRequests[0].resumeAgentsOnRestore)
        XCTAssertEqual(resumeCommands.map(\.paneID), ["desk:p1", "desk:p2"])
        XCTAssertEqual(resumeCommands.map(\.arguments), fixture.manifest.expectedPanes.map {
            ["resume", "--uuid", $0.nativeSessionID, "--profile", $0.profileID, "--generation", "stage-1", "--pane", $0.paneID]
        })
        XCTAssertTrue(resumeCommands.allSatisfy { $0.helperPath == "/opt/ouro/runtime/OuroWorkbenchRemote" })
        XCTAssertTrue(resumeCommands.allSatisfy {
            !$0.shellCommand.contains("command copilot")
                && !$0.shellCommand.contains("/fixtures/bin/copilot")
                && !$0.shellCommand.contains("exec ")
                && !$0.shellCommand.contains("sh -c")
                && $0.shellCommand.hasPrefix("'/opt/ouro/runtime/OuroWorkbenchRemote' 'resume' '--uuid'")
        })
        let active = try fixture.readActive()
        XCTAssertEqual(active.generation, "stage-1")
        XCTAssertEqual(active.sessionName, "stage-1")
        XCTAssertEqual(active.socketPath, fixture.stagedSessionURL.appendingPathComponent("herdr.sock").path)
        XCTAssertEqual(active.expectedInventoryPath, fixture.stagedSessionURL.appendingPathComponent("expected-inventory.json").path)
        XCTAssertEqual(self.mode(at: fixture.activeRuntimeURL), 0o600)
        let relayInventoryURL = fixture.stagedSessionURL.appendingPathComponent("expected-inventory.json")
        let relayInventory = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: relayInventoryURL)) as? [String: Any])
        XCTAssertEqual(Set(relayInventory.keys), Set(["version", "generation", "acknowledged_empty", "panes"]))
        XCTAssertEqual(relayInventory["acknowledged_empty"] as? Bool, false)
        XCTAssertEqual(relayInventory["version"] as? Int, 1)
        XCTAssertEqual(relayInventory["generation"] as? String, "stage-1")
        let relayPanes = try XCTUnwrap(relayInventory["panes"] as? [[String: Any]])
        XCTAssertEqual(relayPanes.count, 2)
        XCTAssertEqual(Set(relayPanes[0].keys), Set(["pane_id", "native_session_id", "profile_id"]))
        XCTAssertEqual(Set(relayPanes.compactMap { $0["pane_id"] as? String }), Set(["desk:p1", "desk:p2"]))
        XCTAssertEqual(self.mode(at: relayInventoryURL), 0o600)
        XCTAssertEqual(try Data(contentsOf: fixture.oldSnapshotURL), fixture.oldSnapshotBytes)

        let restartedGuardian = fixture.guardian(
            probe: { name in
                XCTAssertEqual(name, "stage-1")
                return .running(fixture.finalInventory(generation: "stage-1"))
            },
            boot: { _ in XCTFail("a promoted generation must survive the next guardian tick"); return fixture.structuralInventory },
            resume: { _ in XCTFail("a promoted generation must not resume again"); return fixture.structuralInventory },
            stop: { _ in XCTFail("a promoted generation must not stop"); return .absent }
        )
        XCTAssertEqual(try restartedGuardian.tick(), .alreadyRunning("stage-1"))
    }

    func testGuardianWaitsForTheSharedActiveRuntimeLeaseBeforeInspectingOrPromoting() throws {
        let fixture = try GuardianFixture()
        defer { fixture.remove() }
        let leaseURL = fixture.root.appendingPathComponent("active-runtime.lock")
        let descriptor = Darwin.open(leaseURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        XCTAssertEqual(guardianTestFlock(descriptor, LOCK_SH), 0)
        defer { _ = guardianTestFlock(descriptor, LOCK_UN) }

        let reachedBoot = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = GuardianThreadResult()
        var livePanes = fixture.structuralInventory.panes
        var resumed = 0
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { _ in reachedBoot.signal(); return fixture.structuralInventory },
            resume: { _ in
                let expected = fixture.manifest.expectedPanes[resumed]
                let index = try XCTUnwrap(livePanes.firstIndex(where: { $0.paneID == expected.paneID }))
                livePanes[index] = fixture.resumedInventory(for: expected)
                resumed += 1
                return RemoteHerdrInventory(version: "0.8.2", panes: livePanes)
            },
            stop: { _ in .absent }
        )
        GuardianThreadRun(guardian: guardian, result: result, finished: finished).start()
        usleep(50_000)
        XCTAssertNil(result.get())
        XCTAssertEqual(reachedBoot.wait(timeout: .now()), .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.activeRuntimeURL.path))

        XCTAssertEqual(guardianTestFlock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(reachedBoot.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try result.get()?.get(), .promoted("stage-1"))
    }

    func testGuardianRefusesRecoveryWhileARelayTopologyTransactionIsUnresolved() throws {
        let fixture = try GuardianFixture()
        defer { fixture.remove() }
        try fixture.writePrivateData(
            Data(#"{"schema_version":1,"generation":"old","request_id":"request","action":"agent_start","panes":[]}"#.utf8),
            to: fixture.root.appendingPathComponent("topology-transaction.json")
        )
        var probed = false
        let guardian = fixture.guardian(
            probe: { _ in probed = true; return .absent },
            boot: { _ in XCTFail("an unresolved topology transaction must block recovery"); return fixture.structuralInventory },
            resume: { _ in fixture.structuralInventory },
            stop: { _ in .absent }
        )
        assertRemoteErrorContains("topology transaction") { _ = try guardian.tick() }
        XCTAssertFalse(probed)
    }

    func testGuardianFailsClosedWhenTheRuntimeLeaseOrTopologyTransactionEvidenceIsUnreadable() throws {
        do {
            let fixture = try GuardianFixture(stageName: "blocked-lease")
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("active-runtime.lock"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let guardian = fixture.guardian(
                probe: { _ in XCTFail("an unsafe runtime lease must block recovery"); return .absent },
                boot: { _ in fixture.structuralInventory },
                resume: { _ in fixture.structuralInventory },
                stop: { _ in .absent }
            )
            assertRemoteErrorContains("active runtime lease is unavailable") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "unreadable-topology")
            defer { fixture.remove() }
            let guardian = fixture.guardian(
                probe: { _ in XCTFail("unreadable topology evidence must block recovery"); return .absent },
                boot: { _ in fixture.structuralInventory },
                resume: { _ in fixture.structuralInventory },
                stop: { _ in .absent },
                snapshotLstat: { _, _ in errno = EACCES; return -1 }
            )
            assertRemoteErrorContains("topology transaction state is unreadable") { _ = try guardian.tick() }
        }
    }

    func testGuardianUsesTheOneDigestBoundSelectionReadBeforeAPointerRace() throws {
        let fixture = try GuardianFixture(stageName: "stage-selected")
        defer { fixture.remove() }
        _ = try fixture.capture(id: "capture-a", generation: "source-a", bytes: Data("selected-a".utf8))
        _ = try fixture.capture(id: "capture-b", generation: "source-b", bytes: Data("selected-b".utf8))
        try fixture.selectCapture("capture-a")
        var livePanes = fixture.structuralInventory.panes
        var resumed = 0
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { request in
                XCTAssertEqual(try Data(contentsOf: request.stagedSessionURL.appendingPathComponent("session.json")), Data("selected-a".utf8))
                return fixture.structuralInventory
            },
            resume: { _ in
                let expected = fixture.manifest.expectedPanes[resumed]
                let index = try XCTUnwrap(livePanes.firstIndex(where: { $0.paneID == expected.paneID }))
                livePanes[index] = fixture.resumedInventory(for: expected)
                resumed += 1
                return RemoteHerdrInventory(version: "0.8.2", panes: livePanes)
            },
            stop: { _ in .absent },
            listManagedSessions: {
                try fixture.selectCapture("capture-b")
                return []
            }
        )

        XCTAssertEqual(try guardian.tick(), .promoted("stage-selected"))
        XCTAssertEqual(try String(contentsOf: fixture.lastKnownGoodCurrentURL, encoding: .utf8), "capture-b\n")
    }

    func testGuardianRejectsASnapshotChangedAfterSelectionBeforeAnyBoot() throws {
        let fixture = try GuardianFixture(stageName: "stage-raced")
        defer { fixture.remove() }
        _ = try fixture.capture(id: "capture-race", generation: "source-race", bytes: Data("selected-before-race".utf8))
        let selectedSession = fixture.capturedSessionURL("capture-race").appendingPathComponent("session.json")
        var booted = false
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { _ in booted = true; return fixture.structuralInventory },
            resume: { _ in fixture.structuralInventory },
            stop: { _ in .absent },
            listManagedSessions: {
                try Data("changed-after-selection".utf8).write(to: selectedSession, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selectedSession.path)
                return []
            }
        )

        assertRemoteErrorContains("digest") { _ = try guardian.tick() }
        XCTAssertFalse(booted)
    }

    func testGuardianReturnsAlreadyRunningOnlyForExactHealthyActiveInventory() throws {
        let fixture = try GuardianFixture()
        defer { fixture.remove() }
        try fixture.writeActive("old")
        let exact = fixture.finalInventory(generation: "old")
        var booted = false
        let guardian = fixture.guardian(probe: { name in XCTAssertEqual(name, "old"); return .running(exact) }, boot: { _ in booted = true; return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
        XCTAssertEqual(try guardian.tick(), .alreadyRunning("old"))
        XCTAssertFalse(booted)

        let degraded = fixture.guardian(probe: { _ in .degraded("socket incompatible") }, boot: { _ in XCTFail("must not boot over degraded active generation"); return exact }, resume: { _ in exact }, stop: { _ in .absent })
        assertRemoteErrorContains("degraded") { _ = try degraded.tick() }
        let inexact = fixture.guardian(probe: { _ in .running(fixture.structuralInventory) }, boot: { _ in exact }, resume: { _ in exact }, stop: { _ in .absent })
        assertRemoteErrorContains("not exact") { _ = try inexact.tick() }
    }

    func testGuardianRejectsDuplicateUUIDAndUnsafeOrUnknownManifestBeforeMutation() throws {
        for mutation in ["duplicate", "unknown-root", "unknown-pane", "newer", "unsafe"] {
            let fixture = try GuardianFixture(duplicateUUID: mutation == "duplicate")
            defer { fixture.remove() }
            if mutation != "duplicate" {
                var object = try fixture.readManifestObject()
                if mutation == "unknown-root" { object["surprise"] = true }
                if mutation == "unknown-pane" {
                    var panes = try XCTUnwrap(object["expectedPanes"] as? [[String: Any]])
                    panes[0]["surprise"] = true
                    object["expectedPanes"] = panes
                }
                if mutation == "newer" { object["schemaVersion"] = 2 }
                if mutation == "unsafe" { object["sourceSession"] = "../lkg" }
                try fixture.writeManifestObject(object)
            }
            var mutations = 0
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in mutations += 1; return fixture.structuralInventory }, resume: { _ in mutations += 1; return fixture.structuralInventory }, stop: { _ in mutations += 1; return .absent })
            assertRemoteErrorContains("snapshot") { _ = try guardian.tick() }
            XCTAssertEqual(mutations, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedSessionURL.path))
        }
    }

    func testGuardianRejectsCorruptPointerAndUnsafeSnapshotFilesystem() throws {
        for mutation in ["pointer", "manifest-mode", "source-mode", "symlink", "hardlink", "missing"] {
            let fixture = try GuardianFixture()
            defer { fixture.remove() }
            if mutation == "pointer" {
                try Data("../bad\n".utf8).write(to: fixture.activeRuntimeURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.activeRuntimeURL.path)
            } else if mutation == "manifest-mode" {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.manifestURL.path)
            } else if mutation == "source-mode" {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.sourceSessionJSONURL.path)
            } else if mutation == "symlink" {
                try FileManager.default.removeItem(at: fixture.sourceSessionJSONURL)
                try FileManager.default.createSymbolicLink(at: fixture.sourceSessionJSONURL, withDestinationURL: fixture.oldSnapshotURL)
            } else if mutation == "hardlink" {
                try FileManager.default.linkItem(at: fixture.sourceSessionJSONURL, to: fixture.root.appendingPathComponent("extra-link"))
            } else {
                try FileManager.default.removeItem(at: fixture.sourceSnapshotURL)
            }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("must fail before boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains(mutation == "pointer" ? "active runtime" : "snapshot") { _ = try guardian.tick() }
        }
    }

    func testGuardianBlocksOutstandingLedgerExternalOwnerAndConcurrentTickBeforeBoot() throws {
        let fixture = try GuardianFixture()
        defer { fixture.remove() }
        let expected = fixture.manifest.expectedPanes[0]
        try fixture.ledger.prepare(attemptID: "live", nativeSessionID: expected.nativeSessionID, profileID: expected.profileID, generation: "failed", paneID: expected.paneID, ownerPID: 5)
        try fixture.ledger.markSpawnIntent(attemptID: "live")
        let blocked = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("ownership must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
        assertRemoteErrorContains("ownership") { _ = try blocked.tick() }
        try fixture.ledger.reconcile(attemptID: "live", resolution: .abandon)

        let external = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("external owner must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent }, nativeSessionOwnerExists: { $0 == expected.nativeSessionID })
        assertRemoteErrorContains("ownership") { _ = try external.tick() }

        let held = try RemoteAdvisoryLock.acquire(url: fixture.guardianLockURL)
        defer { held.release() }
        assertRemoteErrorContains("already running") { _ = try blocked.tick() }
    }

    func testGuardianProvesEveryManagedSessionAbsentBeforeStagedBoot() throws {
        let fixture = try GuardianFixture()
        defer { fixture.remove() }
        var booted = false
        let guardian = fixture.guardian(
            probe: { name in name == "stale-copy" ? .running(fixture.finalInventory(generation: "stale-copy")) : .absent },
            boot: { _ in booted = true; return fixture.structuralInventory },
            resume: { _ in fixture.structuralInventory },
            stop: { _ in .absent },
            listManagedSessions: { ["stale-copy"] }
        )
        assertRemoteErrorContains("prior managed session") { _ = try guardian.tick() }
        XCTAssertFalse(booted)

        let unsafe = fixture.guardian(
            probe: { _ in .absent },
            boot: { _ in XCTFail("unsafe managed name must block boot"); return fixture.structuralInventory },
            resume: { _ in fixture.structuralInventory },
            stop: { _ in .absent },
            listManagedSessions: { ["../unsafe"] }
        )
        assertRemoteErrorContains("session name is unsafe") { _ = try unsafe.tick() }
    }

    func testGuardianBlocksStrandedManagedProcessWhenEverySocketProbeSaysAbsent() throws {
        let fixture = try GuardianFixture(stageName: "blocked-by-process")
        defer { fixture.remove() }
        var booted = false
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { _ in booted = true; return fixture.structuralInventory },
            resume: { _ in fixture.structuralInventory },
            stop: { _ in .absent },
            listManagedSessions: { [] },
            listManagedProcessSessions: { ["ouro-stranded-without-socket"] }
        )

        assertRemoteErrorContains("process") { _ = try guardian.tick() }
        XCTAssertFalse(booted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagedSessionURL.path))
    }

    func testGuardianSafelyStopsAndQuarantinesOnlyBeforeAnyPossibleChildSpawn() throws {
        for phase in ["boot", "structure", "typed-pre-spawn"] {
            let fixture = try GuardianFixture(stageName: "safe-\(phase)")
            defer { fixture.remove() }
            try fixture.writeActive("old")
            var stopped: [String] = []
            var reactivated: [String] = []
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in
                    if phase == "boot" { throw RemoteFixtureError.expected }
                    if phase == "structure" { return RemoteHerdrInventory(version: "0.8.2", panes: []) }
                    return fixture.structuralInventory
                },
                resume: { _ in throw RemotePaneResumeFailure.preSpawn("queue rejected") },
                stop: { name in stopped.append(name); return .absent },
                reactivate: { runtime in reactivated.append(runtime.generation); return .running(fixture.finalInventory(generation: runtime.generation)) }
            )
            assertRemoteErrorContains("staged generation") { _ = try guardian.tick() }
            XCTAssertEqual(stopped, [fixture.stageName])
            XCTAssertEqual(reactivated, ["old"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
            XCTAssertEqual(try fixture.readActive().generation, "old")
            XCTAssertEqual(try Data(contentsOf: fixture.oldSnapshotURL), fixture.oldSnapshotBytes)
        }
    }

    func testGuardianRollbackUsesProductionAdapterToRestoreBothPriorPanesExactly() throws {
        let fixture = try GuardianFixture(stageName: "ouro-stage-rollback")
        defer { fixture.remove() }
        let priorGeneration = "ouro-prior"
        try fixture.writeActive(priorGeneration)
        let registry = try remoteRegistry()
        let sessionMapURL = fixture.root.appendingPathComponent("session-map.json")
        let priorExpectedInventoryURL = fixture.root.appendingPathComponent("sessions/\(priorGeneration)/expected-inventory.json")
        let panes = fixture.manifest.expectedPanes.enumerated().map { index, pane in
            (expected: pane, shellPID: Int32(801 + index), childPID: Int32(901 + index))
        }
        try fixture.writePrivateData(try remoteJSONData([
            "schemaVersion": 1,
            "entries": panes.map { pane in
                ["sessionID": pane.expected.nativeSessionID, "profileID": pane.expected.profileID, "paneID": pane.expected.paneID, "generation": priorGeneration]
            }
        ]), to: sessionMapURL)

        var calls: [[String]] = []
        var spawnedGenerations: [String] = []
        var runningSessions = Set<String>()
        var resumedPanes = Set<String>()
        var identities = Dictionary(uniqueKeysWithValues: panes.map { pane in
            (pane.shellPID, remoteProcessIdentity(pid: pane.shellPID, executable: "/bin/zsh", generation: priorGeneration))
        })
        let adapter = RemoteHerdrAdapter(
            rootURL: fixture.root,
            registry: registry,
            ledger: fixture.ledger,
            sessionMapURL: sessionMapURL,
            herdrExecutable: "/fixtures/bin/herdr",
            configPath: "/runtime/profiles.json",
            helperPath: "/runtime/helper",
            shimDirectory: "/runtime/shims",
            zdotdir: "/runtime/zdotdir",
            inheritedEnvironment: [:],
            run: { request, _ in
                calls.append(request.arguments)
                switch request.arguments {
                case ["config", "check"]:
                    return .init(exitCode: 0)
                case ["session", "list", "--json"]:
                    return .init(exitCode: 0, stdout: try remoteJSONData([
                        "sessions": runningSessions.sorted().map { ["name": $0, "running": true] }
                    ]))
                case ["--session", priorGeneration, "api", "snapshot"]:
                    let snapshotPanes: [[String: Any]] = panes.map { pane in
                        [
                            "pane_id": pane.expected.paneID,
                            "workspace_id": pane.expected.workspaceID,
                            "agent_session": ["agent": "copilot", "value": pane.expected.nativeSessionID]
                        ]
                    }
                    return .init(exitCode: 0, stdout: try remoteJSONData([
                        "result": ["snapshot": ["version": "0.8.2", "panes": snapshotPanes]]
                    ]))
                case let arguments where arguments.count == 4 && arguments[0] == "session" && arguments[1] == "stop" && arguments[3] == "--json":
                    runningSessions.remove(arguments[2])
                    return .init(exitCode: 1)
                case let arguments where arguments.count == 6 && arguments[0...3] == ["--session", priorGeneration, "pane", "run"]:
                    let pane = try XCTUnwrap(panes.first { $0.expected.paneID == arguments[4] })
                    let profile = try registry.profile(id: pane.expected.profileID)
                    let identity = remoteProcessIdentity(pid: pane.childPID, startIdentity: "birth-\(pane.childPID)", executable: profile.copilotExecutable, generation: priorGeneration)
                    identities[pane.childPID] = identity
                    let attemptID = "rollback-\(pane.childPID)"
                    let argv = [profile.copilotExecutable] + RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(pane.expected.nativeSessionID)"])
                    try fixture.ledger.prepare(attemptID: attemptID, nativeSessionID: pane.expected.nativeSessionID, profileID: pane.expected.profileID, generation: priorGeneration, paneID: pane.expected.paneID, ownerPID: getpid(), expectedArgvSHA256: RemoteArgvDigest.sha256(argv))
                    try fixture.ledger.markSpawnIntent(attemptID: attemptID)
                    try fixture.ledger.recordChild(attemptID: attemptID, identity: identity)
                    try fixture.ledger.confirm(nativeSessionID: pane.expected.nativeSessionID, profileID: pane.expected.profileID, generation: priorGeneration, paneID: pane.expected.paneID)
                    resumedPanes.insert(pane.expected.paneID)
                    return .init(exitCode: 0)
                case let arguments where arguments.count == 6 && arguments[0...4] == ["--session", priorGeneration, "pane", "process-info", "--pane"]:
                    let pane = try XCTUnwrap(panes.first { $0.expected.paneID == arguments[5] })
                    let foreground: [[String: Any]]
                    if resumedPanes.contains(pane.expected.paneID) {
                        let profile = try registry.profile(id: pane.expected.profileID)
                        foreground = [[
                            "pid": pane.childPID,
                            "argv": [profile.copilotExecutable] + RemoteAccountBroker.managedCopilotArguments(profile: profile, originalArguments: ["--resume=\(pane.expected.nativeSessionID)"])
                        ]]
                    } else {
                        foreground = []
                    }
                    return .init(exitCode: 0, stdout: try remoteJSONData([
                        "result": ["process_info": ["shell_pid": pane.shellPID, "foreground_processes": foreground]]
                    ]))
                case ["api", "/user", "--jq", ".login"]:
                    let login = request.environment["GH_CONFIG_DIR"] == "/tmp/ouro/gh/emu" ? "arimendelow_microsoft" : "arimendelow"
                    return .init(exitCode: 0, stdout: Data("\(login)\n".utf8))
                default:
                    return .init(exitCode: 97)
                }
            },
            listHerdrProcessSessions: { runningSessions.sorted() },
            processIdentityForPID: { pid, _ in identities[pid] },
            shellReadiness: { pid, generation, _ in identities[pid]?.executable == "/bin/zsh" && identities[pid]?.generation == generation },
            readPrivateFile: { path, _ in
                if path == priorExpectedInventoryURL.path {
                    return try Data(contentsOf: URL(fileURLWithPath: path))
                }
                return Data("[session]\nresume_agents_on_restore = false\n".utf8)
            },
            spawnServer: { request in
                XCTAssertEqual(request.arguments.count, 3)
                XCTAssertEqual(request.arguments.first, "--session")
                let generation = request.arguments[1]
                spawnedGenerations.append(generation)
                if generation == fixture.stageName { throw RemoteFixtureError.expected }
                XCTAssertEqual(generation, priorGeneration)
                runningSessions.insert(generation)
                return RemoteHerdrServerHandle(
                    running: { runningSessions.contains(generation) },
                    terminateAndWait: { _ in runningSessions.remove(generation); return true }
                )
            }
        )
        var restored: RemoteHerdrProbe?
        let guardian = fixture.guardian(
            probe: { try adapter.probe(sessionName: $0) },
            boot: adapter.boot,
            resume: adapter.resume,
            stop: { try adapter.stop(sessionName: $0) },
            listManagedSessions: adapter.listManagedSessions,
            listManagedProcessSessions: adapter.listManagedProcessSessions,
            reactivate: { runtime in restored = try adapter.reactivate(runtime); return restored! },
            helperPath: "/runtime/helper"
        )

        assertRemoteErrorContains("prior generation reactivated") { _ = try guardian.tick() }
        guard case let .running(inventory) = restored else { return XCTFail("expected exact prior-generation restoration") }
        XCTAssertEqual(inventory.panes.map(\.paneID), ["desk:p1", "desk:p2"])
        XCTAssertEqual(inventory.panes.map(\.profileID), ["personal", "emu"])
        XCTAssertTrue(inventory.panes.allSatisfy { $0.generation == priorGeneration && $0.childPresent && $0.hookObserved && $0.wrapperReady && $0.foregroundProcess != nil })
        XCTAssertEqual(spawnedGenerations, [fixture.stageName, priorGeneration])
        let paneRuns = calls.filter { $0.count == 6 && $0[0...3] == ["--session", priorGeneration, "pane", "run"] }
        XCTAssertEqual(paneRuns.map { $0[4] }, ["desk:p1", "desk:p2"])
        XCTAssertEqual(runningSessions, Set([priorGeneration]))
        XCTAssertEqual(try fixture.readActive().generation, priorGeneration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.appendingPathComponent("recovery-required.json").path))
    }

    func testSafeFailureWithoutPriorRuntimeMakesAvailabilityExplicitlyUnavailable() throws {
        let fixture = try GuardianFixture(stageName: "no-prior")
        defer { fixture.remove() }
        let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in throw RemoteFixtureError.expected }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
        assertRemoteErrorContains("availability unavailable") { _ = try guardian.tick() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.activeRuntimeURL.path))
    }

    func testPreSpawnFailureQuarantinesWhenProductionAdapterProvesNonexistentSessionAbsent() throws {
        let fixture = try GuardianFixture(stageName: "adapter-nonexistent")
        defer { fixture.remove() }
        let adapter = RemoteHerdrAdapter(
            rootURL: fixture.root,
            registry: try remoteRegistry(),
            ledger: fixture.ledger,
            sessionMapURL: fixture.root.appendingPathComponent("session-map.json"),
            herdrExecutable: "/fixtures/bin/herdr",
            configPath: "/runtime/profiles.json",
            helperPath: "/runtime/helper",
            shimDirectory: "/runtime/shims",
            zdotdir: "/runtime/zdotdir",
            inheritedEnvironment: [:],
            run: { request, _ in
                if request.arguments == ["session", "stop", fixture.stageName, "--json"] { return .init(exitCode: 1) }
                if request.arguments == ["session", "list", "--json"] { return .init(exitCode: 0, stdout: try remoteJSONData(["sessions": []])) }
                throw RemoteFixtureError.expected
            },
            listHerdrProcessSessions: { [] },
            fileExists: { _ in false }
        )
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { _ in throw RemotePaneResumeFailure.preSpawn("fixture rejected before spawn") },
            resume: { _ in fixture.structuralInventory },
            stop: adapter.stop
        )

        assertRemoteErrorContains("availability unavailable") { _ = try guardian.tick() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
    }

    func testGuardianLeavesStageOwnedAndRecoveryRequiredAfterPossibleSpawnOrPartialSuccess() throws {
        for phase in ["resume-error", "inventory", "after-one"] {
            let fixture = try GuardianFixture(stageName: "owned-\(phase)")
            defer { fixture.remove() }
            try fixture.writeActive("old")
            var stopped = 0
            var calls = 0
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in fixture.structuralInventory },
                resume: { _ in
                    calls += 1
                    if phase == "resume-error" { throw RemoteFixtureError.expected }
                    if phase == "inventory" { return RemoteHerdrInventory(version: "0.8.2", panes: []) }
                    if calls == 1 {
                        var panes = fixture.structuralInventory.panes
                        panes[0] = fixture.resumedInventory(for: fixture.manifest.expectedPanes[0])
                        return RemoteHerdrInventory(version: "0.8.2", panes: panes)
                    }
                    throw RemotePaneResumeFailure.preSpawn("second queue failed")
                },
                stop: { _ in stopped += 1; return .absent }
            )
            assertRemoteErrorContains("recovery required") { _ = try guardian.tick() }
            XCTAssertEqual(stopped, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stagedSessionURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
            XCTAssertEqual(mode(at: fixture.recoveryMarkerURL), 0o600)
            XCTAssertEqual(try fixture.readActive().generation, "old")
        }
    }

    func testGuardianTreatsFirstPanePostIntentFailureAsPossibleSpawn() throws {
        let fixture = try GuardianFixture(stageName: "post-intent")
        defer { fixture.remove() }
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { _ in fixture.structuralInventory },
            resume: { _ in throw RemotePaneResumeFailure.postIntent("pane.run transport failed") },
            stop: { _ in XCTFail("an invoked pane.run must never enter the safe-stop path"); return .absent }
        )

        assertRemoteErrorContains("recovery required") { _ = try guardian.tick() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stagedSessionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.path))
    }

    func testGuardianStopsSequentialRestoreWhenAnotherPaneChangesBeforeItsTurn() throws {
        let fixture = try GuardianFixture(stageName: "future-pane-mutated")
        defer { fixture.remove() }
        var resumeCount = 0
        let guardian = fixture.guardian(
            probe: { _ in .absent },
            boot: { _ in fixture.structuralInventory },
            resume: { _ in
                resumeCount += 1
                return RemoteHerdrInventory(
                    version: "0.8.2",
                    panes: fixture.manifest.expectedPanes.map { fixture.resumedInventory(for: $0) }
                )
            },
            stop: { _ in XCTFail("possible children must remain owned"); return .absent }
        )

        assertRemoteErrorContains("recovery required") { _ = try guardian.tick() }
        XCTAssertEqual(resumeCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
    }

    func testGuardianStopFailurePreservesStageAndMarksRecoveryRequired() throws {
        let fixture = try GuardianFixture(stageName: "stop-timeout")
        defer { fixture.remove() }
        let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in throw RemoteFixtureError.expected }, resume: { _ in fixture.structuralInventory }, stop: { _ in .degraded("still running") })
        assertRemoteErrorContains("recovery required") { _ = try guardian.tick() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stagedSessionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
    }

    func testGuardianRequiresWrapperReadinessAndFreshExactHookProcessAccountAndNativeReference() throws {
        for index in 0..<8 {
            let fixture = try GuardianFixture(stageName: "verify-\(index)")
            defer { fixture.remove() }
            let expected = fixture.manifest.expectedPanes[0]
            var invalid = fixture.resumedInventory(for: expected)
            switch index {
            case 0: invalid.childPresent = false
            case 1: invalid.hookObserved = false
            case 2: invalid.profileID = "emu"
            case 3: invalid.nativeSessionID = nil
            case 4: invalid.generation = "wrong"
            case 5: invalid.foregroundProcess = nil
            case 6: invalid.githubLogin = "wrong-login"
            default: invalid.wrapperReady = false
            }
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in
                    if index == 7 {
                        var panes = fixture.structuralInventory.panes
                        panes[0].wrapperReady = false
                        return RemoteHerdrInventory(version: "0.8.2", panes: panes)
                    }
                    return fixture.structuralInventory
                },
                resume: { _ in RemoteHerdrInventory(version: "0.8.2", panes: [invalid] + Array(fixture.structuralInventory.panes.dropFirst())) },
                stop: { _ in .absent }
            )
            assertRemoteErrorContains(index == 7 ? "structural" : "recovery required") { _ = try guardian.tick() }
        }
    }

    func testWorkerIntegrityRequiresExactLiveIdentityArgvAndVerifiedAccount() {
        let recorded = remoteProcessIdentity(pid: 101, startIdentity: "birth-101", executable: "/opt/copilot/bin/copilot", generation: "ouro-generation")
        let expectedArguments = ["--agent", "desk:worker", "--allow-all", "--remote", "--resume=8d5177d6-b6d1-4b5f-a546-564ed0ef8748"]
        let exactArgv = ["/opt/copilot/bin/copilot"] + expectedArguments

        XCTAssertTrue(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 101, herdrArgv: exactArgv, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: nil, herdrPID: 101, herdrArgv: exactArgv, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: remoteProcessIdentity(pid: 101, startIdentity: "replacement", executable: "/opt/copilot/bin/copilot", generation: "ouro-generation"), herdrPID: 101, herdrArgv: exactArgv, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 102, herdrArgv: exactArgv, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 101, herdrArgv: ["/wrong/copilot"] + expectedArguments, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 101, herdrArgv: nil, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 101, herdrArgv: exactArgv + ["unexpected"], expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 101, herdrArgv: exactArgv, expectedExecutable: "/wrong/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "arimendelow", expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 101, herdrArgv: exactArgv, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: nil, expectedGitHubLogin: "arimendelow"))
        XCTAssertFalse(RemoteWorkerIntegrity.matches(recordedIdentity: recorded, liveIdentity: recorded, herdrPID: 101, herdrArgv: exactArgv, expectedExecutable: "/opt/copilot/bin/copilot", expectedArguments: expectedArguments, actualGitHubLogin: "wrong", expectedGitHubLogin: "arimendelow"))
    }

    func testManagedHerdrProcessRequiresExactPinnedServerArgv() {
        let executable = "/opt/herdr/bin/herdr"
        let exact = [executable, "--session", "ouro-generation", "server"]

        XCTAssertEqual(RemoteManagedHerdrProcess.sessionName(executable: executable, argv: exact, expectedExecutable: executable), "ouro-generation")
        XCTAssertNil(RemoteManagedHerdrProcess.sessionName(executable: "/wrong/herdr", argv: exact, expectedExecutable: executable))
        XCTAssertNil(RemoteManagedHerdrProcess.sessionName(executable: executable, argv: nil, expectedExecutable: executable))
        XCTAssertNil(RemoteManagedHerdrProcess.sessionName(executable: executable, argv: ["/wrong/herdr", "--session", "ouro-generation", "server"], expectedExecutable: executable))
        XCTAssertNil(RemoteManagedHerdrProcess.sessionName(executable: executable, argv: [executable, "--session", "foreign-generation", "server"], expectedExecutable: executable))
        XCTAssertNil(RemoteManagedHerdrProcess.sessionName(executable: executable, argv: [executable, "--session", "ouro/unsafe", "server"], expectedExecutable: executable))
        XCTAssertNil(RemoteManagedHerdrProcess.sessionName(executable: executable, argv: [executable, "--session", "ouro-generation", "client"], expectedExecutable: executable))
        XCTAssertNil(RemoteManagedHerdrProcess.sessionName(executable: executable, argv: exact + ["unexpected"], expectedExecutable: executable))
    }

    func testGuardianRejectsUnsafeHelperRootEnumerationAndExistingGenerations() throws {
        for helperPath in ["relative/helper", "/opt/ouro/../helper"] {
            let fixture = try GuardianFixture(stageName: "helper-\(UUID().uuidString)")
            defer { fixture.remove() }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("invalid helper must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent }, helperPath: helperPath)
            assertRemoteErrorContains("absolute normalized helper") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "unsafe-root")
            defer { fixture.remove() }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("unsafe root must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("permissions must be 0700") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "enumeration-failure")
            defer { fixture.remove() }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("enumeration failure must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent }, listManagedSessions: { throw RemoteFixtureError.expected })
            assertRemoteErrorContains("enumeration failed") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "process-enumeration-failure")
            defer { fixture.remove() }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("process enumeration failure must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent }, listManagedProcessSessions: { throw RemoteFixtureError.expected })
            assertRemoteErrorContains("process enumeration failed") { _ = try guardian.tick() }
        }

        for existing in ["staged", "quarantine"] {
            let fixture = try GuardianFixture(stageName: "existing-\(existing)")
            defer { fixture.remove() }
            let url = existing == "staged" ? fixture.stagedSessionURL : fixture.quarantinedSessionURL
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var probed: [String] = []
            let guardian = fixture.guardian(probe: { name in probed.append(name); return .absent }, boot: { _ in XCTFail("existing generation must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent }, listManagedSessions: { ["dead-copy"] })
            assertRemoteErrorContains("already exists") { _ = try guardian.tick() }
            XCTAssertEqual(probed, ["dead-copy"])
        }
    }

    func testGuardianRejectsMalformedManifestShapesFieldsAndBounds() throws {
        for mutation in ["array", "malformed", "pane-shape", "field-type", "version", "empty", "uuid", "identity", "oversized"] {
            let fixture = try GuardianFixture(stageName: "manifest-\(mutation)")
            defer { fixture.remove() }
            if mutation == "array" {
                try fixture.writePrivateData(try remoteJSONData([Any]()), to: fixture.manifestURL)
            } else if mutation == "malformed" {
                try fixture.writePrivateData(Data("{".utf8), to: fixture.manifestURL)
            } else if mutation == "oversized" {
                try fixture.writePrivateData(Data(repeating: 0x20, count: RemoteGuardian.maximumControlFileBytes + 1), to: fixture.manifestURL)
            } else {
                var object = try fixture.readManifestObject()
                if mutation == "pane-shape" { object["expectedPanes"] = ["bad"] }
                if mutation == "field-type" { object["schemaVersion"] = "one" }
                if mutation == "version" { object["herdrVersion"] = "0.8.3" }
                if mutation == "empty" { object["expectedPanes"] = [Any]() }
                if mutation == "uuid" || mutation == "identity" {
                    var panes = try XCTUnwrap(object["expectedPanes"] as? [[String: Any]])
                    panes[0][mutation == "uuid" ? "nativeSessionID" : "paneID"] = mutation == "uuid" ? "not-a-uuid" : ""
                    object["expectedPanes"] = panes
                }
                try fixture.writeManifestObject(object)
            }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("invalid manifest must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("snapshot") { _ = try guardian.tick() }
        }
    }

    func testGuardianRejectsMalformedActiveRuntimeDocumentsFieldsIdentityAndPaths() throws {
        for mutation in ["array", "malformed", "keys", "field-type", "schema", "session", "socket", "inventory"] {
            let fixture = try GuardianFixture(stageName: "runtime-\(mutation)")
            defer { fixture.remove() }
            try fixture.writeActive("old")
            if mutation == "array" {
                try fixture.writePrivateData(try remoteJSONData([Any]()), to: fixture.activeRuntimeURL)
            } else if mutation == "malformed" {
                try fixture.writePrivateData(Data("{".utf8), to: fixture.activeRuntimeURL)
            } else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.activeRuntimeURL)) as? [String: Any])
                if mutation == "keys" { object.removeValue(forKey: "socketPath") }
                if mutation == "field-type" { object["schemaVersion"] = "one" }
                if mutation == "schema" { object["schemaVersion"] = 2 }
                if mutation == "session" { object["sessionName"] = "different" }
                if mutation == "socket" { object["socketPath"] = "/wrong/herdr.sock" }
                if mutation == "inventory" { object["expectedInventoryPath"] = "/wrong/expected-inventory.json" }
                try fixture.writePrivateData(try remoteJSONData(object), to: fixture.activeRuntimeURL)
            }
            let guardian = fixture.guardian(probe: { _ in XCTFail("invalid active runtime must fail before probe"); return .absent }, boot: { _ in fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("active runtime") { _ = try guardian.tick() }
        }
    }

    func testGuardianRejectsMalformedExpectedInventoryDocumentsFieldsAndMismatches() throws {
        for mutation in ["array", "malformed", "keys", "pane-shape", "pane-keys", "field-type", "version", "generation", "panes"] {
            let fixture = try GuardianFixture(stageName: "expected-\(mutation)")
            defer { fixture.remove() }
            try fixture.writeActive("old")
            if mutation == "array" {
                try fixture.writePrivateData(try remoteJSONData([Any]()), to: fixture.oldExpectedInventoryURL)
            } else if mutation == "malformed" {
                try fixture.writePrivateData(Data("{".utf8), to: fixture.oldExpectedInventoryURL)
            } else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.oldExpectedInventoryURL)) as? [String: Any])
                if mutation == "keys" { object.removeValue(forKey: "generation") }
                if mutation == "pane-shape" { object["panes"] = "bad" }
                if mutation == "field-type" { object["version"] = "one" }
                if mutation == "version" { object["version"] = 2 }
                if mutation == "generation" { object["generation"] = "different" }
                if mutation == "pane-keys" || mutation == "panes" {
                    var panes = try XCTUnwrap(object["panes"] as? [[String: Any]])
                    if mutation == "pane-keys" { panes[0]["extra"] = true }
                    if mutation == "panes" { panes[0]["profile_id"] = "different" }
                    object["panes"] = panes
                }
                try fixture.writePrivateData(try remoteJSONData(object), to: fixture.oldExpectedInventoryURL)
            }
            let guardian = fixture.guardian(probe: { _ in .running(fixture.finalInventory(generation: "old")) }, boot: { _ in XCTFail("invalid expected inventory must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("expected inventory") { _ = try guardian.tick() }
        }
    }

    func testGuardianRejectsUnsafeNestedSnapshotSymlinkedDirectoryAndCopyFailure() throws {
        do {
            let fixture = try GuardianFixture(stageName: "nested-mode")
            defer { fixture.remove() }
            let nested = fixture.sourceSnapshotURL.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("unsafe nested directory must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("directory permissions") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "directory-symlink")
            defer { fixture.remove() }
            let target = fixture.root.appendingPathComponent("snapshot-target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.removeItem(at: fixture.sourceSnapshotURL)
            try FileManager.default.createSymbolicLink(at: fixture.sourceSnapshotURL, withDestinationURL: target)
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("symlinked snapshot must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("symbolic link") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "copy-failure")
            defer { fixture.remove() }
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("sessions"))
            try fixture.writePrivateData(Data("not-a-directory".utf8), to: fixture.root.appendingPathComponent("sessions"))
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("copy failure must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("could not be copied") { _ = try guardian.tick() }
        }
    }

    func testGuardianReportsACLBasedControlFileFailures() throws {
        do {
            let fixture = try GuardianFixture(stageName: "manifest-read-acl")
            defer { fixture.remove() }
            try addDenyACL("read", to: fixture.manifestURL)
            defer { try? removeACL(from: fixture.manifestURL) }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("snapshot manifest is unreadable") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "runtime-readattr-acl")
            defer { fixture.remove() }
            try fixture.writeActive("old")
            try addDenyACL("readattr", to: fixture.activeRuntimeURL)
            defer { try? removeACL(from: fixture.activeRuntimeURL) }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("active runtime is unreadable") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "runtime-read-acl")
            defer { fixture.remove() }
            try fixture.writeActive("old")
            try addDenyACL("read", to: fixture.activeRuntimeURL)
            defer { try? removeACL(from: fixture.activeRuntimeURL) }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("active runtime is unreadable") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "runtime-byte-bound")
            defer { fixture.remove() }
            try fixture.writePrivateData(Data(repeating: 0x20, count: RemoteGuardian.maximumControlFileBytes + 1), to: fixture.activeRuntimeURL)
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
            assertRemoteErrorContains("active runtime exceeds the byte bound") { _ = try guardian.tick() }
        }
    }

    func testGuardianRejectsUnlistableSnapshotDirectoryBeforeCopy() throws {
        let fixture = try GuardianFixture(stageName: "snapshot-list-acl")
        defer { fixture.remove() }
        try addDenyACL("list", to: fixture.sourceSnapshotURL)
        defer { try? removeACL(from: fixture.sourceSnapshotURL) }
        let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in XCTFail("unlistable snapshot must block boot"); return fixture.structuralInventory }, resume: { _ in fixture.structuralInventory }, stop: { _ in .absent })
        assertRemoteErrorContains("snapshot source is unreadable") { _ = try guardian.tick() }
    }

    func testGuardianRejectsDisappearingSnapshotEntryAndNonisolatedCopy() throws {
        do {
            let fixture = try GuardianFixture(stageName: "snapshot-entry-race")
            defer { fixture.remove() }
            let disappearing = fixture.sourceSnapshotURL.appendingPathComponent("disappearing.json")
            try fixture.writePrivateData(Data("race".utf8), to: disappearing)
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in XCTFail("unreadable entry must block boot"); return fixture.structuralInventory },
                resume: { _ in fixture.structuralInventory },
                stop: { _ in .absent },
                snapshotLstat: { path, value in
                    if path == disappearing.path { return -1 }
                    return path.withCString { Darwin.lstat($0, value) }
                }
            )
            assertRemoteErrorContains("snapshot entry is unreadable") { _ = try guardian.tick() }
        }

        do {
            let fixture = try GuardianFixture(stageName: "same-inode")
            defer { fixture.remove() }
            let stagedSession = fixture.stagedSessionURL.appendingPathComponent("session.json").path
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in XCTFail("nonisolated copy must block boot"); return fixture.structuralInventory },
                resume: { _ in fixture.structuralInventory },
                stop: { _ in .absent },
                snapshotLstat: { path, value in
                    let result = path.withCString { Darwin.lstat($0, value) }
                    if result == 0, path == fixture.sourceSessionJSONURL.path || path == stagedSession { value.pointee.st_ino = 42 }
                    return result
                }
            )
            assertRemoteErrorContains("isolated inode") { _ = try guardian.tick() }
        }
    }

    func testGuardianFailureTransitionsPreserveOwnershipAndRecoveryEvidence() throws {
        do {
            let fixture = try GuardianFixture(stageName: "stop-throws")
            defer { fixture.remove() }
            let guardian = fixture.guardian(probe: { _ in .absent }, boot: { _ in throw RemoteFixtureError.expected }, resume: { _ in fixture.structuralInventory }, stop: { _ in throw RemoteFixtureError.expected })
            assertRemoteErrorContains("recovery required") { _ = try guardian.tick() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
        }

        do {
            let fixture = try GuardianFixture(stageName: "quarantine-failure")
            defer { fixture.remove() }
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in
                    try FileManager.default.createDirectory(at: fixture.quarantinedSessionURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    throw RemoteFixtureError.expected
                },
                resume: { _ in fixture.structuralInventory },
                stop: { _ in .absent }
            )
            assertRemoteErrorContains("recovery required") { _ = try guardian.tick() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
        }

        for failure in ["inexact", "throws"] {
            let fixture = try GuardianFixture(stageName: "reactivate-\(failure)")
            defer { fixture.remove() }
            try fixture.writeActive("old")
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in throw RemoteFixtureError.expected },
                resume: { _ in fixture.structuralInventory },
                stop: { _ in .absent },
                reactivate: { _ in
                    if failure == "throws" { throw RemoteFixtureError.expected }
                    return .absent
                }
            )
            assertRemoteErrorContains("prior availability requires recovery") { _ = try guardian.tick() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.quarantinedSessionURL.appendingPathComponent("recovery-required.json").path))
        }

        do {
            let fixture = try GuardianFixture(stageName: "publish-failure")
            defer { fixture.remove() }
            var livePanes = fixture.structuralInventory.panes
            var resumed = 0
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in fixture.structuralInventory },
                resume: { _ in
                    let expected = fixture.manifest.expectedPanes[resumed]
                    let index = try XCTUnwrap(livePanes.firstIndex(where: { $0.paneID == expected.paneID }))
                    livePanes[index] = fixture.resumedInventory(for: expected)
                    resumed += 1
                    if resumed == fixture.manifest.expectedPanes.count {
                        try FileManager.default.createDirectory(at: fixture.activeRuntimeURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    }
                    return RemoteHerdrInventory(version: "0.8.2", panes: livePanes)
                },
                stop: { _ in .absent }
            )
            assertRemoteErrorContains("recovery required") { _ = try guardian.tick() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recoveryMarkerURL.path))
        }

        do {
            let fixture = try GuardianFixture(stageName: "marker-failure")
            defer { fixture.remove() }
            let guardian = fixture.guardian(
                probe: { _ in .absent },
                boot: { _ in fixture.structuralInventory },
                resume: { _ in
                    try FileManager.default.createDirectory(at: fixture.recoveryMarkerURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    throw RemoteFixtureError.expected
                },
                stop: { _ in .absent }
            )
            assertRemoteErrorContains("durable marker failed") { _ = try guardian.tick() }
        }
    }

    private func mode(at url: URL) -> mode_t {
        var value = stat()
        XCTAssertEqual(lstat(url.path, &value), 0)
        return value.st_mode & mode_t(0o777)
    }

    private func inode(at url: URL) -> ino_t {
        var value = stat()
        XCTAssertEqual(lstat(url.path, &value), 0)
        return value.st_ino
    }

    private func addDenyACL(_ permission: String, to url: URL) throws {
        try runChmod(["+a", "everyone deny \(permission)", url.path])
    }

    private func removeACL(from url: URL) throws {
        try runChmod(["-N", url.path])
    }

    private func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class GuardianThreadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<RemoteGuardianResult, Error>?

    func set(_ value: Result<RemoteGuardianResult, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Result<RemoteGuardianResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class GuardianThreadRun: @unchecked Sendable {
    private let guardian: RemoteGuardian
    private let result: GuardianThreadResult
    private let finished: DispatchSemaphore

    init(guardian: RemoteGuardian, result: GuardianThreadResult, finished: DispatchSemaphore) {
        self.guardian = guardian
        self.result = result
        self.finished = finished
    }

    func start() {
        Thread.detachNewThread { [self] in
            result.set(Result { try guardian.tick() })
            finished.signal()
        }
    }
}

private final class GuardianFixture {
    let root: URL
    let manifest: RemoteGenerationManifest
    let ledger: RemoteResumeLedger
    let stageName: String
    let oldSnapshotBytes = Data("prior-generation-byte-truth".utf8)

    init(duplicateUUID: Bool = false, acknowledgedEmpty: Bool = false, stageName: String = "stage-1") throws {
        root = try remoteTemporaryDirectory("guardian")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        self.stageName = stageName
        let firstUUID = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let panes: [RemoteExpectedPane] = acknowledgedEmpty ? [] : [
            .init(workspaceID: "desk", paneID: "desk:p1", nativeSessionID: firstUUID, profileID: "personal", githubLogin: "arimendelow"),
            .init(workspaceID: "desk", paneID: "desk:p2", nativeSessionID: duplicateUUID ? firstUUID : "29633c1f-f185-41a7-b628-8f7e54d74422", profileID: "emu", githubLogin: "arimendelow_microsoft")
        ]
        manifest = RemoteGenerationManifest(schemaVersion: 1, sourceSession: "lkg", herdrVersion: "0.8.2", expectedPanes: panes, acknowledgedEmpty: acknowledgedEmpty)
        ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil }, inspectMatchingHerdrForeground: { _ in .absent })
        try FileManager.default.createDirectory(at: sourceSnapshotURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in [root.appendingPathComponent("last-known-good"), root.appendingPathComponent("last-known-good/generations"), root.appendingPathComponent("last-known-good/generations/fixture-lkg"), sourceSnapshotURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try Data("lkg-state".utf8).write(to: sourceSessionJSONURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceSessionJSONURL.path)
        let outer = RemoteLastKnownGoodManifest(schemaVersion: 1, captureID: "fixture-lkg", sourceGeneration: manifest.sourceSession, snapshotSHA256: try RemoteLastKnownGoodStore.snapshotSHA256(at: sourceSnapshotURL), generationManifest: manifest)
        try JSONEncoder().encode(outer).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        try Data("fixture-lkg\n".utf8).write(to: lastKnownGoodCurrentURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lastKnownGoodCurrentURL.path)
        try FileManager.default.createDirectory(at: oldSnapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("sessions").path)
        try oldSnapshotBytes.write(to: oldSnapshotURL)
    }

    var manifestURL: URL { root.appendingPathComponent("last-known-good/generations/fixture-lkg/manifest.json") }
    var sourceSnapshotURL: URL { capturedSessionURL("fixture-lkg") }
    var sourceSessionJSONURL: URL { sourceSnapshotURL.appendingPathComponent("session.json") }
    var activeRuntimeURL: URL { root.appendingPathComponent("active-runtime.json") }
    var guardianLockURL: URL { root.appendingPathComponent("guardian.lock") }
    var stagedSessionURL: URL { root.appendingPathComponent("sessions/\(stageName)", isDirectory: true) }
    var quarantinedSessionURL: URL { root.appendingPathComponent("quarantine/\(stageName)", isDirectory: true) }
    var recoveryMarkerURL: URL { stagedSessionURL.appendingPathComponent("recovery-required.json") }
    var oldSnapshotURL: URL { root.appendingPathComponent("sessions/old/session.json") }
    var oldExpectedInventoryURL: URL { root.appendingPathComponent("sessions/old/expected-inventory.json") }
    var lastKnownGoodCurrentURL: URL { root.appendingPathComponent("last-known-good/current") }
    func capturedSessionURL(_ id: String) -> URL { root.appendingPathComponent("last-known-good/generations/\(id)/session", isDirectory: true) }

    var structuralInventory: RemoteHerdrInventory {
        RemoteHerdrInventory(version: "0.8.2", panes: manifest.expectedPanes.map {
            RemotePaneInventory(workspaceID: $0.workspaceID, paneID: $0.paneID, nativeSessionID: $0.nativeSessionID, profileID: nil, githubLogin: nil, generation: stageName, childPresent: false, hookObserved: false, wrapperReady: true, foregroundProcess: nil)
        })
    }

    func resumedInventory(for expected: RemoteExpectedPane, generation: String? = nil) -> RemotePaneInventory {
        let selectedGeneration = generation ?? stageName
        return RemotePaneInventory(workspaceID: expected.workspaceID, paneID: expected.paneID, nativeSessionID: expected.nativeSessionID, profileID: expected.profileID, githubLogin: expected.githubLogin, generation: selectedGeneration, childPresent: true, hookObserved: true, wrapperReady: true, foregroundProcess: remoteProcessIdentity(pid: expected.profileID == "personal" ? 101 : 102, startIdentity: "birth-\(expected.profileID)", generation: selectedGeneration))
    }

    func finalInventory(generation: String) -> RemoteHerdrInventory {
        RemoteHerdrInventory(version: "0.8.2", panes: manifest.expectedPanes.map { resumedInventory(for: $0, generation: generation) })
    }

    func capture(id: String, generation: String, bytes: Data) throws -> RemoteLastKnownGoodManifest {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("last-known-good").path)
        let source = root.appendingPathComponent("sessions/\(generation)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        try bytes.write(to: source.appendingPathComponent("session.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.appendingPathComponent("session.json").path)
        return try RemoteLastKnownGoodStore(rootURL: root, makeCaptureID: { id }).capture(sourceGeneration: generation, inventory: finalInventory(generation: generation))
    }

    func selectCapture(_ id: String) throws {
        try RemoteDurableFile.write(Data("\(id)\n".utf8), to: lastKnownGoodCurrentURL)
    }

    func guardian(
        probe: @escaping (String) throws -> RemoteHerdrProbe,
        boot: @escaping (RemoteHerdrBootRequest) throws -> RemoteHerdrInventory,
        resume: @escaping (RemotePaneResumeCommand) throws -> RemoteHerdrInventory,
        stop: @escaping (String) throws -> RemoteHerdrProbe,
        nativeSessionOwnerExists: @escaping (String) -> Bool = { _ in false },
        listManagedSessions: @escaping () throws -> [String] = { [] },
        listManagedProcessSessions: @escaping () throws -> [String] = { [] },
        reactivate: ((RemoteActiveRuntime) throws -> RemoteHerdrProbe)? = nil,
        helperPath: String = "/opt/ouro/runtime/OuroWorkbenchRemote",
        snapshotLstat: ((String, UnsafeMutablePointer<stat>) -> Int32)? = nil
    ) -> RemoteGuardian {
        if let snapshotLstat {
            return RemoteGuardian(rootURL: root, helperPath: helperPath, ledger: ledger, probe: probe, listManagedSessions: listManagedSessions, listManagedProcessSessions: listManagedProcessSessions, boot: boot, resume: resume, stop: stop, reactivate: reactivate ?? { runtime in .running(self.finalInventory(generation: runtime.generation)) }, nativeSessionOwnerExists: nativeSessionOwnerExists, makeGenerationName: { self.stageName }, snapshotLstat: snapshotLstat)
        }
        return RemoteGuardian(rootURL: root, helperPath: helperPath, ledger: ledger, probe: probe, listManagedSessions: listManagedSessions, listManagedProcessSessions: listManagedProcessSessions, boot: boot, resume: resume, stop: stop, reactivate: reactivate ?? { runtime in .running(self.finalInventory(generation: runtime.generation)) }, nativeSessionOwnerExists: nativeSessionOwnerExists, makeGenerationName: { self.stageName })
    }

    func writeActive(_ name: String) throws {
        let generationRoot = root.appendingPathComponent("sessions/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: generationRoot, withIntermediateDirectories: true)
        let inventoryURL = generationRoot.appendingPathComponent("expected-inventory.json")
        let inventory: [String: Any] = [
            "version": 1,
            "generation": name,
            "acknowledged_empty": manifest.acknowledgedEmpty,
            "panes": manifest.expectedPanes.map {
                ["pane_id": $0.paneID, "native_session_id": $0.nativeSessionID, "profile_id": $0.profileID]
            }
        ]
        try remoteJSONData(inventory).write(to: inventoryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inventoryURL.path)
        let value = RemoteActiveRuntime(schemaVersion: 1, generation: name, sessionName: name, socketPath: generationRoot.appendingPathComponent("herdr.sock").path, expectedInventoryPath: inventoryURL.path)
        try JSONEncoder().encode(value).write(to: activeRuntimeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeRuntimeURL.path)
    }

    func readActive() throws -> RemoteActiveRuntime {
        try JSONDecoder().decode(RemoteActiveRuntime.self, from: Data(contentsOf: activeRuntimeURL))
    }

    func writeManifestObject(_ object: [String: Any]) throws {
        var outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        outer["generationManifest"] = object
        try remoteJSONData(outer).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    func readManifestObject() throws -> [String: Any] {
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        return try XCTUnwrap(outer["generationManifest"] as? [String: Any])
    }

    func writePrivateData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if url.path.hasPrefix(sourceSnapshotURL.path + "/") { try refreshSnapshotDigest() }
    }

    private func refreshSnapshotDigest() throws {
        var outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        outer["snapshotSHA256"] = try RemoteLastKnownGoodStore.snapshotSHA256(at: sourceSnapshotURL)
        try remoteJSONData(outer).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
