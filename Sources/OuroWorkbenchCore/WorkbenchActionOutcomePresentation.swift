/// Three-state presentation seam for a boss action-log entry's outcome.
///
/// The bug this fixes: the async "start" handlers (`startRepairAgent`,
/// `startVerifyProvider`, …) kick off background work and IMMEDIATELY log an
/// optimistic ack ("Working on getting <name> ready…"). That ack isn't
/// "Skipped"/"Failed", so the old `succeeded: !hasPrefix(…)` flag read `true`,
/// and the row wore a GREEN check — a false success for an action that hadn't
/// completed. The VERIFIED outcome only lands LATER via the `complete*` handlers,
/// as a separate row.
///
/// A green check must mean a VERIFIED success. An in-flight ack is neither success
/// nor failure — it's pending. This seam makes that explicit: it resolves a
/// `Tone` from the entry's `isInFlight` + `succeeded` flags, and maps each tone to
/// a neutral/green/orange icon, color, and label.
///
/// HONESTY INVARIANT: `iconSystemName`/`color` yield the green check / `.green`
/// ONLY for `.succeeded`, which `tone(...)` produces ONLY when
/// `isInFlight == false && succeeded == true`. An in-flight entry is ALWAYS
/// `.pending`/neutral — pending dominates the (meaningless-while-pending)
/// `succeeded` flag. And a genuinely-settled failure stays `.failed`/orange:
/// pending is ONLY for the optimistic in-flight ack, never for a real failure.
///
/// Pure, framework-free (no SwiftUI): the App maps `SemanticColor` to a SwiftUI
/// `Color` at the render site, so this stays unit-testable and coverage-gated.
public enum WorkbenchActionOutcomePresentation {
    /// The resolved presentation tone for one action-log entry.
    public enum Tone: Equatable, Sendable {
        /// An in-flight optimistic ack — work kicked off, outcome not yet known.
        case pending
        /// A VERIFIED success (the `complete*` outcome read healthy).
        case succeeded
        /// A settled failure — a guard-skip or a `complete*` outcome that failed.
        case failed
    }

    /// Resolve the three-state tone from the entry's flags. Pending dominates: an
    /// in-flight entry is pending regardless of the (meaningless-while-pending)
    /// `succeeded` flag, so an optimistic ack can never read as a green success.
    public static func tone(isInFlight: Bool, succeeded: Bool) -> Tone {
        if isInFlight {
            return .pending
        }
        return succeeded ? .succeeded : .failed
    }

    /// SF Symbol name for the tone. `.pending` is a NEUTRAL ellipsis (never the
    /// green check); `.succeeded` is the filled check; `.failed` is the warning
    /// triangle.
    public static func iconSystemName(for tone: Tone) -> String {
        switch tone {
        case .pending:
            return "ellipsis.circle"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    /// A framework-free color intent the App maps to a SwiftUI `Color` at the
    /// render site (`.neutral → .secondary`, `.green → .green`, `.orange → .orange`).
    public enum SemanticColor: Equatable, Sendable {
        case neutral
        case green
        case orange
    }

    /// Color intent for the tone. `.green` is reserved for `.succeeded` ALONE — a
    /// pending entry is `.neutral`, a failure is `.orange`.
    public static func color(for tone: Tone) -> SemanticColor {
        switch tone {
        case .pending:
            return .neutral
        case .succeeded:
            return .green
        case .failed:
            return .orange
        }
    }

    /// Accessibility / tooltip label for the tone.
    public static func label(for tone: Tone) -> String {
        switch tone {
        case .pending:
            return "In progress"
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }
}
