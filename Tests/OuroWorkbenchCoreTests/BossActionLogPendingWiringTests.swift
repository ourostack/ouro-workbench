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
    // so its ack is final/verified, not in-flight.
    //
    // `startReportBug` is NOT in this list only because its async kickoff lives in a
    // DIFFERENT method (`submitBugReport`, which owns the `Task {`), so it can't be
    // pinned via the post-`Task{}` span helper. It IS genuinely in-flight, though —
    // `submitBugReport`'s `recordActionLog(action: "submitBugReport", …)` is the
    // settled-truth row that lands later. It has its own pin below
    // (`testStartReportBugMarksItsOptimisticAckInFlight`).
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
        let source = try WorkbenchAppSource.appSource()
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
        let source = try WorkbenchAppSource.appSource()
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
        let source = try WorkbenchAppSource.appSource()
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

    // MARK: - startReportBug's optimistic ack is in-flight (its settled row lands later)

    func testStartReportBugMarksItsOptimisticAckInFlight() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try handlerBody(named: "startReportBug", in: source)
        // The async kickoff lives inside `submitBugReport(...)`, which logs the
        // VERIFIED outcome later under `action: "submitBugReport"`. The post-call
        // optimistic ack ("Writing an anonymized bug report…") sits AFTER the
        // `submitBugReport(` call and must be pending — otherwise a failed write
        // leaves a green "Writing…" row standing next to the orange "Failed" row.
        let callRange = try XCTUnwrap(
            body.range(of: "submitBugReport("),
            "startReportBug was expected to delegate the async write to submitBugReport(…)"
        )
        let postCall = String(body[callRange.lowerBound...])
        XCTAssertTrue(
            postCall.contains("isInFlight: true"),
            "startReportBug's post-call optimistic ack must pass isInFlight: true — its settled truth lands later via submitBugReport's recordActionLog row"
        )
    }

    // The synchronous guard ack ("Skipped reportBug: missing note") sits BEFORE the
    // submitBugReport(…) call and is a settled skip — it must NOT be in-flight.
    func testStartReportBugGuardAckIsNotInFlight() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try handlerBody(named: "startReportBug", in: source)
        let callRange = try XCTUnwrap(
            body.range(of: "submitBugReport("),
            "startReportBug was expected to delegate the async write to submitBugReport(…)"
        )
        let preCall = String(body[body.startIndex..<callRange.lowerBound])
        XCTAssertFalse(
            preCall.contains("isInFlight: true"),
            "startReportBug's synchronous guard-failure ack must NOT be marked in-flight (it's a real skip → orange)"
        )
    }

    // MARK: - complete* verified-outcome rows are never marked in-flight

    func testCompleteHandlersRecordVerifiedOutcomeNotInFlight() throws {
        let source = try WorkbenchAppSource.appSource()
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
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
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
        let source = try WorkbenchAppSource.appSource()
        let record = try WorkbenchAppSource.sourceSlice(
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
        let finish = try WorkbenchAppSource.sourceSlice(
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
}
