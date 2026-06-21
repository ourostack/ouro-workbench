import Foundation

/// The always-visible read of Boss Watch — the hands-off on/off master switch
/// (#U21). Boss Watch lived only inside the icon-only More (…) overflow and the
/// popover's one-way "Watch" button, so the operator could not see at a glance
/// whether autonomy was running. This pure presentation is the single source for
/// the on/off label, the bidirectional toggle title, and the help string, so the
/// header pill, the popover control, and the dashboard toggle all agree.
public struct BossWatchPresentation: Equatable, Sendable {
    /// Whether Boss Watch (autonomy) is currently running.
    public var isOn: Bool
    /// Whether the header pill should render at all. Boss Watch watches *via* a
    /// boss — with no usable boss there's nothing to watch with, so the
    /// glanceable header pill is hidden entirely (#U31a). A green "Watch On" on a
    /// no-boss first run is incoherent and breaks the calm no-boss header (U5).
    /// The popover and dashboard controls only render once a boss is set, so they
    /// pass the default `hasUsableBoss: true` and stay visible/unchanged.
    public var isVisible: Bool
    /// Bare on/off word — "On" / "Off".
    public var label: String
    /// Glanceable header form — "Watch On" / "Watch Off".
    public var shortLabel: String
    /// The action a tap performs, phrased as the *result* — "Pause Boss Watch"
    /// when on, "Start Boss Watch" when off. Matches the existing menu/command
    /// verb so the header and the More-menu read as one control.
    public var toggleActionTitle: String
    /// One sentence the operator can read to know what the switch governs.
    public var help: String

    /// - Parameters:
    ///   - isEnabled: whether the stored Boss Watch flag is on.
    ///   - hasUsableBoss: whether a usable boss exists to watch with — the same
    ///     usable-boss signal the calm header uses (`currentBossIsUsable`). When
    ///     false the pill is hidden (#U31a). Defaults to `true` so callers that
    ///     only render with a boss set keep today's behavior.
    public static func resolve(
        isEnabled: Bool,
        hasUsableBoss: Bool = true
    ) -> BossWatchPresentation {
        BossWatchPresentation(
            isOn: isEnabled,
            isVisible: hasUsableBoss,
            label: isEnabled ? "On" : "Off",
            shortLabel: isEnabled ? "Watch On" : "Watch Off",
            toggleActionTitle: isEnabled ? "Pause Boss Watch" : "Start Boss Watch",
            help: isEnabled
                ? "Boss Watch is on — the boss is empowered to keep things moving, acting on what your preferences cover and escalating the rest."
                : "Boss Watch is paused — the boss won't act on its own. Start it to let autonomy run."
        )
    }
}

/// A compact summary of the boss's recent **action receipts** — the executed-
/// action ledger (`WorkbenchActionLogEntry`) the boss keeps (#U21). The full log
/// was buried behind Advanced and showed only `prefix(1)`, so a FAILED autonomous
/// action was invisible by default. This pure summary lets the default boss pane
/// render "Recent actions: 3 ok · 1 failed" and surface the failed receipts
/// prominently, without each surface re-counting the log.
public struct BossActionReceiptSummary: Equatable, Sendable {
    public var okCount: Int
    public var failedCount: Int
    /// The most recent failed receipts (newest-first), so the pane can surface
    /// failures prominently without re-scanning the log.
    public var failedReceipts: [WorkbenchActionLogEntry]

    public var totalCount: Int { okCount + failedCount }
    public var hasFailures: Bool { failedCount > 0 }
    public var isEmpty: Bool { totalCount == 0 }

    /// "3 ok · 1 failed" — the failed segment is dropped when nothing failed, so
    /// a clean run reads "2 ok" rather than "2 ok · 0 failed". An empty log reads
    /// "No actions yet".
    public var label: String {
        if isEmpty {
            return "No actions yet"
        }
        if hasFailures {
            return "\(okCount) ok · \(failedCount) failed"
        }
        return "\(okCount) ok"
    }

    /// Summarize the action log, counting only the newest `window` entries (the
    /// log is newest-first after sorting). `window == nil` counts the whole log.
    public static func summarize(
        _ entries: [WorkbenchActionLogEntry],
        window: Int? = nil
    ) -> BossActionReceiptSummary {
        let newestFirst = entries.sorted { $0.occurredAt > $1.occurredAt }
        let considered = window.map { Array(newestFirst.prefix(max(0, $0))) } ?? newestFirst
        let failed = considered.filter { !$0.succeeded }
        return BossActionReceiptSummary(
            okCount: considered.count - failed.count,
            failedCount: failed.count,
            failedReceipts: failed
        )
    }
}
