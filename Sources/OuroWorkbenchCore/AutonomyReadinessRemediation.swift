import Foundation

/// What an in-app one-tap fix does, in framework-free terms. The App layer maps each
/// `kind` to the concrete actuator (trust the terminals, enable resume, …) and renders
/// `actionLabel` on the per-check repair button using the OnboardingRepairStepRow vocabulary.
public enum AutonomyRemediationKind: String, Equatable, Sendable {
    case trustTerminals
    case enableResume
    case connectTools
    case recover
    case enableWatch
    case openAtLogin
}

/// A remediation a non-green check can offer inline. Absent (`nil` from the mapping) means
/// the check has no in-app fix — render NO orphaned button (genuinely degraded states like a
/// missing executable / app / agent bundle, or a boss-name choice the operator must make).
public struct AutonomyRemediation: Equatable, Sendable {
    public var actionLabel: String
    public var kind: AutonomyRemediationKind

    public init(actionLabel: String, kind: AutonomyRemediationKind) {
        self.actionLabel = actionLabel
        self.kind = kind
    }
}

/// The runtime availability of each in-app remediation actuator — whether the
/// per-kind button has actual work to do RIGHT NOW (FIX 1 / U9-1).
///
/// The abstract `AutonomyRemediationMapper.remediation(forCheckId:state:)` says a
/// non-green check *could* offer a one-tap fix, but the App suppresses the button
/// per-row when the actuator has nothing to act on (a `recovery` blocker whose
/// only recovering entries are `.manualActionNeeded` — excluded from
/// `recoverableEntries`; a `terminal-resume` blocker whose blocking agents are
/// `.manual` strategy — excluded from `resumableDisabledAutonomyAgentEntries`).
/// The App fills this from its live view-model so ONE predicate decides both the
/// per-row button visibility and the calm-vs-loud reframe — they can never
/// disagree about whether a blocker has a tappable fix.
public struct AutonomyRemediationAvailability: Equatable, Sendable {
    /// At least one autonomy terminal is untrusted (the Trust button has work).
    public var hasUntrustedTerminals: Bool
    /// At least one terminal can be flipped to auto-resume (an automatic-strategy
    /// agent with resume disabled). A `.manual`-only agent is NOT counted here.
    public var hasResumableDisabledTerminals: Bool
    /// The boss MCP registration is installable in-app (`.notRegistered` /
    /// `.needsUpdate`); a missing binary / bundle is not actionable here.
    public var mcpRegistrationActionable: Bool
    /// At least one entry can be recovered in-app (reattach / resume / respawn).
    /// A `.manualActionNeeded`-only set is NOT counted here.
    public var hasRecoverableEntries: Bool
    /// Boss Watch is currently OFF, so the Watch button has something to enable.
    public var bossWatchDisabled: Bool
    /// The login item can be registered from here (i.e. the app bundle is present).
    public var loginItemActionable: Bool

    public init(
        hasUntrustedTerminals: Bool,
        hasResumableDisabledTerminals: Bool,
        mcpRegistrationActionable: Bool,
        hasRecoverableEntries: Bool,
        bossWatchDisabled: Bool,
        loginItemActionable: Bool
    ) {
        self.hasUntrustedTerminals = hasUntrustedTerminals
        self.hasResumableDisabledTerminals = hasResumableDisabledTerminals
        self.mcpRegistrationActionable = mcpRegistrationActionable
        self.hasRecoverableEntries = hasRecoverableEntries
        self.bossWatchDisabled = bossWatchDisabled
        self.loginItemActionable = loginItemActionable
    }
}

/// How a non-green snapshot reads: a couple of user-side toggles away from green
/// (`.oneTapSetup`, calm action-first framing) vs genuinely degraded (`.degraded`,
/// keep the stop-sign / "cannot recover" language). A paused Boss Watch is `.warning`,
/// not a blocker, so it never forces `.degraded`.
public enum AutonomyReadinessReason: Equatable, Sendable {
    case oneTapSetup
    case degraded
}

