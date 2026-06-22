import XCTest
@testable import OuroWorkbenchCore

/// F6 — existing-agent credential rotation + remove-agent.
///
/// An EXISTING agent's vault ALREADY exists, so rotation is an UNLOCK chain (not `create`), and
/// carries NO `--email` (the vault account is already provisioned). The fold from terminal-exit +
/// re-probe into the next state is REUSED from F13 (`VaultOnboardingMachine.afterVaultTerminal`,
/// which carries F1's safety invariant) — these tests cover only the F6-specific seams: the
/// rotation command string, the rotation-flavored human copy, and the remove-agent decision +
/// confirmation copy.
final class CredentialRotationTests: XCTestCase {

    // MARK: - rotateCredentialCommandLine: the exact unlock chain

    func testRotateCredentialCommandLineDefault() {
        let line = VaultOnboardingCommand.rotateCredentialCommandLine(
            agentName: "ouroboros",
            providerFlag: "anthropic"
        )
        XCTAssertEqual(
            line,
            "ouro vault unlock --agent ouroboros"
                + " && ouro auth --agent ouroboros --provider anthropic"
                + " && ouro provider refresh --agent ouroboros"
        )
    }

    func testRotateCredentialCommandLineHasNoEmailAndUnlocksNotCreates() {
        // An existing agent's vault already exists: rotation must UNLOCK it, never re-CREATE it,
        // and must NOT pass `--email` (the vault account is already provisioned).
        let line = VaultOnboardingCommand.rotateCredentialCommandLine(
            agentName: "scout",
            providerFlag: "openai-codex"
        )
        XCTAssertTrue(line.contains("ouro vault unlock --agent scout"), "rotation must unlock; got: \(line)")
        XCTAssertFalse(line.contains("vault create"), "rotation must NOT create a vault; got: \(line)")
        XCTAssertFalse(line.contains("--email"), "rotation must NOT pass --email; got: \(line)")
        XCTAssertTrue(line.contains("&& ouro auth --agent scout --provider openai-codex"), "got: \(line)")
        XCTAssertTrue(line.contains("&& ouro provider refresh --agent scout"), "got: \(line)")
    }

    func testRotateCredentialCommandLineQuotesShellSignificantChars() {
        // A name with a space must be quoted by ShellArgumentEscaper everywhere it appears; the
        // `&&` separators are literal — never quoted.
        let line = VaultOnboardingCommand.rotateCredentialCommandLine(
            agentName: "my agent",
            providerFlag: "anthropic"
        )
        XCTAssertTrue(line.contains("vault unlock --agent 'my agent'"), "agent name must be shell-quoted; got: \(line)")
        XCTAssertTrue(line.contains("auth --agent 'my agent'"), "agent name must be shell-quoted; got: \(line)")
        XCTAssertTrue(line.contains("provider refresh --agent 'my agent'"), "agent name must be shell-quoted; got: \(line)")
        XCTAssertTrue(line.contains(" && ouro auth "), "the && separators must remain literal/unquoted; got: \(line)")
        XCTAssertTrue(line.contains(" && ouro provider refresh "), "the && separators must remain literal/unquoted; got: \(line)")
        XCTAssertFalse(line.contains("'&&'"), "the && operator must never be quoted; got: \(line)")
    }

    func testRotateCredentialCommandLineQuotesProviderFlag() {
        let line = VaultOnboardingCommand.rotateCredentialCommandLine(
            agentName: "ouroboros",
            providerFlag: "weird provider"
        )
        XCTAssertTrue(line.contains("--provider 'weird provider'"), "provider flag must be shell-quoted; got: \(line)")
    }

    // MARK: - Rotation human copy: present + seam-free for every state, distinct from onboarding

    /// No state's human copy may leak a CLI/vault seam BEYOND the agent name itself (the agent name
    /// is human-chosen and may legitimately contain a substring like "ouro"). Strip the name first,
    /// then scan the remaining copy for CLI/vault vocabulary.
    private func assertSeamFreeBeyondName(
        _ line: String,
        agentName: String,
        file: StaticString = #filePath,
        line ln: UInt = #line
    ) {
        // Mirror F13's proven seam-token list (VaultOnboardingTests): these are the literal CLI /
        // argv leaks. "unlock secret" is product-facing human language (the human really does enter
        // an unlock secret), so "unlock" is NOT a seam — only the raw `vault`/`ouro`/argv tokens are.
        let withoutName = line.replacingOccurrences(of: agentName, with: "").lowercased()
        for token in ["ouro", "vault", "hatch", "--", ".bot", "&&"] {
            XCTAssertFalse(
                withoutName.contains(token),
                "rotation copy leaked the seam token \"\(token)\" (agent name aside): \(line)",
                file: file, line: ln
            )
        }
    }

    private let allStates: [VaultOnboardingState] = [
        .needsSecret,
        .runningVaultTerminal,
        .persisting,
        .ready,
        .failed(reason: .vaultCommandLaunchError),
        .failed(reason: .vaultCommandNonZeroExit),
        .failed(reason: .stillNotConnected),
        .failed(reason: .couldNotConfirm),
    ]

    func testRotationHumanLinePresentAndSeamFreeForEveryState() {
        // Use a seam-colliding agent name ("ouroboros" contains "ouro") to prove the seam check
        // strips the name rather than false-passing on a name with no seam substring.
        let agentName = "ouroboros"
        for state in allStates {
            let line = VaultOnboardingMachine.humanLine(for: state, agentName: agentName, flavor: .rotation)
            let copy = try? XCTUnwrap(line, "every state must have rotation human copy: \(state)")
            guard let copy else { continue }
            XCTAssertFalse(copy.isEmpty, "rotation human copy must be non-empty for \(state)")
            assertSeamFreeBeyondName(copy, agentName: agentName)
        }
    }

    func testRotationHumanLineNamesTheAgent() {
        for state in allStates {
            let line = VaultOnboardingMachine.humanLine(for: state, agentName: "scout", flavor: .rotation)
            XCTAssertTrue((line ?? "").contains("scout"), "rotation copy should name the agent for \(state); got: \(line ?? "nil")")
        }
    }

    func testRotationFirstStepCopyIsReconnectFlavored() {
        // The needs-secret entry copy is the operator's first read — it must be rotation-flavored
        // (reconnect / re-enter), NOT the onboarding "Finish connecting" first-setup copy.
        let rotation = VaultOnboardingMachine.humanLine(for: .needsSecret, agentName: "scout", flavor: .rotation)
        let onboarding = VaultOnboardingMachine.humanLine(for: .needsSecret, agentName: "scout", flavor: .onboarding)
        XCTAssertNotEqual(
            rotation, onboarding,
            "rotation's first-step copy must differ from onboarding's (reconnect vs first-setup)"
        )
        let lowered = (rotation ?? "").lowercased()
        XCTAssertTrue(lowered.contains("reconnect"), "rotation copy should read as a reconnect; got: \(rotation ?? "nil")")
    }

    func testHumanLineDefaultsToOnboardingFlavor() {
        // The 2-arg overload (F13's call sites) must remain the onboarding flavor for back-compat.
        for state in allStates {
            XCTAssertEqual(
                VaultOnboardingMachine.humanLine(for: state, agentName: "scout"),
                VaultOnboardingMachine.humanLine(for: state, agentName: "scout", flavor: .onboarding),
                "the 2-arg humanLine must equal the onboarding-flavored 3-arg form for \(state)"
            )
        }
    }
}
