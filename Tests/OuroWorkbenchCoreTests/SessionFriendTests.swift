import XCTest
@testable import OuroWorkbenchCore

final class SessionFriendTests: XCTestCase {
    func testSlugFromName() {
        XCTAssertEqual(SessionFriend.slug(from: "Ari Mendelow"), "ari-mendelow")
        XCTAssertEqual(SessionFriend.slug(from: "  Spaced  Out  "), "spaced-out")
        XCTAssertEqual(SessionFriend.slug(from: "Agent #7 (beta)"), "agent-7-beta")
    }

    func testFreeformInitDerivesSlugId() {
        let f = SessionFriend(name: "Ari Mendelow", kind: .human, trust: .family)
        XCTAssertEqual(f.id, "ari-mendelow")
        XCTAssertEqual(f.displayLabel, "Ari Mendelow (human, family)")
    }

    func testTrustedLevels() {
        XCTAssertTrue(SessionFriendTrust.family.isTrusted)
        XCTAssertTrue(SessionFriendTrust.friend.isTrusted)
        XCTAssertFalse(SessionFriendTrust.acquaintance.isTrusted)
        XCTAssertFalse(SessionFriendTrust.stranger.isTrusted)
    }

    func testUnknownEnumRawValuesDecodeToSafeDefaults() throws {
        let kind = try JSONDecoder().decode(SessionFriendKind.self, from: Data("\"alien\"".utf8))
        XCTAssertEqual(kind, .human)
        let trust = try JSONDecoder().decode(SessionFriendTrust.self, from: Data("\"bestie\"".utf8))
        // Unknown trust is the most cautious level, never a trusted one.
        XCTAssertEqual(trust, .stranger)
        XCTAssertFalse(trust.isTrusted)
    }

