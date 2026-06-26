#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C9-3 — the split-container / empty-picker / overflow-menu surfaces of the session-detail
/// family, plus the LIVE-TERMINAL-ARM allowlist carve.
///
///   - `EmptyPanePicker` (`:8850`) — the secondary-pane picker. `if candidates.isEmpty`
///     ("No other sessions…") else `ForEach(candidates)` (a row per other session). Driven by
///     the REAL `model.sessionEntries.filter { $0.id != excluding }`.
///   - `DetailSplitContainer` (`:8731`) — the split host. `if let split = model.detailSplit`
///     → the split chrome (each pane a `SessionDetailView` whose live arm is carved) with the
///     secondary pane an `EmptyPanePicker` when `model.secondaryPaneEntry == nil` else a
///     `SessionDetailView` (inactive arm). `else` → a single `SessionDetailView`. The
///     **live-`TerminalPane` pane arm is carved** (no live session → no pane is ever built).
///   - `RunningSessionHeaderControls` (`:9613`) — the overflow controls. `ForEach(primaryActions)`
///     (`.launch` ↔ `.recover` via the REAL `recoveryPlan(for:)`) + the descended `Menu{}`
///     `switch menuButton` over the pure `SessionActionMenu.layout` seam.
///
/// **LIVE-ARM CARVE (the cluster's named hazard — recorded in the allowlist dossier #3/#4).**
/// `SessionDetailView`/`DetailSplitContainer` embed `TerminalPane` (an `NSViewRepresentable` →
/// live PTY) ONLY inside the `if let session = model.activeSession(for:)` arm. The snapshot seam
/// launches NO session → `activeSession(for:) == nil` for every entry → the live arm is NEVER
/// constructed. We assert that invariant directly (`activeSession == nil` for every fixture
/// entry, and no `TerminalPane`-only node in the tree) and snapshot the inactive/empty/split
/// chrome states. The live arm itself is allowlisted (verified-untestable: a live PTY can't be
/// instantiated in-process) — NOT fabricated.
///
/// **Provenance (P2).** Every fixture is built through the real `WorkbenchStore.save` → hermetic
/// VM seam; `detailSplit` is the real settable `@Published` (the same value the App sets via
/// `splitDetail`). `selectedProjectID` is set so `sessionEntries` surfaces the candidates.
///
/// **Access-widening:** `EmptyPanePicker` `private struct` → `internal` (visibility-only,
/// prod-byte-identical) so `@testable import` can reach it. (`DetailSplitContainer` /
/// `RunningSessionHeaderControls` are already `internal`.)
@MainActor
final class SessionSplitAndOverflowTests: XCTestCase {

    private static let primaryId = UUID(uuidString: "C9000003-0000-0000-0000-000000000001")!
    private static let secondaryId = UUID(uuidString: "C9000003-0000-0000-0000-000000000002")!
    private static let projectId = UUID(uuidString: "C9000003-0000-0000-0000-0000000000A1")!
    private static let altProjectId = UUID(uuidString: "C9000003-0000-0000-0000-0000000000A2")!
    private static let wsId = UUID(uuidString: "C90000A3-0000-0000-0000-0000000000A1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c9-3-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        model.selectedProjectID = Self.projectId
        return model
    }

