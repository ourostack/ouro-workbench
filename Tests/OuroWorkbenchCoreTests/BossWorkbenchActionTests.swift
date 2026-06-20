import XCTest
@testable import OuroWorkbenchCore

final class BossWorkbenchActionTests: XCTestCase {
    func testParsesFencedBossActions() throws {
        let reply = """
        I will move Codex forward now.

        ```ouro-workbench-actions
        [
          { "action": "recover", "entry": "OpenAI Codex" },
          { "action": "sendInput", "entry": "Claude Code", "text": "continue", "appendNewline": true }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .recover, entry: "OpenAI Codex"),
            BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue", appendNewline: true),
        ])
    }

    func testNoActionBlockReturnsEmptyList() throws {
        XCTAssertEqual(try BossWorkbenchActionParser().parse("No action needed."), [])
    }

    func testMalformedActionInBatchIsSkippedNotFatal() throws {
        // The middle action has an unknown `action` kind a newer boss might
        // emit. It should be skipped, the two valid actions still applied —
        // rather than the whole batch being discarded.
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "recover", "entry": "OpenAI Codex" },
          { "action": "teleport", "entry": "Nowhere" },
          { "action": "sendInput", "entry": "Claude Code", "text": "go", "appendNewline": true }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .recover, entry: "OpenAI Codex"),
            BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "go", appendNewline: true),
        ])
    }

    func testNonArrayActionPayloadStillThrows() {
        // A payload that isn't an array at all should surface as a parse
        // error, not silently return empty.
        let reply = """
        ```ouro-workbench-actions
        { "action": "recover" }
        ```
        """
        XCTAssertThrowsError(try BossWorkbenchActionParser().parse(reply))
    }

    func testSendInputRequiresNonEmptyTextBeforeQueueing() {
        let action = BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "   ")

        XCTAssertThrowsError(try action.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingTextForSendInput)
        }
    }

    func testEntryScopedActionsRequireEntryBeforeQueueing() {
        let action = BossWorkbenchAction(action: .launch)

        XCTAssertThrowsError(try action.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingEntry(.launch))
        }
    }

    func testCreateTerminalRequiresNameAndCommandBeforeQueueing() {
        let missingName = BossWorkbenchAction(action: .createTerminal, command: "codex --yolo")
        let missingCommand = BossWorkbenchAction(action: .createTerminal, name: "Codex")

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.createTerminal))
        }
        XCTAssertThrowsError(try missingCommand.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingCommandForCreateTerminal)
        }
    }

    func testCreateGroupRequiresNameAndWorkingDirectoryBeforeQueueing() {
        let missingName = BossWorkbenchAction(action: .createGroup, workingDirectory: "/repo")
        let missingWorkingDirectory = BossWorkbenchAction(action: .createGroup, name: "Harness", workingDirectory: "  ")

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.createGroup))
        }
        XCTAssertThrowsError(try missingWorkingDirectory.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingWorkingDirectoryForCreateGroup)
        }
    }

    func testCreateSessionRequiresNameCommandAndOwnerBeforeQueueing() {
        // A well-formed createSession (name + command + owner) validates.
        let valid = BossWorkbenchAction(
            action: .createSession,
            group: "Harness",
            name: "Release Codex",
            command: "codex --yolo",
            workingDirectory: "/repo",
            trust: .trusted,
            owner: "slugger"
        )
        XCTAssertNoThrow(try valid.validateForQueueing())

        // Missing each required field is rejected with the matching error.
        let missingName = BossWorkbenchAction(action: .createSession, command: "codex", owner: "slugger")
        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.createSession))
        }

        let missingCommand = BossWorkbenchAction(action: .createSession, name: "Codex", owner: "slugger")
        XCTAssertThrowsError(try missingCommand.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingCommandForCreateSession)
        }

        let missingOwner = BossWorkbenchAction(action: .createSession, name: "Codex", command: "codex")
        XCTAssertThrowsError(try missingOwner.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingOwnerForCreateSession)
        }

        let blankOwner = BossWorkbenchAction(action: .createSession, name: "Codex", command: "codex", owner: "   ")
        XCTAssertThrowsError(try blankOwner.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingOwnerForCreateSession)
        }
    }

    func testCreateSessionParsesAndCarriesOwner() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "createSession", "group": "Harness", "name": "Boss Codex", "command": "codex --yolo", "workingDirectory": "/repo", "trust": "trusted", "owner": "slugger" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(
                action: .createSession,
                group: "Harness",
                name: "Boss Codex",
                command: "codex --yolo",
                workingDirectory: "/repo",
                trust: .trusted,
                owner: "slugger"
            ),
        ])
        XCTAssertEqual(actions.first?.owner, "slugger")
    }

    func testCreateActionsCarryForwardMemoryProvenance() throws {
        // FORWARD MEMORY (Slice 6): when the boss relaunches a DISCOVERED session
        // it passes the originating `{discoveredHarness, discoveredSessionId}`
        // opaquely on the action. These are additive + optional (the ordinary
        // create that isn't a relaunch omits them), and Workbench stores them
        // verbatim — zero interpretation. The App stamps them onto the draft so
        // the next scan() rediscovers the relaunched session natively.
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "createTerminal", "group": "Harness", "name": "Resumed Claude", "command": "claude --resume abc-123", "workingDirectory": "/repo", "discoveredHarness": "claudeCode", "discoveredSessionId": "abc-123" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions.first?.discoveredHarness, .claudeCode)
        XCTAssertEqual(actions.first?.discoveredSessionId, "abc-123")
    }

    func testCreateActionsDefaultForwardMemoryToNil() throws {
        // An ordinary create (not a relaunch) carries no provenance.
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "createTerminal", "group": "Harness", "name": "Fresh", "command": "claude", "workingDirectory": "/repo" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertNil(actions.first?.discoveredHarness)
        XCTAssertNil(actions.first?.discoveredSessionId)
    }

    func testForwardMemoryActionFieldsRoundTripOnTheWire() throws {
        let action = BossWorkbenchAction(
            action: .createSession,
            name: "Resumed",
            command: "copilot",
            owner: "slugger",
            discoveredHarness: .githubCopilotCLI,
            discoveredSessionId: "cop-9"
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(BossWorkbenchAction.self, from: data)

        XCTAssertEqual(decoded.discoveredHarness, .githubCopilotCLI)
        XCTAssertEqual(decoded.discoveredSessionId, "cop-9")
        XCTAssertEqual(decoded, action)
    }

    func testParsesWorkspaceManagementActions() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "createTerminal", "group": "Harness", "name": "Release Codex", "command": "codex --yolo", "workingDirectory": "/repo", "trust": "trusted", "autoResume": true },
          { "action": "moveSession", "entry": "Release Codex", "group": "Website" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(
                action: .createTerminal,
                group: "Harness",
                name: "Release Codex",
                command: "codex --yolo",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            ),
            BossWorkbenchAction(action: .moveSession, entry: "Release Codex", group: "Website"),
        ])
    }

    func testNonInputActionsDoNotRequireTextBeforeQueueing() throws {
        let action = BossWorkbenchAction(action: .launch, entry: "Claude Code")

        XCTAssertNoThrow(try action.validateForQueueing())
    }

    func testEntryScopedMutationsRequireTheirPayloads() {
        XCTAssertThrowsError(try BossWorkbenchAction(action: .moveSession, entry: "Codex").validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingGroupForMoveSession)
        }
        XCTAssertThrowsError(try BossWorkbenchAction(action: .setTrust, entry: "Codex").validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingTrustForSetTrust)
        }
        XCTAssertThrowsError(try BossWorkbenchAction(action: .setAutoResume, entry: "Codex").validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingAutoResumeForSetAutoResume)
        }
        XCTAssertNoThrow(try BossWorkbenchAction(action: .requestProviderConfig).validateForQueueing())
        XCTAssertNoThrow(try BossWorkbenchAction(action: .ensureDaemon).validateForQueueing())
    }

    func testValidationErrorDescriptionsNameTheMissingContract() {
        let cases: [(BossWorkbenchActionValidationError, String)] = [
            (.missingEntry(.launch), "launch requires an entry"),
            (.missingTextForSendInput, "sendInput requires non-empty text"),
            (.missingName(.repairAgent), "repairAgent requires a non-empty name"),
            (.missingCommandForCreateTerminal, "createTerminal requires a non-empty command"),
            (.missingCommandForCreateSession, "createSession requires a non-empty command"),
            (.missingOwnerForCreateSession, "createSession requires a non-empty owner (the agent name)"),
            (.missingWorkingDirectoryForCreateGroup, "createGroup requires a non-empty workingDirectory"),
            (.missingGroupForMoveSession, "moveSession requires a target group"),
            (.missingTrustForSetTrust, "setTrust requires trust"),
            (.missingAutoResumeForSetAutoResume, "setAutoResume requires autoResume"),
            (.missingLane(.selectLane), "selectLane requires a lane"),
            (.missingProviderForSelectLane, "selectLane requires a non-empty provider"),
            (.missingModelForSelectLane, "selectLane requires a non-empty model"),
        ]

        for (error, description) in cases {
            XCTAssertEqual(error.errorDescription, description)
        }
    }

    // MARK: - Marker fallback (no fenced block)

    func testParsesMarkerActionsWithTrailingProse() throws {
        // The marker fallback (no ```ouro-workbench-actions fence) must capture
        // only the balanced JSON array — trailing prose after it used to make
        // the payload invalid JSON and silently drop the whole batch.
        let reply = """
        OURO_WORKBENCH_ACTIONS: [{ "action": "recover", "entry": "OpenAI Codex" }]
        Some trailing explanation about why I did that.
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .recover, entry: "OpenAI Codex"),
        ])
    }

    func testParsesMarkerActionsWithLeadingAndTrailingProse() throws {
        // Prose on both sides of the marker line, multiple actions, and a
        // string value containing a `]` that must not be mistaken for the
        // array's close.
        let reply = """
        Here is my plan for the waiting sessions.
        OURO_WORKBENCH_ACTIONS: [
          { "action": "recover", "entry": "OpenAI Codex" },
          { "action": "sendInput", "entry": "Claude Code", "text": "done [ok]", "appendNewline": true }
        ]
        I'll check back in a bit.
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .recover, entry: "OpenAI Codex"),
            BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "done [ok]", appendNewline: true),
        ])
    }

    func testMarkerFallbackIgnoresMissingOrUnclosedJSONValues() throws {
        XCTAssertEqual(try BossWorkbenchActionParser().parse("OURO_WORKBENCH_ACTIONS: no-json-here"), [])
        XCTAssertEqual(try BossWorkbenchActionParser().parse("OURO_WORKBENCH_ACTIONS: [ { \"action\": \"recover\" }"), [])
    }

    func testUnclosedFencedBlockIsIgnoredAndEscapedMarkerStringsStayBalanced() throws {
        XCTAssertEqual(try BossWorkbenchActionParser().parse("```ouro-workbench-actions\n[]"), [])

        let reply = #"OURO_WORKBENCH_ACTIONS: [{"action":"sendInput","entry":"Codex","text":"quote: \" and slash: \\ plus bracket ]","appendNewline":false}] trailing"#
        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .sendInput, entry: "Codex", text: #"quote: " and slash: \ plus bracket ]"#, appendNewline: false)
        ])
    }

    func testFencedBlockTakesPrecedenceOverMarker() throws {
        // When both a fence and a marker are present the fenced block wins
        // (unchanged behavior) — guards against the marker change regressing it.
        let reply = """
        ```ouro-workbench-actions
        [ { "action": "recover", "entry": "Fenced" } ]
        ```
        OURO_WORKBENCH_ACTIONS: [ { "action": "recover", "entry": "Marker" } ]
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [BossWorkbenchAction(action: .recover, entry: "Fenced")])
    }

    // MARK: - repairAgent (entry-less onboarding remediation, explicit agent name)

    func testRepairAgentRequiresExplicitAgentNameBeforeQueueing() {
        // repairAgent is entry-less but MUST carry an explicit resolved agent name
        // (never rely on `ouro` default-agent resolution — two agents can exist on the box).
        let missingName = BossWorkbenchAction(action: .repairAgent)
        let blankName = BossWorkbenchAction(action: .repairAgent, name: "   ")

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.repairAgent))
        }
        XCTAssertThrowsError(try blankName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.repairAgent))
        }
    }

    func testRepairAgentDoesNotRequireAnEntryBeforeQueueing() throws {
        // Entry-less by design: it targets an agent by name, not a process entry.
        let action = BossWorkbenchAction(action: .repairAgent, name: "slugger")

        XCTAssertNoThrow(try action.validateForQueueing())
    }

    func testParsesRepairAgentOnboardingAction() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "repairAgent", "name": "slugger" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .repairAgent, name: "slugger"),
        ])
    }

    // MARK: - requestProviderConfig (non-secret-bearing, UI-opening, non-executing)

    func testRequestProviderConfigCarriesNoCredentialField() throws {
        // PROOF: routing a secret through the agent's action/context is forbidden. The
        // BossWorkbenchAction shape (the agent-issuable surface) has no credential-bearing
        // key at all — there is no field whose value could ever be an API key / token /
        // secret. Encode an action and assert its on-the-wire keys are exactly the known,
        // non-secret structural keys.
        let action = BossWorkbenchAction(action: .requestProviderConfig, name: "slugger")
        let data = try JSONEncoder().encode(action)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(object.keys)

        // Exactly the live, non-secret structural keys of BossWorkbenchAction — no credential
        // sink exists. (`owner` is the createSession agent-name label; not a secret.
        // `discoveredHarness`/`discoveredSessionId` are Slice-6 forward-memory provenance —
        // an opaque harness name + session id, neither credential-bearing.)
        let allowedKeys: Set<String> = [
            "action", "entry", "text", "appendNewline", "group",
            "name", "command", "workingDirectory", "trust", "autoResume",
            "owner", "discoveredHarness", "discoveredSessionId",
        ]
        XCTAssertTrue(keys.isSubset(of: allowedKeys), "unexpected keys on the wire: \(keys.subtracting(allowedKeys))")

        // None of the keys is named like a credential sink.
        let secretLike = ["apiKey", "api_key", "token", "secret", "credential", "password", "key"]
        for key in keys {
            for needle in secretLike {
                XCTAssertFalse(
                    key.lowercased().contains(needle.lowercased()),
                    "requestProviderConfig must carry no credential-bearing field; found \(key)"
                )
            }
        }
    }

    func testRequestProviderConfigIsNonExecutingUITrigger() throws {
        // It only OPENS the native form — it does not run a command. The kind classifies as
        // a UI trigger / non-executing, distinguishing it from command-executing onboarding
        // actions like repairAgent.
        XCTAssertTrue(BossWorkbenchActionKind.requestProviderConfig.opensProviderForm)
        XCTAssertFalse(BossWorkbenchActionKind.requestProviderConfig.executesCommand)

        // repairAgent, by contrast, DOES execute a command and does NOT open the form.
        XCTAssertFalse(BossWorkbenchActionKind.repairAgent.opensProviderForm)
        XCTAssertTrue(BossWorkbenchActionKind.repairAgent.executesCommand)

        // Every other kind is command-executing and never opens the form (exhaustive guard so a
        // future kind can't silently become a second UI-opener / non-executing action).
        for kind in BossWorkbenchActionKind.allCases where kind != .requestProviderConfig {
            XCTAssertFalse(kind.opensProviderForm, "\(kind.rawValue) must not open the provider form")
            XCTAssertTrue(kind.executesCommand, "\(kind.rawValue) must execute a command")
        }
    }

    func testRequestProviderConfigDoesNotRequireAnEntryOrNameBeforeQueueing() throws {
        // Entry-less by design and carries no required payload: the human gate lives inside
        // the form, not in the action approval.
        let action = BossWorkbenchAction(action: .requestProviderConfig)

        XCTAssertNoThrow(try action.validateForQueueing())
    }

    func testParsesRequestProviderConfigOnboardingAction() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "requestProviderConfig", "name": "slugger" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .requestProviderConfig, name: "slugger"),
        ])
    }

    // MARK: - verifyProvider (entry-less, explicit agent name, optional lane)

    func testVerifyProviderRequiresExplicitAgentNameBeforeQueueing() {
        let missingName = BossWorkbenchAction(action: .verifyProvider)
        let blankName = BossWorkbenchAction(action: .verifyProvider, name: "   ", lane: .outward)

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.verifyProvider))
        }
        XCTAssertThrowsError(try blankName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.verifyProvider))
        }
    }

    func testVerifyProviderLaneIsOptionalAndEntryless() throws {
        // Lane-less whole-agent verify is valid; a lane is optional (nil = `ouro auth verify`).
        XCTAssertNoThrow(try BossWorkbenchAction(action: .verifyProvider, name: "slugger").validateForQueueing())
        XCTAssertNoThrow(try BossWorkbenchAction(action: .verifyProvider, name: "slugger", lane: .inner).validateForQueueing())
    }

    func testParsesVerifyProviderOnboardingActionWithLane() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "verifyProvider", "name": "slugger", "lane": "outward" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .verifyProvider, name: "slugger", lane: .outward),
        ])
    }

    // MARK: - refreshProvider (entry-less, explicit agent name)

    func testRefreshProviderRequiresExplicitAgentNameBeforeQueueing() {
        let missingName = BossWorkbenchAction(action: .refreshProvider)
        let blankName = BossWorkbenchAction(action: .refreshProvider, name: "   ")

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.refreshProvider))
        }
        XCTAssertThrowsError(try blankName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.refreshProvider))
        }
    }

    func testRefreshProviderDoesNotRequireAnEntryBeforeQueueing() throws {
        XCTAssertNoThrow(try BossWorkbenchAction(action: .refreshProvider, name: "slugger").validateForQueueing())
    }

    // MARK: - selectLane (entry-less, explicit name + lane + provider + model; config-only)

    func testSelectLaneRequiresExplicitNameLaneProviderAndModelBeforeQueueing() {
        let missingName = BossWorkbenchAction(action: .selectLane, lane: .inner, provider: "anthropic", model: "claude")
        let missingLane = BossWorkbenchAction(action: .selectLane, name: "slugger", provider: "anthropic", model: "claude")
        let missingProvider = BossWorkbenchAction(action: .selectLane, name: "slugger", lane: .inner, model: "claude")
        let missingModel = BossWorkbenchAction(action: .selectLane, name: "slugger", lane: .inner, provider: "anthropic")

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.selectLane))
        }
        XCTAssertThrowsError(try missingLane.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingLane(.selectLane))
        }
        XCTAssertThrowsError(try missingProvider.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingProviderForSelectLane)
        }
        XCTAssertThrowsError(try missingModel.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingModelForSelectLane)
        }
    }

    func testSelectLaneFullySpecifiedIsValidAndConfigOnly() throws {
        // Fully-specified and config-only: there is NO secret field on the wire. Encode it and
        // assert no credential-bearing key appears (the credential lives in the vault, never here).
        let action = BossWorkbenchAction(
            action: .selectLane, name: "slugger", lane: .inner, provider: "anthropic", model: "claude"
        )
        XCTAssertNoThrow(try action.validateForQueueing())

        let data = try JSONEncoder().encode(action)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowedKeys: Set<String> = [
            "action", "entry", "text", "appendNewline", "group",
            "name", "command", "workingDirectory", "trust", "autoResume",
            "owner", "lane", "provider", "model",
        ]
        XCTAssertTrue(Set(object.keys).isSubset(of: allowedKeys))
        let secretLike = ["apiKey", "api_key", "token", "secret", "credential", "password", "key"]
        for key in object.keys {
            for needle in secretLike {
                XCTAssertFalse(key.lowercased().contains(needle.lowercased()), "selectLane carries no secret; found \(key)")
            }
        }
    }

    func testParsesSelectLaneOnboardingAction() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "selectLane", "name": "slugger", "lane": "inner", "provider": "anthropic", "model": "claude" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .selectLane, name: "slugger", lane: .inner, provider: "anthropic", model: "claude"),
        ])
    }

    // MARK: - registerWorkbenchMCP (entry-less, explicit agent name)

    func testRegisterWorkbenchMCPRequiresExplicitAgentNameBeforeQueueing() {
        let missingName = BossWorkbenchAction(action: .registerWorkbenchMCP)
        let blankName = BossWorkbenchAction(action: .registerWorkbenchMCP, name: "   ")

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.registerWorkbenchMCP))
        }
        XCTAssertThrowsError(try blankName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.registerWorkbenchMCP))
        }
    }

    func testRegisterWorkbenchMCPDoesNotRequireAnEntryBeforeQueueing() throws {
        XCTAssertNoThrow(try BossWorkbenchAction(action: .registerWorkbenchMCP, name: "slugger").validateForQueueing())
    }

    // MARK: - ensureDaemon (entry-less, machine-scoped — NO agent name)

    func testEnsureDaemonRequiresNoAgentNameOrEntryBeforeQueueing() throws {
        // The daemon is machine-scoped infrastructure: ensureDaemon carries no agent name and
        // no entry, and must validate clean.
        let action = BossWorkbenchAction(action: .ensureDaemon)
        XCTAssertNoThrow(try action.validateForQueueing())
        XCTAssertNil(action.name)
    }

    func testParsesEnsureDaemonOnboardingAction() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "ensureDaemon" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .ensureDaemon),
        ])
    }
}
