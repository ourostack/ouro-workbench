#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU-E2 — Surface E (onboarding) `FirstRunBootstrapView` + `FirstRunMode` mode variants.
///
/// Provenance (Q4 default): each fixture is built through the PURE Core producer
/// (`FirstRunBootstrapDrive.presentIdle()` / `.present(result: BootstrapResult(phase:…,
/// stepOutcomes:…), activeStep:)`), then assigned to the `@Published model.firstRunPresentation`
/// — the genuine VM seam the live `runFirstRunBootstrap()` writes — so the test NEVER
/// hand-assembles the `FirstRunBootstrapPresentation` struct and NEVER invokes the live async
/// bootstrap (which spawns real effects). The agent-driven narration is the static Core copy
/// (`FirstRunBootstrapDrive.agentDrivenHandoffNarration`) assigned to `model.firstRunAgentDrivenNarration`.
///
/// `FirstRunBootstrapView` has NO `.onAppear`/`.task` of its own (only `OnboardingReadinessView`
/// does), so the Q2 no-fire concern does not arise here. The VM is hermetic (AN-001 temp
/// `agentBundlesURL` into BOTH the registrar AND the inventory).
///
/// The view tree (per `WorkbenchViewsAndModel.swift:6825-6931`):
///   - `nil` presentation → the whole body is `if let presentation` → EMPTY tree;
///   - else a `Label(headline, systemImage: headerIcon)` + a `StatusPill(modeLabel, modeColor)`:
///       `.bootstrapping` → "starting"/blue/`gauge.with.dots.needle.bottom.50percent`;
///       `.parkedAwaitingProvider` → "needs you"/orange/`link.badge.plus`;
///       `.needsAttention` → "needs attention"/red/`exclamationmark.triangle.fill`;
///       `.agentDriven` → "agent driving"/green/`sparkles`;
///   - `.agentDriven` → a `FirstRunNarrationRow` (sparkles + the narration); else the
///     per-step `FirstRunStepRow`s + (if `opensProviderGate`) "Connect a provider"/`link`
///     + (if `showsRetryButton`) the reason line + the retry/choose-boss button
///     ("Try again"/`arrow.clockwise` for a failed step, "Choose a boss"/
///     `person.crop.circle.badge.questionmark` for an invalid boss).
///
/// Determinism (P3): every string is pure Core copy (mode/step/reason); the only conceivable
/// variable is a fixture-controlled narration string. No clock/path/UUID/agent-name.
@MainActor
final class FirstRunBootstrapViewTests: XCTestCase {

    // MARK: - Hermetic VM (AN-001-safe)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suE2-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func view(_ model: WorkbenchViewModel) -> FirstRunBootstrapView { FirstRunBootstrapView(model: model) }

    private let drive = FirstRunBootstrapDrive()

