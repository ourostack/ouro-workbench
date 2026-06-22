import Foundation

/// The outcome of running a headless `ouro clone …` plan.
///
/// `.launchFailed` means the process could not be started at all (nothing was cloned);
/// `.timedOut` means the 120s watchdog fired and TERMINATED a wedged child (a distinct cause from
/// a real non-zero git failure — see the F7 gap #3 / B-1 note on `CloneOutcomeClassifier`);
/// `.exited(code:)` carries the real `ouro clone` exit status. The App folds this into
/// `CloneOutcomeClassifier.classifyClone`.
///
/// F7 — `CloneAgentRunner.runHeadless` used to THROW `CloneFailedError` on any non-zero exit and
/// silently kill-then-throw on a watchdog timeout, so the App mapped EVERY failure (including a
/// 120s wedge) to "Check the Git remote" — the wrong cause. The runner now REPORTS the outcome so
/// the classifier can name the real cause honestly.
public enum CloneRunResult: Equatable, Sendable {
    /// The clone process ran and exited with `code` (0 = clean, non-zero = git/`ouro` failure).
    case exited(code: Int32)
    /// The 120s watchdog fired: the child was wedged and got terminated. Distinct from a real
    /// non-zero exit — matched on the ENUM CASE before any `code == 0` test so the two can never
    /// be confused (B-1).
    case timedOut
    /// The process could not be launched at all (e.g. `env` can't resolve the command).
    case launchFailed

    /// The exit code for an `.exited` run, or `nil` for `.timedOut` / `.launchFailed` (no clean
    /// exit observed). The classifier matches `.timedOut` / `.launchFailed` on the case directly;
    /// this accessor exists for parity with `ColdStartRunResult.exitCode`.
    public var exitCode: Int32? {
        switch self {
        case let .exited(code):
            return code
        case .timedOut, .launchFailed:
            return nil
        }
    }

    /// True iff the 120s watchdog fired (a wedged child was terminated). The App reads this only
    /// for clarity; classification keys off the case directly.
    public var watchdogTimedOut: Bool {
        switch self {
        case .timedOut:
            return true
        case .exited, .launchFailed:
            return false
        }
    }
}

/// Why a clone could not be reported as ready. Carries a stable `rawValue` for the audit log (NOT
/// human copy — `CloneOutcome.humanFacingLine` is the human surface).
public enum CloneFailureReason: String, Equatable, Sendable {
    /// The `ouro clone` process could not be launched at all.
    case cloneLaunchError
    /// `ouro clone` ran but exited non-zero — a real git/remote failure (gap #3 cause). This is the
    /// ONLY reason whose human copy blames the Git remote.
    case cloneNonZeroExit
    /// The 120s watchdog fired and terminated a wedged clone. Distinct copy from `cloneNonZeroExit`
    /// (the clone took too long, not "the remote is wrong").
    case timedOut
    /// `ouro clone` exited 0 but produced no usable bundle — `agent.json` is missing (gap #2).
    case invalidMissingAgentJson
    /// `ouro clone` exited 0 with a present bundle, but the post-clone probe could not confirm the
    /// agent is usable (network-unreachable, indeterminate output, or the probe itself timed out).
    case couldNotConfirm
}

/// The honest classification of a headless-clone attempt.
///
/// `.ready` — cloned and verified working. `.needsVaultUnlock` — cloned, but its provider isn't
/// connected yet (the bundle exists; the human still needs to unlock its vault / re-enter the
/// credential — routed to F6's `beginCredentialRotation`). `.failed` — the clone could not be
/// completed/confirmed. This is the value that replaces the old unconditional `.succeeded`.
public enum CloneOutcome: Equatable, Sendable {
    case ready
    case needsVaultUnlock
    case failed(reason: CloneFailureReason)

    /// A stable, non-human audit token for this outcome (for the action log's `result:` line — NOT
    /// a human surface). `humanFacingLine` is the human copy.
    public var auditReason: String {
        switch self {
        case .ready:
            return "ready"
        case .needsVaultUnlock:
            return "needsVaultUnlock"
        case let .failed(reason):
            return reason.rawValue
        }
    }

