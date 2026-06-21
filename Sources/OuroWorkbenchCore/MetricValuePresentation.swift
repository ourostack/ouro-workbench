import Foundation

/// How a dashboard metric chip should render its value (#U23b). The strip used
/// to print a bare "?" whenever a sub-probe was unavailable — visually identical
/// to a real value AND to a genuine zero, reading as "something's broken" when it
/// may be a transient probe, with the why hover-only and no retry. This pure
/// resolver turns "(value, isAvailable, reason)" into a presentation that keeps
/// three states distinct: a real number, a genuine zero, and an unavailable
/// probe (a muted dash + a specific reason + a one-click retry).
public struct MetricValuePresentation: Equatable, Sendable {
    /// The text the chip shows — a number, a passthrough string, or the muted
    /// dash for the not-a-value state.
    public var text: String
    /// Whether this is the unavailable / "can't report yet" state (muted, with a
    /// reason + retry) rather than a real value. A genuine zero is NOT unavailable.
    public var isUnavailable: Bool
    /// The specific reason the probe can't report — shown directly (not
    /// hover-only) so the operator never has to guess. Empty when available.
    public var reason: String
    /// Whether to offer a one-click retry for just this probe. True only when
    /// unavailable.
    public var canRetry: Bool

    /// The not-a-value glyph — a muted em dash, deliberately not "?".
    public static let unavailableText = "—"

    private static let defaultReason = "This metric can't report right now."

    private static func unavailable(issue: String?) -> MetricValuePresentation {
        MetricValuePresentation(
            text: unavailableText,
            isUnavailable: true,
            reason: issue?.isEmpty == false ? issue! : defaultReason,
            canRetry: true
        )
    }

    /// Resolve for an integer-counted metric. `isAvailable == false` (or a `nil`
    /// value even when nominally available — defensive) renders the not-a-value
    /// state; a present value renders the number, with a genuine zero kept
    /// distinct from unavailable.
    public static func resolve(value: Int?, isAvailable: Bool, issue: String?) -> MetricValuePresentation {
        guard isAvailable, let value else {
            return unavailable(issue: issue)
        }
        return MetricValuePresentation(text: "\(value)", isUnavailable: false, reason: "", canRetry: false)
    }

    /// Resolve for a metric whose available value is already a string (e.g. a
    /// "ok"/"unknown" claim). Unavailable still collapses to the not-a-value
    /// state rather than showing a stale or bare token.
    public static func resolve(text: String, isAvailable: Bool, issue: String?) -> MetricValuePresentation {
        guard isAvailable else {
            return unavailable(issue: issue)
        }
        return MetricValuePresentation(text: text, isUnavailable: false, reason: "", canRetry: false)
    }
}
