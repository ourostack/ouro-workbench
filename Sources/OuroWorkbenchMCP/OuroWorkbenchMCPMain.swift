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
    // The boss's one-call attention queue (#U24): the needs-human sessions, each
    // with the inline waiting-prompt the operator path computes, in triage order.
    private let attentionQueueRenderer = WorkbenchAttentionQueueRenderer()
    // The boss's requestId readback (#U24): classifies a queued request's outcome
    // (queued|applied|failed|unknown) from the live queue + the action log.
    private let actionResultClassifier = WorkbenchActionResultClassifier()
    // The boss's read-only TTFA sensor (#U20): builds the same AutonomyReadinessSnapshot the
    // operator's popover shows, then shapes it into the boss-relayable readout (per-check fix:
    // boss-queueable verb vs operator one-tap vs degraded). Read-only — names fixes, queues none.
    private let autonomyReadinessBuilder = AutonomyReadinessBuilder()
    private let autonomyAvailabilityBuilder = AutonomyRemediationAvailabilityBuilder()
    private let autonomyReadinessRenderer = WorkbenchAutonomyReadinessRenderer()
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
    // F10a JSON-RPC-layer dedup. Keyed on the JSON-RPC envelope `id`, this is a
    // DISTINCT layer from the action-fingerprint dedup in
    // WorkbenchActionRequestQueue (which dedups by side effect). Both stay: this
    // catches a same-id retry/replay/reconnect before any side-effecting handler
    // runs; the queue catches a different-id same-effect. NOTE: this `var` is not
    // thread-safe — today's run() is a synchronous readLine loop so no concurrent
    // access occurs; a future concurrent rewrite would wrap it in an actor.
    private var dedupLedger = MCPRequestDedupLedger()
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
            return errorResponse(id: nil, MCPError.parseError(detail: "expected a single JSON-RPC object per line"))
        }

        let id = request["id"]
        // Notifications carry no id and expect no reply — short-circuit BEFORE
        // the dedup ledger so a notification never enters it (and structurally,
        // MCPRequestKey.from would return nil for it anyway).
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }

        // F10a JSON-RPC-layer dedup, scoped to SIDE-EFFECTING tools and keyed on
        // request IDENTITY (envelope id + method + a stable params hash) by the pure
        // `MCPDispatchDedup` seam. Reads + handshakes ALWAYS process fresh — caching
        // a read replays stale data on a re-read; and a recycled id for different
        // content is a distinct key, so it can never replay an unrelated response.
        //   .passThroughFresh → a read/handshake (or an unkeyable side-effecting
        //                       call): dispatch fresh, no ledger interaction;
        //   .replayCached     → a byte-identical side-effecting retry: return the
        //                       ORIGINAL response verbatim, never re-enter dispatch;
        //   .rejectInFlight   → the original side-effecting call is still running;
        //   .proceed          → first sight of a side-effecting call: dispatch, then
        //                       complete(...) below.
        // Date() lives only here at the call boundary; the seam + ledger are pure.
        let (decision, afterObserve) = MCPDispatchDedup.decide(request: request, ledger: dedupLedger, now: Date())
        dedupLedger = afterObserve
        switch decision {
        case let .replayCached(cached):
            return cached.payload
        case .rejectInFlight:
            return errorResponse(id: id, MCPError.duplicateInFlight(id: "\(id ?? NSNull())"))
        case .passThroughFresh, .proceed:
            break
        }

        // ONE exit. Compute `response` on BOTH the success and the thrown arm,
        // then complete the ledger and return — so complete() fires whether the
        // handler succeeded or threw. A thrown handler RELEASES its in-flight
        // slot (response: nil) so its retry can proceed; a produced response
        // (incl. an isError:true tools/call result) is cached as final.
        // complete() is a no-op for the .passThroughFresh path (a read never
        // entered the ledger, and must never be cached).
        let response: [String: Any]
        let cacheable: MCPDedupCachedResponse?
        do {
            switch method {
            case "initialize":
                response = success(id: id, result: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": [
                        "name": WorkbenchRelease.mcpServerName,
                        "version": WorkbenchRelease.version
                    ]
                ])
            case "tools/list":
                response = success(id: id, result: ["tools": toolDefinitions()])
            case "tools/call":
                let text = try callTool(params: request["params"] as? [String: Any] ?? [:])
                response = toolResult(id: id, text: text, isError: false)
            default:
                response = errorResponse(id: id, MCPError.methodNotFound(method: method))
            }
            // A produced response is the final, deterministic answer for this id
            // — cache it so a retry replays it byte-for-byte (same request.id).
            cacheable = MCPDedupCachedResponse(payload: response)
        } catch {
            // A thrown handler is transient: surface the failure as an isError
            // tools/call result, but RELEASE the in-flight slot (don't cache a
            // transient failure as the permanent answer) so a retry re-executes.
            response = toolResult(id: id, text: error.localizedDescription, isError: true)
            cacheable = nil
        }

        dedupLedger = MCPDispatchDedup.complete(request: request, response: cacheable, ledger: dedupLedger, now: Date())
        return response
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
        case WorkbenchAutonomyReadinessRenderer.toolName:
            return try autonomyReadiness()
        case "workbench_sessions":
            return try sessionsList(arguments: arguments)
        case WorkbenchAttentionQueueRenderer.toolName:
            return try attentionQueue()
        case "workbench_action_result":
            return try actionResult(arguments: arguments)
        case "workbench_visibility":
            return try workbenchVisibility(arguments: arguments)
        case "workbench_sense":
            return try workbenchSense()
        case "workbench_transcript_tail":
            return try transcriptTail(arguments: arguments)
        case "workbench_session_health":
            return try sessionHealth(arguments: arguments)
        case "workbench_search_transcripts":
            return try searchTranscripts(arguments: arguments)
        case "workbench_recovery_drill":
            return try recoveryDrillReport()
        case "workbench_request_action":
            return try requestAction(arguments: arguments)
        case "workbench_create_session":
            return try createSession(arguments: arguments)
        case WorkbenchReportBugRenderer.toolName:
            return try reportBug(arguments: arguments)
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
        // F10b Option B: for the boss's highest-traffic read, render a
        // newer-schema state as first-class CONTENT ("upgrade Workbench") rather
        // than an error string — the main check-in shouldn't read as a failure
        // when the only problem is a stale binary against intact data. ONLY the
        // schema case becomes content; genuine corruption (.stateUnreadable) and
        // every other read tool re-throw and surface honestly through Seam A
        // (WorkbenchStoreError: LocalizedError) in the dispatch catch.
        let state: WorkspaceState
        do {
            state = try currentState()
        } catch {
            if let reason = degradedReadReason(for: error),
               case .stateWrittenByNewerWorkbench = reason {
                return reason.advisory
            }
            throw error
        }
        let summary = summarizer.summarize(state)
        // Collision-safe builders (keep first): `bootstrappedState` already
        // de-dups entries by id, but guard here too so a duplicate id can never
        // trap and crash the long-lived read-only server.
        let executableHealth = executableHealthByEntry(state)
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
        // One-line TTFA autonomy verdict (#U20): the same boss-relayable "get to green" summary the
        // workbench_autonomy_readiness sensor returns, folded in so the boss sees hands-off
        // readiness without a second call and is pointed at that tool to queue the fixes.
        let autonomyVerdict = autonomyReadinessReadout(
            state: state,
            summary: summary,
            executableHealth: executableHealth
        ).summary
        return promptBuilder.checkInPrompt(
            question: "What is currently going on in Ouro Workbench?",
            state: state,
            summary: summary,
            dashboard: mailboxDashboardReader.read(boss: state.boss),
            executableHealth: executableHealth,
            gitStatus: gitStatus,
            machineFriend: SessionFriend.machineOwner(),
            waitingPrompts: waitingPrompts,
            autonomyVerdict: autonomyVerdict
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

    /// The boss's read-only TTFA autonomy-readiness snapshot (#U20). Builds the SAME
    /// `AutonomyReadinessSnapshot` the operator's in-app popover shows (boss/bridge/trust/resume/
    /// executables/recovery/watch checks) plus the matching live fix-availability gate, then shapes
    /// both into the boss-relayable `AutonomyReadinessReadout` JSON: overall state, per-check fix
    /// (boss-queueable `request_action` verb vs operator one-tap vs degraded), and one human-
    /// relayable "get to green" summary. A SENSOR — it reads state and queues nothing; the boss
    /// acts on the named verbs via `workbench_request_action`, or relays the operator one-taps.
    private func autonomyReadiness() throws -> String {
        let state = try currentState()
        let readout = autonomyReadinessReadout(
            state: state,
            summary: summarizer.summarize(state),
            executableHealth: executableHealthByEntry(state)
        )
        return try encodeJSON(readout)
    }

    /// Build the boss-relayable TTFA readout from a state + summary (#U20). Shared by the
    /// `workbench_autonomy_readiness` sensor and `workbench_status`'s one-line autonomy verdict, so
    /// both surfaces read the SAME snapshot + fix-availability gate and can never disagree.
    private func autonomyReadinessReadout(
        state: WorkspaceState,
        summary: WorkspaceSummary,
        executableHealth: [UUID: ExecutableHealth]
    ) -> AutonomyReadinessReadout {
        let registration = bossWorkbenchMCPRegistrar.snapshot(for: state.boss)
        let snapshot = autonomyReadinessBuilder.build(
            state: state,
            summary: summary,
            mcpRegistration: registration,
            executableHealth: executableHealth,
            bossWatchIsEnabled: state.bossWatchEnabled
        )
        let availability = autonomyAvailabilityBuilder.availability(
            state: state,
            summary: summary,
            mcpRegistration: registration
        )
        return autonomyReadinessRenderer.readout(snapshot: snapshot, availability: availability)
    }

    /// Collision-safe per-entry executable health (keep first), shared by every read tool that
    /// reports executable availability.
    private func executableHealthByEntry(_ state: WorkspaceState) -> [UUID: ExecutableHealth] {
        Dictionary(
            state.processEntries.map { entry in
                (entry.id, executableHealthChecker.health(for: ExecutableHealthTarget.executable(for: entry)))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Machine-readable list of sessions for an outbound MCP client (the
    /// harness driving coding sessions through Workbench terminals). Returns
    /// `{"sessions": [SessionSnapshot, ...]}`. Unlike `workbench_status` (the
    /// boss's human-readable check-in prompt), this is structured JSON a client
    /// can parse to resolve a freshly-created session's id by `name` and to poll
    /// its `status` / `attention` / `needsHuman`.
    private func sessionsList(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        let attention = try optionalStringArray(arguments, key: "attention").map(Set.init)
        // Attach the inline waiting-prompt the operator path computes, so a boss
        // querying the attention queue via this filter gets the same per-row
        // context the workbench_attention_queue alias provides (#U24).
        let snapshots = sessionsRenderer.snapshots(
            state: state,
            owner: try optionalString(arguments, key: "owner"),
            name: try optionalString(arguments, key: "name"),
            attention: attention,
            includeArchived: (try optionalBool(arguments, key: "includeArchived")) ?? false,
            promptSnippets: attention == nil ? [:] : waitingPromptSnippets(state: state)
        )
        return try encodeJSON(["sessions": snapshots])
    }

    /// The boss's one-call attention queue (#U24): only the sessions that need a
    /// human, each with the same inline waiting-prompt the operator path computes,
    /// in triage order — so the boss reports "what's waiting on me" in a single
    /// cheap round-trip instead of fetching the whole machine.
    private func attentionQueue() throws -> String {
        let state = try currentState()
        let queue = attentionQueueRenderer.queue(
            state: state,
            promptSnippets: waitingPromptSnippets(state: state)
        )
        return try encodeJSON(["sessions": queue])
    }

    /// Read back the outcome of a queued `workbench_request_action` by its
    /// requestId (#U24). Mirrors `workbench_proposal_result`'s not-ready/ready
    /// shape: a request the app hasn't drained yet polls cleanly as `queued`
    /// (never an error); once drained + applied, the action-log entry stamped
    /// with that requestId resolves it to `applied`/`failed` with the result text.
    private func actionResult(arguments: [String: Any]) throws -> String {
        guard let requestId = try optionalString(arguments, key: "requestId"), !requestId.isEmpty else {
            throw MCPToolFailure("Missing requestId")
        }
        let stillQueued: Bool
        if let uuid = UUID(uuidString: requestId) {
            stillQueued = queue.isPendingOrProcessing(requestId: uuid)
        } else {
            // A malformed id is never in the queue (whose filenames carry UUIDs);
            // it resolves to unknown via the log lookup below.
            stillQueued = false
        }
        let state = try currentState()
        let logEntry = state.actionLog.first { $0.requestId?.uuidString == requestId }
        let readback = actionResultClassifier.readback(
            requestId: requestId,
            stillQueued: stillQueued,
            logEntry: logEntry
        )
        return try encodeJSON(readback)
    }

    /// The inline waiting-prompt snippet per human-owned session parked at a
    /// prompt — the SAME transcript-tail computation `workbench_status` uses, so
    /// the attention-queue row's prompt matches the operator-facing path exactly.
    /// Agent-owned sessions are excluded: they're driven by their owning agent's
    /// loop, not the human, so the boss isn't fed their prompts to act on (#U25).
    private func waitingPromptSnippets(state: WorkspaceState) -> [UUID: String] {
        Dictionary(
            state.processEntries
                .filter { !$0.isArchived && $0.attention.needsHuman && $0.owner.agentName == nil }
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

    /// Health verdict for a (re)started session — the boss's one-call way to
    /// confirm a resumed session came up healthy. Composes the session's run
    /// status + recency (from its `SessionSnapshot`) with its transcript tail
    /// through the pure Core `SessionHealthProbe`, so the boss gets a
    /// deterministic `healthy | starting | stalled | failed` instead of
    /// re-interpreting raw output. Returns
    /// `{"name", "health", "status", "needsHuman"}`.
    private func sessionHealth(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        let entry = try targetEntry(arguments: arguments, state: state)
        // The snapshot carries the latest run's status + startedAt/lastOutputAt
        // and exitCode exactly as the boss reads them from workbench_sessions.
        guard let snapshot = sessionsRenderer
            .snapshots(state: state, name: entry.name, includeArchived: true)
            .first(where: { $0.id == entry.id.uuidString }) else {
            throw MCPToolFailure("No session snapshot for \(entry.name)")
        }
        let maxBytes = TranscriptTailLimit.clamped(uintArgument(arguments["maxBytes"]))
        let tail = TranscriptTailReader(maxBytes: maxBytes)
            .read(path: latestRun(for: entry.id, state: state)?.transcriptPath)?.text
        let verdict = SessionHealthProbe.classify(snapshot: snapshot, tail: tail)
        return try encodeJSON(SessionHealthResult(
            name: snapshot.name,
            health: verdict.rawValue,
            status: snapshot.status,
            needsHuman: snapshot.needsHuman
        ))
    }

    /// `workbench_session_health` JSON payload.
    private struct SessionHealthResult: Encodable {
        let name: String
        let health: String
        let status: String
        let needsHuman: Bool
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
        let groupValue = try optionalString(arguments, key: "group")
        let workingDirectory = try optionalString(arguments, key: "workingDirectory")
        let createGroupIfMissing = try optionalBool(arguments, key: "createGroupIfMissing") ?? false
        let action = BossWorkbenchAction(
            action: .createSession,
            text: try optionalString(arguments, key: "notes"),
            group: groupValue,
            name: try optionalString(arguments, key: "name"),
            command: try optionalString(arguments, key: "command"),
            workingDirectory: workingDirectory,
            trust: trust,
            autoResume: try optionalBool(arguments, key: "autoResume"),
            owner: try optionalString(arguments, key: "owner")
        )
        // Surfaces missing name / command / owner as a clear tool error before
        // anything is queued (the app re-validates on drain).
        try action.validateForQueueing()

        // U29 get-or-create: resolve the target group now so the caller gets
        // immediate feedback instead of a silent app-side skip. The pure resolver
        // decides existing / create-new (validated per U14) / defer / strict-must-exist.
        // For the create-new path, the rootPath is the session's workingDirectory
        // (the group's root and the session's cwd are the same in the one-call flow).
        let resolution = WorkbenchSessionGroupResolver.resolve(
            group: groupValue,
            createGroupIfMissing: createGroupIfMissing,
            rootPath: workingDirectory,
            workspaceState: state,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            directoryProbe: { WorkspaceRootValidation.fileSystemProbe($0) }
        )

        let resolvedGroupName: String?
        var createGroupRequestId: String?
        switch resolution {
        case .deferred:
            resolvedGroupName = nil
        case let .existing(project):
            resolvedGroupName = project.name
        case let .create(name, rootPath):
            // One call provisions the workspace: enqueue a validated `createGroup`
            // FIRST (its earlier createdAt drains ahead of the session), then the
            // session referencing the group by name — the app's `project(matching:)`
            // finds the just-created group before it builds the session.
            let createGroupAction = BossWorkbenchAction(
                action: .createGroup,
                group: name,
                name: name,
                workingDirectory: rootPath
            )
            let createGroupRequest = WorkbenchActionRequest(
                source: (arguments["source"] as? String) ?? "ouro-workbench-mcp",
                action: createGroupAction
            )
            try queue.enqueue(createGroupRequest)
            createGroupRequestId = createGroupRequest.id.uuidString
            resolvedGroupName = name
        case let .invalid(message):
            throw MCPToolFailure(message)
        case let .mustExist(message):
            throw MCPToolFailure(message)
        }

        let request = WorkbenchActionRequest(
            source: (arguments["source"] as? String) ?? "ouro-workbench-mcp",
            action: action
        )
        try queue.enqueue(request)
        let ownerName = action.owner ?? ""
        let groupSuffix = resolvedGroupName.map { " in \($0)" } ?? ""
        let provisioned = createGroupRequestId != nil ? " (provisioned the workspace)" : ""
        let message = "Queued createSession \(action.name ?? "session")\(groupSuffix)\(provisioned) owned by \(ownerName) as \(request.id.uuidString)."
        if try wantsJSON(arguments) {
            // The create is queued — the running app builds the session and
            // assigns its id. Poll `workbench_sessions` with this `name` to
            // resolve the id once the app's pump has drained the request.
            return try encodeJSON(CreateAck(
                queued: true,
                name: action.name,
                group: resolvedGroupName,
                owner: action.owner,
                requestId: request.id.uuidString,
                createGroupRequestId: createGroupRequestId,
                message: message
            ))
        }
        return message
    }

    /// U30(b) — the boss's `workbench_report_bug` tool. Captures a Workbench/session
    /// defect into the SAME anonymized bug-report bundle a human would create. The bundle
    /// needs live app state (sessions, decisions, action log, screenshot), so this ENQUEUES
    /// a `.reportBug` action the running app drains through `BugReportWriter` +
    /// `WorkbenchBugReportRedactor` — the exact redaction path the in-app reporter uses,
    /// never a bypass. Returns an enqueue ack; the boss reads the bundle back from the
    /// operator's Report a Bug card. Filing to GitHub stays human-gated.
    private func reportBug(arguments: [String: Any]) throws -> String {
        guard let note = try optionalString(arguments, key: "note"),
              !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolFailure("Missing note (the defect description)")
        }
        let source = (arguments["source"] as? String) ?? "ouro-workbench-mcp"
        // The note rides in the action's `text`. Authorize through the same single gate as
        // every other entry-less action before queueing.
        let action = BossWorkbenchAction(action: .reportBug, text: note)
        try action.validateForQueueing()
        let decision = authorizer.gate(action, resolvedEntry: nil)
        guard decision.authorization.isAllowed else {
            throw MCPToolFailure("Action denied for \(decision.deniedTarget): \(decision.authorization.reason ?? "not authorized")")
        }
        let request = WorkbenchActionRequest(source: source, action: action)
        try queue.enqueue(request)
        let ack = WorkbenchReportBugRenderer.ack(
            requestId: request.id.uuidString,
            note: note,
            source: source
        )
        if try wantsJSON(arguments) {
            return try encodeJSON(ack)
        }
        return ack.message
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
        // Forward memory (Slice 6): pass the workspace state so sessions Workbench
        // itself launched from a discovered one surface NATIVELY (via the
        // scanner's `discoverFromWorkbench` source) instead of only being
        // re-inferred from disk/process scraping. Best-effort: a transient state
        // read failure degrades to recent+running only — discovery must never
        // break because the state file momentarily couldn't be read.
        let state = try? currentState()
        let records = agentSessionScanner.scan(state: state, processLister: runningProcessLister.callAsFunction)
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

    /// Parse an optional array-of-strings argument (e.g. the `attention` filter).
    /// A scalar string is accepted as a one-element array (lenient for a boss that
    /// passes a single value). A non-string element is rejected.
    private func optionalStringArray(_ arguments: [String: Any], key: String) throws -> [String]? {
        guard let value = arguments[key] else {
            return nil
        }
        if let single = value as? String {
            return [single]
        }
        guard let array = value as? [Any] else {
            throw MCPToolFailure("\(key) must be a string or an array of strings")
        }
        return try array.map { element in
            guard let string = element as? String else {
                throw MCPToolFailure("\(key) must contain only strings")
            }
            return string
        }
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
        /// U29: present only when this one call also provisioned the workspace —
        /// the requestId of the `createGroup` queued ahead of the session, so the
        /// boss can poll `workbench_action_result` for it too if it wants.
        let createGroupRequestId: String?
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
                "name": WorkbenchAutonomyReadinessRenderer.toolName,
                "description": WorkbenchAutonomyReadinessRenderer.toolDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_sessions",
                "description": "Machine-readable JSON list of Workbench sessions for programmatic clients (use workbench_status for the human-readable check-in prompt). Returns {\"sessions\":[{id,name,group,owner:{kind,name},kind,status,attention,attentionReason,attentionPrompt,needsHuman,trust,autoResume,isArchived,isPinned,pid,exitCode,workingDirectory,transcriptPath,startedAt,lastOutputAt}]}. status is the latest run's state (configured|running|exited|waitingForInput|needsRecovery|manualActionNeeded); attention is idle|active|waitingOnHuman|blocked|needsBossReview. Pass `attention` to fetch only the attention queue in one round-trip (each human-owned waiting/blocked row then carries `attentionPrompt`, the inline transcript snippet the operator sees) — or call workbench_attention_queue for the same queue pre-ordered. Optional fields are omitted when not applicable. After workbench_create_session, poll this with `name` set to your unique session name to resolve the new session's id and watch its status.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string", "description": "Return only sessions owned by this agent name (owner:agent:<name>). Omit for all owners."],
                        "name": ["type": "string", "description": "Return only sessions whose name matches case-insensitively. Use to resolve the id of a session you just created."],
                        "attention": ["type": "array", "items": ["type": "string", "enum": ["idle", "active", "waitingOnHuman", "blocked", "needsBossReview"]], "description": "Return only sessions whose attention is in this set. Pass [\"waitingOnHuman\",\"blocked\",\"needsBossReview\"] to receive only the sessions needing a human (never idle/active), each waiting/blocked human-owned row carrying its inline attentionPrompt. Omit for all attention states."],
                        "includeArchived": ["type": "boolean", "description": "Include archived sessions. Defaults to false."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": WorkbenchAttentionQueueRenderer.toolName,
                "description": WorkbenchAttentionQueueRenderer.toolDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_action_result",
                "description": "Read back the outcome of a workbench_request_action by the requestId it returned (#U24). Returns {requestId,state,result?,succeeded?} where state is one of: queued (the app hasn't drained it yet — poll again, never an error), applied (drained and succeeded — `result` carries the confirmation text and `succeeded` is true), failed (drained but skipped/errored — `result` carries the reason and `succeeded` is false), or unknown (no such queued request and no log entry — wrong id, or the entry rolled off the bounded action log). Use this to confirm 'did my recover/sendInput land' instead of re-pulling workbench_status and guessing which log line was yours.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "requestId": ["type": "string", "description": "The requestId returned by workbench_request_action (request format \"json\"). Required."]
                    ],
                    "required": ["requestId"],
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
                "name": "workbench_session_health",
                "description": "Confirm a (re)started session came up healthy. Composes the session's run status + recency with its transcript tail into a verdict: returns {\"name\",\"health\",\"status\",\"needsHuman\"} where health is healthy|starting|stalled|failed. healthy = producing fresh output, sitting at a prompt waiting on the human, or exited code 0; starting = no output yet within the startup grace; stalled = running but output went quiet (or nothing emitted past the grace); failed = exited non-zero, needs recovery/manual action, or the tail ended on a terminal error. General — no harness-specific knowledge.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "entry": ["type": "string", "description": "Process UUID or unique process name."],
                        "maxBytes": [
                            "type": "number",
                            "maximum": Double(TranscriptTailLimit.maximumBytes),
                            "description": "Maximum bytes to read from the end of the transcript for the tail signal. Values above the server cap are clamped."
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
                "description": "Create and launch a coding session through Workbench, owned by the calling agent. The session appears as a first-class Workbench session tagged owner:agent:<owner>, with the same trust gating and launch validation as a human-created terminal. The Workbench MCP is registered without an agent identity, so you must pass your own agent name as `owner`. By default the target `group` must already exist (omit it to use the currently-selected group). GET-OR-CREATE (#U29): pass `createGroupIfMissing: true` together with a `workingDirectory` and a `group` name to provision the workspace and land the session in it in ONE call when the group doesn't exist yet — Workbench validates the working directory exists (a non-existent path is rejected here, not at launch), creates the group at it, then launches the session. An existing group is reused, never duplicated; the strict must-already-exist behaviour stays the default when you omit the flag.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string", "description": "Your agent name. Stamped as the session owner (owner:agent:<owner>). Required, non-empty."],
                        "name": ["type": "string", "description": "Session name shown in the Workbench sidebar. Required."],
                        "command": ["type": "string", "description": "The shell command / coding agent to run (e.g. \"codex --yolo\" or \"claude\"). Required."],
                        "group": ["type": "string", "description": "Target group UUID or unique group name. Must already exist unless createGroupIfMissing is set. Omit to use the selected group."],
                        "createGroupIfMissing": ["type": "boolean", "description": "Get-or-create (#U29): when true and the named `group` doesn't exist, provision it (validated against `workingDirectory`) and land the session in it in one call. Defaults to false (strict must-already-exist). Requires `group` and a `workingDirectory` that exists."],
                        "workingDirectory": ["type": "string", "description": "Working directory for the session. Defaults to the group's root path. When createGroupIfMissing provisions a new group, this is also the new group's root path and must be an existing directory."],
                        "trust": ["type": "string", "enum": ["trusted", "untrusted"], "description": "Session trust. Defaults to untrusted; an untrusted session is created but not auto-driven by the boss."],
                        "autoResume": ["type": "boolean", "description": "Whether the session auto-resumes after a crash / restart. Defaults to false."],
                        "notes": ["type": "string", "description": "Optional notes attached to the session."],
                        "source": ["type": "string", "description": "Agent or tool requesting the action (for the audit log)."],
                        "format": ["type": "string", "enum": ["text", "json"], "description": "Response format. \"json\" returns {queued,name,group,owner,requestId,createGroupRequestId?,message} — createGroupRequestId is present only when this call also provisioned the workspace. Poll workbench_sessions with `name` to resolve the new session id. Default \"text\" returns a human-readable confirmation."]
                    ],
                    "required": ["owner", "name", "command"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": WorkbenchReportBugRenderer.toolName,
                "description": WorkbenchReportBugRenderer.toolDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note": ["type": "string", "description": "The defect description — what's wrong (e.g. \"recovery drill failed to reattach session 3\"). Required, non-empty. This text is anonymized before the bundle is written; the screenshot and diagnostics zip are NOT."],
                        "source": ["type": "string", "description": "Agent or tool requesting the report (for the audit log)."],
                        "format": ["type": "string", "enum": ["text", "json"], "description": "Response format. \"json\" returns {queued,requestId,message}. Default \"text\" returns a human-readable confirmation. Either way the bundle is built on the app's drain — read it back from the operator's Report a Bug card."]
                    ],
                    "required": ["note"],
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

    /// Build a JSON-RPC error response from an `MCPError`, routing through its
    /// canonical `jsonRPCError` mapping (F10a) so codes/messages are defined in
    /// one place. A `.toolFailure` (no protocol mapping) falls back to an
    /// internal-error envelope — but the dispatch never feeds one here; tool
    /// failures surface as isError tools/call results upstream.
    private func errorResponse(id: Any?, _ mcpError: MCPError) -> [String: Any] {
        if let mapping = mcpError.jsonRPCError {
            return error(id: id, code: mapping.code, message: mapping.message)
        }
        return error(id: id, code: -32603, message: mcpError.errorDescription ?? "Internal error")
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
        // valid reply built from MCPError.internalError (one place owns the
        // code/message). id is dropped to null since the unserializable value
        // may be the id itself.
        let fallback = MCPError.internalError(detail: "response could not be serialized")
        let code = fallback.jsonRPCError?.code ?? -32603
        let message = fallback.jsonRPCError?.message ?? "Internal error"
        if let escapedMessage = try? JSONSerialization.data(withJSONObject: [message]),
           let messageJSON = String(data: escapedMessage, encoding: .utf8) {
            // messageJSON is `["...escaped..."]`; strip the array brackets to get
            // the bare JSON string literal, keeping the reply hand-built (so a
            // second serialization failure can't recurse here).
            let bare = messageJSON.dropFirst().dropLast()
            print(#"{"jsonrpc":"2.0","id":null,"error":{"code":\#(code),"message":\#(bare)}}"#)
        } else {
            print(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#)
        }
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
