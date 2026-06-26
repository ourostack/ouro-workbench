#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU-E4 — Surface E (onboarding) `OnboardingReadinessView` readiness states.
/// DEPENDS ON SU-E1 (`OnboardingRepairStepRow`) + SU-E2 (`FirstRunBootstrapView`), which the
/// not-ready branch embeds.
///
/// Provenance (Q4 default): each `model.onboardingReadiness` is built through the PURE
/// `WorkbenchOnboardingAdvisor().readiness(boss:agents:mcpRegistration:providerChecks:
/// daemonLiveness:)` with controlled inputs, then assigned to the `@Published onboardingReadiness`
/// (the genuine VM seam) — never hand-assembled. The view embeds `OnboardingAgentProviderSummary`
/// (reads `model.ouroAgent(named:)` → the provider·model label) + `FirstRunBootstrapView` +
/// `OnboardingRepairStepRow`, so the matching fixed `OuroAgentRecord` is injected into
/// `model.ouroAgents` (also satisfies AN-001 hermeticity; the temp `agentBundlesURL` is injected
/// into BOTH the registrar AND the inventory).
///
/// **AN-006 (the recorded unreachable observation — do NOT snapshot):** the view's "Optional
/// checks" branch is gated `readiness.isReady && !readiness.repairSteps.isEmpty`
/// (`WorkbenchViewsAndModel.swift:7017`), but `WorkbenchOnboardingAdvisor.readiness(...)` reaches
/// `.ready` only after `guard blockers.isEmpty` (`Onboarding.swift:383`), and the `blockers`
/// filter enumerates EXACTLY the step ids the builder can append on that path → `blockers.isEmpty
/// ⟺ repairSteps.isEmpty`. So `.ready` is reached only with EMPTY `repairSteps` — the "Optional
/// checks" section is a DEAD branch. Per P2 §2b it is NOT fabricated; `testE4_AN006_*` asserts the
/// impossibility through the real seam instead.
///
/// The reachable readiness state-set is `{nil, ready, notReady(.needsCredentials), inProgress
/// (.needsRepair check-*)}` (the `.needsRepair` sub-variants fold into notReady/inProgress).
///
/// Determinism (P3): a FIXED boss name + a fixed `OuroAgentRecord`; all advisor copy is pure Core.
@MainActor
final class OnboardingReadinessViewTests: XCTestCase {

    // MARK: - Hermetic VM (AN-001-safe)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suE4-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func view(_ model: WorkbenchViewModel) -> OnboardingReadinessView { OnboardingReadinessView(model: model) }

    private let advisor = WorkbenchOnboardingAdvisor()
    private static let bossName = "alpha"

    /// A ready agent with BOTH lanes fully configured to the SAME provider·model (so the readiness
    /// collapses to one connection). `humanFacing`/`agentFacing` drive `lanesShareOneConnection`.
    private func readyAgent(lanes: Bool = true) -> OuroAgentRecord {
        let lane = lanes ? OuroAgentLane(provider: "github-copilot", model: "gpt-5.4") : nil
        return OuroAgentRecord(
            name: Self.bossName,
            bundlePath: "/agent-bundles/\(Self.bossName).ouro",
            configPath: "/agent-bundles/\(Self.bossName).ouro/agent.json",
            status: .ready, detail: "ready",
            humanFacing: lane, agentFacing: lane
        )
    }

    /// A ready agent with NO usable lane → the advisor returns `.needsCredentials`.
    private func noLaneAgent() -> OuroAgentRecord {
        OuroAgentRecord(
            name: Self.bossName,
            bundlePath: "/agent-bundles/\(Self.bossName).ouro",
            configPath: "/agent-bundles/\(Self.bossName).ouro/agent.json",
            status: .ready, detail: "ready"
        )
    }

    /// Build a VM whose `onboardingReadiness` is the advisor's verdict for the given inputs, and
    /// whose `ouroAgents` carries the agent (so `OnboardingAgentProviderSummary` resolves it).
    private func vm(
        agent: OuroAgentRecord?,
        providerChecks: [String: OnboardingProviderCheckResult] = [:]
    ) throws -> WorkbenchViewModel {
        let model = try makeVM()
        if let agent { model.ouroAgents = [agent] }
        model.state.boss.agentName = Self.bossName
        model.onboardingReadiness = advisor.readiness(
            boss: BossAgentSelection(agentName: Self.bossName),
            agents: agent.map { [$0] } ?? [],
            mcpRegistration: nil,
            providerChecks: providerChecks
        )
        return model
    }

    // MARK: - SU-E4.a — readiness state-set

