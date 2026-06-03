import Foundation

public struct BossWorkbenchActionAuthorization: Equatable, Sendable {
    public var isAllowed: Bool
    public var reason: String?

    public static func allowed() -> BossWorkbenchActionAuthorization {
        BossWorkbenchActionAuthorization(isAllowed: true, reason: nil)
    }

    public static func denied(_ reason: String) -> BossWorkbenchActionAuthorization {
        BossWorkbenchActionAuthorization(isAllowed: false, reason: reason)
    }
}

public struct BossWorkbenchActionAuthorizer: Sendable {
    public init() {}

    /// Authorize a boss-driven action against the target entry.
    ///
    /// `livePrompt` is the target session's *current waiting-prompt text* (the
    /// transcript tail the decisions / auto-advance gate reads). It matters only
    /// for `.sendInput`: the danger of a confused/injected `sendInput` lives in
    /// the PROMPT (`Run 'rm -rf /'? [y/N]`, `Confirm payment?`), not the bare
    /// input (`y`/`1`), so the safety floor must see it. Callers that have no
    /// live prompt may omit it; the classifier then sees only the input (the old
    /// input-only behavior), which still catches a dangerous input verbatim.
    public func authorize(
        _ action: BossWorkbenchAction,
        for entry: ProcessEntry,
        livePrompt: String = ""
    ) -> BossWorkbenchActionAuthorization {
        guard !entry.isArchived || action.action == .restore else {
            return .denied("entry is archived")
        }
        guard entry.trust == .trusted else {
            return .denied("entry is untrusted")
        }
        // Defense-in-depth safety floor for boss-driven `sendInput`: even on a
        // trusted session, Workbench refuses to be the conduit for an
        // obviously-destructive / secret-bearing / financial / agreement
        // prompt+input (e.g. a prompt-injected or confused boss answering `y` to
        // a `rm -rf` confirmation). This mirrors the auto-advance *decisions*
        // gate — which classifies the live prompt + proposed input — on the
        // *actions* path, so neither channel can blindly send dangerous text.
        if action.action == .sendInput {
            let safety = PromptSafetyClassifier.classify(prompt: livePrompt, proposedInput: action.text ?? "")
            if case let .unsafe(reason) = safety {
                return .denied("withheld unsafe input (\(reason)) — escalated to a human")
            }
        }
        return .allowed()
    }
}
