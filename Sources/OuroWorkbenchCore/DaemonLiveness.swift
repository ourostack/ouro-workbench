import Foundation

/// Up/down result of a daemon-liveness probe.
///
/// This is deliberately a binary signal derived from a dedicated fast reachability
/// probe — NOT from the mailbox `/api/machine` overview, whose `daemon.status`
/// collapses to `"unknown"` when the daemon is down (the `/api/machine` fetch throws),
/// making it useless as a down-signal. See `BossDashboard.daemonStatus`.
public enum DaemonLiveness: String, Codable, Equatable, Sendable {
    case up
    case down
}

/// Recovery-truth of a detect-reuse-else-start cycle.
///
/// Always classified from the POST-start verify probe, never from a spawn exit code:
/// a zero exit from `ouro up` does not prove the daemon is actually serving.
public enum DaemonRecoveryTruth: String, Codable, Equatable, Sendable {
    /// The daemon was already up; we reused it without spawning.
    case resumed
    /// The daemon was down; we started it and the verify probe now reads up.
    case respawned
    /// After a start attempt (or a vanished daemon), the verify probe still reads down.
    case needsManual

    /// Classify from the before/after probe truth — never from an exit code.
    public static func classify(wasUpBeforeStart: Bool, isUpAfterStart: Bool) -> DaemonRecoveryTruth {
        switch (wasUpBeforeStart, isUpAfterStart) {
        case (true, true):
            return .resumed
        case (false, true):
            return .respawned
        default:
            // (false,false) genuine failure; (true,false) a daemon that read up but is
            // unreachable on the verify probe — never a false "survived".
            return .needsManual
        }
    }

    /// True only when the daemon could not be brought up — the one outcome that must
    /// surface an honest manual-recovery line to the human.
    public var needsManualRecovery: Bool {
        self == .needsManual
    }

    /// Audit/debug detail line. This is the ONE surface where raw `ouro` verbs are
    /// allowed — never the human-facing product voice.
    public var auditDetail: String {
        switch self {
        case .resumed:
            return "Daemon already reachable; reused existing process (no spawn)."
        case .respawned:
            return "Daemon was unreachable; spawned `ouro up` detached and verify probe now reads up."
        case .needsManual:
            return "Daemon still unreachable after start attempt; manual recovery required."
        }
    }
}

public struct DaemonLivenessConfiguration: Equatable, Sendable {
    /// The local mailbox health URL the default reachability probe pings.
    public var reachabilityURL: URL
    /// Short timeout — a liveness probe must be fast; a hung connect resolves to `.down`.
    public var probeTimeoutNanoseconds: UInt64

    public init(
        reachabilityURL: URL = URL(string: "http://127.0.0.1:6876/api/machine")!,
        probeTimeoutNanoseconds: UInt64 = 1_500_000_000
    ) {
        self.reachabilityURL = reachabilityURL
        self.probeTimeoutNanoseconds = probeTimeoutNanoseconds
    }

    fileprivate var probeTimeoutSeconds: TimeInterval {
        TimeInterval(probeTimeoutNanoseconds) / 1_000_000_000
    }
}

/// A pure, injectable daemon-liveness probe.
///
/// Mirrors the `MailboxClient` / `ReleaseUpdateChecker` injection style: a configuration
/// plus a single injected closure (here, reachability) that defaults to a real network
/// implementation. The closure receives the configured timeout (in seconds) so a default
/// implementation can apply it to its own transport; the probe ALSO enforces the timeout
/// at the task level so a hung closure still resolves to `.down`.
public struct DaemonLivenessProbe: Sendable {
    public var configuration: DaemonLivenessConfiguration
    private let reachability: @Sendable (TimeInterval?) async throws -> Bool
    private let syncReachability: @Sendable (TimeInterval?) -> Bool

    public init(
        configuration: DaemonLivenessConfiguration = DaemonLivenessConfiguration(),
        reachability: @escaping @Sendable (TimeInterval?) async throws -> Bool = DaemonLivenessProbe.defaultReachability,
        syncReachability: @escaping @Sendable (TimeInterval?) -> Bool = DaemonLivenessProbe.defaultSyncReachability
    ) {
        self.configuration = configuration
        self.reachability = reachability
        self.syncReachability = syncReachability
    }

