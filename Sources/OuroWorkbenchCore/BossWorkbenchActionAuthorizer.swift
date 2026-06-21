import Foundation

/// F3 — the auto-advance state the injection gate needs to decide whether the
/// boss may inject live input into a session: the operator's global kill-switch
/// (`bossAutoAdvanceEnabled`) and the effective friend governing the target
/// session. Carries no policy of its own — `evaluateBossInjectionGate` reads it.
public struct BossAutoAdvanceContext: Equatable, Sendable {
    /// The operator's auto-advance kill-switch. When OFF, the operator chose to
    /// make the boss "escalate everything instead" — so no channel may inject.
    public let autoAdvanceEnabled: Bool
    /// The effective friend for the target session (own assignment → group
    /// default → machine owner). nil means unassigned, which never injects.
    public let friend: SessionFriend?

    public init(autoAdvanceEnabled: Bool, friend: SessionFriend?) {
        self.autoAdvanceEnabled = autoAdvanceEnabled
        self.friend = friend
    }
}

public extension BossWorkbenchActionKind {
    /// Whether applying this kind INJECTS live input into a session's terminal —
    /// the keystroke channel the auto-advance kill-switch governs. ONLY
    /// `sendInput` does today: control/read verbs (launch, recover, terminate,
    /// archive, …) drive the session lifecycle but never type into a live prompt,
    /// so the kill-switch must not block them. Keeping this an explicit predicate
    /// (rather than an inline `== .sendInput`) makes the one injecting verb a
    /// named, testable concept — a new injecting kind opts in here.
    var injectsLiveInput: Bool {
        self == .sendInput
    }
}

/// F3 — the decision of whether the boss may inject live input into a session,
/// given the auto-advance context. `allow` clears the gate; `deny` carries the
/// audit reason. Pure + exhaustively testable so the kill-switch can't be
/// silently re-opened by a channel that forgets to consult it.
public enum BossInjectionGate: Equatable, Sendable {
    case allow
    case deny(String)
}

/// The single boss-injection gate, folded into the authorizer so EVERY channel
/// (app apply, MCP enqueue) inherits the operator's auto-advance kill-switch and
/// per-friend trust. Mirrors `evaluateAutoAdvanceGate`'s enabled + friend-trust
/// floor for the actions/MCP path that previously never reached it.
///
/// - Non-injecting verbs (everything but `sendInput`) are always allowed: the
///   kill-switch governs keystroke injection only, not control/read verbs.
/// - A nil context fails CLOSED for an injecting verb (the auto-advance state was
///   unavailable — e.g. the MCP enqueue path has no app state — so refuse rather
///   than guess permissive).
/// - Otherwise: the kill-switch must be ON, the session must have a friend, and
///   that friend must be trusted (family/friend) — the same floor the decisions
///   channel applies.
public func evaluateBossInjectionGate(
    action: BossWorkbenchActionKind,
    context: BossAutoAdvanceContext?
) -> BossInjectionGate {
    guard action.injectsLiveInput else { return .allow }
    guard let context else { return .deny("auto-advance state unavailable") }
    guard context.autoAdvanceEnabled else { return .deny("auto-advance disabled") }
    guard let friend = context.friend else { return .deny("session has no friend") }
    guard friend.trust.isTrusted else { return .deny("friend trust is \(friend.trust.rawValue)") }
    return .allow
}

