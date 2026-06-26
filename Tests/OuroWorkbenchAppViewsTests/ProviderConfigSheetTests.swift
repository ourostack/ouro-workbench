#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C6-1 — `ProviderConfigSheet` (`:6136`) enumerated state-set + the Q3 determinism fix.
///
/// The native provider-config form (the ONE human gate) branches on several `@Published`
/// model flags + an injected `humanName` seed:
///   - `model.providerConfigIsNewAgent` (`:6151/6160/6170/6228`) — flips the title
///     ("Create your agent" vs `form.title` "Connect your agent's provider"), shows the
///     "Agent name" field, drives the provider picker over `coldStartProviders` (cold-start
///     can't offer the hatch-incapable GitHub Copilot) vs `allCases`, and labels the primary
///     button "Create Agent" vs "Connect".
///   - `message ?? model.providerConfigColdStartMessage` (`:6190`) — the surfaced outcome line.
///   - `model.providerConfigColdStartInFlight` (`:6198`) — the in-flight ProgressView +
///     `model.providerConfigInFlightLabel`; Cancel disabled.
///   - `model.providerConfigNeedsVaultSetup` (`:6216`) — swaps the primary button for the
///     honest "Finish setup" vault-recovery affordance.
///
/// **Q3 — the cluster's headline determinism fix (a real prod leak, now closed).**
/// `humanName` seeded its `@State` default from `NSFullUserName()`, which flows into the bound
/// `TextField("Your name", text: $humanName)` (`:6176`) and is captured in the snapshot via
/// AN-002 (the harness reads bound `TextField` values). On this machine `NSFullUserName()` is
/// "Microsoft" → it would land in a committed reference (a P3 violation). The fix makes the seed
/// injectable (`init(model:initialHumanName:)`, default `NSFullUserName()` → prod byte-identical)
/// and these tests inject a FIXED name ("Test User"), then ASSERT the rendered tree contains
/// "Test User" AND `!tree.contains(NSFullUserName())` (the no-machine-name guard). This proves
/// the injection is actually COVERED (the humanName field renders) — not bypassed.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection: a
/// temp `agentBundlesURL` into BOTH the registrar AND the inventory). Every state is reached by
/// setting the SAME `@Published` flags the production `requestProviderConfig` / cold-start /
/// onChange paths set (`providerConfigIsNewAgent`, `providerConfigColdStartMessage`,
/// `providerConfigColdStartInFlight`, `providerConfigNeedsVaultSetup`) — NO fabricated state.
///
/// **Determinism (P3).** No clock / UUID; the only machine value is the injected (fixed)
/// `humanName`. The `form.title`/subtitle/credential labels are static Core copy. Byte-identical
/// twice; no `/Users/` leak; no `NSFullUserName()` leak (asserted per state).
///
/// **Non-vacuity (P2).** Each flag flips a CAPTURED node: the new-agent title/field/button vs the
/// existing-agent title/button; the message caption appears/vanishes; the in-flight label/spinner;
/// the "Finish setup" vs "Create Agent"/"Connect" button. The negative controls assert the flip.
@MainActor
final class ProviderConfigSheetTests: XCTestCase {

    /// A fixed, machine-independent human name injected in place of `NSFullUserName()`.
    private static let fixedHumanName = "Test User"

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c6-provider-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// Build the sheet with the FIXED injected name + an optional model mutation closure.
    private func sheet(_ configure: (WorkbenchViewModel) -> Void = { _ in }) throws -> ProviderConfigSheet {
        let model = try makeVM()
        // A non-empty agent name so `form.title` renders the existing-agent copy
        // (the production `requestProviderConfig` seeds this for an existing agent).
        model.providerConfigAgentName = "boss"
        configure(model)
        return ProviderConfigSheet(model: model, initialHumanName: Self.fixedHumanName)
    }

    // MARK: - Enumerated state-set

    /// Existing-agent (default): "Connect your agent's provider" title, the provider picker over
    /// `allCases`, the "Your name" field with the INJECTED fixed name, "Connect" button.
    func testProviderConfig_existingAgent() throws {
        let view = try sheet { $0.providerConfigIsNewAgent = false }
        try assertViewSnapshot(of: view, named: "ProviderConfigSheet.existingAgent")
    }

    /// New-agent (cold-start): "Create your agent" title, the "Agent name" field, the picker over
    /// `coldStartProviders`, "Create Agent" button.
    func testProviderConfig_newAgent() throws {
        let view = try sheet { $0.providerConfigIsNewAgent = true }
        try assertViewSnapshot(of: view, named: "ProviderConfigSheet.newAgent")
    }