    /// Probe the daemon. Returns `.up` only on a clean reachable answer; ANY failure —
    /// unreachable, thrown error, or timeout — resolves to `.down` (never throws).
    public func probe() async -> DaemonLiveness {
        let timeoutSeconds = configuration.probeTimeoutSeconds
        let timeoutNanos = configuration.probeTimeoutNanoseconds
        let reachability = self.reachability

        let reachable = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await reachability(timeoutSeconds)) ?? false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        return reachable ? .up : .down
    }

    /// Synchronous, Swift-concurrency-free daemon probe for callers on a thread that must
    /// block for the answer (e.g. the MCP executable's `readLine()` request loop, which
    /// drives tools synchronously). Returns `.up` only on a clean reachable answer; ANY
    /// failure — unreachable, error, or timeout — resolves to `.down` (never throws).
    ///
    /// Deliberately uses a callback-based `URLSession.dataTask` + `DispatchSemaphore` (see
    /// `defaultSyncReachability`) instead of `async`/`await`: bridging the async `probe()`
    /// into a blocked main thread starves the cooperative executor and crashes the task
    /// allocator in a CLI binary. The reachability work runs on a global queue with the
    /// configured timeout enforced at the semaphore so a hung connect still resolves `.down`.
    public func probeSynchronously() -> DaemonLiveness {
        let timeoutSeconds = configuration.probeTimeoutSeconds
        let semaphore = DispatchSemaphore(value: 0)
        let box = SyncReachabilityBox()
        let reachability = self.syncReachability
        DispatchQueue.global(qos: .userInitiated).async {
            box.reachable = reachability(timeoutSeconds)
            semaphore.signal()
        }
        // Task-level timeout backstop: if the closure hangs past the budget, resolve `.down`.
        if semaphore.wait(timeout: .now() + timeoutSeconds + 0.5) == .timedOut {
            return .down
        }
        return box.reachable ? .up : .down
    }

    /// Default reachability: a short-timeout GET against the local mailbox health URL.
    /// Any non-2xx, transport error, or non-HTTP response is treated by the caller as
    /// unreachable (this closure throws, which `probe()` maps to `.down`).
    public static func defaultReachability(timeoutSeconds: TimeInterval?) async throws -> Bool {
        try await defaultReachability(
            url: URL(string: "http://127.0.0.1:6876/api/machine")!,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func defaultReachability(url: URL, timeoutSeconds: TimeInterval?) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let timeoutSeconds, timeoutSeconds > 0 {
            request.timeoutInterval = timeoutSeconds
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<500).contains(http.statusCode)
    }

    /// Synchronous default reachability: a callback-based (NOT async/await) short-timeout GET
    /// against the local mailbox health URL, blocking the caller's thread on a semaphore until
    /// the dataTask completes or the timeout fires. Any non-2xx, transport error, or non-HTTP
    /// response resolves to `false` (unreachable). Free of Swift concurrency so it is safe to
    /// call from a thread that itself blocks for the result.
    public static func defaultSyncReachability(timeoutSeconds: TimeInterval?) -> Bool {
        defaultSyncReachability(
            url: URL(string: "http://127.0.0.1:6876/api/machine")!,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func defaultSyncReachability(
        url: URL,
        timeoutSeconds: TimeInterval?,
        cancelTask: (URLSessionDataTask) -> Void = { $0.cancel() },
        waitTimeoutPadding: TimeInterval = 0.25
    ) -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let budget = (timeoutSeconds ?? 1.5) > 0 ? (timeoutSeconds ?? 1.5) : 1.5
        request.timeoutInterval = budget
        let semaphore = DispatchSemaphore(value: 0)
        let box = SyncReachabilityBox()
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                box.reachable = (200..<500).contains(http.statusCode)
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + budget + waitTimeoutPadding) == .timedOut {
            cancelTask(task)
            return false
        }
        return box.reachable
    }
}

