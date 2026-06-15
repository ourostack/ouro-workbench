import XCTest
@testable import OuroWorkbenchCore

final class DaemonLivenessTests: XCTestCase {
    func testProbeReportsUpWhenReachabilitySucceeds() async {
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000_000),
            reachability: { _ in true }
        )

        let liveness = await probe.probe()

        XCTAssertEqual(liveness, .up)
    }

    func testProbeReportsDownWhenReachabilityFails() async {
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000_000),
            reachability: { _ in false }
        )

        let liveness = await probe.probe()

        XCTAssertEqual(liveness, .down)
    }

    func testProbeTreatsTimeoutAsDownWithoutThrowing() async {
        // Reachability never completes within the probe window; probe must resolve to .down,
        // never surface a thrown error to the caller.
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 50_000_000),
            reachability: { _ in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return true
            }
        )

        let liveness = await probe.probe()

        XCTAssertEqual(liveness, .down)
    }

    func testProbeTreatsReachabilityThrowAsDown() async {
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000_000),
            reachability: { _ in throw DaemonLivenessTestError.boom }
        )

        let liveness = await probe.probe()

        XCTAssertEqual(liveness, .down)
    }

    func testReachabilityClosureReceivesConfiguredTimeout() async {
        let timeout = LockedBox<TimeInterval?>(nil)
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 250_000_000),
            reachability: { duration in
                timeout.value = duration
                return true
            }
        )

        _ = await probe.probe()

        XCTAssertEqual(timeout.value, 0.25)
    }

    // MARK: - Recovery-truth classification

    func testClassifyResumedWhenAlreadyUp() {
        XCTAssertEqual(
            DaemonRecoveryTruth.classify(wasUpBeforeStart: true, isUpAfterStart: true),
            .resumed
        )
    }

    func testClassifyRespawnedWhenWasDownAndCameUp() {
        XCTAssertEqual(
            DaemonRecoveryTruth.classify(wasUpBeforeStart: false, isUpAfterStart: true),
            .respawned
        )
    }

    func testClassifyNeedsManualWhenStillDownAfterStart() {
        XCTAssertEqual(
            DaemonRecoveryTruth.classify(wasUpBeforeStart: false, isUpAfterStart: false),
            .needsManual
        )
    }

    func testClassifyNeedsManualWhenWasUpButProbeNowDown() {
        // A daemon that read up but is unreachable on the verify probe is not a false "survived".
        XCTAssertEqual(
            DaemonRecoveryTruth.classify(wasUpBeforeStart: true, isUpAfterStart: false),
            .needsManual
        )
    }

    func testRecoveryTruthAuditLineUsesCliVerbsNotHumanVoice() {
        // Audit lines are the ONE place ouro verbs are allowed; assert they carry the verb
        // so the human-facing layer can stay seam-free while audit stays precise.
        XCTAssertTrue(DaemonRecoveryTruth.respawned.auditDetail.contains("ouro up"))
        XCTAssertFalse(DaemonRecoveryTruth.resumed.auditDetail.contains("ouro up"))
        XCTAssertEqual(
            DaemonRecoveryTruth.needsManual.auditDetail,
            "Daemon still unreachable after start attempt; manual recovery required."
        )
    }

    func testDefaultReachabilityProbeURLIsLocalMailbox() {
        XCTAssertEqual(
            DaemonLivenessConfiguration().reachabilityURL.absoluteString,
            "http://127.0.0.1:6876/api/machine"
        )
    }

    func testDefaultReachabilityReturnsFalseForNonHTTPResponse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonLivenessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("machine.json")
        try Data(#"{"ok":true}"#.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let reachable = try await DaemonLivenessProbe.defaultReachability(url: fileURL, timeoutSeconds: 0.1)

        XCTAssertFalse(reachable)
    }

    func testDefaultReachabilityWrapperMapsLocalConnectionFailureToThrow() async {
        await XCTAssertThrowsErrorAsync(try await DaemonLivenessProbe.defaultReachability(timeoutSeconds: 0.001)) { _ in }
    }

    // MARK: - Synchronous probe (the MCP request-loop bridge)

    func testProbeSynchronouslyReportsUpWhenSyncReachabilitySucceeds() {
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000_000),
            syncReachability: { _ in true }
        )

        XCTAssertEqual(probe.probeSynchronously(), .up)
    }

    func testProbeSynchronouslyReportsDownWhenSyncReachabilityFails() {
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000_000),
            syncReachability: { _ in false }
        )

        XCTAssertEqual(probe.probeSynchronously(), .down)
    }

    func testProbeSynchronouslyTreatsAHangAsDownWithoutBlockingForever() {
        // A sync reachability that hangs past the budget must resolve to .down via the
        // semaphore timeout backstop, not wedge the (blocked) caller.
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 100_000_000),
            syncReachability: { _ in
                Thread.sleep(forTimeInterval: 5)
                return true
            }
        )

        let start = Date()
        let liveness = probe.probeSynchronously()
        XCTAssertEqual(liveness, .down)
        // Must give up well before the 5s hang (budget 0.1s + 0.5s backstop).
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testProbeSynchronouslyPassesConfiguredTimeoutToSyncReachability() {
        let seen = LockedBox<TimeInterval?>(nil)
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 250_000_000),
            syncReachability: { duration in
                seen.value = duration
                return true
            }
        )

        _ = probe.probeSynchronously()

        XCTAssertEqual(seen.value, 0.25)
    }

    func testDefaultSyncReachabilityReturnsFalseForNonHTTPResponseAndWrapperFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonLivenessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("machine.json")
        try Data(#"{"ok":true}"#.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(DaemonLivenessProbe.defaultSyncReachability(url: fileURL, timeoutSeconds: 0.1))
        XCTAssertFalse(DaemonLivenessProbe.defaultSyncReachability(timeoutSeconds: 0.001))
        XCTAssertFalse(DaemonLivenessProbe.defaultSyncReachability(url: fileURL, timeoutSeconds: -1))
    }

    func testDaemonManagerDefaultInitializerAndDetachedStartUsesOuroFromPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonLivenessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ouro = root.appendingPathComponent("ouro")
        try """
        #!/usr/bin/env bash
        exit 0
        """.write(to: ouro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ouro.path)
        let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(root.path):\(previousPath)", 1)
        defer {
            setenv("PATH", previousPath, 1)
            try? FileManager.default.removeItem(at: root)
        }

        _ = DaemonManager()
        try await DaemonManager.detachedStart()
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ errorHandler: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}

private enum DaemonLivenessTestError: Error {
    case boom
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
