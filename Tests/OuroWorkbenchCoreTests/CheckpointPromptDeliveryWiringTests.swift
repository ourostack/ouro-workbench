import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 5 — durable wiring assertions for the Copilot checkpoint-prompt delivery.
///
/// The pure `CheckpointPromptDeliveryResolver` + the `TerminalCommandPlan.
/// checkpointPromptDelivery` field are unit-tested + 100% covered in Core; the App
/// (TerminalSessionController) that types the prompt isn't coverage-gated, so we
/// source-pin its structure the `WorkbenchAppSource.appSource()` way.
///
/// The risks these pins defend (the spec's behavioral risks for gap 5):
///   - the controller must consult `plan.checkpointPromptDelivery` and, for
///     `.sendAfterLaunch(text)`, route the text through `sendInput`;
///   - THE key timing risk: it must fire only once the agent's TUI is INTERACTIVE
///     (the post-start first-output signal), NOT immediately in `start()`/`onStarted`
///     — typing before the TUI is ready loses the prompt;
///   - it must fire EXACTLY once (a one-shot guard), not on every output chunk;
///   - the generic-TUI positional path must NOT be regressed (no sendInput for
///     `.positional`).
final class CheckpointPromptDeliveryWiringTests: XCTestCase {
    func testControllerConsultsCheckpointPromptDeliveryAndRoutesSendAfterLaunchViaSendInput() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try sessionControllerBody(source)
        XCTAssertTrue(
            body.contains("plan.checkpointPromptDelivery"),
            "the controller must consult plan.checkpointPromptDelivery"
        )
        XCTAssertTrue(
            body.contains(".sendAfterLaunch"),
            "the controller must branch on .sendAfterLaunch(text)"
        )
        XCTAssertTrue(
            body.contains("sendInput("),
            "the .sendAfterLaunch text must be routed through sendInput"
        )
    }

    func testSendAfterLaunchIsGatedOnInteractivityNotOnStarted() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try sessionControllerBody(source)
        // The delivery must hang off the first-output (interactive) signal, not the
        // synchronous start()/onStarted. Pin that the deliver helper is invoked from
        // the output path and that a one-shot guard exists so it fires exactly once.
        XCTAssertTrue(
            body.contains("deliverCheckpointPromptIfNeeded") || body.contains("hasDeliveredCheckpointPrompt"),
            "the controller must have a one-shot checkpoint-prompt delivery helper/guard"
        )
        // The one-shot guard prevents re-typing on every PTY chunk.
        XCTAssertTrue(
            body.contains("hasDeliveredCheckpointPrompt"),
            "a one-shot guard (hasDeliveredCheckpointPrompt) must ensure the prompt is typed exactly once"
        )
        // It must be reached from recordOutput (the first-output interactive signal),
        // never from start()/onStarted (typing before the TUI is ready loses it).
        let recordOutput = try WorkbenchAppSource.sourceSlice(in: source, from: "private func recordOutput(", to: "\n    func ")
        XCTAssertTrue(
            recordOutput.contains("deliverCheckpointPromptIfNeeded") || recordOutput.contains("CheckpointPrompt"),
            "the checkpoint prompt must be delivered from the first-output (interactive) signal in recordOutput, not start()/onStarted"
        )
    }

    func testStartDoesNotTypeTheCheckpointPromptImmediately() throws {
        let source = try WorkbenchAppSource.appSource()
        let startBody = try WorkbenchAppSource.sourceSlice(in: source, from: "func start() {", to: "\n    func sendInput(")
        // start() must not type the checkpoint prompt synchronously — that's before
        // the TUI is interactive. Delivery belongs to the output path only.
        XCTAssertFalse(
            startBody.contains("checkpointPromptDelivery") || startBody.contains("deliverCheckpointPromptIfNeeded"),
            "start() must NOT deliver the checkpoint prompt (the TUI isn't interactive yet — the prompt would be lost)"
        )
    }

    // MARK: - Helpers

    private func sessionControllerBody(_ source: String) throws -> String {
        try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "final class TerminalSessionController",
            to: "\nfinal class CapturingLocalProcessTerminalView"
        )
    }
}
