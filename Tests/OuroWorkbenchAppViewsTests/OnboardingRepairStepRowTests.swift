#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU-E1 — Surface E (onboarding) leaf `OnboardingRepairStepRow` actor/button variants.
///
/// `OnboardingRepairStepRow(step:model:)` is a leaf row whose `step` is a Core
/// `OnboardingRepairStep` — a legitimate `View` input seam (constructed directly, exactly
/// as U1 built `SidebarWorkspaceEmptyRow` and SU3r built `TerminalAgentRow`; P2 forbids
/// hand-assembling serializer OUTPUT / model STATE, NOT instantiating a `View` from its own
/// typed input). The row reads `model` ONLY for the `workbench-mcp` Register-button gate
/// (`model.bossWorkbenchMCPRegistration?.isActionable`); no E1 fixture exercises that id, so
/// a hermetic empty VM (AN-001 temp `agentBundlesURL` into BOTH the registrar AND the
/// inventory) suffices and renders deterministically.
///
/// The row tree (per `WorkbenchViewsAndModel.swift:7142-7255`):
///   - the actor `StatusPill` → `Text` of `actorLabel`:
///       `check-*` id → "Checking…" (FIRST, before the actor switch); else
///       `.agentRunnable` → "Workbench" (blue), `.humanRequired` → "Needs you" (orange),
///       `.humanChoice` → "Choose" (purple);
///   - `Text(step.title)` + `Text(step.detail)`;
///   - the trailing button, gated by `step.id`:
///       `isProviderSetup` (request-provider-config / outward-lane / inner-lane) → "Connect"/`link`;
///       `check-*` with a commandLine → "Run"/`play.fill`; `check-*` without → a spinner
///       (ProgressView — NO text/image, so the row is pill+title+detail only);
///       else a commandLine step → `commandButtonTitle` ("Try again" for `repair-*-provider`,
///       "Choose" for `.humanChoice`, else "Fix") + `wand.and.stars`;
///       else (no commandLine, not a check/provider step) → no trailing control.
///
/// Determinism (P3): pure Core copy + fixed `step` fields; no clock/path/UUID/agent-name.
@MainActor
final class OnboardingRepairStepRowTests: XCTestCase {

    // MARK: - Hermetic VM (AN-001-safe) — the row reads model only for the workbench-mcp gate

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suE1-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func row(_ step: OnboardingRepairStep, _ model: WorkbenchViewModel) -> OnboardingRepairStepRow {
        OnboardingRepairStepRow(step: step, model: model)
    }

    // MARK: - Fixed step fixtures (distinct titles/details → distinct, non-redundant trees)

    /// `.agentRunnable` with a commandLine, NOT a check/provider id → "Workbench" pill +
    /// the `commandButtonTitle` "Fix" + `wand.and.stars`.
    private func agentRunnableStep() -> OnboardingRepairStep {
        OnboardingRepairStep(
            id: "ensure-daemon", actor: .agentRunnable,
            title: "Wake your agent",
            detail: "Workbench brings the local runtime back online so your agent can respond.",
            command: ["ouro", "up"]
        )
    }

    /// `request-provider-config` (`isProviderSetup`) — `.humanRequired` → "Needs you" pill +
    /// the "Connect"/`link` button (the one human gate).
    private func humanRequiredProviderStep() -> OnboardingRepairStep {
        OnboardingRepairStep(
            id: "request-provider-config", actor: .humanRequired,
            title: "Connect a provider",
            detail: "Workbench opens a setup form so you can connect a provider. This is the only step that needs you."
        )
    }

    /// `.humanChoice` with a commandLine, not a check/provider id → "Choose" pill + the
    /// `commandButtonTitle` "Choose" + `wand.and.stars`.
    private func humanChoiceStep() -> OnboardingRepairStep {
        OnboardingRepairStep(
            id: "hatch", actor: .humanChoice,
            title: "Create a new agent",
            detail: "Set up a brand-new agent — Workbench walks you through it.",
            command: ["ouro", "hatch"]
        )
    }

    /// `check-outward` WITHOUT a command → "Checking…" pill + a spinner (no Run button).
    private func checkInProgressStep() -> OnboardingRepairStep {
        OnboardingRepairStep(
            id: "check-outward", actor: .agentRunnable,
            title: "Checking the model it talks with",
            detail: "Making sure your connection is live."
        )
    }

