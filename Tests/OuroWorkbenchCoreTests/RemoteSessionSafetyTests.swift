import Darwin
import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteSessionSafetyTests: XCTestCase {
    func testSessionHookWritesCanonicalPrivateMapAndJoinsPIDFirstEvidence() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = remoteProcessIdentity(generation: "g-1")
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { pid, _ in pid == identity.pid ? identity : nil })
        try ledger.prepare(attemptID: "launch-1", nativeSessionID: nil, profileID: "personal", generation: "g-1", paneID: "desk:p1", ownerPID: 10)
        try ledger.markSpawnIntent(attemptID: "launch-1")
        try ledger.recordChild(attemptID: "launch-1", identity: identity)
        XCTAssertEqual(try ledger.record(attemptID: "launch-1")?.phase, .spawnedUnconfirmed)
        let store = RemoteSessionMapStore(rootURL: root.appendingPathComponent("map"))
        let hook = try remoteJSONData(["hookEventName": "SessionStart", "sessionId": "8D5177D6-B6D1-4B5F-A546-564ED0EF8748"])
        var officialInput: Data?

        let report = store.record(hookData: hook, profileID: "personal", paneID: "desk:p1", generation: "g-1", registry: try remoteRegistry(), ledger: ledger, officialHook: { data in officialInput = data; return nil })

        XCTAssertNil(report.mappingError)
        XCTAssertNil(report.officialHookError)
        XCTAssertEqual(officialInput, hook)
        XCTAssertEqual(try store.read(registry: remoteRegistry()), [
            RemoteSessionMapping(sessionID: "8d5177d6-b6d1-4b5f-a546-564ed0ef8748", profileID: "personal", paneID: "desk:p1", generation: "g-1")
        ])
        XCTAssertEqual(try ledger.record(attemptID: "launch-1")?.phase, .hookConfirmed)
        XCTAssertTrue(ledger.lockExists(nativeSessionID: "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"))
        XCTAssertFalse(store.hasPendingRecovery)
        XCTAssertEqual(mode(at: store.rootURL), 0o700)
        XCTAssertEqual(mode(at: store.mapURL), 0o600)
    }

    func testSessionHookAcceptsDocumentedPayloadAndRejectsUnsafeMetadata() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteSessionMapStore(rootURL: root)
        let registry = try remoteRegistry()
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let metadata: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": uuid,
            "timestamp": "2026-09-06T03:45:12.123Z",
            "cwd": "/Users/arimendelow/desk",
            "source": "resume",
            "initial_prompt": "continue"
        ]

        XCTAssertNil(store.record(hookData: try remoteJSONData(metadata), profileID: "personal", paneID: "desk:p1", generation: "g-1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError)
        XCTAssertEqual(try store.read(registry: registry).first?.sessionID, uuid)
        var wholeSecondTimestamp = metadata
        wholeSecondTimestamp["timestamp"] = "2026-09-06T03:45:12Z"
        XCTAssertNil(store.record(hookData: try remoteJSONData(wholeSecondTimestamp), profileID: "personal", paneID: "desk:p1", generation: "g-1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError)

        let invalidMetadata: [(String, Any, String)] = [
            ("timestamp", "not-a-timestamp", "timestamp"),
            ("timestamp", String(repeating: "2", count: 65), "timestamp"),
            ("timestamp", 1_725_000_000_000, "timestamp"),
            ("cwd", 42, "cwd"),
            ("cwd", "/" + String(repeating: "x", count: 4_096), "cwd"),
            ("cwd", "relative/path", "cwd"),
            ("cwd", "/tmp/../unsafe", "cwd"),
            ("cwd", "/tmp/bad\npath", "cwd"),
            ("source", "fork", "source"),
            ("source", 42, "source"),
            ("initial_prompt", 42, "initial prompt"),
            ("initial_prompt", String(repeating: "x", count: 32_769), "initial prompt")
        ]
        for (key, value, expected) in invalidMetadata {
            var payload = metadata
            payload["session_id"] = UUID().uuidString.lowercased()
            payload[key] = value
            XCTAssertTrue(store.record(hookData: try remoteJSONData(payload), profileID: "personal", paneID: "desk:p1", generation: "g-1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError?.contains(expected) == true)
        }
    }

    func testHookFirstAndPIDFirstEvidenceReachConfirmedOnlyAfterBothExactFacts() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
        try ledger.prepare(attemptID: "hook-first", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "hook-first")
        try ledger.confirm(nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1")
        XCTAssertEqual(try ledger.record(attemptID: "hook-first")?.phase, .hookObservedAwaitingPID)
        XCTAssertEqual(try ledger.record(attemptID: "hook-first")?.nativeSessionID, uuid)
        try ledger.recordChild(attemptID: "hook-first", identity: remoteProcessIdentity())
        XCTAssertEqual(try ledger.record(attemptID: "hook-first")?.phase, .hookConfirmed)

        try ledger.prepare(attemptID: "pid-first", nativeSessionID: "29633c1f-f185-41a7-b628-8f7e54d74422", profileID: "emu", generation: "g2", paneID: "p2", ownerPID: 2)
        try ledger.markSpawnIntent(attemptID: "pid-first")
        try ledger.recordChild(attemptID: "pid-first", identity: remoteProcessIdentity(pid: 201, startIdentity: "birth-201", generation: "g2"))
        XCTAssertEqual(try ledger.record(attemptID: "pid-first")?.phase, .spawnedUnconfirmed)
        try ledger.confirm(nativeSessionID: "29633c1f-f185-41a7-b628-8f7e54d74422", profileID: "emu", generation: "g2", paneID: "p2")
        XCTAssertEqual(try ledger.record(attemptID: "pid-first")?.phase, .hookConfirmed)
    }

    func testSessionHookRunsOfficialHookIndependentlyAndLeavesRecoverablePendingOnInterruptedMapWrite() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var officialCalls = 0
        let store = RemoteSessionMapStore(rootURL: root)
        let invalid = store.record(hookData: Data("not-json".utf8), profileID: "personal", paneID: "p1", generation: "g", registry: try remoteRegistry(), ledger: nil, officialHook: { _ in officialCalls += 1; return nil })
        XCTAssertNotNil(invalid.mappingError)
        XCTAssertNil(invalid.officialHookError)
        let oversized = store.record(hookData: Data(repeating: 1, count: RemoteSessionMapStore.maximumHookBytes + 1), profileID: "personal", paneID: "p1", generation: "g", registry: try remoteRegistry(), ledger: nil, officialHook: { _ in officialCalls += 1; return RemoteFixtureError.expected })
        XCTAssertTrue(oversized.mappingError?.contains("too large") == true)
        XCTAssertNotNil(oversized.officialHookError)

        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        XCTAssertNil(store.record(hookData: try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]), profileID: "personal", paneID: "p1", generation: "g1", registry: try remoteRegistry(), ledger: nil, officialHook: { _ in officialCalls += 1; return nil }).mappingError)
        let prior = try Data(contentsOf: store.mapURL)
        let interrupted = RemoteSessionMapStore(rootURL: root, writer: { _, _ in throw RemoteFixtureError.expected })
        let failed = interrupted.record(hookData: try remoteJSONData(["hook_event_name": "SessionStart", "session_id": "29633c1f-f185-41a7-b628-8f7e54d74422"]), profileID: "personal", paneID: "p2", generation: "g2", registry: try remoteRegistry(), ledger: nil, officialHook: { _ in officialCalls += 1; return nil })
        XCTAssertNotNil(failed.mappingError)
        XCTAssertNil(failed.officialHookError)
        XCTAssertEqual(try Data(contentsOf: store.mapURL), prior)
        XCTAssertTrue(interrupted.hasPendingRecovery)
        assertRemoteErrorContains("recovery required") { _ = try interrupted.read(registry: remoteRegistry()) }
        XCTAssertEqual(officialCalls, 4)
    }

    func testSessionMapStrictSchemaPermissionsSymlinksAndUnknownProfilesFailClosed() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try remoteRegistry()
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let valid: [String: Any] = ["schemaVersion": 1, "entries": [["sessionID": uuid, "profileID": "personal", "paneID": "p1", "generation": "g1"]]]
        let cases: [([String: Any], String)] = [
            (["schemaVersion": 2, "entries": []], "schema version"),
            (["schemaVersion": 1, "entries": [], "surprise": true], "unknown session map key"),
            (["schemaVersion": 1, "entries": [["sessionID": uuid, "profileID": "personal", "paneID": "p1", "generation": "g1", "surprise": true]]], "unknown session entry key"),
            (["schemaVersion": 1, "entries": [["sessionID": uuid.uppercased(), "profileID": "personal", "paneID": "p1", "generation": "g1"]]], "canonical"),
            (["schemaVersion": 1, "entries": [["sessionID": uuid, "profileID": "removed", "paneID": "p1", "generation": "g1"]]], "unknown profile"),
            (["schemaVersion": 1, "entries": Array(repeating: ["sessionID": uuid, "profileID": "personal", "paneID": "p1", "generation": "g1"], count: 2)], "duplicate")
        ]
        for (object, expected) in cases {
            let isolated = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: isolated.path)
            let map = isolated.appendingPathComponent("session-map.json")
            try remoteJSONData(object).write(to: map)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: map.path)
            assertRemoteErrorContains(expected) { _ = try RemoteSessionMapStore.read(mapURL: map, registry: registry) }
        }

        let permissionRoot = root.appendingPathComponent("permissions")
        try FileManager.default.createDirectory(at: permissionRoot, withIntermediateDirectories: true)
        let permissionMap = permissionRoot.appendingPathComponent("session-map.json")
        try remoteJSONData(valid).write(to: permissionMap)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: permissionMap.path)
        assertRemoteErrorContains("root permissions") { _ = try RemoteSessionMapStore.read(mapURL: permissionMap, registry: registry) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: permissionRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: permissionMap.path)
        assertRemoteErrorContains("file permissions") { _ = try RemoteSessionMapStore.read(mapURL: permissionMap, registry: registry) }

        let symlinkRoot = root.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: symlinkRoot.path)
        let target = root.appendingPathComponent("target.json")
        try remoteJSONData(valid).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("session-map.json"), withDestinationURL: target)
        assertRemoteErrorContains("regular file") { _ = try RemoteSessionMapStore.read(mapURL: symlinkRoot.appendingPathComponent("session-map.json"), registry: registry) }
    }

    func testReadOnlyMapAndLedgerInspectionNeverCreatesDirectoriesOrLockFiles() throws {
        let root = try remoteTemporaryDirectory("read-only-inspection")
        defer { try? FileManager.default.removeItem(at: root) }
        let missingMapRoot = root.appendingPathComponent("missing-map", isDirectory: true)
        assertRemoteErrorContains("root") { _ = try RemoteSessionMapStore.read(mapURL: missingMapRoot.appendingPathComponent("session-map.json"), registry: remoteRegistry()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingMapRoot.path))

        let mapRoot = root.appendingPathComponent("map", isDirectory: true)
        try FileManager.default.createDirectory(at: mapRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let mapURL = mapRoot.appendingPathComponent("session-map.json")
        try remoteJSONData(["schemaVersion": 1, "entries": []]).write(to: mapURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
        XCTAssertEqual(try RemoteSessionMapStore.read(mapURL: mapURL, registry: remoteRegistry()), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapRoot.appendingPathComponent("session-map.lock").path))

        let missingLedgerRoot = root.appendingPathComponent("missing-ledger", isDirectory: true)
        let missingLedger = RemoteResumeLedger(rootURL: missingLedgerRoot, processIdentityForPID: { _, _ in nil })
        XCTAssertNil(try missingLedger.record(attemptID: "missing"))
        XCTAssertFalse(try missingLedger.hasAmbiguousAttempt())
        XCTAssertFalse(try missingLedger.hasOutstandingOwnership(nativeSessionIDs: []))
        XCTAssertTrue(try missingLedger.inspectHealth().isClear)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingLedgerRoot.path))

        let ledgerRoot = root.appendingPathComponent("ledger", isDirectory: true)
        var writer: RemoteResumeLedger? = RemoteResumeLedger(rootURL: ledgerRoot, processIdentityForPID: { _, _ in nil })
        try writer!.prepare(attemptID: "intent", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try writer!.markSpawnIntent(attemptID: "intent")
        writer = nil
        try FileManager.default.removeItem(at: ledgerRoot.appendingPathComponent("ledger-state.lock"))
        let reader = RemoteResumeLedger(rootURL: ledgerRoot, processIdentityForPID: { _, _ in nil })
        XCTAssertEqual(try reader.record(attemptID: "intent")?.phase, .spawnIntent)
        XCTAssertTrue(try reader.hasAmbiguousAttempt())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerRoot.appendingPathComponent("ledger-state.lock").path))
    }

    func testReadOnlyLedgerHealthDistinguishesOwnedReconcileRequiredAndUnknownLiveness() throws {
        let root = try remoteTemporaryDirectory("ledger-health")
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeSessionID = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let child = remoteProcessIdentity(pid: 222, startIdentity: "birth-222", executable: "/fixtures/bin/copilot", generation: "ouro-a")
        var liveIdentity: RemoteProcessIdentity? = child
        var foreground: RemotePresenceEvidence = .absent
        let ledger = RemoteResumeLedger(
            rootURL: root.appendingPathComponent("ledger", isDirectory: true),
            processIdentityForPID: { _, _ in liveIdentity },
            inspectMatchingHerdrForeground: { _ in foreground }
        )
        try ledger.prepare(attemptID: "attempt-a", nativeSessionID: nativeSessionID, profileID: "personal", generation: "ouro-a", paneID: "desk:p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "attempt-a")
        try ledger.recordChild(attemptID: "attempt-a", identity: child)
        try ledger.confirm(nativeSessionID: nativeSessionID, profileID: "personal", generation: "ouro-a", paneID: "desk:p1")

        XCTAssertEqual(try ledger.inspectHealth(), RemoteResumeLedgerInspection(ownedAttemptIDs: ["attempt-a"], reconcileRequiredAttemptIDs: [], unknownAttemptIDs: []))
        liveIdentity = nil
        XCTAssertEqual(try ledger.inspectHealth(), RemoteResumeLedgerInspection(ownedAttemptIDs: [], reconcileRequiredAttemptIDs: ["attempt-a"], unknownAttemptIDs: []))
        foreground = .unavailable
        XCTAssertEqual(try ledger.inspectHealth(), RemoteResumeLedgerInspection(ownedAttemptIDs: [], reconcileRequiredAttemptIDs: [], unknownAttemptIDs: ["attempt-a"]))
        foreground = .live
        XCTAssertEqual(try ledger.inspectHealth(), RemoteResumeLedgerInspection(ownedAttemptIDs: [], reconcileRequiredAttemptIDs: [], unknownAttemptIDs: ["attempt-a"]))
        try ledger.markExited(attemptID: "attempt-a", status: 0)
        XCTAssertTrue(try ledger.inspectHealth().isClear)
    }

    func testReadOnlyLedgerHealthFailsClosedWhenForegroundInspectionThrows() throws {
        let root = try remoteTemporaryDirectory("ledger-health-throw")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil }, inspectMatchingHerdrForeground: { _ in throw RemoteFixtureError.expected })
        try ledger.prepare(attemptID: "attempt-a", nativeSessionID: nil, profileID: "personal", generation: "ouro-a", paneID: "desk:p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "attempt-a")
        XCTAssertEqual(try ledger.inspectHealth().unknownAttemptIDs, ["attempt-a"])
    }

    func testReadOnlyLedgerHealthSortsMultipleOutstandingAttempts() throws {
        let root = try remoteTemporaryDirectory("ledger-health-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil })
        try ledger.prepare(attemptID: "attempt-b", nativeSessionID: nil, profileID: "personal", generation: "ouro-a", paneID: "desk:p2", ownerPID: 1)
        try ledger.prepare(attemptID: "attempt-a", nativeSessionID: nil, profileID: "personal", generation: "ouro-a", paneID: "desk:p1", ownerPID: 1)
        XCTAssertEqual(try ledger.inspectHealth().unknownAttemptIDs, ["attempt-a", "attempt-b"])
    }

    func testLedgerReadOnlyDirectoryValidationRejectsUnavailableWrongKindAndPermissions() throws {
        let root = try remoteTemporaryDirectory("ledger-read-dirs")
        defer { try? FileManager.default.removeItem(at: root) }

        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        assertRemoteErrorContains("unavailable") {
            _ = try RemoteResumeLedger(rootURL: loop.appendingPathComponent("nested"), processIdentityForPID: { _, _ in nil }).record(attemptID: "attempt")
        }

        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        assertRemoteErrorContains("not a directory") {
            _ = try RemoteResumeLedger(rootURL: file, processIdentityForPID: { _, _ in nil }).record(attemptID: "attempt")
        }

        let publicDirectory = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publicDirectory.path)
        assertRemoteErrorContains("0700") {
            _ = try RemoteResumeLedger(rootURL: publicDirectory, processIdentityForPID: { _, _ in nil }).record(attemptID: "attempt")
        }

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: empty.path)
        XCTAssertTrue(try RemoteResumeLedger(rootURL: empty, processIdentityForPID: { _, _ in nil }).inspectHealth().isClear)
    }

    func testExitedAttemptReportsOrdinaryOwnershipAndFailedPreKernelCancellationStaysAmbiguous() throws {
        let root = try remoteTemporaryDirectory("ledger-ownership-residuals")
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("exited"), processIdentityForPID: { _, _ in nil })
        try ledger.prepare(attemptID: "same", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "same")
        try ledger.recordChild(attemptID: "same", identity: remoteProcessIdentity(generation: "g1"))
        try ledger.confirm(nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1")
        try ledger.markExited(attemptID: "same", status: 0)
        assertRemoteErrorContains("already owned") {
            try ledger.prepare(attemptID: "same", nativeSessionID: uuid, profileID: "personal", generation: "g2", paneID: "p2", ownerPID: 2)
        }

        let cancellationRoot = root.appendingPathComponent("cancel")
        let cancellationLedger = RemoteResumeLedger(rootURL: cancellationRoot, processIdentityForPID: { _, _ in nil })
        let supervisor = RemoteChildSupervisor(ledger: cancellationLedger, spawn: { _ in
            let recordURL = cancellationRoot.appendingPathComponent("attempts/pre-kernel.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            object["ownerPID"] = 999
            try remoteJSONData(object).write(to: recordURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            throw RemoteSupervisedSpawnFailure.beforeKernel
        })
        assertRemoteErrorContains("durable intent remains ambiguous") {
            _ = try supervisor.run(request: .init(executable: "/fixtures/bin/copilot"), attemptID: "pre-kernel", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        }
    }

    func testHookValidationRejectsAliasesWrongEventsUnsafeContextAndConflictsWithoutChangingMap() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteSessionMapStore(rootURL: root)
        let registry = try remoteRegistry()
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let fixtures: [(Data, String, String, String, String)] = [
            (try remoteJSONData(["hook_event_name": "Stop", "session_id": uuid]), "personal", "p1", "g", "SessionStart"),
            (try remoteJSONData(["session_id": uuid]), "personal", "p1", "g", "SessionStart"),
            (try remoteJSONData(["hook_event_name": "session_start", "session_id": uuid]), "personal", "p1", "g", "SessionStart"),
            (try remoteJSONData(["hook_event_name": "SessionStart"]), "personal", "p1", "g", "session id"),
            (try remoteJSONData(["hook_event_name": "SessionStart", "session_id": "bad"]), "personal", "p1", "g", "session id"),
            (try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid, "surprise": true]), "personal", "p1", "g", "unknown hook key"),
            (try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid, "sessionId": uuid]), "personal", "p1", "g", "duplicate session id"),
            (try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]), "missing", "p1", "g", "unknown profile"),
            (try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]), "personal", "", "g", "pane id"),
            (try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]), "personal", "bad\npane", "g", "pane id"),
            (try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]), "personal", "p1", "", "generation")
        ]
        for (data, profile, pane, generation, expected) in fixtures {
            XCTAssertTrue(store.record(hookData: data, profileID: profile, paneID: pane, generation: generation, registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError?.contains(expected) == true)
        }
        XCTAssertNil(store.record(hookData: try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]), profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError)
        let prior = try Data(contentsOf: store.mapURL)
        let conflict = store.record(hookData: try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid]), profileID: "emu", paneID: "p2", generation: "g2", registry: registry, ledger: nil, officialHook: { _ in nil })
        XCTAssertTrue(conflict.mappingError?.contains("already mapped") == true)
        XCTAssertEqual(try Data(contentsOf: store.mapURL), prior)
    }

    func testGenerationTransitionRequiresMatchingSupervisedAttemptAndRejectsReplay() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try remoteRegistry()
        let store = RemoteSessionMapStore(rootURL: root.appendingPathComponent("map"))
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let hook = try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid])
        XCTAssertNil(store.record(hookData: hook, profileID: "personal", paneID: "p1", generation: "g0", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError)
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil })
        try ledger.prepare(attemptID: "restore-g1", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "restore-g1")
        try ledger.recordChild(attemptID: "restore-g1", identity: remoteProcessIdentity(generation: "g1"))
        XCTAssertNil(store.record(hookData: hook, profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: ledger, officialHook: { _ in nil }).mappingError)
        XCTAssertEqual(try store.read(registry: registry).first?.generation, "g1")

        let replay = store.record(hookData: hook, profileID: "personal", paneID: "p1", generation: "g0", registry: registry, ledger: ledger, officialHook: { _ in nil })
        XCTAssertTrue(replay.mappingError?.contains("hook does not match") == true)
        XCTAssertEqual(try store.read(registry: registry).first?.generation, "g1")
    }

    func testMapMutationHoldsCrossProcessTransactionLock() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var observedExclusiveLock = false
        let store = RemoteSessionMapStore(rootURL: root, writer: { data, url in
            observedExclusiveLock = try !self.pythonCanLock(root.appendingPathComponent("session-map.lock"))
            try data.write(to: url, options: .atomic)
        })
        let report = store.record(hookData: try remoteJSONData(["hook_event_name": "SessionStart", "session_id": "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"]), profileID: "personal", paneID: "p1", generation: "g1", registry: try remoteRegistry(), ledger: nil, officialHook: { _ in nil })
        XCTAssertNil(report.mappingError)
        XCTAssertTrue(observedExclusiveLock)
    }

    func testResumeLedgerDurableIntentCrashBoundariesAndExactIdentityReconcile() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        var observed: RemoteProcessIdentity?
        var herdrForeground = false
        var first: RemoteResumeLedger? = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in observed }, inspectMatchingHerdrForeground: { _ in herdrForeground ? .live : .absent })
        try first!.prepare(attemptID: "before-intent", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 10)
        first = nil
        let restarted = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in observed }, inspectMatchingHerdrForeground: { _ in herdrForeground ? .live : .absent })
        XCTAssertNoThrow(try restarted.prepare(attemptID: "before-intent", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 11))
        try restarted.markSpawnIntent(attemptID: "before-intent")
        XCTAssertEqual(try restarted.record(attemptID: "before-intent")?.phase, .spawnIntent)
        assertRemoteErrorContains("ambiguous") { try restarted.prepare(attemptID: "retry", nativeSessionID: uuid, profileID: "personal", generation: "g2", paneID: "p1", ownerPID: 12) }

        herdrForeground = true
        assertRemoteErrorContains("live child") { try restarted.reconcile(attemptID: "before-intent", resolution: .abandon) }
        herdrForeground = false
        XCTAssertNoThrow(try restarted.reconcile(attemptID: "before-intent", resolution: .abandon))

        try restarted.prepare(attemptID: "after-kernel", nativeSessionID: uuid, profileID: "personal", generation: "g3", paneID: "p1", ownerPID: 13)
        try restarted.markSpawnIntent(attemptID: "after-kernel")
        let exact = remoteProcessIdentity(pid: 300, startIdentity: "birth-300", generation: "g3")
        try restarted.recordChild(attemptID: "after-kernel", identity: exact)
        observed = exact
        assertRemoteErrorContains("live child") { try restarted.reconcile(attemptID: "after-kernel", resolution: .abandon) }
        observed = remoteProcessIdentity(pid: 300, startIdentity: "reused", generation: "g3")
        XCTAssertNoThrow(try restarted.reconcile(attemptID: "after-kernel", resolution: .abandon))
        XCTAssertFalse(restarted.lockExists(nativeSessionID: uuid))
    }

    func testReconcileRequiresAffirmativeGlobalForegroundAbsenceEvidence() throws {
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        for evidence in ["missing-provider", "scan-failure", "orphan-live"] {
            let root = try remoteTemporaryDirectory(evidence)
            defer { try? FileManager.default.removeItem(at: root) }
            let ledger: RemoteResumeLedger
            if evidence == "missing-provider" {
                ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
            } else if evidence == "scan-failure" {
                ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil }, inspectMatchingHerdrForeground: { _ in throw RemoteFixtureError.expected })
            } else {
                ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil }, inspectMatchingHerdrForeground: { _ in .live })
            }
            try ledger.prepare(attemptID: "intent", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
            try ledger.markSpawnIntent(attemptID: "intent")
            assertRemoteErrorContains(evidence == "orphan-live" ? "live child" : "unavailable") {
                try ledger.reconcile(attemptID: "intent", resolution: .abandon)
            }
            XCTAssertEqual(try ledger.record(attemptID: "intent")?.phase, .spawnIntent)
        }

        let root = try remoteTemporaryDirectory("proven-absent")
        defer { try? FileManager.default.removeItem(at: root) }
        let proven = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil }, inspectMatchingHerdrForeground: { _ in .absent })
        try proven.prepare(attemptID: "intent", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try proven.markSpawnIntent(attemptID: "intent")
        XCTAssertNoThrow(try proven.reconcile(attemptID: "intent", resolution: .abandon))
    }

    func testReconcileInspectsPIDAgainstTheRecordedGeneration() throws {
        let root = try remoteTemporaryDirectory("generation-aware-pid")
        defer { try? FileManager.default.removeItem(at: root) }
        var inspectedGeneration: String?
        let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, generation in
            inspectedGeneration = generation
            return nil
        }, inspectMatchingHerdrForeground: { _ in .absent })
        try ledger.prepare(attemptID: "intent", nativeSessionID: nil, profileID: "personal", generation: "generation-7", paneID: "p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "intent")
        try ledger.recordChild(attemptID: "intent", identity: remoteProcessIdentity(generation: "generation-7"))

        try ledger.reconcile(attemptID: "intent", resolution: .abandon)

        XCTAssertEqual(inspectedGeneration, "generation-7")
    }

    func testRestartedHookConfirmedAttemptRequiresExactChildAndGlobalForegroundAbsence() throws {
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let exact = remoteProcessIdentity(pid: 300, startIdentity: "birth-300", generation: "g1")
        for evidence in ["exact-child-live", "foreground-live", "foreground-unavailable", "absent"] {
            let root = try remoteTemporaryDirectory("hook-confirmed-\(evidence)")
            defer { try? FileManager.default.removeItem(at: root) }
            var initial: RemoteResumeLedger? = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
            try initial!.prepare(attemptID: "confirmed", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
            try initial!.markSpawnIntent(attemptID: "confirmed")
            try initial!.recordChild(attemptID: "confirmed", identity: exact)
            try initial!.confirm(nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1")
            initial = nil

            let restarted = RemoteResumeLedger(
                rootURL: root,
                processIdentityForPID: { _, _ in evidence == "exact-child-live" ? exact : nil },
                inspectMatchingHerdrForeground: { _ in
                    switch evidence {
                    case "foreground-live": return .live
                    case "foreground-unavailable": return .unavailable
                    default: return .absent
                    }
                }
            )
            XCTAssertTrue(try restarted.hasAmbiguousAttempt())
            if evidence == "absent" {
                try restarted.reconcile(attemptID: "confirmed", resolution: .abandon)
                XCTAssertEqual(try restarted.record(attemptID: "confirmed")?.phase, .exited)
                XCTAssertFalse(try restarted.hasAmbiguousAttempt())
                XCTAssertFalse(restarted.lockExists(nativeSessionID: uuid))
            } else {
                assertRemoteErrorContains(evidence.contains("unavailable") ? "unavailable" : "live child") {
                    try restarted.reconcile(attemptID: "confirmed", resolution: .abandon)
                }
                XCTAssertEqual(try restarted.record(attemptID: "confirmed")?.phase, .hookConfirmed)
                XCTAssertTrue(restarted.lockExists(nativeSessionID: uuid))
            }
        }
    }

    func testSpawnNeverRunsWhenAnySpawnIntentDurabilityFenceFails() throws {
        for failedPoint in RemoteDurableWriteCheckpoint.allCases {
            let root = try remoteTemporaryDirectory(failedPoint.rawValue)
            defer { try? FileManager.default.removeItem(at: root) }
            let ledger = RemoteResumeLedger(
                rootURL: root,
                processIdentityForPID: { _, _ in nil },
                inspectMatchingHerdrForeground: { _ in .absent },
                durabilityCheckpoint: { point, _, data in
                    if point == failedPoint, String(decoding: data, as: UTF8.self).contains("spawn_intent") { throw RemoteFixtureError.expected }
                }
            )
            var spawnCalls = 0
            let supervisor = RemoteChildSupervisor(ledger: ledger, spawn: { _ in
                spawnCalls += 1
                return RemoteSupervisedChild(identity: remoteProcessIdentity(), wait: { 0 }, terminate: {})
            })
            assertRemoteErrorContains("persisted") {
                _ = try supervisor.run(request: RemoteProcessRequest(executable: "/fixtures/bin/copilot"), attemptID: "fence", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
            }
            XCTAssertEqual(spawnCalls, 0)
        }
    }

    func testLedgerRejectsWrongTransitionsContextsAndDuplicateOwnership() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
        assertRemoteErrorContains("unsafe attempt") { try ledger.prepare(attemptID: "../bad", nativeSessionID: uuid, profileID: "personal", generation: "g", paneID: "p", ownerPID: 1) }
        assertRemoteErrorContains("invalid native") { try ledger.prepare(attemptID: "bad-uuid", nativeSessionID: "bad", profileID: "personal", generation: "g", paneID: "p", ownerPID: 1) }
        try ledger.prepare(attemptID: "one", nativeSessionID: uuid, profileID: "personal", generation: "g", paneID: "p", ownerPID: 1)
        assertRemoteErrorContains("already owned") { try ledger.prepare(attemptID: "two", nativeSessionID: uuid, profileID: "personal", generation: "g", paneID: "p", ownerPID: 2) }
        assertRemoteErrorContains("spawn_intent") { try ledger.recordChild(attemptID: "one", identity: remoteProcessIdentity(generation: "g")) }
        try ledger.markSpawnIntent(attemptID: "one")
        assertRemoteErrorContains("generation") { try ledger.recordChild(attemptID: "one", identity: remoteProcessIdentity(generation: "wrong")) }
        assertRemoteErrorContains("hook does not match") { try ledger.confirm(nativeSessionID: uuid, profileID: "emu", generation: "g", paneID: "p") }
        assertRemoteErrorContains("only hook_confirmed") { try ledger.markExited(attemptID: "one", status: 1) }
        assertRemoteErrorContains("only prepared") { try ledger.rollbackPrepared(attemptID: "one") }
        assertRemoteErrorContains("missing") { _ = try ledger.record(attemptID: "missing") as RemoteResumeRecord?; try ledger.markSpawnIntent(attemptID: "missing") }
    }

    func testLedgerRejectsUnsafeLookupAndCorruptRecordSchemaStateSizeAndFilesystem() throws {
        let unsafeRoot = try remoteTemporaryDirectory("unsafe-ledger-lookup")
        defer { try? FileManager.default.removeItem(at: unsafeRoot) }
        let unsafeLedger = RemoteResumeLedger(rootURL: unsafeRoot, processIdentityForPID: { _, _ in nil })
        assertRemoteErrorContains("unsafe attempt") { _ = try unsafeLedger.record(attemptID: "../escape") }

        for mutation in ["unknown", "mismatch", "phase", "oversized", "permissions", "symlink", "hardlink"] {
            let root = try remoteTemporaryDirectory("ledger-\(mutation)")
            defer { try? FileManager.default.removeItem(at: root) }
            let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
            try ledger.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "desk:p1", ownerPID: 1)
            let recordURL = root.appendingPathComponent("attempts/attempt.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            if mutation == "unknown" { object["surprise"] = true }
            if mutation == "mismatch" { object["attemptID"] = "other" }
            if mutation == "phase" { object["phase"] = "hook_confirmed" }
            if ["unknown", "mismatch", "phase"].contains(mutation) {
                try remoteJSONData(object).write(to: recordURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            } else if mutation == "oversized" {
                var data = try remoteJSONData(object)
                data.append(Data(repeating: 0x20, count: 1_048_577))
                try data.write(to: recordURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            } else if mutation == "permissions" {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: recordURL.path)
            } else if mutation == "symlink" {
                let target = root.appendingPathComponent("target.json")
                try Data(contentsOf: recordURL).write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try FileManager.default.removeItem(at: recordURL)
                try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: target)
            } else {
                try FileManager.default.linkItem(at: recordURL, to: root.appendingPathComponent("extra-link.json"))
            }
            assertRemoteErrorContains("attempt record") { _ = try ledger.record(attemptID: "attempt") }
        }
    }

    func testLedgerAndAdvisoryLockRejectUnsafeDirectoryAndLockFiles() throws {
        for mutation in ["ledger-mode", "ledger-symlink"] {
            let root = try remoteTemporaryDirectory(mutation)
            defer { try? FileManager.default.removeItem(at: root) }
            let ledgerRoot = root.appendingPathComponent("ledger")
            if mutation == "ledger-mode" {
                try FileManager.default.createDirectory(at: ledgerRoot, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ledgerRoot.path)
            } else {
                let target = root.appendingPathComponent("target")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
                try FileManager.default.createSymbolicLink(at: ledgerRoot, withDestinationURL: target)
            }
            let ledger = RemoteResumeLedger(rootURL: ledgerRoot, processIdentityForPID: { _, _ in nil })
            assertRemoteErrorContains("ledger root") { try ledger.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1) }
        }

        for mutation in ["parent-mode", "lock-mode", "hardlink"] {
            let root = try remoteTemporaryDirectory("lock-\(mutation)")
            defer { try? FileManager.default.removeItem(at: root) }
            let parent = root.appendingPathComponent("locks")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: mutation == "parent-mode" ? 0o755 : 0o700], ofItemAtPath: parent.path)
            let lockURL = parent.appendingPathComponent("uuid.lock")
            if mutation != "parent-mode" {
                let initial = try RemoteAdvisoryLock.acquire(url: lockURL)
                initial.release()
                if mutation == "lock-mode" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockURL.path) }
                if mutation == "hardlink" { try FileManager.default.linkItem(at: lockURL, to: parent.appendingPathComponent("other.lock")) }
            }
            assertRemoteErrorContains(mutation == "parent-mode" ? "lock directory" : "lock file") { _ = try RemoteAdvisoryLock.acquire(url: lockURL) }
        }
    }

    func testAdvisoryUUIDLockExcludesAnotherProcessAndReleasesWithOwner() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("uuid.lock")
        var lock: RemoteAdvisoryLock? = try RemoteAdvisoryLock.acquire(url: lockURL)
        XCTAssertNotNil(lock)
        XCTAssertFalse(try pythonCanLock(lockURL))
        assertRemoteErrorContains("already owned") { _ = try RemoteAdvisoryLock.acquire(url: lockURL) }
        lock = nil
        XCTAssertTrue(try pythonCanLock(lockURL))
    }

    func testSupervisorPersistsIntentBeforeSpawnCancelsOnlySynchronousSpawnFailureAndKeepsAmbiguity() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
        let request = RemoteProcessRequest(executable: "/fixtures/bin/copilot")
        var phaseAtSpawn: RemoteResumePhase?
        let spawnFailure = RemoteChildSupervisor(ledger: ledger, spawn: { _ in
            phaseAtSpawn = try ledger.record(attemptID: "a1")?.phase
            throw RemoteSupervisedSpawnFailure.beforeKernel
        })
        assertRemoteErrorContains("before a kernel child") { _ = try spawnFailure.run(request: request, attemptID: "a1", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1) }
        XCTAssertEqual(phaseAtSpawn, .spawnIntent)
        XCTAssertNil(try ledger.record(attemptID: "a1"))

        for (attemptID, failure): (String, Error) in [("post-kernel", RemoteSupervisedSpawnFailure.afterKernel), ("unknown", RemoteFixtureError.expected)] {
            let ambiguousFailure = RemoteChildSupervisor(ledger: ledger, spawn: { _ in throw failure })
            assertRemoteErrorContains("kernel child may exist") {
                _ = try ambiguousFailure.run(request: request, attemptID: attemptID, nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
            }
            XCTAssertEqual(try ledger.record(attemptID: attemptID)?.phase, .recoveryRequired)
        }

        let noHook = RemoteChildSupervisor(ledger: ledger, spawn: { _ in RemoteSupervisedChild(identity: remoteProcessIdentity(pid: 20, generation: "g2"), wait: { 9 }, terminate: {}) })
        assertRemoteErrorContains("ambiguous") { _ = try noHook.run(request: request, attemptID: "a2", nativeSessionID: uuid, profileID: "personal", generation: "g2", paneID: "p1", ownerPID: 2) }
        XCTAssertEqual(try ledger.record(attemptID: "a2")?.phase, .recoveryRequired)
        XCTAssertTrue(ledger.lockExists(nativeSessionID: uuid))
    }

    func testSupervisorSupportsHookFirstAndPIDFirstAndHoldsLockForChildLifetime() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstUUID = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let secondUUID = "29633c1f-f185-41a7-b628-8f7e54d74422"
        let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
        var phaseAtFinish: RemoteResumePhase?
        let hookFirst = RemoteChildSupervisor(ledger: ledger, spawn: { _ in
            try ledger.confirm(nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1")
            return RemoteSupervisedChild(identity: remoteProcessIdentity(pid: 20), wait: { 0 }, terminate: {}, finish: { phaseAtFinish = try? ledger.record(attemptID: "a1")?.phase })
        })
        XCTAssertEqual(try hookFirst.run(request: RemoteProcessRequest(executable: "/fixtures/bin/copilot"), attemptID: "a1", nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1), 0)
        XCTAssertEqual(phaseAtFinish, .exited)
        XCTAssertFalse(ledger.lockExists(nativeSessionID: firstUUID))

        var heldDuringWait = false
        let pidFirst = RemoteChildSupervisor(ledger: ledger, spawn: { _ in
            RemoteSupervisedChild(identity: remoteProcessIdentity(pid: 21, startIdentity: "birth-21", generation: "g2"), wait: {
                heldDuringWait = ledger.lockExists(nativeSessionID: secondUUID)
                try ledger.confirm(nativeSessionID: secondUUID, profileID: "emu", generation: "g2", paneID: "p2")
                return 0
            }, terminate: {})
        })
        XCTAssertEqual(try pidFirst.run(request: RemoteProcessRequest(executable: "/fixtures/bin/copilot"), attemptID: "a2", nativeSessionID: secondUUID, profileID: "emu", generation: "g2", paneID: "p2", ownerPID: 1), 0)
        XCTAssertTrue(heldDuringWait)

        let thirdUUID = "bed7a650-8f66-4e9b-a0b8-e06b596c939b"
        var terminated = 0
        let waitFailure = RemoteChildSupervisor(ledger: ledger, spawn: { _ in RemoteSupervisedChild(identity: remoteProcessIdentity(pid: 22, startIdentity: "birth-22", generation: "g3"), wait: {
            try ledger.confirm(nativeSessionID: thirdUUID, profileID: "personal", generation: "g3", paneID: "p3")
            throw RemoteFixtureError.expected
        }, terminate: { terminated += 1 }) })
        assertRemoteErrorContains("wait failed") { _ = try waitFailure.run(request: RemoteProcessRequest(executable: "/fixtures/bin/copilot"), attemptID: "a3", nativeSessionID: nil, profileID: "personal", generation: "g3", paneID: "p3", ownerPID: 1) }
        XCTAssertEqual(terminated, 0)
        XCTAssertEqual(try ledger.record(attemptID: "a3")?.phase, .recoveryRequired)
        XCTAssertTrue(ledger.lockExists(nativeSessionID: thirdUUID))
    }

    func testSupervisorMarksRecoveryRequiredWhenConfirmedExitCannotBePersisted() throws {
        let root = try remoteTemporaryDirectory("exit-persistence")
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let ledger = RemoteResumeLedger(
            rootURL: root,
            processIdentityForPID: { _, _ in nil },
            durabilityCheckpoint: { point, _, data in
                if point == .bytesWritten, String(decoding: data, as: UTF8.self).contains("\"phase\":\"exited\"") { throw RemoteFixtureError.expected }
            }
        )
        let supervisor = RemoteChildSupervisor(ledger: ledger, spawn: { _ in
            RemoteSupervisedChild(identity: remoteProcessIdentity(generation: "g1"), wait: {
                try ledger.confirm(nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1")
                return 0
            }, terminate: {})
        })

        assertRemoteErrorContains("recovery") {
            _ = try supervisor.run(request: RemoteProcessRequest(executable: "/fixtures/bin/copilot"), attemptID: "exit-fence", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        }
        XCTAssertEqual(try ledger.record(attemptID: "exit-fence")?.phase, .recoveryRequired)
        XCTAssertTrue(ledger.lockExists(nativeSessionID: uuid))
    }

    func testDurableFileRejectsUnavailablePathsAndReportsDeterministicIOFailures() throws {
        let root = try remoteTemporaryDirectory("durable-failures")
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = root.appendingPathComponent("empty")
        try RemoteDurableFile.write(Data(), to: empty)
        XCTAssertEqual(try Data(contentsOf: empty), Data())

        let blockedParent = root.appendingPathComponent("blocked-parent")
        try Data().write(to: blockedParent)
        assertRemoteErrorContains("directory is not a directory") {
            try RemoteDurableFile.write(Data("x".utf8), to: blockedParent.appendingPathComponent("child"))
        }

        let readOnlyParent = root.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: readOnlyParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyParent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyParent.path) }
        assertRemoteErrorContains("directory is unavailable") {
            try RemoteDurableFile.write(Data("x".utf8), to: readOnlyParent.appendingPathComponent("missing/child"))
        }

        let unavailable = root.appendingPathComponent(String(repeating: "x", count: 256))
        assertRemoteErrorContains("destination is unavailable") {
            try RemoteDurableFile.write(Data("x".utf8), to: unavailable)
        }

        let cannotOpenTemporary = root.appendingPathComponent(String(repeating: "x", count: 220))
        assertRemoteErrorContains("temporary file could not be opened") {
            try RemoteDurableFile.write(Data("x".utf8), to: cannotOpenTemporary)
        }

        for (checkpoint, expected) in [(RemoteDurableWriteCheckpoint.temporaryOpened, "write was incomplete"), (.bytesWritten, "file fsync failed"), (.fileSynced, "file close failed")] {
            let destination = root.appendingPathComponent("closed-\(checkpoint.rawValue)")
            assertRemoteErrorContains(expected) {
                try RemoteDurableFile.write(Data("payload".utf8), to: destination) { point, _, _ in
                    if point == checkpoint { XCTAssertTrue(self.closeTemporaryDescriptor(in: root, destinationName: destination.lastPathComponent)) }
                }
            }
        }

        let renameDestination = root.appendingPathComponent("rename-failure")
        assertRemoteErrorContains("rename failed") {
            try RemoteDurableFile.write(Data("payload".utf8), to: renameDestination) { point, _, _ in
                if point == .fileSynced { try FileManager.default.createDirectory(at: renameDestination, withIntermediateDirectories: false) }
            }
        }

        let movedRoot = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-moved")
        defer { try? FileManager.default.removeItem(at: movedRoot) }
        let directoryOpenDestination = root.appendingPathComponent("directory-open-failure")
        assertRemoteErrorContains("directory could not be opened") {
            try RemoteDurableFile.write(Data("payload".utf8), to: directoryOpenDestination) { point, _, _ in
                if point == .renamed {
                    try FileManager.default.moveItem(at: root, to: movedRoot)
                    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: movedRoot)
                }
            }
        }
    }

    func testSessionMapCoversIdempotenceStrictJSONAndUnavailableRoots() throws {
        let root = try remoteTemporaryDirectory("map-residuals")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try remoteRegistry()
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let hook = try remoteJSONData(["hook_event_name": "SessionStart", "session_id": uuid])
        let ledger = RemoteResumeLedger(rootURL: root.appendingPathComponent("ledger"), processIdentityForPID: { _, _ in nil })
        try ledger.prepare(attemptID: "idempotent", nativeSessionID: uuid, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "idempotent")
        try ledger.recordChild(attemptID: "idempotent", identity: remoteProcessIdentity(generation: "g1"))
        let store = RemoteSessionMapStore(rootURL: root.appendingPathComponent("map"))
        XCTAssertNil(store.record(hookData: hook, profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: ledger, officialHook: { _ in nil }).mappingError)
        XCTAssertNil(store.record(hookData: hook, profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: ledger, officialHook: { _ in nil }).mappingError)

        let duplicateAliases = try remoteJSONData(["hook_event_name": "SessionStart", "hookEventName": "SessionStart", "session_id": uuid])
        XCTAssertTrue(store.record(hookData: duplicateAliases, profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError?.contains("duplicate hook event") == true)
        XCTAssertTrue(store.record(hookData: try JSONSerialization.data(withJSONObject: []), profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError?.contains("must be an object") == true)

        let pending = store.rootURL.appendingPathComponent("session-map.pending.json")
        try Data().write(to: pending)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        XCTAssertTrue(store.record(hookData: hook, profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError?.contains("recovery required") == true)

        let blockedParent = root.appendingPathComponent("blocked-map-parent")
        try Data().write(to: blockedParent)
        let unavailableStore = RemoteSessionMapStore(rootURL: blockedParent.appendingPathComponent("map"))
        XCTAssertTrue(unavailableStore.record(hookData: hook, profileID: "personal", paneID: "p1", generation: "g1", registry: registry, ledger: nil, officialHook: { _ in nil }).mappingError?.contains("root is unavailable") == true)

        let rootFile = root.appendingPathComponent("root-file")
        try Data().write(to: rootFile)
        assertRemoteErrorContains("root is not a directory") {
            _ = try RemoteSessionMapStore.read(mapURL: rootFile.appendingPathComponent("session-map.json"), registry: registry)
        }
    }

    func testSessionMapRejectsEveryResidualSerializationShapeAndSortsEntries() throws {
        let root = try remoteTemporaryDirectory("map-json-residuals")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try remoteRegistry()
        let uuid1 = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let uuid2 = "29633c1f-f185-41a7-b628-8f7e54d74422"
        let cases: [(Data, String)] = [
            (try JSONSerialization.data(withJSONObject: []), "must be an object"),
            (try remoteJSONData(["schemaVersion": 1, "entries": "wrong"]), "entries are malformed"),
            (try remoteJSONData(["schemaVersion": "wrong", "entries": []]), "JSON is malformed"),
            (Data("{".utf8), "JSON is malformed"),
            (Data(repeating: 0x20, count: RemoteSessionMapStore.maximumMapBytes + 1), "byte bound")
        ]
        for (index, fixture) in cases.enumerated() {
            let directory = root.appendingPathComponent("case-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let mapURL = directory.appendingPathComponent("session-map.json")
            try fixture.0.write(to: mapURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
            assertRemoteErrorContains(fixture.1) { _ = try RemoteSessionMapStore.read(mapURL: mapURL, registry: registry) }
        }

        let sortedDirectory = root.appendingPathComponent("sorted")
        try FileManager.default.createDirectory(at: sortedDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sortedDirectory.path)
        let sortedMap = sortedDirectory.appendingPathComponent("session-map.json")
        try remoteJSONData(["schemaVersion": 1, "entries": [
            ["sessionID": uuid1, "profileID": "personal", "paneID": "p1", "generation": "g1"],
            ["sessionID": uuid2, "profileID": "emu", "paneID": "p2", "generation": "g2"]
        ]]).write(to: sortedMap)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sortedMap.path)
        XCTAssertEqual(try RemoteSessionMapStore.read(mapURL: sortedMap, registry: registry).map(\.sessionID), [uuid2, uuid1])
    }

    func testSessionMapRejectsARegularPrivateFileThatCannotBeRead() throws {
        let root = try remoteTemporaryDirectory("map-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = root.appendingPathComponent("session-map.json")
        try remoteJSONData(["schemaVersion": 1, "entries": []]).write(to: mapURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
        try addDenyACL("read", to: mapURL)
        defer { try? removeACL(from: mapURL) }

        assertRemoteErrorContains("missing or unreadable") {
            _ = try RemoteSessionMapStore.read(mapURL: mapURL, registry: remoteRegistry())
        }
    }

    func testLedgerCoversResidualTransitionsQueriesAndLockMigrationConflict() throws {
        let root = try remoteTemporaryDirectory("ledger-residuals")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstUUID = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let secondUUID = "29633c1f-f185-41a7-b628-8f7e54d74422"
        let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil }, inspectMatchingHerdrForeground: { _ in .absent })
        XCTAssertNil(try ledger.record(attemptID: "missing"))
        XCTAssertTrue(ledger.lockExists(nativeSessionID: "not-a-uuid"))
        assertRemoteErrorContains("owner pid") { try ledger.prepare(attemptID: "owner", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 0) }

        try ledger.prepare(attemptID: "prepared", nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        assertRemoteErrorContains("already owned") { try ledger.prepare(attemptID: "prepared", nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 2) }
        XCTAssertFalse(try ledger.hasAmbiguousAttempt())
        try ledger.rollbackPrepared(attemptID: "prepared")
        XCTAssertNil(try ledger.record(attemptID: "prepared"))

        try ledger.prepare(attemptID: "intent", nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try ledger.markSpawnIntent(attemptID: "intent")
        assertRemoteErrorContains("not prepared") { try ledger.markSpawnIntent(attemptID: "intent") }
        assertRemoteErrorContains("cancelable") { try ledger.cancelSynchronousSpawnFailure(attemptID: "intent", ownerPID: 2) }
        XCTAssertTrue(try ledger.hasAmbiguousAttempt())
        XCTAssertTrue(try ledger.hasOutstandingOwnership(nativeSessionIDs: [firstUUID]))
        XCTAssertFalse(try ledger.hasOutstandingOwnership(nativeSessionIDs: [secondUUID]))
        assertRemoteErrorContains("ambiguous") { try ledger.prepare(attemptID: "intent", nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 2) }
        try ledger.reconcile(attemptID: "intent", resolution: .abandon)
        assertRemoteErrorContains("post-intent") { try ledger.markRecoveryRequired(attemptID: "intent") }
        assertRemoteErrorContains("ambiguous spawned child") { try ledger.reconcile(attemptID: "intent", resolution: .abandon) }

        let migration = RemoteResumeLedger(rootURL: root.appendingPathComponent("migration"), processIdentityForPID: { _, _ in nil })
        try migration.prepare(attemptID: "provisional", nativeSessionID: nil, profileID: "personal", generation: "g2", paneID: "p2", ownerPID: 1)
        try migration.markSpawnIntent(attemptID: "provisional")
        let conflictingLock = try RemoteAdvisoryLock.acquire(url: migration.rootURL.appendingPathComponent("locks/\(secondUUID).lock"))
        defer { conflictingLock.release() }
        assertRemoteErrorContains("already owned") { try migration.confirm(nativeSessionID: secondUUID, profileID: "personal", generation: "g2", paneID: "p2") }
    }

    func testLedgerCoversMissingStorageFailedPrepareAndExactNativeValidation() throws {
        let root = try remoteTemporaryDirectory("ledger-missing-residuals")
        defer { try? FileManager.default.removeItem(at: root) }
        let missingLedger = RemoteResumeLedger(rootURL: root.appendingPathComponent("missing"), processIdentityForPID: { _, _ in nil })
        XCTAssertNil(try missingLedger.record(attemptID: "attempt"))

        let emptyLedger = RemoteResumeLedger(rootURL: root.appendingPathComponent("empty"), processIdentityForPID: { _, _ in nil })
        XCTAssertFalse(try emptyLedger.hasAmbiguousAttempt())

        let failedRoot = root.appendingPathComponent("failed-prepare")
        let failedPrepare = RemoteResumeLedger(rootURL: failedRoot, processIdentityForPID: { _, _ in nil }, durabilityCheckpoint: { _, _, _ in throw RemoteFixtureError.expected })
        assertRemoteErrorContains("persisted") {
            try failedPrepare.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedRoot.appendingPathComponent("locks/attempt-attempt.lock").path))

        let firstUUID = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let secondUUID = "29633c1f-f185-41a7-b628-8f7e54d74422"
        let exact = RemoteResumeLedger(rootURL: root.appendingPathComponent("exact"), processIdentityForPID: { _, _ in nil })
        try exact.prepare(attemptID: "attempt", nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try exact.markSpawnIntent(attemptID: "attempt")
        assertRemoteErrorContains("expected native session") { try exact.confirm(nativeSessionID: secondUUID, profileID: "personal", generation: "g1", paneID: "p1") }
        assertRemoteErrorContains("expected native session") { try exact.validateHookContext(nativeSessionID: secondUUID, profileID: "personal", generation: "g1", paneID: "p1") }
        try exact.recordChild(attemptID: "attempt", identity: remoteProcessIdentity(generation: "g1"))
        try exact.confirm(nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1")
        assertRemoteErrorContains("ambiguous") {
            try exact.prepare(attemptID: "attempt", nativeSessionID: firstUUID, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 2)
        }
    }

    func testLedgerRejectsResidualCorruptRecordShapesAndFilesystemFailures() throws {
        let root = try remoteTemporaryDirectory("record-residuals")
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "8d5177d6-b6d1-4b5f-a546-564ed0ef8748"
        let mutations: [(String, (inout [String: Any]) -> Void, String)] = [
            ("wrong-child-keys", { $0["childIdentity"] = ["pid": 1] }, "child identity keys"),
            ("wrong-type", { $0["ownerPID"] = "one" }, "record is corrupt"),
            ("unsafe-pane", { $0["paneID"] = "/bad" }, "unsafe pane id"),
            ("owner", { $0["ownerPID"] = 0 }, "owner pid"),
            ("native", { $0["nativeSessionID"] = uuid.uppercased() }, "native session evidence"),
            ("child", { $0["phase"] = "spawned_unconfirmed"; $0["childIdentity"] = ["pid": 0, "startIdentity": "birth", "executable": "/bin/copilot", "generation": "g1"] }, "child identity is invalid")
        ]
        for (name, mutate, expected) in mutations {
            let ledgerRoot = root.appendingPathComponent(name)
            let ledger = RemoteResumeLedger(rootURL: ledgerRoot, processIdentityForPID: { _, _ in nil })
            try ledger.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
            let recordURL = ledgerRoot.appendingPathComponent("attempts/attempt.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            mutate(&object)
            try remoteJSONData(object).write(to: recordURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            assertRemoteErrorContains(expected) { _ = try ledger.record(attemptID: "attempt") }
        }

        for (name, data, expected) in [
            ("array", try JSONSerialization.data(withJSONObject: []), "must be an object"),
            ("malformed", Data("{".utf8), "record is corrupt")
        ] {
            let ledgerRoot = root.appendingPathComponent(name)
            let ledger = RemoteResumeLedger(rootURL: ledgerRoot, processIdentityForPID: { _, _ in nil })
            try ledger.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
            let recordURL = ledgerRoot.appendingPathComponent("attempts/attempt.json")
            try data.write(to: recordURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            assertRemoteErrorContains(expected) { _ = try ledger.record(attemptID: "attempt") }
        }

        let unexpectedRoot = root.appendingPathComponent("unexpected-entry")
        let unexpected = RemoteResumeLedger(rootURL: unexpectedRoot, processIdentityForPID: { _, _ in nil })
        try unexpected.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try Data().write(to: unexpectedRoot.appendingPathComponent("attempts/surprise.txt"))
        assertRemoteErrorContains("unexpected entry") { _ = try unexpected.hasAmbiguousAttempt() }

        let unreadableRoot = root.appendingPathComponent("unreadable-record")
        let unreadable = RemoteResumeLedger(rootURL: unreadableRoot, processIdentityForPID: { _, _ in nil })
        try unreadable.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        let attemptsURL = unreadableRoot.appendingPathComponent("attempts")
        let attemptsMoved = unreadableRoot.appendingPathComponent("attempts-real")
        try FileManager.default.moveItem(at: attemptsURL, to: attemptsMoved)
        try FileManager.default.createSymbolicLink(at: attemptsURL, withDestinationURL: attemptsURL)
        assertRemoteErrorContains("unreadable") { _ = try unreadable.record(attemptID: "attempt") }
        try FileManager.default.removeItem(at: attemptsURL)
        try FileManager.default.moveItem(at: attemptsMoved, to: attemptsURL)

        let rollbackRoot = root.appendingPathComponent("rollback-failure")
        let rollback = RemoteResumeLedger(rootURL: rollbackRoot, processIdentityForPID: { _, _ in nil })
        try rollback.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rollbackRoot.appendingPathComponent("attempts").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rollbackRoot.appendingPathComponent("attempts").path) }
        assertRemoteErrorContains("rollback failed") { try rollback.rollbackPrepared(attemptID: "attempt") }
    }

    func testLedgerRejectsUnreadablePrivateRecordAndUnlistablePrivateDirectory() throws {
        let root = try remoteTemporaryDirectory("ledger-acl-failures")
        defer { try? FileManager.default.removeItem(at: root) }

        let unreadableRoot = root.appendingPathComponent("unreadable")
        let unreadable = RemoteResumeLedger(rootURL: unreadableRoot, processIdentityForPID: { _, _ in nil })
        try unreadable.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        let recordURL = unreadableRoot.appendingPathComponent("attempts/attempt.json")
        try addDenyACL("read", to: recordURL)
        assertRemoteErrorContains("record is unreadable") { _ = try unreadable.record(attemptID: "attempt") }
        try removeACL(from: recordURL)

        let unlistableRoot = root.appendingPathComponent("unlistable")
        let unlistable = RemoteResumeLedger(rootURL: unlistableRoot, processIdentityForPID: { _, _ in nil })
        try unlistable.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        let attemptsURL = unlistableRoot.appendingPathComponent("attempts")
        try addDenyACL("list", to: attemptsURL)
        assertRemoteErrorContains("records are corrupt") { _ = try unlistable.hasAmbiguousAttempt() }
        try removeACL(from: attemptsURL)
    }

    func testDirectoryAndAdvisoryLockRejectNonENOENTAndCreateFailures() throws {
        let root = try remoteTemporaryDirectory("filesystem-errors")
        defer { try? FileManager.default.removeItem(at: root) }

        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        assertRemoteErrorContains("directory is unavailable") {
            try RemoteDurableFile.write(Data("x".utf8), to: loop.appendingPathComponent("parent/file"))
        }

        let tooLongLock = root.appendingPathComponent(String(repeating: "x", count: 256))
        assertRemoteErrorContains("lock file is unavailable") { _ = try RemoteAdvisoryLock.acquire(url: tooLongLock) }

        let aclDirectory = root.appendingPathComponent("acl-lock")
        try FileManager.default.createDirectory(at: aclDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: aclDirectory.path)
        try addDenyACL("add_file", to: aclDirectory)
        assertRemoteErrorContains("could not be opened") { _ = try RemoteAdvisoryLock.acquire(url: aclDirectory.appendingPathComponent("lock")) }
        try removeACL(from: aclDirectory)
    }

    func testInheritedACLsClosePostCreationStatAndOpenFileStatFailures() throws {
        let root = try remoteTemporaryDirectory("inherited-acl-failures")
        defer { try? FileManager.default.removeItem(at: root) }

        let directoryParent = root.appendingPathComponent("directory-parent")
        try FileManager.default.createDirectory(at: directoryParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryParent.path)
        try addDenyACL("readattr,directory_inherit,only_inherit", to: directoryParent)
        assertRemoteErrorContains("directory is unavailable") {
            try RemoteDurableFile.write(Data("x".utf8), to: directoryParent.appendingPathComponent("created/file"))
        }
        try removeACLRecursively(from: directoryParent)

        for name in ["durable", "lock"] {
            let fileParent = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: fileParent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileParent.path)
            if name == "durable" {
                try addDenyACL("readattr,file_inherit,only_inherit", to: fileParent)
                assertRemoteErrorContains("temporary file is not private") { try RemoteDurableFile.write(Data("x".utf8), to: fileParent.appendingPathComponent("value")) }
                try removeACLRecursively(from: fileParent)
            } else {
                let priorMask = Darwin.umask(0o777)
                defer { Darwin.umask(priorMask) }
                assertRemoteErrorContains("lock file must be a private regular file") { _ = try RemoteAdvisoryLock.acquire(url: fileParent.appendingPathComponent("value.lock")) }
            }
        }
    }

    func testLedgerDetectsRecordRemovedAfterDirectorySnapshot() throws {
        let root = try remoteTemporaryDirectory("record-disappears")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RemoteResumeLedger(rootURL: root, processIdentityForPID: { _, _ in nil })
        try ledger.prepare(attemptID: "attempt", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        let recordURL = root.appendingPathComponent("attempts/attempt.json")
        let awayURL = root.appendingPathComponent("attempt-away.json")
        let stopURL = root.appendingPathComponent("stop")
        let toggler = Process()
        toggler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        toggler.arguments = ["-c", "import os,sys,time\nsrc,away,stop=sys.argv[1:]\nwhile not os.path.exists(stop):\n try: os.rename(src,away)\n except FileNotFoundError: pass\n time.sleep(0.00005)\n try: os.rename(away,src)\n except FileNotFoundError: pass\n time.sleep(0.00005)", recordURL.path, awayURL.path, stopURL.path]
        try toggler.run()
        defer {
            try? Data().write(to: stopURL)
            toggler.waitUntilExit()
            if FileManager.default.fileExists(atPath: awayURL.path) { try? FileManager.default.moveItem(at: awayURL, to: recordURL) }
        }

        var observedDisappearance = false
        for _ in 0..<10_000 where !observedDisappearance {
            do { _ = try ledger.hasAmbiguousAttempt() }
            catch { observedDisappearance = error.localizedDescription.contains("disappeared during read") }
        }
        XCTAssertTrue(observedDisappearance)
    }

    func testDurableFileReportsDirectorySyncFailureWhenItsOpenedDescriptorIsInvalidated() throws {
        let root = try remoteTemporaryDirectory("directory-sync-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        var observedSyncFailure = false
        for attempt in 0..<10 where !observedSyncFailure {
            var closer: RemoteTestDescriptorCloser?
            var fillers: [Int32] = []
            var originalLimit = rlimit()
            var limitChanged = false
            do {
                try RemoteDurableFile.write(Data("payload".utf8), to: root.appendingPathComponent("value-\(attempt)")) { point, _, _ in
                    if point == .renamed {
                        let candidate = RemoteTestDescriptorCloser()
                        candidate.start()
                        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &originalLimit), 0)
                        var constrained = originalLimit
                        constrained.rlim_cur = min(originalLimit.rlim_cur, 128)
                        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &constrained), 0)
                        limitChanged = true
                        while true {
                            let filler = Darwin.open("/dev/null", O_RDONLY)
                            if filler < 0 { break }
                            fillers.append(filler)
                        }
                        let descriptor = try XCTUnwrap(fillers.popLast())
                        Darwin.close(descriptor)
                        candidate.arm(descriptor: descriptor)
                        closer = candidate
                    }
                }
            } catch {
                observedSyncFailure = error.localizedDescription.contains("directory fsync failed")
            }
            closer?.stop()
            fillers.forEach { Darwin.close($0) }
            if limitChanged { XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &originalLimit), 0) }
        }
        XCTAssertTrue(observedSyncFailure)
    }

    func testSupervisorKeepsDurableAmbiguityWhenCancellationOrChildIdentityRecordingFails() throws {
        let root = try remoteTemporaryDirectory("supervisor-residuals")
        defer { try? FileManager.default.removeItem(at: root) }
        let request = RemoteProcessRequest(executable: "/fixtures/bin/copilot")
        let cancellationLedger = RemoteResumeLedger(rootURL: root.appendingPathComponent("cancel"), processIdentityForPID: { _, _ in nil })
        let cancellationFailure = RemoteChildSupervisor(ledger: cancellationLedger, spawn: { _ in
            try cancellationLedger.markRecoveryRequired(attemptID: "cancel")
            throw RemoteFixtureError.expected
        })
        assertRemoteErrorContains("durable intent remains ambiguous") {
            _ = try cancellationFailure.run(request: request, attemptID: "cancel", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        }

        let identityLedger = RemoteResumeLedger(rootURL: root.appendingPathComponent("identity"), processIdentityForPID: { _, _ in nil })
        let identityFailure = RemoteChildSupervisor(ledger: identityLedger, spawn: { _ in
            RemoteSupervisedChild(identity: remoteProcessIdentity(generation: "wrong"), wait: { 0 }, terminate: {})
        })
        assertRemoteErrorContains("exact process identity") {
            _ = try identityFailure.run(request: request, attemptID: "identity", nativeSessionID: nil, profileID: "personal", generation: "g1", paneID: "p1", ownerPID: 1)
        }
        XCTAssertEqual(try identityLedger.record(attemptID: "identity")?.phase, .recoveryRequired)
    }

    func testShellBootstrapSourcesUserStartupBeforeAbsoluteFinalDispatcher() throws {
        let files = try RemoteShellBootstrap.render(zshExecutable: "/bin/zsh", realZDOTDIR: "/Users/example", ouroZDOTDIR: "/opt/ouro/zdotdir", helperPath: "/opt/ouro/runtime/OuroWorkbenchRemote", configPath: "/opt/ouro/config/profiles.json", sessionMapPath: "/opt/ouro/state/session-map.json")
        let zshrc = try XCTUnwrap(String(data: files[".zshrc"]!, encoding: .utf8))
        let profileRange = try XCTUnwrap(zshrc.range(of: "source '/Users/example/.zprofile'"))
        let rcRange = try XCTUnwrap(zshrc.range(of: "source '/Users/example/.zshrc'"))
        let functionRange = try XCTUnwrap(zshrc.range(of: "function copilot"))
        XCTAssertLessThan(profileRange.lowerBound, rcRange.lowerBound)
        XCTAssertLessThan(rcRange.lowerBound, functionRange.lowerBound)
        XCTAssertTrue(zshrc.contains("'/opt/ouro/runtime/OuroWorkbenchRemote' dispatch"))
        XCTAssertTrue(zshrc.contains("'/opt/ouro/runtime/OuroWorkbenchRemote' wrapper-handshake"))
        XCTAssertTrue(zshrc.contains("--zdotdir '/opt/ouro/zdotdir'"))
        XCTAssertTrue(zshrc.contains("--function-body \"${functions[copilot]}\""))
        XCTAssertTrue(zshrc.contains("\"$@\""))
        XCTAssertFalse(zshrc.contains("eval"))
        XCTAssertEqual(String(data: files[".zshenv"]!, encoding: .utf8), "source '/Users/example/.zshenv' 2>/dev/null || true\n")
        assertRemoteErrorContains("absolute path") { _ = try RemoteShellBootstrap.render(zshExecutable: "zsh", realZDOTDIR: "/Users/example", ouroZDOTDIR: "/ouro", helperPath: "/helper", configPath: "/config", sessionMapPath: "/map") }
        XCTAssertEqual(RemoteShellBootstrap.quote("a'b"), "'a'\\''b'")
    }

    private func mode(at url: URL) -> mode_t {
        var value = stat()
        XCTAssertEqual(lstat(url.path, &value), 0)
        return value.st_mode & mode_t(0o777)
    }

    private func pythonCanLock(_ url: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'a');\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(0)\nexcept BlockingIOError: sys.exit(9)", url.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func closeTemporaryDescriptor(in directory: URL, destinationName: String) -> Bool {
        let marker = "/.\(destinationName)."
        for descriptor in 3..<Int32(OPEN_MAX) {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = path.withUnsafeMutableBufferPointer { buffer in fcntl(descriptor, F_GETPATH, buffer.baseAddress!) }
            let end = path.firstIndex(of: 0) ?? path.endIndex
            let value = String(decoding: path[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            if result == 0, value.contains(directory.lastPathComponent), value.contains(marker), value.hasSuffix(".tmp") {
                return Darwin.close(descriptor) == 0
            }
        }
        return false
    }

    private func addDenyACL(_ permission: String, to url: URL) throws {
        try runChmod(["+a", "everyone deny \(permission)", url.path])
    }

    private func removeACL(from url: URL) throws {
        try runChmod(["-N", url.path])
    }

    private func removeACLRecursively(from url: URL) throws {
        try runChmod(["-RN", url.path])
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

private final class RemoteTestDescriptorCloser: @unchecked Sendable {
    private var descriptor: Int32 = -1
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let armed = DispatchSemaphore(value: 0)
    private let spinning = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var running = true

    func start() {
        Thread.detachNewThread { [self] in
            started.signal()
            armed.wait()
            spinning.signal()
            defer { finished.signal() }
            while isRunning {
                Darwin.close(descriptor)
            }
        }
        started.wait()
    }

    func arm(descriptor: Int32) {
        self.descriptor = descriptor
        armed.signal()
        spinning.wait()
        usleep(1_000)
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        finished.wait()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}
