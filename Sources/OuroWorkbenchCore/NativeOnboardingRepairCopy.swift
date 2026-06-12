import Foundation

/// The seam-free in-progress copy the Setup Assistant surfaces when an onboarding repair step
/// runs APP-EXECUTED — headless, through a recovery-truth runner — instead of handing the human a
/// raw `ouro …` CLI pane to watch.
///
/// R4b removed the last human-as-hands repair panes: `repair-agent-config` (→ `AgentRepairRunner`)
/// and `check-outward` / `check-inner` (→ `ProviderVerifyRunner`) now execute in-app, the same way
/// the agent-driven onboarding actions do. The ack line the human sees while the runner is working
/// is product copy, so it must NEVER leak a CLI seam — the raw verbs live only in the action-log /
/// audit lane. Keeping this copy (and its app-executed step set) in pure Core lets the seam-free
/// contract be unit-asserted; the SwiftUI Setup Assistant is thin wiring over it.
public enum NativeOnboardingRepairCopy {

    /// The onboarding repair-step IDs that R4b made app-executed — the last steps that used to
    /// spawn a `.trusted` CLI pane for the human. `repair-agent-config` routes to
    /// `AgentRepairRunner`; `check-outward` / `check-inner` route to `ProviderVerifyRunner`.
    public static let appExecutedStepIDs: [String] = [
        "repair-agent-config",
        "check-outward",
        "check-inner",
    ]

    /// The seam-free in-progress line for an app-executed repair step, or `nil` if the step is not
    /// app-executed (the caller then falls through to its own branch — never a fabricated line).
    ///
    /// COHESIVE-PRODUCT CONTRACT: never leaks a CLI seam (`ouro`, `daemon`, `hatch`, `vault`,
    /// `mcp`, a raw `--flag`) or a lane verb. Workbench + the agent are ONE product: "your agent".
    public static func inProgressLine(forStepID stepID: String) -> String? {
        switch stepID {
        case "repair-agent-config":
            return "Getting your agent ready…"
        case "check-outward", "check-inner":
            // Both lanes read the SAME line — the human never sees an "outward"/"inner" lane verb.
            return "Checking your agent's connection…"
        default:
            return nil
        }
    }
}
