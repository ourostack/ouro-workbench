#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// AN-R3-03 — energy-0 round-3 close for the `.autoResume` arm of `recoveryButtonTitle(for:)`
/// (`:14963`) as rendered by `RecoverableEntryRow`'s recover button (`:1138`).
///
/// `RecoverableEntryRow` renders `Label(model.recoveryButtonTitle(for: entry), …)`, where the
/// title is a five-arm switch over the entry's `RecoveryPlan.action`:
///
///   - .reattach          → "Reconnect"        — pinned (D.losslessReattach)
///   - .autoResume        → "Resume"           ← UNCONTROLLED (residual P2 energy)
///   - .respawn           → "Respawn"          — pinned (D.autoOne / D.autoMany)
///   - .manualActionNeeded→ "Manual Recovery"  — UNREACHABLE here (routes to needsYouEntries →
///                                                NeedsYouEntryRow, not RecoverableEntryRow);
///                                                classify-and-record, NOT closed in this tier.
///   - .noAction          → "Recover"          — pinned (the guard default)
///
/// The round-3 single-actor serial mutation sweep proved the `.autoResume` arm was residual energy:
/// mutating its "Resume" string left the FULL app-views suite GREEN — every committed Recovery
/// fixture is a `.shell` entry (→ `.respawn`) or a live `screen` session (→ `.reattach`); none is a
/// native-resume terminal agent (→ `.autoResume`), so no test ever rendered the "Resume" button,
/// even though a trusted Claude/Codex agent with persisted native-resume metadata produces exactly
/// that plan on every reboot. The sibling reachable arms (.reattach / .respawn / .noAction) went RED
/// under the same sweep (caught in the D.* snapshots), so this leaf closes the one live gap.
///
/// **Provenance (P2).** The `.autoResume` plan is producer-derived end-to-end through the REAL
/// seam: a trusted, auto-resume `.terminalAgent` whose `executable` detects as `.claudeCode`
/// (`TerminalAgentDetector` → the `nativeResumeCommand` preset) plus a latest run carrying a
/// non-empty `terminalSessionId` makes `RecoveryPlanner` emit `.autoResume`
/// (`RecoveryPlanner.swift:217`). The test asserts the planner actually produced `.autoResume`
/// before asserting the rendered "Resume" — no hand-set action. The VM is built through the real
/// `WorkbenchStore.save` + `WorkbenchViewModel` path the other Recovery surface tests use.
///
/// **Determinism (P3).** Fixed ids / a fixed run epoch; the rendered launch command + reason are
/// pure model derivations (no clock / path-from-home / UUID renders). Byte-identical twice + no
/// machine-path leak below (the workingDirectory is a fixed `/tmp/...`, not a `$HOME` path).
@MainActor
final class RecoverableEntryRowAutoResumeLeafTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000DA")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let claudeAgent = UUID(uuidString: "DA000001-0000-0000-0000-000000000001")!
    private static let shellAgent = UUID(uuidString: "DA000002-0000-0000-0000-000000000002")!
    private static let wsRecovery = UUID(uuidString: "DA0000AA-0000-0000-0000-0000000000AA")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suDA-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func sheet(_ model: WorkbenchViewModel) -> RecoverySheet { RecoverySheet(model: model) }

    /// A trusted, auto-resume Claude terminal agent — the real producer of an `.autoResume` plan.
    private func claudeEntry() -> ProcessEntry {
        ProcessEntry(
            id: Self.claudeAgent, projectId: Self.projectId, name: "resume-claude",
            kind: .terminalAgent, executable: "/usr/local/bin/claude", workingDirectory: "/tmp/suDA",
            trust: .trusted, autoResume: true
        )
    }

    /// The latest run carries a native-resume session id → the planner routes to `.autoResume`
    /// (NOT `.respawn`, which is the no-session-id / checkpoint path).
    private func claudeRun() -> ProcessRun {
        ProcessRun(
            id: UUID(uuidString: "DA000001-0000-0000-0000-0000000000FF")!,
            entryId: Self.claudeAgent, status: .needsRecovery, startedAt: Self.runEpoch,
            terminalSessionId: "claude-session-7"
        )
    }

    private func state(entries: [ProcessEntry], runs: [ProcessRun]) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsRecovery, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs
        )
    }

    // MARK: - The committed reference — the .autoResume row renders the "Resume" button

    func testRow_autoResume_rendersResumeButton() throws {
        let model = try makeVM(state: state(entries: [claudeEntry()], runs: [claudeRun()]))

        // Provenance: the REAL planner produced .autoResume (not a hand-set action).
        XCTAssertEqual(model.recoveryPlan(for: claudeEntry())?.action, .autoResume,
                       "provenance: trusted native-resume claude agent + session id → .autoResume")
        XCTAssertEqual(model.recoveryButtonTitle(for: claudeEntry()), "Resume",
                       "provenance: the .autoResume arm's title is 'Resume'")
        XCTAssertEqual(model.autoRecoverableEntries.count, 1,
                       "provenance: the .autoResume entry lands in the RecoverableEntryRow section")

        let tree = try ViewSnapshotHost.snapshotText(of: sheet(model))
        XCTAssertTrue(tree.contains(#"text="Resume""#), "the .autoResume recover button reads 'Resume':\n\(tree)")
        try assertViewSnapshot(of: sheet(model), named: "RecoverableEntryRow.autoResume")
    }

    // MARK: - Negative control (P2) — .respawn renders a DIFFERENT title ("Respawn")

    /// Flipping the producer's action (native-resume claude → a plain shell, which yields `.respawn`)
    /// flips the rendered title from "Resume" to "Respawn" — proving the `.autoResume` arm governs
    /// the captured button text, not an incidental constant.
    func testRow_negativeControl_respawnRendersRespawnNotResume() throws {
        let shell = ProcessEntry(
            id: Self.shellAgent, projectId: Self.projectId, name: "respawn-shell",
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/suDA",
            trust: .trusted, autoResume: true)
        let shellRun = ProcessRun(
            id: UUID(uuidString: "DA000002-0000-0000-0000-0000000000FF")!,
            entryId: Self.shellAgent, status: .needsRecovery, startedAt: Self.runEpoch)
        let model = try makeVM(state: state(entries: [shell], runs: [shellRun]))

        XCTAssertEqual(model.recoveryPlan(for: shell)?.action, .respawn,
                       "provenance: a plain shell auto-resume entry → .respawn")
        let tree = try ViewSnapshotHost.snapshotText(of: sheet(model))
        XCTAssertTrue(tree.contains(#"text="Respawn""#), "the .respawn arm reads 'Respawn':\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="Resume""#), "a .respawn row must NOT read 'Resume':\n\(tree)")
    }

    // MARK: - Determinism (P3)

    func testRow_autoResume_twiceRunByteIdentical_noLeak() throws {
        let model = try makeVM(state: state(entries: [claudeEntry()], runs: [claudeRun()]))
        let a = try ViewSnapshotHost.snapshotText(of: sheet(model))
        let b = try ViewSnapshotHost.snapshotText(of: sheet(model))
        XCTAssertEqual(a, b, "the .autoResume recovery sheet must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
