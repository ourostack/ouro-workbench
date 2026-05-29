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

    public func authorize(_ action: BossWorkbenchAction, for entry: ProcessEntry) -> BossWorkbenchActionAuthorization {
        guard !entry.isArchived || action.action == .restore else {
            return .denied("entry is archived")
        }
        guard entry.trust == .trusted else {
            return .denied("entry is untrusted")
        }
        // Defense-in-depth safety floor for boss-driven `sendInput`: even on a
        // trusted session, Workbench refuses to be the conduit for an
        // obviously-destructive / secret-bearing / financial / agreement input
        // (e.g. a prompt-injected or confused boss proposing `rm -rf`). This is
        // the same floor the auto-advance *decisions* path enforces, applied to
        // the *actions* path so neither can blindly send dangerous text.
        if action.action == .sendInput {
            let safety = PromptSafetyClassifier.classify(prompt: "", proposedInput: action.text ?? "")
            if case let .unsafe(reason) = safety {
                return .denied("withheld unsafe input (\(reason)) — escalated to a human")
            }
        }
        return .allowed()
    }
}
