#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C9-1 — the session-detail INSPECTOR + TITLE STRIP family (the inspector-toggle
/// SwiftUI states the live-terminal-arm carve leaves snapshottable).
///
/// `SessionDetailView`'s INACTIVE arm was already covered by `SessionDetailViewInactiveArmTests`
/// (C0 SU-6 — the live-`TerminalPane` arm carve-out template). This unit covers the REMAINING
/// C9 surfaces in the inspector branch:
///
///   - `SessionInspectorPanel` (`:9161`) — the disclosure panel shown when `showsInspector`.
///     Its `body` renders `Text(model.launchCommand(for: entry))` (`:9193`, **path-leak vector
///     #1** of the two the review gate named — built from the entry's executable + working
///     directory), optional pills (group / cli / owner-badge / trust / auto-resume), an optional
///     `SessionNotesView` (`if let notes = entry.trimmedNotes`), the recovery sentence, and the
///     `if model.transcriptTail(for:) != nil` Transcript button.
///   - `SessionTitleStrip` (`:9036`) — the slim one-row header. `entry.name` Text + optional
///     `cliName` pill + `if entry.isArchived` (Archived label + Restore) vs the
///     `RunningSessionHeaderControls` overflow. (The `liveAttentionToAnnounce` label rides the
///     LIVE-ARM carve — it only renders for `isActiveSession`, structurally unreachable through
///     the no-live-session seam; classified, not fabricated — see the carve dossier.)
///   - `SessionTranscriptSheet` (`:9229`) — the modal transcript sheet. `if let tail =
///     model.transcriptTail(for:)` → `TranscriptHistoryView` else "No transcript captured yet."
///
/// **Provenance (P2).** Every fixture is built via the REAL seam: `WorkbenchStore(paths:).save`
/// → a hermetic VM (AN-001 temp `agentBundlesURL` into BOTH the registrar AND the inventory).
/// The transcript-present state is provenance-built by writing a REAL transcript FILE under a
/// FIXED `/tmp` run dir and a `ProcessRun.transcriptPath` pointing at it, so
/// `transcriptTail(for:)` returns a genuine `TranscriptTail` whose `path` is the fixed file —
/// not a fabricated value (`transcriptTail` reads the file off disk through `TranscriptTailReader`).
///
/// **Path-leak (P3 — the cluster's named hazard, vector #1).** `launchCommand` is composed from
/// `executable` + `workingDirectory`; a real `~`-rooted working dir would leak `/Users/<name>/`.
/// The fixture pins a FIXED `/tmp/u4` working directory (the SU3 `/tmp/su3` precedent), defended
/// by `!tree.contains("/Users/")`.
///
/// **Access-widening (SU-E precedent):** `SessionTitleStrip`, `SessionInspectorPanel`,
/// `SessionTranscriptSheet` were `private struct` → widened to `internal` (visibility-only,
/// zero behavior) so `@testable import` can reach them.
@MainActor
final class SessionInspectorAndTitleStripTests: XCTestCase {

    // MARK: - Fixed ids (stable input → stable resolved order; ids never appear in the tree)

    private static let entryId = UUID(uuidString: "C9000001-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "C9000000-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C90000AA-0000-0000-0000-0000000000A1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    /// Build a hermetic VM. `tmpRoot` is returned so a caller that writes a transcript
    /// FILE can place it under the SAME root the run's `transcriptPath` points at.
    private func makeVM(state: WorkspaceState, tmpRoot: URL) throws -> WorkbenchViewModel {
        let agentBundles = tmpRoot.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmpRoot)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func tmpRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c9-1-\(UUID().uuidString)", isDirectory: true)
    }

