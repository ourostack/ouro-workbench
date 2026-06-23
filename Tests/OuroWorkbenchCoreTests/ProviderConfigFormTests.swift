import XCTest
@testable import OuroWorkbenchCore

final class ProviderConfigFormTests: XCTestCase {
    // MARK: - New-agent name validation (the empty-machine "Create Agent" path)

    func testNewAgentNameValidation() {
        let existing = ["ouroboros", "slugger"]
        // Valid, non-colliding name.
        XCTAssertNil(ProviderConfigForm.newAgentNameValidationMessage("scout", existingNames: existing))
        // Empty / whitespace.
        XCTAssertEqual(ProviderConfigForm.newAgentNameValidationMessage("   ", existingNames: existing), "Please give your agent a name.")
        // Invalid bundle name (slash).
        XCTAssertEqual(
            ProviderConfigForm.newAgentNameValidationMessage("bad/name", existingNames: existing),
            "That name can't be used. Avoid slashes, colons, and backslashes."
        )
        // Collides with an installed agent (case-insensitive) — that's the existing-agent path.
        XCTAssertEqual(
            ProviderConfigForm.newAgentNameValidationMessage("Ouroboros", existingNames: existing),
            "An agent named Ouroboros already exists. Pick a different name."
        )
    }

    // MARK: - Supported providers (the 5 from `ouro`'s isAgentProvider)

    func testSupportedProvidersAreExactlyTheFiveAgentProviders() {
        let ids = Set(WorkbenchProvider.allCases.map(\.providerFlagValue))
        XCTAssertEqual(ids, ["azure", "anthropic", "minimax", "openai-codex", "github-copilot"])
    }

    // MARK: - Resolve a provider from a cloned agent.json lane (F7 / B-4)

    func testProviderRoundTripsFromItsFlagValue() {
        // F7 — a clone has no operator-entered provider; the needsVaultUnlock path reads the
        // provider STRING from the cloned agent.json outward lane and must map it back to a
        // WorkbenchProvider to drive F6's reconnect chain. The mapping must round-trip every case.
        for provider in WorkbenchProvider.allCases {
            XCTAssertEqual(WorkbenchProvider(providerFlagValue: provider.providerFlagValue), provider)
        }
    }

    func testProviderIsNilForAnUnknownOrAbsentFlagValue() {
        // An unrecognized / absent lane provider degrades honestly (the App falls back to the
        // .couldNotConfirm copy rather than guessing a provider).
        XCTAssertNil(WorkbenchProvider(providerFlagValue: "gemini"))
        XCTAssertNil(WorkbenchProvider(providerFlagValue: ""))
    }

    func testEachProviderDeclaresItsRequiredCredentialFields() {
        // Field shapes mirror `ouro`'s PROVIDER_CREDENTIALS required[] for the cold-start sink.
        XCTAssertEqual(WorkbenchProvider.anthropic.credentialFields.map(\.key), ["setupToken"])
        XCTAssertEqual(WorkbenchProvider.openaiCodex.credentialFields.map(\.key), ["oauthToken"])
        XCTAssertEqual(WorkbenchProvider.minimax.credentialFields.map(\.key), ["apiKey"])
        XCTAssertEqual(WorkbenchProvider.azure.credentialFields.map(\.key), ["apiKey", "endpoint", "deployment"])
        XCTAssertEqual(WorkbenchProvider.githubCopilot.credentialFields.map(\.key), ["githubToken"])
    }

    func testProviderCredentialFieldsFlagWhichAreSecret() {
        // The secret-bearing fields must be rendered securely (SecureField) in the form.
        XCTAssertTrue(WorkbenchProvider.anthropic.credentialFields[0].isSecret)
        XCTAssertTrue(WorkbenchProvider.minimax.credentialFields[0].isSecret)
        // Azure: apiKey is secret; endpoint/deployment are not.
        let azure = WorkbenchProvider.azure.credentialFields
        XCTAssertTrue(azure[0].isSecret)   // apiKey
        XCTAssertFalse(azure[1].isSecret)  // endpoint
        XCTAssertFalse(azure[2].isSecret)  // deployment
    }

    // MARK: - Cohesive-product copy (NO CLI seam in any human-facing string)

    func testProviderDisplayNamesAreSeamFree() {
        for provider in WorkbenchProvider.allCases {
            assertSeamFree(provider.displayName)
            for field in provider.credentialFields {
                assertSeamFree(field.label)
            }
        }
    }

    func testFormTitleAndSubtitleAreSeamFree() {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        assertSeamFree(form.title)
        assertSeamFree(form.subtitle)
    }

