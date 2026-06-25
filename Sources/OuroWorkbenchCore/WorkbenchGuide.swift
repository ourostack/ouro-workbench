import Foundation

/// Single source of truth for what Ouro Workbench *is* and how to drive it:
/// keyboard shortcuts, the boss-agent capability set, and the auditable action
/// protocol.
///
/// Everything that needs to describe Workbench to a human or an agent renders
/// from this one catalog so the surfaces never drift apart:
///   - the in-app Keyboard Shortcuts sheet (`ShortcutHelpSheet`),
///   - the `workbench_sense` MCP tool, so the selected boss can answer
///     "how do I switch terminals?" or "what can you do here?",
///   - the inner-agent context file (`WorkbenchContextFile`), so a Claude Code,
///     Codex, Copilot, or shell session launched *inside* Workbench can explain
///     where it is running and what the operator's controls are.
///
/// `docs/guide.md` keeps a hand-maintained mirror of this catalog (its
/// "Workbench MCP exposes" table). It is *not* generated from here, so it can
/// drift; `WorkbenchGuideTests.testGuideDocListsEveryBossTool` guards against
/// that by asserting every `bossTools` tool name appears in the doc.
public enum WorkbenchGuide {
    /// One keyboard shortcut: the key combo and what it does.
    public struct Shortcut: Sendable, Identifiable, Equatable {
        public let keys: String
        public let summary: String
        public var id: String { keys + "\u{1F}" + summary }

        public init(keys: String, summary: String) {
            self.keys = keys
            self.summary = summary
        }
    }

    /// A titled group of shortcuts, with an SF Symbol for the in-app sheet.
    public struct ShortcutCategory: Sendable, Identifiable, Equatable {
        public let id: String
        public let title: String
        public let systemImage: String
        public let shortcuts: [Shortcut]

