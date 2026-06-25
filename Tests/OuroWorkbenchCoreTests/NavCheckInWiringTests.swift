import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the nav + check-in batch (FIX 1–4). The App
/// target isn't coverage-gated and can't be click-tested in CI, so — exactly like
/// the other `*WiringTests` — we source-pin the structural wiring that connects
/// each pure Core seam to its App consumer. The pure decisions themselves are
/// exhaustively unit-tested in their own suites (`ActiveEntryResolverTests`,
/// `BossCheckInFailureCopyTests`, `CheckInAvailabilityTests`); these tests pin
/// that the App actually ROUTES through them and branches the way the seam says.
final class NavCheckInWiringTests: XCTestCase {

    // MARK: - FIX 1: focusTerminal / activeEntry honors focus mode

    /// `activeEntry` (what ⌘. Stop / ⌘L Redraw act on) must fold its decision
    /// through the pure `ActiveEntryResolver` seam, NOT inline the old
    /// secondary-pane-or-selection branch that ignored focus mode.
    func testActiveEntryRoutesThroughTheResolverSeam() throws {
        let body = try activeEntryBranch()
        XCTAssertTrue(
            body.contains("ActiveEntryResolver.resolve"),
            "activeEntry must fold its decision through ActiveEntryResolver.resolve"
        )
    }

    /// THE destructive bug: focus mode must feed the resolver so a focused terminal
    /// authoritatively defines the active target. The resolver call must pass both
    /// `terminalFocusEntryID` and a `focusEntryResolves` liveness flag.
    func testActiveEntryFeedsFocusModeIntoTheResolver() throws {
        let body = try activeEntryBranch()
        XCTAssertTrue(
            body.contains("terminalFocusEntryID: terminalFocusEntryID"),
            "the resolver call must pass terminalFocusEntryID so focus mode can win"
        )
        XCTAssertTrue(
            body.contains("focusEntryResolves: terminalFocusEntry != nil"),
            "the resolver call must pass a liveness flag so a stale/dead focus id can't redirect ⌘."
        )
    }

    /// The pre-fix inputs (sidebar selection + the focused-secondary-pane split
    /// state) must still feed the resolver so focus-OFF behavior is unchanged.
    func testActiveEntryStillFeedsSelectionAndSecondaryPane() throws {
        let body = try activeEntryBranch()
        XCTAssertTrue(
            body.contains("selectedEntryID: selectedEntry?.id"),
            "the resolver must still receive the sidebar selection (focus-OFF fallback)"
        )
        XCTAssertTrue(
            body.contains("secondaryPaneIsFocused: activePaneID == .secondary"),
            "the resolver must still receive the focused-secondary-pane state (pre-fix split behavior)"
        )
        XCTAssertTrue(
            body.contains("secondaryPaneEntryID: secondaryPaneEntry?.id"),
            "the resolver must still receive the secondary pane's entry id"
        )
    }

