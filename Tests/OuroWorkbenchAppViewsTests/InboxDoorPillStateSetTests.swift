#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C2-1 — `InboxDoorPill` (BossDashboardView dashboard strip; the open-inbox "door"
/// pill, #U22). The classification first-pass binned this BRANCHLESS, but the C1
/// precedent (`SidebarCountBadge`, reconfirmed LOGIC) sets the standard: a data-driven
/// value substituted into a CAPTURED node (the host whitelist captures `Text` strings
/// + a11y label/value) is logic-bearing — the harness records the flip. `InboxDoorPill`
/// renders `door.label` ("N waiting on you") as a `Text` and `door.accessibilityLabel`
/// (which pluralizes on `count`) — both flip with the resolved presentation → **LOGIC,
/// re-confirmed at execution and snapshotted here** (the doc invites exactly this:
/// "a few may flip to logic-bearing and join the cluster").
///
/// **Provenance (P2).** `InboxDoorPresentation` is provenance-built through its REAL
/// producer — `InboxDoorPresentation.resolve(state:now:)` — fed a `WorkspaceState`
/// whose `decisionLog` carries real `BossInboxDecision`s recorded via the production
/// `state.recordDecision(_:)` mutation. The pill's count + top-severity tint then read
/// the SAME derivation the live boss pane uses (`state.openInbox(now:)` →
/// `DecisionSeverity.of`). We do NOT hand-assemble the presentation struct; we drive
/// the real resolver. The pill is then instantiated DIRECTLY via its `View`
/// initializer (the leaf seam; the SU3r/C0-chip precedent).
///
/// **Determinism (P3).** A single canonical fixed `Date` (`Self.fixedNow`) governs
/// every decision's `occurredAt` and the resolve `now:`, so `isOpenForTriage` is
/// deterministic; the prompts carry no machine path / clock / UUID-in-text. The pill's
/// `.help(...)` tooltip is dropped by the host (AN-004). Byte-identical twice +
/// `!contains("/Users/")`.
///
/// **Enumerated state-set (the resolved presentation's captured-node flips):**
///   - `normalOne`  — a single `.autoAdvance` (recorded, not applied) decision →
///       count 1, top-severity `.normal` → "1 waiting on you" + singular a11y label.
///   - `elevatedTwo` — two `.escalate` decisions → count 2, top-severity `.elevated`
///       → "2 waiting on you" + plural a11y label.
///   - `none` — an empty/triaged inbox → `resolve` returns `nil` → the pill is never
///       constructed (asserted at the resolver, the calm/absent gate the door promises).
///
/// **Severity is a real STATE but a DROPPED node (the `GitBranchChip.dirty` precedent).**
/// The top-severity drives only the pill TINT (`Color`), which the host whitelist drops —
/// so a `.critical` (`rm -rf` unsafe-floored) door and an `.elevated` door at the SAME
/// count serialize byte-identically. Snapshotting both would be a redundant reference
/// (P4e). We therefore enumerate the captured trees by COUNT (the only captured driver),
/// and assert the severity STATE via provenance (`topSeverity`) — exactly how
/// `GitBranchChip.dirty` asserts the geometry-only dirty dot.
@MainActor
final class InboxDoorPillStateSetTests: XCTestCase {

    /// A single canonical epoch — `2026-01-02T03:04:05Z` — for every decision's
    /// `occurredAt` and the resolve `now:`, so the open-inbox derivation is fixed.
    private static let fixedNow = Date(timeIntervalSince1970: 1_767_323_045)

    // MARK: - Provenance fixture (the REAL resolver seam)

    /// Record `decisions` into a fresh `WorkspaceState` via the production
    /// `recordDecision(_:)` mutation, then resolve the door through the real producer.
    private func door(_ decisions: [BossInboxDecision]) -> InboxDoorPresentation? {
        var state = WorkspaceState()
        for decision in decisions {
            state.recordDecision(decision)
        }
        return InboxDoorPresentation.resolve(state: state, now: Self.fixedNow)
    }

    private func decision(
        prompt: String,
        kind: BossDecisionKind,
        proposedInput: String? = nil,
        secondsAgo: TimeInterval = 0
    ) -> BossInboxDecision {
        BossInboxDecision(
            occurredAt: Self.fixedNow.addingTimeInterval(-secondsAgo),
            source: "boss:fixture",
            prompt: prompt,
            kind: kind,
            proposedInput: proposedInput,
            reasoning: "fixture"
        )
    }

    private func pill(_ door: InboxDoorPresentation) -> InboxDoorPill {
        InboxDoorPill(door: door, action: {})
    }

    // MARK: - Enumerated state-set

    func testDoor_normalOne() throws {
        let presentation = try XCTUnwrap(door([
            decision(prompt: "Continue with step 3?", kind: .autoAdvance, proposedInput: "y")
        ]))
        XCTAssertEqual(presentation.count, 1, "provenance: one open decision")
        XCTAssertEqual(presentation.topSeverity, .normal, "provenance: autoAdvance → normal")
        XCTAssertEqual(presentation.label, "1 waiting on you")
        try assertViewSnapshot(of: pill(presentation), named: "InboxDoorPill.normalOne")
    }

