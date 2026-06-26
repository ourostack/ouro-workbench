#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C0 SU-4 — the **fixed-timestamp clock** recipe (edge-case playbook #4).
/// `BossWatchStatusView` renders the change-row timestamp via the shared
/// `Date.workbenchTimeText(date:time:timeZone:)` seam — an absolute `Date` formatted to
/// a STRING at body-evaluation time. The string's zone is an **injected** `TimeZone`:
/// production defaults to `.autoupdatingCurrent` (operator-local, unchanged), the test
/// injects `.gmt`. **The fixture also pins the clock:** a single CANONICAL FIXED `Date`
/// epoch constant fed to the change-summary producer, so every formatted string is
/// byte-identical. The injected `.gmt` zone makes the `.formatted(...)` render
/// deterministic regardless of the CI runner's zone (P3) — independent of any global
/// host TimeZone pin or cross-test ordering (the C0 root cause: that read-time process
/// pin was not reliably effective for a body-evaluated `.formatted()` under the full
/// CI suite).
///
/// **Provenance (P2).** The change summaries are produced by the REAL Core producer
/// `WorkspaceChangeSummarizer.summarize(previous:current:occurredAt:)` — fed two real
/// `WorkspaceState`s with a diff (a renamed session) + the FIXED `occurredAt` — then
/// assigned to `model.bossWatchChangeSummaries` (the SAME `@Published` the production
/// boss-watch ingest path sets — direct injection IS the real seam here). The model is
/// built via the `makeVM` dual-injection store seam (AN-001 temp `agentBundlesURL`).
///
/// **Enumerated state-set (the view's data-driven branches):**
///   - `enabledNoChanges` — `bossWatchIsEnabled == true`, empty change list →
///       "eye.fill" glyph + the "watching" status line, no change rows.
///   - `disabledNoChanges` — `bossWatchIsEnabled == false` → "eye" glyph + "paused".
///   - `withChanges` — a non-empty change list → the `ForEach` rows render, each with the
///       FIXED-timestamp `Text` + the change title/detail.
@MainActor
final class BossWatchStatusViewClockTests: XCTestCase {

