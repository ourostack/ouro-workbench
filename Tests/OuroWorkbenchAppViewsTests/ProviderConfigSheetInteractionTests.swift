#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B7 — `ProviderConfigSheet` (`:6148`) INTERACTION drive-to-100%.
///
/// The C6-1 `ProviderConfigSheetTests` snapshot the rendered state-set but never EXECUTE the
/// footer buttons, the credential-field binding, the provider `.onChange`, nor the `submit()`
/// helper — so the "Cancel" (`:6235` → `dismiss()`), "Finish setup" (`:6244` →
/// `beginVaultOnboarding`), "Connect/Create" (`:6252` → `submit()`) actions, the
/// `binding(for:)` set closure (`:6286`), the `.onChange(of: provider)` reset (`:6265`), the
/// non-secret credential `TextField` arm (`:6207`), and `submit()`'s body (`:6290–6307`) were
/// never coloured. ViewInspector 0.10.3 invokes action-closures + Picker `select` + TextField
/// `setInput`, so this suite DRIVES the reachable ones and ASSERTS their model side-effect.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection).
/// `submit()` is driven through its VALIDATION-FAILURE arms (new-agent invalid name; existing-
/// agent invalid credentials) so NO live `ouro hatch`/vault terminal is ever spawned — the
/// honest early-return paths. The clear of `model.providerConfigColdStartMessage` (the FIRST
/// statement of `submit()`) is the observable proof the helper ran.
///
/// **Carves (recorded for Unit 3 — `@State`-no-init-seam):** the non-secret credential
/// `TextField` arm (`:6207`) and the `.onChange(of: provider)` reset (`:6265`) both require
/// flipping the `@State private var provider` (no init seam; prod default `.anthropic`
/// UNCHANGED). ViewInspector's synchronous `inspect()` does not persist a `@State` mutation
/// across re-inspection (the C4 `DecisionLogRow.taught` / AgentDetailView precedent), so a
/// Picker `select(value:)` cannot reach the post-change render. Recorded as carves, not faked.
///
/// **Non-vacuity (P2 — mutation-verified).** Neutering `submit()`'s `model.providerConfigColdStartMessage = nil`
/// leaves the seeded stale message → `testProvider_connect_runsSubmit` goes RED.
@MainActor
final class ProviderConfigSheetInteractionTests: XCTestCase {

    private static let fixedHumanName = "Test User"

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-provider-\(UUID().uuidString)", isDirectory: true)
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

    private func sheet(_ configure: (WorkbenchViewModel) -> Void = { _ in }) throws -> ProviderConfigSheet {
        let model = try makeVM()
        model.providerConfigAgentName = "boss"
        configure(model)
        return ProviderConfigSheet(model: model, initialHumanName: Self.fixedHumanName)
    }

    // MARK: - Footer buttons

    /// "Cancel" (`:6235`) runs `dismiss()` (a no-op under ViewInspector, but the closure RUNS).
    func testProvider_cancel_runsDismiss() throws {
        let view = try sheet { $0.providerConfigIsNewAgent = false }
        XCTAssertNoThrow(try view.inspect().find(button: "Cancel").tap())
    }

