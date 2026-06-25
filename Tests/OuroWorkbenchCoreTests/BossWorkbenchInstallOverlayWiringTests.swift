import XCTest
@testable import OuroWorkbenchCore

/// F9 cold-review — close the re-introduced false-GREEN on the install path and gate the
/// onboarding Register button on `isActionable`.
///
/// The pure overlay decision (`applyingInjectionVerdict(.confirmed(.absent), to: <.registered>)
/// → .toolsNotInjected`) is tested directly in `WorkbenchToolsNotInjectedStatusTests`. These
/// SOURCE-PIN the App-fold wiring (the App target isn't coverage-gated), the same pattern
/// `BossInjectionGateWiringTests` / `BossWatchActionableGateTests` use.
///
/// HIGH — `installWorkbenchMCP(for:)` used to write the post-cleanup registrar snapshot RAW
/// into `bossWorkbenchMCPRegistrationByAgentName` / `bossWorkbenchMCPRegistration`, BYPASSING
/// the injection overlay. A registrar cleanup can't fix a too-old `ouro` (the `workbench_*`
/// strip is upstream of the bundle), so the snapshot read `.registered`; the success path
/// never re-applied the overlay even though the cached verdict was `.confirmed(.absent)`. Net:
/// the `.toolsNotInjected` blocker flipped GREEN. The fix routes the install success path's
/// registration update through `refreshWorkbenchMCPRegistration()` (which overlays). This pin
/// trips if a raw snapshot assignment is re-introduced into `installWorkbenchMCP`.
///
/// LOW — the onboarding `workbench-mcp` Register button was gated ONLY on
/// `step.id == "workbench-mcp"`, not on `isActionable`, so a `.toolsNotInjected` blocker (which
/// registration can't fix, `isActionable == false`) surfaced a futile Register button. The fix
/// ANDs `model.bossWorkbenchMCPRegistration?.isActionable == true`, matching the
/// autonomy-popover + boss-pane buttons. This pin trips if that condition is dropped.
final class BossWorkbenchInstallOverlayWiringTests: XCTestCase {
    // MARK: - HIGH: installWorkbenchMCP must not skip the injection overlay

    func testInstallWorkbenchMCPSuccessPathRoutesThroughTheOverlay() throws {
        let body = try installWorkbenchMCPBody()

        // The success path must update the published registration via the overlay-applying
        // refresh, NOT a raw snapshot assignment that skips `applyingInjectionVerdict`.
        XCTAssertTrue(
            body.contains("refreshWorkbenchMCPRegistration()"),
            "installWorkbenchMCP must route its registration update through refreshWorkbenchMCPRegistration() so the cached injection verdict re-overlays (F9 false-GREEN fix)"
        )

        // No RAW snapshot assignment to the published registration vars — those would skip the
        // overlay and re-open the false-GREEN. (The only legitimate writes to these vars live in
        // `refreshWorkbenchMCPRegistration`, which overlays each one.)
        XCTAssertFalse(
            body.contains("bossWorkbenchMCPRegistrationByAgentName[agent.name] = snapshot"),
            "installWorkbenchMCP must NOT raw-write the registrar snapshot into bossWorkbenchMCPRegistrationByAgentName — that skips applyingInjectionVerdict and re-opens the F9 false-GREEN"
        )
        XCTAssertFalse(
            body.contains("bossWorkbenchMCPRegistration = snapshot"),
            "installWorkbenchMCP must NOT raw-write the registrar snapshot into bossWorkbenchMCPRegistration — that skips applyingInjectionVerdict and re-opens the F9 false-GREEN"
        )
    }

    // MARK: - LOW: the onboarding Register button must require isActionable

    func testOnboardingRepairStepRowRegisterButtonRequiresIsActionable() throws {
        let body = try onboardingRepairStepRowBody()

        // The Register branch is still keyed on the workbench-mcp step id …
        XCTAssertTrue(
            body.contains("step.id == \"workbench-mcp\""),
            "the Register button branch must still key on the workbench-mcp step id"
        )
        // … AND must additionally require the registration be actionable, so a .toolsNotInjected
        // blocker (isActionable == false, registration can't fix it) shows no futile button —
        // matching the autonomy-popover + boss-pane buttons.
        XCTAssertTrue(
            body.contains("step.id == \"workbench-mcp\", model.bossWorkbenchMCPRegistration?.isActionable == true")
                || body.contains("step.id == \"workbench-mcp\" && model.bossWorkbenchMCPRegistration?.isActionable == true"),
            "the Register button must additionally require model.bossWorkbenchMCPRegistration?.isActionable == true (F9 — hide the futile button on a .toolsNotInjected blocker)"
        )
    }

    // MARK: - source pinning helpers (App is not coverage-gated)

    /// Body of `installWorkbenchMCP(for:)` from its declaration to the next top-level
    /// `func` / `private func` boundary.
    private func installWorkbenchMCPBody() throws -> String {
        try slice(
            from: "func installWorkbenchMCP(for agent: OuroAgentRecord) {",
            label: "installWorkbenchMCP"
        )
    }

    /// Body of the `OnboardingRepairStepRow` view struct from its declaration to the next
    /// top-level `private struct` / `struct` boundary — spans the Register button branch.
    private func onboardingRepairStepRowBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        // Access-level-agnostic anchor: U3 widened this view from `private struct` to
        // `struct` (so the view-snapshot tests can instantiate it). `struct …: View {` is a
        // substring of both forms, so this slice helper keeps working either way.
        let start = try XCTUnwrap(
            source.range(of: "struct OnboardingRepairStepRow: View {")?.upperBound,
            "could not find OnboardingRepairStepRow in the App source"
        )
        let tail = source[start...]
        let end = tail.range(of: "\nprivate struct ")?.lowerBound
            ?? tail.range(of: "\nstruct ")?.lowerBound
            ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }

    private func slice(from declaration: String, label: String) throws -> String {
        let source = try WorkbenchAppSource.appSource()
        let start = try XCTUnwrap(
            source.range(of: declaration)?.upperBound,
            "could not find \(label) in the App source"
        )
        let tail = source[start...]
        let end = tail.range(of: "\n    private func ")?.lowerBound
            ?? tail.range(of: "\n    func ")?.lowerBound
            ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }
}
