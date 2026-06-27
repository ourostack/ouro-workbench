#if os(macOS)
import XCTest
import SwiftUI
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 Unit 2 — batch B10 (K4 non-View behavioral helpers).
///
/// These are the pure enums / structs / extensions that stayed in `WorkbenchViews.swift` after
/// the Unit-1 split. They render NO captured node through `ViewSnapshotHost.mapNode` (no
/// Text/Image/a11y node), so the snapshot campaign never touched them and they sat as uncovered
/// region-entries on the gated views file. They are NOT snapshot-able — so this drives them with
/// **direct `XCTAssert` logic tests**: construct each, exercise every computed-property / init /
/// switch arm, assert the result. Each arm is mutation-verifiable (mutating the source arm makes
/// the corresponding assertion RED — recorded in `b10-records.md`).
///
/// `SwiftUI.Color`'s standard named colors (`.green`, `.orange`, `.red`, `.secondary`, …) are
/// `Equatable`, so `XCTAssertEqual(helper, .green)` both COVERS the switch arm and ASSERTS its
/// mapping (anneal P2: no executed-but-unasserted region).
final class B10K4HelpersLogicTests: XCTestCase {

    // MARK: - WorkbenchGroupColor.swiftUIColor (10 regions — 8 switch arms + entry + ext)

    /// Every `WorkbenchGroupColor` case maps to its semantic SwiftUI color. Exercises all 8
    /// switch arms (`L10653–10660`) plus the property/extension entry region. `allCases`
    /// guarantees a NEW case can't silently slip past this (it would have no expectation).
    func testWorkbenchGroupColor_swiftUIColor_everyArm() {
        let expected: [WorkbenchGroupColor: SwiftUI.Color] = [
            .gray: .gray,
            .blue: .blue,
            .green: .green,
            .orange: .orange,
            .red: .red,
            .purple: .purple,
            .pink: .pink,
            .teal: .teal,
        ]
        // Every case is in the expectation table (no case un-asserted).
        XCTAssertEqual(Set(WorkbenchGroupColor.allCases), Set(expected.keys),
                       "every WorkbenchGroupColor case must have an asserted swiftUIColor mapping")
        for color in WorkbenchGroupColor.allCases {
            XCTAssertEqual(color.swiftUIColor, expected[color],
                           "WorkbenchGroupColor.\(color.rawValue).swiftUIColor")
        }
    }

    // MARK: - AutonomyReadinessState (.tint / .displayName) (7 regions)

    /// Both computed properties over all three states. `.tint` is a 3-arm color switch
    /// (`L4992/4994/...`), `.displayName` a 3-arm string switch (`L5001–5007`) — note
    /// `.attention` maps to the SHORT label "watch" (not "attention"), so the assertion pins
    /// the exact mapping, not just non-empty.
    func testAutonomyReadinessState_tintAndDisplayName_everyArm() {
        XCTAssertEqual(AutonomyReadinessState.ready.tint, .green)
        XCTAssertEqual(AutonomyReadinessState.attention.tint, .orange)
        XCTAssertEqual(AutonomyReadinessState.blocked.tint, .red)

        XCTAssertEqual(AutonomyReadinessState.ready.displayName, "ready")
        XCTAssertEqual(AutonomyReadinessState.attention.displayName, "watch")
        XCTAssertEqual(AutonomyReadinessState.blocked.displayName, "blocked")
    }

    // MARK: - DetailPaneID <-> PaneLayoutState.Focus (init + persisted) (6 regions)

    /// The persistence bridge round-trips losslessly both directions, every arm
    /// (`L153–157` init, `L163` persisted). Both arms of `init(_:)` and both of `.persisted`.
    func testDetailPaneID_persistenceBridge_everyArm() {
        XCTAssertEqual(DetailPaneID(PaneLayoutState.Focus.primary), .primary)
        XCTAssertEqual(DetailPaneID(PaneLayoutState.Focus.secondary), .secondary)
        XCTAssertEqual(DetailPaneID.primary.persisted, .primary)
        XCTAssertEqual(DetailPaneID.secondary.persisted, .secondary)
        // Round-trip identity through the persisted form.
        for focus in [PaneLayoutState.Focus.primary, .secondary] {
            XCTAssertEqual(DetailPaneID(focus).persisted, focus)
        }
    }

    // MARK: - DetailSplitAxis <-> PaneLayoutState.Axis (init + persisted) (5 regions)

