import Foundation

/// Whether it's safe for the boss to auto-answer a waiting prompt on the
/// operator's behalf, or whether it must always be escalated to a human.
public enum PromptSafety: Equatable, Sendable {
    case safe
    /// Must escalate — carries a short reason for the audit log.
    case unsafe(String)

    public var isSafe: Bool {
        if case .safe = self { return true }
        return false
    }

    public var reason: String? {
        if case let .unsafe(reason) = self { return reason }
        return nil
    }
}

/// Defense-in-depth gate for auto-advance: even when the boss decides to
/// auto-advance, Workbench independently refuses to send input for prompts that
/// are destructive, irreversible, secret-bearing, financial, or agreement-
/// accepting. The boss's judgment is the policy; this is the hard floor under
/// it — and it errs toward *escalate* (a blocked mundane prompt just becomes a
/// human decision; a wrongly-auto-answered `rm -rf` does not).
///
/// Pure and exhaustively testable; classifies the prompt the session is showing
/// plus the input the boss proposes to send.
public enum PromptSafetyClassifier {
    public static func classify(prompt: String, proposedInput: String?) -> PromptSafety {
        let haystack = (prompt + "\n" + (proposedInput ?? "")).lowercased()

        for (needle, reason) in dangerousNeedles {
            if haystack.contains(needle) {
                return .unsafe(reason)
            }
        }
        return .safe
    }

    /// High-confidence dangerous substrings → escalate. Kept focused so mundane
    /// confirmations (edits, test runs, "continue?", selection menus) still
    /// auto-advance; only genuinely consequential classes are blocked.
    private static let dangerousNeedles: [(String, String)] = [
        // Secrets / credentials — never auto-entered.
        ("password", "credential prompt"),
        ("passphrase", "credential prompt"),
        ("api key", "credential prompt"),
        ("secret key", "credential prompt"),
        ("access token", "credential prompt"),
        ("2fa", "authentication prompt"),
        ("one-time code", "authentication prompt"),
        ("verification code", "authentication prompt"),
        // Destructive / irreversible filesystem + VCS.
        ("rm -rf", "destructive command"),
        ("rm -r ", "destructive command"),
        ("reset --hard", "destructive git reset"),
        ("git clean", "destructive git clean"),
        ("force-push", "force push"),
        ("force push", "force push"),
        ("push --force", "force push"),
        ("push -f", "force push"),
        ("dd if=", "raw disk write"),
        ("mkfs", "filesystem format"),
        ("format disk", "disk format"),
        ("drop table", "destructive database operation"),
        ("drop database", "destructive database operation"),
        ("truncate table", "destructive database operation"),
        ("permanently delete", "permanent deletion"),
        ("delete all", "bulk deletion"),
        // Privilege escalation.
        ("sudo ", "privileged command"),
        // Deploys / publishing to production.
        ("deploy to production", "production deploy"),
        ("deploy to prod", "production deploy"),
        ("publish to production", "production publish"),
        ("npm publish", "package publish"),
        ("release to production", "production release"),
        // Financial.
        ("confirm purchase", "purchase"),
        ("confirm payment", "payment"),
        ("place order", "purchase"),
        ("charge my", "payment"),
        ("complete checkout", "checkout"),
        // Agreements / consent.
        ("accept the terms", "terms acceptance"),
        ("accept terms", "terms acceptance"),
        ("terms of service", "terms acceptance"),
        ("license agreement", "license acceptance"),
        ("i agree to", "agreement acceptance"),
        ("end user license", "license acceptance")
    ]
}

/// The outcome of the auto-advance gate: whether the boss may actually send its
/// proposed input to a session, or why it's held back to escalation.
public enum AutoAdvanceGate: Equatable, Sendable {
    case allow
    case block(String)

    public var allows: Bool {
        if case .allow = self { return true }
        return false
    }

    public var blockedReason: String? {
        if case let .block(reason) = self { return reason }
        return nil
    }
}

/// Defense-in-depth decision for whether the boss may auto-advance a session.
/// All conditions must hold, layered cheapest/most-explicit first: the global
/// kill-switch, the session's own trust (untrusted is the default, so this is
/// the operator's per-session opt-in), the friend's trust level, and the prompt
/// safety floor. Pure so the whole gate is unit-tested rather than buried in UI.
public func evaluateAutoAdvanceGate(
    enabled: Bool,
    sessionTrusted: Bool,
    friend: SessionFriend?,
    prompt: String,
    proposedInput: String?
) -> AutoAdvanceGate {
    guard enabled else {
        return .block("auto-advance disabled")
    }
    guard sessionTrusted else {
        return .block("session not trusted")
    }
    guard let friend else {
        return .block("session has no friend")
    }
    guard friend.trust.isTrusted else {
        return .block("friend trust is \(friend.trust.rawValue)")
    }
    guard let proposedInput, !proposedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .block("no proposed input")
    }
    if case let .unsafe(reason) = PromptSafetyClassifier.classify(prompt: prompt, proposedInput: proposedInput) {
        return .block("unsafe prompt: \(reason)")
    }
    return .allow
}
