import Foundation

public enum BossWorkbenchActionKind: String, Codable, Sendable, CaseIterable {
    case launch
    case recover
    case terminate
    case sendInput
    case createGroup
    case createTerminal
    case createSession
    case moveSession
    case setTrust
    case setAutoResume
    case archive
    case restore
    /// Onboarding remediation: repair the named agent's vault/provider readiness
    /// (`ouro repair --agent <name>`). Entry-less — it targets an agent by an EXPLICIT
    /// `name`, never a process entry, and never relies on `ouro` default-agent resolution.
    /// Authorized under the `trustedOnboarding` posture (auto-apply + mandatory audit);
    /// executed headlessly with a post-command verify probe (recovery truth from the
    /// probe, never the exit code).
    case repairAgent
    /// Onboarding UI signal: open the native provider-config form (the one human touchpoint).
    ///
    /// NON-SECRET-BEARING by construction: it carries NO credential — routing a secret through
    /// the agent's action/context/transcript is catastrophically wrong. Its ONLY effect is to
    /// signal the native app to open the provider form; it does NOT run a command. The human
    /// gate (and the actual credential entry) lives inside the native form, never in this action.
    /// Entry-less and authorized under the `trustedOnboarding` posture (entry-less).
    case requestProviderConfig
    /// Onboarding remediation: verify the named agent's provider connection
    /// (`ouro auth verify --agent <name>`, or `ouro check --agent <name> --lane <lane>` when a
    /// lane is named). Entry-less — explicit agent name, optional lane. Recovery truth from the
    /// POST-command verify probe, never the exit code.
    case verifyProvider
    /// Onboarding remediation: push the named agent's vault credentials into the running daemon
    /// (`ouro provider refresh --agent <name>`). Entry-less, explicit agent name, post-command
    /// verify. Carries no secret — it re-pushes already-stored vault creds, never new ones.
    case refreshProvider
    /// Onboarding remediation: select the named agent's lane provider/model — CONFIG ONLY, no
    /// secret (`ouro use --agent <name> --lane <lane> --provider <p> --model <m>`). Entry-less,
    /// explicit agent name + explicit lane/provider/model. The credential lives in the vault and
    /// is never routed through this action.
    case selectLane
    /// Onboarding remediation: register the Workbench MCP for the named agent — wraps the
    /// existing headless in-app registrar (`BossWorkbenchMCPRegistrar.install`) as an
    /// agent-issuable action. Entry-less, explicit agent name; classified from the registrar
    /// SNAPSHOT, never the install throw.
    case registerWorkbenchMCP
    /// Onboarding remediation: ensure the local daemon is running — wraps Slice 0's
    /// detect-reuse-else-start `DaemonManager.ensureRunning()` as an agent-issuable action.
    /// Entry-less and MACHINE-SCOPED: the daemon is machine infrastructure, so this carries no
    /// agent name. Recovery truth from the post-start verify probe, never an exit code.
    case ensureDaemon

    /// Whether this kind's effect is to OPEN the native provider-config form rather than
    /// execute a command. Only `requestProviderConfig` is a UI-opening signal: it shows UI and
    /// runs nothing. This is what makes it non-executing — a hard guarantee that no command (and
    /// therefore no credential) is ever spawned from the agent-issued request.
    public var opensProviderForm: Bool {
        self == .requestProviderConfig
    }

    /// Whether applying this kind executes a command / mutates state (vs. only opening UI). The
    /// non-secret-bearing `requestProviderConfig` opens the form and executes nothing; every
    /// other kind drives a concrete app effect.
    public var executesCommand: Bool {
        self != .requestProviderConfig
    }
}

public struct BossWorkbenchAction: Codable, Equatable, Sendable {
    public var action: BossWorkbenchActionKind
    public var entry: String?
    public var text: String?
    public var appendNewline: Bool
    public var group: String?
    public var name: String?
    public var command: String?
    public var workingDirectory: String?
    public var trust: ProcessTrust?
    public var autoResume: Bool?
    /// The owning agent's name for `createSession`. Stamped onto the new
    /// `ProcessEntry` as `owner: .agent(<name>)` so an agent-initiated session
    /// is a first-class, attributed Workbench session. The Workbench MCP is
    /// registered with no agent identity in its command/env, so the calling
    /// agent must pass its own name; the server validates it non-empty.
    public var owner: String?
    /// The explicit provider lane (`outward` / `inner`) for the lane-scoped onboarding actions
    /// (`verifyProvider`, `selectLane`). Optional on `verifyProvider` (nil = whole-agent verify),
    /// required on `selectLane`.
    public var lane: ProviderLane?
    /// The explicit provider id for `selectLane` (config-only, never a secret).
    public var provider: String?
    /// The explicit model id for `selectLane` (config-only, never a secret).
    public var model: String?
    /// FORWARD MEMORY (Slice 6). When the boss relaunches a DISCOVERED session
    /// (`createTerminal` / `createSession`), it passes the originating discovery
    /// provenance here so the App can stamp it onto the new `ProcessEntry`
    /// (`discoveredHarness` / `discoveredSessionId`) — making the relaunched
    /// session natively rediscoverable by the next `AgentSessionScanner.scan`
    /// instead of re-inferred. Both are additive + OPTIONAL (an ordinary create
    /// that isn't a relaunch omits them) and are GENERAL opaque values Workbench
    /// stores verbatim — never interpreted. Non-secret structural keys.
    public var discoveredHarness: AgentHarness?
    public var discoveredSessionId: String?

