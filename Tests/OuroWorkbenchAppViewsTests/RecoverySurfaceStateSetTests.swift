#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU-D — Surface D (recovery + archived) COMPLETE enumerated state-set on `RecoverySheet`
/// (+ the sidebar `Section("Archived")` on `WorkbenchSidebarView`).
///
/// Every fixture is provenance-built via the REAL seam: `WorkbenchStore(paths:).save(state)`
/// → a fresh hermetic VM (AN-001 temp `agentBundlesURL` into BOTH the registrar AND the
/// inventory) whose `load()` derives `summary.recoveryPlans` through the PURE `RecoveryPlanner`
/// off each entry's latest `ProcessRun.status`; `model.liveScreenSessionNames` (a settable
/// `@Published`, keyed on `PersistentTerminalSession.sessionName(for: entryId)`) drives the
/// lossless `.reattach`. The SU-D0 spike (`./U3-onboarding-recovery/recovery-extraction-spike.md`)
/// verified: (i) the save→load seam PRESERVES the fixture run status so the planner emits the
/// intended digest buckets; (ii) ViewInspector descends the system `ContentUnavailableView`
/// so the "nothing" reference is meaningful; (iii) `@Environment(\.dismiss)` / `.task` do NOT
/// fire under the synchronous `inspect()` path.
///
/// **VALIDATION-corrected facts:**
///   (4) the auto-recoverable fixture is TRUSTED + `autoResume` on a `.shell` entry → a
///       deterministic `.respawn` plan (the planner routes an UNTRUSTED `.needsRecovery` to
///       `.manualActionNeeded`, which would make the "flip status moves sections" negative
///       control vacuous — so the auto fixture MUST be trusted+autoResume).
///   (5) Recover-All sizing counts reattach plans too (`autoRecoverableEntries =
///       reattach + auto`, gate `count > 1`), so `D.autoOne`'s single entry is NOT
///       reattach-counted, and `D.autoMany`/`D.both` size the union ≥ 2.
///
/// Determinism (P3): the rows render `entry.name` / the planner reason sentence /
/// `launchCommand` (the canonical fixture executable `/bin/zsh`, NO cwd/path) /
/// `entry.lastSummary`; the path-bearing `.help("Recovery detail: …")` tooltips are DROPPED
/// by the host's AN-004. `ProcessRun.startedAt` is a FIXED epoch and is NOT rendered.
@MainActor
final class RecoverySurfaceStateSetTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suD-\(UUID().uuidString)", isDirectory: true)
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
    private func sidebar(_ model: WorkbenchViewModel) -> WorkbenchSidebarView { WorkbenchSidebarView(model: model) }

    // MARK: - Fixture builders

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    // Fixed ids (stable input order → stable resolved order; ids never appear in the tree).
    private static let manualUntrusted = UUID(uuidString: "DD000001-0000-0000-0000-000000000001")!
    private static let manualTrusted = UUID(uuidString: "DD000002-0000-0000-0000-000000000002")!
    private static let autoShell = UUID(uuidString: "DD000003-0000-0000-0000-000000000003")!
    private static let autoShell2 = UUID(uuidString: "DD000004-0000-0000-0000-000000000004")!
    private static let reattachShell = UUID(uuidString: "DD000005-0000-0000-0000-000000000005")!
    private static let archivedId = UUID(uuidString: "DD000006-0000-0000-0000-000000000006")!
    private static let liveTab = UUID(uuidString: "DD000007-0000-0000-0000-000000000007")!

    private func entry(
        id: UUID, name: String, trust: ProcessTrust, autoResume: Bool,
        isArchived: Bool = false, lastSummary: String? = nil
    ) -> ProcessEntry {
        ProcessEntry(
            id: id, projectId: Self.projectId, name: name, kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/suD",
            trust: trust, autoResume: autoResume, isArchived: isArchived,
            lastSummary: lastSummary
        )
    }

    private func run(_ entryId: UUID, _ status: ProcessStatus) -> ProcessRun {
        ProcessRun(id: deterministicRunID(entryId), entryId: entryId, status: status, startedAt: Self.runEpoch)
    }

    /// A deterministic run id derived from the entry id (so re-runs are byte-identical).
    private func deterministicRunID(_ entryId: UUID) -> UUID {
        var bytes = entryId.uuid
        bytes.15 = bytes.15 ^ 0xFF // perturb the last byte → a stable, distinct run id
        return UUID(uuid: bytes)
    }

    /// Build a recovery state: a single workspace whose `tabIds` reference every
    /// NON-archived entry (the migration no-op invariant); archived entries are in NO
    /// workspace. `processRuns` drive the planner.
    private func recoveryState(entries: [ProcessEntry], runs: [ProcessRun]) -> WorkspaceState {
        let nonArchivedIds = entries.filter { !$0.isArchived }.map(\.id)
        return WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsRecovery, autoName: "WS", tabIds: nonArchivedIds)],
            processRuns: runs
        )
    }
    private static let wsRecovery = UUID(uuidString: "DD0000AA-0000-0000-0000-0000000000AA")!

    // MARK: - D.nothing

    func testD_nothing() throws {
        // Empty state → recoveryDigest.shouldShow == false → ContentUnavailableView.
        let model = try makeVM(state: WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        XCTAssertFalse(model.recoveryDigest.shouldShow, "provenance: nothing actionable")
        try assertViewSnapshot(of: sheet(model), named: "D.nothing")
    }

    // MARK: - D.needsYouOnly (also the trust-fix boundary)

    func testD_needsYouOnly() throws {
        // One UNTRUSTED .needsRecovery entry → .manualActionNeeded (blocker .untrusted) →
        // "Needs you" with "Trust & resume" (the trust-fix branch). No auto-recoverable.
        let entries = [entry(id: Self.manualUntrusted, name: "needs-trust", trust: .untrusted, autoResume: false)]
        let runs = [run(Self.manualUntrusted, .needsRecovery)]
        let model = try makeVM(state: recoveryState(entries: entries, runs: runs))
        XCTAssertEqual(model.recoveryDigest.needsYouCount, 1, "provenance: one needs-you")
        XCTAssertEqual(model.recoveryDigest.autoRecoverableCount, 0, "provenance: no auto-recoverable")
        XCTAssertTrue(model.recoveryTrustFixAvailable(for: entries[0]), "provenance: trust-fix available (untrusted blocker)")
        XCTAssertEqual(model.autoRecoverableEntries.count, 0, "provenance: no Recover-All")
        try assertViewSnapshot(of: sheet(model), named: "D.needsYouOnly")
    }

    // MARK: - D.startFresh (the Start-fresh boundary, contrast to trust-fix)

    func testD_startFresh() throws {
        // A TRUSTED entry whose latest run is directly .manualActionNeeded → plan
        // .manualActionNeeded with NO typed blocker → recoveryTrustFixAvailable == false →
        // "Start fresh" (not "Trust & resume"). The Start-fresh half of the boundary.
        let entries = [entry(id: Self.manualTrusted, name: "no-resume", trust: .trusted, autoResume: false)]
        let runs = [run(Self.manualTrusted, .manualActionNeeded)]
        let model = try makeVM(state: recoveryState(entries: entries, runs: runs))
        XCTAssertEqual(model.recoveryDigest.needsYouCount, 1, "provenance: one needs-you")
        XCTAssertFalse(model.recoveryTrustFixAvailable(for: entries[0]), "provenance: NO trust-fix (no untrusted blocker)")
        XCTAssertNil(model.recoveryPlan(for: entries[0])?.blocker, "provenance: no typed blocker → Start fresh")
        try assertViewSnapshot(of: sheet(model), named: "D.startFresh")
    }

    // MARK: - D.autoOne (exactly one auto-recoverable, NO Recover-All)

    func testD_autoOne() throws {
        // One TRUSTED + autoResume .shell .needsRecovery entry → .respawn (auto-recoverable),
        // NOT in liveScreenSessionNames → autoRecoverableEntries.count == 1 → NO Recover-All.
        let entries = [entry(id: Self.autoShell, name: "respawn-me", trust: .trusted, autoResume: true)]
        let runs = [run(Self.autoShell, .needsRecovery)]
        let model = try makeVM(state: recoveryState(entries: entries, runs: runs))
        XCTAssertEqual(model.recoveryDigest.autoRecoverableCount, 1, "provenance: one auto-recoverable (.respawn)")
        XCTAssertEqual(model.recoveryDigest.losslessReattachCount, 0, "provenance: not reattach")
        XCTAssertEqual(model.autoRecoverableEntries.count, 1, "provenance: union size 1 → Recover-All OFF (count > 1 false)")
        XCTAssertEqual(model.recoveryPlan(for: entries[0])?.action, .respawn, "provenance: respawn plan")
        try assertViewSnapshot(of: sheet(model), named: "D.autoOne")
    }

    // MARK: - D.autoMany (≥2 auto-recoverable → Recover-All SHOWN)

    func testD_autoMany() throws {
        // Two TRUSTED + autoResume .shell .needsRecovery entries → two .respawn plans →
        // autoRecoverableEntries.count == 2 → Recover-All SHOWN (count > 1).
        let entries = [
            entry(id: Self.autoShell, name: "respawn-alpha", trust: .trusted, autoResume: true),
            entry(id: Self.autoShell2, name: "respawn-bravo", trust: .trusted, autoResume: true)
        ]
        let runs = [run(Self.autoShell, .needsRecovery), run(Self.autoShell2, .needsRecovery)]
        let model = try makeVM(state: recoveryState(entries: entries, runs: runs))
        XCTAssertEqual(model.autoRecoverableEntries.count, 2, "provenance: union size 2 → Recover-All ON")
        XCTAssertEqual(model.recoveryDigest.needsYouCount, 0, "provenance: no needs-you")
        try assertViewSnapshot(of: sheet(model), named: "D.autoMany")
    }

    // MARK: - D.both (needs-you AND auto-recoverable)

    func testD_both() throws {
        // One untrusted .needsRecovery (needs-you / trust-fix) + one trusted+autoResume
        // .shell .needsRecovery (.respawn, auto) → BOTH sections render. Distinct names (Q6).
        let entries = [
            entry(id: Self.manualUntrusted, name: "needs-trust", trust: .untrusted, autoResume: false),
            entry(id: Self.autoShell, name: "respawn-me", trust: .trusted, autoResume: true)
        ]
        let runs = [run(Self.manualUntrusted, .needsRecovery), run(Self.autoShell, .needsRecovery)]
        let model = try makeVM(state: recoveryState(entries: entries, runs: runs))
        XCTAssertEqual(model.recoveryDigest.needsYouCount, 1, "provenance: one needs-you")
        XCTAssertEqual(model.recoveryDigest.autoRecoverableCount, 1, "provenance: one auto-recoverable")
        try assertViewSnapshot(of: sheet(model), named: "D.both")
    }

    // MARK: - D.losslessReattach (the reattach pill vs not — ROW-level, both in "Ready to recover")

    func testD_losslessReattach() throws {
        // Two TRUSTED + autoResume .shell .needsRecovery entries; ONE has its derived session
        // name in liveScreenSessionNames → .reattach (the "Reconnect — no loss" pill + green
        // link glyph), the OTHER → .respawn (no pill, orange glyph). Both render WITHIN
        // "Ready to recover" (the union → Recover-All ON, since union size 2; fact (5)).
        let entries = [
            entry(id: Self.reattachShell, name: "reconnect-me", trust: .trusted, autoResume: true, lastSummary: "live agent"),
            entry(id: Self.autoShell, name: "respawn-me", trust: .trusted, autoResume: true)
        ]
        let runs = [run(Self.reattachShell, .needsRecovery), run(Self.autoShell, .needsRecovery)]
        let model = try makeVM(state: recoveryState(entries: entries, runs: runs))
        model.liveScreenSessionNames = [PersistentTerminalSession.sessionName(for: Self.reattachShell)]
        XCTAssertEqual(model.recoveryDigest.losslessReattachCount, 1, "provenance: one reattach")
        XCTAssertEqual(model.recoveryDigest.autoRecoverableCount, 1, "provenance: one respawn")
        XCTAssertTrue(model.isLosslessReattach(for: entries[0]), "provenance: the live one reattaches")
        XCTAssertFalse(model.isLosslessReattach(for: entries[1]), "provenance: the other respawns")
        try assertViewSnapshot(of: sheet(model), named: "D.losslessReattach")
    }

    // MARK: - D.sidebarArchived (the sidebar Section("Archived"))

    func testD_sidebarArchived() throws {
        // An ARCHIVED entry (isArchived, in NO workspace's tabIds) → the sidebar
        // Section("Archived") renders (gate `!archivedSessionEntries.isEmpty`). A live
        // (non-archived) tab is in the workspace so the migration is a no-op.
        let entries = [
            entry(id: Self.liveTab, name: "live-tab", trust: .trusted, autoResume: false),
            entry(id: Self.archivedId, name: "archived-session", trust: .trusted, autoResume: false, isArchived: true)
        ]
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsRecovery, autoName: "WS", tabIds: [Self.liveTab])]
        )
        let model = try makeVM(state: state)
        XCTAssertEqual(model.archivedSessionEntries.map(\.name), ["archived-session"],
                       "provenance: exactly the archived entry is in the Archived section")
        try assertViewSnapshot(of: sidebar(model), named: "D.sidebarArchived")
    }

    // MARK: - MUTATION-verified negative controls (P2) — in-tree flips

    /// NEGATIVE CONTROL (1) — flipping a TRUSTED+autoResume entry's latest run status
    /// `.needsRecovery`↔`.manualActionNeeded` MOVES the row between "Ready to recover" and
    /// "Needs you" (the section membership at the call site AND the tree flip). On a
    /// trusted+autoResume entry this is non-vacuous (fact (4)).
    func testD_negativeControl_runStatusMovesSection() throws {
        func model(status: ProcessStatus) throws -> WorkbenchViewModel {
            let entries = [entry(id: Self.autoShell, name: "respawn-me", trust: .trusted, autoResume: true)]
            return try makeVM(state: recoveryState(entries: entries, runs: [run(Self.autoShell, status)]))
        }
        let needsRecovery = try model(status: .needsRecovery)
        let manualNeeded = try model(status: .manualActionNeeded)
        // Section membership flips at the call site (a vacuous no-move would fail here).
        XCTAssertEqual(needsRecovery.recoveryDigest.autoRecoverableCount, 1, "needsRecovery → auto-recoverable")
        XCTAssertEqual(needsRecovery.recoveryDigest.needsYouCount, 0)
        XCTAssertEqual(manualNeeded.recoveryDigest.autoRecoverableCount, 0)
        XCTAssertEqual(manualNeeded.recoveryDigest.needsYouCount, 1, "manualActionNeeded → needs-you")
        // And the rendered tree flips.
        let recoverTree = try ViewSnapshotHost.snapshotText(of: sheet(needsRecovery))
        let manualTree = try ViewSnapshotHost.snapshotText(of: sheet(manualNeeded))
        XCTAssertNotEqual(recoverTree, manualTree, "the row moves sections → the tree flips")
        XCTAssertTrue(recoverTree.contains("Ready to recover"), "needsRecovery shows Ready-to-recover:\n\(recoverTree)")
        XCTAssertTrue(manualTree.contains("Needs you"), "manualActionNeeded shows Needs-you:\n\(manualTree)")
    }

    /// NEGATIVE CONTROL (2) — adding/removing the entry's DERIVED session name from
    /// `liveScreenSessionNames` toggles the "Reconnect — no loss" pill.
    func testD_negativeControl_liveSessionTogglesReattachPill() throws {
        let entries = [entry(id: Self.reattachShell, name: "reconnect-me", trust: .trusted, autoResume: true)]
        func tree(live: Bool) throws -> String {
            let m = try makeVM(state: recoveryState(entries: entries, runs: [run(Self.reattachShell, .needsRecovery)]))
            if live { m.liveScreenSessionNames = [PersistentTerminalSession.sessionName(for: Self.reattachShell)] }
            return try ViewSnapshotHost.snapshotText(of: sheet(m))
        }
        let withPill = try tree(live: true)
        let withoutPill = try tree(live: false)
        XCTAssertNotEqual(withPill, withoutPill, "the reattach pill flips the tree")
        XCTAssertTrue(withPill.contains("Reconnect — no loss"), "live session → pill:\n\(withPill)")
        XCTAssertFalse(withoutPill.contains("Reconnect — no loss"), "no live session → no pill:\n\(withoutPill)")
    }

    /// NEGATIVE CONTROL (3) — flipping `entry.trust` on a `.needsRecovery` entry flips
    /// "Trust & resume" (untrusted → needs-you with the one-click fix) ↔ a recoverable
    /// `.respawn` (trusted+autoResume → "Ready to recover"). Proves the trust gate is
    /// load-bearing in the rendered surface.
    func testD_negativeControl_trustFlipsRow() throws {
        func tree(trust: ProcessTrust) throws -> (String, WorkbenchViewModel, ProcessEntry) {
            let e = entry(id: Self.manualUntrusted, name: "row", trust: trust, autoResume: true)
            let m = try makeVM(state: recoveryState(entries: [e], runs: [run(Self.manualUntrusted, .needsRecovery)]))
            return (try ViewSnapshotHost.snapshotText(of: sheet(m)), m, e)
        }
        let (untrustedTree, untrustedModel, untrustedEntry) = try tree(trust: .untrusted)
        let (trustedTree, _, _) = try tree(trust: .trusted)
        XCTAssertNotEqual(untrustedTree, trustedTree, "flipping trust flips the row's section/button")
        XCTAssertTrue(untrustedModel.recoveryTrustFixAvailable(for: untrustedEntry), "untrusted → trust-fix")
        XCTAssertTrue(untrustedTree.contains("Trust & resume"), "untrusted → Trust & resume:\n\(untrustedTree)")
        XCTAssertTrue(trustedTree.contains("Ready to recover"), "trusted+autoResume → Ready to recover:\n\(trustedTree)")
        XCTAssertFalse(trustedTree.contains("Trust & resume"), "trusted has no Trust & resume:\n\(trustedTree)")
    }

    /// NEGATIVE CONTROL (4) — Recover-All appears only when the auto-recoverable union > 1.
    func testD_negativeControl_recoverAllGate() throws {
        let one = try makeVM(state: recoveryState(
            entries: [entry(id: Self.autoShell, name: "a", trust: .trusted, autoResume: true)],
            runs: [run(Self.autoShell, .needsRecovery)]))
        let many = try makeVM(state: recoveryState(
            entries: [entry(id: Self.autoShell, name: "a", trust: .trusted, autoResume: true),
                      entry(id: Self.autoShell2, name: "b", trust: .trusted, autoResume: true)],
            runs: [run(Self.autoShell, .needsRecovery), run(Self.autoShell2, .needsRecovery)]))
        let oneTree = try ViewSnapshotHost.snapshotText(of: sheet(one))
        let manyTree = try ViewSnapshotHost.snapshotText(of: sheet(many))
        XCTAssertFalse(oneTree.contains("Recover All"), "one auto-recoverable → NO Recover All:\n\(oneTree)")
        XCTAssertTrue(manyTree.contains("Recover All"), "two auto-recoverable → Recover All:\n\(manyTree)")
    }

    /// NEGATIVE CONTROL (5) — the sidebar Archived section appears only when there is an
    /// archived entry (gate `!archivedSessionEntries.isEmpty`).
    func testD_negativeControl_archivedSectionGate() throws {
        let withArchived = try makeVM(state: WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry(id: Self.liveTab, name: "live", trust: .trusted, autoResume: false),
                             entry(id: Self.archivedId, name: "arch", trust: .trusted, autoResume: false, isArchived: true)],
            workspaces: [Workspace(id: Self.wsRecovery, autoName: "WS", tabIds: [Self.liveTab])]))
        let withoutArchived = try makeVM(state: WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry(id: Self.liveTab, name: "live", trust: .trusted, autoResume: false)],
            workspaces: [Workspace(id: Self.wsRecovery, autoName: "WS", tabIds: [Self.liveTab])]))
        let withTree = try ViewSnapshotHost.snapshotText(of: sidebar(withArchived))
        let withoutTree = try ViewSnapshotHost.snapshotText(of: sidebar(withoutArchived))
        XCTAssertNotEqual(withTree, withoutTree, "the Archived section flips the sidebar tree")
        XCTAssertTrue(withTree.contains(#"text="Archived""#), "archived entry → Archived section:\n\(withTree)")
        XCTAssertFalse(withoutTree.contains(#"text="Archived""#), "no archived entry → no Archived section:\n\(withoutTree)")
    }

    // MARK: - Determinism (P3)

    func testD_determinism_eachFixtureByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("nothing", {
                try ViewSnapshotHost.snapshotText(of: self.sheet(try self.makeVM(
                    state: WorkspaceState(boss: BossAgentSelection(agentName: "boss")))))
            }),
            ("both", {
                let entries = [
                    self.entry(id: Self.manualUntrusted, name: "needs-trust", trust: .untrusted, autoResume: false),
                    self.entry(id: Self.autoShell, name: "respawn-me", trust: .trusted, autoResume: true)
                ]
                let runs = [self.run(Self.manualUntrusted, .needsRecovery), self.run(Self.autoShell, .needsRecovery)]
                return try ViewSnapshotHost.snapshotText(of: self.sheet(try self.makeVM(
                    state: self.recoveryState(entries: entries, runs: runs))))
            }),
            ("reattach", {
                let entries = [self.entry(id: Self.reattachShell, name: "reconnect-me", trust: .trusted, autoResume: true)]
                let m = try self.makeVM(state: self.recoveryState(entries: entries, runs: [self.run(Self.reattachShell, .needsRecovery)]))
                m.liveScreenSessionNames = [PersistentTerminalSession.sessionName(for: Self.reattachShell)]
                return try ViewSnapshotHost.snapshotText(of: self.sheet(m))
            }),
            ("sidebarArchived", {
                let entries = [
                    self.entry(id: Self.liveTab, name: "live-tab", trust: .trusted, autoResume: false),
                    self.entry(id: Self.archivedId, name: "archived-session", trust: .trusted, autoResume: false, isArchived: true)
                ]
                let state = WorkspaceState(
                    boss: BossAgentSelection(agentName: "boss"),
                    processEntries: entries,
                    workspaces: [Workspace(id: Self.wsRecovery, autoName: "WS", tabIds: [Self.liveTab])])
                return try ViewSnapshotHost.snapshotText(of: self.sidebar(try self.makeVM(state: state)))
            })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
