import Foundation

/// FIX 1 (HIGH, destructive) — the single pure decision behind `activeEntry`:
/// which terminal the "selected-session" menu chords act on (⌘. Stop, ⌘L Redraw,
/// ⌘F Find). macOS menu key-equivalents win over a focus view's inline buttons,
/// so whatever `activeEntry` returns is what ⌘. KILLS — it MUST be the terminal
/// the operator is looking at.
///
/// The bug this fixes: full-screen focus mode (entered from a row's Focus button
/// or `jumpToAttentionPrompt`) set only `terminalFocusEntryID` and never the
/// sidebar selection, while `activeEntry` consulted only the sidebar selection /
/// secondary pane. So ⌘. on a focused terminal stopped a *different* agent — one
/// the operator wasn't even watching. Focus mode should authoritatively define the
/// active terminal, so this resolver makes a live focus session WIN over both the
/// secondary pane and the sidebar selection.
///
/// Pure + framework-free so the priority order is exhaustively unit-tested rather
/// than buried in a SwiftUI view model. The model passes already-resolved inputs
/// (it owns `activeSessions`, the split state, and the entry lookups); this just
/// folds them into one id with a stable priority.
public enum ActiveEntryResolver {
    /// Resolve the id of the terminal that selected-session commands act on.
    ///
    /// Priority (highest first):
    /// 1. **Focus mode** — when `terminalFocusEntryID` is set AND that session
    ///    still resolves to a live entry (`focusEntryResolves`), the focused
    ///    terminal wins. A stale/dead focus id (no longer resolves) does NOT win;
    ///    it falls through so the chords still hit a live target.
    /// 2. **Focused secondary pane** — when a split is active and its secondary
    ///    pane is focused AND its entry resolves, that pane's entry. (The pre-fix
    ///    split behavior, unchanged.)
    /// 3. **Sidebar selection** — `selectedEntryID` otherwise (single-pane / primary
    ///    pane / unfocused — the original behavior).
    ///
    /// - Parameters:
    ///   - selectedEntryID: the resolved sidebar selection (`selectedEntry?.id`).
    ///   - terminalFocusEntryID: `terminalFocusEntryID` — non-nil iff focus mode
    ///     was entered (regardless of whether the session is still alive).
    ///   - focusEntryResolves: whether `terminalFocusEntry` resolves to a live entry
    ///     (`terminalFocusEntry != nil`). Guards against targeting a dead focus id.
    ///   - splitIsActive: `detailSplit != nil`.
    ///   - secondaryPaneIsFocused: `activePaneID == .secondary`.
    ///   - secondaryPaneEntryID: the secondary pane's resolved entry id
    ///     (`secondaryPaneEntry?.id`), or nil when it's an unassigned picker / its
    ///     session no longer resolves.
    /// - Returns: the active entry id, or nil when nothing resolves.
    public static func resolve(
        selectedEntryID: UUID?,
        terminalFocusEntryID: UUID?,
        focusEntryResolves: Bool,
        splitIsActive: Bool,
        secondaryPaneIsFocused: Bool,
        secondaryPaneEntryID: UUID?
    ) -> UUID? {
        // 1. Focus mode authoritatively defines the active terminal — but only when
        //    its session is still live, so a stale focus id can't redirect ⌘. onto
        //    a dead/unrelated target.
        if let terminalFocusEntryID, focusEntryResolves {
            return terminalFocusEntryID
        }
        // 2. Focused secondary pane (pre-fix split behavior, unchanged).
        if splitIsActive, secondaryPaneIsFocused, let secondaryPaneEntryID {
            return secondaryPaneEntryID
        }
        // 3. Sidebar selection (the original single-pane behavior).
        return selectedEntryID
    }
}