/// Pure, view-free mapping from a readiness check to the inline fix it can offer. Keyed on the
/// check id + its state so the App can render the right repair button without re-deriving intent.
///
/// `boss` (a bad/missing boss bundle name — the operator must pick a different boss, not flip a
/// toggle) and `executables` (a missing executable — genuinely degraded) never map to a one-tap
/// fix. `boss-mcp` and `open-at-login` carry App-only degraded sub-states (missing binary / missing
/// app bundle) the App suppresses separately; this seam offers their happy-path setup remediation.
public enum AutonomyRemediationMapper {
    /// Check ids that can never be fixed by a single in-app tap regardless of state.
    public static let nonRemediableCheckIds: Set<String> = ["boss", "executables"]

    public static func remediation(
        forCheckId id: String,
        state: AutonomyReadinessCheckState
    ) -> AutonomyRemediation? {
        guard state != .ok else {
            return nil
        }
        switch id {
        case "terminal-trust":
            return AutonomyRemediation(actionLabel: "Trust", kind: .trustTerminals)
        case "terminal-resume":
            return AutonomyRemediation(actionLabel: "Enable resume", kind: .enableResume)
        case "boss-mcp":
            return AutonomyRemediation(actionLabel: "Connect tools", kind: .connectTools)
        case "recovery":
            return AutonomyRemediation(actionLabel: "Recover", kind: .recover)
        case "boss-watch":
            return AutonomyRemediation(actionLabel: "Watch", kind: .enableWatch)
        case "open-at-login":
            return AutonomyRemediation(actionLabel: "Login", kind: .openAtLogin)
        default:
            return nil
        }
    }

    /// Whether the in-app button for a remediation `kind` has actual work to do
    /// right now, given the live actuator availability (FIX 1 / U9-1). This is the
    /// SAME per-kind runtime gate the popover's per-row button uses, so the
    /// calm-vs-loud reframe and the row buttons consult one predicate. A `false`
    /// here means: the abstract mapper offers this kind a fix, but the App would
    /// suppress its button (nothing to act on) — i.e. genuinely degraded for this row.
    public static func hasLiveButton(
        for kind: AutonomyRemediationKind,
        availability: AutonomyRemediationAvailability
    ) -> Bool {
        switch kind {
        case .trustTerminals:
            return availability.hasUntrustedTerminals
        case .enableResume:
            return availability.hasResumableDisabledTerminals
        case .connectTools:
            return availability.mcpRegistrationActionable
        case .recover:
            return availability.hasRecoverableEntries
        case .enableWatch:
            return availability.bossWatchDisabled
        case .openAtLogin:
            return availability.loginItemActionable
        }
    }

    /// The check ids that are a `.blocker` mapping to an abstract remediation whose
    /// in-app button the runtime gate would suppress (FIX 1 / U9-1). The App folds
    /// these into `degradedCheckIds` so `reason(...)` and the reframe consult the
    /// SAME per-row runtime availability the rows use — a blocker with no live,
    /// tappable fix is classified degraded (loud), never promised as one-tap setup.
    ///
    /// Only `.blocker` checks that the abstract mapper WOULD offer a button for are
    /// considered: a warning is never a wall, and a check with no abstract
    /// remediation is already handled by `reason(...)`'s non-remediable path.
    public static func runtimeSuppressedDegradedCheckIds(
        checks: [AutonomyReadinessCheck],
        availability: AutonomyRemediationAvailability
    ) -> Set<String> {
        var ids: Set<String> = []
        for blocker in checks where blocker.state == .blocker {
            guard let remediation = remediation(forCheckId: blocker.id, state: blocker.state) else {
                continue
            }
            if !hasLiveButton(for: remediation.kind, availability: availability) {
                ids.insert(blocker.id)
            }
        }
        return ids
    }

    /// Classify why a snapshot isn't green. `degradedCheckIds` is the App-supplied set of check ids
    /// whose non-green state is genuinely degraded (missing executable / app / agent bundle, or a
    /// boss-name the operator must change) — the App knows these because the underlying status
    /// (e.g. boss-mcp `executableMissing`, open-at-login `appBundleMissing`) lives above this seam.
    ///
    /// Degraded iff any **blocker** is non-remediable: either in `degradedCheckIds`, or a known
    /// never-remediable id, or an id with no mapping at all. Warnings (a paused Boss Watch, an
    /// unchecked bridge) never force degraded — they're watch points, not walls.
    public static func reason(
        for checks: [AutonomyReadinessCheck],
        degradedCheckIds: Set<String> = []
    ) -> AutonomyReadinessReason {
        let blockers = checks.filter { $0.state == .blocker }
        for blocker in blockers {
            if degradedCheckIds.contains(blocker.id) {
                return .degraded
            }
            if nonRemediableCheckIds.contains(blocker.id) {
                return .degraded
            }
            if remediation(forCheckId: blocker.id, state: blocker.state) == nil {
                return .degraded
            }
        }
        return .oneTapSetup
    }
}