    /// `check-outward` WITH a command → "Checking…" pill + the "Run"/`play.fill` button.
    private func checkPendingStep() -> OnboardingRepairStep {
        OnboardingRepairStep(
            id: "check-outward", actor: .agentRunnable,
            title: "Check the model it talks with",
            detail: "Workbench will make sure your connection works.",
            command: ["ouro", "check", "--agent", "boss", "--lane", "outward"]
        )
    }

    // MARK: - SU-E1.a — actor/button-variant state-set (each a non-redundant reference)

    func testE1_agentRunnable() throws {
        let model = try makeVM()
        let tree = try ViewSnapshotHost.snapshotText(of: row(agentRunnableStep(), model))
        // Provenance at the call site: the pure-Core actor mapping renders "Workbench" + the Fix verb.
        XCTAssertTrue(tree.contains(#"text="Workbench""#), "agentRunnable → Workbench pill:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Fix""#), "commandLine step → Fix button:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="wand.and.stars""#), "Fix icon:\n\(tree)")
        try assertViewSnapshot(of: row(agentRunnableStep(), model), named: "E1.agentRunnable")
    }

    func testE1_humanRequiredProviderSetup() throws {
        let model = try makeVM()
        let tree = try ViewSnapshotHost.snapshotText(of: row(humanRequiredProviderStep(), model))
        XCTAssertTrue(tree.contains(#"text="Needs you""#), "humanRequired → Needs you pill:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Connect""#), "isProviderSetup → Connect button:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="link""#), "Connect icon:\n\(tree)")
        try assertViewSnapshot(of: row(humanRequiredProviderStep(), model), named: "E1.humanRequiredProviderSetup")
    }

    func testE1_humanChoice() throws {
        let model = try makeVM()
        let tree = try ViewSnapshotHost.snapshotText(of: row(humanChoiceStep(), model))
        XCTAssertTrue(tree.contains(#"text="Choose""#), "humanChoice → Choose pill + Choose button:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="wand.and.stars""#), "commandLine humanChoice → Choose/wand button:\n\(tree)")
        try assertViewSnapshot(of: row(humanChoiceStep(), model), named: "E1.humanChoice")
    }

    func testE1_checkInProgress() throws {
        let model = try makeVM()
        let tree = try ViewSnapshotHost.snapshotText(of: row(checkInProgressStep(), model))
        XCTAssertTrue(tree.contains(#"text="Checking…""#), "check-* → Checking… pill:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="Run""#), "no command → spinner, NO Run button:\n\(tree)")
        XCTAssertFalse(tree.contains(#"image="play.fill""#), "no Run icon when spinning:\n\(tree)")
        try assertViewSnapshot(of: row(checkInProgressStep(), model), named: "E1.checkInProgress")
    }

    func testE1_checkPending() throws {
        let model = try makeVM()
        let tree = try ViewSnapshotHost.snapshotText(of: row(checkPendingStep(), model))
        XCTAssertTrue(tree.contains(#"text="Checking…""#), "check-* → Checking… pill:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Run""#), "check-* with command → Run button:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="play.fill""#), "Run icon:\n\(tree)")
        try assertViewSnapshot(of: row(checkPendingStep(), model), named: "E1.checkPending")
    }

    // MARK: - SU-E1.b — MUTATION-verified negative controls (P2)

    /// NEGATIVE CONTROL — flipping `step.actor` `.agentRunnable`↔`.humanRequired` flips the
    /// StatusPill label/color ("Workbench"→"Needs you"). The pure-Core `actorLabel`/`color`
    /// switch is the load-bearing guard; this proves the rendered pill is driven by it.
    func testE1_negativeControl_actorFlipsPill() throws {
        let model = try makeVM()
        let agentRunnable = OnboardingRepairStep(
            id: "ensure-daemon", actor: .agentRunnable, title: "T", detail: "D", command: ["ouro", "up"])
        let humanRequired = OnboardingRepairStep(
            id: "ensure-daemon", actor: .humanRequired, title: "T", detail: "D", command: ["ouro", "up"])
        let agentTree = try ViewSnapshotHost.snapshotText(of: row(agentRunnable, model))
        let humanTree = try ViewSnapshotHost.snapshotText(of: row(humanRequired, model))
        XCTAssertNotEqual(agentTree, humanTree, "flipping the actor flips the pill text")
        XCTAssertTrue(agentTree.contains(#"text="Workbench""#), "agentRunnable → Workbench:\n\(agentTree)")
        XCTAssertTrue(humanTree.contains(#"text="Needs you""#), "humanRequired → Needs you:\n\(humanTree)")
        XCTAssertFalse(humanTree.contains(#"text="Workbench""#), "humanRequired is NOT Workbench:\n\(humanTree)")
    }

    /// NEGATIVE CONTROL — flipping `step.id` across the check-* button boundary flips the
    /// trailing control: a `check-*` id with a command renders "Run"/`play.fill`; the SAME
    /// command under a non-check id renders the "Fix"/`wand.and.stars` command button. The
    /// `step.id.hasPrefix("check-")` guard is load-bearing.
    func testE1_negativeControl_checkIdFlipsButton() throws {
        let model = try makeVM()
        let command = ["ouro", "check", "--agent", "boss", "--lane", "outward"]
        let checkStep = OnboardingRepairStep(id: "check-outward", actor: .agentRunnable, title: "T", detail: "D", command: command)
        let fixStep = OnboardingRepairStep(id: "ensure-daemon", actor: .agentRunnable, title: "T", detail: "D", command: command)
        let checkTree = try ViewSnapshotHost.snapshotText(of: row(checkStep, model))
        let fixTree = try ViewSnapshotHost.snapshotText(of: row(fixStep, model))
        XCTAssertNotEqual(checkTree, fixTree, "the check-* id flips both the pill AND the button")
        XCTAssertTrue(checkTree.contains(#"text="Run""#) && checkTree.contains(#"text="Checking…""#),
                      "check-* → Checking… pill + Run button:\n\(checkTree)")
        XCTAssertTrue(fixTree.contains(#"text="Fix""#) && fixTree.contains(#"text="Workbench""#),
                      "non-check → Workbench pill + Fix button:\n\(fixTree)")
    }

    // MARK: - U5 B3 — DRIVE the trailing-button action closures + the un-hit render arms

    /// A `workbench-mcp` step (`isActionable == true` snapshot) renders the Register button
    /// (`:7297`) — the un-hit `if step.id == "workbench-mcp", isActionable` gate (`:7289`) + the
    /// button label (`:7301`). The Register action runs `installWorkbenchMCPForBoss()` +
    /// `refreshOnboardingReadiness()` + `runOnboardingProviderChecksIfNeeded()`; DRIVEN by `.tap()`
    /// → the model-observable effect is `onboardingReadiness` becoming non-nil (the refresh ran).
    private func workbenchMCPStep() -> OnboardingRepairStep {
        OnboardingRepairStep(
            id: "workbench-mcp", actor: .agentRunnable,
            title: "Connect your agent to Workbench",
            detail: "Register the Workbench tools so your agent can act here.")
    }

    private func actionableRegistration(_ boss: String) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: boss, serverName: "ouro_workbench",
            commandPath: "/tmp/u5/ouro-workbench-mcp", agentConfigPath: "/tmp/u5/\(boss).ouro/agent.json",
            status: .notRegistered, detail: "not registered")
    }

    func testE1_drive_registerButton_workbenchMCP() throws {
        let model = try makeVM()
        model.state.boss.agentName = "boss"
        model.bossWorkbenchMCPRegistration = actionableRegistration("boss")
        XCTAssertTrue(model.bossWorkbenchMCPRegistration?.isActionable == true, "precondition: actionable")
        model.onboardingReadiness = nil
        let row = OnboardingRepairStepRow(step: workbenchMCPStep(), model: model)
        // The actionable gate renders the Register button (the un-hit gate + label arms).
        let tree = try ViewSnapshotHost.snapshotText(of: row)
        XCTAssertTrue(tree.contains(#"text="Register""#), "workbench-mcp actionable → Register button:\n\(tree)")
        // DRIVE the action closure.
        try row.inspect().find(button: "Register").tap()
        XCTAssertNotNil(model.onboardingReadiness, "tapping Register runs refreshOnboardingReadiness()")
    }

    /// The Connect button (`:7310`, `isProviderSetup`) action runs `openOnboardingRepair(step)` →
    /// `presentProviderConfigForm` → `isProviderConfigPresented = true`. DRIVEN by `.tap()`.
    func testE1_drive_connectButton_providerSetup() throws {
        let model = try makeVM()
        model.state.boss.agentName = "boss"
        XCTAssertFalse(model.isProviderConfigPresented, "precondition")
        let row = OnboardingRepairStepRow(step: humanRequiredProviderStep(), model: model)
        try row.inspect().find(button: "Connect").tap()
        XCTAssertTrue(model.isProviderConfigPresented, "tapping Connect presents the provider-config form")
    }

    /// The Run button (`:7323`, a `check-*` step WITH a commandLine) action runs
    /// `runOnboardingProviderChecksIfNeeded()`. With no ready selected agent it early-returns —
    /// the closure still executes the region; the assertion is that the responsive button's
    /// action runs without throwing (no model-observable mutation on the early-return path).
    func testE1_drive_runButton_checkPending() throws {
        let model = try makeVM()
        let row = OnboardingRepairStepRow(step: checkPendingStep(), model: model)
        let button = try row.inspect().find(button: "Run")
        XCTAssertNoThrow(try button.tap(), "tapping Run executes runOnboardingProviderChecksIfNeeded()")
    }

    /// The Fix button (`:7337`, a commandLine non-check non-provider step) action runs
    /// `openOnboardingRepair(step)` → `runOnboardingRepairStepNatively` → (default case)
    /// `refreshOnboardingReadiness()`. DRIVEN by `.tap()` → `onboardingReadiness` becomes non-nil.
    func testE1_drive_fixButton_commandStep() throws {
        let model = try makeVM()
        model.state.boss.agentName = "boss"
        model.onboardingReadiness = nil
        let row = OnboardingRepairStepRow(step: agentRunnableStep(), model: model)
        try row.inspect().find(button: "Fix").tap()
        XCTAssertNotNil(model.onboardingReadiness,
                        "tapping Fix routes to runOnboardingRepairStepNatively → refreshOnboardingReadiness()")
    }

    /// RENDER the `commandButtonTitle` `repair-*-provider` ternary (`:7369`) → the "Try again"
    /// label (vs the "Fix" default). A `repair-outward-provider` step carries a command but is
    /// NOT a provider-setup / check-* / workbench-mcp step, so it renders the command "Try again"
    /// button. This drives the un-hit ternary arm.
    func testE1_render_tryAgainButton_repairProvider() throws {
        let model = try makeVM()
        let step = OnboardingRepairStep(
            id: "repair-outward-provider", actor: .agentRunnable,
            title: "Recheck the outward lane", detail: "Run the connection check again.",
            command: ["ouro", "check", "--lane", "outward"])
        let tree = try ViewSnapshotHost.snapshotText(of: OnboardingRepairStepRow(step: step, model: model))
        XCTAssertTrue(tree.contains(#"text="Try again""#),
                      "repair-*-provider → the 'Try again' command button (not 'Fix'):\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="Fix""#), "repair-*-provider is NOT the 'Fix' default:\n\(tree)")
        try assertViewSnapshot(of: OnboardingRepairStepRow(step: step, model: model), named: "E1.tryAgainRepairProvider")
    }

    /// NEGATIVE CONTROL — the `repair-*-provider` ternary is load-bearing: the SAME command under a
    /// non-`repair-*-provider` id renders "Fix", not "Try again". Flipping the id flips the label.
    func testE1_negativeControl_repairProviderTernaryFlipsLabel() throws {
        let model = try makeVM()
        let command = ["ouro", "check", "--lane", "outward"]
        let tryAgain = OnboardingRepairStep(id: "repair-outward-provider", actor: .agentRunnable, title: "T", detail: "D", command: command)
        let fix = OnboardingRepairStep(id: "ensure-daemon", actor: .agentRunnable, title: "T", detail: "D", command: command)
        let tryAgainTree = try ViewSnapshotHost.snapshotText(of: OnboardingRepairStepRow(step: tryAgain, model: model))
        let fixTree = try ViewSnapshotHost.snapshotText(of: OnboardingRepairStepRow(step: fix, model: model))
        XCTAssertNotEqual(tryAgainTree, fixTree, "the repair-*-provider id flips the command-button label")
        XCTAssertTrue(tryAgainTree.contains(#"text="Try again""#), "repair-*-provider → Try again:\n\(tryAgainTree)")
        XCTAssertTrue(fixTree.contains(#"text="Fix""#), "non-repair → Fix:\n\(fixTree)")
    }

    // MARK: - Determinism (P3)

    func testE1_determinism_eachVariantByteIdenticalTwiceAndNoLeak() throws {
        let model = try makeVM()
        let cases: [(String, OnboardingRepairStep)] = [
            ("agentRunnable", agentRunnableStep()),
            ("humanRequiredProviderSetup", humanRequiredProviderStep()),
            ("humanChoice", humanChoiceStep()),
            ("checkInProgress", checkInProgressStep()),
            ("checkPending", checkPendingStep())
        ]
        for (name, step) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: row(step, model))
            let b = try ViewSnapshotHost.snapshotText(of: row(step, model))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
