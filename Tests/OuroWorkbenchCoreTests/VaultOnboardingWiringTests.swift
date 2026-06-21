import XCTest
@testable import OuroWorkbenchCore

/// F13 — durable wiring assertions for in-app vault onboarding (the `.needsVaultSetup` cold-start
/// recovery path). The App target isn't coverage-gated and can't be click-tested in CI, so we pin
/// the structural wiring the same way `ColdStartHonestWiringTests` (F1) does: source-pin the
/// branches, method calls, and gated side-effects against the literal App source text.
///
/// Grouped by unit:
///  - Unit 2: the `.coldStartHatch` outcome switch SPLITS `.needsVaultSetup` from `.failed`, sets
///    `providerConfigNeedsVaultSetup`, and stashes the provider into `providerConfigColdStartProvider`.
///  - Unit 3: `beginVaultOnboarding()` builds the chain via `VaultOnboardingCommand` and opens a
///    `.trusted` native terminal via `createCustomSession(_:launchAfterCreate:)`.
///  - Unit 4: `markTerminated` detects the onboarding session's exit and calls
///    `completeVaultOnboarding`, which re-probes via `runColdStartProviderCheck`, folds via
///    `VaultOnboardingMachine.afterVaultTerminal`, and gates the F1 `.ready` side-effects on it.
final class VaultOnboardingWiringTests: XCTestCase {

    // MARK: - Unit 2 — stash the provider + split the shared arm

    func testNewPublishedPropertiesExist() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("var providerConfigNeedsVaultSetup"),
            "must add a published `providerConfigNeedsVaultSetup` flag"
        )
        XCTAssertTrue(
            source.contains("var providerConfigColdStartProvider"),
            "must add a published `providerConfigColdStartProvider` to stash the typed-in provider"
        )
    }

    func testNeedsVaultSetupArmIsSplitFromFailed() throws {
        let branch = try coldStartBranch()
        // The shared `case .needsVaultSetup, .failed:` arm must be gone — split into two arms.
        XCTAssertFalse(
            branch.contains("case .needsVaultSetup, .failed:"),
            "the `.needsVaultSetup` arm must be split out from `.failed` (it routes to finish-setup)"
        )
        XCTAssertTrue(
            branch.contains("case .needsVaultSetup:"),
            "there must be a dedicated `.needsVaultSetup` arm"
        )
        XCTAssertTrue(
            branch.contains("case .failed:"),
            "there must still be a dedicated `.failed` arm"
        )
    }

    func testNeedsVaultSetupArmSetsTheFlagAndStashesTheProvider() throws {
        let arm = try needsVaultSetupArm()
        XCTAssertTrue(
            arm.contains("providerConfigNeedsVaultSetup = true"),
            "the `.needsVaultSetup` arm must set providerConfigNeedsVaultSetup = true"
        )
        XCTAssertTrue(
            arm.contains("providerConfigColdStartProvider = provider"),
            "the `.needsVaultSetup` arm must stash the typed-in provider for the recovery chain"
        )
    }

    func testFailedArmDoesNotSetTheVaultFlag() throws {
        let failed = try failedArm()
        XCTAssertFalse(
            failed.contains("providerConfigNeedsVaultSetup = true"),
            "an honest `.failed` (not needs-vault) must NOT offer the finish-setup flow"
        )
    }

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)

    /// The `.coldStartHatch` branch text (start marker → the next method's doc-comment).
    private func coldStartBranch() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "case let .coldStartHatch(plan):",
            to: "/// Open the native provider-config form in response to a non-secret-bearing"
        )
    }

    /// The `.needsVaultSetup` arm only (from its `case` to the next `case .failed:`).
    private func needsVaultSetupArm() throws -> String {
        let branch = try coldStartBranch()
        return try sourceSlice(in: branch, from: "case .needsVaultSetup:", to: "case .failed:")
    }

    /// The `.failed` arm only (from its `case` to the end of the switch `}`).
    private func failedArm() throws -> String {
        let branch = try coldStartBranch()
        let start = try XCTUnwrap(branch.range(of: "case .failed:")?.lowerBound)
        return String(branch[start...])
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