/// A minimal reference box for carrying a `Bool` reachability result out of a callback /
/// dispatched closure across a `DispatchSemaphore` handoff. Access is serialized by the
/// semaphore (write happens-before signal; read happens-after wait), so this is safe despite
/// the `@unchecked` marker.
private final class SyncReachabilityBox: @unchecked Sendable {
    var reachable: Bool = false
}

/// The result of a single detect-reuse-else-start cycle.
///
/// `recovery` and `liveness` are BOTH derived from the post-cycle probe truth (never a
/// spawn exit code). `startAttempted` records whether a start was actually issued (false
/// when an already-up daemon was reused, true once a down daemon triggered a spawn —
/// regardless of whether the spawn itself threw).
public struct DaemonStartOutcome: Equatable, Sendable {
    /// The recovery-truth classification (`resumed | respawned | needsManual`).
    public let recovery: DaemonRecoveryTruth
    /// Final liveness after the cycle (the verify-probe truth).
    public let liveness: DaemonLiveness
    /// Whether a start was attempted at all (false = reused an already-up daemon).
    public let startAttempted: Bool

    public init(recovery: DaemonRecoveryTruth, liveness: DaemonLiveness, startAttempted: Bool) {
        self.recovery = recovery
        self.liveness = liveness
        self.startAttempted = startAttempted
    }

    /// Audit/debug detail line (raw `ouro` verbs allowed here only) — mirrors the
    /// recovery-truth's own audit line so callers have one source of truth.
    public var auditDetail: String {
        recovery.auditDetail
    }

    /// True only when the daemon could not be brought up.
    public var needsManualRecovery: Bool {
        recovery.needsManualRecovery
    }

    /// Human-facing, seam-free copy describing this outcome's effect on a check-in.
    ///
    /// COHESIVE-PRODUCT CONTRACT: this string is the product's human voice — it must NEVER
    /// expose a CLI seam (`ouro up`, `daemon`, raw `ouro …`). Those belong in `auditDetail`
    /// only. Returns `nil` when the daemon was already up (resumed) and the check-in should
    /// proceed silently with no human-facing line at all.
    public var humanFacingStartupLine: String? {
        switch recovery {
        case .resumed:
            return nil
        case .respawned:
            return "Waking your agent…"
        case .needsManual:
            return "Your agent isn't responding yet. Workbench couldn't bring it back online automatically — please reopen Workbench, and if it keeps happening, restart your Mac."
        }
    }
}

/// Bounded patience for the post-start verify probe after a detached `ouro up`.
///
/// The daemon is spawned detached and is not awaited, so it needs a moment to bind its
/// socket. These knobs give it `maxProbeAttempts` probes spaced by `probeIntervalNanoseconds`
/// to come up before the cycle classifies `needsManual`. Defaults to ~10s total (20 × 500ms),
/// comfortably covering a Node cold start; a genuine failure still resolves to an honest
/// manual-recovery line once the budget elapses. Tests inject a no-op sleep to stay fast.
public struct DaemonStartVerifyConfiguration: Equatable, Sendable {
    /// Number of post-start verify probes before classifying `needsManual` (≥ 1).
    public var maxProbeAttempts: Int
    /// Delay between post-start verify probes.
    public var probeIntervalNanoseconds: UInt64

    public init(maxProbeAttempts: Int = 20, probeIntervalNanoseconds: UInt64 = 500_000_000) {
        self.maxProbeAttempts = max(1, maxProbeAttempts)
        self.probeIntervalNanoseconds = probeIntervalNanoseconds
    }
}

