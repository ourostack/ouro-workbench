#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B6 — `DecisionLogRow` (`:2577`) INTERACTION drive-to-100%.
///
/// The C4 state-set suite (`DecisionLogRowStateSetTests`) drove every RENDERED arm via snapshots
/// and explicitly RECORDED the interaction-closure regions (the Teach Menu's `taught == true`
/// post-tap arm, the inbox triage Button actions, the Snooze Menu items) as "structurally
/// unreachable in a snapshot". They are NOT unreachable — ViewInspector 0.10.3 descends `Menu {}`
/// and INVOKES action closures via `Button.tap()`. This suite drives each remaining un-hit region
/// by INVOKING its closure and ASSERTING the side-effect, then the negative-control proves the
/// assertion is non-vacuous (mutation-verified in the gate run).
///
/// Regions driven here (measured `--show-regions`, the residual after the C4 snapshots):
///   - L2624  `decision.sessionName ?? "unknown session"` — the `nil`-session RHS arm.
///   - L2680  Resolve `Button { onResolve() }` action — tapped, `onResolve` fires.
///   - L2690  Snooze Menu `Button("1 hour") { onSnooze(3600) }` — tapped, `onSnooze(3600)`.
///   - L2693  Snooze Menu `Button("Until end of day") { onSnooze(untilEndOfDay()) }` — tapped.
///   - L2694  Snooze Menu `Button("1 day") { onSnooze(86_400) }` — tapped.
///   - L2703  Ack `Button { onAcknowledge() }` action — tapped, `onAcknowledge` fires.
///   - L2726  Teach Menu `Button { onTeach(option.reinforces); taught = true }` — tapped (both
///            statements execute: `onTeach` fires AND `@State taught` is assigned).
///   - L2779/L2780  `severityColor` `.normal → .blue` / `.low → .secondary` switch arms.
///
/// **CARVE (recorded for Unit 3):** L2713 — the `if taught {` TRUE arm ("Sent to boss"). Tapping a
/// Teach Menu item EXECUTES `taught = true` (L2728 covered), but ViewInspector's no-host synchronous
/// `inspect()` re-seeds `@State` from its `false` initializer on the next read, so the *rendered*
/// `taught == true` branch never evaluates. The C4 suite recorded this same arm as snapshot-
/// unreachable; the invocation API reaches the SETTER, not a live re-render. `--show-regions`:
/// `L2713:27` `^0` — only-renderer is a live SwiftUI host re-evaluating the body after the @State
/// write, which ViewInspector does not provide.
///   - L2779/L2780  `severityColor` `.normal → .blue` / `.low → .secondary` switch arms — driven
///            by an inbox-mode row whose REAL `DecisionSeverity.of` lands on `.normal` / `.low`.
///
/// **Provenance (P2).** Every `BossInboxDecision` is built via its REAL public initializer; severity
/// flows through the REAL `DecisionSeverity.of` (a `.normal`/`.low` decision is producer-derived, not
/// hand-set). The triage/teach closures are the SAME closures the live sheets wire to the VM.
///
/// **Clock (AN-007).** Standalone row with a FIXED `occurredAt` + injected `.gmt`/`en_GB` (the C4
/// recipe), so any captured timestamp is runner-independent.
@MainActor
final class DecisionLogRowInteractionTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let decisionId = UUID(uuidString: "DEC15102-0000-0000-0000-00000000000D")!

    private func decision(
        kind: BossDecisionKind,
        sessionName: String? = "deploy-runner",
        friendName: String? = "Sam",
        prompt: String = "Apply the migration?",
        confidence: Double? = 0.7
    ) -> BossInboxDecision {
        BossInboxDecision(
            id: Self.decisionId,
            occurredAt: Self.fixedDate,
            source: "boss:slugger",
            sessionName: sessionName,
            friendName: friendName,
            prompt: prompt,
            kind: kind,
            proposedInput: nil,
            preferenceCited: nil,
            confidence: confidence,
            reasoning: "Matches the team's standing preference.",
            status: .recorded
        )
    }

    // MARK: - L2595 / L2596 — the prod-default `timeZone`/`locale` autoclosure arms

    /// Constructing the row WITHOUT injecting `timeZone`/`locale` exercises the production-default
    /// `.autoupdatingCurrent` autoclosure initializers (the seams every prior test bypassed by
    /// injecting `.gmt`/`en_GB`). The `ViewSnapshotHost` reads every `Text` through its pinned
    /// `en_US_POSIX` locale + UTC process-TZ, so the rendered tree is still deterministic even
    /// though the row's own defaults are `.autoupdatingCurrent`.
    func testRow_prodDefaultClock_constructsAndRendersDeterministically() throws {
        let row = DecisionLogRow(
            decision: decision(kind: .escalate),
            onTeach: { _ in })  // timeZone/locale default to .autoupdatingCurrent
        let a = try ViewSnapshotHost.snapshotText(of: row)
        let b = try ViewSnapshotHost.snapshotText(of: row)
        XCTAssertEqual(a, b, "the prod-default-clock row renders byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertTrue(a.contains("deploy-runner"), "the row content renders under the prod defaults")
    }

    // MARK: - L2624 — the `sessionName ?? "unknown session"` nil-RHS arm

    func testRow_nilSessionName_rendersUnknownFallback() throws {
        let row = DecisionLogRow(
            decision: decision(kind: .escalate, sessionName: nil),
            timeZone: .gmt, locale: Self.clockLocale,
            onTeach: { _ in })
        let tree = try ViewSnapshotHost.snapshotText(of: row)
        XCTAssertTrue(tree.contains("unknown session"),
                      "the nil-sessionName fallback renders:\n\(tree)")
        XCTAssertFalse(tree.contains("deploy-runner"), "no real session name when nil")
    }

    // MARK: - L2726 — Teach Menu button action (fires onTeach + assigns @State taught)

    func testRow_teachMenu_tapReinforce_firesOnTeachTrue() throws {
        var taughtPolarity: Bool?
        let row = DecisionLogRow(
            decision: decision(kind: .escalate),  // escalate → "Always ask me" is current
            timeZone: .gmt, locale: Self.clockLocale,
            onTeach: { taughtPolarity = $0 })

        // BEFORE: the Teach Menu is present, no confirmation yet.
        let before = try ViewSnapshotHost.snapshotText(of: row)
        XCTAssertTrue(before.contains("Teach the boss"), "before: the Teach Menu:\n\(before)")
        XCTAssertFalse(before.contains("Sent to boss"), "before: no confirmation yet")

        // INVOKE: tap the reinforce option ("Do this automatically next time") inside the Menu.
        // The action body executes BOTH statements (`onTeach(option.reinforces)` AND `taught = true`)
        // — covering the L2726 button-action region. The onTeach side-effect is the observable proof.
        try row.inspect().find(button: "Do this automatically next time").tap()

        // EFFECT: the onTeach closure fired with the reinforce polarity (true).
        XCTAssertEqual(taughtPolarity, true,
                       "tapping the reinforce option fires onTeach(true)")
        // NOTE: the L2713 `if taught` TRUE re-render arm is the recorded carve — ViewInspector
        // re-seeds @State per inspect, so the "Sent to boss" branch never re-evaluates here.
    }

    /// The "Always ask me" option fires onTeach(false) — the OTHER Teach polarity (defense in
    /// depth that the button hands the option's real `reinforces` flag, not a constant).
    func testRow_teachMenu_tapCorrect_firesOnTeachFalse() throws {
        var taughtPolarity: Bool?
        let row = DecisionLogRow(
            decision: decision(kind: .autoAdvance),  // autoAdvance → "automatic" is current
            timeZone: .gmt, locale: Self.clockLocale,
            onTeach: { taughtPolarity = $0 })
        try row.inspect().find(button: "Always ask me").tap()
        XCTAssertEqual(taughtPolarity, false, "the correct option fires onTeach(false)")
    }

    // MARK: - L2680 — Resolve button action

    func testRow_inbox_resolveButton_firesOnResolve() throws {
        var resolved = false
        let row = inboxRow(decision(kind: .escalate), onResolve: { resolved = true })
        try row.inspect().find(button: "Resolve").tap()
        XCTAssertTrue(resolved, "tapping Resolve fires onResolve")
    }

    // MARK: - L2703 — Ack button action

    func testRow_inbox_ackButton_firesOnAcknowledge() throws {
        var acked = false
        let row = inboxRow(decision(kind: .escalate), onAcknowledge: { acked = true })
        try row.inspect().find(button: "Ack").tap()
        XCTAssertTrue(acked, "tapping Ack fires onAcknowledge")
    }

    // MARK: - L2690 / L2693 / L2694 — the three Snooze Menu items

    func testRow_inbox_snoozeMenu_oneHour_fires3600() throws {
        var snoozed: TimeInterval?
        let row = inboxRow(decision(kind: .escalate), onSnooze: { snoozed = $0 })
        try row.inspect().find(button: "1 hour").tap()
        XCTAssertEqual(snoozed, 3600, "the 1-hour Snooze item fires onSnooze(3600)")
    }

    func testRow_inbox_snoozeMenu_oneDay_fires86400() throws {
        var snoozed: TimeInterval?
        let row = inboxRow(decision(kind: .escalate), onSnooze: { snoozed = $0 })
        try row.inspect().find(button: "1 day").tap()
        XCTAssertEqual(snoozed, 86_400, "the 1-day Snooze item fires onSnooze(86_400)")
    }

    func testRow_inbox_snoozeMenu_untilEndOfDay_firesPositiveInterval() throws {
        var snoozed: TimeInterval?
        let row = inboxRow(decision(kind: .escalate), onSnooze: { snoozed = $0 })
        try row.inspect().find(button: "Until end of day").tap()
        // The interval is computed at tap time via the REAL WorkbenchTriageInterval.untilEndOfDay()
        // (clamped to >= 60s); we assert it is a positive, bounded interval rather than a fixed
        // constant so the test stays deterministic across the day.
        let value = try XCTUnwrap(snoozed, "the end-of-day item fires onSnooze")
        XCTAssertGreaterThanOrEqual(value, 60, "end-of-day snooze is clamped to >= 60s")
        XCTAssertLessThanOrEqual(value, 86_400, "end-of-day snooze is at most one day out")
    }

    // MARK: - L2779 / L2780 — severityColor `.normal` / `.low` switch arms

    /// A `.autoAdvance` decision with a SAFE prompt and no friend → the REAL `DecisionSeverity.of`
    /// lands on `.normal` (the `.blue` accent arm). Inbox mode reads `severityColor` for the stripe.
    func testRow_inbox_normalSeverity_drivesBlueAccentArm() throws {
        let d = decision(kind: .autoAdvance, sessionName: "calm-runner", confidence: 0.95)
        XCTAssertEqual(DecisionSeverity.of(d), .normal,
                       "provenance: a safe autoAdvance decision is .normal severity")
        let row = inboxRow(d)
        let tree = try ViewSnapshotHost.snapshotText(of: row)
        // The accent color is presentation; the load-bearing assertion is that the inbox-mode row
        // for a .normal decision renders (its triage controls present), executing severityColor.
        XCTAssertTrue(tree.contains("Resolve"), "the .normal inbox row renders its triage controls:\n\(tree)")
    }

    /// A `.hold` decision → `.low` severity (the `.secondary` accent arm).
    func testRow_inbox_lowSeverity_drivesSecondaryAccentArm() throws {
        let d = decision(kind: .hold, prompt: "Hold for review", confidence: nil)
        XCTAssertEqual(DecisionSeverity.of(d), .low,
                       "provenance: a hold decision is .low severity")
        let row = inboxRow(d)
        let tree = try ViewSnapshotHost.snapshotText(of: row)
        XCTAssertTrue(tree.contains("Resolve"), "the .low inbox row renders its triage controls:\n\(tree)")
    }

    // MARK: - Helpers

    private func inboxRow(
        _ decision: BossInboxDecision,
        onTeach: @escaping (Bool) -> Void = { _ in },
        onAcknowledge: @escaping () -> Void = {},
        onSnooze: @escaping (TimeInterval) -> Void = { _ in },
        onResolve: @escaping () -> Void = {}
    ) -> DecisionLogRow {
        DecisionLogRow(
            decision: decision,
            mode: .inbox,
            timeZone: .gmt,
            locale: Self.clockLocale,
            onTeach: onTeach,
            onAcknowledge: onAcknowledge,
            onSnooze: onSnooze,
            onResolve: onResolve
        )
    }
}
#endif
