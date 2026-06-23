import Foundation

/// Pure decisions that gate the workbench's autonomous action application on the
/// Boss Watch kill-switch. Extracted so the "should the pump apply now?" rule is
/// unit-tested rather than buried in the view model.
///
/// The operator's "Pause Boss Watch" is a TRUE kill-switch: while paused, the
/// external-action pump must NOT drain+apply queued requests. Pausing the watch
/// loop already stops NEW actions from being generated, but the pump drained and
/// applied ALREADY-QUEUED requests (and out-of-band requests from another
/// process) every ~2s regardless — so a pause wasn't a real stop. This seam makes
/// the pump consult the switch BEFORE each drain/apply: when off it skips the
/// drain entirely, leaving the request files HELD in the queue dir (never moved
/// into `processing/`, never lost). Resuming lets the pump apply the held queue
/// again. An apply already mid-execution finishes (you can't un-send a
/// `sendInput`); the kill-switch means "no NEW applies while paused".
public enum BossAutonomyGating {
    /// Whether the external-action pump may drain + apply queued requests right
    /// now. True iff Boss Watch is enabled. When false the caller skips the drain
    /// so the queued request files stay on disk, held until the watch resumes.
    public static func shouldApplyQueuedActions(bossWatchEnabled: Bool) -> Bool {
        bossWatchEnabled
    }
}