    /// "Finish setup" (`:6244`) runs `beginVaultOnboarding`. WITHOUT a stashed
    /// `providerConfigColdStartProvider` it takes the early-return guard (nothing to recover) →
    /// the closure RUNS (coverage) and NO terminal is spawned (the guard holds).
    func testProvider_finishSetup_runsBeginVaultOnboarding_earlyReturns() throws {
        let view = try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigNeedsVaultSetup = true      // shows the "Finish setup" button
            // providerConfigColdStartProvider left nil → beginVaultOnboarding early-returns.
        }
        XCTAssertTrue(view.model.state.processEntries.isEmpty, "precondition: no sessions")
        try view.inspect().find(button: "Finish setup").tap()
        XCTAssertTrue(view.model.state.processEntries.isEmpty,
                      "beginVaultOnboarding early-returns (no stashed provider) → no terminal spawned")
    }

    /// "Connect" (`:6252`) runs `submit()` (`:6290`). For an EXISTING agent with invalid (empty)
    /// credentials, `submitProviderConfig` → `form.submit` returns `.invalid` and submit returns
    /// the message — NO live hatch/terminal. The observable proof: submit's first statements clear
    /// `model.providerConfigColdStartMessage` (seeded stale here) — so the helper demonstrably ran.
    func testProvider_connect_runsSubmit() throws {
        let view = try sheet {
            $0.providerConfigIsNewAgent = false
            $0.providerConfigColdStartMessage = "stale outcome line"   // submit() clears this
        }
        XCTAssertEqual(view.model.providerConfigColdStartMessage, "stale outcome line", "precondition: seeded")
        try view.inspect().find(button: "Connect").tap()
        XCTAssertNil(view.model.providerConfigColdStartMessage,
                     "submit() clears the stale cold-start message → the Connect action ran the helper")
    }

    /// "Create Agent" (`:6252`, new-agent) runs `submit()` → the new-agent block (`:6294`) +
    /// `newAgentNameValidationMessage` (`:6298`). With the form's BLANK `newAgentName` @State the
    /// name is invalid → submit sets the local message and returns at `:6300` BEFORE any hatch (the
    /// safe validation-failure arm). The observable proof: submit's `model.providerConfigColdStartMessage`
    /// clear ran, and NO terminal spawned.
    func testProvider_createAgent_runsSubmit_newAgentInvalidNameArm() throws {
        let view = try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigColdStartMessage = "stale outcome line"
        }
        try view.inspect().find(button: "Create Agent").tap()
        XCTAssertNil(view.model.providerConfigColdStartMessage,
                     "submit() ran (the new-agent block + name validation), clearing the stale message")
        XCTAssertTrue(view.model.state.processEntries.isEmpty,
                      "the invalid blank name returns BEFORE any hatch → no terminal spawned")
    }

    /// The EXISTING-agent Connect path drives `submitProviderConfig`'s `.invalid` failure arm
    /// (`:6304` true → `:6305` message → `:6306` return): the hermetic roster has no "boss" agent,
    /// so `providerConfigAgentAlreadyExists` is false → `form.submit` returns `.invalid` (EMPTY
    /// credential values fail the missing-fields guard FIRST, BEFORE any hatch). Observable proof:
    /// the submit ran AND no terminal spawned (the honest validation-failure return).
    func testProvider_connect_submitProviderConfigInvalidArm() throws {
        let view = try sheet { $0.providerConfigIsNewAgent = false }   // existing agent "boss"
        try view.inspect().find(button: "Connect").tap()
        XCTAssertTrue(view.model.state.processEntries.isEmpty,
                      "submitProviderConfig returned .invalid (missing credentials) → no terminal spawned")
        XCTAssertFalse(view.model.providerConfigColdStartInFlight,
                       "the validation-failure arm never sets the in-flight flag (no hatch)")
    }

    // MARK: - Credential-field binding set closure (`:6286`)

    /// Editing a credential field drives the `binding(for:)` SET closure (`:6286` →
    /// `values[key] = $0`). The Anthropic setup-token is a `SecureField`; setting its input runs
    /// the bound setter. The observable proof is no-throw (the bound value is local `@State`).
    func testProvider_credentialField_setInput_runsBindingSetter() throws {
        let view = try sheet { $0.providerConfigIsNewAgent = false }   // anthropic default
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.SecureField.self).setInput("token-value"),
            "setting the secure credential field runs the binding(for:) setter")
    }

    // MARK: - Provider .onChange reset (`:6265`)

    /// The `.onChange(of: provider)` reset (`:6265`) clears the per-provider field values AND drops
    /// a stale `.needsVaultSetup` affordance + stashed provider + cold-start message (BUG 1). Driven
    /// via ViewInspector's `callOnChange` (which fires the closure directly), asserted on the MODEL
    /// writes it performs — so the closure is covered + non-vacuous without a `@State` init seam.
    func testProvider_onChangeProvider_resetsStaleVaultAffordance() throws {
        let view = try sheet {
            $0.providerConfigIsNewAgent = true
            $0.providerConfigNeedsVaultSetup = true                 // a stale affordance to drop
            $0.providerConfigColdStartProvider = .anthropic         // a stashed provider to clear
            $0.providerConfigColdStartMessage = "stale outcome"     // a stale message to clear
        }
        try view.inspect().vStack().callOnChange(oldValue: WorkbenchProvider.anthropic,
                                                 newValue: WorkbenchProvider.minimax)
        XCTAssertFalse(view.model.providerConfigNeedsVaultSetup,
                       "onChange drops the stale needs-vault affordance (BUG 1)")
        XCTAssertNil(view.model.providerConfigColdStartProvider,
                     "onChange clears the stashed cold-start provider")
        XCTAssertNil(view.model.providerConfigColdStartMessage,
                     "onChange clears the stale cold-start message")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The Connect action's submit() side-effect (clearing the stale cold-start message) is
    /// load-bearing: before the tap the stale message is present; after, it's cleared.
    func testProvider_negativeControl_submitClearsStaleMessage() throws {
        let model = try makeVM()
        model.providerConfigAgentName = "boss"
        model.providerConfigIsNewAgent = false
        model.providerConfigColdStartMessage = "stale"
        let view = ProviderConfigSheet(model: model, initialHumanName: Self.fixedHumanName)
        XCTAssertNotNil(model.providerConfigColdStartMessage, "before: stale present")
        try view.inspect().find(button: "Connect").tap()
        XCTAssertNil(model.providerConfigColdStartMessage, "after: cleared (submit ran)")
    }
}
#endif