    /// Build a VM whose `firstRunPresentation` is the pure-producer presentation for `phase`.
    private func vm(phase: BootstrapPhase, stepOutcomes: [BootstrapStepOutcome] = [], activeStep: BootstrapStep? = nil) throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.firstRunPresentation = drive.present(
            result: BootstrapResult(phase: phase, stepOutcomes: stepOutcomes),
            activeStep: activeStep
        )
        return model
    }

    // MARK: - SU-E2.a — mode-variant state-set

    func testE2_bootstrapping() throws {
        // The all-pending idle presentation = .bootstrapping mode ("starting"/blue).
        let model = try makeVM()
        model.firstRunPresentation = drive.presentIdle()
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertEqual(model.firstRunPresentation?.mode, .bootstrapping, "provenance: idle → bootstrapping")
        XCTAssertTrue(tree.contains(#"text="starting""#), "bootstrapping → starting pill:\n\(tree)")
        XCTAssertTrue(tree.contains("Workbench is getting your agent ready"), "bootstrapping headline:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E2.bootstrapping")
    }

    func testE2_parked() throws {
        // .parkedAwaitingProviderConfig → parkedAwaitingProvider mode ("needs you"/orange) +
        // the "Connect a provider" gate button (opensProviderGate).
        let model = try vm(phase: .parkedAwaitingProviderConfig)
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertEqual(model.firstRunPresentation?.mode, .parkedAwaitingProvider, "provenance: parked")
        XCTAssertTrue(model.firstRunPresentation?.opensProviderGate == true, "provenance: opens the provider gate")
        XCTAssertTrue(tree.contains(#"text="needs you""#), "parked → needs you pill:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Connect a provider""#), "parked → Connect a provider button:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E2.parked")
    }

    func testE2_needsAttention_failedStep() throws {
        // .failedStep(_) → needsAttention mode ("needs attention"/red); the DERIVED attentionReason
        // is .failedStep → "Try again"/arrow.clockwise + the failed-step reason line.
        let model = try vm(phase: .failedStep(.verifyCredentials),
                           stepOutcomes: [BootstrapStepOutcome(step: .verifyCredentials, recovery: .needsManual)])
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertEqual(model.firstRunPresentation?.mode, .needsAttention, "provenance: needsAttention")
        XCTAssertEqual(model.firstRunPresentation?.attentionReason, .failedStep, "provenance: failed-step reason")
        XCTAssertTrue(tree.contains(#"text="needs attention""#), "needsAttention → needs attention pill:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Try again""#), "failedStep → Try again button:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="arrow.clockwise""#), "Try again icon:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E2.needsAttention")
    }

    func testE2_needsAttention_invalidBoss() throws {
        // .failedInvalidAgent → needsAttention mode, but the attentionReason is .invalidBoss →
        // "Choose a boss"/person.crop.circle.badge.questionmark + the invalid-boss reason line.
        // A SEPARATE reference: the reason copy + button + icon differ from the failed-step tree.
        let model = try vm(phase: .failedInvalidAgent)
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertEqual(model.firstRunPresentation?.mode, .needsAttention, "provenance: needsAttention")
        XCTAssertEqual(model.firstRunPresentation?.attentionReason, .invalidBoss, "provenance: invalid-boss reason")
        XCTAssertTrue(tree.contains(#"text="Choose a boss""#), "invalidBoss → Choose a boss button:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="person.crop.circle.badge.questionmark""#), "Choose a boss icon:\n\(tree)")
        // The two needs-attention reasons render DIFFERENT trees (the reason line + button differ).
        let failedStepTree = try ViewSnapshotHost.snapshotText(of: view(try vm(phase: .failedStep(.verifyCredentials))))
        XCTAssertNotEqual(tree, failedStepTree, "invalid-boss vs failed-step render distinct reason/button trees")
        try assertViewSnapshot(of: view(model), named: "E2.needsAttentionInvalidBoss")
    }

    func testE2_agentDriven() throws {
        // .handedOff → agentDriven mode ("agent driving"/green) + the FirstRunNarrationRow.
        let model = try vm(phase: .handedOff)
        model.firstRunAgentDrivenNarration = FirstRunBootstrapDrive.agentDrivenHandoffNarration
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertEqual(model.firstRunPresentation?.mode, .agentDriven, "provenance: agentDriven")
        XCTAssertTrue(tree.contains(#"text="agent driving""#), "agentDriven → agent driving pill:\n\(tree)")
        XCTAssertTrue(tree.contains("taking over from here"), "agentDriven narration row:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E2.agentDriven")
    }

    func testE2_nil() throws {
        // firstRunPresentation == nil → the whole body is `if let presentation` → EMPTY tree.
        let model = try makeVM()
        XCTAssertNil(model.firstRunPresentation, "provenance: nil presentation")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.isEmpty, "nil presentation → empty tree, got:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E2.nil")
    }

    // MARK: - SU-E2.b — MUTATION-verified negative control (P2)

    /// NEGATIVE CONTROL — changing the input `BootstrapPhase`
    /// (`.parkedAwaitingProviderConfig` → `.failedStep`) flips the mode pill/icon AND the
    /// gate button: the `FirstRunMode(phase:)` mapping is the load-bearing guard. (The exact
    /// `FirstRunMode(phase:)` switch mutation — parked→needsAttention — is re-applied in the
    /// dedicated mutation cycle run from the orchestrator; this test proves the rendered surface
    /// is driven by the phase→mode mapping.)
    func testE2_negativeControl_phaseFlipsMode() throws {
        let parked = try vm(phase: .parkedAwaitingProviderConfig)
        let failed = try vm(phase: .failedStep(.verifyCredentials))
        let parkedTree = try ViewSnapshotHost.snapshotText(of: view(parked))
        let failedTree = try ViewSnapshotHost.snapshotText(of: view(failed))
        XCTAssertNotEqual(parkedTree, failedTree, "a different phase flips the mode pill + button")
        XCTAssertTrue(parkedTree.contains(#"text="needs you""#) && parkedTree.contains(#"text="Connect a provider""#),
                      "parked → needs you + Connect a provider:\n\(parkedTree)")
        XCTAssertTrue(failedTree.contains(#"text="needs attention""#) && failedTree.contains(#"text="Try again""#),
                      "failedStep → needs attention + Try again:\n\(failedTree)")
        XCTAssertFalse(failedTree.contains(#"text="needs you""#), "failedStep is NOT needs you:\n\(failedTree)")
    }

    // MARK: - Determinism (P3)

    func testE2_determinism_eachModeByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> WorkbenchViewModel)] = [
            ("bootstrapping", { let m = try self.makeVM(); m.firstRunPresentation = self.drive.presentIdle(); return m }),
            ("parked", { try self.vm(phase: .parkedAwaitingProviderConfig) }),
            ("needsAttention", { try self.vm(phase: .failedStep(.verifyCredentials)) }),
            ("invalidBoss", { try self.vm(phase: .failedInvalidAgent) }),
            ("agentDriven", {
                let m = try self.vm(phase: .handedOff)
                m.firstRunAgentDrivenNarration = FirstRunBootstrapDrive.agentDrivenHandoffNarration
                return m
            }),
            ("nil", { try self.makeVM() })
        ]
        for (name, makeModel) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: view(try makeModel()))
            let b = try ViewSnapshotHost.snapshotText(of: view(try makeModel()))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
