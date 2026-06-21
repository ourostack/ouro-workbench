import XCTest
@testable import OuroWorkbenchCore

/// U15 — the pure validation→(enabled, message) mapping behind the clone sheet's
/// optional agent-name field. A blank name is VALID (it defaults to the repo name);
/// only a non-blank-but-malformed name disables the action and shows an inline error.
final class CloneAgentNameValidationTests: XCTestCase {
    func testBlankNameIsValidAndProceeds() {
        // Empty / whitespace-only is the "default to the repo name" path — valid,
        // no error message, and never disables the action on the name's account.
        for blank in ["", "   ", "\n\t "] {
            let result = CloneAgentNameValidation.evaluate(blank)
            XCTAssertFalse(result.isInvalid, "blank name should not be invalid: \(blank.debugDescription)")
            XCTAssertNil(result.message, "blank name should carry no inline error: \(blank.debugDescription)")
        }
    }

    func testWellFormedNameIsValid() {
        let result = CloneAgentNameValidation.evaluate("sprout")
        XCTAssertFalse(result.isInvalid)
        XCTAssertNil(result.message)
    }

    func testLeadingTrailingWhitespaceIsTrimmedBeforeValidating() {
        // The operator typing "  sprout  " is fine — the trimmed name is well-formed.
        let result = CloneAgentNameValidation.evaluate("  sprout  ")
        XCTAssertFalse(result.isInvalid)
        XCTAssertNil(result.message)
    }

    func testNameWithDisallowedCharactersIsInvalidWithInlineMessage() {
        // Slash / colon / backslash / path-traversal are rejected by the shared
        // bundle-name rule — and surfaced as a labeled inline message, never the
        // command preview.
        for bad in ["../sprout", "a/b", "a:b", "a\\b", ".", ".."] {
            let result = CloneAgentNameValidation.evaluate(bad)
            XCTAssertTrue(result.isInvalid, "expected \(bad.debugDescription) to be invalid")
            XCTAssertEqual(
                result.message,
                "That name can't be used. Avoid slashes, colons, and backslashes.",
                "inline message should match the native form's wording for \(bad.debugDescription)"
            )
        }
    }

    func testValidationReusesTheSharedBundleNameRule() {
        // The mapping must agree with BossWorkbenchMCPRegistrar.isValidAgentBundleName
        // for every non-blank input (the single source of truth for name legality).
        for name in ["sprout", "Recipe Bot", "../x", "a/b", "a:b", "ok-name_1"] {
            let result = CloneAgentNameValidation.evaluate(name)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                result.isInvalid,
                !BossWorkbenchMCPRegistrar.isValidAgentBundleName(trimmed),
                "evaluate() must mirror isValidAgentBundleName for \(name.debugDescription)"
            )
        }
    }
}
