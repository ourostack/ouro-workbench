import Foundation

/// What kind of fix a non-green readiness check has, in boss-relayable terms (#U20).
///
/// The boss is a SENSOR, not a hand for these: `bossAction` means the boss can queue the
/// fix itself over `workbench_request_action`; `operatorOneTap` means the operator has a
/// one-tap fix in the in-app TTFA popover (U9) that the boss should RELAY, not perform
/// (Boss Watch / open-at-login); `degraded` means neither — a missing executable / app /
/// agent bundle, or a boss-name the operator must change, that needs real setup work.
public enum AutonomyReadinessFixKind: String, Codable, Equatable, Sendable {
    /// The boss can queue this fix itself via `workbench_request_action` (`bossAction` carries the verb).
    case bossAction
    /// The operator has a one-tap fix in the TTFA popover; the boss relays the ask (no boss verb).
    case operatorOneTap
    /// Genuinely degraded — neither a boss verb nor a one-tap toggle clears it.
    case degraded
}

/// The boss-relayable fix for one non-green check: a plain-language `summary` (no enum/jargon),
/// the `kind` (boss-queueable vs operator one-tap vs degraded), and — when the boss can act —
/// the `bossAction` `workbench_request_action` verb to queue.
public struct AutonomyReadinessFix: Codable, Equatable, Sendable {
    public var summary: String
    public var kind: AutonomyReadinessFixKind
    /// The `workbench_request_action` verb the boss queues for a `.bossAction` fix; omitted otherwise.
    public var bossAction: String?

    public init(summary: String, kind: AutonomyReadinessFixKind, bossAction: String? = nil) {
        self.summary = summary
        self.kind = kind
        self.bossAction = bossAction
    }
}

/// One check in the boss-facing readout: the raw check fields the boss can read,
/// plus a `fix` for every non-green check (absent on `.ok` checks).
public struct AutonomyReadinessReadoutCheck: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var state: String
    public var detail: String
    public var fix: AutonomyReadinessFix?

    public init(id: String, title: String, state: String, detail: String, fix: AutonomyReadinessFix? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
    }
}

/// The structured TTFA autonomy-readiness readout a boss reads over MCP (#U20). A legible
/// mirror of the operator's in-app readiness popover: overall state, per-check status, and —
/// for each non-green check — whether a one-tap operator fix exists (and whether the BOSS can
/// queue it) vs a degraded condition needing something else, plus a single human-relayable
/// "to get to green" summary the boss can hand the operator verbatim.
///
/// READ-ONLY sensor: this readout names the fixes but performs none of them. The boss queues
/// the `bossAction` verbs itself via `workbench_request_action`; it RELAYS the operator one-tap
/// asks (pointing at the in-app readiness popover) rather than acting on them.
public struct AutonomyReadinessReadout: Codable, Equatable, Sendable {
    /// Boss-legible overall state: `ready` | `watch` | `blocked` (no raw `attention` enum leak).
    public var state: String
    /// Plain headline (the same calm headline the operator's popover leads with).
    public var headline: String
    /// The single human-relayable line the boss can hand the operator: "Hands-off ready" when
    /// green, otherwise "To get to green, the operator needs to: …" naming each non-green fix.
    public var summary: String
    public var blockerCount: Int
    public var warningCount: Int
    public var checks: [AutonomyReadinessReadoutCheck]
    /// Where the operator clears the one-tap fixes — pointed at so the boss can relay it.
    public var operatorFixLocation: String

    public init(
        state: String,
        headline: String,
        summary: String,
        blockerCount: Int,
        warningCount: Int,
        checks: [AutonomyReadinessReadoutCheck],
        operatorFixLocation: String
    ) {
        self.state = state
        self.headline = headline
        self.summary = summary
        self.blockerCount = blockerCount
        self.warningCount = warningCount
        self.checks = checks
        self.operatorFixLocation = operatorFixLocation
    }
}