    /// Seam-free human copy for the clone result. Names the agent; never leaks `ouro`/`clone`/
    /// `vault`/argv flags. ONLY the `.cloneNonZeroExit` line blames the Git remote — that's the one
    /// cause where the remote is the likely culprit. A 120s wedge gets its own honest line (gap #3).
    public func humanFacingLine(agentName: String) -> String {
        switch self {
        case .ready:
            return "\(agentName) is connected and ready."
        case .needsVaultUnlock:
            return "\(agentName) was cloned, but its provider isn't connected yet — "
                + "Workbench will help you finish setup."
        case let .failed(reason):
            switch reason {
            case .cloneLaunchError:
                return "Workbench couldn't start cloning \(agentName). Please try again."
            case .cloneNonZeroExit:
                // The ONLY "Git remote" copy — a real non-zero clone is most often a remote problem.
                return "Couldn't clone \(agentName). Check the Git remote and try again."
            case .timedOut:
                return "Cloning \(agentName) took too long and was stopped. "
                    + "Check your network or the remote's size, then try again."
            case .invalidMissingAgentJson:
                return "\(agentName) didn't finish cloning — its configuration is missing. "
                    + "Please try again."
            case .couldNotConfirm:
                return "\(agentName) was cloned, but Workbench couldn't confirm it's connected. "
                    + "Please check your details and try again."
            }
        }
    }
}

/// Classifies a headless-clone run into an honest `CloneOutcome`. PURE: no I/O, fully unit-tested,
/// so the App wiring stays a thin fold from `runHeadless` + a bundle check + a probe into a
/// side-effect branch. Mirrors `ProviderConfigForm.classifyColdStart` /
/// `VaultOnboardingMachine.afterVaultTerminal`.
///
/// SAFETY INVARIANT (load-bearing): a clean exit ALONE is NEVER `.ready`. `.ready` requires
/// `agentJsonPresent == true` AND `checkVerdict == .working`. Anything short of that is
/// `.needsVaultUnlock` (the bundle exists but isn't connected) or a `.failed` reason — never a
/// false green. `.timedOut` / `.launchFailed` are matched on the ENUM CASE BEFORE any `code == 0`
/// test, so a watchdog kill can never collide with a real git-failure exit (B-1).
public enum CloneOutcomeClassifier {
    /// - `runResult`: the runner's reported outcome (exited / timed-out / launch-failed).
    /// - `agentJsonPresent`: whether `~/AgentBundles/<name>.ouro/agent.json` exists AFTER a clean
    ///   exit (only meaningful on `.exited(code: 0)`; the App reads it solely on that arm).
    /// - `checkVerdict`: the `ProviderCheckClassifier` verdict for the configured lane, or `nil`
    ///   when the probe timed out / couldn't run.
    public static func classifyClone(
        runResult: CloneRunResult,
        agentJsonPresent: Bool,
        checkVerdict: ProviderConnectionVerdict?
    ) -> CloneOutcome {
        switch runResult {
        case .launchFailed:
            // Never launched — nothing was cloned, regardless of any later state.
            return .failed(reason: .cloneLaunchError)
        case .timedOut:
            // B-1 / gap #3: matched on the CASE before any `code == 0` test. A 120s wedge gets its
            // OWN reason — never "Check the Git remote".
            return .failed(reason: .timedOut)
        case let .exited(code):
            // gap #3: a real non-zero clone is the only "Check the Git remote" cause.
            guard code == 0 else {
                return .failed(reason: .cloneNonZeroExit)
            }
            // gap #2: a clean exit that produced no bundle is NOT success.
            guard agentJsonPresent else {
                return .failed(reason: .invalidMissingAgentJson)
            }
            // gap #1: a clean clone with a present bundle — the truth is now entirely the probe's.
            switch checkVerdict {
            case .working:
                return .ready
            case .vaultLocked, .unauthorized:
                // The bundle exists but its provider isn't connected — route to finish setup.
                return .needsVaultUnlock
            case .unreachable, .indeterminate, nil:
                // Can't positively confirm (network down, ambiguous output, or probe timed out).
                return .failed(reason: .couldNotConfirm)
            }
        }
    }
}

/// Pure path convention for a cloned agent's `agent.json`. The App injects `~/AgentBundles` as the
/// root; this keeps the `<root>/<name>.ouro/agent.json` shape unit-tested in Core (mirrors
/// `OuroAgentInventory`'s `<bundle>.ouro/agent.json` convention).
public enum CloneBundleLocator {
    public static func agentJsonPath(agentName: String, agentBundlesRoot: URL) -> String {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return agentBundlesRoot
            .appendingPathComponent("\(trimmed).ouro", isDirectory: true)
            .appendingPathComponent("agent.json")
            .path
    }
}
