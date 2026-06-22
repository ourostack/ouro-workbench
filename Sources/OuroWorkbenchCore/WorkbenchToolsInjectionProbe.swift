import Foundation

/// The verdict of asking a live boss `mcp-serve` process *"did you actually inject the
/// `workbench_*` tools?"* — the missing check that #F9 adds. An `alpha.660+` runtime
/// spawned with `--workbench-mcp` injects the `workbench_*` catalog into its
/// `tools/list`; an older runtime silently ignores the flag and answers with only the
/// boss's native ouro tools. `.absent` is that silent-strip — the boss reads "registered"
/// on disk yet can drive nothing in Workbench.
public enum WorkbenchToolsInjection: String, Equatable, Sendable {
    /// ≥1 advertised `workbench_*` tool appeared in the live `tools/list`.
    case present
    /// `tools/list` answered, but ZERO advertised tools — the silent-strip.
    case absent
}

/// The outcome of running the `tools/list` injection probe at the handoff edge (#F9). The
/// distinction between a CONFIRMED verdict and an UNCONFIRMED one is load-bearing: only a
/// confirmed `.absent` is the hard "tools stripped" blocker; a probe that couldn't answer
/// (timeout / spawn error) is `.unconfirmed` and must NEVER block — a slow cold start must
/// not false-report "your ouro is too old".
public enum WorkbenchToolsInjectionProbeOutcome: Equatable, Sendable {
    /// The `tools/list` answered and yielded a definite verdict.
    case confirmed(WorkbenchToolsInjection)
    /// The probe could not produce a verdict (timeout / process error). Treat as
    /// `.absent`-but-UNCONFIRMED: stay awaiting, never a blocker.
    case unconfirmed
}

/// Pure, framework-free verdict + parse for the `tools/list` injection probe (#F9 Seam A).
/// No live process here — `BossAgentMCPClient.listToolNames` does the spawn and feeds the
/// answer line into `toolNames(fromToolsListJSON:)`, then `verdict(fromToolNames:)`.
public enum WorkbenchToolsInjectionProbe {

    /// Pure verdict from the tool names a live `tools/list` returned. `.present` iff at
    /// least one name is in `WorkbenchGuide.advertisedToolNames` — the canonical set the
    /// MCP server's `tools/list` is pinned to (and `smoke-mcp-tool-catalog.sh` asserts
    /// against). Reusing that set (rather than a hand-rolled `hasPrefix("workbench_")`)
    /// keeps the probe locked to the same single source as the catalog and stays robust
    /// if a non-`workbench_`-prefixed tool is ever advertised.
    public static func verdict(fromToolNames names: [String]) -> WorkbenchToolsInjection {
        for name in names where WorkbenchGuide.advertisedToolNames.contains(name) {
            return .present
        }
        return .absent
    }

    /// Tolerant parse of a raw JSON-RPC `tools/list` response line → the advertised tool
    /// names it carries. Any malformed / error / empty shape yields `[]` (which the
    /// verdict reads as `.absent` ⇒ not ready). Nameless or non-object tool entries are
    /// skipped rather than failing the whole parse.
    public static func toolNames(fromToolsListJSON line: String) -> [String] {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let result = object["result"] as? [String: Any],
              let tools = result["tools"] as? [Any] else {
            return []
        }
        var names: [String] = []
        for entry in tools {
            guard let tool = entry as? [String: Any],
                  let name = tool["name"] as? String else {
                continue
            }
            names.append(name)
        }
        return names
    }
}