    /// A surfaced cold-start outcome line (`model.providerConfigColdStartMessage`).
    func testProviderConfig_coldStartMessage() throws {
        let view = try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigColdStartMessage = "Your agent was created but isn't connected yet."
        }
        try assertViewSnapshot(of: view, named: "ProviderConfigSheet.coldStartMessage")
    }

    /// In-flight: the ProgressView + the in-flight label; Cancel disabled.
    func testProviderConfig_inFlight() throws {
        let view = try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigColdStartInFlight = true
            $0.providerConfigInFlightLabel = "Creating your agent…"
        }
        try assertViewSnapshot(of: view, named: "ProviderConfigSheet.inFlight")
    }

    /// Needs-vault: the honest "Finish setup" affordance replaces "Create Agent"/"Connect".
    func testProviderConfig_needsVaultSetup() throws {
        let view = try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigNeedsVaultSetup = true
        }
        try assertViewSnapshot(of: view, named: "ProviderConfigSheet.needsVaultSetup")
    }

    // MARK: - Q3 determinism (P3 — the injected humanName renders, no machine-name leak)

    /// The injected fixed name reaches the rendered "Your name" `TextField` (proving the Q3
    /// injection is COVERED, not bypassed), and NO machine `NSFullUserName()` leaks into the tree.
    func testProviderConfig_humanNameInjected_noMachineNameLeak() throws {
        for (name, configure) in [
            ("existingAgent", { (m: WorkbenchViewModel) in m.providerConfigIsNewAgent = false }),
            ("newAgent", { (m: WorkbenchViewModel) in m.providerConfigIsNewAgent = true }),
        ] {
            let tree = try ViewSnapshotHost.snapshotText(of: try sheet(configure))
            XCTAssertTrue(tree.contains(Self.fixedHumanName),
                          "\(name): the injected fixed human name must render in the bound TextField:\n\(tree)")
            XCTAssertFalse(tree.contains(NSFullUserName()),
                           "\(name): the machine NSFullUserName() must NOT leak into the tree (Q3):\n\(tree)")
        }
    }

    // MARK: - Determinism (P3)

    func testProviderConfig_determinism_byteIdenticalTwiceNoLeak() throws {
        let cases: [(String, (WorkbenchViewModel) -> Void)] = [
            ("existingAgent", { $0.providerConfigIsNewAgent = false }),
            ("newAgent", { $0.providerConfigIsNewAgent = true }),
            ("coldStartMessage", { $0.providerConfigIsNewAgent = true; $0.providerConfigColdStartMessage = "Your agent was created but isn't connected yet." }),
            ("inFlight", { $0.providerConfigIsNewAgent = true; $0.providerConfigColdStartInFlight = true }),
            ("needsVaultSetup", { $0.providerConfigIsNewAgent = true; $0.providerConfigNeedsVaultSetup = true }),
        ]
        for (name, configure) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try sheet(configure))
            let b = try ViewSnapshotHost.snapshotText(of: try sheet(configure))
            XCTAssertEqual(a, b, "\(name) must be byte-identical twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains(NSFullUserName()), "\(name): no machine-name leak:\n\(a)")
        }
    }

    // MARK: - Negative controls (P2 — mutation-verified)

    /// The `providerConfigIsNewAgent` gate flips the title + primary-button label (captured copy).
    func testProviderConfig_negativeControl_newAgentGateFlipsTree() throws {
        let existing = try ViewSnapshotHost.snapshotText(of: try sheet { $0.providerConfigIsNewAgent = false })
        let newAgent = try ViewSnapshotHost.snapshotText(of: try sheet { $0.providerConfigIsNewAgent = true })

        XCTAssertNotEqual(existing, newAgent, "the providerConfigIsNewAgent gate must drive the tree")
        XCTAssertTrue(existing.contains("Connect your agent's provider"),
                      "existing: the form.title renders:\n\(existing)")
        XCTAssertTrue(existing.contains("Connect"), "existing: the Connect button renders")
        XCTAssertFalse(existing.contains("Create your agent"), "existing: not the cold-start title")
        // The existing-agent picker renders the raw `allCases` set → GitHub Copilot is offered.
        XCTAssertTrue(existing.contains("GitHub Copilot"),
                      "existing: the allCases picker includes GitHub Copilot:\n\(existing)")
        XCTAssertTrue(newAgent.contains("Create your agent"),
                      "newAgent: the cold-start title renders:\n\(newAgent)")
        XCTAssertTrue(newAgent.contains("Create Agent"), "newAgent: the Create-Agent button renders")
        // BUG2 — the cold-start picker renders only `coldStartProviders` (hatch-capable), so the
        // hatch-incapable GitHub Copilot is DROPPED from the brand-new-agent provider set. This is
        // a captured node-flip that proves the gate AND the cold-start-filter fix together.
        XCTAssertFalse(newAgent.contains("GitHub Copilot"),
                       "newAgent: the cold-start picker drops the hatch-incapable GitHub Copilot:\n\(newAgent)")
    }

    /// The `providerConfigNeedsVaultSetup` gate swaps the primary button for "Finish setup".
    func testProviderConfig_negativeControl_needsVaultGateFlipsButton() throws {
        let normal = try ViewSnapshotHost.snapshotText(of: try sheet { $0.providerConfigIsNewAgent = true })
        let vault = try ViewSnapshotHost.snapshotText(of: try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigNeedsVaultSetup = true
        })

        XCTAssertNotEqual(normal, vault, "the needsVaultSetup gate must drive the button")
        XCTAssertTrue(normal.contains("Create Agent"), "normal: the Create-Agent button renders")
        XCTAssertFalse(normal.contains("Finish setup"), "normal: no Finish-setup affordance")
        XCTAssertTrue(vault.contains("Finish setup"), "vault: the Finish-setup affordance renders:\n\(vault)")
        XCTAssertFalse(vault.contains("Create Agent"), "vault: the Create-Agent button is replaced")
    }

    /// The `providerConfigColdStartInFlight` gate adds the spinner label.
    func testProviderConfig_negativeControl_inFlightGateShowsLabel() throws {
        let idle = try ViewSnapshotHost.snapshotText(of: try sheet { $0.providerConfigIsNewAgent = true })
        let busy = try ViewSnapshotHost.snapshotText(of: try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigColdStartInFlight = true
            $0.providerConfigInFlightLabel = "Creating your agent…"
        })

        XCTAssertNotEqual(idle, busy, "the in-flight gate must drive the tree")
        XCTAssertFalse(idle.contains("Creating your agent…"), "idle: no in-flight label")
        XCTAssertTrue(busy.contains("Creating your agent…"), "busy: the in-flight label renders:\n\(busy)")
    }
}
#endif
