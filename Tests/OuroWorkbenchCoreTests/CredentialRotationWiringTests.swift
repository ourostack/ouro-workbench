import XCTest
@testable import OuroWorkbenchCore

/// F6 — durable wiring assertions for existing-agent credential rotation + remove-agent. The App
/// target isn't coverage-gated and can't be click-tested in CI, so we pin the structural wiring
/// against the literal App source text (same approach as `VaultOnboardingWiringTests` for F13).
///
/// Grouped by behavioral risk the prompt flagged (a/b/c), since a source-pin is blind to runtime
/// effects and these are the cases cold-reviews keep catching:
///  - (c) the existing-agent short-circuit is REPLACED by rotation, and only fires for existing
///    agents (the new-agent path is untouched).
///  - rotation reuses F13's terminal-run + the SAME exit-matching markers + `completeVaultOnboarding`
///    (so it inherits F1's `.working` re-probe invariant — risk a).
///  - (b) remove-agent actually mutates the roster/selection/boss, not just deletes the directory.
final class CredentialRotationWiringTests: XCTestCase {

    // MARK: - (c) the short-circuit is replaced by rotation, existing-agent-only

    func testExistingAgentNoLongerShortCircuitsToUnavailableMessage() throws {
        let method = try submitProviderConfigMethod()
        // The old behavior returned the honest-but-dead "isn't available here yet" message and did
        // nothing. That return must be gone from the existing-agent branch.
        XCTAssertFalse(
            method.contains("return ProviderConfigForm.existingAgentRefreshUnavailableMessage("),
            "the existing-agent branch must no longer dead-end on existingAgentRefreshUnavailableMessage — it must drive rotation"
        )
    }

    func testExistingAgentBranchDrivesRotation() throws {
        let method = try submitProviderConfigMethod()
        // The existing-agent guard must now route into the rotation flow.
        let guardRange = try XCTUnwrap(
            method.range(of: "if providerConfigAgentAlreadyExists("),
            "the existing-vs-new detection must still gate the branch"
        )
        let afterGuard = String(method[guardRange.lowerBound...])
        XCTAssertTrue(
            afterGuard.contains("beginCredentialRotation("),
            "an existing agent's submit must drive beginCredentialRotation (not the dead message)"
        )
    }

    func testNewAgentPathStillColdStartHatches() throws {
        let method = try submitProviderConfigMethod()
        // Risk (c): rotation must NOT swallow the new-agent path — the cold-start hatch branch
        // (`.coldStartHatch`) must remain intact and reachable for a brand-new agent.
        XCTAssertTrue(
            method.contains("case let .coldStartHatch(plan):"),
            "the new-agent cold-start hatch branch must remain (rotation is existing-agent-only)"
        )
    }

    // MARK: - rotation reuses F13's terminal + re-probe invariant (risk a)

