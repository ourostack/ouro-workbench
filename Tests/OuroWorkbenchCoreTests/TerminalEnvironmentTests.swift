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

        XCTAssertTrue(environment.contains("TERM=xterm-256color"))
        XCTAssertTrue(environment.contains("COLORTERM=truecolor"))
        XCTAssertTrue(environment.contains("LANG=en_US.UTF-8"))
        XCTAssertTrue(environment.contains("TERM_PROGRAM=OuroWorkbench"))
        XCTAssertTrue(environment.contains { $0.hasPrefix("PATH=") && $0.contains("/Users/test/.local/bin") })
        XCTAssertTrue(environment.contains { $0.hasPrefix("PATH=") && $0.contains("/opt/homebrew/bin") })
        XCTAssertTrue(environment.contains("HOME=/Users/test"))
    }

    func testDictionaryEnvironmentIncludesResolvedPathAndInteractiveTerminalType() {
        let environment = TerminalEnvironment(values: ["PATH": "/custom/bin", "TERM": "dumb"]).valuesWithResolvedPath()

        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["TERM_PROGRAM"], "OuroWorkbench")
        XCTAssertEqual(environment["PATH"]?.hasPrefix("/custom/bin"), true)
        XCTAssertEqual(environment["PATH"]?.contains("/opt/homebrew/bin"), true)
    }
}
