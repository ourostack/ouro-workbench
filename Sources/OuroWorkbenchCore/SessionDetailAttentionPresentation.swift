import Foundation

/// U10: the live session-detail header tells the truth about attention.
///
/// The pre-U10 header hand-rolled a green/orange/grey trichotomy from
/// `isActiveSession` / `canRecover` and ignored `entry.attention` entirely, so a
/// running session sitting on a prompt — orange `waitingOnHuman` in the 8pt
/// sidebar dot — showed a calm GREEN dot in the full-screen header the operator
/// lives on. Two sources of truth, the worse one winning the biggest pixels.
///
/// This pure, framework-free seam is the SINGLE mapping the detail header drives
/// from: it decides the header dot's identity and whether a slim "why" banner
/// renders above the terminal. The App view maps `DotState.attention(_:)`
/// through the shared `AttentionState.healthColor/healthSymbol/healthLabel`
/// (the same mapping the sidebar `StatusDot`/`SessionChip` use), so the header
/// and the sidebar can't drift — and the boss's `entry.attention` signal stays
/// consistent with what the header shows.
public enum SessionDetailAttentionPresentation {
    /// The header status dot's identity. For a LIVE session it follows the real
    /// `attention` (so the App tints/glyphs it via the shared `AttentionState`
    /// helpers); for an inactive session it keeps the prior recovery semantics
    /// (orange "recoverable" / grey "idle"), and archived is always dimmed.
    public enum DotState: Equatable, Sendable {
        case attention(AttentionState)
        case recoverable
        case inactive
        case archived
    }

    /// Which live-attention state the banner is announcing. Drives the App's
    /// color/icon (reusing the shared `AttentionState` helpers).
    public enum BannerKind: Equatable, Sendable {
        case waitingOnHuman
        case blocked
        case needsBossReview
    }

    /// A slim one-line attention banner rendered ABOVE the terminal pane when a
    /// live session needs the human. `text` is the full headline incl. the
    /// detected reason ("Waiting on you · <reason>" / "Blocked · <reason>");
    /// `offersJumpToPrompt` is true for the waiting/blocked cases that have a
    /// place in the terminal to focus, false for a boss-review flag (no operator
    /// prompt to jump to).
    public struct Banner: Equatable, Sendable {
        public var kind: BannerKind
        public var text: String
        public var offersJumpToPrompt: Bool

        public init(kind: BannerKind, text: String, offersJumpToPrompt: Bool) {
            self.kind = kind
            self.text = text
            self.offersJumpToPrompt = offersJumpToPrompt
        }
    }

    /// The resolved header presentation: the dot's identity plus an optional
    /// attention banner.
    public struct Presentation: Equatable, Sendable {
        public var dot: DotState
        public var banner: Banner?

        public init(dot: DotState, banner: Banner?) {
            self.dot = dot
            self.banner = banner
        }
    }

    /// Resolve the detail-header presentation.
    ///
    /// - Parameters:
    ///   - attention: the entry's `AttentionState` — the SAME value the boss reads.
    ///   - isActiveSession: whether the entry has a live in-app session/process.
    ///   - canRecover: whether an inactive session is recoverable (orange dot).
    ///   - isArchived: archived sessions are always dimmed and never banner.
    ///   - reason: the short "why" line from `AttentionSignalDetector` (the prompt
    ///     the agent is waiting on / the error it's stuck on); blank/nil omits the
    ///     " · <reason>" suffix.
    public static func resolve(
        attention: AttentionState,
        isActiveSession: Bool,
        canRecover: Bool,
        isArchived: Bool,
        reason: String?
    ) -> Presentation {
        Presentation(
            dot: dotState(
                attention: attention,
                isActiveSession: isActiveSession,
                canRecover: canRecover,
                isArchived: isArchived
            ),
            banner: banner(
                attention: attention,
                isActiveSession: isActiveSession,
                isArchived: isArchived,
                reason: reason
            )
        )
    }

    private static func dotState(
        attention: AttentionState,
        isActiveSession: Bool,
        canRecover: Bool,
        isArchived: Bool
    ) -> DotState {
        if isArchived { return .archived }
        if isActiveSession { return .attention(attention) }
        if canRecover { return .recoverable }
        return .inactive
    }

    private static func banner(
        attention: AttentionState,
        isActiveSession: Bool,
        isArchived: Bool,
        reason: String?
    ) -> Banner? {
        // The banner is for LIVE attention only — a session with no live process
        // is owned by the recovery surface, not this prompt banner.
        guard isActiveSession, !isArchived else { return nil }

        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = (trimmedReason?.isEmpty == false) ? " · \(trimmedReason!)" : ""

        switch attention {
        case .waitingOnHuman:
            return Banner(kind: .waitingOnHuman, text: "Waiting on you\(suffix)", offersJumpToPrompt: true)
        case .blocked:
            return Banner(kind: .blocked, text: "Blocked\(suffix)", offersJumpToPrompt: true)
        case .needsBossReview:
            return Banner(kind: .needsBossReview, text: "Needs boss review\(suffix)", offersJumpToPrompt: false)
        case .active, .idle:
            return nil
        }
    }
}
