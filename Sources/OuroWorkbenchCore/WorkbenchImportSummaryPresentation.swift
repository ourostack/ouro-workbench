/// Two-state presentation seam for the post-import "Imported N terminals" banner.
///
/// The bug this fixes: importing a workspace (the workspace-config apply path and
/// the onboarding-apply path) called the view-model's `save()`, then
/// UNCONDITIONALLY set `lastImportSummary` (driving a GREEN `ImportSummaryBanner`)
/// and logged `succeeded:true` — EVEN WHEN the durable `store.save(state)` threw
/// and the failure was swallowed into `errorMessage`. The user saw a green
/// "Imported N terminals" success over an in-memory-only import that's lost on
/// quit. Same false-success family as the readiness / action-log false-greens.
///
/// Now `save()` returns a `Bool`, and both apply paths thread that `persisted`
/// flag into `WorkbenchImportApplyResult`. This seam resolves the banner's
/// green-vs-warning tone from `persisted` so the honesty rule is unit-tested in
/// one pure place rather than hand-wired at the SwiftUI render site.
///
/// HONESTY INVARIANT (asserted exhaustively in the tests): `.success` — the green
/// `checkmark.seal.fill` + `.green` color — is produced ONLY when
/// `persisted == true`. An import whose write failed (`persisted == false`) is
/// ALWAYS `.warning`/`.orange`, regardless of `createdCount`. A SUCCESSFUL
/// persisted import (the common case) STILL shows the normal green banner — the
/// warning path fires ONLY when the durable write actually failed. A partial
/// import (some terminals skipped) that DID persist is still a green success with
/// a skipped note; the skipped-count messaging lives on `WorkbenchImportApplyResult`
/// and is unaffected by this tone.
///
/// Pure, framework-free (no SwiftUI): the App maps `SemanticColor` to a SwiftUI
/// `Color` at the render site, so this stays unit-testable and coverage-gated.
public enum WorkbenchImportSummaryPresentation {
    /// The resolved banner tone for one import result.
    public enum Tone: Equatable, Sendable {
        /// The import persisted — show the normal green "Imported N terminals"
        /// banner (including a "Nothing imported" that wrote cleanly).
        case success
        /// The durable write FAILED — show an orange/warning banner so the user
        /// knows the import is in-memory only and lost on quit.
        case warning
    }

    /// A framework-free color intent the App maps to a SwiftUI `Color` at the
    /// render site (`.green → .green`, `.orange → .orange`).
    public enum SemanticColor: Equatable, Sendable {
        case green
        case orange
    }

    /// Resolve the banner tone. `.success` (green) is produced ONLY when the
    /// import persisted; a failed write is ALWAYS `.warning`. `createdCount` is
    /// accepted for symmetry with the call site (and to make the honesty sweep
    /// explicit that the count does NOT influence the green/warning decision) but
    /// does not gate the tone — only `persisted` does.
    public static func tone(persisted: Bool, createdCount: Int) -> Tone {
        _ = createdCount
        return persisted ? .success : .warning
    }

    /// SF Symbol for the tone. `.success` is the filled seal-check (matching the
    /// banner's historical green icon); `.warning` is the warning triangle.
    public static func iconSystemName(for tone: Tone) -> String {
        switch tone {
        case .success:
            return "checkmark.seal.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Color intent for the tone. `.green` is reserved for `.success` ALONE.
    public static func color(for tone: Tone) -> SemanticColor {
        switch tone {
        case .success:
            return .green
        case .warning:
            return .orange
        }
    }

    /// The honest human-facing line appended when the import did NOT persist, so
    /// the user knows the in-memory import is lost on quit.
    public static let notPersistedNote =
        "Imported, but couldn't save to disk — they'll be lost when you quit."
}