    func testDoor_elevatedTwo() throws {
        let presentation = try XCTUnwrap(door([
            decision(prompt: "Need a human call on the rename", kind: .escalate, secondsAgo: 10),
            decision(prompt: "Approve the migration plan?", kind: .escalate, secondsAgo: 0)
        ]))
        XCTAssertEqual(presentation.count, 2, "provenance: two open decisions")
        XCTAssertEqual(presentation.topSeverity, .elevated, "provenance: escalate → elevated")
        XCTAssertEqual(presentation.label, "2 waiting on you")
        try assertViewSnapshot(of: pill(presentation), named: "InboxDoorPill.elevatedTwo")
    }

    /// Severity provenance (no redundant snapshot — see the doc comment): an `rm -rf`
    /// prompt floors the door to `.critical`, which drives only the dropped TINT. We
    /// assert the STATE via the real resolver, and confirm the captured tree matches the
    /// same-count `.elevated` door byte-for-byte (the geometry-only-difference proof).
    func testDoor_criticalSeverity_isProvenanceOnly_droppedTint() throws {
        let critical = try XCTUnwrap(door([
            decision(prompt: "Run `rm -rf build/`?", kind: .autoAdvance, proposedInput: "y", secondsAgo: 5),
            decision(prompt: "Need a human call on the rename", kind: .escalate, secondsAgo: 0)
        ]))
        XCTAssertEqual(critical.topSeverity, .critical,
                       "provenance: the rm -rf prompt floors to critical (PromptSafetyClassifier)")
        XCTAssertEqual(critical.count, 2, "provenance: two open decisions")

        let elevated = try XCTUnwrap(door([
            decision(prompt: "A", kind: .escalate, secondsAgo: 10),
            decision(prompt: "B", kind: .escalate, secondsAgo: 0)
        ]))
        XCTAssertEqual(elevated.topSeverity, .elevated)
        // Same count, different severity → identical captured tree (tint is dropped).
        let criticalTree = try ViewSnapshotHost.snapshotText(of: pill(critical))
        let elevatedTree = try ViewSnapshotHost.snapshotText(of: pill(elevated))
        XCTAssertEqual(criticalTree, elevatedTree,
                       "severity drives only the dropped tint → same-count trees are byte-identical")
    }

    func testDoor_none_resolvesNilNeverRenders() throws {
        // The calm/absent gate: an empty inbox resolves to nil, so the pill is NEVER
        // constructed (the caller guards on `model.inboxDoor != nil`). The contract
        // the door promises — no dead zero-count button.
        XCTAssertNil(door([]), "empty inbox → nil → no door")
    }

    // MARK: - Negative control (P2 mutation-verified): the resolved count/severity flips the tree

    /// The resolved presentation's count + severity drive the captured `Text` label and
    /// the a11y label. This is the load-bearing proof the pill renders its DATA — the
    /// exact value-flip standard the C1 `SidebarCountBadge` reconfirm established.
    func testDoor_negativeControl_countAndSeverityFlipTree() throws {
        let one = try ViewSnapshotHost.snapshotText(of: pill(try XCTUnwrap(door([
            decision(prompt: "Continue?", kind: .autoAdvance, proposedInput: "y")
        ]))))
        let two = try ViewSnapshotHost.snapshotText(of: pill(try XCTUnwrap(door([
            decision(prompt: "Continue?", kind: .escalate, secondsAgo: 10),
            decision(prompt: "Approve?", kind: .escalate, secondsAgo: 0)
        ]))))

        XCTAssertNotEqual(one, two, "the resolved count must drive the captured Text + a11y label")
        XCTAssertTrue(one.contains(#"text="1 waiting on you""#), "one: the label renders:\n\(one)")
        XCTAssertTrue(two.contains(#"text="2 waiting on you""#), "two: the label renders:\n\(two)")
        // The a11y label pluralizes on count — a second captured flip.
        XCTAssertTrue(one.contains("1 decision waiting on you"), "one: singular a11y label:\n\(one)")
        XCTAssertTrue(two.contains("2 decisions waiting on you"), "two: plural a11y label:\n\(two)")
    }

    // MARK: - Determinism (P3)

    func testDoor_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, [BossInboxDecision])] = [
            ("normalOne", [decision(prompt: "Continue?", kind: .autoAdvance, proposedInput: "y")]),
            ("elevatedTwo", [
                decision(prompt: "A", kind: .escalate, secondsAgo: 10),
                decision(prompt: "B", kind: .escalate, secondsAgo: 0)
            ]),
            ("criticalMixed", [
                decision(prompt: "Run `rm -rf build/`?", kind: .autoAdvance, proposedInput: "y", secondsAgo: 5),
                decision(prompt: "Need a human call", kind: .escalate, secondsAgo: 0)
            ])
        ]
        for (name, decisions) in cases {
            let presentation = try XCTUnwrap(door(decisions))
            let a = try ViewSnapshotHost.snapshotText(of: pill(presentation))
            let b = try ViewSnapshotHost.snapshotText(of: pill(presentation))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
