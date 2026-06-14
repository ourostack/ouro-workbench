import Foundation

public enum OnboardingRepairActor: String, Codable, Equatable, Sendable {
    case agentRunnable = "agent-runnable"
    case humanRequired = "human-required"
    case humanChoice = "human-choice"
}

public enum OnboardingReadinessState: String, Codable, Equatable, Sendable {
    case ready
    case needsAgent
    case needsDaemon
    case needsCredentials
    case needsRepair
}

public struct OnboardingRepairStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var actor: OnboardingRepairActor
    public var title: String
    public var detail: String
    public var command: [String]

    public init(
        id: String,
        actor: OnboardingRepairActor,
        title: String,
        detail: String,
        command: [String] = []
    ) {
        self.id = id
        self.actor = actor
        self.title = title
        self.detail = detail
        self.command = command
    }

    public var commandLine: String? {
        command.isEmpty ? nil : ShellArgumentEscaper.commandLine(command)
    }

    /// Whether this step is a provider-setup step the UI routes to the NATIVE provider form
    /// (the one human gate) rather than a `ouro connect providers` `.trusted` pane. These are
    /// the steps Slice 3 redirected away from pane-spawning: the cold-start credential gate
    /// (`request-provider-config`) and the existing-agent lane-completion steps
    /// (`outward-lane` / `inner-lane` — the documented existing-agent gap).
    public var isProviderSetup: Bool {
        id == "request-provider-config" || id == "outward-lane" || id == "inner-lane"
    }
}

public enum OnboardingProviderCheckState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case passed
    case failed
}

public struct OnboardingProviderCheckResult: Codable, Equatable, Sendable {
    public var lane: String
    public var state: OnboardingProviderCheckState
    public var detail: String

    public init(lane: String, state: OnboardingProviderCheckState, detail: String) {
        self.lane = lane
        self.state = state
        self.detail = detail
    }
}

public struct OnboardingReadiness: Codable, Equatable, Sendable {
    public var state: OnboardingReadinessState
    public var headline: String
    public var detail: String
    public var selectedBossName: String
    public var repairSteps: [OnboardingRepairStep]

    public init(
        state: OnboardingReadinessState,
        headline: String,
        detail: String,
        selectedBossName: String,
        repairSteps: [OnboardingRepairStep]
    ) {
        self.state = state
        self.headline = headline
        self.detail = detail
        self.selectedBossName = selectedBossName
        self.repairSteps = repairSteps
    }

    public var isReady: Bool {
        state == .ready
    }
}

/// Renders an `OnboardingReadiness` snapshot as the structured text the
/// `workbench_onboarding_status` read MCP tool returns: state + selected boss + ordered,
/// numbered repair steps with actor tags + an audit-history lane that carries the raw
/// recovery verbs.
///
/// Pure and free of I/O so the MCP executable (which has no test target of its own) can
/// delegate both the rendering and the agent-facing tool description here and have them
/// unit-tested from `OuroWorkbenchCoreTests`.
public struct OnboardingReadinessReportRenderer: Sendable {
    /// The published MCP tool name.
    public static let toolName = "workbench_onboarding_status"

    /// The agent-facing tool description.
    ///
    /// CONTRACT (load-bearing): the action queue behind `workbench_request_action` is
    /// asynchronous and polled (~2s), so an enqueue acknowledgement proves only that the
    /// request was *accepted*, never that the remediation *succeeded*. The agent MUST narrate
    /// outcomes from the NEXT `workbench_onboarding_status` read — never from a
    /// `workbench_request_action` enqueue ack — or it will report "done" off an action that
    /// has not run yet. This sentence is asserted by a test so it cannot silently drift.
    public static let toolDescription = """
    Read the daemon- and credential-aware onboarding readiness of the selected boss agent: \
    the current readiness state, an ordered list of repair steps (each tagged with its actor — \
    agent-runnable, human-required, or human-choice), and an audit history of the underlying \
    recovery commands. This is a read-only inspection tool. IMPORTANT: any remediation you \
    queue via workbench_request_action is applied asynchronously by the native app (the action \
    queue is polled roughly every 2 seconds), so the enqueue acknowledgement only confirms the \
    request was accepted — it does NOT mean the action completed. Always narrate progress and \
    outcomes from the NEXT workbench_onboarding_status read, never from a workbench_request_action \
    enqueue acknowledgement.
    """

    public init() {}