    func testBeginCredentialRotationMethodExists() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("func beginCredentialRotation("),
            "must add a beginCredentialRotation method"
        )
    }

    func testBeginCredentialRotationBuildsTheUnlockChainViaTheCoreSeam() throws {
        let method = try beginCredentialRotationMethod()
        XCTAssertTrue(
            method.contains("VaultOnboardingCommand.rotateCredentialCommandLine("),
            "rotation must build its command from the pure Core seam, not hand-assemble it"
        )
        // Must NOT reuse the cold-start CREATE chain — an existing agent's vault already exists.
        XCTAssertFalse(
            method.contains("finishSetupCommandLine("),
            "rotation must use the unlock chain, never the cold-start create chain"
        )
    }

    func testBeginCredentialRotationOpensATrustedNativeTerminal() throws {
        let method = try beginCredentialRotationMethod()
        XCTAssertTrue(method.contains("createCustomSession("), "rotation must run in a native terminal")
        XCTAssertTrue(method.contains("launchAfterCreate: true"), "the rotation terminal must launch immediately")
        XCTAssertTrue(method.contains("trust: .trusted"), "the rotation terminal must be .trusted (F3 gate)")
    }

    func testBeginCredentialRotationReusesTheSameExitMatchingMarkers() throws {
        let method = try beginCredentialRotationMethod()
        // Reusing the SAME vaultOnboarding* markers means markTerminated → completeVaultOnboarding
        // (F13's re-probe-gated fold) is reused verbatim — NOT a duplicated fold. That is how
        // rotation inherits F1's `.working` invariant (risk a).
        XCTAssertTrue(
            method.contains("vaultOnboardingEntryID") && method.contains("vaultOnboardingRunID"),
            "rotation must capture the SAME exit-matching markers so completeVaultOnboarding is reused"
        )
        XCTAssertTrue(
            method.contains("vaultOnboardingFlavor = .rotation"),
            "rotation must record the .rotation flavor so completion surfaces rotation-flavored copy"
        )
    }

    func testCompletionFoldIsNotDuplicatedForRotation() throws {
        let source = try appSource()
        // The prompt forbids duplicating F13's fold. There must be exactly ONE call site of
        // afterVaultTerminal (inside completeVaultOnboarding) — rotation reuses it, not re-implements.
        let occurrences = source.components(separatedBy: "VaultOnboardingMachine.afterVaultTerminal(").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "afterVaultTerminal must have exactly one call site (rotation reuses F13's fold, never duplicates it)"
        )
    }

    func testCompletionUsesTheFlavorForFailureCopy() throws {
        let method = try completeVaultOnboardingMethod()
        // The failure copy must be flavored so rotation failures read as reconnect copy, not setup.
        // The flavor is captured into a local before the markers are cleared, then passed into
        // humanLine — pin both the capture and the pass-through.
        XCTAssertTrue(
            method.contains("let flavor = vaultOnboardingFlavor"),
            "completion must capture the flavor before clearing the in-flight markers"
        )
        XCTAssertTrue(
            method.contains("flavor: flavor"),
            "completion must pass the captured flavor into humanLine so rotation failures read correctly"
        )
    }

    // MARK: - (b) remove-agent mutates roster/selection/boss, not just the directory

    func testRemoveAgentMethodExists() throws {
        let source = try appSource()
        XCTAssertTrue(source.contains("func removeAgent("), "must add a removeAgent method")
    }

    func testRemoveAgentDeletesTheBundleViaTheSeamDecision() throws {
        let method = try removeAgentMethod()
        XCTAssertTrue(
            method.contains("AgentRemoval.decide("),
            "removeAgent must take its delete target from the pure AgentRemoval.decide seam"
        )
        XCTAssertTrue(
            method.contains("removeItem("),
            "removeAgent must actually delete the on-disk bundle (the only honest removal)"
        )
    }

    func testRemoveAgentRefreshesTheRosterAfterDeleting() throws {
        let method = try removeAgentMethod()
        // Risk (b): a stale @Published roster would leave the deleted agent dangling in the list.
        XCTAssertTrue(
            method.contains("refreshOuroAgents()"),
            "removeAgent must refresh the roster so the deleted agent stops appearing (no dangling)"
        )
    }

    func testRemoveAgentClearsDanglingSelectionAndBoss() throws {
        let method = try removeAgentMethod()
        // Risk (b) — the F5-class implicit-observer/selection bug: the deleted agent must not remain
        // the current selection or boss. The method must touch both selection and boss state.
        XCTAssertTrue(
            method.contains("selectedAgentName"),
            "removeAgent must clear the detail-pane selection if it pointed at the deleted agent"
        )
        XCTAssertTrue(
            method.contains("state.boss.agentName"),
            "removeAgent must handle the case where the deleted agent was the boss"
        )
    }

    func testRemoveAgentIsGatedBehindAConfirmation() throws {
        let source = try appSource()
        // The destructive action must sit behind a confirmation that uses the Core confirmation copy.
        XCTAssertTrue(
            source.contains("AgentRemoval.confirmationCopy("),
            "the remove-agent UI must use the seam's confirmation copy"
        )
        // The row must offer a Remove affordance that arms the confirmation (not call removeAgent directly).
        let row = try sourceSlice(in: source, from: "struct OuroAgentRowView: View {", to: "private var agentStatusImage:")
        XCTAssertTrue(
            row.contains("agentPendingRemoval") || row.contains("confirmationDialog") || row.contains("RemovalConfirmation"),
            "the agent row must arm a confirmation before removing (no unconfirmed delete)"
        )
    }

    // MARK: - Helpers (mirror VaultOnboardingWiringTests)

    private func submitProviderConfigMethod() throws -> String {
        let source = try appSource()
        return try sourceSlice(in: source, from: "func submitProviderConfig(", to: "\n    func ")
    }

    private func beginCredentialRotationMethod() throws -> String {
        let source = try appSource()
        return try sourceSlice(in: source, from: "func beginCredentialRotation(", to: "\n    func ")
    }

    private func completeVaultOnboardingMethod() throws -> String {
        let source = try appSource()
        return try sourceSlice(in: source, from: "func completeVaultOnboarding(", to: "\n    func ")
    }

    private func removeAgentMethod() throws -> String {
        let source = try appSource()
        return try sourceSlice(in: source, from: "func removeAgent(", to: "\n    func ")
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
