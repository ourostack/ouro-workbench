import XCTest
@testable import OuroWorkbenchCore

/// Source-pins for the first-run cold-start retry/routing wiring in `FirstRunBootstrapView`. The
/// App target isn't coverage-gated and can't be click-tested in CI, so we pin the SwiftUI wiring
/// the same way `ProviderColdStartDeadEndWiringTests` does (read the app source, assert on the
/// `FirstRunBootstrapView` body's literal wiring).
///
/// FIX 1 — `.needsAttention` (the actionable cold-start failure mode) was dead copy: the row said
/// "you can try again" but the view rendered NO retry control there (only the provider gate had a
/// button), and an in-place transition won't re-fire `.onAppear`. The view must render a Try-again
/// button gated on the pure `showsRetryButton` property and call the re-runnable retry entry
/// `runFirstRunBootstrap()`.
///
/// FIX 2 — an invalid-boss cold start (`.failedInvalidAgent` → `.invalidBoss`) must route to the
/// boss-CHOICE surface (`presentOnboarding()`, which lands on Choose Boss), NOT the generic
/// provider-reconnect retry. The view branches on the carried `attentionReason` so invalid-boss
/// gets choose-boss and a failed step gets retry.
final class FirstRunBootstrapRetryWiringTests: XCTestCase {

    // MARK: - FIX 1: a Try-again button gated on the actionable failure mode, calling the retry entry

    func testNeedsAttentionRendersARetryControl() throws {
        let body = try firstRunBootstrapViewBody()
        // The view must gate its retry control on the pure `showsRetryButton` property (true only
        // for `.needsAttention`), NOT hard-code a mode check that could drift.
        XCTAssertTrue(
            body.contains("showsRetryButton"),
            "FirstRunBootstrapView must gate its retry control on the pure `showsRetryButton` mode property so the button appears ONLY in the actionable failure mode"
        )
    }

    func testRetryControlCallsTheReRunnableRetryEntry() throws {
        let body = try firstRunBootstrapViewBody()
        // The retry control's action must call the re-runnable bootstrap retry entry. Without this,
        // the "you can try again" copy is dead (the bug).
        XCTAssertTrue(
            body.contains("runFirstRunBootstrap()"),
            "the Try-again control must call `model.runFirstRunBootstrap()` — the re-runnable bootstrap retry entry — otherwise the retry copy is dead"
        )
    }

    // MARK: - FIX 2: invalid-boss routes to the choose-boss surface; failed-step routes to retry

    func testInvalidBossRoutesToChooseBossSurface() throws {
        let body = try firstRunBootstrapViewBody()
        // The view must branch on the carried attention reason so it can route invalid-boss to the
        // boss-CHOICE surface instead of the generic provider-reconnect retry.
        XCTAssertTrue(
            body.contains("attentionReason"),
            "FirstRunBootstrapView must read `presentation.attentionReason` to distinguish invalid-boss (choose-boss) from a failed step (retry)"
        )
        // The choose-boss route is `presentOnboarding()`, which lands on the Choose Boss page.
        XCTAssertTrue(
            body.contains("presentOnboarding()"),
            "the invalid-boss recovery must route to the boss-CHOICE surface via `model.presentOnboarding()` (lands on Choose Boss), not the provider-reconnect retry"
        )
        // The route decision must come from the pure Core seam, never an ad-hoc string compare.
        XCTAssertTrue(
            body.contains(".chooseBoss"),
            "the view must route off the pure `recoveryAction` (.chooseBoss / .retry) seam so invalid-boss vs failed-step routing stays in tested Core"
        )
    }

    // MARK: - Helpers (mirror ProviderColdStartDeadEndWiringTests)

    /// The full `FirstRunBootstrapView` view declaration (covers the mode switch + the buttons).
    private func firstRunBootstrapViewBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        // Access-level-agnostic `from:` anchor: U3 widened this view from `private struct`
        // to `struct` (so the view-snapshot tests can instantiate it). `struct …: View {` is
        // a substring of both forms; `FirstRunStepRow` stays `private`, so the `to:` anchor
        // is unchanged.
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct FirstRunBootstrapView: View {",
            to: "private struct FirstRunStepRow: View {"
        )
    }
}