    /// The menu chords route through `activeEntry`, so pinning that the chord
    /// dispatch reads `activeEntry` (not the raw `selectedEntry`) keeps the fix
    /// wired end-to-end: ⌘. / ⌘L hit the focus-mode-aware target.
    func testStopAndRedrawChordsTargetActiveEntry() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("if let entry = model.activeEntry { model.requestStop(entry) }"),
            "the ⌘. Stop chord must target model.activeEntry (focus-mode aware)"
        )
        XCTAssertTrue(
            source.contains("if let entry = model.activeEntry { model.redrawTerminal(entry) }"),
            "the ⌘L Redraw chord must target model.activeEntry (focus-mode aware)"
        )
    }

    // MARK: - FIX 2: the check-in failure copy branches on bossWatchIsEnabled

    /// The transient product-voice line set after a failed ask must come from the
    /// pure `BossCheckInFailureCopy.failureLine` seam (branched on watch state), NOT
    /// the old hardcoded "Workbench will try again shortly" that lied when watch was
    /// off.
    func testCatchPathFailureLineRoutesThroughTheSeamBranchedOnWatchState() throws {
        let source = try WorkbenchAppSource.appSource()
        // The old false-promise literal must be GONE from the App (it now lives in
        // the seam's watch-ON arm only).
        XCTAssertFalse(
            source.contains("bossCheckInAnswer = \"Your agent didn't answer just now. Workbench will try again shortly.\""),
            "the hardcoded always-on retry promise must be replaced by the seam"
        )
        XCTAssertTrue(
            source.contains("bossCheckInAnswer = BossCheckInFailureCopy.failureLine("),
            "the catch path must set bossCheckInAnswer from BossCheckInFailureCopy.failureLine"
        )
        XCTAssertTrue(
            source.contains("bossWatchIsEnabled: bossWatchIsEnabled"),
            "the failure-line call must branch on bossWatchIsEnabled"
        )
    }

    /// The persistent "agent isn't answering" banner (>= 2 failures) must render its
    /// copy from the seam's `persistentBanner`, branched on watch state — so it can't
    /// promise "keeps trying" when nothing is retrying.
    func testPersistentBannerRendersFromTheSeamBranchedOnWatchState() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("BossCheckInFailureCopy.persistentBanner("),
            "the persistent failure banner must render from BossCheckInFailureCopy.persistentBanner"
        )
        // The old hardcoded body strings must be gone from the banner.
        XCTAssertFalse(
            source.contains("Workbench keeps trying, a little less often each time — press Check In to try now."),
            "the hardcoded 'keeps trying' guidance must be replaced by the seam"
        )
        XCTAssertFalse(
            source.contains("times. Workbench is still trying."),
            "the hardcoded 'still trying' detail must be replaced by the seam"
        )
        XCTAssertTrue(
            source.contains("bossWatchIsEnabled: model.bossWatchIsEnabled"),
            "the persistent-banner call must branch on bossWatchIsEnabled"
        )
    }

    // MARK: - FIX 3: cmd-J on an empty attention queue gives feedback (no silent no-op)

    /// "Jump to Next Needing Me" (cmd-J) used to discard the false return when nothing
    /// needs the operator — a silent no-op. The dispatch must now consume the bool
    /// and, when the jump didn't move (false), surface a brief transient status via
    /// the app's existing transient-message channel (`errorMessage`) — no new infra.
    func testJumpToAttentionSurfacesStatusOnTheEmptyQueuePath() throws {
        let source = try WorkbenchAppSource.appSource()
        let branch = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "case .jumpToAttention:",
            to: "\n        case .newTerminal:"
        )
        // The discarded `_ =` must be gone — the return is now consumed.
        XCTAssertFalse(
            branch.contains("_ = model.jumpToNextAttentionSession()"),
            "the cmd-J dispatch must no longer discard the jump's bool return"
        )
        // The false path must set a transient status (reusing errorMessage) so the
        // operator gets feedback instead of a dead key.
        XCTAssertTrue(
            branch.contains("model.jumpToNextAttentionSession()"),
            "the dispatch must still call jumpToNextAttentionSession()"
        )
        XCTAssertTrue(
            branch.contains("errorMessage"),
            "the empty-queue (false) path must surface a transient status via errorMessage (existing infra)"
        )
        XCTAssertTrue(
            branch.contains("Nothing needs you"),
            "the transient status must read 'Nothing needs you right now' (reusing the inbox-zero phrasing)"
        )
    }

    // MARK: - FIX 4: Check-In routes .bossUnreachable to reconnect, not onboarding

    /// `attemptCheckIn` must route each availability case distinctly: `.noBoss` →
    /// onboarding (as before), `.bossUnreachable` → the Harness Status reconnect /
    /// repair affordance (NOT onboarding). The old single `.needsBoss → onboarding`
    /// collapse — which dumped a configured-but-unreachable boss into the full
    /// boss-pick — must be gone.
    func testAttemptCheckInRoutesNoBossAndUnreachableDistinctly() throws {
        let source = try WorkbenchAppSource.appSource()
        let branch = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func attemptCheckIn() {",
            to: "\n    @Published var bossWatchIsEnabled"
        )
        // The old collapsed case must be gone.
        XCTAssertFalse(
            branch.contains("case .needsBoss:"),
            "attemptCheckIn must no longer have a single collapsed .needsBoss case"
        )
        // No-boss still routes to onboarding.
        guard let noBossRange = branch.range(of: "case .noBoss:") else {
            return XCTFail("attemptCheckIn must have an explicit .noBoss case")
        }
        let afterNoBoss = String(branch[noBossRange.lowerBound...])
        XCTAssertTrue(
            afterNoBoss.contains("presentOnboarding()"),
            "the .noBoss case must route to the full onboarding pick"
        )
        // Unreachable routes to the reconnect/repair affordance (Harness Status),
        // NOT onboarding.
        guard let unreachableRange = branch.range(of: "case .bossUnreachable:") else {
            return XCTFail("attemptCheckIn must have an explicit .bossUnreachable case")
        }
        let afterUnreachable = String(branch[unreachableRange.lowerBound...])
        // Inspect only the .bossUnreachable arm (up to the next case).
        let unreachableArm = afterUnreachable.components(separatedBy: "case .running:").first ?? afterUnreachable
        XCTAssertTrue(
            unreachableArm.contains("isHarnessStatusPresented = true"),
            "the .bossUnreachable case must route to the Harness Status reconnect/repair affordance"
        )
        XCTAssertFalse(
            unreachableArm.contains("presentOnboarding()"),
            "the .bossUnreachable case must NOT route to the full onboarding pick"
        )
    }

    /// The model's `checkInAvailability` must still derive from the pure
    /// `CheckInAvailability.resolve` seam (now producing the split), feeding it the
    /// boss usability so the configured-but-unreachable distinction is live.
    func testCheckInAvailabilityResolvesViaTheSeamWithUsability() throws {
        let source = try WorkbenchAppSource.appSource()
        let branch = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "var checkInAvailability: CheckInAvailability {",
            to: "\n    var checkInHelpText: String {"
        )
        XCTAssertTrue(
            branch.contains("CheckInAvailability.resolve("),
            "checkInAvailability must derive from CheckInAvailability.resolve"
        )
        XCTAssertTrue(
            branch.contains("bossIsUsable: currentBossIsUsable"),
            "resolve must be fed the boss usability so .bossUnreachable can be distinguished"
        )
    }

    // MARK: - Slice helpers

    private func activeEntryBranch() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "var activeEntry: ProcessEntry? {",
            to: "\n    var summary: WorkspaceSummary {"
        )
    }

    // MARK: - Helpers (mirror the other *WiringTests)
}
