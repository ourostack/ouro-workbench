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
        XCTAssertTrue(DaemonRecoveryTruth.needsManual.needsManualRecovery)
    }

    func testDaemonStartOutcomeDerivedCopy() {
        let resumed = DaemonStartOutcome(recovery: .resumed, liveness: .up, startAttempted: false)
        let respawned = DaemonStartOutcome(recovery: .respawned, liveness: .up, startAttempted: true)
        let manual = DaemonStartOutcome(recovery: .needsManual, liveness: .down, startAttempted: true)

        XCTAssertEqual(resumed.auditDetail, DaemonRecoveryTruth.resumed.auditDetail)
        XCTAssertFalse(resumed.needsManualRecovery)
        XCTAssertNil(resumed.humanFacingStartupLine)
        XCTAssertEqual(respawned.humanFacingStartupLine, "Waking your agent…")
        XCTAssertTrue(manual.needsManualRecovery)
        XCTAssertTrue(manual.humanFacingStartupLine?.contains("isn't responding yet") == true)
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

    func testDefaultReachabilityTreatsHTTPStatusesBelow500AsReachable() async throws {
        try await StubURLProtocol.withHTTPStatus(204) {
            let reachable = try await DaemonLivenessProbe.defaultReachability(
                url: URL(string: "http://daemon.test/machine")!,
                timeoutSeconds: 0.1
            )
            XCTAssertTrue(reachable)
        }

        try await StubURLProtocol.withHTTPStatus(499) {
            let reachable = try await DaemonLivenessProbe.defaultReachability(
                url: URL(string: "http://daemon.test/machine")!,
                timeoutSeconds: 0.1
            )
            XCTAssertTrue(reachable)
        }

        try await StubURLProtocol.withHTTPStatus(500) {
            let reachable = try await DaemonLivenessProbe.defaultReachability(
                url: URL(string: "http://daemon.test/machine")!,
                timeoutSeconds: 0.1
            )
            XCTAssertFalse(reachable)
        }

        try await StubURLProtocol.withHTTPStatus(204) {
            let reachable = try await DaemonLivenessProbe.defaultReachability(timeoutSeconds: 0.1)
            XCTAssertTrue(reachable)
        }
    }

    func testDefaultProbeInitializersUseDefaultReachabilitySeams() async {
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000)
        )

        let asyncLiveness = await probe.probe()
        XCTAssertTrue([DaemonLiveness.up, .down].contains(asyncLiveness))
        XCTAssertTrue([DaemonLiveness.up, .down].contains(probe.probeSynchronously()))
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

    func testDefaultSyncReachabilityTreatsHTTPStatusesBelow500AsReachable() throws {
        try StubURLProtocol.withHTTPStatus(200) {
            XCTAssertTrue(DaemonLivenessProbe.defaultSyncReachability(
                url: URL(string: "http://daemon.test/machine")!,
                timeoutSeconds: nil
            ))
        }

        try StubURLProtocol.withHTTPStatus(500) {
            XCTAssertFalse(DaemonLivenessProbe.defaultSyncReachability(
                url: URL(string: "http://daemon.test/machine")!,
                timeoutSeconds: 0.1
            ))
        }
    }

    func testDefaultSyncReachabilityCancelsTimedOutDataTask() throws {
        let cancelled = LockedBox(false)

        try StubURLProtocol.withHandler(
            start: { _ in },
            stop: { cancelled.value = true }
        ) {
            XCTAssertFalse(DaemonLivenessProbe.defaultSyncReachability(
                url: URL(string: "http://daemon.test/hangs")!,
                timeoutSeconds: 0.1,
                cancelTask: { task in
                    cancelled.value = true
                    task.cancel()
                },
                waitTimeoutPadding: -0.05
            ))
        }
        XCTAssertTrue(cancelled.value)

        try StubURLProtocol.withHandler(start: { _ in }) {
            XCTAssertFalse(DaemonLivenessProbe.defaultSyncReachability(
                url: URL(string: "http://daemon.test/default-cancel")!,
                timeoutSeconds: 0.1,
                waitTimeoutPadding: -0.05
            ))
        }
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

    func testDaemonManagerDefaultStartSeamIsNotInvokedWhenAlreadyUp() async {
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000),
            reachability: { _ in true }
        )
        let manager = DaemonManager(probe: probe)

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome, DaemonStartOutcome(recovery: .resumed, liveness: .up, startAttempted: false))
    }

    func testDaemonManagerDefaultStartSeamCanRespawnWithPathOuro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonLivenessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ouro = root.appendingPathComponent("ouro")
        try "#!/usr/bin/env bash\nexit 0\n".write(to: ouro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ouro.path)
        let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(root.path):\(previousPath)", 1)
        defer {
            setenv("PATH", previousPath, 1)
            try? FileManager.default.removeItem(at: root)
        }

        let attempts = LockedBox(0)
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000),
            reachability: { _ in
                attempts.value += 1
                return attempts.value >= 2
            }
        )
        let manager = DaemonManager(
            probe: probe,
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 1, probeIntervalNanoseconds: 0),
            sleep: { _ in }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome, DaemonStartOutcome(recovery: .respawned, liveness: .up, startAttempted: true))
    }

    func testDaemonManagerDefaultSleepSeamIsUsedBetweenFailedVerifyAttempts() async {
        let attempts = LockedBox(0)
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000),
            reachability: { _ in
                attempts.value += 1
                return false
            }
        )
        let manager = DaemonManager(
            probe: probe,
            startDaemon: {},
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 2, probeIntervalNanoseconds: 0)
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome, DaemonStartOutcome(recovery: .needsManual, liveness: .down, startAttempted: true))
        XCTAssertEqual(attempts.value, 3)
    }

    func testDaemonManagerClassifiesRespawnedWhenVerifyProbeComesUp() async {
        let attempts = LockedBox(0)
        let probe = DaemonLivenessProbe(
            configuration: DaemonLivenessConfiguration(probeTimeoutNanoseconds: 1_000_000),
            reachability: { _ in
                attempts.value += 1
                return attempts.value >= 3
            }
        )
        let manager = DaemonManager(
            probe: probe,
            startDaemon: {},
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 3, probeIntervalNanoseconds: 0),
            sleep: { _ in }
        )

        let outcome = await manager.ensureRunning()

        XCTAssertEqual(outcome, DaemonStartOutcome(recovery: .respawned, liveness: .up, startAttempted: true))
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

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startHandler: ((StubURLProtocol) -> Void)?
    nonisolated(unsafe) private static var stopHandler: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock {
            Self.startHandler
        }?(self)
    }

    override func stopLoading() {
        Self.lock.withLock {
            Self.stopHandler
        }?()
    }

    static func withHTTPStatus<T>(_ statusCode: Int, run body: () async throws -> T) async throws -> T {
        try await withHandler(start: { loader in
            let response = HTTPURLResponse(
                url: loader.request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
            loader.client?.urlProtocol(loader, didLoad: Data())
            loader.client?.urlProtocolDidFinishLoading(loader)
        }, run: body)
    }

    static func withHTTPStatus<T>(_ statusCode: Int, run body: () throws -> T) throws -> T {
        try withHandler(start: { loader in
            let response = HTTPURLResponse(
                url: loader.request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
            loader.client?.urlProtocol(loader, didLoad: Data())
            loader.client?.urlProtocolDidFinishLoading(loader)
        }, run: body)
    }

    static func withHandler<T>(
        start: @escaping (StubURLProtocol) -> Void,
        stop: (() -> Void)? = nil,
        run body: () async throws -> T
    ) async throws -> T {
        setHandlers(start: start, stop: stop)
        URLProtocol.registerClass(Self.self)
        defer {
            URLProtocol.unregisterClass(Self.self)
            setHandlers(start: nil, stop: nil)
        }
        return try await body()
    }

    static func withHandler<T>(
        start: @escaping (StubURLProtocol) -> Void,
        stop: (() -> Void)? = nil,
        run body: () throws -> T
    ) throws -> T {
        setHandlers(start: start, stop: stop)
        URLProtocol.registerClass(Self.self)
        defer {
            URLProtocol.unregisterClass(Self.self)
            setHandlers(start: nil, stop: nil)
        }
        return try body()
    }

    private static func setHandlers(start: ((StubURLProtocol) -> Void)?, stop: (() -> Void)?) {
        lock.withLock {
            startHandler = start
            stopHandler = stop
        }
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