    func testSessionFriendRoundTrips() throws {
        let original = SessionFriend(id: "uuid-123", name: "Codex Bot", kind: .agent, trust: .friend)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionFriend.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Resolution

    func testEffectiveFriendPrefersEntryThenGroupDefault() {
        let groupFriend = SessionFriend(name: "Ari", kind: .human, trust: .family)
        let entryFriend = SessionFriend(name: "Codex", kind: .agent, trust: .friend)
        var project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        project.defaultFriend = groupFriend
        let assigned = ProcessEntry(projectId: project.id, name: "a", kind: .terminalAgent, executable: "codex", workingDirectory: "/tmp/p", friend: entryFriend)
        let inherits = ProcessEntry(projectId: project.id, name: "b", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p")
        let state = WorkspaceState(projects: [project], processEntries: [assigned, inherits])

        XCTAssertEqual(state.effectiveFriend(for: assigned), entryFriend, "entry's own friend wins")
        XCTAssertEqual(state.effectiveFriend(for: inherits), groupFriend, "inherits group default")
    }

    func testEffectiveFriendNilWhenUnassignedAndNoFallback() {
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let entry = ProcessEntry(projectId: project.id, name: "a", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p")
        let state = WorkspaceState(projects: [project], processEntries: [entry])
        XCTAssertNil(state.effectiveFriend(for: entry))
    }

    func testEffectiveFriendFallsBackToMachineOwnerWhenUnassigned() {
        let owner = SessionFriend(id: "ari", name: "Ari", kind: .human, trust: .family)
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let entry = ProcessEntry(projectId: project.id, name: "a", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p")
        let state = WorkspaceState(projects: [project], processEntries: [entry])
        // No explicit/group friend -> the injected machine owner governs.
        XCTAssertEqual(state.effectiveFriend(for: entry, fallback: owner), owner)
    }

    func testExplicitAndGroupFriendsOutrankMachineOwnerFallback() {
        let owner = SessionFriend(id: "ari", name: "Ari", kind: .human, trust: .family)
        let groupFriend = SessionFriend(name: "Teammate", kind: .human, trust: .friend)
        let entryFriend = SessionFriend(name: "Codex", kind: .agent, trust: .friend)
        var project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        project.defaultFriend = groupFriend
        let assigned = ProcessEntry(projectId: project.id, name: "a", kind: .terminalAgent, executable: "codex", workingDirectory: "/tmp/p", friend: entryFriend)
        let inherits = ProcessEntry(projectId: project.id, name: "b", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p")
        let state = WorkspaceState(projects: [project], processEntries: [assigned, inherits])
        XCTAssertEqual(state.effectiveFriend(for: assigned, fallback: owner), entryFriend)
        XCTAssertEqual(state.effectiveFriend(for: inherits, fallback: owner), groupFriend)
    }

    // MARK: - Machine owner

    func testMachineOwnerUsesUsernameAsIdAndFullNameAsName() {
        let owner = SessionFriend.machineOwner(username: "ari", fullName: "Ari Mendelow")
        XCTAssertEqual(owner?.id, "ari", "id is the local username — the boss's (local, username) external id")
        XCTAssertEqual(owner?.name, "Ari Mendelow")
        XCTAssertEqual(owner?.kind, .human)
        XCTAssertEqual(owner?.trust, .family)
    }

    func testMachineOwnerFallsBackToUsernameWhenFullNameBlank() {
        XCTAssertEqual(SessionFriend.machineOwner(username: "ari", fullName: "   ")?.name, "ari")
    }

    func testMachineOwnerNilWhenNoUsername() {
        XCTAssertNil(SessionFriend.machineOwner(username: "  ", fullName: "Whoever"))
    }

    // MARK: - Boss prompt visibility

    func testBossPromptShowsFriendAndUnassigned() {
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let owned = ProcessEntry(
            projectId: project.id, name: "Mine", kind: .terminalAgent,
            agentKind: .openAICodex, executable: "codex", workingDirectory: "/tmp/p",
            friend: SessionFriend(name: "Ari", kind: .human, trust: .family)
        )
        let orphan = ProcessEntry(
            projectId: project.id, name: "Orphan", kind: .shell,
            executable: "zsh", workingDirectory: "/tmp/p"
        )
        let state = WorkspaceState(projects: [project], processEntries: [owned, orphan])
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "status?",
            state: state,
            summary: WorkspaceSummarizer().summarize(state)
        )
        XCTAssertTrue(prompt.contains("friend=Ari (human, family)"))
        XCTAssertTrue(prompt.contains("friend=unassigned"))
    }

    func testBossPromptInlinesWaitingPromptsForDecisioning() {
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let waiter = ProcessEntry(projectId: project.id, name: "Codex", kind: .terminalAgent, agentKind: .openAICodex, executable: "codex", workingDirectory: "/tmp/p", attention: .waitingOnHuman)
        let run = ProcessRun(entryId: waiter.id, status: .running)
        let state = WorkspaceState(projects: [project], processEntries: [waiter], processRuns: [run])
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "status?",
            state: state,
            summary: WorkspaceSummarizer().summarize(state),
            waitingPrompts: [waiter.id: "Do you want to proceed? 1. Yes  2. No"]
        )
        XCTAssertTrue(prompt.contains("Waiting prompts (decide each via ouro-workbench-decisions):"))
        XCTAssertTrue(prompt.contains("Do you want to proceed? 1. Yes  2. No"))
    }

    func testBossPromptOmitsWaitingSectionWhenNonePending() {
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let active = ProcessEntry(projectId: project.id, name: "A", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p", attention: .active)
        let state = WorkspaceState(projects: [project], processEntries: [active])
        let prompt = BossAgentPromptBuilder().checkInPrompt(question: "s", state: state, summary: WorkspaceSummarizer().summarize(state))
        XCTAssertFalse(prompt.contains("Waiting prompts"))
    }

    func testBossPromptResolvesUnassignedToMachineOwnerWhenProvided() {
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let orphan = ProcessEntry(projectId: project.id, name: "Orphan", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p")
        let state = WorkspaceState(projects: [project], processEntries: [orphan])
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "status?",
            state: state,
            summary: WorkspaceSummarizer().summarize(state),
            machineFriend: SessionFriend(id: "ari", name: "Ari", kind: .human, trust: .family)
        )
        // With a machine owner injected, an unassigned session resolves to it.
        XCTAssertTrue(prompt.contains("friend=Ari (human, family)"))
        XCTAssertFalse(prompt.contains("friend=unassigned"))
    }

    // MARK: - Backward compatibility

    func testProcessEntryWithoutFriendDecodesToNil() throws {
        // A pre-friend persisted entry (no `friend` key) must load with nil.
        let json = """
        {"id":"\(UUID().uuidString)","projectId":"\(UUID().uuidString)","name":"old","kind":"shell","executable":"zsh","arguments":[],"workingDirectory":"/tmp","trust":"untrusted","autoResume":false}
        """
        let entry = try JSONDecoder().decode(ProcessEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.friend)
    }

    func testWorkbenchProjectWithoutDefaultFriendDecodesToNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"old","rootPath":"/tmp","boss":{"agentName":"slugger","scope":"machine"}}
        """
        let project = try JSONDecoder().decode(WorkbenchProject.self, from: Data(json.utf8))
        XCTAssertNil(project.defaultFriend)
    }
}
