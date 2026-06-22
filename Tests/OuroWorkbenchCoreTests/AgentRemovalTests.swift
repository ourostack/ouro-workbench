import XCTest
@testable import OuroWorkbenchCore

/// F6 — the pure remove-agent seam.
///
/// Workbench's agent roster is a pure filesystem scan of `~/AgentBundles/*.ouro`
/// (`OuroAgentInventory.scan`): there is NO separate Workbench-side registration to deregister
/// from. So the ONLY honest removal is deleting the on-disk `.ouro` bundle directory, and the
/// confirmation copy must say that plainly (permanent, deletes the bundle — never a soft "hide").
///
/// This is the PURE seam: the "what to remove" decision value (`AgentRemoval`) + the seam-free
/// confirmation copy. The actual `FileManager.removeItem` + roster/selection/boss mutation is the
/// App's thin I/O layer over this value.
final class AgentRemovalTests: XCTestCase {

    private func record(
        name: String = "scout",
        bundlePath: String = "/Users/me/AgentBundles/scout.ouro",
        status: OuroAgentBundleStatus = .ready
    ) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: bundlePath,
            configPath: bundlePath + "/agent.json",
            status: status,
            detail: "ready"
        )
    }

    // MARK: - decide: what to remove

    func testDecideCarriesTheBundlePathAndName() {
        let decision = AgentRemoval.decide(for: record(name: "scout", bundlePath: "/b/scout.ouro"))
        XCTAssertEqual(decision.agentName, "scout")
        XCTAssertEqual(decision.bundlePath, "/b/scout.ouro")
        XCTAssertTrue(
            decision.deletesBundle,
            "the only honest removal deletes the on-disk bundle (the roster is a filesystem scan)"
        )
    }

    func testDecideDeletesBundleForEveryStatus() {
        // Even a broken bundle (missingConfig / invalidConfig) is removed by deleting its directory:
        // there's no other handle to forget it by. The decision is uniform across status.
        for status in [OuroAgentBundleStatus.ready, .disabled, .missingConfig, .invalidConfig] {
            let decision = AgentRemoval.decide(for: record(status: status))
            XCTAssertTrue(decision.deletesBundle, "must delete the bundle for status \(status)")
        }
    }

    // MARK: - confirmationCopy: honest + seam-free + states the destruction

    func testConfirmationTitleNamesTheAgent() {
        let copy = AgentRemoval.confirmationCopy(agentName: "scout", isBoss: false)
        XCTAssertTrue(copy.title.contains("scout"), "title must name the agent; got: \(copy.title)")
    }

    func testConfirmationMessageStatesPermanentBundleDeletion() {
        let copy = AgentRemoval.confirmationCopy(agentName: "scout", isBoss: false)
        let lowered = copy.message.lowercased()
        // The honest removal IS a permanent on-disk deletion — the copy must say so, not imply a
        // reversible "hide from the list".
        XCTAssertTrue(lowered.contains("permanent"), "message must call the deletion permanent; got: \(copy.message)")
        XCTAssertTrue(lowered.contains("delete"), "message must say it deletes; got: \(copy.message)")
        XCTAssertTrue(copy.message.contains("scout"), "message must name the agent; got: \(copy.message)")
    }

    func testConfirmActionLabelReadsAsDestructive() {
        let copy = AgentRemoval.confirmationCopy(agentName: "scout", isBoss: false)
        XCTAssertEqual(copy.confirmTitle, "Delete")
        XCTAssertEqual(copy.cancelTitle, "Cancel")
    }

    func testConfirmationWarnsWhenRemovingTheBoss() {
        // Removing the CURRENT boss is an extra-consequential action (the selection has to move).
        // The boss-flavored copy must add a heads-up the non-boss copy doesn't.
        let bossCopy = AgentRemoval.confirmationCopy(agentName: "scout", isBoss: true)
        let plainCopy = AgentRemoval.confirmationCopy(agentName: "scout", isBoss: false)
        XCTAssertNotEqual(
            bossCopy.message, plainCopy.message,
            "removing the boss must warn that it's the current boss"
        )
        XCTAssertTrue(
            bossCopy.message.lowercased().contains("boss"),
            "the boss-removal copy must mention it's the current boss; got: \(bossCopy.message)"
        )
    }

    func testConfirmationCopyIsSeamFree() {
        // No CLI / path / argv seam beyond the agent name. (The agent name is human-chosen.)
        for isBoss in [true, false] {
            let copy = AgentRemoval.confirmationCopy(agentName: "ouroboros", isBoss: isBoss)
            for field in [copy.title, copy.message, copy.confirmTitle, copy.cancelTitle] {
                let withoutName = field.replacingOccurrences(of: "ouroboros", with: "").lowercased()
                for token in ["ouro ", "vault", "--", ".ouro", "/agentbundles", "removeitem", "filemanager"] {
                    XCTAssertFalse(
                        withoutName.contains(token),
                        "confirmation copy leaked the seam token \"\(token)\": \(field)"
                    )
                }
            }
        }
    }
}