    private enum CodingKeys: String, CodingKey {
        case action
        case entry
        case text
        case appendNewline
        case group
        case name
        case command
        case workingDirectory
        case trust
        case autoResume
        case owner
        case lane
        case provider
        case model
        case discoveredHarness
        case discoveredSessionId
    }

    public init(
        action: BossWorkbenchActionKind,
        entry: String? = nil,
        text: String? = nil,
        appendNewline: Bool = true,
        group: String? = nil,
        name: String? = nil,
        command: String? = nil,
        workingDirectory: String? = nil,
        trust: ProcessTrust? = nil,
        autoResume: Bool? = nil,
        owner: String? = nil,
        lane: ProviderLane? = nil,
        provider: String? = nil,
        model: String? = nil,
        discoveredHarness: AgentHarness? = nil,
        discoveredSessionId: String? = nil
    ) {
        self.action = action
        self.entry = entry
        self.text = text
        self.appendNewline = appendNewline
        self.group = group
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.trust = trust
        self.autoResume = autoResume
        self.owner = owner
        self.lane = lane
        self.provider = provider
        self.model = model
        self.discoveredHarness = discoveredHarness
        self.discoveredSessionId = discoveredSessionId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(BossWorkbenchActionKind.self, forKey: .action)
        self.entry = try container.decodeIfPresent(String.self, forKey: .entry)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? true
        self.group = try container.decodeIfPresent(String.self, forKey: .group)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.trust = try container.decodeIfPresent(ProcessTrust.self, forKey: .trust)
        self.autoResume = try container.decodeIfPresent(Bool.self, forKey: .autoResume)
        self.owner = try container.decodeIfPresent(String.self, forKey: .owner)
        self.lane = try container.decodeIfPresent(ProviderLane.self, forKey: .lane)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        // Forward memory (Slice 6): additive + optional. AgentHarness's own
        // decoder maps an unknown raw value to `.custom`, so a relaunch action
        // from a newer build still parses.
        self.discoveredHarness = try container.decodeIfPresent(AgentHarness.self, forKey: .discoveredHarness)
        self.discoveredSessionId = try container.decodeIfPresent(String.self, forKey: .discoveredSessionId)
    }
}

public enum BossWorkbenchActionValidationError: LocalizedError, Equatable, Sendable {
    case missingEntry(BossWorkbenchActionKind)
    case missingTextForSendInput
    case missingName(BossWorkbenchActionKind)
    case missingCommandForCreateTerminal
    case missingCommandForCreateSession
    case missingOwnerForCreateSession
    case missingWorkingDirectoryForCreateGroup
    case missingGroupForMoveSession
    case missingTrustForSetTrust
    case missingAutoResumeForSetAutoResume
    case missingLane(BossWorkbenchActionKind)
    case missingProviderForSelectLane
    case missingModelForSelectLane

    public var errorDescription: String? {
        switch self {
        case .missingEntry(let action):
            return "\(action.rawValue) requires an entry"
        case .missingTextForSendInput:
            return "sendInput requires non-empty text"
        case .missingName(let action):
            return "\(action.rawValue) requires a non-empty name"
        case .missingCommandForCreateTerminal:
            return "createTerminal requires a non-empty command"
        case .missingCommandForCreateSession:
            return "createSession requires a non-empty command"
        case .missingOwnerForCreateSession:
            return "createSession requires a non-empty owner (the agent name)"
        case .missingWorkingDirectoryForCreateGroup:
            return "createGroup requires a non-empty workingDirectory"
        case .missingGroupForMoveSession:
            return "moveSession requires a target group"
        case .missingTrustForSetTrust:
            return "setTrust requires trust"
        case .missingAutoResumeForSetAutoResume:
            return "setAutoResume requires autoResume"
        case .missingLane(let action):
            return "\(action.rawValue) requires a lane"
        case .missingProviderForSelectLane:
            return "selectLane requires a non-empty provider"
        case .missingModelForSelectLane:
            return "selectLane requires a non-empty model"
        }
    }
}

