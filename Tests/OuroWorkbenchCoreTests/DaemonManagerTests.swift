import XCTest
@testable import OuroWorkbenchCore

final class DaemonManagerTests: XCTestCase {
    func testAlreadyUpReusesWithoutSpawning() async {
        let spawnCount = Counter()
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in true }),
            startDaemon: { spawnCount.increment() }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome.recovery, .resumed)
        XCTAssertEqual(outcome.startAttempted, false)
        XCTAssertEqual(spawnCount.value, 0, "An already-up daemon must be reused, never re-spawned.")
    }

    func testDownThenUpAfterStartClassifiesRespawned() async {
        let spawnCount = Counter()
        // First probe (pre-start) reads down; post-start verify probe reads up.
        let livenessSequence = ProbeSequence([.down, .up])
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in livenessSequence.next() == .up }),
            startDaemon: { spawnCount.increment() }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome.recovery, .respawned)
        XCTAssertEqual(outcome.startAttempted, true)
        XCTAssertEqual(spawnCount.value, 1, "A down daemon must be started exactly once.")
    }

    func testStartThenStillUnreachableClassifiesNeedsManual() async {
        let spawnCount = Counter()
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in false }),
            startDaemon: { spawnCount.increment() },
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 4, probeIntervalNanoseconds: 0),
            sleep: { _ in }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome.recovery, .needsManual)
        XCTAssertEqual(outcome.startAttempted, true)
        XCTAssertEqual(spawnCount.value, 1, "Start is issued once even though the verify probe is polled repeatedly.")
    }

    func testPollingRecoversWhenDaemonComesUpAfterSeveralProbes() async {
        let spawnCount = Counter()
        // Pre-start probe reads down; the daemon is still binding its socket for the first two
        // post-start verify probes, then comes up on the third. Polling must classify respawned —
        // a single immediate probe (the old behavior) would have lost this race and misreported
        // needsManual, surfacing a false manual-recovery line on the cold-start path.
        let livenessSequence = ProbeSequence([.down, .down, .down, .up])
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in livenessSequence.next() == .up }),
            startDaemon: { spawnCount.increment() },
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 20, probeIntervalNanoseconds: 0),
            sleep: { _ in }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome.recovery, .respawned, "A daemon that comes up within the verify budget must classify respawned.")
        XCTAssertEqual(outcome.liveness, .up)
        XCTAssertEqual(outcome.startAttempted, true)
        XCTAssertEqual(spawnCount.value, 1, "Polling re-probes the same start; it must never re-spawn.")
    }

    func testStartFailureStillClassifiesFromPostProbeNeedsManual() async {
        // Even when the spawn itself throws, the recovery truth comes from the verify probe,
        // never the spawn error — a thrown spawn must not crash ensureRunning.
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in false }),
            startDaemon: { throw DaemonManagerTestError.spawnFailed },
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 4, probeIntervalNanoseconds: 0),
            sleep: { _ in }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome.recovery, .needsManual)
        XCTAssertEqual(outcome.startAttempted, true)
    }

    func testOutcomeAuditDetailMatchesRecoveryTruth() async {
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in true }),
            startDaemon: {}
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome.auditDetail, DaemonRecoveryTruth.resumed.auditDetail)
        XCTAssertEqual(outcome.liveness, .up)
    }

    func testNeedsManualOutcomeReportsDownLiveness() async {
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in false }),
            startDaemon: {},
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 4, probeIntervalNanoseconds: 0),
            sleep: { _ in }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome.liveness, .down)
        XCTAssertTrue(outcome.recovery.needsManualRecovery)
    }

    func testResumedAndRespawnedDoNotNeedManualRecovery() {
        XCTAssertFalse(DaemonRecoveryTruth.resumed.needsManualRecovery)
        XCTAssertFalse(DaemonRecoveryTruth.respawned.needsManualRecovery)
        XCTAssertTrue(DaemonRecoveryTruth.needsManual.needsManualRecovery)
    }

    // MARK: - Cohesive-product human-facing copy

    func testResumedOutcomeHasNoHumanFacingLine() {
        let outcome = DaemonStartOutcome(recovery: .resumed, liveness: .up, startAttempted: false)
        // Already up → proceed silently, no human-facing line.
        XCTAssertNil(outcome.humanFacingStartupLine)
    }

    func testRespawnedOutcomeHumanLineIsSeamFree() {
        let outcome = DaemonStartOutcome(recovery: .respawned, liveness: .up, startAttempted: true)
        let line = outcome.humanFacingStartupLine
        XCTAssertNotNil(line)
        assertNoCliSeam(line)
    }

    func testNeedsManualOutcomeHumanLineIsSeamFreeAndHonest() {
        let outcome = DaemonStartOutcome(recovery: .needsManual, liveness: .down, startAttempted: true)
        let line = outcome.humanFacingStartupLine
        XCTAssertNotNil(line)
        assertNoCliSeam(line)
        // Honest manual-recovery line — names that the agent isn't responding, no false "done".
        XCTAssertTrue(line?.localizedCaseInsensitiveContains("responding") ?? false)
    }

    /// A human-facing string must never expose a CLI seam — no `ouro up`, no bare `ouro`,
    /// no "daemon". Those verbs live only in audit/debug lines.
    private func assertNoCliSeam(_ line: String?, file: StaticString = #filePath, line lineNumber: UInt = #line) {
        guard let value = line else {
            XCTFail("expected a human-facing line", file: file, line: lineNumber)
            return
        }
        let lowered = value.lowercased()
        XCTAssertFalse(lowered.contains("ouro"), "human copy leaks 'ouro': \(value)", file: file, line: lineNumber)
        XCTAssertFalse(lowered.contains("daemon"), "human copy leaks 'daemon': \(value)", file: file, line: lineNumber)
    }
}

private enum DaemonManagerTestError: Error {
    case spawnFailed
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class ProbeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DaemonLiveness]
    private var index = 0

    init(_ values: [DaemonLiveness]) {
        self.values = values
    }

    func next() -> DaemonLiveness {
        lock.lock()
        defer { lock.unlock() }
        guard index < values.count else {
            return values.last ?? .down
        }
        let value = values[index]
        index += 1
        return value
    }
}