    /// A fixed `.shell` entry with a FIXED `/tmp/u4` working dir (the path-leak fix — the
    /// launch command renders the executable + cwd).
    private func entry(
        isArchived: Bool = false,
        notes: String? = nil,
        name: String = "build",
        executable: String = "/bin/zsh"
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name,
            kind: .shell, executable: executable, workingDirectory: "/tmp/u4",
            isArchived: isArchived, notes: notes
        )
    }

    private func state(entry: ProcessEntry, runs: [ProcessRun] = []) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.entryId])],
            processRuns: runs
        )
    }

    // MARK: - SessionInspectorPanel

    private func inspector(_ model: WorkbenchViewModel, entry: ProcessEntry) -> SessionInspectorPanel {
        SessionInspectorPanel(entry: entry, model: model, onShowTranscript: {})
    }

    func testInspector_basic_noNotesNoTranscript() throws {
        let e = entry()
        let model = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
        let loaded = model.state.processEntries.first ?? e
        XCTAssertNil(model.transcriptTail(for: loaded), "provenance: no run → no transcript → no Transcript button")
        XCTAssertNil(loaded.trimmedNotes, "provenance: no notes → no SessionNotesView")
        try assertViewSnapshot(of: inspector(model, entry: loaded), named: "SessionInspectorPanel.basic")
    }

    func testInspector_withNotes() throws {
        let e = entry(notes: "left mid-refactor")
        let model = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
        let loaded = model.state.processEntries.first ?? e
        XCTAssertEqual(loaded.trimmedNotes, "left mid-refactor", "provenance: notes present → SessionNotesView renders")
        try assertViewSnapshot(of: inspector(model, entry: loaded), named: "SessionInspectorPanel.withNotes")
    }

    func testInspector_withTranscript_showsTranscriptButton() throws {
        let root = tmpRoot()
        let e = entry()
        let (run, _) = try writeTranscript(under: root, text: "hello from the agent\n")
        let model = try makeVM(state: state(entry: e, runs: [run]), tmpRoot: root)
        let loaded = model.state.processEntries.first ?? e
        XCTAssertNotNil(model.transcriptTail(for: loaded), "provenance: a real transcript file → the Transcript button branch")
        try assertViewSnapshot(of: inspector(model, entry: loaded), named: "SessionInspectorPanel.withTranscript")
    }

    // MARK: - Path-leak defense (P3 — vector #1: launchCommand)

    func testInspector_pathLeakDefense_noMachinePathInTree() throws {
        for notes in [nil, "a note"] as [String?] {
            let e = entry(notes: notes)
            let model = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            let loaded = model.state.processEntries.first ?? e
            let tree = try ViewSnapshotHost.snapshotText(of: inspector(model, entry: loaded))
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified) — the notes branch flips the tree

    func testInspector_negativeControl_notesBranchFlipsTree() throws {
        let withoutNotes = try { () -> String in
            let e = entry()
            let m = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            return try ViewSnapshotHost.snapshotText(of: inspector(m, entry: m.state.processEntries.first ?? e))
        }()
        let withNotes = try { () -> String in
            let e = entry(notes: "left mid-refactor")
            let m = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            return try ViewSnapshotHost.snapshotText(of: inspector(m, entry: m.state.processEntries.first ?? e))
        }()
        XCTAssertNotEqual(withoutNotes, withNotes, "the notes branch must drive the tree")
        XCTAssertFalse(withoutNotes.contains("left mid-refactor"), "no notes: no notes text:\n\(withoutNotes)")
        XCTAssertTrue(withNotes.contains("left mid-refactor"), "notes: the notes text renders:\n\(withNotes)")
    }

    /// The `if model.transcriptTail(for:) != nil` Transcript button is the inspector's
    /// data-driven render branch — adding a real transcript flips the tree.
    func testInspector_negativeControl_transcriptButtonBranchFlipsTree() throws {
        let withoutTranscript = try { () -> String in
            let e = entry()
            let m = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            return try ViewSnapshotHost.snapshotText(of: inspector(m, entry: m.state.processEntries.first ?? e))
        }()
        let withTranscript = try { () -> String in
            let root = tmpRoot()
            let e = entry()
            let (run, _) = try writeTranscript(under: root, text: "agent output\n")
            let m = try makeVM(state: state(entry: e, runs: [run]), tmpRoot: root)
            return try ViewSnapshotHost.snapshotText(of: inspector(m, entry: m.state.processEntries.first ?? e))
        }()
        XCTAssertNotEqual(withoutTranscript, withTranscript, "the transcript-tail branch must drive the tree")
        XCTAssertFalse(withoutTranscript.contains(#"text="Transcript""#), "no transcript: no Transcript button:\n\(withoutTranscript)")
        XCTAssertTrue(withTranscript.contains(#"text="Transcript""#), "transcript: the Transcript button renders:\n\(withTranscript)")
    }

    // MARK: - SessionTitleStrip

    private func titleStrip(_ model: WorkbenchViewModel, entry: ProcessEntry) -> SessionTitleStrip {
        SessionTitleStrip(entry: entry, model: model, showsInspector: .constant(true))
    }

    func testTitleStrip_active_showsOverflowControls() throws {
        let e = entry()
        let model = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
        let loaded = model.state.processEntries.first ?? e
        XCTAssertFalse(loaded.isArchived, "provenance: not archived → the RunningSessionHeaderControls overflow")
        try assertViewSnapshot(of: titleStrip(model, entry: loaded), named: "SessionTitleStrip.active")
    }

    func testTitleStrip_archived_showsRestore() throws {
        let e = entry(isArchived: true)
        let model = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
        let loaded = model.state.processEntries.first ?? e
        XCTAssertTrue(loaded.isArchived, "provenance: archived → the Archived label + Restore button arm")
        try assertViewSnapshot(of: titleStrip(model, entry: loaded), named: "SessionTitleStrip.archived")
    }

    /// `entry.isArchived` flips the title-strip's trailing controls (Archived/Restore ↔
    /// the RunningSessionHeaderControls overflow) — a real entry-driven branch in a captured node.
    func testTitleStrip_negativeControl_archivedFlipsControls() throws {
        let active = try { () -> String in
            let e = entry()
            let m = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            return try ViewSnapshotHost.snapshotText(of: titleStrip(m, entry: m.state.processEntries.first ?? e))
        }()
        let archived = try { () -> String in
            let e = entry(isArchived: true)
            let m = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            return try ViewSnapshotHost.snapshotText(of: titleStrip(m, entry: m.state.processEntries.first ?? e))
        }()
        XCTAssertNotEqual(active, archived, "the archived flag must flip the title-strip controls")
        XCTAssertTrue(archived.contains(#"text="Archived""#), "archived: the Archived label:\n\(archived)")
        XCTAssertTrue(archived.contains(#"text="Restore""#), "archived: the Restore button:\n\(archived)")
        XCTAssertTrue(active.contains(#"text="More""#), "active: the overflow More menu:\n\(active)")
        XCTAssertFalse(active.contains(#"text="Archived""#), "active: no Archived label:\n\(active)")
    }

    func testTitleStrip_pathLeakDefense_noMachinePathInTree() throws {
        for archived in [false, true] {
            let e = entry(isArchived: archived)
            let m = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            let tree = try ViewSnapshotHost.snapshotText(of: titleStrip(m, entry: m.state.processEntries.first ?? e))
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ leak:\n\(tree)")
        }
    }

    // MARK: - SessionTranscriptSheet

    private func transcriptSheet(_ model: WorkbenchViewModel, entry: ProcessEntry) -> SessionTranscriptSheet {
        SessionTranscriptSheet(entry: entry, model: model)
    }

    func testTranscriptSheet_empty_noTranscript() throws {
        let e = entry()
        let model = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
        let loaded = model.state.processEntries.first ?? e
        XCTAssertNil(model.transcriptTail(for: loaded), "provenance: no run → the empty 'No transcript captured yet.' arm")
        try assertViewSnapshot(of: transcriptSheet(model, entry: loaded), named: "SessionTranscriptSheet.empty")
    }

    func testTranscriptSheet_withTranscript() throws {
        let root = tmpRoot()
        let e = entry()
        let (run, _) = try writeTranscript(under: root, text: "the transcript body\n")
        let model = try makeVM(state: state(entry: e, runs: [run]), tmpRoot: root)
        let loaded = model.state.processEntries.first ?? e
        XCTAssertNotNil(model.transcriptTail(for: loaded), "provenance: a real transcript → the TranscriptHistoryView arm")
        try assertViewSnapshot(of: transcriptSheet(model, entry: loaded), named: "SessionTranscriptSheet.withTranscript")
    }

    /// The `if let tail = model.transcriptTail(for:)` branch flips the sheet's body
    /// (TranscriptHistoryView ↔ the empty-state Text).
    func testTranscriptSheet_negativeControl_tailBranchFlipsTree() throws {
        let empty = try { () -> String in
            let e = entry()
            let m = try makeVM(state: state(entry: e), tmpRoot: tmpRoot())
            return try ViewSnapshotHost.snapshotText(of: transcriptSheet(m, entry: m.state.processEntries.first ?? e))
        }()
        let withTail = try { () -> String in
            let root = tmpRoot()
            let e = entry()
            let (run, _) = try writeTranscript(under: root, text: "the transcript body\n")
            let m = try makeVM(state: state(entry: e, runs: [run]), tmpRoot: root)
            return try ViewSnapshotHost.snapshotText(of: transcriptSheet(m, entry: m.state.processEntries.first ?? e))
        }()
        XCTAssertNotEqual(empty, withTail, "the transcript-tail branch must flip the sheet body")
        XCTAssertTrue(empty.contains("No transcript captured yet."), "empty: the no-transcript copy:\n\(empty)")
        XCTAssertTrue(withTail.contains("the transcript body"), "with tail: the transcript renders:\n\(withTail)")
        XCTAssertFalse(withTail.contains("No transcript captured yet."), "with tail: not the empty copy:\n\(withTail)")
    }

    func testTranscriptSheet_pathLeakDefense_noMachinePathInTree() throws {
        // Even the transcript-present arm (which renders TranscriptHistoryView →
        // Text(tail.path)) must not leak — the run's transcriptPath is a fixed /tmp file.
        let root = tmpRoot()
        let e = entry()
        let (run, path) = try writeTranscript(under: root, text: "body\n")
        let m = try makeVM(state: state(entry: e, runs: [run]), tmpRoot: root)
        let tree = try ViewSnapshotHost.snapshotText(of: transcriptSheet(m, entry: m.state.processEntries.first ?? e))
        XCTAssertFalse(tree.contains("/Users/"), "no /Users/ leak (the run transcriptPath is /tmp):\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-UUID leak — the path is a fixed /tmp literal:\n\(tree)")
        XCTAssertTrue(tree.contains(Self.fixedTranscriptPath),
                      "the fixed transcript path renders verbatim (vector #2 — TranscriptHistoryView Text(tail.path)):\n\(tree)")
        XCTAssertEqual(path, Self.fixedTranscriptPath, "sanity: the fixture path is the fixed /tmp literal")
    }

    // MARK: - Determinism (P3)

    func testC9_1_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("inspector.basic", {
                let e = self.entry()
                let m = try self.makeVM(state: self.state(entry: e), tmpRoot: self.tmpRoot())
                return try ViewSnapshotHost.snapshotText(of: self.inspector(m, entry: m.state.processEntries.first ?? e))
            }),
            ("titleStrip.archived", {
                let e = self.entry(isArchived: true)
                let m = try self.makeVM(state: self.state(entry: e), tmpRoot: self.tmpRoot())
                return try ViewSnapshotHost.snapshotText(of: self.titleStrip(m, entry: m.state.processEntries.first ?? e))
            }),
            ("transcriptSheet.empty", {
                let e = self.entry()
                let m = try self.makeVM(state: self.state(entry: e), tmpRoot: self.tmpRoot())
                return try ViewSnapshotHost.snapshotText(of: self.transcriptSheet(m, entry: m.state.processEntries.first ?? e))
            })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Transcript-file fixture helper

    /// Write a REAL transcript file at a FIXED, DETERMINISTIC `/tmp` path and return the
    /// `ProcessRun` whose `transcriptPath` points at it (so `transcriptTail(for:)` reads it off
    /// disk). The path is rendered VERBATIM by `TranscriptHistoryView` (`Text(tail.path)`,
    /// path-leak vector #2), so it MUST be a fixed string with NO `/Users/`, NO `/var/folders/`
    /// temp-UUID, no machine component (P3 determinism). We use `/tmp/ouro-c9` (a fixed literal,
    /// NOT the VM's random `NSTemporaryDirectory()` root) so the committed reference is
    /// byte-identical across runs and machines. The file is rewritten each call (hermetic).
    private static let fixedTranscriptPath = "/tmp/ouro-c9/run.log"

    private func writeTranscript(under _: URL, text: String) throws -> (run: ProcessRun, path: String) {
        let file = URL(fileURLWithPath: Self.fixedTranscriptPath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: file)
        let run = ProcessRun(
            id: UUID(uuidString: "C9000001-0000-0000-0000-0000000000F1")!,
            entryId: Self.entryId, status: .exited, startedAt: Self.runEpoch,
            transcriptPath: file.path
        )
        return (run, file.path)
    }
}
#endif
