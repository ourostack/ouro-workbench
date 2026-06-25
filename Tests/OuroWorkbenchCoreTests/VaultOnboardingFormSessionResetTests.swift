import XCTest
@testable import OuroWorkbenchCore

/// F13 (cold-review follow-up) — the vault-onboarding cold-start flags
/// (`providerConfigNeedsVaultSetup`, `providerConfigColdStartProvider`,
/// `providerConfigColdStartMessage`) are cleared ONLY on a verified-ready completion. Neither
/// form-open method reset them, and the sheet has no `onDismiss` reset — so hitting
/// `.needsVaultSetup` for agent A, dismissing, then opening the form for a DIFFERENT agent B made
/// B wrongly show "Finish setup" carrying A's stale stashed provider. It was never a safety hole
/// (`beginVaultOnboarding` re-derives the agent from the (reset) `providerConfigAgentName` and still
/// gates `.ready` on a live re-probe), but it's a confusing wrong affordance.
///
/// The fix resets all three at the TOP of BOTH form-open methods so each form session starts clean.
/// The App target isn't coverage-gated and can't be click-tested in CI, so we source-pin the reset
/// the same way `VaultOnboardingWiringTests` / `ColdStartHonestWiringTests` do.
final class VaultOnboardingFormSessionResetTests: XCTestCase {

    private let resets = [
        "providerConfigNeedsVaultSetup = false",
        "providerConfigColdStartProvider = nil",
        "providerConfigColdStartMessage = nil",
    ]

    func testPresentProviderConfigFormResetsTheVaultOnboardingFlags() throws {
        let method = try presentProviderConfigFormMethod()
        for reset in resets {
            XCTAssertTrue(
                method.contains(reset),
                "presentProviderConfigForm must reset `\(reset)` so a fresh form session can't inherit a prior agent's stale vault-onboarding state"
            )
        }
    }

    func testPresentNewAgentProviderConfigFormResetsTheVaultOnboardingFlags() throws {
        let method = try presentNewAgentProviderConfigFormMethod()
        for reset in resets {
            XCTAssertTrue(
                method.contains(reset),
                "presentNewAgentProviderConfigForm must reset `\(reset)` so a fresh form session can't inherit a prior agent's stale vault-onboarding state"
            )
        }
    }

    // MARK: - Helpers (mirror VaultOnboardingWiringTests)

    private func presentProviderConfigFormMethod() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func presentProviderConfigForm(agentName:",
            to: "/// Present the provider form to CREATE A NEW AGENT"
        )
    }

    private func presentNewAgentProviderConfigFormMethod() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func presentNewAgentProviderConfigForm(",
            to: "/// U18: the install sheet is demoted"
        )
    }
}
