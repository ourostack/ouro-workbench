import Foundation

/// A preference the operator wants the boss to remember about a friend, so the
/// boss's future inbox decisions improve. The boss owns its own memory
/// (`FriendRecord` notes / preferences), so Workbench doesn't write it directly
/// — it hands the boss a directive to persist via its own notes tools. This is
/// the learning loop: reinforce a good call, or correct a wrong one.
public struct FriendPreferenceTeaching: Equatable, Sendable {
    public var friendName: String
    public var friendId: String?
    /// The preference, phrased as guidance to the boss.
    public var preference: String

    public init(friendName: String, friendId: String? = nil, preference: String) {
        self.friendName = friendName
        self.friendId = friendId
        self.preference = preference
    }

    /// The directive sent to the boss (over the same conversation plane as
    /// check-ins) asking it to persist this preference against the friend.
    public func bossDirective() -> String {
        let idClause = friendId.map { " (id \($0))" } ?? ""
        return """
        Update your saved notes/preferences for your friend \(friendName)\(idClause): \(preference)

        Persist this with your notes tools so you apply it to future Ouro Workbench inbox decisions for this friend. This is a standing preference from the operator, not a one-off. Reply briefly to confirm you saved it.
        """
    }

    /// Build a teaching from a decision the operator is reinforcing or
    /// correcting. `autoAdvance == true` means "do this automatically next
    /// time"; `false` means "always ask me — don't auto-advance this".
    public static func reinforcement(
        for decision: BossInboxDecision,
        autoAdvance: Bool
    ) -> FriendPreferenceTeaching {
        let promptClause = decision.prompt.isEmpty ? "this kind of prompt" : "prompts like: \"\(decision.prompt)\""
        let preference: String
        if autoAdvance {
            let answerClause = decision.proposedInput.map { " — the right answer is usually \"\($0)\"" } ?? ""
            preference = "When a session for this friend shows \(promptClause), it is OK to auto-advance it without asking me\(answerClause)."
        } else {
            preference = "When a session for this friend shows \(promptClause), do NOT auto-advance — always escalate to me first."
        }
        return FriendPreferenceTeaching(
            friendName: decision.friendName ?? "the operator",
            friendId: decision.friendId,
            preference: preference
        )
    }
}
