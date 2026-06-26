#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `SessionTitleStrip` (`:9067`) close-out. `SessionInspectorAndTitleStripTests` drove
/// the active/archived RENDER arms (via `showsInspector: .constant(true)`, a human-owned shell)
/// but carved: the inspector-toggle ACTION, the live-attention Label + its switch, the cliName
/// pill, the archived Restore ACTION, and the statusDot switch arms. The 13 uncovered:
///   - `L9074:20` — the inspector-toggle Button ACTION `showsInspector.toggle()`;
///   - `L9097:56`/`L9105:14` — the `if let attention = liveAttentionToAnnounce { Label(…) }` arm;
///   - `L9107:56`/`L9115:14` — the `if let cliName` pill;
///   - `L9119:16`/`L9124:24` — the `if entry.isArchived { Archived label + Restore ACTION }`;
///   - `L9164:89`/`L9165:16`/`L9166:9` — the `liveAttentionToAnnounce` switch arms;
///   - `L9168:9`/`L9176:9`/`L9180:9` — the `statusDot` switch arms.
///
/// DRIVEN: the toggle + Restore ACTIONS via `.tap()`; the live-attention Label + the
/// liveAttentionToAnnounce switch by a LIVE session (no-PTY controller) with each non-active
/// `AttentionState`; the statusDot arms by the four DotState seams (active / recoverable /
/// inactive / archived); the cliName pill by a `.terminalAgent` entry.
@MainActor
final class SessionTitleStripDriveTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B5717153-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B5717153-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "B5717153-0000-0000-0000-0000000000B1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5title-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func entry(
        kind: ProcessKind = .shell, executable: String = "/bin/zsh",
        isArchived: Bool = false, attention: AttentionState = .idle, autoResume: Bool = false
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build",
            kind: kind, executable: executable, workingDirectory: "/tmp/u5",
            trust: .trusted, autoResume: autoResume, isArchived: isArchived, attention: attention)
    }

    private func run(_ status: ProcessStatus) -> ProcessRun {
        ProcessRun(id: UUID(uuidString: "B5717153-0000-0000-0000-0000000000F1")!,
                   entryId: Self.entryId, status: status, startedAt: Self.runEpoch)
    }

    private func state(entry: ProcessEntry, runs: [ProcessRun] = []) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u5")],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.entryId])],
            processRuns: runs)
    }

    private func loaded(_ m: WorkbenchViewModel, fallback: ProcessEntry) -> ProcessEntry {
        m.state.processEntries.first ?? fallback
    }

    private func session(for entry: ProcessEntry) throws -> TerminalSessionController {
        let plan = TerminalCommandPlan(entryId: entry.id, executable: "/bin/zsh", arguments: [],
                                       workingDirectory: "/tmp/u5", reason: "test")
        return try TerminalSessionController(plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    private func strip(_ m: WorkbenchViewModel, entry e: ProcessEntry,
                       showsInspector: Binding<Bool> = .constant(false)) -> SessionTitleStrip {
        SessionTitleStrip(entry: e, model: m, showsInspector: showsInspector)
    }

    // MARK: - L9074 — drive the inspector-toggle Button ACTION

    func testStrip_toggleTap_flipsShowsInspector() throws {
        let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
        let box = BindingBox(false)
        let view = strip(m, entry: le, showsInspector: box.binding)
        // INVOCATION: the disclosure chevron is the first plain button → tap → showsInspector.toggle().
        try view.inspect().find(ViewType.Button.self, where: { b in
            (try? b.labelView().image().actualImage().name()) == "chevron.right"
        }).tap()
        XCTAssertTrue(box.value, "the toggle tap must flip showsInspector false→true")
    }

    // MARK: - L9097/9105 + L9164/9165 — the live-attention label + switch

    func testStrip_liveWaitingOnHuman_showsAttentionLabel() throws {
        let e = entry(attention: .waitingOnHuman)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        m.activeSessions[le.id] = try session(for: le)
        let tree = try ViewSnapshotHost.snapshotText(of: strip(m, entry: le))
        XCTAssertTrue(tree.contains(#"label="Attention:"#), "the live-attention label (L9097/9105):\n\(tree)")
        try assertViewSnapshot(of: strip(m, entry: le), named: "SessionTitleStrip.liveWaiting")
    }

    func testStrip_liveAttentionSwitch_allArms() throws {
        // waitingOnHuman / blocked / needsBossReview → liveAttentionToAnnounce returns the state
        // (L9165); active / idle → nil (L9168). All five drive the switch.
        for att in [AttentionState.waitingOnHuman, .blocked, .needsBossReview, .active, .idle] {
            let e = entry(attention: att)
            let m = try makeVM(state: state(entry: e))
            let le = loaded(m, fallback: e)
            m.activeSessions[le.id] = try session(for: le)
            _ = try ViewSnapshotHost.snapshotText(of: strip(m, entry: le))
        }
    }

    // MARK: - L9168/9176/9180 — the statusDot switch arms (all four DotState seams)

    func testStrip_statusDot_allFourStates() throws {
        // .attention → live session; .recoverable → inactive+canRecover; .inactive → inactive;
        // .archived → archived. Snapshot each so the four statusDot arms all execute.
        // archived
        let archived = entry(isArchived: true)
        let mA = try makeVM(state: state(entry: archived))
        _ = try ViewSnapshotHost.snapshotText(of: strip(mA, entry: loaded(mA, fallback: archived)))
        // recoverable (inactive + canRecover)
        let recoverable = entry(autoResume: true)
        let mR = try makeVM(state: state(entry: recoverable, runs: [run(.needsRecovery)]))
        let leR = loaded(mR, fallback: recoverable)
        XCTAssertTrue(mR.canRecover(leR), "provenance: recoverable → the .recoverable dot")
        _ = try ViewSnapshotHost.snapshotText(of: strip(mR, entry: leR))
        // inactive (no run, not recoverable)
        let inactive = entry()
        let mI = try makeVM(state: state(entry: inactive))
        _ = try ViewSnapshotHost.snapshotText(of: strip(mI, entry: loaded(mI, fallback: inactive)))
        // attention (live)
        let active = entry(attention: .active)
        let mAc = try makeVM(state: state(entry: active))
        let leAc = loaded(mAc, fallback: active)
        mAc.activeSessions[leAc.id] = try session(for: leAc)
        _ = try ViewSnapshotHost.snapshotText(of: strip(mAc, entry: leAc))
    }

    // MARK: - L9107/9115 — the cliName pill

    func testStrip_cliEntry_showsCliPill() throws {
        let e = entry(kind: .terminalAgent, executable: "/usr/local/bin/claude")
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        let tree = try ViewSnapshotHost.snapshotText(of: strip(m, entry: le))
        XCTAssertTrue(tree.contains(#"text="Claude Code""#), "the cliName pill (L9107/9115):\n\(tree)")
        try assertViewSnapshot(of: strip(m, entry: le), named: "SessionTitleStrip.cliPill")
    }

    // MARK: - L9119/9124 — the archived Restore ACTION

    func testStrip_archivedRestoreTap_restoresEntry() throws {
        let e = entry(isArchived: true)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        let view = strip(m, entry: le)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Archived""#), "the Archived label (L9119):\n\(tree)")
        try view.inspect().find(button: "Restore").tap()
        XCTAssertFalse(m.state.processEntries.first?.isArchived ?? true, "Restore tap → un-archived")
    }

    // MARK: - Negative control + determinism

    func testStrip_negativeControl_liveAttentionFlipsLabel() throws {
        let waiting = try ViewSnapshotHost.snapshotText(of: { () -> SessionTitleStrip in
            let e = entry(attention: .waitingOnHuman); let m = try makeVM(state: state(entry: e))
            let le = loaded(m, fallback: e); m.activeSessions[le.id] = try session(for: le)
            return strip(m, entry: le)
        }())
        let idleActive = try ViewSnapshotHost.snapshotText(of: { () -> SessionTitleStrip in
            let e = entry(attention: .active); let m = try makeVM(state: state(entry: e))
            let le = loaded(m, fallback: e); m.activeSessions[le.id] = try session(for: le)
            return strip(m, entry: le)
        }())
        XCTAssertNotEqual(waiting, idleActive, "waitingOnHuman must surface a label the active state hides")
        XCTAssertTrue(waiting.contains(#"label="Attention:"#))
        XCTAssertFalse(idleActive.contains(#"label="Attention:"#), "active: no attention label:\n\(idleActive)")
    }

    func testStrip_deterministic_noLeak() throws {
        func make() throws -> String {
            let e = entry(kind: .terminalAgent, executable: "/usr/local/bin/claude")
            let m = try makeVM(state: state(entry: e))
            return try ViewSnapshotHost.snapshotText(of: strip(m, entry: loaded(m, fallback: e)))
        }
        let a = try make(); let b = try make()
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}

/// A reference box backing a `Binding<Bool>` so a `.tap()`-driven toggle's effect is readable.
@MainActor
private final class BindingBox {
    var value: Bool
    init(_ initial: Bool) { value = initial }
    var binding: Binding<Bool> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
#endif
