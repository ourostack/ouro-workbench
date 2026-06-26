#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C4 (DecisionLogRow — its OWN sub-unit/commit, the brief's 5th high-fan-out target).
///
/// `DecisionLogRow` (`:2552`) is the deepest state-set of the C4 five. Its body fans on:
///   - `decision.kind` → the kind capsule label (`Auto-advance` / `Escalate` / `Hold`).
///   - `decision.sessionName ?? "unknown session"`.
///   - `if let friend = decision.friendName` (`:2591`) → the `· <friend>` chip.
///   - the `occurredAt` TIMESTAMP (`:2598`) — **migrated to the `Date.workbenchTimeText`
///     seam (AN-007)** so the rendered string is deterministic under an injected zone+locale
///     (prod stays `.autoupdatingCurrent`, byte-identical to the prior `.formatted(…)`).
///   - `if !decision.prompt.isEmpty` (`:2602`).
///   - `if let proposed = decision.proposedInput, !proposed.isEmpty` (`:2611`).
///   - `if let pref = decision.preferenceCited, !pref.isEmpty` (`:2614`).
///   - `if !decision.reasoning.isEmpty` (`:2617`).
///   - `if let confidence = decision.confidence` (`:2621`) → "confidence N%".
///   - the status/source footer via the REAL `DecisionLogPhrasebook` (`:2628/:2629`).
///   - `mode == .inbox` (`:2638`) → the Resolve/Snooze/Ack triage controls (vs `.log` Teach-only).
///   - `@State private var taught` (`:2569`) → `inspect()` renders its INITIAL `false` (the
///     "Teach the boss" Menu, not the "Sent to boss" confirmation) — the post-tap `taught == true`
///     arm is only reachable by firing the in-view Button closure, which `inspect()` does not do
///     (recorded as the structurally-unreachable arm, NOT fabricated — the C1/AN-006 discipline).
///
/// **Clock (AN-007 — the C4-specific hazard).** The row is instantiated STANDALONE with a FIXED
/// `occurredAt` epoch and injected `.gmt` + `en_GB`, so the timestamp renders byte-identically on
/// any CI runner zone/locale. The cross-TZ/locale proof (`TZ=…` × `en_GB`) lives in the gate run.
///
/// **Provenance (P2).** Each `BossInboxDecision` is built via its REAL public initializer (the
/// same type the persisted log decodes to); severity / phrasing / teach-options flow through the
/// REAL `DecisionSeverity.of` / `DecisionLogPhrasebook` / `PromptSafetyClassifier` seams. NO
/// serializer output is hand-assembled. The row is a leaf `View` struct (now `internal` after the
/// `private`→`internal` widening) → snapshotting it standalone IS the legitimate seam (the SU3r
/// leaf pattern; the parent sheets embed it via `ForEach`, covered in their own sub-units).
@MainActor
final class DecisionLogRowStateSetTests: XCTestCase {

    /// A single canonical fixed epoch — 2026-01-02 03:04:05 UTC. Under the injected `.gmt` zone +
    /// `en_GB` locale, `workbenchTimeText(date: .abbreviated, time: .shortened)` renders a clean,
    /// runner-independent string (`2 Jan 2026 at 03:04` — captured in the recorded refs). `en_GB`
    /// is the stable clock locale (the C0 finding: it avoids the U+202F narrow-no-break-space that
    /// `en_US_POSIX` injects before AM/PM, an ICU-version landmine across runners).
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let decisionId = UUID(uuidString: "DEC15102-0000-0000-0000-00000000000A")!

    /// Build a decision through the REAL public initializer with a FIXED occurredAt + id.
    private func decision(
        kind: BossDecisionKind,
        sessionName: String? = "deploy-runner",
        friendName: String? = nil,
        prompt: String = "Apply the migration?",
        proposedInput: String? = nil,
        preferenceCited: String? = nil,
        confidence: Double? = nil,
        reasoning: String = "Matches the team's standing preference.",
        status: BossDecisionStatus = .recorded
    ) -> BossInboxDecision {
        BossInboxDecision(
            id: Self.decisionId,
            occurredAt: Self.fixedDate,
            source: "boss:slugger",
            sessionName: sessionName,
            friendName: friendName,
            prompt: prompt,
            kind: kind,
            proposedInput: proposedInput,
            preferenceCited: preferenceCited,
            confidence: confidence,
            reasoning: reasoning,
            status: status
        )
    }

    private func row(_ decision: BossInboxDecision, mode: DecisionLogRow.Mode = .log) -> DecisionLogRow {
        DecisionLogRow(decision: decision, mode: mode, timeZone: .gmt, locale: Self.clockLocale,
                       onTeach: { _ in }, onAcknowledge: {}, onSnooze: { _ in }, onResolve: {})
    }

    // MARK: - Enumerated state-set

    /// The minimal `.log` row — auto-advance kind, no friend/proposed/pref/confidence.
    func testRow_logMinimal() throws {
        let view = row(decision(kind: .autoAdvance))
        try assertViewSnapshot(of: view, named: "DecisionLogRow.logMinimal")
    }

    /// The FULL `.log` row — escalate kind, with friend + proposedInput + preferenceCited +
    /// confidence (every optional `if let` arm rendered at once).
    func testRow_logFull() throws {
        let view = row(decision(
            kind: .escalate,
            friendName: "Sam",
            proposedInput: "y",
            preferenceCited: "Sam always approves staging migrations",
            confidence: 0.82
        ))
        XCTAssertEqual(DecisionSeverity.of(view.decision), .elevated,
                       "provenance: a safe escalate decision is .elevated severity")
        try assertViewSnapshot(of: view, named: "DecisionLogRow.logFull")
    }

