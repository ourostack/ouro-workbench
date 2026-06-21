import XCTest
@testable import OuroWorkbenchCore

/// F13 — in-app vault onboarding (the `.needsVaultSetup` cold-start recovery path).
///
/// These tests pin the PURE seams in `VaultOnboarding.swift`: when to offer "Finish setup",
/// how the native-terminal exit + the re-probe verdict fold into the next state (the F1 safety
/// invariant — never `.ready` without a positive `.working` re-probe), the exact recovery
/// command chain, and the seam-free human copy.
final class VaultOnboardingTests: XCTestCase {

    // MARK: - Public surface

    func testMachineIsConstructible() {
        // The documented public initializer is part of the seam's API surface.
        _ = VaultOnboardingMachine()
    }

    // MARK: - shouldOffer: only the honest needs-vault case

    func testShouldOfferOnlyForNeedsVaultSetup() {
        XCTAssertTrue(VaultOnboardingMachine.shouldOffer(coldStart: .needsVaultSetup))
        XCTAssertFalse(VaultOnboardingMachine.shouldOffer(coldStart: .ready))
        XCTAssertFalse(VaultOnboardingMachine.shouldOffer(coldStart: .failed(reason: .hatchNonZeroExit)))
        XCTAssertFalse(VaultOnboardingMachine.shouldOffer(coldStart: .failed(reason: .couldNotConfirm)))
        XCTAssertFalse(VaultOnboardingMachine.shouldOffer(coldStart: .failed(reason: .hatchLaunchError)))
    }

    // MARK: - afterVaultTerminal: exit + re-probe → next state

