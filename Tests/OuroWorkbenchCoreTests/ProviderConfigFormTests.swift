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

    // MARK: - Existing-agent credential-refresh gap (gap a — honest, seam-free, NOT a pane)

    func testExistingAgentRefreshMessageIsHonestAndSeamFree() {
        // Refreshing an EXISTING agent's provider credentials has no headless `ouro`
        // non-interactive sink today (the documented narrow gap). The form must say so
        // honestly — never fabricate a command and never reopen a CLI pane. The copy is a
        // pure Core value so the cohesive-product wording is unit-tested.
        let message = ProviderConfigForm.existingAgentRefreshUnavailableMessage(agentName: "slugger")

        // Names the agent and is honest that it's "not available yet" (no false promise of work).
        XCTAssertTrue(message.contains("slugger"), "message should name the agent: \(message)")
        let lowered = message.lowercased()
        XCTAssertTrue(
            lowered.contains("not available") || lowered.contains("isn't available") || lowered.contains("yet"),
            "message must honestly signal the affordance is not available yet: \(message)"
        )
        // Seam-free: no CLI/daemon/hatch vocabulary leaks to the human.
        assertSeamFree(message)
    }

    // MARK: - Whitespace trimming

    func testCredentialValuesAreTrimmedBeforeBuildingCommand() throws {
        let form = ProviderConfigForm(agentName: "slugger", humanName: "Ari")
        let outcome = form.submit(provider: .minimax, values: ["apiKey": "  mm-123  "])

        guard case let .coldStartHatch(plan) = outcome else {
            return XCTFail("expected coldStartHatch, got \(outcome)")
        }
        XCTAssertEqual(plan.tokens.last, "mm-123")
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