    /// A single canonical fixed epoch — 2026-01-02 03:04:05 UTC. The view formats it under
    /// the injected `.gmt` zone + `en_GB` locale (see `view(enabled:summaries:)`), so
    /// `workbenchTimeText(date:.omitted, time:.standard, timeZone:.gmt, locale: en_GB)`
    /// renders `3:04:05` byte-identically on any runner. (Captured in the recorded ref.)
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)

    /// The locale the view formats the timestamp under (injected). `en_GB` is chosen as
    /// the stable, runner-independent CLOCK locale: under it `.standard` time renders a
    /// clean ASCII-only `3:04:05` (24-hour, `:`-separated, NO AM/PM and — critically — NO
    /// narrow-no-break-space). `en_US_POSIX` would render `3:04:05\u{202F}AM`, whose
    /// U+202F separator is an ICU-version landmine across runners; `en_GB` sidesteps it
    /// entirely (verified byte-stable across forced env locales). The recorded ref
    /// captures exactly `3:04:05`.
    private static let clockLocale = Locale(identifier: "en_GB")

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c0clock-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private static let entryId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    /// Produce a change summary through the REAL producer: a session-rename diff with the
    /// FIXED `occurredAt`.
    private func renameSummaries() -> [WorkspaceChangeSummary] {
        func entry(named name: String) -> ProcessEntry {
            ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: name,
                         kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4")
        }
        let previous = WorkspaceState(processEntries: [entry(named: "old-name")])
        let current = WorkspaceState(processEntries: [entry(named: "new-name")])
        return WorkspaceChangeSummarizer().summarize(
            previous: previous, current: current, occurredAt: Self.fixedDate)
    }

    private func view(enabled: Bool, summaries: [WorkspaceChangeSummary]) throws -> BossWatchStatusView {
        let model = try makeVM()
        model.bossWatchIsEnabled = enabled
        model.bossWatchLastError = nil
        model.bossWatchLastRunAt = nil      // → status line "watching"/"paused" (clock-free)
        model.bossWatchChangeSummaries = summaries
        // Inject `.gmt` + `en_GB` so the change-row timestamp renders byte-identically
        // regardless of the CI runner's TimeZone AND locale (C0 recipe; `.standard` time
        // is sharply locale-sensitive — `en_US`→`3:04:05\u{202F}AM`, a 24-h
        // `.current`→`03:04:05`, `en_GB`→a clean ASCII `3:04:05`). Production defaults to
        // `.autoupdatingCurrent` for both (operator-local, unchanged) — the explicit seam
        // is what makes the snapshot deterministic, independent of any global host pin,
        // test ordering, runner zone, or runner locale.
        return BossWatchStatusView(model: model, timeZone: .gmt, locale: Self.clockLocale)
    }

    // MARK: - Enumerated state-set

    func testWatch_enabledNoChanges() throws {
        let view = try view(enabled: true, summaries: [])
        XCTAssertTrue(view.model.bossWatchChangeSummaries.isEmpty, "provenance: no change rows")
        XCTAssertEqual(view.model.bossWatchStatusLine, "watching", "provenance: enabled, no run → watching")
        try assertViewSnapshot(of: view, named: "BossWatchStatusView.enabledNoChanges")
    }

    func testWatch_disabledNoChanges() throws {
        let view = try view(enabled: false, summaries: [])
        XCTAssertEqual(view.model.bossWatchStatusLine, "paused", "provenance: disabled → paused")
        try assertViewSnapshot(of: view, named: "BossWatchStatusView.disabledNoChanges")
    }

    func testWatch_withChanges() throws {
        let summaries = renameSummaries()
        let view = try view(enabled: true, summaries: summaries)
        let change = try XCTUnwrap(summaries.first)
        XCTAssertEqual(change.title, "Session renamed", "provenance: real producer title")
        XCTAssertEqual(change.detail, "old-name is now new-name", "provenance: real producer detail")
        XCTAssertEqual(change.occurredAt, Self.fixedDate, "provenance: fixed timestamp")
        try assertViewSnapshot(of: view, named: "BossWatchStatusView.withChanges")
    }

    // MARK: - U5 B8 — drive the production timeZone/locale DEFAULT-argument autoclosures

    /// U5 B8 — the `timeZone`/`locale` default-argument autoclosures (`:7992`/`:7993` —
    /// `var timeZone: TimeZone = .autoupdatingCurrent` / `var locale: Locale = .autoupdatingCurrent`).
    /// Every other test injects explicit `.gmt`/`en_GB`, so the PRODUCTION defaults (the autoclosures
    /// the real call site `BossWatchStatusView(model:)` at `:5347` evaluates) were never executed. Here
    /// we construct the view EXACTLY as production does — OMITTING both arguments — so the
    /// `.autoupdatingCurrent` default autoclosures run. With NO change summaries the body renders no
    /// timestamp `Text` (the `ForEach(...workbenchTimeText...)` block is empty), so the captured tree is
    /// TZ/locale-INDEPENDENT and deterministic. ASSERT the status line + label render.
    func testWatch_productionDefaults_noTimeZoneOrLocaleArg() throws {
        let model = try makeVM()
        model.bossWatchIsEnabled = true
        model.bossWatchLastError = nil
        model.bossWatchLastRunAt = nil
        model.bossWatchChangeSummaries = []   // no rows → no timestamp → deterministic
        XCTAssertEqual(model.bossWatchStatusLine, "watching", "provenance: enabled, no run → watching")
        // Construct as production does — defaults for timeZone + locale (drives :7992/:7993).
        let view = BossWatchStatusView(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="watching""#),
                      "the prod-default view renders the status line:\n\(tree)")
        XCTAssertTrue(tree.contains("Boss Watch"), "the Boss Watch label renders:\n\(tree)")
        XCTAssertTrue(tree.contains("eye.fill"), "enabled → the filled eye glyph:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }

    // MARK: - Clock determinism (P3 — the recipe's whole point)

    /// The change-row timestamp is a baked-at-construction `Date.formatted`, so determinism
    /// depends ENTIRELY on the fixed `occurredAt` + the host's UTC pin. Assert it: the tree
    /// is byte-identical twice and carries no live-clock drift / machine path.
    func testWatch_clockDeterminism_byteIdenticalTwice() throws {
        let summaries = renameSummaries()
        let a = try ViewSnapshotHost.snapshotText(of: try view(enabled: true, summaries: summaries))
        let b = try ViewSnapshotHost.snapshotText(of: try view(enabled: true, summaries: summaries))
        XCTAssertEqual(a, b, "the fixed-timestamp change row must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The enabled flag flips the eye glyph + status line, and a non-empty change list adds
    /// the `ForEach` rows — both real model-driven branches.
    func testWatch_negativeControl_enabledFlagAndChangesFlipTree() throws {
        let enabled = try ViewSnapshotHost.snapshotText(of: try view(enabled: true, summaries: []))
        let disabled = try ViewSnapshotHost.snapshotText(of: try view(enabled: false, summaries: []))
        let withRows = try ViewSnapshotHost.snapshotText(of: try view(enabled: true, summaries: renameSummaries()))

        XCTAssertNotEqual(enabled, disabled, "the bossWatchIsEnabled flag must drive the tree")
        XCTAssertTrue(enabled.contains("eye.fill"), "enabled: filled eye:\n\(enabled)")
        XCTAssertTrue(enabled.contains("watching"), "enabled: watching:\n\(enabled)")
        XCTAssertTrue(disabled.contains("paused"), "disabled: paused:\n\(disabled)")

        XCTAssertNotEqual(enabled, withRows, "a non-empty change list must add the ForEach rows")
        XCTAssertTrue(withRows.contains("Session renamed"), "withRows: the change title renders:\n\(withRows)")
    }
}
#endif