    /// The axis persistence bridge, every arm (`L137–141` init, `.persisted`).
    func testDetailSplitAxis_persistenceBridge_everyArm() {
        XCTAssertEqual(DetailSplitAxis(PaneLayoutState.Axis.vertical), .vertical)
        XCTAssertEqual(DetailSplitAxis(PaneLayoutState.Axis.horizontal), .horizontal)
        XCTAssertEqual(DetailSplitAxis.vertical.persisted, .vertical)
        XCTAssertEqual(DetailSplitAxis.horizontal.persisted, .horizontal)
        for axis in [PaneLayoutState.Axis.vertical, .horizontal] {
            XCTAssertEqual(DetailSplitAxis(axis).persisted, axis)
        }
    }

    // MARK: - BossWorkbenchMCPRegistrationStatus.harnessTint (5 regions)

    /// Every status maps to the right harness tint, including the compound red arm
    /// (`L1681`) that folds 5 statuses into `.red`. Each of the 8 cases is asserted.
    func testBossWorkbenchMCPRegistrationStatus_harnessTint_everyArm() {
        XCTAssertEqual(BossWorkbenchMCPRegistrationStatus.registered.harnessTint, .green)
        XCTAssertEqual(BossWorkbenchMCPRegistrationStatus.needsUpdate.harnessTint, .orange,
                       "cleanup-pending (auto-fixable) reads orange, not red")
        // The compound `.red` arm — every status it folds in.
        for red in [BossWorkbenchMCPRegistrationStatus.notRegistered, .agentMissing,
                    .executableMissing, .invalidConfig, .toolsNotInjected] {
            XCTAssertEqual(red.harnessTint, .red, "\(red.rawValue) → red")
        }
    }

    // MARK: - Optional<BossWorkbenchMCPRegistrationStatus>.harnessTint (2 regions)

    /// The unknown-status tint: a non-nil delegates to the wrapped tint; `nil` reads
    /// `.secondary` (calm — no problem implied before the check runs). Both `??` arms (`L1693`).
    func testOptionalBossMCPStatus_harnessTint_bothArms() {
        let present: BossWorkbenchMCPRegistrationStatus? = .registered
        XCTAssertEqual(present.harnessTint, .green, "non-nil delegates to wrapped tint")
        let absent: BossWorkbenchMCPRegistrationStatus? = nil
        XCTAssertEqual(absent.harnessTint, .secondary, "nil reads secondary, not an alarm color")
    }

    // MARK: - HarnessHealthState (.tint / .displayName) (1 region — the .attention arm)

    /// All three arms of both `.tint` and `.displayName`. The residual uncovered region was
    /// the `.attention` arm (`L1643`); asserting all three keeps every arm covered.
    func testHarnessHealthState_tintAndDisplayName_everyArm() {
        XCTAssertEqual(HarnessHealthState.healthy.tint, .green)
        XCTAssertEqual(HarnessHealthState.attention.tint, .orange)
        XCTAssertEqual(HarnessHealthState.blocked.tint, .red)

        XCTAssertEqual(HarnessHealthState.healthy.displayName, "healthy")
        XCTAssertEqual(HarnessHealthState.attention.displayName, "attention")
        XCTAssertEqual(HarnessHealthState.blocked.displayName, "blocked")
    }

    // MARK: - AutonomyRemediationKind.systemImage (1 region — the .enableWatch arm)

    /// Every repair kind maps to its SF Symbol. The residual region was the `.enableWatch`
    /// arm (`L4943`); asserting every arm pins the icon vocabulary.
    func testAutonomyRemediationKind_systemImage_everyArm() {
        XCTAssertEqual(AutonomyRemediationKind.trustTerminals.systemImage, "checkmark.shield")
        XCTAssertEqual(AutonomyRemediationKind.enableResume.systemImage, "arrow.clockwise")
        XCTAssertEqual(AutonomyRemediationKind.connectTools.systemImage,
                       "point.3.connected.trianglepath.dotted")
        XCTAssertEqual(AutonomyRemediationKind.recover.systemImage, "arrow.uturn.backward")
        XCTAssertEqual(AutonomyRemediationKind.enableWatch.systemImage, "eye")
        XCTAssertEqual(AutonomyRemediationKind.openAtLogin.systemImage, "power")
    }

    // MARK: - HeaderCalmPresentation.BossDotColor.swiftUIColor (1 region — the .orange arm)

    /// Every framework-free dot-color class maps to SwiftUI, including the residual `.orange`
    /// arm (`L5022`). `.neutral` reads `.secondary` (calm no-boss-yet), not an alarm.
    func testHeaderCalmPresentationBossDotColor_swiftUIColor_everyArm() {
        XCTAssertEqual(HeaderCalmPresentation.BossDotColor.neutral.swiftUIColor, .secondary)
        XCTAssertEqual(HeaderCalmPresentation.BossDotColor.green.swiftUIColor, .green)
        XCTAssertEqual(HeaderCalmPresentation.BossDotColor.orange.swiftUIColor, .orange)
        XCTAssertEqual(HeaderCalmPresentation.BossDotColor.red.swiftUIColor, .red)
    }

