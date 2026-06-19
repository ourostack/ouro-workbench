import Foundation
import Darwin
import OuroWorkbenchCore

@main
struct OuroWorkbenchMCP {
    static func main() {
        do {
            let diagnostics = try WorkbenchLaunchDiagnostics.parse(CommandLine.arguments)
            let paths = diagnostics.appSupportRoot.map { WorkbenchPaths(rootURL: $0) } ?? .defaultPaths()
            WorkbenchMCPServer(paths: paths).run()
        } catch {
            FileHandle.standardError.write(Data("Invalid Workbench MCP arguments: \(error.localizedDescription)\n".utf8))
            Darwin.exit(2)
        }
    }
}

final class WorkbenchMCPServer {
    private let paths: WorkbenchPaths
    private let store: WorkbenchStore
    private let queue: WorkbenchActionRequestQueue
    private let summarizer = WorkspaceSummarizer()
    private let promptBuilder = BossAgentPromptBuilder()
    private let bootstrapper = WorkbenchBootstrapper()
    private let authorizer = BossWorkbenchActionAuthorizer()
    private let executableHealthChecker = ExecutableHealthChecker()
    private let gitStatusReader = GitStatusReader()
    private let transcriptSearcher = TranscriptSearcher()
    private let recoveryDrill = RecoveryDrill()
    private let senseRenderer = WorkbenchSenseRenderer()
    private let sessionsRenderer = WorkbenchSessionsRenderer()
    private let visibilityBuilder = WorkbenchVisibilityBuilder()
    private let visibilityRenderer = WorkbenchVisibilityTextRenderer()
    private let workCardReader = OuroWorkCardReader()
    private let mailboxDashboardReader = MailboxDashboardSnapshotReader()
    private let onboardingAdvisor = WorkbenchOnboardingAdvisor()
    private let onboardingReportRenderer = OnboardingReadinessReportRenderer()
    private let ouroAgentInventory = OuroAgentInventory()
    private let bossWorkbenchMCPRegistrar = BossWorkbenchMCPRegistrar()
    private let daemonLivenessProbe = DaemonLivenessProbe()
    // Discovery of agent sessions the boss did NOT create. The scanner is pure
    // Core (FS via its homeURL seam); the lister is the executable-target Process
    // shell that feeds it the running-process table. The scanner builds no resume
    // commands and carries no agency knowledge — it returns GENERAL records only.
    private let agentSessionScanner = AgentSessionScanner()
    private let runningProcessLister = RunningProcessLister()
    // The boss's propose-for-approval CAPABILITY (NEVER a gate). `workbench_propose`
    // enqueues an editable `AgentProposal`; the App's native card lets the operator
    // tick/edit/approve; `workbench_proposal_result` reads the operator's decision
    // back. The boss may also just act — nothing here forces this round-trip.
    private let proposalQueue: AgentProposalQueue
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Deterministic key order (stable tests / diffs) + readable timestamps.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(paths: WorkbenchPaths = .defaultPaths()) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.queue = WorkbenchActionRequestQueue(paths: paths)
        self.proposalQueue = AgentProposalQueue(paths: paths)
    }

    func run() {
        while let line = readLine() {
            guard let response = handle(line: line) else {
                continue
            }
            write(response)
        }
    }

    private func handle(line: String) -> [String: Any]? {
        // Blank / whitespace keepalive lines carry no request — skip silently.
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard
            let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = request["method"] as? String
        else {
            // A non-empty line we can't parse as a JSON-RPC request: reply with
            // a parse error (id null) rather than silently dropping it, so the
            // caller never hangs waiting for a response. (One JSON object per
            // line is the contract — pretty-printed/batched input won't parse.)
            return error(id: nil, code: -32700, message: "Parse error: expected a single JSON-RPC object per line")
        }

        let id = request["id"]
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }

        do {
            switch method {
            case "initialize":
                return success(id: id, result: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": [
                        "name": WorkbenchRelease.mcpServerName,
                        "version": WorkbenchRelease.version
                    ]
                ])
            case "tools/list":
                return success(id: id, result: ["tools": toolDefinitions()])
            case "tools/call":
                let text = try callTool(params: request["params"] as? [String: Any] ?? [:])
                return toolResult(id: id, text: text, isError: false)
            default:
                return error(id: id, code: -32601, message: "Unknown method: \(method)")
            }
        } catch {
            return toolResult(id: id, text: error.localizedDescription, isError: true)
        }
    }

    private func callTool(params: [String: Any]) throws -> String {
        guard let name = params["name"] as? String else {
            throw MCPToolFailure("Missing tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "workbench_status":
            return try workbenchStatus()
        case OnboardingReadinessReportRenderer.toolName:
            return try onboardingStatus()
        case "workbench_sessions":
            return try sessionsList(arguments: arguments)
        case "workbench_visibility":
            return try workbenchVisibility(arguments: arguments)
        case "workbench_sense":
            return try workbenchSense()
        case "workbench_transcript_tail":
            return try transcriptTail(arguments: arguments)
        case "workbench_search_transcripts":
            return try searchTranscripts(arguments: arguments)
        case "workbench_recovery_drill":
            return try recoveryDrillReport()
        case "workbench_request_action":
            return try requestAction(arguments: arguments)
        case "workbench_create_session":
            return try createSession(arguments: arguments)
        case "workbench_discover_agent_sessions":
            return try discoverAgentSessions()
        case "workbench_propose":
            return try propose(arguments: arguments)
        case "workbench_proposal_result":
            return try proposalResult(arguments: arguments)
        default:
            throw MCPToolFailure("Unknown tool: \(name)")
        }
    }

    private func workbenchStatus() throws -> String {
        let state = try currentState()
        let summary = summarizer.summarize(state)
        // Collision-safe builders (keep first): `bootstrappedState` already
        // de-dups entries by id, but guard here too so a duplicate id can never
        // trap and crash the long-lived read-only server.
        let executableHealth = Dictionary(
            state.processEntries.map { entry in
                let executable = ExecutableHealthTarget.executable(for: entry)
                return (entry.id, executableHealthChecker.health(for: executable))
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Probe git per session (read-only, watchdog-bounded) so the boss's
        // primary read tool reports each session's branch / dirty / ahead-behind.
        let gitStatus = Dictionary(
            state.processEntries.map { entry in
                (entry.id, gitStatusReader.status(forDirectory: entry.workingDirectory))
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Inline the waiting prompt for each session that needs a human, so the
        // boss can decide without a separate workbench_transcript_tail call.
        // Only human-owned sessions: agent-owned sessions are driven by their
        // owning agent's loop, so the boss shouldn't be fed their prompts to act on.
        let waitingPrompts = Dictionary(
            state.processEntries
                .filter { !$0.isArchived && $0.attention == .waitingOnHuman && $0.owner.agentName == nil }
                .compactMap { entry -> (UUID, String)? in
                    guard let path = latestRun(for: entry.id, state: state)?.transcriptPath,
                          let tail = TranscriptTailReader(maxBytes: 1200).read(path: path) else {
                        return nil
                    }
                    let snippet = String(tail.text.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return snippet.isEmpty ? nil : (entry.id, snippet)
                },
            uniquingKeysWith: { first, _ in first }
        )
        return promptBuilder.checkInPrompt(
            question: "What is currently going on in Ouro Workbench?",
            state: state,
            summary: summary,
            dashboard: mailboxDashboardReader.read(boss: state.boss),
            executableHealth: executableHealth,
            gitStatus: gitStatus,
            machineFriend: SessionFriend.machineOwner(),
            waitingPrompts: waitingPrompts
        )
    }

    /// The daemon- and credential-aware onboarding readiness of the selected boss, rendered
    /// as the structured text the `workbench_onboarding_status` read tool returns. Mirrors
    /// `workbenchStatus()`: load state, scan the local agent inventory, snapshot the boss's
    /// MCP registration, probe daemon liveness, then hand all four to the pure
    /// `WorkbenchOnboardingAdvisor.readiness(...)` and render via the pure
    /// `OnboardingReadinessReportRenderer` (both unit-tested in Core).
    private func onboardingStatus() throws -> String {
        let state = try currentState()
        let agents = ouroAgentInventory.scan()
        let registration = bossWorkbenchMCPRegistrar.snapshot(for: state.boss)
        // Synchronous, Swift-concurrency-free probe: the MCP request loop drives tools
        // synchronously off `readLine()`, and bridging the async probe into that blocked
        // thread starves the cooperative executor (crashes the task allocator in a CLI
        // binary). The Core probe's `probeSynchronously()` uses a callback-based URLSession +
        // semaphore instead, so it is safe to block for here.
        let daemonLiveness = daemonLivenessProbe.probeSynchronously()
        let readiness = onboardingAdvisor.readiness(
            boss: state.boss,
            agents: agents,
            mcpRegistration: registration,
            daemonLiveness: daemonLiveness
        )
        return onboardingReportRenderer.render(readiness)
    }

    /// Machine-readable list of sessions for an outbound MCP client (the
    /// harness driving coding sessions through Workbench terminals). Returns
    /// `{"sessions": [SessionSnapshot, ...]}`. Unlike `workbench_status` (the
    /// boss's human-readable check-in prompt), this is structured JSON a client
    /// can parse to resolve a freshly-created session's id by `name` and to poll
    /// its `status` / `attention` / `needsHuman`.
    private func sessionsList(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        let snapshots = sessionsRenderer.snapshots(
            state: state,
            owner: try optionalString(arguments, key: "owner"),
            name: try optionalString(arguments, key: "name"),
            includeArchived: (try optionalBool(arguments, key: "includeArchived")) ?? false
        )
        return try encodeJSON(["sessions": snapshots])
    }

    private func workbenchSense() throws -> String {
        let state = try currentState()
        return senseRenderer.render(
            state: state,
            summary: summarizer.summarize(state)
        )
    }

    /// Read-only visibility plane for Workbench + Ouro durable work. This does
    /// not inspect transcript content or queue actions; it returns counts,
    /// source availability, and typed "unknown/unavailable" states.
    private func workbenchVisibility(arguments: [String: Any]) throws -> String {
        var state = try currentState()
        let agentName = try optionalString(arguments, key: "agent") ?? state.boss.agentName
        state.boss.agentName = agentName
        let workCard = workCardReader.read(agent: agentName)
        let snapshot = visibilityBuilder.build(state: state, workCard: workCard)
        let format = (try optionalString(arguments, key: "format"))?.lowercased() ?? "text"
        switch format {
        case "json":
            return try encodeJSON(snapshot)
        case "text":
            return visibilityRenderer.render(snapshot)
        default:
            throw MCPToolFailure("Invalid format: \(format)")
        }
    }

    private func transcriptTail(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        let entry = try targetEntry(arguments: arguments, state: state)
        let latestRun = latestRun(for: entry.id, state: state)
        let maxBytes = TranscriptTailLimit.clamped(uintArgument(arguments["maxBytes"]))
        guard let tail = TranscriptTailReader(maxBytes: maxBytes).read(path: latestRun?.transcriptPath) else {
            return "No transcript is available for \(entry.name)."
        }
        let marker = tail.truncated ? "latest \(maxBytes) bytes" : "complete transcript"
        return "\(entry.name) transcript (\(marker)):\n\(tail.text)"
    }

    private func searchTranscripts(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolFailure("Missing query")
        }
        let maxMatches = Int(TranscriptSearchLimit.clamped(uintArgument(arguments["maxMatches"])))
        let matches = transcriptSearcher.search(query: query, state: state, maxMatches: maxMatches)
        guard !matches.isEmpty else {
            return "No transcript matches for \(query)."
        }
        var lines = ["Transcript matches for \(query):"]
        for match in matches {
            let groupName = groupName(for: match.entryId, state: state) ?? "unknown"
            lines.append("- \(groupName) / \(match.entryName) line \(match.lineNumber) (\(match.transcriptPath)): \(match.line)")
        }
        return lines.joined(separator: "\n")
    }

    private func recoveryDrillReport() throws -> String {
        let state = try currentState()
        let result = recoveryDrill.run(state: state)
        var lines = ["Recovery drill: \(result.oneLineStatus)"]
        for item in result.items {
            let groupName = groupName(for: item.id, state: state) ?? "unknown"
            lines.append("- \(groupName) / \(item.entryName): \(item.beforeStatus?.rawValue ?? "none") -> \(item.afterStatus?.rawValue ?? "none"), action=\(item.action.rawValue), reason=\(item.reason)")
        }
        return lines.joined(separator: "\n")
    }

    private func requestAction(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        guard let rawAction = try optionalString(arguments, key: "action"),
              let actionKind = BossWorkbenchActionKind(rawValue: rawAction) else {
            throw MCPToolFailure("Missing or invalid action")
        }
        let trust: ProcessTrust?
        if let rawTrust = try optionalString(arguments, key: "trust") {
            guard let parsedTrust = ProcessTrust(rawValue: rawTrust) else {
                throw MCPToolFailure("Invalid trust value: \(rawTrust)")
            }
            trust = parsedTrust
        } else {
            trust = nil
        }
        let lane: ProviderLane?
        if let rawLane = try optionalString(arguments, key: "lane") {
            guard let parsedLane = ProviderLane(rawValue: rawLane) else {
                throw MCPToolFailure("Invalid lane value: \(rawLane)")
            }
            lane = parsedLane
        } else {
            lane = nil
        }
        let action = BossWorkbenchAction(
            action: actionKind,
            entry: try optionalString(arguments, key: "entry"),
            text: try optionalString(arguments, key: "text"),
            appendNewline: try optionalBool(arguments, key: "appendNewline") ?? true,
            group: try optionalString(arguments, key: "group"),
            name: try optionalString(arguments, key: "name"),
            command: try optionalString(arguments, key: "command"),
            workingDirectory: try optionalString(arguments, key: "workingDirectory"),
            trust: trust,
            autoResume: try optionalBool(arguments, key: "autoResume"),
            lane: lane,
            provider: try optionalString(arguments, key: "provider"),
            model: try optionalString(arguments, key: "model")
        )
        try action.validateForQueueing()

        let resolvedEntry: ProcessEntry?
        if let entryValue = action.entry, !entryValue.isEmpty {
            resolvedEntry = try targetEntry(value: entryValue, state: state)
        } else {
            resolvedEntry = nil
        }

        // Authorize EVERY action through the single gate — entry-scoped AND entry-less.
        // Previously entry-less actions skipped authorization entirely (the check ran only
        // `if let entry`); routing them through `authorizer.gate(...)` closes that bypass so an
        // unknown/unauthorized entry-less action is now rejected at enqueue. Entry-scoped
        // actions still run live's `livePrompt` sendInput safety floor inside the gate (the
        // enqueue path has no live transcript tail, so it forwards the default empty prompt —
        // the classifier still catches a verbatim-dangerous input, and the app apply path
        // re-classifies against the real live prompt before sending).
        let decision = authorizer.gate(action, resolvedEntry: resolvedEntry)
        guard decision.authorization.isAllowed else {
            throw MCPToolFailure("Action denied for \(decision.deniedTarget): \(decision.authorization.reason ?? "not authorized")")
        }
        let request = WorkbenchActionRequest(
            source: (arguments["source"] as? String) ?? "ouro-workbench-mcp",
            action: action
        )
        try queue.enqueue(request)
        let message: String
        if let entry = resolvedEntry {
            message = "Queued \(actionKind.rawValue) for \(entry.name) as \(request.id.uuidString)."
        } else {
            message = "Queued \(actionKind.rawValue) as \(request.id.uuidString)."
        }
        if try wantsJSON(arguments) {
            return try encodeJSON(ActionAck(ok: true, message: message, requestId: request.id.uuidString))
        }
        return message
    }

    /// Create and launch a coding session through Workbench, attributed to the
    /// calling agent. Queues a `createSession` action that the running app
    /// executes: it constructs a `ProcessEntry` with `owner: .agent(<owner>)`
    /// in the target group and launches it under the same trust gating and
    /// launch validation as a human-created terminal.
    ///
    /// The Workbench MCP is injected into the boss's turn at runtime (Workbench
    /// passes `--workbench-mcp` when it launches the boss) with no agent identity
    /// baked into its command/env, so the calling agent must pass its own name as
    /// `owner`. We validate it non-empty here; the app stamps it as the session owner.
    private func createSession(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        let trust: ProcessTrust?
        if let rawTrust = try optionalString(arguments, key: "trust") {
            guard let parsedTrust = ProcessTrust(rawValue: rawTrust) else {
                throw MCPToolFailure("Invalid trust value: \(rawTrust)")
            }
            trust = parsedTrust
        } else {
            trust = nil
        }
        let action = BossWorkbenchAction(
            action: .createSession,
            text: try optionalString(arguments, key: "notes"),
            group: try optionalString(arguments, key: "group"),
            name: try optionalString(arguments, key: "name"),
            command: try optionalString(arguments, key: "command"),
            workingDirectory: try optionalString(arguments, key: "workingDirectory"),
            trust: trust,
            autoResume: try optionalBool(arguments, key: "autoResume"),
            owner: try optionalString(arguments, key: "owner")
        )
        // Surfaces missing name / command / owner as a clear tool error before
        // anything is queued (the app re-validates on drain).
        try action.validateForQueueing()

        // Resolve the target group now so the caller gets immediate feedback
        // instead of a silent app-side skip. The group must already exist —
        // create one first via `workbench_request_action` (action createGroup)
        // if needed. A nil/empty group defers to the app's selected group.
        let resolvedGroup = try resolveGroup(action.group, state: state)

        let request = WorkbenchActionRequest(
            source: (arguments["source"] as? String) ?? "ouro-workbench-mcp",
            action: action
        )
        try queue.enqueue(request)
        let ownerName = action.owner ?? ""
        let groupSuffix = resolvedGroup.map { " in \($0.name)" } ?? ""
        let message = "Queued createSession \(action.name ?? "session")\(groupSuffix) owned by \(ownerName) as \(request.id.uuidString)."
        if try wantsJSON(arguments) {
            // The create is queued — the running app builds the session and
            // assigns its id. Poll `workbench_sessions` with this `name` to
            // resolve the id once the app's pump has drained the request.
            return try encodeJSON(CreateAck(
                queued: true,
                name: action.name,
                group: resolvedGroup?.name,
                owner: action.owner,
                requestId: request.id.uuidString,
                message: message
            ))
        }
        return message
    }

    /// Resolve a target group (project) by UUID or unique name for createSession.
    /// A nil/empty value defers to the app (it uses the selected/first group),
    /// so this returns nil in that case. A non-empty value that doesn't match a
    /// unique existing group throws so the caller learns the group is missing.
    private func resolveGroup(_ value: String?, state: WorkspaceState) throws -> WorkbenchProject? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let id = UUID(uuidString: value), let project = state.projects.first(where: { $0.id == id }) {
            return project
        }
        let matches = state.projects.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        guard matches.count == 1, let project = matches.first else {
            throw MCPToolFailure("No unique group matches \(value). Create it first via workbench_request_action (createGroup).")
        }
        return project
    }

    /// Discover agent sessions the boss did NOT create — recent (on disk:
    /// Claude `~/.claude/projects`, Copilot `~/.copilot/session-state`) and
    /// running (the live process table, via the executable-side lister). Returns
    /// `{"sessions": [AgentSessionRecord, ...]}` — GENERAL records (harness,
    /// sessionId, cwd, repository, branch, title, lastActive, running) and nothing
    /// more. Workbench builds NO resume command and carries zero agency knowledge:
    /// the boss reads these facts and constructs any relaunch itself.
    ///
    /// Synchronous, matching the readLine-driven request loop. The lister degrades
    /// to recent-only on any `ps` failure, and the scanner's FS reads are
    /// best-effort (a missing dir is simply no records), so this never throws on a
    /// merely-empty environment — it returns `{"sessions": []}`.
    private func discoverAgentSessions() throws -> String {
        let records = agentSessionScanner.scan(processLister: runningProcessLister.callAsFunction)
        return try encodeJSON(["sessions": records])
    }

    /// Show the operator an editable plan and get their ticks/edits/approvals
    /// back. A CAPABILITY the boss reaches for when it judges a plan should be
    /// confirmed — NEVER a gate: the boss may also just act (`workbench_create_session`,
    /// `workbench_request_action`). Enqueues a GENERAL `AgentProposal` (a titled
    /// list of items the operator toggles/edits in a native card) via
    /// `AgentProposalQueue` and returns its `proposalId`. The boss later reads the
    /// operator's decision with `workbench_proposal_result`. Workbench attaches no
    /// meaning to the items — the boss decides what they mean.
    private func propose(arguments: [String: Any]) throws -> String {
        guard let title = try optionalString(arguments, key: "title"), !title.isEmpty else {
            throw MCPToolFailure("Missing title")
        }
        guard let rawItems = arguments["items"] as? [Any] else {
            throw MCPToolFailure("items must be an array")
        }
        let items = try rawItems.enumerated().map { index, raw in
            try parseProposalItem(raw, fallbackIndex: index)
        }
        // The boss may supply a stable id to correlate; otherwise we assign one and
        // return it so the boss can poll the result.
        let proposalId = (try optionalString(arguments, key: "id")).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString
        let proposal = AgentProposal(id: proposalId, title: title, items: items)
        try proposalQueue.enqueue(proposal)
        return try encodeJSON(ProposeAck(
            ok: true,
            proposalId: proposalId,
            itemCount: items.count,
            message: "Proposal \(proposalId) queued with \(items.count) item(s). The operator reviews it in Workbench; poll workbench_proposal_result with this proposalId for their decision."
        ))
    }

    /// Read back the operator's decision for a proposal (the SELECTED, possibly
    /// edited items). Returns `{"ready": false}` until the operator has acted, then
    /// `{"ready": true, "result": {id, items:[...]}}`. The boss polls this after
    /// `workbench_propose`. A proposal the operator hasn't answered yet is simply
    /// not-ready (never an error), so the boss can poll without special-casing.
    private func proposalResult(arguments: [String: Any]) throws -> String {
        guard let proposalId = try optionalString(arguments, key: "proposalId"), !proposalId.isEmpty else {
            throw MCPToolFailure("Missing proposalId")
        }
        guard let result = proposalQueue.readResult(id: proposalId) else {
            return try encodeJSON(ProposalResultAck(ready: false, result: nil))
        }
        return try encodeJSON(ProposalResultAck(ready: true, result: result))
    }

    /// Parse one proposal item from the tool's `items` array. GENERAL: a label
    /// (required) plus optional detail/command/cwd/harness/selected/editableFields.
    /// `selected` defaults true (the boss proposes items expecting them ticked);
    /// `editableFields` defaults to every field so the operator can edit freely
    /// unless the boss narrows it.
    private func parseProposalItem(_ raw: Any, fallbackIndex: Int) throws -> AgentProposalItem {
        guard let dict = raw as? [String: Any] else {
            throw MCPToolFailure("Each item must be an object")
        }
        guard let label = try optionalString(dict, key: "label"), !label.isEmpty else {
            throw MCPToolFailure("Each item must have a non-empty label")
        }
        let id = (try optionalString(dict, key: "id")).flatMap { $0.isEmpty ? nil : $0 }
            ?? "item-\(fallbackIndex)"
        let harness: AgentHarness?
        if let rawHarness = try optionalString(dict, key: "harness") {
            // Unknown raw → .custom (mirrors AgentHarness's own decode); never throws.
            harness = AgentHarness(rawValue: rawHarness) ?? .custom
        } else {
            harness = nil
        }
        let editableFields: [AgentProposalItem.Field]
        if let rawFields = dict["editableFields"] as? [Any] {
            // Drop unknown field names (newer-producer tolerant), like the model's
            // own decode does.
            editableFields = rawFields.compactMap { ($0 as? String).flatMap(AgentProposalItem.Field.init(rawValue:)) }
        } else {
            editableFields = AgentProposalItem.Field.allCases
        }
        return AgentProposalItem(
            id: id,
            label: label,
            detail: try optionalString(dict, key: "detail"),
            command: try optionalString(dict, key: "command"),
            cwd: try optionalString(dict, key: "cwd"),
            harness: harness,
            selected: (try optionalBool(dict, key: "selected")) ?? true,
            editableFields: editableFields
        )
    }

    private func optionalString(_ arguments: [String: Any], key: String) throws -> String? {
        guard let value = arguments[key] else {
            return nil
        }
        guard let string = value as? String else {
            throw MCPToolFailure("\(key) must be a string")
        }
        return string
    }

    private func optionalBool(_ arguments: [String: Any], key: String) throws -> Bool? {
        guard let value = arguments[key] else {
            return nil
        }
        guard let bool = value as? Bool else {
            throw MCPToolFailure("\(key) must be a boolean")
        }
        return bool
    }

    private func currentState() throws -> WorkspaceState {
        // Read-only: never quarantine. The MCP server shares the app's state
        // file but doesn't own it — moving it aside on a transient read or a
        // schema bump (seen by a stale MCP binary) would destroy the app's
        // live workspace. Quarantine is the owning app's decision alone.
        bootstrapper.bootstrappedState(from: try store.load(quarantineCorruptFile: false))
    }

    private func targetEntry(arguments: [String: Any], state: WorkspaceState) throws -> ProcessEntry {
        guard let value = arguments["entry"] as? String, !value.isEmpty else {
            throw MCPToolFailure("Missing entry")
        }
        return try targetEntry(value: value, state: state)
    }

    private func targetEntry(value: String, state: WorkspaceState) throws -> ProcessEntry {
        if let id = UUID(uuidString: value), let entry = state.processEntries.first(where: { $0.id == id }) {
            return entry
        }
        let matches = state.processEntries.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        guard matches.count == 1, let entry = matches.first else {
            throw MCPToolFailure("No unique process entry matches \(value)")
        }
        return entry
    }

    private func latestRun(for entryId: UUID, state: WorkspaceState) -> ProcessRun? {
        state.processRuns
            .filter { $0.entryId == entryId }
            .sorted(by: ProcessRun.isMoreRecent)
            .first
    }

    private func groupName(for entryId: UUID, state: WorkspaceState) -> String? {
        guard let entry = state.processEntries.first(where: { $0.id == entryId }) else {
            return nil
        }
        return state.projects.first { $0.id == entry.projectId }?.name
    }

    private func uintArgument(_ value: Any?) -> UInt64? {
        if let int = value as? Int, int > 0 {
            return UInt64(int)
        }
        if let double = value as? Double, double > 0 {
            guard double.isFinite, double <= Double(UInt64.max) else {
                return UInt64.max
            }
            return UInt64(double)
        }
        return nil
    }

    /// Whether the caller asked for a structured JSON result (`format: "json"`).
    /// Default is the human-readable text the boss has always received, so
    /// opting in never regresses an existing caller.
    private func wantsJSON(_ arguments: [String: Any]) throws -> Bool {
        (try optionalString(arguments, key: "format"))?.lowercased() == "json"
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try jsonEncoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPToolFailure("Failed to encode JSON response")
        }
        return text
    }

    /// `format: "json"` acknowledgement for `workbench_request_action`.
    private struct ActionAck: Encodable {
        let ok: Bool
        let message: String
        let requestId: String
    }

    /// `format: "json"` acknowledgement for `workbench_create_session`. The
    /// create is queued (the running app's pump builds the session), so this
    /// carries the `name` to poll `workbench_sessions` for, not a session id.
    private struct CreateAck: Encodable {
        let queued: Bool
        let name: String?
        let group: String?
        let owner: String?
        let requestId: String
        let message: String
    }

    /// Acknowledgement for `workbench_propose`: the assigned `proposalId` the boss
    /// polls `workbench_proposal_result` with.
    private struct ProposeAck: Encodable {
        let ok: Bool
        let proposalId: String
        let itemCount: Int
        let message: String
    }

    /// `workbench_proposal_result` reply. `ready` is false until the operator has
    /// answered; once true, `result` carries the SELECTED, possibly-edited items.
    private struct ProposalResultAck: Encodable {
        let ready: Bool
        let result: AgentProposalResult?
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "workbench_status",
                "description": "Summarize Ouro Workbench state, processes, recovery plans, and transcript paths.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": OnboardingReadinessReportRenderer.toolName,
                "description": OnboardingReadinessReportRenderer.toolDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_sessions",
                "description": "Machine-readable JSON list of Workbench sessions for programmatic clients (use workbench_status for the human-readable check-in prompt). Returns {\"sessions\":[{id,name,group,owner:{kind,name},kind,status,attention,needsHuman,trust,autoResume,isArchived,isPinned,pid,exitCode,workingDirectory,transcriptPath,startedAt,lastOutputAt}]}. status is the latest run's state (configured|running|exited|waitingForInput|needsRecovery|manualActionNeeded); attention is idle|active|waitingOnHuman|blocked|needsBossReview. Optional fields are omitted when not applicable. After workbench_create_session, poll this with `name` set to your unique session name to resolve the new session's id and watch its status.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string", "description": "Return only sessions owned by this agent name (owner:agent:<name>). Omit for all owners."],
                        "name": ["type": "string", "description": "Return only sessions whose name matches case-insensitively. Use to resolve the id of a session you just created."],
                        "includeArchived": ["type": "boolean", "description": "Include archived sessions. Defaults to false."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_visibility",
                "description": "Read-only visibility snapshot for Workbench sessions, boss decisions, and the selected Ouro agent's durable Work Card. Returns typed unavailable/unknown fields instead of false zeroes; does not include transcript content or queue actions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent": ["type": "string", "description": "Ouro agent name to read with `ouro work card`. Defaults to Workbench's selected boss agent."],
                        "format": ["type": "string", "enum": ["text", "json"], "description": "Response format. \"json\" returns the structured visibility snapshot; default \"text\" returns a concise human-readable summary."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_sense",
                "description": "Render the Workbench sense contract for the selected Ouro agent: boss/terminal boundaries, available Workbench tools, the ouro-workbench-actions protocol, and the operator keyboard shortcuts (so the boss can answer how-do-I questions).",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_transcript_tail",
                "description": "Read a bounded tail from the latest transcript for a Workbench process entry.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "entry": ["type": "string", "description": "Process UUID or unique process name."],
                        "maxBytes": [
                            "type": "number",
                            "maximum": Double(TranscriptTailLimit.maximumBytes),
                            "description": "Maximum bytes to read from the end of the transcript. Values above the server cap are clamped."
                        ]
                    ],
                    "required": ["entry"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_search_transcripts",
                "description": "Search saved Workbench transcript text across process runs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Case-insensitive text to search for."],
                        "maxMatches": [
                            "type": "number",
                            "maximum": Double(TranscriptSearchLimit.maximumMatches),
                            "description": "Maximum number of matching transcript lines to return. Values above the server cap are clamped."
                        ]
                    ],
                    "required": ["query"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_recovery_drill",
                "description": "Dry-run restart recovery planning for current Workbench sessions without mutating state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_request_action",
                "description": "Queue an auditable Workbench action for the native app to apply. Entry-scoped actions target a trusted process entry; the entry-less onboarding remediations target an agent by its explicit `name` (never default-agent resolution): `repairAgent` repairs an agent's vault/provider readiness, `requestProviderConfig` opens the native provider-setup form (the ONE human touchpoint) so the human can connect or refresh a provider — entry-less, carries no secret, needs no agent name, `verifyProvider` checks an agent's provider connection (optionally for a single `lane`), `refreshProvider` re-pushes an agent's stored credentials into the running daemon, `selectLane` sets an agent's `lane` provider/model (config-only, no secret), `registerWorkbenchMCP` connects an agent to Workbench, and `ensureDaemon` brings the local daemon online (machine-scoped — no agent name). Applying is asynchronous (a 2s pump drains the queue): this call returns only an enqueue ack, NOT the result. To learn whether a remediation actually worked, read the agent's readiness again and narrate from THAT, never from this ack.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["launch", "recover", "terminate", "sendInput", "createGroup", "createTerminal", "moveSession", "setTrust", "setAutoResume", "archive", "restore", "repairAgent", "requestProviderConfig", "verifyProvider", "refreshProvider", "selectLane", "registerWorkbenchMCP", "ensureDaemon"]],
                        "entry": ["type": "string", "description": "Process UUID or unique process name for entry-scoped actions."],
                        "text": ["type": "string", "description": "Required non-empty input text when action is sendInput."],
                        "appendNewline": ["type": "boolean"],
                        "group": ["type": "string", "description": "Group UUID or unique group name for createTerminal and moveSession."],
                        "name": ["type": "string", "description": "Required for createGroup and createTerminal; and the explicit agent name (never default-agent resolution) for the agent-targeted onboarding remediations repairAgent, verifyProvider, refreshProvider, selectLane, and registerWorkbenchMCP. Omit for ensureDaemon (machine-scoped)."],
                        "command": ["type": "string", "description": "Required command for createTerminal."],
                        "workingDirectory": ["type": "string", "description": "Group root path or terminal working directory."],
                        "trust": ["type": "string", "enum": ["trusted", "untrusted"]],
                        "autoResume": ["type": "boolean"],
                        "lane": ["type": "string", "enum": ["outward", "inner"], "description": "Provider lane (outward = human-facing, inner = agent-facing). Optional for verifyProvider (omit = whole-agent verify); required for selectLane."],
                        "provider": ["type": "string", "description": "Provider id for selectLane (config-only, never a secret)."],
                        "model": ["type": "string", "description": "Model id for selectLane (config-only, never a secret)."],
                        "source": ["type": "string", "description": "Agent or tool requesting the action."],
                        "format": ["type": "string", "enum": ["text", "json"], "description": "Response format. \"json\" returns {ok,message,requestId} for programmatic callers; default \"text\" returns a human-readable confirmation."]
                    ],
                    "required": ["action"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_create_session",
                "description": "Create and launch a coding session through Workbench, owned by the calling agent. The session appears as a first-class Workbench session tagged owner:agent:<owner>, with the same trust gating and launch validation as a human-created terminal. The Workbench MCP is registered without an agent identity, so you must pass your own agent name as `owner`. The target `group` must already exist (create one first via workbench_request_action with action createGroup if needed); omit it to use the currently-selected group.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string", "description": "Your agent name. Stamped as the session owner (owner:agent:<owner>). Required, non-empty."],
                        "name": ["type": "string", "description": "Session name shown in the Workbench sidebar. Required."],
                        "command": ["type": "string", "description": "The shell command / coding agent to run (e.g. \"codex --yolo\" or \"claude\"). Required."],
                        "group": ["type": "string", "description": "Target group UUID or unique group name. Must already exist. Omit to use the selected group."],
                        "workingDirectory": ["type": "string", "description": "Working directory for the session. Defaults to the group's root path."],
                        "trust": ["type": "string", "enum": ["trusted", "untrusted"], "description": "Session trust. Defaults to untrusted; an untrusted session is created but not auto-driven by the boss."],
                        "autoResume": ["type": "boolean", "description": "Whether the session auto-resumes after a crash / restart. Defaults to false."],
                        "notes": ["type": "string", "description": "Optional notes attached to the session."],
                        "source": ["type": "string", "description": "Agent or tool requesting the action (for the audit log)."],
                        "format": ["type": "string", "enum": ["text", "json"], "description": "Response format. \"json\" returns {queued,name,group,owner,requestId,message} — poll workbench_sessions with `name` to resolve the new session id. Default \"text\" returns a human-readable confirmation."]
                    ],
                    "required": ["owner", "name", "command"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_discover_agent_sessions",
                "description": "Discover agent CLI sessions that were NOT created through Workbench — recent (on disk: Claude Code under ~/.claude/projects, GitHub Copilot CLI under ~/.copilot/session-state) and currently running (the live process table). Returns {\"sessions\":[{harness,sessionId,cwd,repository,branch,title,lastActive,running}]} sorted running-first then most-recent. harness is one of claudeCode|githubCopilotCLI|openAICodex|custom; repository/branch/title/lastActive are omitted when the source didn't carry them. These are GENERAL facts only — Workbench builds NO resume command and has zero knowledge of which agent owns what: YOU read these records and construct any relaunch (e.g. `claude --resume <sessionId>` in `cwd`) yourself. Returns {\"sessions\":[]} when nothing is found.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_propose",
                "description": "Show the operator an editable plan and get their ticks/edits/approvals back. This is a CAPABILITY, NOT a gate — reach for it when YOU judge a plan should be confirmed; you can also just act (workbench_create_session, workbench_request_action) without ever proposing. Workbench attaches NO meaning to the items: a proposal is a titled list of general items (label + optional detail/command/cwd/harness), and YOU decide what they mean. The operator reviews them in a native Workbench card, ticks/edits/approves per item, and their decision flows back to you. Returns {ok,proposalId,itemCount,message}; poll workbench_proposal_result with the proposalId to read the operator's approved (and possibly edited) items. selected defaults true; editableFields defaults to all of label/detail/command/cwd unless you narrow it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Operator-facing heading for the card (e.g. \"Bring back your work\"). Required, non-empty."],
                        "id": ["type": "string", "description": "Optional stable id to correlate the result. Omit to have one assigned and returned."],
                        "items": [
                            "type": "array",
                            "description": "The proposed items, in presentation order. Each is a general object — Workbench attaches no meaning.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string", "description": "Optional stable item id. Defaults to item-<index>."],
                                    "label": ["type": "string", "description": "Operator-facing item label. Required, non-empty."],
                                    "detail": ["type": "string", "description": "Optional supporting detail shown under the label."],
                                    "command": ["type": "string", "description": "Optional command you'd run if this item is approved (e.g. a resume command). Display/edit only — Workbench does not execute it."],
                                    "cwd": ["type": "string", "description": "Optional working directory associated with the item."],
                                    "harness": ["type": "string", "enum": ["claudeCode", "githubCopilotCLI", "openAICodex", "custom"], "description": "Optional harness tag. Unknown values map to custom."],
                                    "selected": ["type": "boolean", "description": "Whether the item is ticked by default. Defaults to true."],
                                    "editableFields": ["type": "array", "items": ["type": "string", "enum": ["label", "detail", "command", "cwd"]], "description": "Which fields the operator may edit in the card. Defaults to all four; unknown names are ignored."]
                                ],
                                "required": ["label"],
                                "additionalProperties": false
                            ]
                        ]
                    ],
                    "required": ["title", "items"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_proposal_result",
                "description": "Read back the operator's decision for a proposal you created with workbench_propose. Returns {ready:false} until the operator has reviewed it, then {ready:true,result:{id,items:[...]}} carrying ONLY the items the operator kept selected, with any edits they made (label/detail/command/cwd). Poll this after proposing. A not-yet-answered proposal is simply not-ready, never an error.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "proposalId": ["type": "string", "description": "The proposalId returned by workbench_propose. Required."]
                    ],
                    "required": ["proposalId"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private func success(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func toolResult(id: Any?, text: String, isError: Bool) -> [String: Any] {
        success(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ])
    }

    private func error(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
    }

    private func write(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            print(text)
            fflush(stdout)
            return
        }
        // Serialization failed (should never happen for our String/Dict
        // responses, but never hang the caller): emit a minimal, guaranteed
        // valid reply. id is dropped to null since the unserializable value
        // may be the id itself.
        print(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: response could not be serialized"}}"#)
        fflush(stdout)
    }
}

struct MCPToolFailure: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