        public init(id: String, title: String, systemImage: String, shortcuts: [Shortcut]) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.shortcuts = shortcuts
        }
    }

    /// Something the selected Ouro boss can do through the Workbench MCP server.
    public struct Capability: Sendable, Identifiable, Equatable {
        public let tool: String
        public let summary: String
        public var id: String { tool }

        public init(tool: String, summary: String) {
            self.tool = tool
            self.summary = summary
        }
    }

    // MARK: - Catalogs

    /// The complete keyboard map. The in-app sheet and every agent-facing
    /// surface render from this list; edit shortcuts here and nowhere else.
    public static let shortcutCategories: [ShortcutCategory] = [
        ShortcutCategory(
            id: "navigate",
            title: "Navigate",
            systemImage: "arrow.left.arrow.right.circle",
            shortcuts: [
                Shortcut(keys: "⌘1 … ⌘9", summary: "Select the Nth terminal in the current group"),
                Shortcut(keys: "⌘[", summary: "Previous terminal (wraps)"),
                Shortcut(keys: "⌘]", summary: "Next terminal (wraps)"),
                Shortcut(keys: "⇧⌘[", summary: "Previous group"),
                Shortcut(keys: "⇧⌘]", summary: "Next group"),
                Shortcut(keys: "⇧⌘F", summary: "Full-screen the focused terminal (and back)"),
                Shortcut(keys: "⌥⌘→", summary: "Split the focused terminal to the right"),
                Shortcut(keys: "⌥⌘↓", summary: "Split the focused terminal downward"),
                Shortcut(keys: "⌥⌘]", summary: "Focus the other split pane"),
                Shortcut(keys: "⌥⌘W", summary: "Close the focused split pane")
            ]
        ),
        ShortcutCategory(
            id: "boss",
            title: "Boss + Agents",
            systemImage: "person.2.badge.gearshape",
            shortcuts: [
                Shortcut(keys: "⌘I", summary: "Boss Check In"),
                Shortcut(keys: "⌘J", summary: "Jump to the next session that needs you (waiting / needs review / blocked)"),
                Shortcut(keys: "⌘K", summary: "Open the command palette"),
                Shortcut(keys: "⌘K, type 'agent <name>'", summary: "Jump to that agent in the Agents pane"),
                Shortcut(keys: "⌘K, type 'repair'", summary: "Run `ouro check` against the focused agent"),
                Shortcut(keys: "⌘K, type 'manage agents'", summary: "Open the Agents pane on the current boss")
            ]
        ),
        ShortcutCategory(
            id: "terminal",
            title: "Terminal Signals",
            systemImage: "terminal",
            shortcuts: [
                Shortcut(keys: "⌘\u{21A9}", summary: "Launch / Restart the selected terminal"),
                Shortcut(keys: "⌘L", summary: "Send Ctrl-L (redraw)"),
                Shortcut(keys: "⌘.", summary: "Stop the selected terminal"),
                Shortcut(keys: "⌘F", summary: "Find in the focused terminal"),
                Shortcut(keys: "⌘G / ⇧⌘G", summary: "Next / previous match in the search bar"),
                Shortcut(keys: "⌘R", summary: "Rename the selected tab"),
                Shortcut(keys: "⇧⌘R", summary: "Rename the active group"),
                Shortcut(keys: "⌘+ / ⌘=", summary: "Increase terminal font size"),
                Shortcut(keys: "⌘-", summary: "Decrease terminal font size"),
                Shortcut(keys: "⌘0", summary: "Reset terminal font size")
            ]
        ),
        ShortcutCategory(
            id: "app",
            title: "App",
            systemImage: "wand.and.stars",
            shortcuts: [
                Shortcut(keys: "⌘N", summary: "New terminal"),
                Shortcut(keys: "⌘T", summary: "New terminal tab"),
                Shortcut(keys: "⌘O", summary: "Open a workspace file"),
                Shortcut(keys: "⇧⌘S", summary: "Save the current workspace as a file"),
                Shortcut(keys: "⌃⌘B", summary: "Toggle sidebar visibility"),
                Shortcut(keys: "⌘,", summary: "Open Settings"),
                Shortcut(keys: "⇧⌘B", summary: "Report a bug (bundles a screenshot, diagnostics, and recent activity)"),
                Shortcut(keys: "⌘/", summary: "Show the keyboard shortcut help")
            ]
        )
    ]

    /// The Workbench MCP tools the boss gains once the Workbench server is registered with the
    /// selected Ouro agent (#U27: this happens automatically when you pick the boss on Choose Boss,
    /// or via the Connect page's tool-status step). The single source feeding the boss
    /// check-in prompt, `workbench_sense`, and the inner-agent context file, so it
    /// must name EVERY tool the MCP server's `tools/list` advertises and none it
    /// doesn't (#U25). `WorkbenchGuideTests.testBossToolsAreExactlyTheAdvertisedToolSet`
    /// pins set-equality against `advertisedToolNames`, and
    /// `smoke-mcp-tool-catalog.sh` drives the real binary so the server and this
    /// catalog can't drift — adding or removing a tool fails the build/test until
    /// they agree.
    public static let bossTools: [Capability] = [
        Capability(tool: "workbench_status", summary: "read the whole machine workbench state"),
        Capability(tool: OnboardingReadinessReportRenderer.toolName, summary: "read the selected boss's daemon/credential onboarding readiness — ordered steps, each with its remediation"),
        Capability(tool: WorkbenchAutonomyReadinessRenderer.toolName, summary: "read the TTFA autonomy-readiness snapshot — state, per-check fix (boss-queueable verb vs operator one-tap vs degraded), and a 'get to green' ask"),
        Capability(tool: "workbench_sessions", summary: "machine-readable JSON list of sessions (filters: owner / name / attention / includeArchived)"),
        Capability(tool: WorkbenchAttentionQueueRenderer.toolName, summary: "one-call attention queue — only the sessions needing a human, each with its inline waiting-prompt, in triage order"),
        Capability(tool: "workbench_action_result", summary: "poll a request_action's requestId for its outcome (queued / applied / failed)"),
        Capability(tool: "workbench_visibility", summary: "read Workbench + Ouro Work Card visibility with typed unknown/unavailable fields"),
        Capability(tool: "workbench_sense", summary: "reread this sense contract, tools, shortcuts, and action protocol"),
        Capability(tool: "workbench_transcript_tail", summary: "inspect one terminal's recent output"),
        Capability(tool: "workbench_session_health", summary: "read one session's structured health (process, transcript, git, recovery)"),
        Capability(tool: "workbench_search_transcripts", summary: "search remembered terminal output"),
        Capability(tool: "workbench_recovery_drill", summary: "simulate restart recovery"),
        Capability(tool: "workbench_request_action", summary: "queue auditable native actions"),
        Capability(tool: "workbench_create_session", summary: "create and launch an agent-owned coding session"),
        Capability(tool: "workbench_discover_agent_sessions", summary: "discover agent coding sessions running outside Workbench that it could adopt/recover"),
        Capability(tool: "workbench_propose", summary: "show the operator an editable plan and get their ticks/edits/approvals back"),
        Capability(tool: "workbench_proposal_result", summary: "read back the operator's decision for a workbench_propose proposal"),
        Capability(tool: WorkbenchReportBugRenderer.toolName, summary: "report a Workbench defect you hit — anonymized note → the operator's Report a Bug card (text scrubbed; screenshot/diagnostics verbatim, nothing uploaded)")
    ]

    /// The canonical set of tool names the MCP server's `tools/list` advertises —
    /// the contract `bossTools` must cover exactly (#U25). Declared INDEPENDENTLY
    /// of `bossTools` (not derived from it) so the set-equality test is a real
    /// check, not a tautology: a tool added to one catalog but not the other fails
    /// `testBossToolsAreExactlyTheAdvertisedToolSet`. `tools/list` is built in the
    /// MCP executable (which the Core test target can't import), so this constant
    /// is the shared pin — `smoke-mcp-tool-catalog.sh` drives the real binary's
    /// `tools/list` and asserts the live names equal it, closing the loop end to
    /// end so the server and the boss's self-description can never disagree.
    public static let advertisedToolNames: Set<String> = [
        "workbench_status",
        "workbench_onboarding_status",
        "workbench_autonomy_readiness",
        "workbench_sessions",
        "workbench_attention_queue",
        "workbench_action_result",
        "workbench_visibility",
        "workbench_sense",
        "workbench_transcript_tail",
        "workbench_session_health",
        "workbench_search_transcripts",
        "workbench_recovery_drill",
        "workbench_request_action",
        "workbench_create_session",
        "workbench_discover_agent_sessions",
        "workbench_propose",
        "workbench_proposal_result",
        "workbench_report_bug"
    ]

    /// Every action verb the boss may put in an `ouro-workbench-actions` block.
    /// Derived straight from `BossWorkbenchActionKind` so the prompt, the sense,
    /// and the validator can never list a verb the parser won't accept.
    public static let actionVerbs: [String] = BossWorkbenchActionKind.allCases.map(\.rawValue)

    /// Environment variables Workbench sets on every session it launches, so a
    /// terminal agent can detect and describe its host. Documented for agents
    /// and asserted in tests.
    public static let environmentMarkers: [String] = [
        "OURO_WORKBENCH=1",
        "OURO_WORKBENCH_VERSION",
        "OURO_WORKBENCH_CONTEXT_FILE",
        "OURO_WORKBENCH_GROUP",
        "OURO_WORKBENCH_SESSION",
        "OURO_WORKBENCH_BOSS",
        "TERM_PROGRAM=OuroWorkbench"
    ]

    // MARK: - Renderers

    /// Markdown shortcut tables, grouped by category. Used by the sense, the
    /// inner-agent context file, and the docs.
    public static func shortcutsMarkdown() -> String {
        shortcutCategories.map { category in
            let rows = category.shortcuts
                .map { "- `\($0.keys)` — \($0.summary)" }
                .joined(separator: "\n")
            return "### \(category.title)\n\(rows)"
        }
        .joined(separator: "\n\n")
    }

    /// A compact one-line-per-tool capabilities list for prompts.
    public static func capabilitiesMarkdown() -> String {
        bossTools.map { "- \($0.tool): \($0.summary)" }.joined(separator: "\n")
    }

    /// The action-protocol paragraph the boss must follow to make the native
    /// app act, including the verb list and a worked example.
    public static func actionProtocolMarkdown() -> String {
        """
        To make the native app act now, include exactly one fenced JSON block labeled `ouro-workbench-actions`. Supported actions: \(actionVerbs.joined(separator: ", ")). Use a process id from Processes in the `entry` field; names are accepted only when unique.

        ```ouro-workbench-actions
        [{"action":"recover","entry":"PROCESS-ID"},{"action":"sendInput","entry":"PROCESS-ID","text":"continue","appendNewline":true}]
        ```
        """
    }

    /// The full inner-agent context document. Written to Application Support and
    /// pointed at by `OURO_WORKBENCH_CONTEXT_FILE` so a session launched inside
    /// Workbench can answer "what am I running in?" by reading one file.
    public static func innerAgentContext(version: String, boss: String?) -> String {
        let bossLine = boss.map {
            "A selected Ouro boss agent (`\($0)`) watches every session in this machine and can act on them."
        } ?? "A selected Ouro boss agent watches every session in this machine and can act on them."
        return """
        # You are running inside Ouro Workbench

        Ouro Workbench is a native macOS workbench for terminal/TUI agents (v\(version)). It wraps Claude Code, GitHub Copilot CLI, OpenAI Codex, and arbitrary terminal sessions, giving them durable workspace state, restart recovery, and a selectable Ouro boss agent that coordinates the machine. This terminal session was launched by Workbench.

        ## How to confirm your host

        Workbench sets these environment variables on every session it launches:

        \(environmentMarkers.map { "- `\($0)`" }.joined(separator: "\n"))

        `cat "$OURO_WORKBENCH_CONTEXT_FILE"` re-reads this document. `OURO_WORKBENCH_GROUP` and `OURO_WORKBENCH_SESSION` name the group and terminal you live in.

        ## What Workbench gives the operator

        - A cmux-style sidebar of named groups, each holding any number of terminal tabs.
        - Restart recovery: sessions are reattached after an app or computer restart wherever possible.
        - A boss/Ouro dashboard that summarizes what is going on and what is waiting on the human.

        ## Keyboard shortcuts (for the human operating Workbench)

        \(shortcutsMarkdown())

        ## The boss agent

        \(bossLine) Through the Workbench MCP server it can:

        \(capabilitiesMarkdown())

        If you stop at a prompt and the operator has marked this session trusted, the boss may answer it for you, using the session friend's known preferences — but never for destructive or secret prompts (those always wait for a human). Every such decision is recorded in the operator's Boss Decision Log. If a prompt must be answered by a human, make that explicit in your prompt text.

        ## If asked "what am I running in?"

        You are a terminal agent inside Ouro Workbench. You keep doing your own job (coding, answering, running commands); Workbench is the room you run in, observes your output, recovers you after restarts, and lets a boss agent take auditable actions on your session.
        """
    }
}
