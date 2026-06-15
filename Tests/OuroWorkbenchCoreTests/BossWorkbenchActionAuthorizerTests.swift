import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class BossWorkbenchActionAuthorizerTests: XCTestCase {
    func testTrustedEntriesCanReceiveBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "status")

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertNil(authorization.reason)
    }

    func testUntrustedEntriesCannotReceiveBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Untrusted",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .untrusted
        )
        let action = BossWorkbenchAction(action: .launch, entry: entry.id.uuidString)

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "entry is untrusted")
    }

    func testArchivedEntriesCannotReceiveBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Archived",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            isArchived: true
        )
        let action = BossWorkbenchAction(action: .launch, entry: entry.id.uuidString)

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "entry is archived")
    }

    func testTrustedArchivedEntriesCanBeRestoredByBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Archived",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            isArchived: true
        )
        let action = BossWorkbenchAction(action: .restore, entry: entry.id.uuidString)

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertNil(authorization.reason)
    }

    func testTrustedShellEntriesCanBeArchivedAndRestoredByBossActions() throws {
        let activeShell = ProcessEntry(
            projectId: UUID(),
            name: "User Shell",
            kind: .shell,
            executable: "/bin/zsh",
            arguments: ["-l"],
            workingDirectory: "/repo",
            trust: .trusted
        )
        let archive = BossWorkbenchAction(action: .archive, entry: activeShell.id.uuidString)
        var archivedShell = activeShell
        archivedShell.isArchived = true
        let restore = BossWorkbenchAction(action: .restore, entry: archivedShell.id.uuidString)
        let authorizer = BossWorkbenchActionAuthorizer()

        XCTAssertTrue(authorizer.authorize(archive, for: activeShell).isAllowed)
        XCTAssertTrue(authorizer.authorize(restore, for: archivedShell).isAllowed)
    }

    func testUntrustedShellEntriesCannotBeArchivedOrRestoredByBossActions() throws {
        let activeShell = ProcessEntry(
            projectId: UUID(),
            name: "User Shell",
            kind: .shell,
            executable: "/bin/zsh",
            arguments: ["-l"],
            workingDirectory: "/repo",
            trust: .untrusted
        )
        var archivedShell = activeShell
        archivedShell.isArchived = true
        let authorizer = BossWorkbenchActionAuthorizer()

        XCTAssertEqual(
            authorizer.authorize(BossWorkbenchAction(action: .archive, entry: activeShell.id.uuidString), for: activeShell).reason,
            "entry is untrusted"
        )
        XCTAssertEqual(
            authorizer.authorize(BossWorkbenchAction(action: .restore, entry: archivedShell.id.uuidString), for: archivedShell).reason,
            "entry is untrusted"
        )
    }

    func testUnsafeSendInputIsWithheldEvenOnTrustedSession() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "rm -rf /tmp/cache")

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "withheld unsafe input (destructive command) — escalated to a human")
    }

    /// P0 regression: the danger of a `sendInput` lives in the live PROMPT, not
    /// the bare input. A boss answering `y` to a `rm -rf /? [y/N]` confirmation
    /// must be withheld + escalated — even though `y` on its own is innocuous.
    func testSendInputToDestructiveLivePromptIsWithheld() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "y")

        let authorization = BossWorkbenchActionAuthorizer().authorize(
            action,
            for: entry,
            livePrompt: "Run 'rm -rf /'? [y/N]"
        )

        XCTAssertFalse(authorization.isAllowed, "y to an rm -rf prompt must be withheld")
        XCTAssertEqual(authorization.reason, "withheld unsafe input (destructive command) — escalated to a human")
    }

    func testSendInputToSecretBearingLivePromptIsWithheld() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "hunter2")

        let authorization = BossWorkbenchActionAuthorizer().authorize(
            action,
            for: entry,
            livePrompt: "Enter your password to continue:"
        )

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "withheld unsafe input (credential prompt) — escalated to a human")
    }

    /// Prompt-aware floor: a safe input to a SAFE (or empty) live prompt stays
    /// allowed. This replaces the old input-only assumption — a benign `y`/`1`
    /// is allowed only because the prompt it answers is also benign.
    func testSafeSendInputToSafePromptIsAllowedOnTrustedSession() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let cases: [(input: String, prompt: String)] = [
            ("y", "Run tests? (y/N)"),
            ("1", "Do you want to make this edit?\n❯ 1. Yes\n  2. No"),
            ("continue", "Continue with the refactor?"),
            ("run the tests", "What should I do next?"),
            // No live prompt available (transcript missing): a benign input is
            // still allowed — the floor degrades to input-only, as documented.
            ("y", "")
        ]
        for testCase in cases {
            let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: testCase.input)
            let authorization = BossWorkbenchActionAuthorizer().authorize(
                action,
                for: entry,
                livePrompt: testCase.prompt
            )
            XCTAssertTrue(
                authorization.isAllowed,
                "expected input '\(testCase.input)' to a safe prompt '\(testCase.prompt)' to be allowed"
            )
        }
    }

    // MARK: - Entry-less authorization (closes the bypass; trusted-onboarding posture)

    func testEntrylessRepairAgentIsAllowedUnderTrustedOnboarding() throws {
        let action = BossWorkbenchAction(action: .repairAgent, name: "slugger")

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertEqual(authorization.posture, .trustedOnboarding)
        XCTAssertTrue(authorization.requiresAudit)
    }

    func testEntrylessRepairAgentWithoutAgentNameIsDenied() throws {
        // Even an onboarding action must carry its explicit resolved agent name to be
        // authorized entry-less — never lean on `ouro` default-agent resolution.
        let action = BossWorkbenchAction(action: .repairAgent, name: "   ")

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "repairAgent requires an explicit agent name")
        XCTAssertEqual(authorization.posture, .denied)
        XCTAssertFalse(authorization.requiresAudit)
    }

    func testEntrylessCreateGroupRemainsExplicitlyAuthorized() throws {
        // Previously bypassed authorization entirely; now must pass through explicitly.
        let action = BossWorkbenchAction(
            action: .createGroup,
            name: "Harness",
            workingDirectory: "/repo"
        )

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertEqual(authorization.posture, .knownEntryless)
    }

    func testEntrylessCreateTerminalRemainsExplicitlyAuthorized() throws {
        let action = BossWorkbenchAction(
            action: .createTerminal,
            group: "Harness",
            name: "Codex",
            command: "codex --yolo"
        )

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertEqual(authorization.posture, .knownEntryless)
    }

    func testEntrylessCreateSessionRemainsExplicitlyAuthorized() throws {
        // `createSession` is a live-added third known entry-less kind — it must also
        // pass the now-explicit entry-less authorization under `knownEntryless`.
        let action = BossWorkbenchAction(
            action: .createSession,
            group: "Harness",
            name: "Release Codex",
            command: "codex --yolo",
            owner: "slugger"
        )

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertEqual(authorization.posture, .knownEntryless)
    }

    func testEntrylessEntryScopedActionIsDenied() throws {
        // An action that is supposed to be entry-scoped must NEVER be allowed entry-less:
        // routing it through the entry-less path means it slipped the entry check.
        let action = BossWorkbenchAction(action: .launch)

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "launch is not authorized without a target entry")
        XCTAssertEqual(authorization.posture, .denied)
        XCTAssertFalse(authorization.requiresAudit)
    }

    func testEntrylessSendInputIsDenied() throws {
        // The most security-sensitive entry-scoped action: a `sendInput` arriving with no
        // entry must be denied entry-less — it can never slip the entry-scoped livePrompt floor.
        let action = BossWorkbenchAction(action: .sendInput, text: "y")

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "sendInput is not authorized without a target entry")
        XCTAssertEqual(authorization.posture, .denied)
    }

    // MARK: - Unified front door (both MCP enqueue + app apply route through this)

    func testUnifiedAuthorizeDispatchesToEntryScopedWhenEntryPresent() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Untrusted",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .untrusted
        )
        let action = BossWorkbenchAction(action: .launch, entry: entry.id.uuidString)

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, resolvedEntry: entry)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "entry is untrusted")
    }

    func testUnifiedAuthorizeDispatchesToEntrylessWhenNoEntry() throws {
        let action = BossWorkbenchAction(action: .repairAgent, name: "slugger")

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, resolvedEntry: nil)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertEqual(authorization.posture, .trustedOnboarding)
    }

    func testUnifiedAuthorizeDeniesUnknownEntrylessAction() throws {
        // An entry-scoped action arriving with no entry must be denied via the front door.
        let action = BossWorkbenchAction(action: .sendInput, text: "status")

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, resolvedEntry: nil)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "sendInput is not authorized without a target entry")
    }

    func testUnifiedAuthorizeAllowsKnownEntrylessCreateGroup() throws {
        let action = BossWorkbenchAction(action: .createGroup, name: "Harness", workingDirectory: "/repo")

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, resolvedEntry: nil)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertEqual(authorization.posture, .knownEntryless)
    }

    // MARK: - ADDITIVE-MERGE REGRESSION GUARD: the livePrompt safety floor must still fire

    /// THE keystone regression guard. R2's additive merge adds an entry-less posture path
    /// WITHOUT touching live's `authorize(_:for:livePrompt:)` sendInput safety floor. This
    /// test proves the floor STILL fires after the merge: a boss answering `y` to an
    /// `rm -rf /` confirmation on a TRUSTED session, routed through the unified front door
    /// with a resolved entry, must be withheld + escalated (classified off the live prompt,
    /// not the bare input). If this ever goes green-to-allowed, the additive merge silently
    /// deleted live's destructive-input protection — a security regression.
    func testUnifiedFrontDoorPreservesLivePromptSafetyFloorForDangerousSendInput() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "y")

        // Route through the entry-scoped overload WITH the live prompt — the exact call
        // `applyBossAction` makes at the second switch. The merge must not have changed it.
        let authorization = BossWorkbenchActionAuthorizer().authorize(
            action,
            for: entry,
            livePrompt: "Run 'rm -rf /'? [y/N]"
        )

        XCTAssertFalse(authorization.isAllowed, "the livePrompt floor must still withhold `y` to an rm -rf prompt")
        XCTAssertEqual(authorization.reason, "withheld unsafe input (destructive command) — escalated to a human")
    }

    /// Companion guard: a credential-bearing live prompt must still be withheld after the
    /// merge — proving the floor's full classifier (not just `rm -rf`) survives intact.
    func testUnifiedFrontDoorPreservesLivePromptSafetyFloorForSecretBearingPrompt() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "hunter2")

        let authorization = BossWorkbenchActionAuthorizer().authorize(
            action,
            for: entry,
            livePrompt: "Enter your password to continue:"
        )

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "withheld unsafe input (credential prompt) — escalated to a human")
    }

    // MARK: - R2.2 enqueue/apply gate (the shared bypass-closing decision both call sites use)

    /// The MCP enqueue path (`main.swift requestAction`) and the app apply path
    /// (`applyBossAction` first switch) both route entry-less actions through this gate. It
    /// returns the authorization PLUS the human-readable denial target so the two call sites
    /// can't drift in how they reject. An unknown/unauthorized entry-less action must be denied
    /// with the action's raw name as the target (no entry to name).
    func testEnqueueGateRejectsUnknownEntrylessActionWithRawTarget() throws {
        let action = BossWorkbenchAction(action: .sendInput, text: "y")

        let decision = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)

        XCTAssertFalse(decision.authorization.isAllowed)
        XCTAssertEqual(decision.deniedTarget, "sendInput")
        XCTAssertEqual(decision.authorization.reason, "sendInput is not authorized without a target entry")
    }

    func testEnqueueGateAllowsKnownEntrylessKinds() throws {
        // All three live entry-less kinds still pass the now-explicit gate.
        let createGroup = BossWorkbenchAction(action: .createGroup, name: "Harness", workingDirectory: "/repo")
        let createTerminal = BossWorkbenchAction(action: .createTerminal, group: "Harness", name: "Codex", command: "codex")
        let createSession = BossWorkbenchAction(action: .createSession, group: "Harness", name: "Codex", command: "codex", owner: "slugger")
        let authorizer = BossWorkbenchActionAuthorizer()

        for action in [createGroup, createTerminal, createSession] {
            let decision = authorizer.gate(action, resolvedEntry: nil)
            XCTAssertTrue(decision.authorization.isAllowed, "\(action.action.rawValue) must pass the entry-less gate")
            XCTAssertEqual(decision.authorization.posture, .knownEntryless)
        }
    }

    func testEnqueueGateAllowsRepairAgentUnderTrustedOnboarding() throws {
        let action = BossWorkbenchAction(action: .repairAgent, name: "slugger")

        let decision = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)

        XCTAssertTrue(decision.authorization.isAllowed)
        XCTAssertEqual(decision.authorization.posture, .trustedOnboarding)
        // Entry-less: there is no entry to name, so the denial target is the raw kind
        // (the agent name lives on the action, not the entry).
        XCTAssertEqual(decision.deniedTarget, "repairAgent")
    }

    /// The gate forwards `livePrompt` to the entry-scoped floor when an entry is present, so a
    /// dangerous `sendInput` is still withheld through the SAME gate both call sites use. This
    /// proves closing the bypass did not bypass the floor: the entry-scoped path keeps it.
    func testEnqueueGatePreservesLivePromptFloorWhenEntryPresent() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "y")

        let decision = BossWorkbenchActionAuthorizer().gate(
            action,
            resolvedEntry: entry,
            livePrompt: "Run 'rm -rf /'? [y/N]"
        )

        XCTAssertFalse(decision.authorization.isAllowed)
        XCTAssertEqual(decision.deniedTarget, "Trusted")
        XCTAssertEqual(decision.authorization.reason, "withheld unsafe input (destructive command) — escalated to a human")
    }

    // MARK: - Slice 4 onboarding actions (entry-less, trusted-onboarding posture)

    func testEntrylessAgentTargetedOnboardingActionsAreAllowedUnderTrustedOnboarding() throws {
        let authorizer = BossWorkbenchActionAuthorizer()
        let actions: [BossWorkbenchAction] = [
            BossWorkbenchAction(action: .verifyProvider, name: "slugger", lane: .outward),
            BossWorkbenchAction(action: .refreshProvider, name: "slugger"),
            BossWorkbenchAction(action: .selectLane, name: "slugger", lane: .inner, provider: "anthropic", model: "claude"),
            BossWorkbenchAction(action: .registerWorkbenchMCP, name: "slugger"),
        ]
        for action in actions {
            let authorization = authorizer.authorizeEntryless(action)
            XCTAssertTrue(authorization.isAllowed, "\(action.action.rawValue) must be allowed entry-less")
            XCTAssertEqual(authorization.posture, .trustedOnboarding)
            XCTAssertTrue(authorization.requiresAudit, "\(action.action.rawValue) must require an audit line")
        }
    }

    func testEntrylessAgentTargetedOnboardingActionsWithoutAgentNameAreDenied() throws {
        let authorizer = BossWorkbenchActionAuthorizer()
        let kinds: [BossWorkbenchActionKind] = [.verifyProvider, .refreshProvider, .selectLane, .registerWorkbenchMCP]
        for kind in kinds {
            // Empty/whitespace name → the command never runs (could repair/verify the wrong agent).
            let action = BossWorkbenchAction(action: kind, name: "   ")
            let authorization = authorizer.authorizeEntryless(action)
            XCTAssertFalse(authorization.isAllowed, "\(kind.rawValue) without an agent name must be denied")
            XCTAssertEqual(authorization.reason, "\(kind.rawValue) requires an explicit agent name")
        }
    }

    func testEntrylessEnsureDaemonIsAllowedUnderTrustedOnboardingWithNoAgentName() throws {
        // Machine-scoped infrastructure: no agent name required.
        let action = BossWorkbenchAction(action: .ensureDaemon)

        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertEqual(authorization.posture, .trustedOnboarding)
        XCTAssertTrue(authorization.requiresAudit)
        XCTAssertNil(action.name)
    }

    func testEnqueueGateAllowsSlice4OnboardingActionsWithRawKindTarget() throws {
        let authorizer = BossWorkbenchActionAuthorizer()
        let cases: [(BossWorkbenchAction, String)] = [
            (BossWorkbenchAction(action: .verifyProvider, name: "slugger"), "verifyProvider"),
            (BossWorkbenchAction(action: .refreshProvider, name: "slugger"), "refreshProvider"),
            (BossWorkbenchAction(action: .selectLane, name: "slugger", lane: .inner, provider: "anthropic", model: "claude"), "selectLane"),
            (BossWorkbenchAction(action: .registerWorkbenchMCP, name: "slugger"), "registerWorkbenchMCP"),
            (BossWorkbenchAction(action: .ensureDaemon), "ensureDaemon"),
        ]
        for (action, rawTarget) in cases {
            let decision = authorizer.gate(action, resolvedEntry: nil)
            XCTAssertTrue(decision.authorization.isAllowed, "\(rawTarget) must pass the entry-less gate")
            XCTAssertEqual(decision.authorization.posture, .trustedOnboarding)
            // Entry-less: the denial target is the raw kind (no entry to name).
            XCTAssertEqual(decision.deniedTarget, rawTarget)
        }
    }
}
