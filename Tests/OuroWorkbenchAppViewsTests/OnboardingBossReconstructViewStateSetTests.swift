#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C10-6 — the "Bring back your work" onboarding step (`OnboardingBossReconstructView` `:7377`).
/// The boss-reconstruct hand-off page: gate on readiness, offer the kick-off button, then show
/// the in-progress / finished hand-off state.
///
/// **Access-widening (recorded, surfaced to the operator).** The view was a `private struct`;
/// `@testable import` cannot construct a `private` type standalone, so it is widened
/// `private`→`internal` (zero-behavior, prod-byte-identical — the only Sources behavior change in
/// C10-6, every mutation reverted byte-identically). The parent onboarding page still embeds it
/// via the same `OnboardingBossReconstructView(model:)` initializer (`:6692`).
///
/// **Provenance (P2).** Every branch is driven by the REAL model seam: `onboardingReadiness`
/// (a real `OnboardingReadiness` via its public initializer; `.ready` → `isReady == true`),
/// `onboardingReconstructionHandedOff` + `bossCheckInIsRunning` (`@Published`, set the way the
/// production hand-off path sets them), and `state.boss.agentName` (the real `BossAgentSelection`).
/// The intro/empty copy comes from the REAL `WorkbenchOnboardingNarrative` Core constants. NO
/// fabricated state — each is the genuine value the seam produces.
///
/// **No clock / path surface** → no cross-TZ proof, no path-leak fixture needed.
///
/// **Enumerated state-set (the view's data-driven branches):**
///   - `notReady`      — `onboardingReadiness?.isReady != true` → the "Finish connecting…" callout.
///   - `readyToStart`  — ready + not handed off → the "Bring Back My Work" button.
///   - `handedRunning` — ready + handed off + `bossCheckInIsRunning` → the "is looking for your
///                       recent work…" line (the spinner arm).
///   - `handedDone`    — ready + handed off + not running → the green check + "has finished — see
///                       its reply below." + the "Ask Again" button.
@MainActor
final class OnboardingBossReconstructViewStateSetTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c10reconstruct-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "slugger")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        // A fixed boss name (no machine-local leak) the "finished/looking" copy interpolates.
        model.state = WorkspaceState(boss: BossAgentSelection(agentName: "slugger"))
        return model
    }

    private func readiness(_ state: OnboardingReadinessState) -> OnboardingReadiness {
        OnboardingReadiness(state: state, headline: "h", detail: "d",
                            selectedBossName: "slugger", repairSteps: [])
    }

    private func view(
        readiness state: OnboardingReadinessState?,
        handedOff: Bool = false,
        running: Bool = false
    ) throws -> OnboardingBossReconstructView {
        let model = try makeVM()
        model.onboardingReadiness = state.map(readiness)
        model.onboardingReconstructionHandedOff = handedOff
        model.bossCheckInIsRunning = running
        return OnboardingBossReconstructView(model: model)
    }

    // MARK: - Enumerated state-set

    /// NOT READY — readiness not `.ready` → the "Finish connecting the boss…" callout, no button.
    func testReconstruct_notReady() throws {
        let view = try view(readiness: .needsAgent)
        XCTAssertNotEqual(view.model.onboardingReadiness?.isReady, true, "provenance: not ready")
        try assertViewSnapshot(of: view, named: "OnboardingBossReconstructView.notReady")
    }

    /// READY, NOT HANDED OFF — the "Bring Back My Work" kick-off button.
    func testReconstruct_readyToStart() throws {
        let view = try view(readiness: .ready, handedOff: false)
        XCTAssertEqual(view.model.onboardingReadiness?.isReady, true, "provenance: ready")
        XCTAssertFalse(view.model.onboardingReconstructionHandedOff, "provenance: not handed off")
        try assertViewSnapshot(of: view, named: "OnboardingBossReconstructView.readyToStart")
    }

    /// HANDED OFF, RUNNING — the boss is working → the spinner arm + "is looking for your recent
    /// work…" line (interpolating the fixed boss name).
    func testReconstruct_handedRunning() throws {
        let view = try view(readiness: .ready, handedOff: true, running: true)
        try assertViewSnapshot(of: view, named: "OnboardingBossReconstructView.handedRunning")
    }

    /// HANDED OFF, DONE — the boss finished → the green check + "has finished — see its reply
    /// below." + the "Ask Again" button.
    func testReconstruct_handedDone() throws {
        let view = try view(readiness: .ready, handedOff: true, running: false)
        try assertViewSnapshot(of: view, named: "OnboardingBossReconstructView.handedDone")
    }

    // MARK: - Determinism (P3)

    func testReconstruct_determinism_byteIdenticalTwiceNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try view(readiness: .ready, handedOff: true, running: true))
        let b = try ViewSnapshotHost.snapshotText(of: try view(readiness: .ready, handedOff: true, running: true))
        XCTAssertEqual(a, b, "the reconstruct page must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertTrue(a.contains("slugger"), "the fixed boss name interpolates (no machine leak):\n\(a)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The readiness + hand-off + running flags each flip the tree across the four arms — real
    /// model-driven branches.
    func testReconstruct_negativeControl_flagsFlipTree() throws {
        let notReady = try ViewSnapshotHost.snapshotText(of: try view(readiness: .needsAgent))
        let readyToStart = try ViewSnapshotHost.snapshotText(of: try view(readiness: .ready))
        let running = try ViewSnapshotHost.snapshotText(of: try view(readiness: .ready, handedOff: true, running: true))
        let done = try ViewSnapshotHost.snapshotText(of: try view(readiness: .ready, handedOff: true, running: false))

        XCTAssertNotEqual(notReady, readyToStart, "the isReady gate must flip the tree")
        XCTAssertTrue(notReady.contains("Finish connecting"), "not-ready: the gating callout:\n\(notReady)")
        XCTAssertFalse(notReady.contains("Bring Back My Work"), "not-ready: no kick-off button")
        XCTAssertTrue(readyToStart.contains("Bring Back My Work"), "ready: the kick-off button:\n\(readyToStart)")

        XCTAssertNotEqual(readyToStart, running, "the handedOff flag must flip the tree")
        XCTAssertTrue(running.contains("is looking for your recent work"),
                      "running: the in-progress line:\n\(running)")

        XCTAssertNotEqual(running, done, "the bossCheckInIsRunning flag must flip the tree")
        XCTAssertTrue(done.contains("has finished"), "done: the finished line:\n\(done)")
        XCTAssertTrue(done.contains("Ask Again"), "done: the Ask Again button:\n\(done)")
    }
}
#endif
