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

    // MARK: - Helpers (mirror VaultOnboardingFormSessionResetTests)

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