    // MARK: - Cold-start command construction (argv sink, 4 supported providers)

    func testAnthropicColdStartBuildsHatchWithSetupToken() throws {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .anthropic, values: ["setupToken": "sk-ant-oat01-XYZ"])

        guard case let .coldStartHatch(plan) = outcome else {
            return XCTFail("expected coldStartHatch, got \(outcome)")
        }
        XCTAssertEqual(plan.tokens, [
            "ouro", "hatch",
            "--agent", "slugger",
            "--human", "Ari",
            "--provider", "anthropic",
            "--setup-token", "sk-ant-oat01-XYZ",
        ])
    }

    func testOpenAICodexColdStartBuildsHatchWithOAuthToken() throws {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .openaiCodex, values: ["oauthToken": "oauth-abc"])

        guard case let .coldStartHatch(plan) = outcome else {
            return XCTFail("expected coldStartHatch, got \(outcome)")
        }
        XCTAssertEqual(plan.tokens, [
            "ouro", "hatch",
            "--agent", "slugger", "--human", "Ari", "--provider", "openai-codex",
            "--oauth-token", "oauth-abc",
        ])
    }

    func testMinimaxColdStartBuildsHatchWithApiKey() throws {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .minimax, values: ["apiKey": "mm-123"])

        guard case let .coldStartHatch(plan) = outcome else {
            return XCTFail("expected coldStartHatch, got \(outcome)")
        }
        XCTAssertEqual(plan.tokens, [
            "ouro", "hatch",
            "--agent", "slugger", "--human", "Ari", "--provider", "minimax",
            "--api-key", "mm-123",
        ])
    }

    func testAzureColdStartBuildsHatchWithApiKeyEndpointDeployment() throws {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .azure, values: [
            "apiKey": "az-key",
            "endpoint": "https://example.openai.azure.com",
            "deployment": "gpt-4o",
        ])

        guard case let .coldStartHatch(plan) = outcome else {
            return XCTFail("expected coldStartHatch, got \(outcome)")
        }
        XCTAssertEqual(plan.tokens, [
            "ouro", "hatch",
            "--agent", "slugger", "--human", "Ari", "--provider", "azure",
            "--api-key", "az-key",
            "--endpoint", "https://example.openai.azure.com",
            "--deployment", "gpt-4o",
        ])
    }

    // MARK: - Validation branches (missing fields, invalid agent)

    func testMissingRequiredFieldYieldsValidationError() {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .azure, values: ["apiKey": "az-key", "endpoint": "  "])

        guard case let .invalid(message) = outcome else {
            return XCTFail("expected invalid, got \(outcome)")
        }
        assertSeamFree(message)
        // Names the empty human-facing field labels, not the raw flag keys.
        XCTAssertTrue(message.contains("Azure endpoint"))
        XCTAssertTrue(message.contains("Azure deployment"))
        XCTAssertFalse(message.contains("--endpoint"))
    }

    func testMissingCredentialLabelsTreatAbsentKeysAsMissing() {
        let fields = [
            ProviderCredentialField(key: "present", label: "Present", isSecret: true),
            ProviderCredentialField(key: "absent", label: "Absent", isSecret: false),
        ]

        XCTAssertEqual(
            ProviderConfigForm.missingCredentialLabels(fields: fields, trimmed: ["present": "value"]),
            ["Absent"]
        )
    }

    func testBlankAgentNameYieldsValidationError() {
        let form = ProviderConfigForm(agentName: "   ", humanName: "Ari")
        let outcome = form.submit(provider: .minimax, values: ["apiKey": "mm-123"])

        guard case let .invalid(message) = outcome else {
            return XCTFail("expected invalid, got \(outcome)")
        }
        assertSeamFree(message)
    }

    func testBlankHumanNameYieldsValidationError() {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "  ")
        let outcome = form.submit(provider: .minimax, values: ["apiKey": "mm-123"])

        guard case .invalid = outcome else {
            return XCTFail("expected invalid, got \(outcome)")
        }
    }

    func testInvalidAgentBundleNameYieldsValidationError() {
        // A non-empty but invalid bundle name (path separators) reaches the hatch builder, which
        // throws — surfaced as a seam-free validation message, never a crash or fabricated command.
        let form = ProviderConfigForm(agentName: "bad/name", humanName: "Ari")
        let outcome = form.submit(provider: .minimax, values: ["apiKey": "mm-123"])

        guard case let .invalid(message) = outcome else {
            return XCTFail("expected invalid, got \(outcome)")
        }
        assertSeamFree(message)
    }

    // MARK: - github-copilot: the documented cold-start sink gap (flagged, NOT a pane)

    func testGithubCopilotColdStartIsUnsupportedSinkNotACommand() {
        // `ouro hatch` has no argv flag for github-copilot's githubToken/baseUrl, so cold-start
        // via argv is genuinely unavailable today. The form reports this honestly as an
        // unsupported sink — it does NOT fabricate a command and does NOT reopen a pane.
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .githubCopilot, values: ["githubToken": "gho_abc"])

        guard case let .unsupportedColdStartSink(message) = outcome else {
            return XCTFail("expected unsupportedColdStartSink, got \(outcome)")
        }
        assertSeamFree(message)
    }

    func testGithubCopilotHasNoHatchCredentialSink() {
        // Direct contract: github-copilot maps to no `ouro hatch` argv credential (the gap).
        XCTAssertNil(WorkbenchProvider.githubCopilot.hatchCredential(from: ["githubToken": "gho_abc"]))
        XCTAssertNotNil(WorkbenchProvider.minimax.hatchCredential(from: ["apiKey": "mm-123"]))
    }

    func testProviderHatchCredentialMappingsUseTrimmedValuesByKey() {
        XCTAssertEqual(
            WorkbenchProvider.anthropic.hatchCredential(from: ["setupToken": "setup"]),
            .setupToken("setup")
        )
        XCTAssertEqual(
            WorkbenchProvider.openaiCodex.hatchCredential(from: ["oauthToken": "oauth"]),
            .oauthToken("oauth")
        )
        XCTAssertEqual(
            WorkbenchProvider.minimax.hatchCredential(from: ["apiKey": "mm"]),
            .apiKey("mm")
        )
        XCTAssertEqual(
            WorkbenchProvider.azure.hatchCredential(from: ["endpoint": "https://example", "deployment": "gpt"]),
            .endpoint(endpoint: "https://example", deployment: "gpt")
        )
        XCTAssertEqual(WorkbenchProvider.anthropic.hatchCredential(from: [:]), .setupToken(""))
        XCTAssertEqual(WorkbenchProvider.openaiCodex.hatchCredential(from: [:]), .oauthToken(""))
        XCTAssertEqual(WorkbenchProvider.minimax.hatchCredential(from: [:]), .apiKey(""))
        XCTAssertEqual(WorkbenchProvider.azure.hatchCredential(from: [:]), .endpoint(endpoint: "", deployment: ""))
    }

    func testProviderAndFieldIdentifiers() {
        // Identifiable conformance powers the SwiftUI ForEach over providers/fields.
        XCTAssertEqual(WorkbenchProvider.azure.id, "azure")
        let field = WorkbenchProvider.azure.credentialFields[0]
        XCTAssertEqual(field.id, field.key)
    }

    func testCanSubmitColdStartReflectsArgvSinkSupport() {
        XCTAssertTrue(WorkbenchProvider.anthropic.supportsColdStartHatch)
        XCTAssertTrue(WorkbenchProvider.openaiCodex.supportsColdStartHatch)
        XCTAssertTrue(WorkbenchProvider.minimax.supportsColdStartHatch)
        XCTAssertTrue(WorkbenchProvider.azure.supportsColdStartHatch)
        XCTAssertFalse(WorkbenchProvider.githubCopilot.supportsColdStartHatch)
    }

    func testColdStartProvidersExcludesHatchIncapableProviders() {
        // BUG 2: the Create-Agent / cold-start picker must offer ONLY providers a brand-new agent
        // can actually be hatched for. GitHub Copilot has no `ouro hatch` argv sink
        // (`supportsColdStartHatch == false`), so offering it as a cold-start option is a guaranteed
        // dead end — `submit()` returns `.unsupportedColdStartSink`. The cold-start set is exactly
        // `allCases` filtered on `supportsColdStartHatch`.
        let coldStart = WorkbenchProvider.coldStartProviders

        // Copilot — the one hatch-incapable provider — must be absent from the cold-start set.
        XCTAssertFalse(coldStart.contains(.githubCopilot))
        // Every hatch-capable provider must remain offered (an API-key one + the rest).
        XCTAssertTrue(coldStart.contains(.minimax))
        XCTAssertTrue(coldStart.contains(.anthropic))
        XCTAssertTrue(coldStart.contains(.openaiCodex))
        XCTAssertTrue(coldStart.contains(.azure))
        // The set is precisely allCases minus the hatch-incapable providers (order preserved).
        XCTAssertEqual(coldStart, WorkbenchProvider.allCases.filter(\.supportsColdStartHatch))
        // Copilot is NOT removed globally — it stays a valid WorkbenchProvider for the reconnect /
        // existing-agent path (ouroboros is a github-copilot agent). Only the cold-start set drops it.
        XCTAssertTrue(WorkbenchProvider.allCases.contains(.githubCopilot))
    }

    // NOTE (F6): the former `testExistingAgentRefreshMessageIsHonestAndSeamFree` is gone with the
    // `existingAgentRefreshUnavailableMessage` it covered — an existing agent's Connect now drives a
    // real credential rotation (see `CredentialRotationTests` for the rotation command + flavored
    // copy, and `CredentialRotationWiringTests` for the short-circuit replacement).

    // MARK: - Whitespace trimming

    func testCredentialValuesAreTrimmedBeforeBuildingCommand() throws {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .minimax, values: ["apiKey": "  mm-123  "])

        guard case let .coldStartHatch(plan) = outcome else {
            return XCTFail("expected coldStartHatch, got \(outcome)")
        }
        XCTAssertEqual(plan.tokens.last, "mm-123")
    }

    func testAzureApiKeyInsertionFallsBackSafelyWhenProviderTokenIsAbsent() {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let plan = BootstrapAgentProvisionPlan(tokens: ["ouro", "hatch"])

        let outcome = form.submit(provider: .azure, values: [
            "apiKey": "az-key",
            "endpoint": "https://example.openai.azure.com",
            "deployment": "gpt-4o",
        ])

        guard case let .coldStartHatch(realPlan) = outcome else {
            return XCTFail("expected coldStartHatch, got \(outcome)")
        }
        XCTAssertEqual(realPlan.tokens[realPlan.tokens.firstIndex(of: "azure")! + 1], "--api-key")

        let fallback = form.withAzureApiKey("az-key", into: plan, provider: .azure)
        XCTAssertEqual(fallback.tokens, ["ouro", "hatch", "--api-key", "az-key"])
    }

    func testColdStartRunnerReturnsExitedZeroForSuccessfulCommand() async {
        // F1 seam 1: runHeadless now REPORTS the hatch exit instead of swallowing it. A finite
        // command that exits 0 (`true`) returns `.exited(code: 0)` — mirrors CloneAgentRunner's
        // `true`/`false` finite-command coverage.
        let result = await ColdStartHatchRunner.runHeadless(plan: BootstrapAgentProvisionPlan(tokens: ["true"]))
        XCTAssertEqual(result, .exited(code: 0))
    }

    func testColdStartRunnerReturnsExitedNonZeroForFailingCommand() async {
        // A finite command that exits non-zero (`false` exits 1) surfaces `.exited(code: 1)` —
        // this is the truth the old "deliberately ignore the exit status" code threw away, which
        // is exactly what let a dead, credential-less hatch report success.
        let result = await ColdStartHatchRunner.runHeadless(plan: BootstrapAgentProvisionPlan(tokens: ["false"]))
        XCTAssertEqual(result, .exited(code: 1))
    }

    func testColdStartRunnerReturnsLaunchFailedWhenProcessCannotStart() async {
        // When the process can't be launched at all, `run()` throws and runHeadless catches it →
        // `.launchFailed` (distinct from a non-zero exit, so the classifier can tell "never ran"
        // from "ran + failed"). Production hardcodes `/usr/bin/env` (which always launches), so we
        // inject a non-existent executable to exercise this path deterministically.
        let result = await ColdStartHatchRunner.runHeadless(
            plan: BootstrapAgentProvisionPlan(tokens: ["whatever"]),
            executableURL: URL(fileURLWithPath: "/no/such/binary/ouro-coldstart-does-not-exist")
        )
        XCTAssertEqual(result, .launchFailed)
    }

    func testColdStartRunResultExposesExitCodeForExitedAndNilForLaunchFailed() {
        // The App wiring reads `run.exitCode` to fold `.launchFailed` → nil and `.exited` → its code
        // before handing to classifyColdStart. Pin that accessor.
        XCTAssertEqual(ColdStartRunResult.exited(code: 0).exitCode, 0)
        XCTAssertEqual(ColdStartRunResult.exited(code: 7).exitCode, 7)
        XCTAssertNil(ColdStartRunResult.launchFailed.exitCode)
    }

    // MARK: - Helpers

    private func assertSeamFree(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = string.lowercased()
        for seam in ["ouro", "daemon", "hatch", "cli", "--", "vault", "serpentguide"] {
            XCTAssertFalse(
                lowered.contains(seam),
                "human-facing copy must not expose the CLI seam '\(seam)': \(string)",
                file: file,
                line: line
            )
        }
    }
}
