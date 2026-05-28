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

    func testEffectiveFriendNilWhenUnassigned() {
        let project = WorkbenchProject(name: "P", rootPath: "/tmp/p")
        let entry = ProcessEntry(projectId: project.id, name: "a", kind: .shell, executable: "zsh", workingDirectory: "/tmp/p")
        let state = WorkspaceState(projects: [project], processEntries: [entry])
        XCTAssertNil(state.effectiveFriend(for: entry))
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
