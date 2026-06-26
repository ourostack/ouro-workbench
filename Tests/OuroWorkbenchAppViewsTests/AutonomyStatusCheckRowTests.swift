#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-4 — `AutonomyStatusCheckRow` (`:4773`) enumerated state-set (STANDALONE).
///
/// The row takes its `check: AutonomyReadinessCheck`, `model`, `loginItem`, and `isDegraded`
/// directly, so it is snapshotted STANDALONE with a constructed check. Its data-driven branches:
///   - the leading `indicator` glyph: `if check.state == .blocker, remediation != nil,
///     !isDegraded → "exclamationmark.circle.fill"` (soft orange) else `check.state.systemImage`
///     (`checkmark.circle.fill` / `exclamationmark.triangle.fill` / `xmark.octagon.fill`).
///   - the `if let remediation` trailing repair button (`Label(actionLabel, systemImage:)`).
/// Captured nodes: the indicator `Image`, the `check.label` + `check.detail` `Text`s, and the
/// repair button's `Label` (`Text` + `Image`) when a remediation is live.
///
/// **Login-item determinism (P3).** `loginItem` ONLY affects the captured tree for a check
/// whose `id == "open-at-login"` (its remediation kind is `.openAtLogin`, gated by
/// `loginItemActionable`). EVERY check covered here has a non-`open-at-login` id, so the
/// live, non-injectable `LoginItemController()` cannot leak into the snapshot — proven by the
/// determinism test below (two FRESH controllers → byte-identical trees). The `open-at-login`
/// row is deliberately NOT covered standalone (it would read the live machine login state).
///
/// **Provenance (P2).** `AutonomyReadinessCheck` is a `public` Core value type — constructing it
/// with deterministic inputs IS the real seam (the same type `AutonomyReadinessBuilder.build`
/// emits). `remediation` is decided by the REAL pure `AutonomyRemediationMapper` fed
/// `model.untrustedAutonomyAgentEntries`/`recoverableEntries`/etc. (all empty for the hermetic
/// `makeVM` VM, except where the fixture provenance-builds an untrusted terminal). `isDegraded`
/// is the App-supplied genuinely-degraded flag.
///
/// **Enumerated state-set (the indicator + remediation branches):**
///   - `ok`              — `.ok` check → `checkmark.circle.fill`, no repair button.
///   - `warning`         — `.warning` check → `exclamationmark.triangle.fill`, no repair button.
///   - `blockerSoft`     — `.blocker` with a LIVE remediation, not degraded → soft orange
///                          `exclamationmark.circle.fill` + the "Trust" repair button.
///   - `blockerDegraded` — same `.blocker` but `isDegraded == true` → the loud
///                          `xmark.octagon.fill` octagon, no soft glyph (still has the button).
@MainActor
final class AutonomyStatusCheckRowTests: XCTestCase {

    private func makeVM(untrustedTerminal: Bool) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-ascr-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        if untrustedTerminal {
            // A real untrusted terminal-agent entry → `untrustedAutonomyAgentEntries` non-empty
            // → `hasUntrustedTerminals` → the `.trustTerminals` remediation has a live button.
            let entry = ProcessEntry(
                id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!,
                projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                name: "agent-tab",
                kind: .terminalAgent,
                executable: "/usr/bin/claude",
                workingDirectory: "/tmp/c3ascr",
                trust: .untrusted
            )
            state.processEntries = [entry]
        }
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func check(id: String, label: String, detail: String, state: AutonomyReadinessCheckState) -> AutonomyReadinessCheck {
        AutonomyReadinessCheck(id: id, label: label, detail: detail, state: state)
    }

    private func row(
        check: AutonomyReadinessCheck,
        isDegraded: Bool = false,
        untrustedTerminal: Bool = false
    ) throws -> AutonomyStatusCheckRow {
        AutonomyStatusCheckRow(
            check: check,
            model: try makeVM(untrustedTerminal: untrustedTerminal),
            loginItem: LoginItemController(),
            isDegraded: isDegraded
        )
    }

    // MARK: - Enumerated state-set

    func testRow_ok() throws {
        let view = try row(check: check(id: "boss-watch", label: "Boss watch",
                                        detail: "Automatic watch mode is running.", state: .ok))
        try assertViewSnapshot(of: view, named: "AutonomyStatusCheckRow.ok")
    }

    func testRow_warning() throws {
        let view = try row(check: check(id: "boss-watch", label: "Boss watch",
                                        detail: "Watch mode is paused; manual boss asks still work.", state: .warning))
        try assertViewSnapshot(of: view, named: "AutonomyStatusCheckRow.warning")
    }