    func testE4_nil() throws {
        // onboardingReadiness == nil → only the unconditional header texts render. (The VM's
        // bootstrap derives a `.needsAgent` readiness for an empty machine, so the genuine nil
        // state — the `@Published`'s declared default before any advisor run — is set explicitly;
        // `onboardingReadiness` is the settable VM seam.)
        let model = try makeVM()
        model.onboardingReadiness = nil
        XCTAssertNil(model.onboardingReadiness, "provenance: nil readiness")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains("Connect your agent"), "header always renders:\n\(tree)")
        XCTAssertFalse(tree.contains("is ready"), "nil → no readiness body:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E4.nil")
    }

    func testE4_ready() throws {
        // A ready agent + a usable lane + a PASSED provider check + nil mcpRegistration → the
        // advisor returns .ready with EMPTY repairSteps → checkmark + "<boss> is ready" + the
        // scan-intro; NO "Optional checks" (empty repairSteps).
        let model = try vm(
            agent: readyAgent(),
            providerChecks: ["outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok")]
        )
        let readiness = try XCTUnwrap(model.onboardingReadiness)
        XCTAssertEqual(readiness.state, .ready, "provenance: advisor reached .ready")
        XCTAssertTrue(readiness.repairSteps.isEmpty, "provenance: .ready ⟹ empty repairSteps (AN-006 invariant)")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains("\(Self.bossName) is ready"), "ready → '<boss> is ready':\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="checkmark.seal.fill""#), "ready → checkmark:\n\(tree)")
        XCTAssertFalse(tree.contains("Optional checks"), "ready+empty repairSteps → NO Optional checks:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E4.ready")
    }

    func testE4_notReady_needsCredentials() throws {
        // A ready agent with NO usable lane → .needsCredentials (isReady == false) → the not-ready
        // branch: FirstRunBootstrapView (nil presentation → empty) + the OnboardingStatusRow
        // (headline/detail) + the "Connect a provider" (request-provider-config) repair step.
        let model = try vm(agent: noLaneAgent())
        let readiness = try XCTUnwrap(model.onboardingReadiness)
        XCTAssertEqual(readiness.state, .needsCredentials, "provenance: needsCredentials")
        XCTAssertFalse(readiness.isReady, "provenance: not ready")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains("Connect a provider"), "needsCredentials → Connect a provider:\n\(tree)")
        XCTAssertFalse(tree.contains("is ready"), "not ready → no ready surface:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E4.notReady")
    }

    func testE4_inProgress_checkRunning() throws {
        // A ready agent + a configured lane whose provider check is .running → a `check-outward`
        // repair step (the "Checking…" actorLabel + spinner) → .needsRepair (NOT ready, since a
        // check-* step is in the blockers filter). The repairSteps list renders here (in the
        // not-ready branch, where it is reachable), plus the "first connection check…can take up
        // to a minute" caption.
        let model = try vm(
            agent: readyAgent(),
            providerChecks: ["outward": OnboardingProviderCheckResult(lane: "outward", state: .running, detail: "checking")]
        )
        let readiness = try XCTUnwrap(model.onboardingReadiness)
        XCTAssertEqual(readiness.state, .needsRepair, "provenance: a running check forces .needsRepair")
        XCTAssertTrue(readiness.repairSteps.contains { $0.id.hasPrefix("check-") }, "provenance: a check-* step")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(#"text="Checking…""#), "running check → Checking… pill:\n\(tree)")
        XCTAssertTrue(tree.contains("The first connection check after setup can take up to a minute"),
                      "in-progress caption renders:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "E4.inProgress")
    }

    // MARK: - AN-006 — the unreachable "Optional checks" branch (recorded, NOT fabricated)

    /// AN-006: prove through the REAL advisor seam that `.ready` is reached ONLY with EMPTY
    /// `repairSteps`, so the view's "Optional checks" branch (`readiness.isReady &&
    /// !readiness.repairSteps.isEmpty`) is a DEAD branch. We do NOT fabricate an
    /// `OnboardingReadiness(state: .ready, repairSteps: [non-empty])` to snapshot it (P2 §2b).
    func testE4_AN006_readyImpliesEmptyRepairSteps() throws {
        // Exercise several input shapes that reach .ready; in EVERY case repairSteps is empty.
        let inputs: [[String: OnboardingProviderCheckResult]] = [
            ["outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok")],
            [:] // no checks: a collapsed single-lane ready agent still produces a check step, so
                // use the passed-check shape as the canonical .ready; this empty-checks case is
                // asserted to be NOT .ready (it yields a pending check-* → .needsRepair).
        ]
        // Canonical .ready (passed check) → empty repairSteps.
        let readyReadiness = advisor.readiness(
            boss: BossAgentSelection(agentName: Self.bossName),
            agents: [readyAgent()],
            mcpRegistration: nil,
            providerChecks: inputs[0]
        )
        XCTAssertEqual(readyReadiness.state, .ready)
        XCTAssertTrue(readyReadiness.repairSteps.isEmpty,
                      "AN-006: .ready ⟹ empty repairSteps — the Optional-checks branch is unreachable")
        // A pending (no) check is NOT ready (a check-* blocker) — so it cannot reach the dead branch either.
        let pendingReadiness = advisor.readiness(
            boss: BossAgentSelection(agentName: Self.bossName),
            agents: [readyAgent()],
            mcpRegistration: nil,
            providerChecks: inputs[1]
        )
        XCTAssertNotEqual(pendingReadiness.state, .ready,
                          "AN-006: a pending check → .needsRepair, never .ready-with-repairSteps")
    }

    // MARK: - U5 B3 — DRIVE the `.onAppear` closure (L7184)

    /// U5 B3 (corrected recipe). The view's `.onAppear { model.startFirstRunBootstrapIfNeeded() }`
    /// (`:7184`) is its only interaction region. DRIVEN by `callOnAppear()`. With a `.ready`
    /// readiness, `FirstRunBootstrapDrive.shouldStart(isReady: true, …)` returns false (and the
    /// fully-configured ready agent also short-circuits the configured-agent guard), so
    /// `startFirstRunBootstrapIfNeeded()` early-returns WITHOUT spawning the live bootstrap Task —
    /// the closure executes, the region is covered, and the no-op is asserted
    /// (`firstRunBootstrapIsRunning` stays false, no presentation kicked).
    func testE4_drive_onAppear_readyIsNoOp() throws {
        let model = try vm(
            agent: readyAgent(),
            providerChecks: ["outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok")])
        XCTAssertEqual(model.onboardingReadiness?.isReady, true, "precondition: ready")
        XCTAssertFalse(model.firstRunBootstrapIsRunning, "precondition: bootstrap not running")
        try view(model).inspect().find(ViewType.VStack.self).callOnAppear()
        XCTAssertFalse(model.firstRunBootstrapIsRunning,
                       "ready → startFirstRunBootstrapIfNeeded() early-returns, no bootstrap kicked")
        XCTAssertNil(model.firstRunPresentation, "ready → no live presentation seeded")
    }

    /// MUTATION control for the `.onAppear` — a NOT-ready readiness + a resolved boss makes the
    /// SAME `.onAppear` closure kick the bootstrap: `startFirstRunBootstrapIfNeeded()` proceeds
    /// (`shouldStart(isReady: false, hasResolvedBoss: true, …) == true`), flipping
    /// `firstRunBootstrapIsRunning` true + seeding the idle presentation SYNCHRONOUSLY. We assert
    /// that synchronous effect (the spawned bootstrap Task runs against the hermetic temp dirs and
    /// is not awaited). This proves the `.onAppear` action is behaviorally load-bearing — deleting
    /// it would leave `firstRunBootstrapIsRunning` false.
    func testE4_drive_onAppear_notReadyKicksBootstrap() throws {
        let model = try makeVM()
        // A not-ready readiness with a resolved boss NOT present in ouroAgents → no configured-agent
        // short-circuit → shouldStart == true → the bootstrap starts synchronously.
        model.state.boss.agentName = Self.bossName
        model.onboardingReadiness = OnboardingReadiness(
            state: .needsCredentials, headline: "h", detail: "d",
            selectedBossName: Self.bossName, repairSteps: [])
        XCTAssertFalse(model.firstRunBootstrapIsRunning, "precondition")
        try view(model).inspect().find(ViewType.VStack.self).callOnAppear()
        XCTAssertTrue(model.firstRunBootstrapIsRunning,
                      "not-ready + resolved boss → .onAppear kicks the bootstrap (running flag flips)")
        XCTAssertNotNil(model.firstRunPresentation, "the idle presentation is seeded synchronously")
    }

    // MARK: - SU-E4.b — MUTATION-verified negative control (P2)

    /// NEGATIVE CONTROL — changing the advisor INPUTS so the state flips `.ready` ↔ not-ready
    /// (remove the usable lane → `.needsCredentials`) flips the ready surface ↔ the not-ready
    /// (bootstrap + repair) surface. Proves the rendered surface is driven by the advisor's
    /// `isReady` verdict, not a constant.
    func testE4_negativeControl_readinessStateFlipsSurface() throws {
        let ready = try vm(
            agent: readyAgent(),
            providerChecks: ["outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok")])
        let notReady = try vm(agent: noLaneAgent())
        let readyTree = try ViewSnapshotHost.snapshotText(of: view(ready))
        let notReadyTree = try ViewSnapshotHost.snapshotText(of: view(notReady))
        XCTAssertNotEqual(readyTree, notReadyTree, "the readiness state flips the whole surface")
        XCTAssertTrue(readyTree.contains("\(Self.bossName) is ready"), "ready → ready surface:\n\(readyTree)")
        XCTAssertTrue(notReadyTree.contains("Connect a provider") && !notReadyTree.contains("is ready"),
                      "needsCredentials → not-ready surface:\n\(notReadyTree)")
    }

    // MARK: - Determinism (P3)

    func testE4_determinism_eachStateByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> WorkbenchViewModel)] = [
            ("nil", { let m = try self.makeVM(); m.onboardingReadiness = nil; return m }),
            ("ready", { try self.vm(agent: self.readyAgent(),
                providerChecks: ["outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok")]) }),
            ("notReady", { try self.vm(agent: self.noLaneAgent()) }),
            ("inProgress", { try self.vm(agent: self.readyAgent(),
                providerChecks: ["outward": OnboardingProviderCheckResult(lane: "outward", state: .running, detail: "checking")]) })
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