/// Detect-reuse-else-start manager for the local Ouro daemon.
///
/// Pure + injectable: it takes a `DaemonLivenessProbe` (the probe from Unit 0.1) and a
/// `startDaemon` closure. Tests inject a deterministic probe + a no-op/throwing start; the
/// app injects `DaemonManager.detachedStart` which spawns `ouro up` DETACHED so the daemon
/// survives Workbench quitting (one-directional dependency — Workbench manages the daemon,
/// the daemon never relies on Workbench).
///
/// Recovery truth is always classified from the before/after probe, never from the spawn:
/// a thrown spawn does NOT crash `ensureRunning()` and does NOT short-circuit the verify
/// probe — `startDaemon` throwing simply means the post-start probe will (almost certainly)
/// still read `.down`, classifying `needsManual`.
public struct DaemonManager: Sendable {
    public var probe: DaemonLivenessProbe
    private let startDaemon: @Sendable () async throws -> Void
    private let verifyConfig: DaemonStartVerifyConfiguration
    private let sleep: @Sendable (UInt64) async -> Void

    public init(
        probe: DaemonLivenessProbe = DaemonLivenessProbe(),
        startDaemon: @escaping @Sendable () async throws -> Void = DaemonManager.detachedStart,
        verifyConfig: DaemonStartVerifyConfiguration = DaemonStartVerifyConfiguration(),
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.probe = probe
        self.startDaemon = startDaemon
        self.verifyConfig = verifyConfig
        self.sleep = sleep
    }

    /// Detect → reuse if up → else start (detached) → re-probe → classify recovery truth.
    public func ensureRunning() async -> DaemonStartOutcome {
        let wasUp = await probe.probe()
        if wasUp == .up {
            return DaemonStartOutcome(recovery: .resumed, liveness: .up, startAttempted: false)
        }

        // Down: issue the start. Swallow a thrown spawn — recovery truth comes from the
        // verify probe, never the spawn error.
        try? await startDaemon()

        let afterStart = await verifyStartedWithinBudget()
        let recovery = DaemonRecoveryTruth.classify(
            wasUpBeforeStart: false,
            isUpAfterStart: afterStart == .up
        )
        return DaemonStartOutcome(recovery: recovery, liveness: afterStart, startAttempted: true)
    }

    /// Verify a freshly-spawned daemon came up, polling with a bounded budget.
    ///
    /// `detachedStart` spawns `ouro up` and does NOT wait — the daemon needs a moment to bind
    /// its socket (a Node cold start, or a one-time CLI self-update download on the first `up`
    /// after a new release). A single immediate probe loses that race and would misclassify a
    /// still-booting daemon as `needsManual`, surfacing a false manual-recovery line on the
    /// exact factory-reset cold-start path this spine exists to make seam-free. So probe
    /// repeatedly: return `.up` the instant a probe reads up, `.down` only after the whole
    /// budget genuinely elapses (the honest "couldn't bring it back" case). The first probe is
    /// immediate, so an already-fast start adds zero latency.
    private func verifyStartedWithinBudget() async -> DaemonLiveness {
        for attempt in 0..<verifyConfig.maxProbeAttempts {
            if await probe.probe() == .up {
                return .up
            }
            if attempt < verifyConfig.maxProbeAttempts - 1 {
                await sleep(verifyConfig.probeIntervalNanoseconds)
            }
        }
        return .down
    }

    /// Default start: spawn `ouro up` DETACHED from Workbench so the daemon outlives the app.
    ///
    /// Mirrors the `BossAgentMCPClient` spawn shape (`/usr/bin/env ouro …` +
    /// `TerminalEnvironment().valuesWithResolvedPath()`) so `ouro` resolves from a
    /// Finder-launched `.app`'s minimal PATH. The child is fully detached: a fresh session
    /// (`setsid`-equivalent via `/dev/null` stdio + no inherited pipes), and we DO NOT wait
    /// on it — Workbench never becomes the daemon's parent-of-record for lifecycle purposes.
    @Sendable
    public static func detachedStart() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro", "up"]
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        // Detach stdio so quitting Workbench never closes the daemon's streams.
        let devNull = FileHandle.nullDevice
        process.standardInput = devNull
        process.standardOutput = devNull
        process.standardError = devNull

        try process.run()
        // Deliberately do NOT wait: the daemon is independent. `ouro up` returns once the
        // daemon is launched; the post-start verify probe is what establishes recovery truth.
    }
}