/// Pure, view-free transform from an `AutonomyReadinessSnapshot` (+ live remediation
/// availability) to the boss-facing `AutonomyReadinessReadout` the `workbench_autonomy_readiness`
/// MCP tool returns. The MCP-renderer seam (sibling to `WorkbenchSessionsRenderer`): no I/O, so
/// it's unit-tested in Core and reused by the read-only sensor tool.
///
/// It reuses `AutonomyRemediationMapper` (U9) so the boss sees the SAME per-check intent the
/// operator's popover surfaces, then layers the boss-vs-operator distinction on top: a one-tap
/// remediation the boss can queue over `workbench_request_action` is a `.bossAction` (with the
/// verb); a one-tap the operator must perform (Boss Watch / open-at-login) is `.operatorOneTap`;
/// a blocker with no live fix is `.degraded`.
public struct WorkbenchAutonomyReadinessRenderer {
    /// The MCP tool name — single-sourced here so the dispatch, the tool definition, and the
    /// boss-tools catalog can't drift.
    public static let toolName = "workbench_autonomy_readiness"

    /// The tool description the boss reads in `tools/list`. Names the blocker→`request_action`
    /// verb mapping so the boss knows which fixes it can queue itself.
    public static let toolDescription = """
        Read the boss's own TTFA autonomy-readiness snapshot — the rolled-up "is hands-off operation ready, and what's blocking it" verdict the operator sees in the in-app readiness popover (a sensor, NOT a hand: this tool changes nothing). Returns {state(ready|watch|blocked),headline,summary,blockerCount,warningCount,operatorFixLocation,checks:[{id,title,state(ok|warning|blocker),detail,fix?}]}. For each non-green check, `fix` is {summary,kind,bossAction?} where kind is one of: bossAction (you can queue it yourself via workbench_request_action — `bossAction` carries the verb: terminal-trust→setTrust, terminal-resume→setAutoResume, boss-mcp→registerWorkbenchMCP, recovery→recover), operatorOneTap (a one-tap fix only the operator can do in the popover, e.g. Boss Watch — relay the ask, don't act), or degraded (genuinely needs setup — a missing executable/app/agent bundle or a boss-name the operator must change). `summary` is one human-relayable "To get to green, the operator needs to: …" sentence you can hand the operator verbatim. After you queue a bossAction fix, re-read this tool to confirm the check turned green.
        """

    /// Where the operator clears the one-tap fixes; relayed to the boss so it can point the human.
    public static let operatorFixLocation = "the TTFA readiness popover (the autonomy pill in the Workbench header)"

    public init() {}

    public func readout(
        snapshot: AutonomyReadinessSnapshot,
        availability: AutonomyRemediationAvailability,
        degradedCheckIds: Set<String> = []
    ) -> AutonomyReadinessReadout {
        let checks = snapshot.checks.map { check in
            AutonomyReadinessReadoutCheck(
                id: check.id,
                title: check.label,
                state: check.state.rawValue,
                detail: check.detail,
                fix: fix(for: check, availability: availability, degradedCheckIds: degradedCheckIds)
            )
        }
        return AutonomyReadinessReadout(
            state: Self.bossState(for: snapshot.state),
            headline: snapshot.headline,
            summary: summary(for: snapshot, checks: checks),
            blockerCount: snapshot.blockerCount,
            warningCount: snapshot.warningCount,
            checks: checks,
            operatorFixLocation: Self.operatorFixLocation
        )
    }

    /// Boss-legible overall state — never the raw `attention` enum the boss shouldn't have to decode.
    private static func bossState(for state: AutonomyReadinessState) -> String {
        switch state {
        case .ready:
            return "ready"
        case .attention:
            return "watch"
        case .blocked:
            return "blocked"
        }
    }

    /// The boss-relayable fix for one check. `.ok` checks carry none. A non-green check whose
    /// abstract remediation the runtime gate would suppress (or which is in `degradedCheckIds`,
    /// or never-remediable) is `.degraded`. Otherwise it's a one-tap fix, split into a boss verb
    /// (`.bossAction`) vs an operator-only toggle (`.operatorOneTap`).
    private func fix(
        for check: AutonomyReadinessCheck,
        availability: AutonomyRemediationAvailability,
        degradedCheckIds: Set<String>
    ) -> AutonomyReadinessFix? {
        guard check.state != .ok else {
            return nil
        }
        guard let remediation = AutonomyRemediationMapper.remediation(forCheckId: check.id, state: check.state) else {
            return AutonomyReadinessFix(summary: Self.degradedSummary(for: check.id, state: check.state), kind: .degraded)
        }
        let suppressed = !AutonomyRemediationMapper.hasLiveButton(for: remediation.kind, availability: availability)
        if suppressed || degradedCheckIds.contains(check.id) {
            return AutonomyReadinessFix(summary: Self.degradedSummary(for: check.id, state: check.state), kind: .degraded)
        }
        let summary = Self.fixSummary(for: remediation.kind)
        if let verb = Self.bossActionVerb(for: remediation.kind) {
            return AutonomyReadinessFix(summary: summary, kind: .bossAction, bossAction: verb)
        }
        return AutonomyReadinessFix(summary: summary, kind: .operatorOneTap)
    }

