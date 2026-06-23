import XCTest
@testable import OuroWorkbenchCore

/// Source-pins for two cold-start onboarding dead-ends in `ProviderConfigSheet` (the native
/// Create-Agent / provider-config form). The App target isn't coverage-gated and can't be
/// click-tested in CI, so we source-pin the wiring the same way `VaultOnboardingWiringTests` /
/// `VaultOnboardingFormSessionResetTests` do.
///
/// BUG 2 — the cold-start (`providerConfigIsNewAgent`) provider picker rendered raw
/// `WorkbenchProvider.allCases`, which INCLUDES `.githubCopilot`. Copilot has no `ouro hatch`
/// argv sink (`supportsColdStartHatch == false`), so picking it + Create Agent always lands in
/// `.unsupportedColdStartSink` — a guaranteed dead end with no in-app path to a boss. The fix
/// drives the cold-start picker off `WorkbenchProvider.coldStartProviders`
/// (= `allCases.filter(\.supportsColdStartHatch)`), NOT raw `allCases`.
///
/// BUG 1 — switching the Provider picker while the form sits in `.needsVaultSetup` kept the stale
/// "Finish setup" affordance, which on tap ran `beginVaultOnboarding()` for the OLD provider. The
/// `onChange(of: provider)` handler cleared `values` / `message` / `providerConfigColdStartMessage`
/// but NOT `providerConfigNeedsVaultSetup` (nor the stashed `providerConfigColdStartProvider`), so
/// the button stayed "Finish setup". The fix also resets those in the onChange handler, returning
/// the form to the normal "Create Agent" state for the newly-picked provider.
final class ProviderColdStartDeadEndWiringTests: XCTestCase {

    // MARK: - BUG 2: cold-start picker filters on supportsColdStartHatch (not raw allCases)

    func testColdStartPickerFiltersOnColdStartCapability() throws {
        let sheet = try providerConfigSheetBody()

        // The cold-start picker must NOT render the raw `WorkbenchProvider.allCases` list as its
        // ForEach source — that's exactly the bug (it leaks the hatch-incapable `.githubCopilot`
        // into the Create-Agent set).
        XCTAssertFalse(
            sheet.contains("ForEach(WorkbenchProvider.allCases)"),
            "the cold-start provider picker must not iterate raw WorkbenchProvider.allCases — that offers hatch-incapable providers (GitHub Copilot) as a dead-end cold-start option"
        )
        // It must drive off the cold-start-eligible set, which filters on `supportsColdStartHatch`.
        XCTAssertTrue(
            sheet.contains("coldStartProviders"),
            "the cold-start provider picker must render `coldStartProviders` (= allCases.filter(\\.supportsColdStartHatch)) so only hatch-capable providers are offered for a brand-new agent"
        )
    }

    // MARK: - BUG 1: onChange(of: provider) resets the stale vault-setup flag

    func testProviderOnChangeResetsVaultSetupFlag() throws {
        let onChange = try providerOnChangeBlock()

        // Switching providers must drop the prior provider's stale `.needsVaultSetup` affordance,
        // otherwise the "Finish setup" button stays and runs the OLD provider's vault chain.
        XCTAssertTrue(
            onChange.contains("providerConfigNeedsVaultSetup = false"),
            "onChange(of: provider) must reset `providerConfigNeedsVaultSetup = false` so switching providers returns the form to the normal Create-Agent state instead of keeping a stale Finish-setup flow for the previous provider"
        )
        // And the stashed cold-start provider that the vault chain reads must be cleared too, so a
        // later vault flow can't fire against the previously-picked provider.
        XCTAssertTrue(
            onChange.contains("providerConfigColdStartProvider = nil"),
            "onChange(of: provider) must clear `providerConfigColdStartProvider = nil` so the (now-reset) Finish-setup chain can't name the previously-picked provider"
        )
    }

    // MARK: - Helpers (mirror VaultOnboardingFormSessionResetTests)

    /// Just the `.onChange(of: provider)` handler body inside `ProviderConfigSheet`.
    private func providerOnChangeBlock() throws -> String {
        let body = try providerConfigSheetBody()
        return try sourceSlice(
            in: body,
            from: ".onChange(of: provider)",
            to: "private func binding(for key:"
        )
    }

    /// The full `ProviderConfigSheet` view declaration (covers the picker + the onChange handler).
    private func providerConfigSheetBody() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "struct ProviderConfigSheet: View {",
            to: "/// U18: demoted to its ONLY unique capability"
        )
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}
