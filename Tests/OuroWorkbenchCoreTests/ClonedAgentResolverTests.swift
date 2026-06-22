import XCTest
@testable import OuroWorkbenchCore

/// F7 cold-review CRITICAL fix — the pure resolution behind "which agent did this clone actually
/// produce, and is its bundle present?". The App's old `cloneAgentHeadless` gated the whole
/// bundle/probe inspection on `!resolvedName.isEmpty`, so a BLANK agent name (the RECOMMENDED
/// DEFAULT — the clone derives a name from the repo) SKIPPED the inspection entirely:
/// `agentJsonPresent` stayed false and a clean successful clone was reported as the false
/// `.invalidMissingAgentJson` failure. This seam resolves the cloned agent from the REFRESHED
/// roster (the filesystem `agent.json` scan), so BOTH the named and blank paths go through one
/// tested resolution — verified against reality, never an assumed derivation.
final class ClonedAgentResolverTests: XCTestCase {

    private func entry(_ name: String, present: Bool = true, provider: String? = nil) -> ClonedRosterEntry {
        ClonedRosterEntry(name: name, agentJsonPresent: present, provider: provider)
    }

    // MARK: - Blank name (THE regression case): derived name appears in the refreshed roster

    /// THE bug: a blank-name clean clone derives its name from the repo, the bundle lands under that
    /// derived name, and the refreshed roster contains it. The resolver MUST report present=true.
    /// Against the OLD skip-on-blank behavior this would have been `agentJsonPresent=false` → the
    /// false `.invalidMissingAgentJson`.
    func testBlankNameDerivedNamePresentInRosterResolvesPresent() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "",
            remote: "git@github.com:acme/sprout.git",
            rosterNamesBefore: ["existing-bot"],
            rosterAfter: [entry("existing-bot"), entry("sprout", provider: "anthropic")]
        )
        XCTAssertEqual(resolution.name, "sprout")
        XCTAssertTrue(resolution.agentJsonPresent, "a blank-name clean clone whose derived bundle is in the roster MUST resolve present")
        XCTAssertEqual(resolution.provider, "anthropic")
    }

    /// Blank name where `ouro`'s naming DIVERGES from `remoteLabel`'s derivation: the derived name
    /// isn't in the roster, but there's EXACTLY ONE new entry vs the before-snapshot — that new
    /// entry is the clone. This covers the case the assumed-derivation approach would have missed.
    func testBlankNameDivergentDerivationFallsBackToTheSoleNewRosterEntry() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "",
            // remoteLabel derives "sprout", but `ouro` named the bundle "sprout-main".
            remote: "https://github.com/acme/sprout.git",
            rosterNamesBefore: ["existing-bot"],
            rosterAfter: [entry("existing-bot"), entry("sprout-main", provider: "azure")]
        )
        XCTAssertEqual(resolution.name, "sprout-main", "the sole new roster entry IS the clone when the derived name diverges")
        XCTAssertTrue(resolution.agentJsonPresent)
        XCTAssertEqual(resolution.provider, "azure")
    }

    // MARK: - Given (non-blank) name: found in the roster

    func testGivenNameFoundInRosterResolvesPresentWithLane() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "recipe-bot",
            remote: "git@github.com:acme/recipes.git",
            rosterNamesBefore: ["existing-bot"],
            rosterAfter: [entry("existing-bot"), entry("recipe-bot", provider: "openai-codex")]
        )
        XCTAssertEqual(resolution.name, "recipe-bot")
        XCTAssertTrue(resolution.agentJsonPresent)
        XCTAssertEqual(resolution.provider, "openai-codex")
    }

    func testGivenNameTrimmedBeforeLookup() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "  recipe-bot  ",
            remote: "git@github.com:acme/recipes.git",
            rosterNamesBefore: [],
            rosterAfter: [entry("recipe-bot", provider: "minimax")]
        )
        XCTAssertEqual(resolution.name, "recipe-bot")
        XCTAssertTrue(resolution.agentJsonPresent)
        XCTAssertEqual(resolution.provider, "minimax")
    }

    /// Name match is case-insensitive (the roster scan derives the bundle dir name; the operator may
    /// type a differently-cased name). The RESOLVED name is the roster's canonical casing.
    func testGivenNameMatchesRosterCaseInsensitivelyAndAdoptsRosterCasing() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "Recipe-Bot",
            remote: "git@github.com:acme/recipes.git",
            rosterNamesBefore: [],
            rosterAfter: [entry("recipe-bot", provider: "anthropic")]
        )
        XCTAssertEqual(resolution.name, "recipe-bot")
        XCTAssertTrue(resolution.agentJsonPresent)
        XCTAssertEqual(resolution.provider, "anthropic")
    }

    // MARK: - Nothing created → honest invalid (present=false)

    /// A clean exit that created NO bundle: the resolved name isn't in the roster AND there's no new
    /// entry vs the before-snapshot. Honest `agentJsonPresent=false` → the App classifies
    /// `.invalidMissingAgentJson` for REAL (not the false positive the old code produced on success).
    func testNothingCreatedResolvesNotPresent() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "",
            remote: "git@github.com:acme/sprout.git",
            rosterNamesBefore: ["existing-bot"],
            rosterAfter: [entry("existing-bot")]
        )
        XCTAssertEqual(resolution.name, "sprout", "with nothing created the expected (derived) name is still reported")
        XCTAssertFalse(resolution.agentJsonPresent)
        XCTAssertNil(resolution.provider)
    }

    /// Given name, nothing created (no roster entry, no new diff entry) → not present.
    func testGivenNameNothingCreatedResolvesNotPresent() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "recipe-bot",
            remote: "git@github.com:acme/recipes.git",
            rosterNamesBefore: ["existing-bot"],
            rosterAfter: [entry("existing-bot")]
        )
        XCTAssertEqual(resolution.name, "recipe-bot")
        XCTAssertFalse(resolution.agentJsonPresent)
        XCTAssertNil(resolution.provider)
    }

    // MARK: - Present-but-no-provider lane (provider absent → nil)

    /// The bundle is present (the name is in the roster) but its outward lane has no provider — e.g.
    /// the scan saw `agent.json` but the lane is unconfigured. Present=true, provider=nil (the App
    /// then degrades the needs-unlock path to "couldn't confirm" rather than guessing).
    func testPresentEntryWithNoProviderResolvesProviderNil() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "recipe-bot",
            remote: "git@github.com:acme/recipes.git",
            rosterNamesBefore: [],
            rosterAfter: [entry("recipe-bot", provider: nil)]
        )
        XCTAssertEqual(resolution.name, "recipe-bot")
        XCTAssertTrue(resolution.agentJsonPresent)
        XCTAssertNil(resolution.provider)
    }

    /// A roster entry found by name but with `agentJsonPresent=false` (the bundle dir exists but its
    /// `agent.json` is missing — `OuroAgentBundleStatus.missingConfig`) is NOT present: the resolver
    /// honors the entry's own presence flag rather than treating "name in roster" as present.
    func testNamedEntryWithoutAgentJsonResolvesNotPresent() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "recipe-bot",
            remote: "git@github.com:acme/recipes.git",
            rosterNamesBefore: [],
            rosterAfter: [entry("recipe-bot", present: false, provider: nil)]
        )
        XCTAssertEqual(resolution.name, "recipe-bot")
        XCTAssertFalse(resolution.agentJsonPresent, "a roster entry whose agent.json is missing is NOT present")
        XCTAssertNil(resolution.provider)
    }

    // MARK: - Roster-diff guardrails

    /// More than one new entry (a concurrent install + the clone) → the diff is AMBIGUOUS, so the
    /// resolver does NOT guess: it falls back to the derived name's presence (here: not found → not
    /// present). The named-or-derived lookup remains the authority; the diff only rescues the
    /// EXACTLY-ONE-new case.
    func testBlankNameMultipleNewEntriesDoesNotGuessFromTheDiff() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "",
            remote: "https://github.com/acme/sprout.git",
            rosterNamesBefore: ["existing-bot"],
            // Two new names, neither equal to the derived "sprout": ambiguous.
            rosterAfter: [entry("existing-bot"), entry("alpha"), entry("beta")]
        )
        XCTAssertEqual(resolution.name, "sprout")
        XCTAssertFalse(resolution.agentJsonPresent, "an ambiguous multi-new diff must not be guessed as the clone")
        XCTAssertNil(resolution.provider)
    }

    /// The derived name takes precedence over the diff: when BOTH the derived name is present AND a
    /// single new entry exists, the named lookup wins (and they're the same entry in the common
    /// case). Here the derived name matches an EXISTING entry that was already there — but a clean
    /// re-clone over an existing bundle still resolves present via the name, with no spurious diff.
    func testDerivedNameMatchPreferredOverDiffWhenBothApply() {
        let resolution = ClonedAgentResolver.resolveClonedAgent(
            givenName: "",
            remote: "https://github.com/acme/sprout.git",
            // "sprout" already existed (re-clone); a single unrelated new entry also appeared.
            rosterNamesBefore: ["sprout", "existing-bot"],
            rosterAfter: [entry("sprout", provider: "anthropic"), entry("existing-bot"), entry("late-arrival")]
        )
        XCTAssertEqual(resolution.name, "sprout", "the derived-name match is preferred over the roster diff")
        XCTAssertTrue(resolution.agentJsonPresent)
        XCTAssertEqual(resolution.provider, "anthropic")
    }

    // MARK: - ClonedRosterEntry value semantics

    func testClonedRosterEntryIsEquatable() {
        XCTAssertEqual(
            ClonedRosterEntry(name: "a", agentJsonPresent: true, provider: "azure"),
            ClonedRosterEntry(name: "a", agentJsonPresent: true, provider: "azure")
        )
        XCTAssertNotEqual(
            ClonedRosterEntry(name: "a", agentJsonPresent: true, provider: "azure"),
            ClonedRosterEntry(name: "a", agentJsonPresent: false, provider: "azure")
        )
    }
}