    /// The `workbench_request_action` verb that clears a remediation kind, or `nil` when the fix is
    /// an operator-only in-app toggle the boss should relay (Boss Watch / open-at-login).
    private static func bossActionVerb(for kind: AutonomyRemediationKind) -> String? {
        switch kind {
        case .trustTerminals:
            return "setTrust"
        case .enableResume:
            return "setAutoResume"
        case .connectTools:
            return "registerWorkbenchMCP"
        case .recover:
            return "recover"
        case .enableWatch, .openAtLogin:
            return nil
        }
    }

    /// Plain-language, relayable fix for each remediation kind — no enum/jargon, never empty.
    /// One total mapping over every kind (boss-queueable and operator-only alike); the
    /// boss-vs-operator split is the `bossActionVerb` presence, so no arm is structurally dead.
    private static func fixSummary(for kind: AutonomyRemediationKind) -> String {
        switch kind {
        case .trustTerminals:
            return "Trust the agent terminals so the boss may drive them."
        case .enableResume:
            return "Turn on automatic resume so the terminals come back after a restart."
        case .connectTools:
            return "Connect the boss to the Workbench tools."
        case .recover:
            return "Recover the sessions waiting on a restart."
        case .enableWatch:
            return "Turn Boss Watch on so the boss runs hands-off."
        case .openAtLogin:
            return "Let Workbench open at login so recovery survives a reboot."
        }
    }

    /// Plain-language degraded condition the boss can describe but not clear. The `terminal-*`
    /// checks are a `.warning` only in the "no agent terminals open yet" state — a watch point, not
    /// a wall — so that case reads as a calm "nothing to do until terminals exist" rather than the
    /// blocker copy (a `.manual`-strategy / unflippable-trust wall).
    private static func degradedSummary(for checkId: String, state: AutonomyReadinessCheckState) -> String {
        switch checkId {
        case "boss":
            return "Pick a valid Ouro boss agent — the current selection isn't a usable bundle."
        case "executables":
            return "Install the missing terminal command — it isn't on PATH."
        case "boss-mcp":
            return "Reinstall Workbench — the boss-tools binary is missing or the bundle needs repair."
        case "open-at-login":
            return "Reinstall Workbench — the app bundle can't be registered to open at login."
        case "recovery":
            return "These sessions need a manual restart the boss can't queue."
        case "terminal-resume":
            return state == .warning
                ? "Open an agent terminal — there's nothing to set a resume strategy on yet."
                : "These terminals have no automatic resume strategy to turn on."
        case "terminal-trust":
            return state == .warning
                ? "Open an agent terminal — there's nothing to trust yet."
                : "No agent terminals are open to trust."
        case "boss-watch":
            return "Boss Watch can't be turned on from here right now."
        default:
            return "This needs setup beyond a one-tap fix."
        }
    }

    /// The single human-relayable "to get to green" line. Green → a calm hands-off-ready line;
    /// otherwise "To get to green, the operator needs to: …" joining each non-green fix's plain
    /// summary (blockers first), so the boss hands the operator one sentence with no jargon.
    ///
    /// Every non-green check carries a fix and every fix summary is non-empty, so a non-ready
    /// snapshot always yields at least one ask — no empty-string fallback is reachable here.
    private func summary(for snapshot: AutonomyReadinessSnapshot, checks: [AutonomyReadinessReadoutCheck]) -> String {
        guard snapshot.state != .ready else {
            return "Hands-off ready — the boss can inspect, drive, and recover the Workbench with no human in the loop."
        }
        // Blockers (the hardest stops) lead the relayable line; warnings follow. A stable
        // partition keeps each group in check order.
        let blockerAsks = checks.compactMap { $0.state == "blocker" ? $0.fix?.summary : nil }
        let warningAsks = checks.compactMap { $0.state == "warning" ? $0.fix?.summary : nil }
        return "To get to green, the operator needs to: " + (blockerAsks + warningAsks).joined(separator: " ")
    }
}
