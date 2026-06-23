import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the boss action-log false-green fix. The App
/// target isn't coverage-gated and can't be click-tested in CI, so we pin the
/// structural wiring the same way `ColdStartHonestWiringTests` does:
///
///   1. Each genuinely-async "start" handler's POST-`Task{}` optimistic ack passes
///      `isInFlight: true` to `finishBossAction` — so the in-flight row renders
///      neutral (pending), never a green check.
///   2. The SYNCHRONOUS guard-failure acks (`"Skipped …"`) and the `complete*`
///      verified-outcome `recordActionLog` calls do NOT pass `isInFlight: true` —
///      a real, settled failure/success is never disguised as pending.
///   3. The per-entry render site (`actionLogEntryRow`) routes its icon + color
///      through `WorkbenchActionOutcomePresentation`, not a raw `entry.succeeded ?`
///      ternary.
final class BossActionLogPendingWiringTests: XCTestCase {
    // The 6 handlers that defer to an async `Task { … complete*(…) }` and then
    // return an optimistic in-flight ack. `openProviderConfig` is deliberately
    // EXCLUDED: it's synchronous (presents the form, no async Task, no `complete*`),
    // so its ack is final/verified, not in-flight. `startReportBug` is EXCLUDED for
    // the same honesty reason: its `Task` writes a bundle but records no `complete*`
    // verified-outcome row, so marking it pending would never resolve.
    private let inFlightHandlers = [
        "startRepairAgent",
        "startVerifyProvider",
        "startRefreshProvider",
        "startSelectLane",
        "startRegisterWorkbenchMCP",
        "startEnsureDaemon",
    ]

    // MARK: - In-flight acks pass isInFlight: true

    func testEachAsyncStartHandlerMarksItsPostTaskAckInFlight() throws {
        let source = try appSource()
        for handler in inFlightHandlers {
            let body = try handlerBody(named: handler, in: source)
            // The optimistic ack lives AFTER the `Task {` that kicks off the
            // background work. Pin that the post-Task span carries isInFlight: true.
            let postTask = try postTaskSpan(in: body, handler: handler)
            XCTAssertTrue(
                postTask.contains("isInFlight: true"),
                "\(handler)'s post-Task optimistic ack must pass isInFlight: true (it's pending, not green)"
            )
        }
    }

    // MARK: - Guard-failure acks stay isInFlight: false (a real skip is orange)

    func testGuardFailureAcksAreNotMarkedInFlight() throws {
        let source = try appSource()
        // Every "Skipped …" guard ack is a settled failure — it must NOT be pending.
        for handler in inFlightHandlers {
            let body = try handlerBody(named: handler, in: source)
            guard let taskRange = body.range(of: "Task {") else { continue }
            let preTask = String(body[body.startIndex..<taskRange.lowerBound])
            // The synchronous guard ack (when present) sits before the Task. It must
            // not carry isInFlight: true.
            XCTAssertFalse(
                preTask.contains("isInFlight: true"),
                "\(handler)'s synchronous guard-failure ack must NOT be marked in-flight (it's a real skip → orange)"
            )
        }
    }

    // MARK: - openProviderConfig (synchronous) is NOT in-flight

    func testOpenProviderConfigStaysSynchronousNotInFlight() throws {
        let source = try appSource()
        let body = try handlerBody(named: "openProviderConfig", in: source)
        XCTAssertFalse(
            body.contains("Task {"),
            "openProviderConfig is synchronous (no async Task) — guarding the in-flight assumption"
        )
        XCTAssertFalse(
            body.contains("isInFlight: true"),
            "openProviderConfig's ack is final/verified (the form opened), never in-flight"
        )
    }

    // MARK: - startReportBug has no complete*, so it stays not-in-flight

    func testStartReportBugIsNotMarkedInFlight() throws {
        let source = try appSource()
        let body = try handlerBody(named: "startReportBug", in: source)
        XCTAssertFalse(
            body.contains("isInFlight: true"),
            "startReportBug records no complete* verified row, so pending would never resolve — keep it not-in-flight"
        )
    }

    // MARK: - complete* verified-outcome rows are never marked in-flight

    func testCompleteHandlersRecordVerifiedOutcomeNotInFlight() throws {
        let source = try appSource()
        for handler in ["completeRepairAgent", "completeOnboardingAction"] {
            let body = try handlerBody(named: handler, in: source)
            XCTAssertTrue(
                body.contains("recordActionLog"),
                "\(handler) records the verified outcome"
            )
            XCTAssertFalse(
                body.contains("isInFlight: true"),
                "\(handler)'s recordActionLog is the VERIFIED outcome — never in-flight"
            )
        }
    }

    // MARK: - render site routes through the seam (not a raw entry.succeeded ternary)

    func testActionLogEntryRowRoutesThroughPresentationSeam() throws {
        let source = try appSource()
        let body = try sourceSlice(
            in: source,
            from: "private func actionLogEntryRow(",
            to: "private func actionLogEntryHelp("
        )
        XCTAssertTrue(
            body.contains("WorkbenchActionOutcomePresentation.tone(") &&
            body.contains("isInFlight: entry.isInFlight"),
            "actionLogEntryRow must resolve the tone via WorkbenchActionOutcomePresentation.tone(isInFlight:…)"
        )
        XCTAssertTrue(
            body.contains("iconSystemName(for:"),
            "actionLogEntryRow must take its icon from the seam"
        )
        // The raw `entry.succeeded ?` ternary that drove icon + color is gone.
        XCTAssertFalse(
            body.contains("entry.succeeded ?"),
            "actionLogEntryRow must no longer pick icon/color from a raw entry.succeeded ternary"
        )
    }

    // MARK: - recordActionLog / finishBossAction thread the flag

    func testRecordActionLogAndFinishBossActionThreadTheFlag() throws {
        let source = try appSource()
        let record = try sourceSlice(
            in: source,
            from: "private func recordActionLog(",
            to: "private func processEntry("
        )
        XCTAssertTrue(
            record.contains("isInFlight: Bool = false"),
            "recordActionLog must accept an isInFlight parameter (default false)"
        )
        XCTAssertTrue(
            record.contains("isInFlight: isInFlight"),
            "recordActionLog must thread isInFlight into the WorkbenchActionLogEntry"
        )
        let finish = try sourceSlice(
            in: source,
            from: "private func finishBossAction(",
            to: "private func recordActionLog("
        )
        XCTAssertTrue(
            finish.contains("isInFlight: Bool = false"),
            "finishBossAction must accept an isInFlight parameter (default false)"
        )
        XCTAssertTrue(
            finish.contains("isInFlight: isInFlight"),
            "finishBossAction must thread isInFlight into recordActionLog"
        )
    }

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)

    /// The body of one `private func <name>(` up to the next `\n    private func `.
    private func handlerBody(named name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: "private func \(name)(")?.lowerBound,
            "could not find handler \(name)"
        )
        let after = source.index(start, offsetBy: 1)
        let end = source.range(of: "\n    private func ", range: after..<source.endIndex)?.lowerBound
            ?? source.endIndex
        return String(source[start..<end])
    }

    /// The span of a handler body AFTER its `Task {` — where the post-kickoff
    /// optimistic ack lives.
    private func postTaskSpan(in body: String, handler: String) throws -> String {
        let taskStart = try XCTUnwrap(
            body.range(of: "Task {")?.lowerBound,
            "\(handler) was expected to kick off an async Task"
        )
        return String(body[taskStart...])
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound, "missing start marker: \(startMarker)")
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound,
            "missing end marker: \(endMarker)"
        )
        return String(source[start..<end])
    }
}