    public func render(_ readiness: OnboardingReadiness) -> String {
        var lines: [String] = []
        lines.append("# workbench onboarding status")
        lines.append("state: \(readiness.state.rawValue)")
        lines.append("boss: \(readiness.selectedBossName)")
        lines.append(readiness.headline)
        lines.append(readiness.detail)
        lines.append("")

        if readiness.repairSteps.isEmpty {
            lines.append("repair steps: none — no remediation needed.")
        } else {
            lines.append("repair steps (apply in order):")
            for (index, step) in readiness.repairSteps.enumerated() {
                lines.append("\(index + 1). [\(step.actor.rawValue)] \(step.title): \(step.detail)")
            }
        }
        lines.append("")

        lines.append("audit history (recovery commands — debug lane, not human-facing):")
        let auditableSteps = readiness.repairSteps.filter { $0.commandLine != nil }
        if auditableSteps.isEmpty {
            lines.append("- none")
        } else {
            for step in auditableSteps {
                lines.append("- \(step.id): \(step.commandLine ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct WorkbenchOnboardingAdvisor: Sendable {
    public init() {}

    /// Compute onboarding readiness.
    ///
    /// Pure and synchronous: the daemon-liveness signal (Slice 0's `DaemonLiveness`) is
    /// passed IN already-resolved, and the credential signal is derived synchronously from
    /// the selected agent's `humanFacing` / `agentFacing` lanes. This type never performs
    /// I/O — callers run the probe / inventory scan and hand the results here.
    ///
    /// Precedence: daemon-down is the top gate (you cannot act through a daemon that is not
    /// serving — not even to repair an agent), so it short-circuits every other check.
    /// `daemonLiveness` defaults to `.up` so existing callers keep compiling.
    ///
    /// `.needsCredentials` (no usable lane at all) is COMPLEMENTARY to `providerChecks`
    /// (which live-checks a *configured* lane and can fail it): the two never overlap, because
    /// an agent with no usable lane never reaches the per-lane `providerChecks` path.
    public func readiness(
        boss: BossAgentSelection,
        agents: [OuroAgentRecord],
        mcpRegistration: BossWorkbenchMCPRegistrationSnapshot?,
        providerChecks: [String: OnboardingProviderCheckResult] = [:],
        daemonLiveness: DaemonLiveness = .up
    ) -> OnboardingReadiness {
        if daemonLiveness == .down {
            return OnboardingReadiness(
                state: .needsDaemon,
                headline: "Bringing Workbench online",
                detail: "Your agent isn't responding yet. Workbench will wake it for you — no action needed on your part.",
                selectedBossName: boss.agentName,
                repairSteps: [
                    OnboardingRepairStep(
                        id: "ensure-daemon",
                        actor: .agentRunnable,
                        title: "Wake your agent",
                        detail: "Workbench brings the local runtime back online so your agent can respond.",
                        command: ["ouro", "up"]
                    )
                ]
            )
        }

        guard !agents.isEmpty else {
            return OnboardingReadiness(
                state: .needsAgent,
                headline: "Set up an Ouro agent",
                detail: "Workbench needs a local Ouro agent on this machine before it can act as the boss.",
                selectedBossName: boss.agentName,
                repairSteps: [
                    OnboardingRepairStep(
                        id: "hatch",
                        actor: .humanChoice,
                        title: "Hatch a new agent",
                        detail: "Create a new local Ouro agent through a guided setup conversation.",
                        command: ["ouro", "hatch"]
                    ),
                    OnboardingRepairStep(
                        id: "clone",
                        actor: .humanChoice,
                        title: "Clone an existing agent",
                        detail: "Bring an existing agent bundle and vault onto this machine.",
                        command: ["ouro", "clone", "<remote>"]
                    )
                ]
            )
        }

        guard let selected = agents.first(where: { $0.name.caseInsensitiveCompare(boss.agentName) == .orderedSame }) else {
            // Empty boss = unresolved (fresh / factory-reset, or >1 agent so
            // auto-adopt declined). A non-empty-but-missing name means the
            // persisted boss's bundle is gone. Keep the copy honest for each —
            // never render "The selected boss  is not installed" with a blank name.
            let detail = boss.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Choose which local agent runs as the boss on this machine."
                : "The selected boss \(boss.agentName) is not installed. Choose a local agent or install the missing bundle."
            return OnboardingReadiness(
                state: .needsAgent,
                headline: "Choose this machine's boss",
                detail: detail,
                selectedBossName: boss.agentName,
                repairSteps: agents
                    .filter(\.isUsableAsBoss)
                    .map { agent in
                        OnboardingRepairStep(
                            id: "use-\(agent.name)",
                            actor: .humanChoice,
                            title: "Use \(agent.name)",
                            detail: "Make \(agent.name) the Workbench boss for this machine."
                        )
                    }
            )
        }

        var repairSteps: [OnboardingRepairStep] = []
        if selected.status != .ready {
            repairSteps.append(
                OnboardingRepairStep(
                    id: "repair-agent-config",
                    actor: .agentRunnable,
                    title: "Repair \(selected.name)",
                    detail: selected.detail,
                    command: ["ouro", "repair", "--agent", selected.name]
                )
            )
        }

        // Credential signal: an otherwise-ready agent that has NO usable provider in EITHER
        // lane is "exists but has no usable credentials" — categorically distinct from a
        // single incomplete lane (which flows into the per-lane `providerChecks` path below
        // and stays `needsRepair`). Provider configuration is the one irreducibly human
        // touchpoint, so this surfaces a non-secret-bearing request to open the provider form
        // rather than an agent-runnable auto-remediation. This is COMPLEMENTARY to
        // `providerChecks` (which live-checks a *configured* lane): the two never overlap,
        // because an agent with no usable lane never reaches the per-lane check path.
        if selected.status == .ready, !hasAnyUsableLane(selected) {
            return OnboardingReadiness(
                state: .needsCredentials,
                headline: "Connect a provider",
                detail: "\(selected.name) is installed but has no provider connected yet. Connecting one lets your agent start working.",
                selectedBossName: selected.name,
                repairSteps: [
                    OnboardingRepairStep(
                        id: "request-provider-config",
                        actor: .humanRequired,
                        title: "Connect a provider",
                        detail: "Workbench opens a setup form so you can connect a provider for \(selected.name). This is the only step that needs you."
                        // No audit-lane command: this step opens the NATIVE provider form, not a
                        // `ouro connect providers` CLI pane. That interactive pane is the TTFA
                        // violation Slice 3 deleted — the human gate lives inside the native form.
                    )
                ]
            )
        }

        repairSteps.append(
            contentsOf: providerRepairSteps(
                agent: selected,
                lane: "outward",
                laneName: "outward",
                purpose: "human-facing turns",
                configured: selected.humanFacing?.provider != nil && selected.humanFacing?.model != nil,
                check: providerChecks["outward"]
            )
        )

        repairSteps.append(
            contentsOf: providerRepairSteps(
                agent: selected,
                lane: "inner",
                laneName: "inner",
                purpose: "agent-facing work",
                configured: selected.agentFacing?.provider != nil && selected.agentFacing?.model != nil,
                check: providerChecks["inner"]
            )
        )

        // RUNTIME-INJECTION model: the Workbench tools are injected into the boss's turn at
        // runtime (Workbench passes `--workbench-mcp` when it launches the boss) — nothing is
        // written to the synced bundle. This step is therefore "are the Workbench tools available
        // to this boss at runtime" — i.e. the Workbench MCP binary is present on disk AND the
        // bundle is clean of any stale entry an older Workbench left. `.registered` means both
        // hold; anything else surfaces this step. The boss actually HAVING the tools is confirmed
        // by the handoff `status` round-trip, not the bundle.
        if mcpRegistration?.status != .registered {
            repairSteps.append(
                OnboardingRepairStep(
                    id: "workbench-mcp",
                    actor: .agentRunnable,
                    title: "Connect Workbench tools",
                    detail: mcpRegistration?.detail ?? "Workbench tools aren't available to this boss at runtime yet."
                )
            )
        }

        let blockers = repairSteps.filter { step in
            step.id == "repair-agent-config" ||
                step.id == "outward-lane" ||
                step.id == "inner-lane" ||
                step.id == "check-outward" ||
                step.id == "check-inner" ||
                step.id == "repair-outward-provider" ||
                step.id == "repair-inner-provider" ||
                step.id == "workbench-mcp"
        }
        guard blockers.isEmpty else {
            return OnboardingReadiness(
                state: .needsRepair,
                headline: "Repair \(selected.name)",
                detail: "Workbench found \(selected.name), but it needs setup before it can be a reliable boss.",
                selectedBossName: selected.name,
                repairSteps: repairSteps
            )
        }

        return OnboardingReadiness(
            state: .ready,
            headline: "\(selected.name) is ready",
            detail: "The boss is installed, provider lanes passed live checks, and Workbench tools are available to it at runtime.",
            selectedBossName: selected.name,
            repairSteps: repairSteps
        )
    }

    private func providerRepairSteps(
        agent: OuroAgentRecord,
        lane: String,
        laneName: String,
        purpose: String,
        configured: Bool,
        check: OnboardingProviderCheckResult?
    ) -> [OnboardingRepairStep] {
        guard configured else {
            return [
                OnboardingRepairStep(
                    id: "\(lane)-lane",
                    actor: .humanChoice,
                    title: "Choose \(laneName) provider",
                    detail: "The \(laneName) lane is incomplete. Workbench can open Ouro's provider setup flow.",
                    command: ["ouro", "connect", "providers", "--agent", agent.name]
                )
            ]
        }

        switch check?.state {
        case .passed?:
            return []
        case .failed?:
            return [
                OnboardingRepairStep(
                    id: "repair-\(lane)-provider",
                    actor: .humanRequired,
                    title: "Repair \(laneName) provider",
                    detail: check?.detail ?? "The \(laneName) provider failed its live check.",
                    command: ["ouro", "connect", "providers", "--agent", agent.name]
                )
            ]
        case .running?:
            return [
                OnboardingRepairStep(
                    id: "check-\(lane)",
                    actor: .agentRunnable,
                    title: "Checking \(laneName) provider",
                    detail: "Workbench is verifying the provider/model selected for \(purpose)."
                )
            ]
        case .pending?, nil:
            return [
                OnboardingRepairStep(
                    id: "check-\(lane)",
                    actor: .agentRunnable,
                    title: "Check \(laneName) provider",
                    detail: "Workbench must verify the provider/model selected for \(purpose).",
                    command: ["ouro", "check", "--agent", agent.name, "--lane", lane]
                )
            ]
        }
    }

    /// The credential signal, derived from the selected agent's provider lanes: an agent has
    /// usable credentials only when at least one lane (`humanFacing` or `agentFacing`) names a
    /// provider. A lane with no provider carries no usable credential regardless of model.
    private func hasAnyUsableLane(_ agent: OuroAgentRecord) -> Bool {
        agent.humanFacing?.provider != nil || agent.agentFacing?.provider != nil
    }
}

public enum RecentSessionSource: String, Codable, Equatable, Sendable {
    case claudeCode
    case cmux
    case openAICodex
    case githubCopilotCLI
    case shellHistory
    case workbench
}

public struct RecentSessionCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var source: RecentSessionSource
    public var agentKind: TerminalAgentKind?
    public var title: String
    public var workingDirectory: String
    public var lastActiveAt: Date?
    public var resumeCommand: [String]
    public var summary: String
    public var evidencePaths: [String]
    public var confidence: Double
    public var preferredGroupName: String?
    /// The git repository root that `workingDirectory` lives in, if any —
    /// resolved against the filesystem by the scanner. This is the natural
    /// grouping unit: every session in a repo (whatever subdirectory it was
    /// launched from) belongs to one group. `nil` when the directory isn't in
    /// a git repo, in which case grouping falls back to a path heuristic.
    public var repositoryRoot: String?

    public init(
        id: String,
        source: RecentSessionSource,
        agentKind: TerminalAgentKind?,
        title: String,
        workingDirectory: String,
        lastActiveAt: Date?,
        resumeCommand: [String],
        summary: String,
        evidencePaths: [String],
        confidence: Double,
        preferredGroupName: String? = nil,
        repositoryRoot: String? = nil
    ) {
        self.id = id
        self.source = source
        self.agentKind = agentKind
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastActiveAt = lastActiveAt
        self.resumeCommand = resumeCommand
        self.summary = summary
        self.evidencePaths = evidencePaths
        self.confidence = min(1, max(0, confidence))
        self.preferredGroupName = preferredGroupName
        self.repositoryRoot = repositoryRoot
    }

    public var resumeCommandLine: String {
        ShellArgumentEscaper.commandLine(resumeCommand)
    }
}

public struct RecentSessionScanner {
    public struct LiveTerminalProcess: Equatable, Sendable {
        public var pid: Int
        public var ttyName: String?
        public var command: String

        public init(pid: Int, ttyName: String?, command: String) {
            self.pid = pid
            self.ttyName = ttyName
            self.command = command
        }
    }

    public var homeURL: URL
    public var fileManager: FileManager
    public var now: Date
    public var lookback: TimeInterval
    public var sqlite3URL: URL
    public var cmuxSessionURL: URL
    public var liveProcessLister: () -> [LiveTerminalProcess]

    public init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        now: Date = Date(),
        lookback: TimeInterval = 7 * 24 * 60 * 60,
        sqlite3URL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        cmuxSessionURL: URL? = nil,
        liveProcessLister: (() -> [LiveTerminalProcess])? = nil
    ) {
        self.homeURL = homeURL
        self.fileManager = fileManager
        self.now = now
        self.lookback = lookback
        self.sqlite3URL = sqlite3URL
        self.cmuxSessionURL = cmuxSessionURL ?? homeURL
            .appendingPathComponent("Library/Application Support/cmux/session-com.cmuxterm.app.json")
        self.liveProcessLister = liveProcessLister ?? Self.systemLiveTerminalProcesses
    }

    public func scan() -> [RecentSessionCandidate] {
        let liveProcesses = liveProcessLister()
        let claudeHistory = scanClaudeCode() + scanClaudeTaskRecords()
        let candidates = scanWorkbench()
            + scanCmuxSessions(liveProcesses: liveProcesses, claudeHistory: claudeHistory)
            + scanLiveClaudeCode(liveProcesses: liveProcesses, claudeHistory: claudeHistory)
            + claudeHistory
            + scanCodex()
            + scanShellHistory()

        return resolveRepositoryRoots(dedupe(candidates))
    }

    /// Fill in each candidate's git repository root (the natural grouping unit)
    /// by walking up from its working directory. Cheap — a few `stat`s per
    /// candidate — and cached per directory so repeated cwds aren't re-walked.
    private func resolveRepositoryRoots(_ candidates: [RecentSessionCandidate]) -> [RecentSessionCandidate] {
        var cache: [String: String?] = [:]
        return candidates.map { candidate in
            guard candidate.repositoryRoot == nil else {
                return candidate
            }
            let directory = candidate.workingDirectory
            let resolved: String?
            if let cached = cache[directory] {
                resolved = cached
            } else {
                resolved = WorkspaceGrouping.repositoryRoot(for: directory) { dir in
                    self.fileManager.fileExists(atPath: dir + "/.git")
                }
                cache[directory] = resolved
            }
            var updated = candidate
            updated.repositoryRoot = resolved
            return updated
        }
            .sorted { left, right in
                switch (left.lastActiveAt, right.lastActiveAt) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.confidence > right.confidence
                }
            }
    }

    public func scanLiveClaudeCode(
        liveProcesses: [LiveTerminalProcess]? = nil,
        claudeHistory: [RecentSessionCandidate] = []
    ) -> [RecentSessionCandidate] {
        let processes = liveProcesses ?? liveProcessLister()
        let historyById = candidateById(claudeHistory)
        return processes.compactMap { process in
            guard isClaudeProcess(command: process.command),
                  let sessionId = claudeSessionId(from: process.command)
            else {
                return nil
            }
            let id = "claude:\(sessionId)"
            let history = historyById[id]
            return RecentSessionCandidate(
                id: id,
                source: .claudeCode,
                agentKind: .claudeCode,
                title: history?.title ?? "Live Claude Code session \(sessionId.prefix(8))",
                workingDirectory: history?.workingDirectory ?? homeURL.path,
                lastActiveAt: maxDate(now, history?.lastActiveAt),
                resumeCommand: claudeResumeCommand(sessionId: sessionId, from: process.command),
                summary: history?.summary ?? "Live Claude Code process detected from the local process table.",
                evidencePaths: (history?.evidencePaths ?? []) + ["process:\(process.pid)"],
                confidence: history == nil ? 0.86 : max(0.95, history?.confidence ?? 0)
            )
        }
    }

    public func scanCmuxSessions(
        liveProcesses: [LiveTerminalProcess]? = nil,
        claudeHistory: [RecentSessionCandidate] = []
    ) -> [RecentSessionCandidate] {
        guard let data = try? Data(contentsOf: cmuxSessionURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }

        let processes = liveProcesses ?? liveProcessLister()
        let processesByTTY = Dictionary(grouping: processes, by: { normalizedTTYName($0.ttyName) ?? "" })
        let historyById = candidateById(claudeHistory)

        return cmuxWorkspaces(in: root).flatMap { workspace in
            workspace.panels.compactMap { panel -> RecentSessionCandidate? in
                guard let panelTTY = normalizedTTYName(panel.ttyName) else {
                    return nil
                }
                let liveProcess = processesByTTY[panelTTY]
                    .flatMap { ttyProcesses in
                        ttyProcesses.first(where: { isClaudeProcess(command: $0.command) })
                    }
                guard let liveProcess,
                      let sessionId = claudeSessionId(from: liveProcess.command)
                else {
                    return nil
                }

                let id = "claude:\(sessionId)"
                let history = historyById[id]
                let cwd = panel.workingDirectory
                    ?? panel.directory
                    ?? workspace.currentDirectory
                    ?? history?.workingDirectory
                    ?? homeURL.path
                let title = cleanedCmuxTitle(panel.title)
                    ?? history?.title
                    ?? workspace.customTitle
                    ?? "Live Claude Code session \(sessionId.prefix(8))"
                let status = workspace.statusEntries.compactMap(\.value).joined(separator: ", ")
                let statusSentence = status.isEmpty ? "" : " Status: \(status)."

                return RecentSessionCandidate(
                    id: id,
                    source: .cmux,
                    agentKind: .claudeCode,
                    title: title,
                    workingDirectory: cwd,
                    lastActiveAt: maxDate(
                        now,
                        workspace.statusEntries.compactMap(\.timestamp).max(),
                        history?.lastActiveAt
                    ),
                    resumeCommand: claudeResumeCommand(sessionId: sessionId, from: liveProcess.command),
                    summary: "Live cmux Claude Code panel in \(workspace.customTitle ?? workspace.processTitle ?? "cmux").\(statusSentence)",
                    evidencePaths: (history?.evidencePaths ?? []) + [cmuxSessionURL.path, "tty:\(panel.ttyName ?? "unknown")"],
                    confidence: 0.99,
                    preferredGroupName: workspace.customTitle
                )
            }
        }
    }

    public func scanWorkbench(state: WorkspaceState = WorkspaceState()) -> [RecentSessionCandidate] {
        state.processEntries.compactMap { entry in
            guard entry.kind == .terminalAgent || entry.kind == .shell else {
                return nil
            }
            return RecentSessionCandidate(
                id: "workbench:\(entry.id.uuidString)",
                source: .workbench,
                agentKind: TerminalAgentDetector.detect(entry: entry),
                title: entry.name,
                workingDirectory: entry.workingDirectory,
                lastActiveAt: state.processRuns
                    .filter { $0.entryId == entry.id }
                    .compactMap(\.lastOutputAt)
                    .max(),
                resumeCommand: [entry.executable] + entry.arguments,
                summary: entry.lastSummary ?? entry.trimmedNotes ?? "Existing Workbench terminal.",
                evidencePaths: [],
                confidence: 0.96
            )
        }
    }

    public func scanClaudeCode() -> [RecentSessionCandidate] {
        let projectsURL = homeURL.appendingPathComponent(".claude/projects", isDirectory: true)
        let files = recentFiles(under: projectsURL, pathExtension: "jsonl")
        return files.compactMap { fileURL in
            let records = jsonLineObjects(fileURL)
            let sessionId = firstString(records, keys: ["sessionId"])
                ?? fileURL.deletingPathExtension().lastPathComponent
            let cwd = firstString(records, keys: ["cwd"])
                ?? inferredClaudeProjectPath(from: fileURL)
                ?? homeURL.path
            let title = firstPrompt(records)
                .flatMap(Self.titleFromPrompt)
                ?? fileURL.deletingPathExtension().lastPathComponent
            let lastActive = newestDate(in: records) ?? modificationDate(fileURL)
            guard isRecent(lastActive) else {
                return nil
            }
            return RecentSessionCandidate(
                id: "claude:\(sessionId)",
                source: .claudeCode,
                agentKind: .claudeCode,
                title: title,
                workingDirectory: cwd,
                lastActiveAt: lastActive,
                resumeCommand: ["claude", "--resume", sessionId],
                summary: firstPrompt(records) ?? "Recent Claude Code session.",
                evidencePaths: [evidencePath(fileURL)],
                confidence: cwd == homeURL.path ? 0.72 : 0.92
            )
        }
    }

    public func scanClaudeTaskRecords() -> [RecentSessionCandidate] {
        let tasksURL = homeURL.appendingPathComponent(".claude/tasks", isDirectory: true)
        let projectsURL = homeURL.appendingPathComponent(".claude/projects", isDirectory: true)
        return scanClaudeJSONRecords(under: tasksURL) + scanClaudeJSONRecords(under: projectsURL)
    }

    public func scanCodex() -> [RecentSessionCandidate] {
        scanCodexSQLite()
            + scanCodexSessionIndex()
            + scanCodexRecoveryJSONL()
    }

    private func scanCodexSessionIndex() -> [RecentSessionCandidate] {
        let indexURL = homeURL.appendingPathComponent(".codex/session_index.jsonl")
        return jsonLineObjects(indexURL).compactMap { object in
            guard let id = object["id"] as? String else {
                return nil
            }
            let title = (object["thread_name"] as? String).flatMap(Self.titleFromPrompt) ?? id
            let lastActive = parseDate(object["updated_at"] as? String)
            guard isRecent(lastActive) else {
                return nil
            }
            return RecentSessionCandidate(
                id: "codex:\(id)",
                source: .openAICodex,
                agentKind: .openAICodex,
                title: title,
                workingDirectory: homeURL.path,
                lastActiveAt: lastActive,
                resumeCommand: ["codex", "resume", id],
                summary: title,
                evidencePaths: [indexURL.path],
                confidence: 0.68
            )
        }
    }

    private func scanCodexRecoveryJSONL() -> [RecentSessionCandidate] {
        let codexURL = homeURL.appendingPathComponent(".codex", isDirectory: true)
        return recentFiles(under: codexURL, pathExtension: "jsonl")
            .filter { fileURL in
                let path = fileURL.path
                return path.contains("/archived_sessions/")
                    || path.contains("/manual-recovery-")
            }
            .flatMap { fileURL in
                jsonLineObjects(fileURL).compactMap { object in
                    codexCandidate(from: object, evidenceURL: fileURL)
                }
            }
    }

    public func scanShellHistory() -> [RecentSessionCandidate] {
        let historyURL = homeURL.appendingPathComponent(".zsh_history")
        guard let raw = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return []
        }
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> RecentSessionCandidate? in
                guard let parsed = parseZshHistoryLine(String(line)) else {
                    return nil
                }
                let command = parsed.command.trimmingCharacters(in: .whitespacesAndNewlines)
                let tokens = TerminalCommandParser.parse(command)
                let kind = tokens.flatMap { TerminalAgentDetector.detect(executable: $0.executable, arguments: $0.arguments) }
                guard kind != nil || command.hasPrefix("gh copilot") || command.contains(" gh copilot") else {
                    return nil
                }
                let date = Date(timeIntervalSince1970: TimeInterval(parsed.epoch))
                guard isRecent(date) else {
                    return nil
                }
                let fallbackTokens = tokens.map { [$0.executable] + $0.arguments } ?? command.split(whereSeparator: \.isWhitespace).map(String.init)
                return RecentSessionCandidate(
                    id: "shell:\(parsed.epoch):\(command.hashValue)",
                    source: command.contains("copilot") ? .githubCopilotCLI : .shellHistory,
                    agentKind: kind ?? (command.contains("copilot") ? .githubCopilotCLI : nil),
                    title: command,
                    workingDirectory: homeURL.path,
                    lastActiveAt: date,
                    resumeCommand: fallbackTokens,
                    summary: "Recent shell launch: \(command)",
                    evidencePaths: [historyURL.path],
                    confidence: 0.42
                )
            }
    }

    private func scanClaudeJSONRecords(under root: URL) -> [RecentSessionCandidate] {
        recentFiles(under: root, pathExtension: "json").compactMap { fileURL in
            guard let object = jsonObject(fileURL),
                  let sessionId = firstString(object, keys: ["sessionId", "session_id", "id"])
            else {
                return nil
            }
            let cwd = firstString(object, keys: ["cwd", "workingDirectory", "working_directory"])
                ?? inferredClaudeProjectPath(from: fileURL)
                ?? homeURL.path
            let titleSeed = firstString(object, keys: ["summary", "title", "prompt", "message", "content"])
                ?? sessionId
            let lastActive = firstDate(object, keys: ["updatedAt", "updated_at", "timestamp", "lastActiveAt"])
                ?? modificationDate(fileURL)
            guard isRecent(lastActive) else {
                return nil
            }
            return RecentSessionCandidate(
                id: "claude:\(sessionId)",
                source: .claudeCode,
                agentKind: .claudeCode,
                title: Self.titleFromPrompt(titleSeed) ?? sessionId,
                workingDirectory: cwd,
                lastActiveAt: lastActive,
                resumeCommand: ["claude", "--resume", sessionId],
                summary: titleSeed,
                evidencePaths: [evidencePath(fileURL)],
                confidence: cwd == homeURL.path ? 0.7 : 0.9
            )
        }
    }

    private func codexCandidate(from object: [String: Any], evidenceURL: URL) -> RecentSessionCandidate? {
        guard let sessionId = firstString(object, keys: ["id", "sessionId", "session_id", "threadId", "thread_id"]) else {
            return nil
        }
        let cwd = firstString(object, keys: ["cwd", "workingDirectory", "working_directory"])
        let titleSeed = firstString(object, keys: ["prompt", "summary", "title", "thread_name", "message", "content"])
            ?? sessionId
        let lastActive = firstDate(object, keys: ["timestamp", "updatedAt", "updated_at", "lastActiveAt", "last_active_at"])
            ?? modificationDate(evidenceURL)
        guard isRecent(lastActive) else {
            return nil
        }
        let workingDirectory = cwd ?? homeURL.path
        return RecentSessionCandidate(
            id: "codex:\(sessionId)",
            source: .openAICodex,
            agentKind: .openAICodex,
            title: Self.titleFromPrompt(titleSeed) ?? sessionId,
            workingDirectory: workingDirectory,
            lastActiveAt: lastActive,
            resumeCommand: ["codex", "resume", sessionId],
            summary: titleSeed,
            evidencePaths: [evidencePath(evidenceURL)],
            confidence: cwd == nil ? 0.7 : 0.88
        )
    }

    private func scanCodexSQLite() -> [RecentSessionCandidate] {
        let sqliteURL = homeURL.appendingPathComponent(".codex/state_5.sqlite")
        guard fileManager.fileExists(atPath: sqliteURL.path),
              fileManager.isExecutableFile(atPath: sqlite3URL.path)
        else {
            return []
        }
        let sinceMs = Int64((now.timeIntervalSince1970 - lookback) * 1000)
        let query = """
        select id, replace(title, char(9), ' '), replace(cwd, char(9), ' '), coalesce(git_branch, ''), coalesce(updated_at_ms, updated_at * 1000)
        from threads
        where coalesce(updated_at_ms, updated_at * 1000) >= \(sinceMs)
        order by coalesce(updated_at_ms, updated_at * 1000) desc
        limit 200;
        """
        let process = Process()
        let pipe = Pipe()
        process.executableURL = sqlite3URL
        // `-readonly` so we never contend for a write lock with a live Codex,
        // and a watchdog below so a WAL-locked / slow DB can't hang the scan
        // (which would leave onboardingIsScanning stuck and disable Scan/Arrange).
        process.arguments = ["-readonly", "-separator", "\t", "-noheader", sqliteURL.path, query]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            let start = Date()
            try process.run()
            // Terminate sqlite3 if it runs past the deadline. `readDataToEndOfFile`
            // drains continuously and returns at EOF — which happens on normal
            // exit OR when the watchdog terminates the process — so a hung query
            // can't wedge us, and large output can't fill the pipe buffer.
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard Date().timeIntervalSince(start) < 5, process.terminationStatus == 0 else {
                return []
            }
            let output = String(decoding: data, as: UTF8.self)
            return output.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 5 else {
                    return nil
                }
                let id = fields[0]
                let title = Self.titleFromPrompt(fields[1]) ?? id
                let cwd = fields[2].isEmpty ? homeURL.path : fields[2]
                let milliseconds = Double(fields[4]) ?? 0
                let lastActive = milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1000) : nil
                return RecentSessionCandidate(
                    id: "codex:\(id)",
                    source: .openAICodex,
                    agentKind: .openAICodex,
                    title: title,
                    workingDirectory: cwd,
                    lastActiveAt: lastActive,
                    resumeCommand: ["codex", "resume", id],
                    summary: fields[1].isEmpty ? title : fields[1],
                    evidencePaths: [sqliteURL.path],
                    confidence: cwd == homeURL.path ? 0.74 : 0.94
                )
            }
        } catch {
            return []
        }
    }

    private func recentFiles(under root: URL, pathExtension: String) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            guard isRecent(modificationDate(url)) else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private func jsonLineObjects(_ url: URL) -> [[String: Any]] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return nil
                }
                return object
            }
    }

    private func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func evidencePath(_ url: URL) -> String {
        let path = url.path
        let privateHomePrefix = "/private" + homeURL.path
        if path.hasPrefix(privateHomePrefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private func firstString(_ records: [[String: Any]], keys: [String]) -> String? {
        for record in records {
            for key in keys {
                if let value = record[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func firstDate(_ object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let date = parseDate(object[key] as? String) {
                return date
            }
            if let milliseconds = object[key] as? Double, milliseconds > 0 {
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
            if let seconds = object[key] as? Int, seconds > 0 {
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
        }
        return nil
    }

    private func firstPrompt(_ records: [[String: Any]]) -> String? {
        for record in records {
            for key in ["content", "message", "summary"] {
                if let value = stringValue(record[key]), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let array = value as? [[String: Any]] {
            return array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let object = value as? [String: Any] {
            return stringValue(object["content"]) ?? stringValue(object["text"])
        }
        return nil
    }

    private func newestDate(in records: [[String: Any]]) -> Date? {
        records.compactMap { parseDate($0["timestamp"] as? String) }.max()
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func isRecent(_ date: Date?) -> Bool {
        guard let date else {
            return false
        }
        return date >= now.addingTimeInterval(-lookback)
    }

    private func inferredClaudeProjectPath(from fileURL: URL) -> String? {
        let projectDirectory = fileURL.deletingLastPathComponent().lastPathComponent
        guard projectDirectory.hasPrefix("-") else {
            return nil
        }
        let path = "/" + projectDirectory.dropFirst().replacingOccurrences(of: "-", with: "/")
        return path.isEmpty ? nil : path
    }

    private func parseZshHistoryLine(_ line: String) -> (epoch: Int, command: String)? {
        guard line.hasPrefix(": ") else {
            return nil
        }
        let pieces = line.dropFirst(2).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let epochText = pieces[0].split(separator: ":").first,
              let epoch = Int(epochText)
        else {
            return nil
        }
        return (epoch, String(pieces[1]))
    }

    private static func systemLiveTerminalProcesses() -> [LiveTerminalProcess] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,tt=,command="]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return []
            }
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap(parseProcessLine)
        } catch {
            return []
        }
    }

    private static func parseProcessLine(_ line: Substring) -> LiveTerminalProcess? {
        let pieces = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard pieces.count == 3, let pid = Int(pieces[0]) else {
            return nil
        }
        return LiveTerminalProcess(
            pid: pid,
            ttyName: String(pieces[1]),
            command: String(pieces[2])
        )
    }

    private func candidateById(_ candidates: [RecentSessionCandidate]) -> [String: RecentSessionCandidate] {
        var byId: [String: RecentSessionCandidate] = [:]
        for candidate in candidates {
            if let existing = byId[candidate.id], existing.confidence >= candidate.confidence {
                continue
            }
            byId[candidate.id] = candidate
        }
        return byId
    }

    private func isClaudeProcess(command: String) -> Bool {
        guard let parsed = canonicalCommandTokens(command) else {
            return false
        }
        return URL(fileURLWithPath: parsed.executable).lastPathComponent.lowercased() == "claude"
    }

    private func claudeSessionId(from command: String) -> String? {
        guard let parsed = canonicalCommandTokens(command) else {
            return nil
        }
        var index = 0
        while index < parsed.arguments.count {
            let token = parsed.arguments[index]
            if token == "--session-id", index + 1 < parsed.arguments.count {
                return parsed.arguments[index + 1]
            }
            if token.hasPrefix("--session-id=") {
                return String(token.dropFirst("--session-id=".count))
            }
            index += 1
        }
        return nil
    }

    private func claudeResumeCommand(sessionId: String, from command: String) -> [String] {
        ["claude"] + preservedClaudeResumeArguments(from: command) + ["--resume", sessionId]
    }

    private func preservedClaudeResumeArguments(from command: String) -> [String] {
        guard let parsed = canonicalCommandTokens(command) else {
            return []
        }
        var preserved: [String] = []
        var index = 0
        while index < parsed.arguments.count {
            let token = parsed.arguments[index]
            switch token {
            case "--dangerously-skip-permissions", "--yolo":
                preserved.append(token)
                index += 1
            case "--model", "--permission-mode", "--add-dir":
                if index + 1 < parsed.arguments.count {
                    preserved.append(token)
                    preserved.append(parsed.arguments[index + 1])
                    index += 2
                } else {
                    index += 1
                }
            default:
                if token.hasPrefix("--model=")
                    || token.hasPrefix("--permission-mode=")
                    || token.hasPrefix("--add-dir=")
                {
                    preserved.append(token)
                }
                index += 1
            }
        }
        return preserved
    }

    private func canonicalCommandTokens(_ command: String) -> TerminalCommandTokens? {
        guard let parsed = TerminalCommandParser.parse(command) else {
            return nil
        }
        return TerminalAgentDetector.canonicalTokens(executable: parsed.executable, arguments: parsed.arguments)
    }

    private func cmuxWorkspaces(in root: [String: Any]) -> [CmuxWorkspace] {
        let windows = root["windows"] as? [[String: Any]] ?? []
        return windows.flatMap { window -> [CmuxWorkspace] in
            guard let tabManager = window["tabManager"] as? [String: Any],
                  let workspaces = tabManager["workspaces"] as? [[String: Any]]
            else {
                return []
            }
            return workspaces.map(cmuxWorkspace)
        }
    }

    private func cmuxWorkspace(_ object: [String: Any]) -> CmuxWorkspace {
        let panels = (object["panels"] as? [[String: Any]] ?? []).map(cmuxPanel)
        let statusEntries = (object["statusEntries"] as? [[String: Any]] ?? []).map(cmuxStatusEntry)
        return CmuxWorkspace(
            customTitle: object["customTitle"] as? String,
            currentDirectory: object["currentDirectory"] as? String,
            processTitle: object["processTitle"] as? String,
            panels: panels,
            statusEntries: statusEntries
        )
    }

    private func cmuxPanel(_ object: [String: Any]) -> CmuxPanel {
        let terminal = object["terminal"] as? [String: Any]
        return CmuxPanel(
            title: object["title"] as? String,
            directory: object["directory"] as? String,
            workingDirectory: terminal?["workingDirectory"] as? String,
            ttyName: object["ttyName"] as? String
        )
    }

    private func cmuxStatusEntry(_ object: [String: Any]) -> CmuxStatusEntry {
        let timestamp = (object["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:))
        return CmuxStatusEntry(
            value: object["value"] as? String,
            timestamp: timestamp
        )
    }

    private func cleanedCmuxTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        while let first = title.unicodeScalars.first,
              !CharacterSet.alphanumerics.contains(first),
              first != "/",
              first != "~"
        {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.isEmpty ? nil : title
    }

    private func normalizedTTYName(_ ttyName: String?) -> String? {
        guard let ttyName, !ttyName.isEmpty, ttyName != "??" else {
            return nil
        }
        if ttyName.hasPrefix("ttys") {
            return ttyName
        }
        if ttyName.hasPrefix("s") {
            return "tty\(ttyName)"
        }
        return ttyName
    }

    private func maxDate(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }

    private func dedupe(_ candidates: [RecentSessionCandidate]) -> [RecentSessionCandidate] {
        var byId: [String: RecentSessionCandidate] = [:]
        for candidate in candidates {
            if let existing = byId[candidate.id], existing.confidence >= candidate.confidence {
                continue
            }
            byId[candidate.id] = candidate
        }
        return Array(byId.values)
    }

    public static func titleFromPrompt(_ prompt: String) -> String? {
        let cleaned = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return nil
        }
        if cleaned.count <= 72 {
            return cleaned
        }
        let prefix = cleaned.prefix(72)
        if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) {
            return String(prefix[..<lastSpace])
        }
        return String(prefix)
    }
}

private struct CmuxWorkspace {
    var customTitle: String?
    var currentDirectory: String?
    var processTitle: String?
    var panels: [CmuxPanel]
    var statusEntries: [CmuxStatusEntry]
}

private struct CmuxPanel {
    var title: String?
    var directory: String?
    var workingDirectory: String?
    var ttyName: String?
}

private struct CmuxStatusEntry {
    var value: String?
    var timestamp: Date?
}

public struct ProposedTerminalImport: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var candidate: RecentSessionCandidate
    public var name: String
    public var selectedByDefault: Bool

    public init(
        id: String,
        candidate: RecentSessionCandidate,
        name: String,
        selectedByDefault: Bool
    ) {
        self.id = id
        self.candidate = candidate
        self.name = name
        self.selectedByDefault = selectedByDefault
    }
}

public struct ProposedWorkbenchGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var rootPath: String
    public var terminals: [ProposedTerminalImport]

    public init(
        id: String,
        name: String,
        rootPath: String,
        terminals: [ProposedTerminalImport]
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.terminals = terminals
    }
}

public struct WorkbenchImportProposal: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var groups: [ProposedWorkbenchGroup]
    public var ignoredCandidates: [RecentSessionCandidate]

    public init(
        generatedAt: Date,
        groups: [ProposedWorkbenchGroup],
        ignoredCandidates: [RecentSessionCandidate]
    ) {
        self.generatedAt = generatedAt
        self.groups = groups
        self.ignoredCandidates = ignoredCandidates
    }

    public var selectedTerminalCount: Int {
        groups.reduce(0) { sum, group in
            sum + group.terminals.filter(\.selectedByDefault).count
        }
    }

    /// Toggle a terminal's "include in arrange" state. Returns the new selection
    /// state (`true` if the terminal is now selected, `false` otherwise) so the
    /// view layer can react without recomputing.
    @discardableResult
    public mutating func toggleSelection(groupID: String, terminalID: String) -> Bool? {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
              let terminalIndex = groups[groupIndex].terminals.firstIndex(where: { $0.id == terminalID }) else {
            return nil
        }
        let newValue = !groups[groupIndex].terminals[terminalIndex].selectedByDefault
        groups[groupIndex].terminals[terminalIndex].selectedByDefault = newValue
        return newValue
    }

    /// Bulk-select or bulk-clear every terminal in a group.
    public mutating func setSelection(groupID: String, selected: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        for terminalIndex in groups[groupIndex].terminals.indices {
            groups[groupIndex].terminals[terminalIndex].selectedByDefault = selected
        }
    }
}

/// How a candidate is bucketed into a group. An explicit name (e.g. a cmux
/// workspace title) always wins; otherwise sessions group by their git repo
/// root, so every terminal opened anywhere inside a repo lands in one group.
private enum WorkbenchImportGroupKey: Hashable {
    case named(String)
    case root(String)
}

/// Resolve a directory to its enclosing git repository root, by walking up the
/// path until a `.git` entry is found. Pure: the filesystem check is injected,
/// so it's unit-testable against synthetic trees.
public enum WorkspaceGrouping {
    public static func repositoryRoot(
        for path: String,
        hasGitEntry: (String) -> Bool
    ) -> String? {
        var dir = standardizedDirectory(path)
        guard !dir.isEmpty else {
            return nil
        }
        var hops = 0
        while hops < 64 {
            hops += 1
            if hasGitEntry(dir) {
                return dir
            }
            guard let parent = parentDirectory(of: dir), parent != dir else {
                return nil
            }
            dir = parent
        }
        return nil
    }

    static func standardizedDirectory(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    static func parentDirectory(of path: String) -> String? {
        guard path != "/", !path.isEmpty else {
            return nil
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}

public struct WorkbenchImportProposalBuilder: Sendable {
    public var maxSelectedPerGroup: Int
    public var maxSelectedTotal: Int

    public init(maxSelectedPerGroup: Int = 6, maxSelectedTotal: Int = 12) {
        self.maxSelectedPerGroup = max(1, maxSelectedPerGroup)
        self.maxSelectedTotal = max(1, maxSelectedTotal)
    }

    public func build(candidates: [RecentSessionCandidate], now: Date = Date()) -> WorkbenchImportProposal {
        let importable = candidates.filter { $0.confidence >= 0.50 }
        let ignored = candidates.filter { $0.confidence < 0.50 }
        let grouped = Dictionary(grouping: importable) { groupKey(for: $0) }
        var groups = grouped.map { key, groupCandidates in
            let newest = groupCandidates.max {
                ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast)
            }
            let groupName: String
            let groupRootPath: String
            switch key {
            case let .named(name):
                groupName = name
                groupRootPath = newest?.repositoryRoot ?? newest?.workingDirectory ?? ""
            case let .root(root):
                groupName = displayName(for: root)
                groupRootPath = root
            }
            let trackSlug = slug(groupName)
            let terminals = groupCandidates
                .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
                .map { candidate in
                    ProposedTerminalImport(
                        id: candidate.id,
                        candidate: candidate,
                        name: terminalName(for: candidate),
                        selectedByDefault: false
                    )
                }
            return ProposedWorkbenchGroup(
                id: trackSlug,
                name: groupName,
                rootPath: groupRootPath,
                terminals: terminals
            )
        }
        .sorted { lhs, rhs in
            let lhsNewest = lhs.terminals.compactMap(\.candidate.lastActiveAt).max() ?? .distantPast
            let rhsNewest = rhs.terminals.compactMap(\.candidate.lastActiveAt).max() ?? .distantPast
            if lhsNewest != rhsNewest {
                return lhsNewest > rhsNewest
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        // Distinct groups whose names slugify identically (e.g. "My Project"
        // and "my-project", or two different rootPaths) would otherwise share
        // an `id`, which breaks SwiftUI's Identifiable ForEach
        // (dropped/duplicated rows) and makes selection toggles hit the wrong
        // group. De-dupe the slug-derived `id` across groups.
        var usedGroupSlugs = Set<String>()
        groups = groups.map { group in
            let uniqueGroupSlug = uniqueSlug(group.id, used: &usedGroupSlugs)
            guard uniqueGroupSlug != group.id else {
                return group
            }
            var deduped = group
            deduped.id = uniqueGroupSlug
            return deduped
        }

        var totalSelected = 0
        for groupIndex in groups.indices {
            var groupSelected = 0
            for terminalIndex in groups[groupIndex].terminals.indices {
                guard totalSelected < maxSelectedTotal,
                      groupSelected < maxSelectedPerGroup,
                      groups[groupIndex].terminals[terminalIndex].candidate.confidence >= 0.70 else {
                    continue
                }
                groups[groupIndex].terminals[terminalIndex].selectedByDefault = true
                groupSelected += 1
                totalSelected += 1
            }
        }

        return WorkbenchImportProposal(generatedAt: now, groups: groups, ignoredCandidates: ignored)
    }

    /// Bucket a candidate: an explicit group name (cmux workspace title, etc.)
    /// wins; otherwise group by the git repo root the session lives in, falling
    /// back to the path heuristic when the directory isn't in a repo.
    private func groupKey(for candidate: RecentSessionCandidate) -> WorkbenchImportGroupKey {
        if let name = candidate.preferredGroupName,
           !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return .named(name)
        }
        if let repositoryRoot = candidate.repositoryRoot,
           !repositoryRoot.isEmpty {
            return .root(repositoryRoot)
        }
        return .root(workspaceRoot(for: candidate.workingDirectory))
    }

    public func workspaceRoot(for workingDirectory: String) -> String {
        let marker = "/.claude/worktrees/"
        if let range = workingDirectory.range(of: marker) {
            return String(workingDirectory[..<range.lowerBound])
        }
        let components = workingDirectory.split(separator: "/").map(String.init)
        if let projectsIndex = components.firstIndex(of: "Projects"),
           projectsIndex + 1 < components.count {
            return "/" + components[0...projectsIndex + 1].joined(separator: "/")
        }
        return workingDirectory
    }

    public func displayName(for rootPath: String) -> String {
        let last = URL(fileURLWithPath: rootPath, isDirectory: true).lastPathComponent
        return last.isEmpty ? "Home" : last
    }

    public func terminalName(for candidate: RecentSessionCandidate) -> String {
        let prefix: String
        switch candidate.agentKind {
        case .claudeCode?:
            prefix = "Claude"
        case .openAICodex?:
            prefix = "Codex"
        case .githubCopilotCLI?:
            prefix = "Copilot"
        default:
            prefix = "Terminal"
        }
        let title = RecentSessionScanner.titleFromPrompt(candidate.title) ?? "Session"
        return "\(prefix): \(title)"
    }

    public func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        var scalars: [Character] = []
        var previousWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                scalars.append(character)
                previousWasDash = false
            } else if !previousWasDash {
                scalars.append("-")
                previousWasDash = true
            }
        }
        let slug = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "workbench-import" : slug
    }

    private func uniqueSlug(_ base: String, used: inout Set<String>) -> String {
        guard used.contains(base) else {
            used.insert(base)
            return base
        }
        var index = 2
        while used.contains("\(base)-\(index)") {
            index += 1
        }
        let value = "\(base)-\(index)"
        used.insert(value)
        return value
    }
}

public struct DeskBridgePlan: Codable, Equatable, Sendable {
    public var agentName: String
    public var terminalKind: TerminalAgentKind
    public var setupCommand: [String]?
    public var detail: String

    public init(agentName: String, terminalKind: TerminalAgentKind, setupCommand: [String]?, detail: String) {
        self.agentName = agentName
        self.terminalKind = terminalKind
        self.setupCommand = setupCommand
        self.detail = detail
    }

    public var commandLine: String? {
        setupCommand.map(ShellArgumentEscaper.commandLine)
    }
}

public struct DeskBridgePlanner: Sendable {
    public init() {}

    public func plan(agentName: String, terminalKind: TerminalAgentKind) -> DeskBridgePlan {
        switch terminalKind {
        case .claudeCode:
            return DeskBridgePlan(
                agentName: agentName,
                terminalKind: terminalKind,
                setupCommand: ["ouro", "setup", "--tool", "claude-code", "--agent", agentName],
                detail: "Install the Ouro MCP bridge and hooks into Claude Code so this terminal agent can use the selected Ouro agent's desk tools."
            )
        case .openAICodex:
            return DeskBridgePlan(
                agentName: agentName,
                terminalKind: terminalKind,
                setupCommand: ["ouro", "setup", "--tool", "codex", "--agent", agentName],
                detail: "Install the Ouro MCP bridge and hooks into Codex so this terminal agent can use the selected Ouro agent's desk tools."
            )
        case .githubCopilotCLI:
            return DeskBridgePlan(
                agentName: agentName,
                terminalKind: terminalKind,
                setupCommand: nil,
                detail: "Copilot CLI does not yet expose the same MCP setup target; Workbench will preserve transcript and Desk context until a native bridge exists."
            )
        case .custom:
            return DeskBridgePlan(
                agentName: agentName,
                terminalKind: terminalKind,
                setupCommand: nil,
                detail: "Custom terminal agents can still be mirrored into Desk through Workbench transcripts and notes."
            )
        }
    }
}

public struct WorkbenchSenseRenderer: Sendable {
    public init() {}

    public func render(state: WorkspaceState, summary: WorkspaceSummary, readiness: OnboardingReadiness? = nil) -> String {
        var lines: [String] = []
        lines.append("## workbench sense")
        lines.append("Ouro Workbench is my local machine sense for terminal/TUI agents. It is not a replacement for Claude Code, Codex, Copilot, or shell sessions; it is the room where I can observe them, inspect transcripts, and ask the native app to take auditable actions.")
        lines.append("")
        lines.append("boss: \(state.boss.agentName)")
        if let readiness {
            lines.append("readiness: \(readiness.state.rawValue) - \(readiness.headline)")
        }
        lines.append("status: \(summary.oneLineStatus)")
        lines.append("")
        lines.append("organization:")
        for project in state.projects {
            let entries = state.processEntries.filter { $0.projectId == project.id && !$0.isArchived }
            lines.append("- \(project.name): \(entries.count) active terminal\(entries.count == 1 ? "" : "s")")
        }
        lines.append("")
        lines.append("tools:")
        for tool in WorkbenchGuide.bossTools {
            lines.append("- \(tool.tool): \(tool.summary)")
        }
        lines.append("")
        lines.append("action protocol:")
        lines.append(WorkbenchGuide.actionProtocolMarkdown())
        lines.append("")
        lines.append("operator keyboard shortcuts (so I can answer how-do-I questions):")
        lines.append(WorkbenchGuide.shortcutsMarkdown())
        return lines.joined(separator: "\n")
    }
}