    // MARK: - WorkbenchToolsInjectionRecorder (record / snapshot) (2 regions)

    /// The thread-safe injection-verdict sink: `record(agentName:outcome:)` stores per-agent,
    /// `snapshot()` reads back, and last-write-per-agent wins. Drives the `record` body
    /// (`L1659`) + the `snapshot` return (`L1666`).
    func testWorkbenchToolsInjectionRecorder_recordAndSnapshot() {
        let rec = WorkbenchToolsInjectionRecorder()
        XCTAssertTrue(rec.snapshot().isEmpty, "fresh recorder is empty")

        rec.record(agentName: "alpha", outcome: .unconfirmed)
        rec.record(agentName: "beta", outcome: .confirmed(.present))
        var snap = rec.snapshot()
        XCTAssertEqual(snap["alpha"], .unconfirmed)
        XCTAssertEqual(snap["beta"], .confirmed(.present))
        XCTAssertEqual(snap.count, 2)

        // Last write per agent wins (one probe per bringup).
        rec.record(agentName: "alpha", outcome: .confirmed(.absent))
        snap = rec.snapshot()
        XCTAssertEqual(snap["alpha"], .confirmed(.absent), "last write per agent wins")
        XCTAssertEqual(snap.count, 2, "re-record does not add a new key")
    }

    // MARK: - WorkbenchImportApplyResult (persisted default / headline / detail) (4 regions)

    /// `headline` over its (createdCount, groupNames.count) arms — the residual was the
    /// `(0, _)` "Nothing imported" arm (`L10616`); `detail` over its present/absent and
    /// already-present arms (`L10637/10643`); the `persisted` default-true region (`L10608`).
    func testWorkbenchImportApplyResult_headlineDetailAndPersistedDefault() {
        func make(created: Int, groups: [String], skipped: [String] = [],
                  alreadyPresent: Int = 0) -> WorkbenchImportApplyResult {
            WorkbenchImportApplyResult(createdCount: created, groupNames: groups,
                                       skippedNames: skipped, alreadyPresentCount: alreadyPresent,
                                       firstSelectedEntryID: nil)
        }

        // headline — all four (createdCount, groupNames.count) arms.
        XCTAssertEqual(make(created: 0, groups: []).headline, "Nothing imported")
        XCTAssertEqual(make(created: 1, groups: ["g"]).headline, "Brought back 1 terminal")
        XCTAssertEqual(make(created: 3, groups: ["g"]).headline,
                       "Brought back 3 terminals in 1 workspace")
        XCTAssertEqual(make(created: 5, groups: ["a", "b"]).headline,
                       "Brought back 5 terminals across 2 workspaces")

        // detail — the all-empty (no imports, nothing to say) → nil arm.
        XCTAssertNil(make(created: 0, groups: []).detail,
                     "no groups, no skips, no imports → nil detail")

        // detail — already-present surfaced, skipped surfaced, duplicate-cleanup hint appended.
        let detail = make(created: 2, groups: ["Work"], skipped: ["bad"], alreadyPresent: 3).detail
        XCTAssertNotNil(detail)
        XCTAssertTrue(detail?.contains("Work") == true, "group name surfaced")
        XCTAssertTrue(detail?.contains("Skipped: bad") == true, "skip surfaced")
        XCTAssertTrue(detail?.contains("3 already present") == true,
                      "already-present count surfaced (not a silent drop)")
        XCTAssertTrue(detail?.contains(WorkbenchOnboardingNarrative.duplicateCleanup) == true,
                      "duplicate-cleanup hint appended when there are imports")

        // `persisted` defaults to true — this construction OMITS `persisted`, exercising the
        // L10608 default-value region. (`firstSelectedEntryID` has no default, so it's supplied.)
        let defaulted = WorkbenchImportApplyResult(createdCount: 1, groupNames: ["g"],
                                                   skippedNames: [], firstSelectedEntryID: nil)
        XCTAssertTrue(defaulted.persisted, "persisted defaults to true when omitted")
        XCTAssertEqual(defaulted.alreadyPresentCount, 0, "alreadyPresentCount defaults to 0")
        XCTAssertTrue(defaulted.hasImports, "createdCount > 0 → hasImports")
        XCTAssertFalse(make(created: 0, groups: []).hasImports,
                       "createdCount == 0 → not hasImports")
    }
}
#endif