/// The posture under which an action was (or was not) authorized.
///
/// Entry-less actions never had an authorization posture before R2 — they bypassed the
/// authorizer entirely. The posture makes the decision EXPLICIT and auditable: onboarding
/// remediations run under `trustedOnboarding` (auto-apply + mandatory audit), the
/// previously-bypassed known callers run under `knownEntryless`, and anything that reaches
/// the entry-less path but shouldn't is `denied`. Entry-scoped decisions keep the historical
/// `entryScoped` posture (the default), so live's `authorize(_:for:livePrompt:)` floor is
/// unchanged.
public enum BossWorkbenchAuthorizationPosture: String, Equatable, Sendable {
    /// Entry-scoped authorization (the original `authorize(_:for:livePrompt:)` path).
    case entryScoped
    /// Onboarding remediation, auto-applied with a mandatory audit line.
    case trustedOnboarding
    /// A known-legit entry-less action (`createGroup` / `createTerminal` / `createSession`) —
    /// previously bypassed, now explicitly authorized.
    case knownEntryless
    /// Denied.
    case denied
}

public struct BossWorkbenchActionAuthorization: Equatable, Sendable {
    public var isAllowed: Bool
    public var reason: String?
    /// The posture this decision was made under. Defaults to `.entryScoped` so the existing
    /// entry-scoped `allowed()`/`denied(_:)` factories keep their historical meaning and the
    /// live `authorize(_:for:livePrompt:)` floor's allow/deny results are unaffected.
    public var posture: BossWorkbenchAuthorizationPosture

    /// Whether applying this action MUST emit an audit line. Onboarding remediations are
    /// auto-applied with no human prompt, so a mandatory audit line is the accountability
    /// surface (recovery-truth). Denials and entry-scoped allows do not set this.
    public var requiresAudit: Bool {
        isAllowed && posture == .trustedOnboarding
    }

    public init(
        isAllowed: Bool,
        reason: String?,
        posture: BossWorkbenchAuthorizationPosture = .entryScoped
    ) {
        self.isAllowed = isAllowed
        self.reason = reason
        self.posture = posture
    }

    public static func allowed() -> BossWorkbenchActionAuthorization {
        BossWorkbenchActionAuthorization(isAllowed: true, reason: nil, posture: .entryScoped)
    }

    public static func denied(_ reason: String) -> BossWorkbenchActionAuthorization {
        BossWorkbenchActionAuthorization(isAllowed: false, reason: reason, posture: .denied)
    }

