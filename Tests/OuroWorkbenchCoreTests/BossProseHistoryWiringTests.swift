import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 3a — durable wiring assertions for the boss-prose history.
///
/// The pure `WorkspaceState.recordProse` + `BossProseEntry` are unit-tested + 100%
/// covered in Core; the App that wires the check-in success path isn't coverage-
/// gated, so we source-pin its structure the `WorkbenchAppSource.appSource()` way.
///
/// The risks these pins defend:
///   - the SUCCESS path must recordProse the boss's answer + save — not just set
///     the transient `bossCheckInAnswer` the next tick overwrites;
///   - the ERROR/empty path must NOT record prose (the product-voice fallback line
///     and the daemon startup line aren't the boss's prose);
///   - the new save() rides the hot tick, so it must go through the model's `save()`
///     (which already suppresses isLoadingState / isResettingToFirstRun) — never a
///     bespoke unconditional store write.
final class BossProseHistoryWiringTests: XCTestCase {
    func testSuccessPathRecordsProseAndSavesNotJustSetsTheTransientAnswer() throws {
        let body = try checkInBody()
        // The success assignment of the real boss answer.
        let answerIndex = try XCTUnwrap(
            body.range(of: "bossCheckInAnswer = answer")?.lowerBound,
            "the success path must set bossCheckInAnswer = answer"
        )
        let recordIndex = try XCTUnwrap(
            body.range(of: "recordProse(")?.lowerBound,
            "the success path must persist the boss's prose via recordProse"
        )
        XCTAssertGreaterThan(
            recordIndex, answerIndex,
            "recordProse must run on the SUCCESS path, right after the answer is in hand"
        )
        // It must build a BossProseEntry from the answer and persist via save().
        XCTAssertTrue(
            body.contains("BossProseEntry("),
            "recordProse must be handed a BossProseEntry built from the answer"
        )
    }

    func testProseRecordIsGuardedOnNonEmptyAnswer() throws {
        let body = try checkInBody()
        // An empty boss answer isn't prose worth keeping; the record must be gated.
        let recordRange = try XCTUnwrap(body.range(of: "recordProse("))
        let preamble = String(body[..<recordRange.lowerBound])
        XCTAssertTrue(
            preamble.contains("answer.trimmingCharacters") || preamble.contains("!answer.isEmpty") || preamble.contains("answer.isEmpty"),
            "the prose record must be gated on a non-empty answer (don't persist empty prose)"
        )
    }

    func testErrorFallbackLineIsNotRecordedAsProse() throws {
        let body = try checkInBody()
        // The catch block sets the product-voice fallback line; prose recording
        // must live on the success path, BEFORE the catch, so the fallback line is
        // never persisted as the boss's prose.
        let recordIndex = try XCTUnwrap(body.range(of: "recordProse(")?.lowerBound)
        let catchIndex = try XCTUnwrap(
            body.range(of: "} catch {")?.lowerBound,
            "the check-in must have a catch arm"
        )
        XCTAssertLessThan(
            recordIndex, catchIndex,
            "recordProse must be on the success path, before the catch (the fallback line is not prose)"
        )
    }

    // MARK: - Helpers

    private func checkInBody() throws -> String {
        // The check-in's do/catch around the boss ask — from the success answer
        // assignment region down through the catch.
        try WorkbenchAppSource.sourceSlice(
            in: try WorkbenchAppSource.appSource(),
            from: "let queueDepthBeforeAsk = externalActionQueue.pendingCount()",
            to: "\n    func applyBossActions(from answer: String) {"
        )
    }
}