/// View-free calm-vs-loud framing for the TTFA readiness popover (#U9). Decides, per snapshot state
/// + reason, whether the popover leads with calm action-first copy or keeps the loud "cannot recover"
/// wall — without touching the `AutonomyReadinessState` enum or `state(for:)`. The App maps `tone`
/// onto the pill tint and per-check stop-sign-vs-needs-you glyph.
public enum AutonomyReadinessTone: Equatable, Sendable {
    /// Quick user-side setup — soft framing, no octagon, no "cannot recover".
    case calm
    /// Genuinely degraded (missing executable / app / agent bundle) — keep the stop-sign + wall copy.
    case degraded
}

public struct AutonomyReadinessReframedCopy: Equatable, Sendable {
    public var tone: AutonomyReadinessTone
    public var pillText: String
    public var headline: String
    public var detail: String

    public init(tone: AutonomyReadinessTone, pillText: String, headline: String, detail: String) {
        self.tone = tone
        self.pillText = pillText
        self.headline = headline
        self.detail = detail
    }
}

public enum AutonomyReadinessReframe {
    /// Resolve the popover header copy. A `.blocked` snapshot whose blockers are all one-tap toggles
    /// is reframed as calm quick-setup ("N thing(s) to make this hands-off"); a degraded blocker keeps
    /// the loud Core headline/detail. `.attention` / `.ready` always pass the Core copy through calm.
    public static func present(
        state: AutonomyReadinessState,
        checks: [AutonomyReadinessCheck],
        degradedCheckIds: Set<String> = []
    ) -> AutonomyReadinessReframedCopy {
        // Re-derive the Core copy without changing the snapshot: a fresh snapshot off these checks
        // yields the same headline/detail the live snapshot shows, so the degraded path stays faithful.
        let coreCopy = AutonomyReadinessSnapshot(checks: checks)

        switch state {
        case .ready:
            return AutonomyReadinessReframedCopy(
                tone: .calm,
                pillText: "ready",
                headline: coreCopy.headline,
                detail: coreCopy.detail
            )
        case .attention:
            return AutonomyReadinessReframedCopy(
                tone: .calm,
                pillText: "watch",
                headline: coreCopy.headline,
                detail: coreCopy.detail
            )
        case .blocked:
            let blockerCount = checks.filter { $0.state == .blocker }.count
            let reason = AutonomyReadinessReframe.reasonForBlocked(
                checks: checks,
                degradedCheckIds: degradedCheckIds,
                blockerCount: blockerCount
            )
            switch reason {
            case .degraded:
                return AutonomyReadinessReframedCopy(
                    tone: .degraded,
                    pillText: "blocked",
                    headline: coreCopy.headline,
                    detail: coreCopy.detail
                )
            case .oneTapSetup:
                let noun = blockerCount == 1 ? "thing" : "things"
                return AutonomyReadinessReframedCopy(
                    tone: .calm,
                    pillText: "needs you",
                    headline: "\(blockerCount) \(noun) to make this hands-off",
                    detail: "A couple of taps from hands-off — fix each below and the boss can run on its own."
                )
            }
        }
    }

    /// A `.blocked` snapshot with no actual blocker check is defensively treated as calm setup rather
    /// than inventing the wall; otherwise defer to the shared `reason` classifier.
    private static func reasonForBlocked(
        checks: [AutonomyReadinessCheck],
        degradedCheckIds: Set<String>,
        blockerCount: Int
    ) -> AutonomyReadinessReason {
        guard blockerCount > 0 else {
            return .oneTapSetup
        }
        return AutonomyRemediationMapper.reason(for: checks, degradedCheckIds: degradedCheckIds)
    }
}
