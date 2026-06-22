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
}