    func testRow_blockerSoft() throws {
        // A `.blocker` terminal-trust check WITH a live Trust button (untrusted terminal present),
        // not degraded → the soft orange `exclamationmark.circle.fill` + the "Trust" repair button.
        let c = check(id: "terminal-trust", label: "Agent terminals", detail: "agent-tab is not trusted.", state: .blocker)
        let view = try row(check: c, isDegraded: false, untrustedTerminal: true)
        XCTAssertFalse(view.model.untrustedAutonomyAgentEntries.isEmpty,
                       "provenance: a real untrusted terminal drives the live Trust button")
        try assertViewSnapshot(of: view, named: "AutonomyStatusCheckRow.blockerSoft")
    }

    func testRow_blockerDegraded() throws {
        // Same blocker, but the App marks it genuinely degraded → the loud octagon, not the soft glyph.
        let c = check(id: "terminal-trust", label: "Agent terminals", detail: "agent-tab is not trusted.", state: .blocker)
        let view = try row(check: c, isDegraded: true, untrustedTerminal: true)
        try assertViewSnapshot(of: view, named: "AutonomyStatusCheckRow.blockerDegraded")
    }

    // MARK: - Determinism (P3) — login-item independence + byte-identical

    /// The covered rows are login-item-INDEPENDENT: two FRESH (live-state) `LoginItemController()`
    /// instances render byte-identical trees, so the non-injectable login state never leaks.
    func testRow_determinism_loginItemIndependentAndNoLeak() throws {
        let specs: [(String, AutonomyReadinessCheck, Bool, Bool)] = [
            ("ok", check(id: "boss-watch", label: "Boss watch", detail: "Automatic watch mode is running.", state: .ok), false, false),
            ("blockerSoft", check(id: "terminal-trust", label: "Agent terminals", detail: "agent-tab is not trusted.", state: .blocker), false, true)
        ]
        for (name, c, degraded, untrusted) in specs {
            let a = try ViewSnapshotHost.snapshotText(of: try row(check: c, isDegraded: degraded, untrustedTerminal: untrusted))
            let b = try ViewSnapshotHost.snapshotText(of: try row(check: c, isDegraded: degraded, untrustedTerminal: untrusted))
            XCTAssertEqual(a, b, "\(name) must be byte-identical across fresh login controllers")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The indicator branch flips the captured glyph: an `.ok` check renders the checkmark, a
    /// `.warning` the triangle, a soft blocker the orange circle, and a degraded blocker the
    /// loud octagon — and a live remediation adds the "Trust" repair button a green row omits.
    func testRow_negativeControl_indicatorAndRemediationFlipTree() throws {
        let ok = try ViewSnapshotHost.snapshotText(of: try row(check: check(id: "boss-watch", label: "Boss watch", detail: "Automatic watch mode is running.", state: .ok)))
        let warning = try ViewSnapshotHost.snapshotText(of: try row(check: check(id: "boss-watch", label: "Boss watch", detail: "Watch mode is paused; manual boss asks still work.", state: .warning)))
        let soft = try ViewSnapshotHost.snapshotText(of: try row(check: check(id: "terminal-trust", label: "Agent terminals", detail: "agent-tab is not trusted.", state: .blocker), isDegraded: false, untrustedTerminal: true))
        let degraded = try ViewSnapshotHost.snapshotText(of: try row(check: check(id: "terminal-trust", label: "Agent terminals", detail: "agent-tab is not trusted.", state: .blocker), isDegraded: true, untrustedTerminal: true))

        XCTAssertTrue(ok.contains("checkmark.circle.fill"), "ok: the green check:\n\(ok)")
        XCTAssertTrue(warning.contains("exclamationmark.triangle.fill"), "warning: the triangle:\n\(warning)")
        XCTAssertNotEqual(ok, warning, "the check state must flip the indicator")

        // The soft blocker uses the orange circle + the live Trust button; the degraded one the octagon.
        XCTAssertTrue(soft.contains("exclamationmark.circle.fill"), "soft blocker: the orange circle:\n\(soft)")
        XCTAssertTrue(soft.contains("Trust"), "soft blocker: the live Trust repair button:\n\(soft)")
        XCTAssertTrue(degraded.contains("xmark.octagon.fill"), "degraded blocker: the loud octagon:\n\(degraded)")
        XCTAssertNotEqual(soft, degraded, "the isDegraded flag must flip the indicator")

        // A green row carries no repair button.
        XCTAssertFalse(ok.contains("Trust"), "ok: no repair button:\n\(ok)")
    }
}
#endif
