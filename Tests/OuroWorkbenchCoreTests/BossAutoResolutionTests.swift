import XCTest
@testable import OuroWorkbenchCore

final class BossAutoResolutionTests: XCTestCase {
    private func agent(_ name: String, _ status: OuroAgentBundleStatus = .ready) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "/bundles/\(name).ouro",
            configPath: "/bundles/\(name).ouro/agent.json",
            status: status,
            detail: "test record"
        )
    }

    func testEmptyBossWithNoAgentsResolvesToNil() {
        XCTAssertNil(BossAutoResolution.adoptableBossName(persistedBossName: "", agents: []))
    }

    func testEmptyBossWithSingleUsableAgentAdoptsIt() {
        XCTAssertEqual(
            BossAutoResolution.adoptableBossName(persistedBossName: "", agents: [agent("ouroboros")]),
            "ouroboros"
        )
    }

    func testEmptyBossWithMultipleUsableAgentsRequiresChoice() {
        // Two usable agents → Workbench never guesses; the human picks.
        XCTAssertNil(
            BossAutoResolution.adoptableBossName(
                persistedBossName: "",
                agents: [agent("ouroboros"), agent("slugger")]
            )
        )
    }

    func testEmptyBossCountsOnlyUsableAgents() {
        // One ready + one disabled → exactly one USABLE → adopt the usable one.
        XCTAssertEqual(
            BossAutoResolution.adoptableBossName(
                persistedBossName: "",
                agents: [agent("ouroboros"), agent("slugger", .disabled)]
            ),
            "ouroboros"
        )
    }

    func testEmptyBossWithNoUsableAgentsResolvesToNil() {
        XCTAssertNil(
            BossAutoResolution.adoptableBossName(
                persistedBossName: "",
                agents: [agent("ouroboros", .disabled), agent("slugger", .missingConfig)]
            )
        )
    }

    func testPersistedBossNamingNoInstalledBundleAdoptsSoleUsable() {
        // The persisted boss's bundle is gone (uninstalled); a single usable agent
        // is adopted rather than leaving a dangling, unusable selection.
        XCTAssertEqual(
            BossAutoResolution.adoptableBossName(persistedBossName: "ghost", agents: [agent("ouroboros")]),
            "ouroboros"
        )
    }

    func testResolvedBossIsNeverSwitchedAway() {
        // Persisted boss resolves to an installed bundle → leave it; never auto-
        // switch, even with exactly one usable agent.
        XCTAssertNil(
            BossAutoResolution.adoptableBossName(persistedBossName: "ouroboros", agents: [agent("ouroboros")])
        )
    }

    func testInstalledButUnusableBossIsLeftForRepair() {
        // Persisted boss is installed but disabled; do NOT silently switch to the
        // other usable agent — that's the repair/choose path, not auto-adopt.
        XCTAssertNil(
            BossAutoResolution.adoptableBossName(
                persistedBossName: "slugger",
                agents: [agent("slugger", .disabled), agent("ouroboros")]
            )
        )
    }

    func testReadyAgentWithInvalidBundleNameIsNotUsable() {
        // isUsableAsBoss also requires a valid bundle name; a ready agent whose name
        // is invalid (e.g. contains "/") is not adoptable, so a lone such agent
        // yields no auto-adoption.
        XCTAssertNil(
            BossAutoResolution.adoptableBossName(persistedBossName: "", agents: [agent("bad/name")])
        )
    }

    func testWhitespaceBossNameTreatedAsEmpty() {
        XCTAssertEqual(
            BossAutoResolution.adoptableBossName(persistedBossName: "   ", agents: [agent("ouroboros")]),
            "ouroboros"
        )
    }
}