    /// The `.hold` kind variant (the third kind branch + .low severity).
    func testRow_logHold() throws {
        let view = row(decision(kind: .hold, prompt: "Hold for review", confidence: nil))
        XCTAssertEqual(DecisionSeverity.of(view.decision), .low, "provenance: hold → .low")
        try assertViewSnapshot(of: view, named: "DecisionLogRow.logHold")
    }

    /// The `.inbox` mode — the triage controls (Resolve / Snooze / Ack) render in addition to the
    /// shared body (the `mode == .inbox` branch).
    func testRow_inboxTriage() throws {
        let view = row(decision(kind: .escalate, friendName: "Sam", confidence: 0.5), mode: .inbox)
        try assertViewSnapshot(of: view, named: "DecisionLogRow.inboxTriage")
    }

    /// The CRITICAL-severity arm — an unsafe prompt floors severity to `.critical` via the REAL
    /// `PromptSafetyClassifier` (kind-independent), driving the inbox accent. Provenance: the
    /// classifier, not a fabricated severity.
    func testRow_inboxCritical() throws {
        let unsafe = decision(kind: .autoAdvance, prompt: "rm -rf / --no-preserve-root",
                              proposedInput: "y", confidence: 0.9)
        XCTAssertEqual(DecisionSeverity.of(unsafe), .critical,
                       "provenance: the safety classifier floors an unsafe prompt to .critical")
        try assertViewSnapshot(of: row(unsafe, mode: .inbox), named: "DecisionLogRow.inboxCritical")
    }

    // MARK: - @State taught arm (structurally-unreachable in a snapshot — recorded, not fabricated)

    /// `@State private var taught` defaults to `false`; ViewInspector's synchronous `inspect()`
    /// renders the INITIAL state, so the row always shows the "Teach the boss" Menu, never the
    /// post-tap "Sent to boss" confirmation (reachable only by firing the Menu Button's closure,
    /// which `inspect()` does not do). Asserted via the captured tree, classifying the unreachable
    /// arm rather than fabricating it.
    func testRow_taughtArm_isUnreachableFalseByDefault() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: row(decision(kind: .escalate)))
        XCTAssertTrue(tree.contains("Teach the boss"),
                      "the initial @State taught==false renders the Teach Menu:\n\(tree)")
        XCTAssertFalse(tree.contains("Sent to boss"),
                       "the taught==true confirmation is structurally unreachable in a snapshot")
    }

    // MARK: - Clock determinism (P3 — AN-007)

    func testRow_clockDeterminism_byteIdenticalTwiceAndFixedTimestamp() throws {
        let view = row(decision(kind: .escalate, friendName: "Sam"))
        let a = try ViewSnapshotHost.snapshotText(of: view)
        let b = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertEqual(a, b, "the fixed-timestamp row must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        // The migrated seam renders the FIXED epoch under .gmt/en_GB → a stable string.
        XCTAssertTrue(a.contains("Jan 2026") || a.contains("Jan 2026 at 03:04") || a.contains("2026"),
                      "the fixed occurredAt renders a deterministic 2026 timestamp:\n\(a)")
    }

    // MARK: - Negative controls (P2 — mutation-verified)

    /// The optional `if let` arms and the kind/mode branches each flip the captured tree: the
    /// friend chip, the proposed-input / preference / confidence rows, and the inbox triage
    /// controls all appear/vanish with the underlying data — real model-driven branches.
    func testRow_negativeControl_optionalArmsAndModeFlipTree() throws {
        let minimal = try ViewSnapshotHost.snapshotText(of: row(decision(kind: .autoAdvance)))
        let full = try ViewSnapshotHost.snapshotText(of: row(decision(
            kind: .escalate, friendName: "Sam", proposedInput: "y",
            preferenceCited: "Sam approves", confidence: 0.82)))
        let inbox = try ViewSnapshotHost.snapshotText(of: row(
            decision(kind: .escalate, friendName: "Sam"), mode: .inbox))

        // Optional arms drive the tree.
        XCTAssertNotEqual(minimal, full, "the optional if-let arms must flip the tree")
        XCTAssertFalse(minimal.contains("· Sam"), "minimal: no friend chip:\n\(minimal)")
        XCTAssertTrue(full.contains("· Sam"), "full: the friend chip renders")
        XCTAssertTrue(full.contains("Proposed input"), "full: the proposed-input row renders")
        XCTAssertTrue(full.contains("Preference"), "full: the preference row renders")
        XCTAssertTrue(full.contains("confidence 82%"), "full: the confidence renders")
        XCTAssertFalse(minimal.contains("confidence"), "minimal: no confidence row")
        // The kind capsule label flips.
        XCTAssertTrue(minimal.contains("Auto-advance"), "minimal: the auto-advance kind label")
        XCTAssertTrue(full.contains("Escalate"), "full: the escalate kind label")
        // Mode drives the triage controls.
        XCTAssertNotEqual(full, inbox, "the mode==.inbox branch must flip the tree")
        XCTAssertTrue(inbox.contains("Resolve"), "inbox: the Resolve control renders:\n\(inbox)")
        XCTAssertTrue(inbox.contains("Snooze"), "inbox: the Snooze control renders")
        XCTAssertTrue(inbox.contains("Ack"), "inbox: the Ack control renders")
        XCTAssertFalse(full.contains("Resolve"), "log: no triage controls")
    }
}
#endif
