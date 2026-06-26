#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `EditTerminalSessionSheet` (22 uncovered regions: the whole view body
/// + the two `init` arms were never driven by the campaign).
///
/// The sheet's `init` seeds its `@State` from `model.customSessionDraft(for:)`
/// when the entry IS a custom session (`.shell`/`.terminalAgent`), else it falls
/// back to a hand-built `CustomTerminalSessionDraft` from the entry's own fields
/// (`.command`/`.ouroBoss` — non-custom kinds). BOTH arms are reachable through
/// the real seam by varying the entry's `kind`, so both are DRIVEN here, each
/// asserting the captured `TextField` bound values (Name/Command/Working-Directory)
/// that the seeded draft flows into.
///
/// **Path-leak (the cluster's MEDIUM hazard) — pinned.** `workingDirectory` is
/// seeded from `entry.workingDirectory`; a FIXED relative `/tmp/u4` keeps `/Users/`
/// out of the captured tree, defended by `!contains("/Users/")`.
///
/// **Genuinely-unreachable (recorded carve candidates, NOT driven):** the button
/// ACTION closures (`save()`, `chooseWorkingDirectory()` → `NSOpenPanel.runModal()`)
/// are never invoked by a render pass — ViewInspector descends `label:` but not the
/// action — so their bodies stay `^0`. They are in-closure-only (no render seam can
/// execute a button tap synchronously). Recorded for Unit 3.
@MainActor
final class EditTerminalSessionSheetTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B4ED7E51-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B4ED7E51-0000-0000-0000-0000000000A1")!

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4editterm-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            selectedProjectId: Self.projectId,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")]))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A FIXED entry whose kind decides which `init` arm seeds the draft.
    private func entry(
        kind: ProcessKind,
        name: String = "build",
        executable: String = "/bin/zsh",
        arguments: [String] = ["-lc", "make all"],
        notes: String? = "ship it"
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name,
            kind: kind, executable: executable, arguments: arguments,
            workingDirectory: "/tmp/u4", trust: .trusted, autoResume: true,
            notes: notes)
    }

    private func sheet(for entry: ProcessEntry) throws -> EditTerminalSessionSheet {
        EditTerminalSessionSheet(model: try makeVM(), entry: entry)
    }

    // MARK: - init arm A: custom-session entry → seeded from customSessionDraft

    func testSheet_customSessionEntry_seedsFromDraft() throws {
        // A `.shell` entry IS a custom session, so the init reads
        // `model.customSessionDraft(for: entry)` (the non-fallback arm). The
        // `/bin/zsh -lc make all` form round-trips to command "make all".
        let view = try sheet(for: entry(kind: .shell))
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Edit Terminal""#), "the sheet title:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="build""#),
                      "the Name field seeds from the draft:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="make all""#),
                      "the Command field round-trips `-lc <cmd>`:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4""#),
                      "the Working Directory field seeds from entry.workingDirectory:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Save""#) && tree.contains(#"text="Cancel""#),
                      "the static form buttons render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "EditTerminalSessionSheet.customDraft")
    }

    // MARK: - init arm B: non-custom entry → hand-built fallback draft

    func testSheet_nonCustomEntry_usesFallbackDraft() throws {
        // A `.command` entry is NOT a custom session, so `customSessionDraft(for:)`
        // returns nil and the init takes the `?? CustomTerminalSessionDraft(...)`
        // fallback arm (command defaults to "" there).
        let view = try sheet(for: entry(kind: .command, name: "runner", notes: nil))
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"kind=editable text="runner""#),
                      "the fallback draft seeds Name from entry.name:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4""#),
                      "the fallback seeds Working Directory from entry.workingDirectory:\n\(tree)")
        try assertViewSnapshot(of: view, named: "EditTerminalSessionSheet.fallbackDraft")
    }

    // MARK: - Path-leak defense (P3)

    func testSheet_noMachinePathLeak() throws {
        for kind in [ProcessKind.shell, .command] {
            let tree = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: kind)))
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
        }
    }

    func testSheet_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell)))
        let b = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell)))
        XCTAssertEqual(a, b, "the sheet must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The draft-seeded Name/Command fields are the data-driven discriminators: a
    /// different entry name flips the captured Name TextField value.
    func testSheet_negativeControl_nameFieldFlipsWithEntry() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell, name: "build")))
        let b = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell, name: "deploy")))
        XCTAssertNotEqual(a, b, "the Name field must flip with the entry name")
        XCTAssertTrue(a.contains(#"kind=editable text="build""#))
        XCTAssertTrue(b.contains(#"kind=editable text="deploy""#))
    }
}
#endif