public extension BossWorkbenchAction {
    func validateForQueueing() throws {
        switch action {
        case .launch, .recover, .terminate, .sendInput, .moveSession, .setTrust, .setAutoResume, .archive, .restore:
            guard entry?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingEntry(action)
            }
        case .createGroup, .createTerminal, .createSession, .repairAgent, .requestProviderConfig,
             .verifyProvider, .refreshProvider, .selectLane, .registerWorkbenchMCP, .ensureDaemon:
            break
        }

        switch action {
        case .sendInput:
            guard text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingTextForSendInput
            }
        case .createGroup:
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingName(action)
            }
            guard workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingWorkingDirectoryForCreateGroup
            }
        case .createTerminal:
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingName(action)
            }
            guard command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingCommandForCreateTerminal
            }
        case .createSession:
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingName(action)
            }
            guard command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingCommandForCreateSession
            }
            guard owner?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingOwnerForCreateSession
            }
        case .moveSession:
            guard group?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingGroupForMoveSession
            }
        case .setTrust:
            guard trust != nil else {
                throw BossWorkbenchActionValidationError.missingTrustForSetTrust
            }
        case .setAutoResume:
            guard autoResume != nil else {
                throw BossWorkbenchActionValidationError.missingAutoResumeForSetAutoResume
            }
        case .repairAgent, .verifyProvider, .refreshProvider, .registerWorkbenchMCP:
            // Entry-less, but every agent-targeted onboarding remediation MUST carry an EXPLICIT
            // resolved agent name — never lean on `ouro` default-agent resolution (multiple
            // agents can exist on the box, and the wrong one could be acted on). verifyProvider's
            // lane is OPTIONAL (nil = whole-agent verify), so it isn't checked here.
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingName(action)
            }
        case .selectLane:
            // Config-only (no secret) but FULLY specified: explicit agent name + explicit lane +
            // explicit provider + explicit model.
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingName(action)
            }
            guard lane != nil else {
                throw BossWorkbenchActionValidationError.missingLane(action)
            }
            guard provider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingProviderForSelectLane
            }
            guard model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingModelForSelectLane
            }
        case .launch, .recover, .terminate, .archive, .restore, .requestProviderConfig, .ensureDaemon:
            // requestProviderConfig carries no required payload: it only signals the app to
            // open the native form. ensureDaemon is machine-scoped infrastructure — it carries
            // no agent name. The human gate (and the credential) lives inside the form, never in
            // these non-secret-bearing actions.
            break
        }
    }
}

public struct BossWorkbenchActionParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> [BossWorkbenchAction] {
        guard let json = fencedActionJSON(in: text) ?? markerActionJSON(in: text) else {
            return []
        }
        // Decode the action array leniently: one malformed action (e.g. the
        // boss emits an unknown action type or a wrong field shape) shouldn't
        // discard the whole batch of otherwise-valid actions. If the payload
        // isn't an array at all, this still throws so the caller can surface a
        // parse error.
        let wrappers = try JSONDecoder().decode([FailableDecodable<BossWorkbenchAction>].self, from: Data(json.utf8))
        return wrappers.compactMap(\.base)
    }

    private func fencedActionJSON(in text: String) -> String? {
        let fence = "```ouro-workbench-actions"
        guard let start = text.range(of: fence) else {
            return nil
        }
        let remainder = text[start.upperBound...]
        guard let end = remainder.range(of: "```") else {
            return nil
        }
        return String(remainder[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markerActionJSON(in text: String) -> String? {
        let marker = "OURO_WORKBENCH_ACTIONS:"
        guard let start = text.range(of: marker) else {
            return nil
        }
        // Capture only the balanced JSON value after the marker, not everything
        // to EOF — otherwise trailing prose ("OURO_WORKBENCH_ACTIONS: [...] and
        // I'll check back later.") makes the whole payload invalid JSON and
        // silently drops the entire batch.
        return balancedJSONValue(in: text[start.upperBound...])
    }
}

/// Extracts the first complete, balanced JSON value (object or array) from a
/// substring — the first `{`/`[` to its matching close, tracking nesting depth
/// and ignoring brackets that appear inside string literals (and their escapes).
/// Returns nil if there's no opener or the value never closes. Shared by the
/// `OURO_WORKBENCH_ACTIONS:` marker fallback so trailing prose after the JSON
/// doesn't break decoding.
func balancedJSONValue(in text: Substring) -> String? {
    guard let openIndex = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
        return nil
    }
    var depth = 0
    var inString = false
    var escaped = false
    var index = openIndex
    while index < text.endIndex {
        let char = text[index]
        if inString {
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                inString = false
            }
        } else {
            switch char {
            case "\"":
                inString = true
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    return String(text[openIndex..<end])
                }
            default:
                break
            }
        }
        index = text.index(after: index)
    }
    return nil
}
