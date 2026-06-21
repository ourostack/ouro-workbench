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

    // MARK: - Unit 3 — beginVaultOnboarding + the "Finish setup" affordance

    func testBeginVaultOnboardingMethodExists() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("func beginVaultOnboarding("),
            "must add a `beginVaultOnboarding` method that runs the recovery chain"
        )
    }

    func testBeginVaultOnboardingBuildsTheChainViaTheCoreCommand() throws {
        let method = try beginVaultOnboardingMethod()
        XCTAssertTrue(
            method.contains("VaultOnboardingCommand.finishSetupCommandLine("),
            "the recovery command must be built by the pure Core seam, not hand-assembled in the App"
        )
    }

    func testBeginVaultOnboardingOpensATrustedNativeTerminal() throws {
        let method = try beginVaultOnboardingMethod()
        XCTAssertTrue(
            method.contains("createCustomSession("),
            "the recovery chain must run in a native terminal via createCustomSession"
        )
        XCTAssertTrue(
            method.contains("launchAfterCreate: true"),
            "the recovery terminal must launch immediately"
        )
        XCTAssertTrue(
            method.contains("trust: .trusted"),
            "the recovery terminal must be .trusted so F3's gate doesn't block the human prompts"
        )
    }

    func testBeginVaultOnboardingCapturesTheOnboardingRunForExitMatching() throws {
        let method = try beginVaultOnboardingMethod()
        // The new entry id + runId must be stashed so markTerminated can match the exit.
        XCTAssertTrue(
            method.contains("vaultOnboardingEntryID") && method.contains("vaultOnboardingRunID"),
            "must capture the onboarding entry id + runId so markTerminated can detect its exit"
        )
    }

    func testFinishSetupAffordanceIsGatedOnTheVaultFlag() throws {
        let source = try appSource()
        // The sheet shows "Finish setup" ONLY when providerConfigNeedsVaultSetup, and it calls
        // beginVaultOnboarding. Pin both in the ProviderConfigSheet view.
        let sheet = try sourceSlice(
            in: source,
            from: "struct ProviderConfigSheet: View {",
            to: "private func binding(for key: String)"
        )
        XCTAssertTrue(
            sheet.contains("providerConfigNeedsVaultSetup"),
            "the sheet must gate the Finish setup affordance on providerConfigNeedsVaultSetup"
        )
        XCTAssertTrue(
            sheet.contains("beginVaultOnboarding()"),
            "the Finish setup affordance must call model.beginVaultOnboarding()"
        )
    }

    // MARK: - Unit 4 — completeVaultOnboarding + exit detection

    func testMarkTerminatedDetectsTheOnboardingSessionExit() throws {
        let method = try markTerminatedMethod()
        // markTerminated must match the onboarding entry/runId and route to completion, decoding
        // the exit via ProcessExitStatus. Both the normal and detached-persistent branches must
        // be hooked (a one-shot screen session can route through either).
        XCTAssertTrue(
            method.contains("vaultOnboardingEntryID") && method.contains("vaultOnboardingRunID"),
            "markTerminated must recognize the onboarding session by its entry id + runId"
        )
        XCTAssertTrue(
            method.contains("completeVaultOnboarding("),
            "markTerminated must hand the onboarding exit to completeVaultOnboarding"
        )
    }

    func testCompleteVaultOnboardingReprobesAndFoldsViaTheMachine() throws {
        let method = try completeVaultOnboardingMethod()
        XCTAssertTrue(
            method.contains("runColdStartProviderCheck("),
            "completion must RE-PROBE via F1's runColdStartProviderCheck (the authoritative signal)"
        )
        XCTAssertTrue(
            method.contains("VaultOnboardingMachine.afterVaultTerminal("),
            "completion must fold exit + re-probe via the pure machine"
        )
    }

    func testCompleteVaultOnboardingGatesReadyOnTheMachine() throws {
        let method = try completeVaultOnboardingMethod()
        // The .ready side-effects (F1's exact ones) must sit behind a `.ready` arm of the machine
        // result — never reachable on a bare clean exit.
        guard let readyRange = method.range(of: "case .ready:") else {
            return XCTFail("completion must switch on the machine result with an explicit .ready arm")
        }
        let afterReady = String(method[readyRange.lowerBound...])
        XCTAssertTrue(
            afterReady.contains("runFirstRunBootstrap()"),
            "the .ready arm must reuse F1's runFirstRunBootstrap side-effect"
        )
        XCTAssertTrue(
            afterReady.contains("isProviderConfigPresented = false"),
            "the .ready arm must dismiss the form like F1's ready path"
        )
        XCTAssertTrue(
            afterReady.contains("succeeded: true"),
            "the .ready arm must log success like F1's ready path"
        )
        // Success clears the retry flag.
        XCTAssertTrue(
            afterReady.contains("providerConfigNeedsVaultSetup = false"),
            "a verified-ready recovery must clear the needs-vault flag"
        )
    }

    func testCompleteVaultOnboardingKeepsRetryOnFailure() throws {
        let method = try completeVaultOnboardingMethod()
        // On a `.failed` machine result, surface the seam-free humanLine and KEEP the finish-setup
        // affordance available for retry (do NOT clear providerConfigNeedsVaultSetup, do NOT log
        // success). Pin the seam-free human copy comes from the Core machine.
        XCTAssertTrue(
            method.contains("VaultOnboardingMachine.humanLine("),
            "a failed recovery must surface the seam-free Core humanLine"
        )
        guard let failedRange = method.range(of: "case let .failed(") ?? method.range(of: "case .failed(") else {
            return XCTFail("completion must have an explicit .failed arm")
        }
        let afterFailed = String(method[failedRange.lowerBound...])
        XCTAssertFalse(
            afterFailed.contains("isProviderConfigPresented = false"),
            "a failed recovery must NOT dismiss the form (the user retries)"
        )
    }

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)

    private func beginVaultOnboardingMethod() throws -> String {
        let source = try appSource()
        return try sourceSlice(in: source, from: "func beginVaultOnboarding(", to: "\n    func ")
    }

    private func completeVaultOnboardingMethod() throws -> String {
        let source = try appSource()
        return try sourceSlice(in: source, from: "func completeVaultOnboarding(", to: "\n    func ")
    }

    private func markTerminatedMethod() throws -> String {
        let source = try appSource()
        // `markTerminated` is immediately followed by the `shouldPostExitNotification` helper
        // (its doc-comment is the slice boundary).
        return try sourceSlice(
            in: source,
            from: "func markTerminated(entryId:",
            to: "/// Whether enough time has passed since the last unexpected-exit"
        )
    }


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
