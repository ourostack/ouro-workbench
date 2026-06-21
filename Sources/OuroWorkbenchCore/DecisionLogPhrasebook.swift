import Foundation

/// One explicit teach choice the operator can pick for a decision (#U23a). The
/// segmented teach control presents BOTH intents for every decision kind, so a
/// first-timer never has to decode which polarity reinforces vs corrects.
public struct DecisionTeachOption: Equatable, Sendable, Identifiable {
    /// The plain-language choice.
    public var title: String
    /// Whether picking this reinforces the boss acting automatically
    /// (`autoAdvance == true`) or corrects toward always-ask (`false`). This is
    /// the value handed to the existing teach closure.
    public var reinforces: Bool
    /// Whether this option matches what the boss already did for this decision —
    /// shown as the current/selected segment.
    public var isCurrent: Bool

    public var id: Bool { reinforces }

    public init(title: String, reinforces: Bool, isCurrent: Bool) {
        self.title = title
        self.reinforces = reinforces
        self.isCurrent = isCurrent
    }
}

/// Maps the Decision Log's raw developer fields to plain operator language
/// (#U23a). The footer used to print `status: <rawValue>` (the boss-side
/// lifecycle enum) and `source: <actor id like boss:slugger>` verbatim, and the
/// Teach button's polarity silently inverted by kind. This phrasebook is the
/// single place that vocabulary lives so the operator-facing row reads in plain
/// words while the raw value stays available for a power-user disclosure.
public struct DecisionLogPhrasebook: Sendable {
    public init() {}

    /// Plain-language phrasing of the boss-side lifecycle status.
    public func statusPhrase(_ status: BossDecisionStatus) -> String {
        switch status {
        case .recorded:
            return "Logged (not sent)"
        case .applied:
            return "Sent"
        case .overridden:
            return "You corrected it"
        }
    }

    /// "Decided by:" value for a decision `source` actor id. A `boss:<name>`
    /// actor — the Boss Watch loop — reads as "Boss Watch"; any other actor reads
    /// as its bare name (never a raw colon-delimited id); an empty source reads
    /// "Unknown".
    public func decidedBy(source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Unknown"
        }
        if trimmed.lowercased().hasPrefix("boss:") {
            return "Boss Watch"
        }
        return trimmed
    }

    /// The two explicit teach choices for a decision kind. Both intents are
    /// always offered in the same order — "Do this automatically next time"
    /// (reinforces) then "Always ask me" (corrects) — so the control's polarity
    /// never depends on the kind. `isCurrent` marks the choice that matches what
    /// the boss already did: an `autoAdvance` decision's current is "automatic";
    /// an `escalate`/`hold` decision's current is "always ask me".
    public func teachOptions(for kind: BossDecisionKind) -> [DecisionTeachOption] {
        let autoIsCurrent = (kind == .autoAdvance)
        return [
            DecisionTeachOption(
                title: "Do this automatically next time",
                reinforces: true,
                isCurrent: autoIsCurrent
            ),
            DecisionTeachOption(
                title: "Always ask me",
                reinforces: false,
                isCurrent: !autoIsCurrent
            )
        ]
    }
}