    static func allowed(posture: BossWorkbenchAuthorizationPosture) -> BossWorkbenchActionAuthorization {
        BossWorkbenchActionAuthorization(isAllowed: true, reason: nil, posture: posture)
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

    /// The single authorization front door used by BOTH call sites — the MCP enqueue path
    /// (`OuroWorkbenchMCP/OuroWorkbenchMCPMain.swift requestAction`) and the app apply path
    /// (`OuroWorkbenchApp applyBossAction`). It dispatches to the entry-scoped check (which
    /// runs live's `livePrompt` sendInput safety floor) when an entry was resolved, and to the
    /// explicit entry-less check otherwise.
    ///
    /// This is what closes the historical bypass: previously each call site only consulted the
    /// authorizer `if let entry`, so entry-less actions slipped authorization entirely. Routing
    /// every action — entry-scoped or entry-less — through one front door guarantees no path
    /// can skip the check.
    ///
    /// ADDITIVE MERGE: when an entry is present this delegates to the UNCHANGED
    /// `authorize(_:for:livePrompt:)` (forwarding `livePrompt`), so live's destructive-input
    /// safety floor still fires on the entry-scoped `sendInput` channel. The entry-less branch
    /// is a NEW, separate path that never touches the floor.
    public func authorize(
        _ action: BossWorkbenchAction,
        resolvedEntry entry: ProcessEntry?,
        livePrompt: String = ""
    ) -> BossWorkbenchActionAuthorization {
        if let entry {
            return authorize(action, for: entry, livePrompt: livePrompt)
        }
        return authorizeEntryless(action)
    }

    /// The shared enqueue/apply gate decision: the authorization PLUS the human-readable
    /// target name to name in a denial. Both bypass-closing call sites (MCP `requestAction`
    /// and app `applyBossAction`) reject with the SAME target string, so they can't drift.
    public struct GateDecision: Equatable, Sendable {
        public let authorization: BossWorkbenchActionAuthorization
        /// The entry's name when entry-scoped, else the action's raw kind (no entry to name).
        public let deniedTarget: String
    }

    /// The single bypass-closing gate both call sites use. Routes EVERY action through the
    /// `authorize(_:resolvedEntry:livePrompt:)` front door (entry-scoped runs live's
    /// `livePrompt` floor; entry-less runs the explicit posture check) and resolves the denial
    /// target. Previously entry-less actions skipped authorization entirely; routing them here
    /// closes that bypass identically in both the MCP enqueue path and the app apply path.
    public func gate(
        _ action: BossWorkbenchAction,
        resolvedEntry entry: ProcessEntry?,
        livePrompt: String = ""
    ) -> GateDecision {
        let authorization = authorize(action, resolvedEntry: entry, livePrompt: livePrompt)
        return GateDecision(
            authorization: authorization,
            deniedTarget: entry?.name ?? action.action.rawValue
        )
    }

    /// Authorize an ENTRY-LESS action with an explicit allow/deny + reason + posture.
    ///
    /// This closes the historical bypass: before R2, entry-less actions skipped authorization
    /// entirely (the only authorizer took a `ProcessEntry`). Now every entry-less action gets
    /// an explicit decision:
    ///
    /// - Onboarding remediation (`repairAgent`) → allowed under `trustedOnboarding` (auto-apply,
    ///   mandatory audit), but ONLY when it carries its explicit resolved agent name — never
    ///   lean on `ouro` default-agent resolution.
    /// - Known-legit entry-less actions (`createGroup` / `createTerminal` / `createSession`) →
    ///   allowed under `knownEntryless` (previously bypassed; now explicitly authorized).
    /// - Anything else reaching the entry-less path → denied (it slipped its entry check). This
    ///   notably includes `sendInput`, so a `sendInput` with no entry can never bypass the
    ///   entry-scoped `livePrompt` safety floor by arriving entry-less.
    public func authorizeEntryless(_ action: BossWorkbenchAction) -> BossWorkbenchActionAuthorization {
        switch action.action {
        case .repairAgent:
            guard action.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return .denied("repairAgent requires an explicit agent name")
            }
            return .allowed(posture: .trustedOnboarding)
        case .requestProviderConfig:
            // Non-secret-bearing, non-executing UI signal: it carries no credential and runs no
            // command — its sole effect is asking the app to open the native provider form (the
            // one human gate). Allowed entry-less under `trustedOnboarding`; it needs no explicit
            // agent name (the form resolves/labels the target itself).
            return .allowed(posture: .trustedOnboarding)
        case .verifyProvider, .refreshProvider, .selectLane, .registerWorkbenchMCP:
            // Every agent-targeted onboarding remediation requires an EXPLICIT resolved agent
            // name — never lean on `ouro` default-agent resolution (the wrong agent could be
            // acted on). Authorized under the trusted-onboarding posture (auto-apply + mandatory
            // audit). An empty name is denied here, so the command never runs.
            guard action.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return .denied("\(action.action.rawValue) requires an explicit agent name")
            }
            return .allowed(posture: .trustedOnboarding)
        case .ensureDaemon:
            // The daemon is machine-scoped infrastructure (no agent name). Authorized under the
            // trusted-onboarding posture (auto-apply + mandatory audit).
            return .allowed(posture: .trustedOnboarding)
        case .createGroup, .createTerminal, .createSession, .reportBug:
            // `reportBug` is a known-legit entry-less write — the boss capturing a defect into
            // the same local anonymized bundle a human would create (U30b). Reversible local
            // artifact; filing to GitHub stays human-gated.
            return .allowed(posture: .knownEntryless)
        case .launch, .recover, .terminate, .sendInput, .moveSession,
             .setTrust, .setAutoResume, .archive, .restore:
            return .denied("\(action.action.rawValue) is not authorized without a target entry")
        }
    }
}