    func testAfterVaultTerminalNeverLaunched() {
        // nil exit = the terminal never launched.
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: nil, reprobeVerdict: .working),
            .failed(reason: .vaultCommandLaunchError)
        )
        // Even a positive verdict can't rescue a never-launched terminal.
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: nil, reprobeVerdict: nil),
            .failed(reason: .vaultCommandLaunchError)
        )
    }

    func testAfterVaultTerminalNonZeroExit() {
        // Any non-zero exit is a command failure, regardless of the verdict.
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 1, reprobeVerdict: .working),
            .failed(reason: .vaultCommandNonZeroExit)
        )
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 130, reprobeVerdict: .working),
            .failed(reason: .vaultCommandNonZeroExit)
        )
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 1, reprobeVerdict: nil),
            .failed(reason: .vaultCommandNonZeroExit)
        )
    }

    func testAfterVaultTerminalReadyOnlyOnWorking() {
        // The ONLY path to .ready: clean exit AND a positive .working re-probe (F1 invariant).
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 0, reprobeVerdict: .working),
            .ready
        )
    }

    func testAfterVaultTerminalCleanExitStillNotConnected() {
        // Clean exit but the credential still isn't usable → still-not-connected (retryable).
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 0, reprobeVerdict: .vaultLocked),
            .failed(reason: .stillNotConnected)
        )
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 0, reprobeVerdict: .unauthorized),
            .failed(reason: .stillNotConnected)
        )
    }

    func testAfterVaultTerminalCleanExitCouldNotConfirm() {
        // Clean exit but we can't positively confirm (network/ambiguous/probe-timeout).
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 0, reprobeVerdict: .unreachable),
            .failed(reason: .couldNotConfirm)
        )
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 0, reprobeVerdict: .indeterminate),
            .failed(reason: .couldNotConfirm)
        )
        XCTAssertEqual(
            VaultOnboardingMachine.afterVaultTerminal(vaultExitCode: 0, reprobeVerdict: nil),
            .failed(reason: .couldNotConfirm)
        )
    }

    // MARK: - finishSetupCommandLine: the exact recovery chain

    func testFinishSetupCommandLineDefaultEmail() {
        let line = VaultOnboardingCommand.finishSetupCommandLine(
            agentName: "ouroboros",
            providerFlag: "anthropic",
            email: nil
        )
        XCTAssertEqual(
            line,
            "ouro vault create --agent ouroboros --email ouroboros@ouro.bot"
                + " && ouro auth --agent ouroboros --provider anthropic"
                + " && ouro provider refresh --agent ouroboros"
        )
    }

    func testFinishSetupCommandLineExplicitEmailUsedVerbatim() {
        let line = VaultOnboardingCommand.finishSetupCommandLine(
            agentName: "scout",
            providerFlag: "openai-codex",
            email: "scout@example.com"
        )
        XCTAssertEqual(
            line,
            "ouro vault create --agent scout --email scout@example.com"
                + " && ouro auth --agent scout --provider openai-codex"
                + " && ouro provider refresh --agent scout"
        )
    }

    func testFinishSetupCommandLineQuotesShellSignificantChars() {
        // A name with a space must be quoted by ShellArgumentEscaper everywhere it appears,
        // and the default email's local part uses the same (quoted) name. The `&&` separators
        // are literal — never quoted.
        let line = VaultOnboardingCommand.finishSetupCommandLine(
            agentName: "my agent",
            providerFlag: "anthropic",
            email: nil
        )
        XCTAssertTrue(line.contains("--agent 'my agent'"), "agent name must be shell-quoted; got: \(line)")
        XCTAssertTrue(line.contains("--email 'my agent@ouro.bot'"), "default email local part must be the (quoted) name; got: \(line)")
        XCTAssertTrue(line.contains(" && ouro auth "), "the && separators must remain literal/unquoted; got: \(line)")
        XCTAssertTrue(line.contains(" && ouro provider refresh "), "the && separators must remain literal/unquoted; got: \(line)")
        // The literal operator must never be wrapped in quotes.
        XCTAssertFalse(line.contains("'&&'"), "the && operator must never be quoted; got: \(line)")
    }

    func testFinishSetupCommandLineQuotesProviderFlag() {
        // A provider flag carrying a shell-significant char must be quoted in the auth segment.
        let line = VaultOnboardingCommand.finishSetupCommandLine(
            agentName: "ouroboros",
            providerFlag: "weird provider",
            email: nil
        )
        XCTAssertTrue(line.contains("--provider 'weird provider'"), "provider flag must be shell-quoted; got: \(line)")
    }

    // MARK: - humanLine: present + seam-free for every state

    /// No state's human copy may leak a CLI/vault seam BEYOND the agent name itself. The agent
    /// name is human-chosen and may legitimately contain a substring like "ouro" (e.g. the
    /// canonical agent "ouroboros"); seam-leak detection therefore strips the agent name first,
    /// then scans the remaining copy for CLI/vault vocabulary.
    private func assertSeamFreeBeyondName(
        _ line: String,
        agentName: String,
        file: StaticString = #filePath,
        line ln: UInt = #line
    ) {
        let withoutName = line.replacingOccurrences(of: agentName, with: "").lowercased()
        for token in ["ouro", "vault", "hatch", "--", ".bot"] {
            XCTAssertFalse(
                withoutName.contains(token),
                "human copy leaked the seam token \"\(token)\" (agent name aside): \(line)",
                file: file, line: ln
            )
        }
    }

    func testHumanLinePresentAndSeamFreeForEveryState() {
        let states: [VaultOnboardingState] = [
            .needsSecret,
            .runningVaultTerminal,
            .persisting,
            .ready,
            .failed(reason: .vaultCommandLaunchError),
            .failed(reason: .vaultCommandNonZeroExit),
            .failed(reason: .stillNotConnected),
            .failed(reason: .couldNotConfirm),
        ]
        // Use a seam-COLLIDING agent name ("ouroboros" contains "ouro") to prove the check
        // strips the name correctly rather than false-passing on a name with no seam substring.
        let agentName = "ouroboros"
        for state in states {
            let line = VaultOnboardingMachine.humanLine(for: state, agentName: agentName)
            let copy = try? XCTUnwrap(line, "every state must have human copy: \(state)")
            guard let copy else { continue }
            XCTAssertFalse(copy.isEmpty, "human copy must be non-empty for \(state)")
            assertSeamFreeBeyondName(copy, agentName: agentName)
        }
    }

    func testHumanLineNamesTheAgent() {
        // At least the terminal/ready/failure surfaces name the agent so the human knows which.
        let ready = VaultOnboardingMachine.humanLine(for: .ready, agentName: "ouroboros")
        XCTAssertTrue((ready ?? "").contains("ouroboros"), "ready copy should name the agent; got: \(ready ?? "nil")")
        let failed = VaultOnboardingMachine.humanLine(for: .failed(reason: .stillNotConnected), agentName: "ouroboros")
        XCTAssertTrue((failed ?? "").contains("ouroboros"), "failure copy should name the agent; got: \(failed ?? "nil")")
    }
}
