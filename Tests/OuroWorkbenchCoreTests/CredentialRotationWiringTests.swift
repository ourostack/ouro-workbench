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
        let source = try WorkbenchAppSource.appSource()
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

    // MARK: - re-entrancy gate (the MEDIUM cold-review bug)

    func testBeginCredentialRotationSetsTheInFlightGateBeforeLaunchingTheTerminal() throws {
        let method = try beginCredentialRotationMethod()
        // The MEDIUM bug: without this gate, Connect/Cancel stay enabled with no spinner while the
        // reconnect terminal is live, so a second Connect re-enters and OVERWRITES the exit-matching
        // markers to a second terminal — orphaning the first (its exit fails the entryId/runId match
        // so its re-probe fold never runs). The gate (`providerConfigColdStartInFlight = true`) drives
        // the `.disabled(...)` modifiers on Connect/Cancel. It must be set BEFORE the terminal
        // launches; otherwise the window between launch and gate is exactly the double-fire window.
        let gateRange = try XCTUnwrap(
            method.range(of: "providerConfigColdStartInFlight = true"),
            "rotation must set the in-flight gate so Connect/Cancel are disabled while the terminal runs"
        )
        let launchRange = try XCTUnwrap(
            method.range(of: "createCustomSession("),
            "rotation must launch its terminal via createCustomSession"
        )
        XCTAssertTrue(
            gateRange.lowerBound < launchRange.lowerBound,
            "the in-flight gate must be set BEFORE the terminal launches (that ordering closes the double-fire window)"
        )
    }

    func testConnectAndCancelButtonsAreGatedOnTheInFlightFlag() throws {
        let source = try WorkbenchAppSource.appSource()
        // The gate only prevents re-entry because the form's Connect AND Cancel buttons are disabled
        // on `providerConfigColdStartInFlight`. Pin both disables so a refactor that drops one (and
        // re-opens the double-fire window) trips this.
        let sheet = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "if model.providerConfigColdStartInFlight {",
            to: ".padding()"
        )
        let disableCount = sheet.components(separatedBy: ".disabled(model.providerConfigColdStartInFlight)").count - 1
        XCTAssertGreaterThanOrEqual(
            disableCount, 2,
            "both Connect and Cancel must be .disabled(providerConfigColdStartInFlight) so the gate actually blocks re-entry"
        )
    }

    func testSpinnerLabelBranchesOnFlavorNotHardcodedToCreateCopy() throws {
        let source = try WorkbenchAppSource.appSource()
        // The shared in-flight spinner serves two flavors (cold-start hatch vs reconnect). Its label
        // must render the published `providerConfigInFlightLabel` (which the model sets per-flavor),
        // NOT a hardcoded "Creating your agent…" Text — that copy is wrong for a reconnect.
        let sheet = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "if model.providerConfigColdStartInFlight {",
            to: "Spacer()"
        )
        XCTAssertTrue(
            sheet.contains("Text(model.providerConfigInFlightLabel)"),
            "the spinner label must render the published per-flavor label, not a hardcoded create-copy string"
        )
        XCTAssertFalse(
            sheet.contains("Text(\"Creating your agent…\")"),
            "the spinner must NOT hardcode the cold-start label (it's wrong for the reconnect flavor)"
        )
    }

    func testRotationSetsTheReconnectFlavoredSpinnerLabel() throws {
        let method = try beginCredentialRotationMethod()
        // Rotation must set the per-flavor spinner label to the reconnect-flavored running copy
        // (reusing the Core seam) so the spinner doesn't read "Creating your agent…" during a reconnect.
        XCTAssertTrue(
            method.contains("providerConfigInFlightLabel ="),
            "rotation must set the spinner label so it reads as a reconnect, not a cold-start create"
        )
        XCTAssertTrue(
            method.contains("VaultOnboardingMachine.humanLine(for: .runningVaultTerminal")
                && method.contains("flavor: .rotation"),
            "rotation's spinner label must reuse the seam-free rotation-flavored running line"
        )
    }

    func testCompletionFoldIsNotDuplicatedForRotation() throws {
        let source = try WorkbenchAppSource.appSource()
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
        let source = try WorkbenchAppSource.appSource()
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

    func testRemoveAgentReResolvesTheLiveRecordBeforeDeleting() throws {
        let method = try removeAgentMethod()
        // LOW hardening (cold-review): the armed `agent` captured `bundlePath` when the trash icon was
        // tapped. If the roster re-scanned and the bundle moved between arm and confirm, that path is
        // stale. removeAgent must re-resolve the LIVE record by name from the current scan and decide
        // against THAT (not the stale snapshot), bailing if it's gone.
        XCTAssertTrue(
            method.contains("ouroAgents.first(where:"),
            "removeAgent must re-resolve the live record from the current ouroAgents scan (not trust the armed snapshot)"
        )
        // The decision must be taken against the re-resolved live record, not the stale `agent` arg.
        XCTAssertTrue(
            method.contains("AgentRemoval.decide(for: live)"),
            "removeAgent must decide against the live re-resolved record so a moved bundle isn't deleted by stale path"
        )
        XCTAssertFalse(
            method.contains("AgentRemoval.decide(for: agent)"),
            "removeAgent must NOT decide against the stale armed snapshot"
        )
    }

    func testRemoveAgentIsGatedBehindAConfirmation() throws {
        let source = try WorkbenchAppSource.appSource()
        // The destructive action must sit behind a confirmation that uses the Core confirmation copy.
        XCTAssertTrue(
            source.contains("AgentRemoval.confirmationCopy("),
            "the remove-agent UI must use the seam's confirmation copy"
        )
        // The row must offer a Remove affordance that arms the confirmation (not call removeAgent directly).
        let row = try WorkbenchAppSource.sourceSlice(in: source, from: "struct OuroAgentRowView: View {", to: "private var agentStatusImage:")
        XCTAssertTrue(
            row.contains("agentPendingRemoval") || row.contains("confirmationDialog") || row.contains("RemovalConfirmation"),
            "the agent row must arm a confirmation before removing (no unconfirmed delete)"
        )
    }

    // MARK: - Helpers (mirror VaultOnboardingWiringTests)

    private func submitProviderConfigMethod() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(in: source, from: "func submitProviderConfig(", to: "\n    func ")
    }

    private func beginCredentialRotationMethod() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(in: source, from: "func beginCredentialRotation(", to: "\n    func ")
    }

    private func completeVaultOnboardingMethod() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(in: source, from: "func completeVaultOnboarding(", to: "\n    func ")
    }

    private func removeAgentMethod() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(in: source, from: "func removeAgent(", to: "\n    func ")
    }
}
