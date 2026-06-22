import Foundation

/// THE single readiness contract for the one condition the two readiness systems overlap on:
/// "can the selected boss inspect and control the Workbench?" — i.e. is a valid boss selected
/// AND are the Workbench tools available to it (the boss/MCP-bridge condition).
///
/// Before #U17 the autonomy readiness (`AutonomyReadinessBuilder` → the TTFA popover) and the
/// onboarding readiness (`WorkbenchOnboardingAdvisor` → the opt-in wizard) each judged this
/// condition with their own ad-hoc switch, with no shared evaluator and no test pinning
/// consistency — so the same machine could read `.blocked` in one surface and the warm
/// "a couple of things need you" in the other for the same underlying cause. This contract is
/// the single place that condition is classified; both surfaces derive their boss/bridge
/// rendering from it, so they can never report a contradictory verdict (state) or tone
/// (severity / copy register) for the same fixture.
///
/// Pure and framework-free: it consumes only the boss name + the on-disk MCP-registration
/// snapshot both systems already gather, and emits a `severity` (the shared copy register) plus
/// human-facing label/detail. The two builders adapt this into their own check / repair-step
/// vocabularies WITHOUT re-deriving the verdict.
public enum BossBridgeContract {
    /// The shared severity of the boss/MCP-bridge condition — the one "copy register" both
    /// surfaces must agree on. `blocker` is the loud register ("blocked" / "needs you to finish"),
    /// `warning` is the soft watch-point register (unchecked / paused), `ok` is calm/green.
    ///
    /// This deliberately mirrors `AutonomyReadinessCheckState` so the autonomy builder can map it
    /// 1:1 onto its checks without changing a single user-facing state; the onboarding builder maps
    /// `blocker` onto "surface a repair step" and `ok`/`warning` onto "no repair step needed".
    public enum Severity: String, Equatable, Sendable {
        case ok
        case warning
        case blocker
    }

    /// One classified facet of the boss/bridge condition. The two facets — `boss` (is a valid boss
    /// selected) and `bridge` (are the Workbench tools available to it) — are the exact overlap the
    /// two systems judged independently; classifying them here makes the verdict single-sourced.
    public struct Verdict: Equatable, Sendable {
        /// Stable id matching the autonomy check id (`boss` / `boss-mcp`) so the autonomy builder
        /// adapts without renaming anything the popover / remediation mapper key on.
        public var id: String
        public var label: String
        public var detail: String
        public var severity: Severity

        public init(id: String, label: String, detail: String, severity: Severity) {
            self.id = id
            self.label = label
            self.detail = detail
            self.severity = severity
        }
    }

    /// Classify whether a valid boss is selected. A name that can't be used as an Ouro agent
    /// bundle name is the loud register (the operator must pick a different boss).
    public static func bossVerdict(agentName: String) -> Verdict {
        if BossWorkbenchMCPRegistrar.isValidAgentBundleName(agentName) {
            return Verdict(
                id: "boss",
                label: "Boss agent",
                detail: "\(agentName) is selected.",
                severity: .ok
            )
        }
        return Verdict(
            id: "boss",
            label: "Boss agent",
            detail: "The selected boss name is not a valid Ouro agent bundle name.",
            severity: .blocker
        )
    }

    /// Classify whether the Workbench tools are available to the boss at runtime.
    ///
    /// RUNTIME-INJECTION model: "available" means the Workbench MCP binary is present (runtime
    /// injection works) AND the boss bundle is clean of any stale entry — not that anything is
    /// written into the synced bundle. A `nil` snapshot (not checked yet) is the soft watch-point
    /// register, never the loud one — an unchecked bridge is not a known failure.
    public static func bridgeVerdict(_ registration: BossWorkbenchMCPRegistrationSnapshot?) -> Verdict {
        guard let registration else {
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "Workbench tools availability has not been checked.",
                severity: .warning
            )
        }

        switch registration.status {
        case .registered:
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "Workbench tools are available to \(registration.agentName) at runtime.",
                severity: .ok
            )
        case .notRegistered:
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The Workbench tools binary isn't installed, so \(registration.agentName) can't be connected at runtime. Reinstall Workbench.",
                severity: .blocker
            )
        case .needsUpdate:
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "A stale Workbench entry is left in the boss bundle from an older setup and needs to be cleaned.",
                severity: .blocker
            )
        case .agentMissing:
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The selected boss agent bundle is missing.",
                severity: .blocker
            )
        case .executableMissing:
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The Workbench tools binary is not installed.",
                severity: .blocker
            )
        case .invalidConfig:
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The selected boss agent config cannot be updated safely.",
                severity: .blocker
            )
        case .toolsNotInjected:
            // #F9 — the binary is on disk but the live tools didn't load: an old `ouro`
            // silently stripped them. Name the concrete version target (allowed in human
            // copy) but keep raw CLI verbs out of this lane.
            return Verdict(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "Workbench tools didn't load for \(registration.agentName). Your ouro may be too old — update to ouro alpha.660+, then reopen Workbench.",
                severity: .blocker
            )
        }
    }
}
