import Foundation

/// Derives `AutonomyRemediationAvailability` — whether each one-tap fix actuator has live work —
/// from pure workspace inputs, so the boss-facing `workbench_autonomy_readiness` sensor classifies
/// fix vs degraded with the SAME runtime gate the operator's in-app popover uses (#U20).
///
/// The App computes the same fields off its live view-model (`untrustedAutonomyAgentEntries`,
/// `resumableDisabledAutonomyAgentEntries`, `recoverableEntries`, `bossWatchIsEnabled`). This
/// Core builder mirrors that derivation from `(state, summary, registration)` so the MCP sensor
/// and the popover never disagree about whether a blocker has a tappable fix.
///
/// `loginItemActionable` has no Core/MCP signal (the login-item status lives above this seam) and
/// `open-at-login` isn't one of the checks `AutonomyReadinessBuilder.build` emits, so it defaults
/// `true` — the readout never surfaces that check, so the field is inert here.
public struct AutonomyRemediationAvailabilityBuilder: Sendable {
    public init() {}

    public func availability(
        state: WorkspaceState,
        summary: WorkspaceSummary,
        mcpRegistration: BossWorkbenchMCPRegistrationSnapshot?
    ) -> AutonomyRemediationAvailability {
        let agentEntries = state.processEntries.filter { !$0.isArchived && $0.kind == .terminalAgent }

        let hasUntrusted = agentEntries.contains { $0.trust != .trusted }

        let hasResumableDisabled = agentEntries.contains { entry in
            guard !entry.autoResume else { return false }
            guard let agentKind = TerminalAgentDetector.detect(entry: entry),
                  let preset = TerminalAgentPresets.preset(for: agentKind) else {
                return false
            }
            return preset.resumeStrategy.kind != .manual
        }

        let hasRecoverable = summary.recoveryPlans.contains { plan in
            plan.action == .reattach || plan.action == .autoResume || plan.action == .respawn
        }

        return AutonomyRemediationAvailability(
            hasUntrustedTerminals: hasUntrusted,
            hasResumableDisabledTerminals: hasResumableDisabled,
            mcpRegistrationActionable: mcpRegistration?.isActionable == true,
            hasRecoverableEntries: hasRecoverable,
            bossWatchDisabled: !state.bossWatchEnabled,
            loginItemActionable: true
        )
    }
}