    private func entry(_ id: UUID, name: String, autoResume: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: id, projectId: Self.projectId, name: name,
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4",
            autoResume: autoResume
        )
    }

    private func run(_ entryId: UUID, _ status: ProcessStatus) -> ProcessRun {
        ProcessRun(id: deterministicRunID(entryId), entryId: entryId, status: status, startedAt: Self.runEpoch)
    }

    private func deterministicRunID(_ entryId: UUID) -> UUID {
        var bytes = entryId.uuid
        bytes.15 ^= 0xFF
        return UUID(uuid: bytes)
    }

    private func state(entries: [ProcessEntry], runs: [ProcessRun] = []) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            selectedProjectId: Self.projectId,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs
        )
    }

    private func loadedEntry(_ model: WorkbenchViewModel, id: UUID) -> ProcessEntry {
        model.state.processEntries.first { $0.id == id }!
    }

    // MARK: - The live-arm carve invariant (asserted, not fabricated)

    /// The whole cluster rests on this: no live session is ever launched in-process, so the
    /// `if let session = model.activeSession(for:)` arm — the ONLY place `TerminalPane` is
    /// constructed — is never entered. Assert it for every fixture entry.
    func testCarve_noLiveSessionForAnyEntry() throws {
        let primary = entry(Self.primaryId, name: "primary")
        let secondary = entry(Self.secondaryId, name: "secondary")
        let model = try makeVM(state: state(entries: [primary, secondary]))
        for e in model.state.processEntries {
            XCTAssertNil(model.activeSession(for: e),
                         "carve-out: no live session for \(e.name) → the live TerminalPane arm is never constructed")
        }
    }

    // MARK: - EmptyPanePicker

    private func picker(_ model: WorkbenchViewModel, excluding: UUID) -> EmptyPanePicker {
        EmptyPanePicker(excluding: excluding, model: model)
    }

    func testPicker_empty_onlyExcludedSession() throws {
        // Only the excluded session exists → candidates empty → the empty-state copy.
        let only = entry(Self.primaryId, name: "only")
        let model = try makeVM(state: state(entries: [only]))
        XCTAssertEqual(model.sessionEntries.filter { $0.id != Self.primaryId }.count, 0,
                       "provenance: no candidates → the empty arm")
        try assertViewSnapshot(of: picker(model, excluding: Self.primaryId), named: "EmptyPanePicker.empty")
    }

    func testPicker_withCandidates() throws {
        // A second session exists → it appears as a candidate row.
        let primary = entry(Self.primaryId, name: "primary")
        let secondary = entry(Self.secondaryId, name: "secondary")
        let model = try makeVM(state: state(entries: [primary, secondary]))
        XCTAssertEqual(model.sessionEntries.filter { $0.id != Self.primaryId }.map(\.name), ["secondary"],
                       "provenance: exactly the other session is a candidate")
        try assertViewSnapshot(of: picker(model, excluding: Self.primaryId), named: "EmptyPanePicker.withCandidates")
    }

    /// `if candidates.isEmpty` flips the picker between the empty copy and the candidate rows.
    func testPicker_negativeControl_candidatesBranchFlipsTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: { () -> EmptyPanePicker in
            let m = try makeVM(state: state(entries: [entry(Self.primaryId, name: "only")]))
            return picker(m, excluding: Self.primaryId)
        }())
        let withCandidate = try ViewSnapshotHost.snapshotText(of: { () -> EmptyPanePicker in
            let m = try makeVM(state: state(entries: [entry(Self.primaryId, name: "primary"),
                                                      entry(Self.secondaryId, name: "secondary")]))
            return picker(m, excluding: Self.primaryId)
        }())
        XCTAssertNotEqual(empty, withCandidate, "the candidates branch must flip the picker")
        XCTAssertTrue(empty.contains("No other sessions in this group yet."), "empty: the empty copy:\n\(empty)")
        XCTAssertTrue(withCandidate.contains(#"text="secondary""#), "withCandidate: the candidate row:\n\(withCandidate)")
        XCTAssertFalse(withCandidate.contains("No other sessions in this group yet."), "withCandidate: not the empty copy:\n\(withCandidate)")
    }

    // MARK: - DetailSplitContainer

    private func container(_ model: WorkbenchViewModel, primary: ProcessEntry) -> DetailSplitContainer {
        DetailSplitContainer(primaryEntry: primary, model: model)
    }

    func testContainer_noSplit_singleDetail() throws {
        let primary = entry(Self.primaryId, name: "primary")
        let model = try makeVM(state: state(entries: [primary]))
        XCTAssertNil(model.detailSplit, "provenance: no split → the single SessionDetailView arm")
        try assertViewSnapshot(of: container(model, primary: loadedEntry(model, id: Self.primaryId)),
                               named: "DetailSplitContainer.noSplit")
    }

    func testContainer_splitWithEmptyPicker() throws {
        // A split with NO secondary entry → the secondary pane shows the EmptyPanePicker.
        let primary = entry(Self.primaryId, name: "primary")
        let secondary = entry(Self.secondaryId, name: "secondary")
        let model = try makeVM(state: state(entries: [primary, secondary]))
        model.detailSplit = DetailSplitState(axis: .vertical, secondaryEntryID: nil)
        XCTAssertNil(model.secondaryPaneEntry, "provenance: split, no secondary → the EmptyPanePicker arm")
        // Carve invariant: neither pane has a live session.
        XCTAssertNil(model.activeSession(for: loadedEntry(model, id: Self.primaryId)))
        try assertViewSnapshot(of: container(model, primary: loadedEntry(model, id: Self.primaryId)),
                               named: "DetailSplitContainer.splitEmptyPicker")
    }

    func testContainer_splitWithSecondarySession() throws {
        // A split WITH a secondary entry → the secondary pane shows that session's
        // SessionDetailView (inactive arm — no live session).
        let primary = entry(Self.primaryId, name: "primary")
        let secondary = entry(Self.secondaryId, name: "secondary")
        let model = try makeVM(state: state(entries: [primary, secondary]))
        model.detailSplit = DetailSplitState(axis: .horizontal, secondaryEntryID: Self.secondaryId)
        XCTAssertEqual(model.secondaryPaneEntry?.id, Self.secondaryId, "provenance: split with secondary")
        XCTAssertNil(model.activeSession(for: loadedEntry(model, id: Self.secondaryId)),
                     "carve: the secondary pane's session is inactive too")
        try assertViewSnapshot(of: container(model, primary: loadedEntry(model, id: Self.primaryId)),
                               named: "DetailSplitContainer.splitSecondary")
    }

    /// `if let split = model.detailSplit` and the secondary-pane `if let entry` both flip the
    /// container tree (single vs split, picker vs secondary detail).
    func testContainer_negativeControl_splitAndSecondaryFlipTree() throws {
        let primary = entry(Self.primaryId, name: "primary")
        let secondary = entry(Self.secondaryId, name: "secondary")
        func tree(_ configure: (WorkbenchViewModel) -> Void) throws -> String {
            let m = try makeVM(state: state(entries: [primary, secondary]))
            configure(m)
            return try ViewSnapshotHost.snapshotText(of: container(m, primary: loadedEntry(m, id: Self.primaryId)))
        }
        let noSplit = try tree { _ in }
        let splitPicker = try tree { $0.detailSplit = DetailSplitState(axis: .vertical, secondaryEntryID: nil) }
        let splitSecondary = try tree { $0.detailSplit = DetailSplitState(axis: .vertical, secondaryEntryID: Self.secondaryId) }
        XCTAssertNotEqual(noSplit, splitPicker, "the split branch must flip the container")
        XCTAssertNotEqual(splitPicker, splitSecondary, "the secondary-pane branch must flip the container")
        XCTAssertTrue(splitPicker.contains("Pick a session for this pane"), "splitPicker: the picker header:\n\(splitPicker)")
        XCTAssertFalse(noSplit.contains("Pick a session for this pane"), "noSplit: no picker:\n\(noSplit)")
        XCTAssertFalse(splitSecondary.contains("Pick a session for this pane"), "splitSecondary: no picker:\n\(splitSecondary)")
    }

    // MARK: - RunningSessionHeaderControls (reclassified — its branches ride the carve)

    private func overflow(_ model: WorkbenchViewModel, entry: ProcessEntry) -> RunningSessionHeaderControls {
        RunningSessionHeaderControls(entry: entry, model: model)
    }

    /// **Reclassification finding (recorded, not hand-waved).** `RunningSessionHeaderControls`
    /// has THREE nominal data-driven branches — `ForEach(controls.primaryActions)`,
    /// `Menu{} switch menuButton` over `SessionActionMenu.layout(isRunning:isCustomSession:)` —
    /// but NONE of them flips through the no-live-session snapshot seam:
    ///   (a) `isRunning = model.activeSession(for:) != nil` is ALWAYS false in-process (the
    ///       live-arm carve) → the `.stop`/Send/Window arms ride the carve;
    ///   (b) `controls.primaryActions` uses `isRecoverable: model.recoveryPlan(for:) != nil`,
    ///       but `recoveryPlan` returns a `.noAction` plan even with NO run (verified:
    ///       "no prior run to recover") → `!= nil` is ALWAYS true → the primary action is
    ///       CONSTANT `[.recover]` (the launchable and needsRecovery trees are byte-identical);
    ///   (c) `isCustomSession` is ALWAYS true for a `.shell`/`.terminalAgent` entry (the only
    ///       kinds the detail surface shows) → the menu layout is constant.
    /// So through this seam the overflow renders ONE reachable static composition. We snapshot
    /// THAT (real coverage of the descended `Menu{}` body) and assert the carve invariant — we
    /// do NOT fabricate an unreachable `isRunning`/launchable flip (the AN-006/C1 discipline).
    /// The non-vacuity control mutates a captured label INSIDE the always-rendered menu.
    func testOverflow_reachableComposition() throws {
        let e = entry(Self.primaryId, name: "primary")
        let model = try makeVM(state: state(entries: [e]))
        let le = loadedEntry(model, id: Self.primaryId)
        XCTAssertNil(model.activeSession(for: le), "carve: not running → the .stop/Send/Window arms are never built")
        XCTAssertNotNil(model.recoveryPlan(for: le), "finding: recoveryPlan != nil even with no run → primary action constant .recover")
        XCTAssertTrue(model.isCustomSession(le), "finding: a .shell is always a custom session → constant menu layout")
        try assertViewSnapshot(of: overflow(model, entry: le), named: "RunningSessionHeaderControls.composition")
    }

    /// The `recoveryPlan != nil` is always-true through the seam, so adding a real
    /// needsRecovery run does NOT change the overflow tree — recorded directly (a guard
    /// against a future regression that would make it accidentally flip / become non-deterministic).
    func testOverflow_recoveryPlanAlwaysPresent_treeIsStable() throws {
        let noRun = try ViewSnapshotHost.snapshotText(of: { () -> RunningSessionHeaderControls in
            let e = entry(Self.primaryId, name: "p")
            let m = try makeVM(state: state(entries: [e]))
            return overflow(m, entry: loadedEntry(m, id: Self.primaryId))
        }())
        let needsRecovery = try ViewSnapshotHost.snapshotText(of: { () -> RunningSessionHeaderControls in
            let e = entry(Self.primaryId, name: "p", autoResume: true)
            let m = try makeVM(state: state(entries: [e], runs: [run(Self.primaryId, .needsRecovery)]))
            return overflow(m, entry: loadedEntry(m, id: Self.primaryId))
        }())
        XCTAssertEqual(noRun, needsRecovery,
                       "finding: recoveryPlan != nil always → the overflow primary action is constant .recover through the seam")
        XCTAssertTrue(noRun.contains(#"text="Recover""#), "the constant Recover primary action:\n\(noRun)")
    }

    // MARK: - Path-leak + determinism (P3)

    func testC9_3_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("picker.withCandidates", {
                let m = try self.makeVM(state: self.state(entries: [self.entry(Self.primaryId, name: "primary"),
                                                                    self.entry(Self.secondaryId, name: "secondary")]))
                return try ViewSnapshotHost.snapshotText(of: self.picker(m, excluding: Self.primaryId))
            }),
            ("container.splitEmptyPicker", {
                let m = try self.makeVM(state: self.state(entries: [self.entry(Self.primaryId, name: "primary"),
                                                                    self.entry(Self.secondaryId, name: "secondary")]))
                m.detailSplit = DetailSplitState(axis: .vertical, secondaryEntryID: nil)
                return try ViewSnapshotHost.snapshotText(of: self.container(m, primary: self.loadedEntry(m, id: Self.primaryId)))
            }),
            ("overflow.composition", {
                let m = try self.makeVM(state: self.state(entries: [self.entry(Self.primaryId, name: "primary")]))
                return try ViewSnapshotHost.snapshotText(of: self.overflow(m, entry: self.loadedEntry(m, id: Self.primaryId)))
            })
        ]
        for (name, make) in cases {
            let a = try make(); let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "\(name): no temp-UUID leak:\n\(a)")
        }
    }
}
#endif
