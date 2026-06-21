import Foundation

/// U31(b): the calm-vs-loud decision for the in-window header's one-line status
/// text. `HeaderView` rendered `summary.oneLineStatus` unconditionally, so a fresh
/// no-boss machine read "0 running, nothing to recover" — two information-free
/// zeros next to the (now calm) boss selector, undercutting the shipped calm
/// first-run header (U5). This pure seam hides the line on a genuinely quiet
/// machine (nobody waiting, nothing running, nothing actionable to recover) and
/// shows the existing informative text only when there's something to say.
///
/// The wording itself is unchanged — `oneLineStatus` already routes recovery
/// phrasing through the shared `RecoveryDigest` vocabulary (no "recovery action"
/// jargon). The boss prompt builder keeps reading the raw `oneLineStatus`; only
/// the human header gates on this.
public struct HeaderStatusLinePresentation: Equatable, Sendable {
    /// Whether the header should render the status line at all.
    public var shouldShow: Bool
    /// The text to render when `shouldShow` — the existing `oneLineStatus`.
    public var text: String

    public init(shouldShow: Bool, text: String) {
        self.shouldShow = shouldShow
        self.text = text
    }

    public static func resolve(summary: WorkspaceSummary) -> HeaderStatusLinePresentation {
        let runningCount = summary.processSnapshots.filter { $0.status == .running }.count
        let isQuiet =
            summary.waitingOnHuman.isEmpty
            && runningCount == 0
            && summary.recoveryDigest.actionableCount == 0
        return HeaderStatusLinePresentation(
            shouldShow: !isQuiet,
            text: summary.oneLineStatus
        )
    }
}
