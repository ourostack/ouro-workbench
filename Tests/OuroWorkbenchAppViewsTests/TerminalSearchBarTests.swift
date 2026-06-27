#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `TerminalSearchBar` (20 uncovered regions: the whole search-bar body +
/// the conditional "No matches" arm were never driven by the campaign).
///
/// Every rendered region binds to the VM's `@Published` terminal-search state — a real
/// seam. We drive BOTH arms of the conditional "No matches" badge:
///   - default (query empty, `terminalSearchHasResult == true`) → the badge is absent;
///   - `query == "missing"`, `terminalSearchHasResult == false` → the
///     `!hasResult && !query.isEmpty` arm renders the "No matches" Text.
/// The captured `TextField` bound value tracks `terminalSearchQuery` (the data-driven
/// discriminator), and the three `TerminalSearchToggleButton`s (Aa / .* / Wˌ) + the
/// chevrons + Done render statically.
///
/// **Genuinely-unreachable (recorded carve candidates, NOT driven):** the `.onSubmit`,
/// `.onChange`, the chevron/Done/toggle button ACTION closures, and the `.onAppear`
/// focus closure are never invoked by a render pass. Recorded for Unit 3.
@MainActor
final class TerminalSearchBarTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4search-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A VM whose terminal-search state is set through its real `@Published` seam.
    private func vm(query: String, hasResult: Bool) throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.terminalSearchQuery = query
        model.terminalSearchHasResult = hasResult
        return model
    }

    private func bar(query: String, hasResult: Bool) throws -> TerminalSearchBar {
        TerminalSearchBar(model: try vm(query: query, hasResult: hasResult))
    }

    // MARK: - Arm A: default → no "No matches" badge

    func testBar_defaultState_noBadge() throws {
        let view = try bar(query: "", hasResult: true)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"image="magnifyingglass""#), "the search glyph:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="""#),
                      "the query field binds to the (empty) terminalSearchQuery:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Aa""#) && tree.contains(#"text=".*""#) && tree.contains(#"text="Wˌ""#),
                      "the three search-option toggle buttons:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Done""#), "the Done button:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="No matches""#),
                       "the default state must NOT show the No-matches badge:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TerminalSearchBar.default")
    }

    // MARK: - Arm B: query + no result → "No matches" badge renders

    func testBar_noResultWithQuery_showsBadge() throws {
        let view = try bar(query: "missing", hasResult: false)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"kind=editable text="missing""#),
                      "the query field tracks terminalSearchQuery:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="No matches""#),
                      "the !hasResult && !query.isEmpty arm renders the badge:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TerminalSearchBar.noMatches")
    }

    func testBar_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try bar(query: "missing", hasResult: false))
        let b = try ViewSnapshotHost.snapshotText(of: try bar(query: "missing", hasResult: false))
        XCTAssertEqual(a, b, "the bar must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The "No matches" badge is the data-driven conditional arm: it appears only when
    /// `!hasResult && !query.isEmpty`. The two states must differ.
    func testBar_negativeControl_badgeArmFlips() throws {
        let withBadge = try ViewSnapshotHost.snapshotText(of: try bar(query: "missing", hasResult: false))
        let noBadge = try ViewSnapshotHost.snapshotText(of: try bar(query: "", hasResult: true))
        XCTAssertNotEqual(withBadge, noBadge, "the No-matches arm must flip with the search state")
        XCTAssertTrue(withBadge.contains(#"text="No matches""#))
        XCTAssertFalse(noBadge.contains(#"text="No matches""#))
    }

    // MARK: - U5 B4-REDO — drive the event-closure regions (originally WRONGLY carved)
    //
    // ViewInspector 0.10.3 invokes action-closures, so the `.onSubmit` / `.onChange` /
    // toggle-`onChange` / chevron / Done / `.onAppear` closures the original B4 recorded
    // as "carves" are DRIVABLE. Each is invoked through the view and its `@Published`
    // side-effect asserted. The bar holds NO `@State` — every effect lands on the VM's
    // real terminal-search published state, the SAME fields the live search bar drives.

    /// Helper: a bar whose VM has NO active session, so `stepTerminalSearch` takes its
    /// `guard activeEntry, activeSession` else-arm (sets `hasResult = false`) — no live
    /// SwiftTerm needed, deterministic, no spawn.
    private func bar(_ model: WorkbenchViewModel) -> TerminalSearchBar {
        TerminalSearchBar(model: model)
    }

    // MARK: - L9021 `.onSubmit { model.stepTerminalSearch(.next) }`

    func testBar_onSubmit_stepsSearch() throws {
        let model = try makeVM()
        model.terminalSearchQuery = "needle"
        model.terminalSearchHasResult = true
        // The `.onSubmit` is on the query TextField. With no active session,
        // stepTerminalSearch hits its guard-else → terminalSearchHasResult = false.
        try bar(model).inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertFalse(model.terminalSearchHasResult,
                       "onSubmit → stepTerminalSearch(.next); no live session → hasResult false")
    }

    // MARK: - L9024/L9025/L9027 `.onChange(of: terminalSearchQuery)` — BOTH arms

    func testBar_onChangeQuery_emptyArm_setsHasResultTrue() throws {
        let model = try makeVM()
        model.terminalSearchHasResult = false  // provenance: start false so the arm flips it
        // newValue empty → the `if newValue.isEmpty` TRUE arm: terminalSearchHasResult = true.
        try bar(model).inspect().find(ViewType.TextField.self)
            .callOnChange(oldValue: "x", newValue: "")
        XCTAssertTrue(model.terminalSearchHasResult,
                      "onChange empty-arm sets terminalSearchHasResult = true")
    }

    func testBar_onChangeQuery_nonEmptyArm_stepsSearch() throws {
        let model = try makeVM()
        model.terminalSearchQuery = "q"
        model.terminalSearchHasResult = true
        // newValue non-empty → the else-arm: stepTerminalSearch(.next) → no session → false.
        try bar(model).inspect().find(ViewType.TextField.self)
            .callOnChange(oldValue: "", newValue: "q")
        XCTAssertFalse(model.terminalSearchHasResult,
                       "onChange non-empty-arm → stepTerminalSearch → hasResult false (no session)")
    }

    // MARK: - L9045/L9051/L9057 — the three toggle `onChange:` closures + the toggle flip

    func testBar_toggleAa_flipsCaseSensitiveAndSteps() throws {
        let model = try makeVM()
        XCTAssertFalse(model.terminalSearchCaseSensitive, "provenance: off")
        // Tapping "Aa" runs the toggle's `isOn.toggle()` (flips the bound @Published) AND its
        // `onChange: { model.stepTerminalSearch(.next) }` closure.
        try bar(model).inspect().find(button: "Aa").tap()
        XCTAssertTrue(model.terminalSearchCaseSensitive, "Aa tap flips terminalSearchCaseSensitive on")
    }

    func testBar_toggleRegex_flipsRegexAndSteps() throws {
        let model = try makeVM()
        try bar(model).inspect().find(button: ".*").tap()
        XCTAssertTrue(model.terminalSearchRegex, ".* tap flips terminalSearchRegex on")
    }

    func testBar_toggleWholeWord_flipsWholeWordAndSteps() throws {
        let model = try makeVM()
        try bar(model).inspect().find(button: "Wˌ").tap()
        XCTAssertTrue(model.terminalSearchWholeWord, "Wˌ tap flips terminalSearchWholeWord on")
    }

    // MARK: - L9059 / L9068 — the Previous / Next chevron button actions

    func testBar_chevronUpTap_stepsPrevious() throws {
        let model = try makeVM()
        model.terminalSearchQuery = "x"
        model.terminalSearchHasResult = true
        // The Previous button is the chevron.up image-only button → stepTerminalSearch(.previous).
        try bar(model).inspect().find(ViewType.Button.self, where: { b in
            (try? b.labelView().image().actualImage().name()) == "chevron.up"
        }).tap()
        XCTAssertFalse(model.terminalSearchHasResult,
                       "Previous chevron → stepTerminalSearch(.previous) → hasResult false (no session)")
    }

    func testBar_chevronDownTap_stepsNext() throws {
        let model = try makeVM()
        model.terminalSearchQuery = "x"
        model.terminalSearchHasResult = true
        try bar(model).inspect().find(ViewType.Button.self, where: { b in
            (try? b.labelView().image().actualImage().name()) == "chevron.down"
        }).tap()
        XCTAssertFalse(model.terminalSearchHasResult,
                       "Next chevron → stepTerminalSearch(.next) → hasResult false (no session)")
    }

    // MARK: - L9077 — the Done button action `{ model.dismissTerminalSearch() }`

    func testBar_doneTap_dismissesSearch() throws {
        let model = try makeVM()
        model.isTerminalSearchPresented = true
        try bar(model).inspect().find(button: "Done").tap()
        XCTAssertFalse(model.isTerminalSearchPresented,
                       "Done tap → dismissTerminalSearch → isTerminalSearchPresented false")
    }

    // MARK: - L9093 — the `.onAppear { fieldIsFocused = true }` closure

    func testBar_onAppear_invokesFocusClosure() throws {
        let model = try makeVM()
        // The onAppear is on the root HStack; it sets the bar's own `@FocusState
        // fieldIsFocused = true` (no VM effect), so invoking it covers the closure region.
        // It must not throw.
        XCTAssertNoThrow(try bar(model).inspect().hStack().callOnAppear(),
                         "the onAppear focus closure executes")
    }

    // MARK: - Negative controls (P2 — mutation-verified)

    /// The Done tap is load-bearing: it dismisses the search. (Mutation-verify: replacing
    /// `model.dismissTerminalSearch()` with a no-op leaves isTerminalSearchPresented true → RED.)
    func testBar_negativeControl_doneDismisses() throws {
        let model = try makeVM()
        model.isTerminalSearchPresented = true
        try bar(model).inspect().find(button: "Done").tap()
        XCTAssertFalse(model.isTerminalSearchPresented, "Done must dismiss the search")
    }

    /// The Aa toggle is load-bearing: it flips the case-sensitive option. (Mutation-verify:
    /// removing `isOn.toggle()` leaves terminalSearchCaseSensitive false → RED.)
    func testBar_negativeControl_aaToggleFlips() throws {
        let model = try makeVM()
        XCTAssertFalse(model.terminalSearchCaseSensitive, "provenance: off")
        try bar(model).inspect().find(button: "Aa").tap()
        XCTAssertTrue(model.terminalSearchCaseSensitive, "Aa must flip the case-sensitive option")
    }
}
#endif
