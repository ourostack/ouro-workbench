import XCTest
@testable import OuroWorkbenchCore

final class TerminalEnvironmentTests: XCTestCase {
    func testResolvedPathAddsHomebrewAndSystemFallbacks() {
        let path = TerminalEnvironment.resolvedPath(from: ["PATH": "/custom/bin:/usr/bin", "HOME": "/Users/test"])

        XCTAssertTrue(path.hasPrefix("/custom/bin:/usr/bin"))
        XCTAssertTrue(path.contains("/Users/test/.local/bin"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/bin"))
        XCTAssertEqual(path.components(separatedBy: ":").filter { $0 == "/usr/bin" }.count, 1)
    }

    func testMergedEnvironmentIncludesPathAndTerminalDefaults() {
        let environment = TerminalEnvironment(values: ["HOME": "/Users/test"]).mergedWithTerminalDefaults()

        // 256-color, with NO truecolor claim — advertising COLORTERM=truecolor
        // makes agent TUIs emit 24-bit sequences that screen 4.00.03 mangles.
        XCTAssertTrue(environment.contains("TERM=xterm-256color"))
        XCTAssertFalse(environment.contains { $0.hasPrefix("COLORTERM=") })
        XCTAssertTrue(environment.contains("LANG=en_US.UTF-8"))
        XCTAssertTrue(environment.contains("TERM_PROGRAM=OuroWorkbench"))
        XCTAssertTrue(environment.contains { $0.hasPrefix("PATH=") && $0.contains("/Users/test/.local/bin") })
        XCTAssertTrue(environment.contains { $0.hasPrefix("PATH=") && $0.contains("/opt/homebrew/bin") })
        XCTAssertTrue(environment.contains("HOME=/Users/test"))
    }

    func testDictionaryEnvironmentIncludesResolvedPathAndInteractiveTerminalType() {
        let environment = TerminalEnvironment(values: ["PATH": "/custom/bin", "TERM": "dumb", "COLORTERM": "truecolor"]).valuesWithResolvedPath()

        XCTAssertEqual(environment["TERM"], "xterm-256color")
        // Inherited COLORTERM=truecolor must be stripped — the screen 4.00.03
        // transport can't carry truecolor, and advertising it mangles TUIs.
        XCTAssertNil(environment["COLORTERM"])
        XCTAssertEqual(environment["TERM_PROGRAM"], "OuroWorkbench")
        XCTAssertEqual(environment["PATH"]?.hasPrefix("/custom/bin"), true)
        XCTAssertEqual(environment["PATH"]?.contains("/opt/homebrew/bin"), true)
    }

    func testAlwaysOnWorkbenchMarkersAreSetEvenWithoutContext() {
        let environment = TerminalEnvironment(values: ["HOME": "/Users/test"]).valuesWithResolvedPath()

        XCTAssertEqual(environment["OURO_WORKBENCH"], "1")
        XCTAssertEqual(environment["OURO_WORKBENCH_VERSION"], WorkbenchRelease.version)
        // No per-session context supplied: the contextual vars must be absent,
        // never emitted empty.
        XCTAssertNil(environment["OURO_WORKBENCH_GROUP"])
        XCTAssertNil(environment["OURO_WORKBENCH_SESSION"])
        XCTAssertNil(environment["OURO_WORKBENCH_CONTEXT_FILE"])
        XCTAssertNil(environment["OURO_WORKBENCH_BOSS"])
    }

    func testWorkbenchContextInjectsOnlyPopulatedSessionVariables() {
        let context = WorkbenchSessionContext(
            contextFilePath: "/tmp/agent-context.md",
            group: "ouro-workbench",
            session: "Codex",
            boss: ""
        )
        let environment = TerminalEnvironment(
            values: ["HOME": "/Users/test"],
            workbenchContext: context
        ).valuesWithResolvedPath()

        XCTAssertEqual(environment["OURO_WORKBENCH_CONTEXT_FILE"], "/tmp/agent-context.md")
        XCTAssertEqual(environment["OURO_WORKBENCH_GROUP"], "ouro-workbench")
        XCTAssertEqual(environment["OURO_WORKBENCH_SESSION"], "Codex")
        // Empty boss is dropped rather than exported as an empty string.
        XCTAssertNil(environment["OURO_WORKBENCH_BOSS"])
        XCTAssertEqual(environment["OURO_WORKBENCH"], "1")
    }
}
