import Foundation

/// Coarse "Ns" / "Nm" / "Nh Nm" elapsed-time labels used in the sidebar's
/// running-session pill. Sub-minute updates would just noise the UI, so the
/// pill in the App refreshes every 30s; this formatter is the pure function
/// that drives the displayed string.
///
/// Promoted to the core module so the formatter — the part most likely to
/// regress as the codebase grows — has a tested home. The view in
/// `OuroWorkbenchApp` keeps the SwiftUI/TimelineView wrapper.
public enum WorkbenchElapsedFormatter {
    /// Coarse description for `now - start`. Negative durations clamp to 0.
    /// - Under 1m → `"<seconds>s"`.
    /// - Under 1h → `"<minutes>m"`.
    /// - Over 1h with non-zero remainder → `"<h>h <m>m"`.
    /// - Exact hours → `"<h>h"`.
    public static func coarseDescription(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let totalMinutes = seconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }
}
