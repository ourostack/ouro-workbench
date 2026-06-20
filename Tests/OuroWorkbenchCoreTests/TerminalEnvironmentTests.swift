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

    func testResolvedPathIncludesOuroCliBinAheadOfSystemDirs() {
        // `ouro` installs only to ~/.ouro-cli/bin (CurrentVersion symlink) and is
        // present nowhere else; a Finder/login-launched app inherits the bare
        // launchd PATH, so without this entry daemon bringup / hatch / verify
        // shellouts cannot resolve `ouro` on a clean install. It must also precede
        // the system dirs so it wins resolution.
        let path = TerminalEnvironment.resolvedPath(from: ["HOME": "/Users/test"])
        let comps = path.components(separatedBy: ":")
        XCTAssertTrue(comps.contains("/Users/test/.ouro-cli/bin"))
        let ouroIdx = comps.firstIndex(of: "/Users/test/.ouro-cli/bin")!
        let homebrewIdx = comps.firstIndex(of: "/opt/homebrew/bin")!
        let usrBinIdx = comps.firstIndex(of: "/usr/bin")!
        XCTAssertLessThan(ouroIdx, homebrewIdx)
        XCTAssertLessThan(ouroIdx, usrBinIdx)
    }

    func testLoginShellPathBecomesThePathBaseWhenCaptured() {
        // The login-shell PATH (captured at launch) must seed the resolved PATH so a
        // version-manager `node` (nvm/asdf) — which lives under a dynamic version dir
        // that no hardcoded list can name — resolves for `ouro` shellouts.
        let saved = TerminalEnvironment.loginShellPath
        defer { TerminalEnvironment.loginShellPath = saved }
        let nvmBin = "/Users/test/.nvm/versions/node/v20.19.5/bin"
        TerminalEnvironment.loginShellPath = "\(nvmBin):/usr/bin"

        let environment = TerminalEnvironment(values: ["HOME": "/Users/test", "PATH": "/seed/bin"]).valuesWithResolvedPath()
        let comps = (environment["PATH"] ?? "").components(separatedBy: ":")

        // The nvm node dir is present and wins over the prior PATH seed + fallbacks.
        XCTAssertTrue(comps.contains(nvmBin))
        let nvmIdx = comps.firstIndex(of: nvmBin)!
        let seedIdx = comps.firstIndex(of: "/seed/bin")!
        let usrBinIdx = comps.firstIndex(of: "/usr/bin")!
        XCTAssertLessThan(nvmIdx, seedIdx)
        XCTAssertLessThan(nvmIdx, usrBinIdx)
    }

    func testLoginShellPathSeedsPathWhenNoExistingPathPresent() {
        // Covers the empty-existing-PATH branch: the login PATH becomes the base
        // outright (no leading colon, no empty component).
        let saved = TerminalEnvironment.loginShellPath
        defer { TerminalEnvironment.loginShellPath = saved }
        let nvmBin = "/Users/test/.nvm/versions/node/v20.19.5/bin"
        TerminalEnvironment.loginShellPath = nvmBin

        let environment = TerminalEnvironment(values: ["HOME": "/Users/test"]).valuesWithResolvedPath()
        let comps = (environment["PATH"] ?? "").components(separatedBy: ":")

        XCTAssertEqual(comps.first, nvmBin)
        XCTAssertFalse(comps.contains(""))
    }

    func testEmptyLoginShellPathIsIgnored() {
        // An empty capture (login shell returned nothing) must not prepend an empty
        // component or otherwise disturb the synthesized fallback PATH.
        let saved = TerminalEnvironment.loginShellPath
        defer { TerminalEnvironment.loginShellPath = saved }
        TerminalEnvironment.loginShellPath = ""

        let environment = TerminalEnvironment(values: ["HOME": "/Users/test", "PATH": "/custom/bin"]).valuesWithResolvedPath()
        let comps = (environment["PATH"] ?? "").components(separatedBy: ":")

        XCTAssertEqual(comps.first, "/custom/bin")
        XCTAssertFalse(comps.contains(""))
        XCTAssertTrue(comps.contains("/Users/test/.ouro-cli/bin"))
    }

    func testNilLoginShellPathLeavesSynthesizedPathUnchanged() {
        // The default (no capture): behaviour is identical to before the
        // login-PATH seed existed.
        let saved = TerminalEnvironment.loginShellPath
        defer { TerminalEnvironment.loginShellPath = saved }
        TerminalEnvironment.loginShellPath = nil

        let environment = TerminalEnvironment(values: ["HOME": "/Users/test", "PATH": "/custom/bin"]).valuesWithResolvedPath()
        let comps = (environment["PATH"] ?? "").components(separatedBy: ":")

        XCTAssertEqual(comps.first, "/custom/bin")
        XCTAssertTrue(comps.contains("/Users/test/.ouro-cli/bin"))
    }

    func testLoginShellCaptureArgumentsAreInteractive() {
        // REGRESSION GUARD for the multi-week "can't get past connect" onboarding bug: the PATH
        // capture MUST run an INTERACTIVE shell. nvm/node/ouro-cli live in `.zshrc`, which a shell
        // sources only when interactive — a non-interactive login shell (`-lc`) silently captures a
        // PATH with no `node`, so every `ouro check` fails and the wizard never confirms the
        // provider. If someone "simplifies" this back to `-lc`, this test fails loudly.
        let args = TerminalEnvironment.loginShellCaptureArguments
        let flags = args.first ?? ""
        XCTAssertTrue(flags.contains("i"), "capture shell must be INTERACTIVE (-i): \(args)")
        XCTAssertTrue(flags.contains("l"), "capture shell should be a login shell (-l): \(args)")
        XCTAssertTrue(flags.contains("c"), "capture shell runs a command (-c): \(args)")
        XCTAssertEqual(args.last, "printf %s \"$PATH\"")
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
