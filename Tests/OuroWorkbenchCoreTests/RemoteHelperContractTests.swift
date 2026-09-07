import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteHelperContractTests: XCTestCase {
    func testInvocationParsesStrictOptionsAndPreservesPassthroughArguments() throws {
        let invocation = try RemoteHelperInvocation.parse([
            "launch", "--config", "/runtime/profiles.json", "--profile=personal", "--json", "--", "--model", "gpt 5", "a'b"
        ])

        XCTAssertEqual(invocation.command, .launch)
        XCTAssertEqual(try invocation.requiredPath("config"), "/runtime/profiles.json")
        XCTAssertEqual(try invocation.requiredValue("profile"), "personal")
        XCTAssertTrue(invocation.hasFlag("json"))
        XCTAssertEqual(invocation.passthrough, ["--model", "gpt 5", "a'b"])
    }

    func testInvocationRejectsUnknownDuplicateMissingAndUnexpectedArguments() throws {
        for (arguments, expected) in [
            (["unknown"], "unknown command"),
            (["launch", "--profile", "personal", "--profile", "emu"], "duplicate option"),
            (["launch", "--profile"], "missing value"),
            (["launch", "positional"], "unexpected argument"),
            (["launch", "--config", "relative"], "absolute path"),
            (["launch", "--profile", ""], "empty")
        ] {
            assertRemoteErrorContains(expected) {
                let invocation = try RemoteHelperInvocation.parse(arguments)
                if arguments.contains("--config") { _ = try invocation.requiredPath("config") }
                if arguments.contains("--profile") { _ = try invocation.requiredValue("profile") }
            }
        }
        XCTAssertEqual(try RemoteHelperInvocation.parse([]).command, .help)
        XCTAssertEqual(try RemoteHelperInvocation.parse(["--help"]).command, .help)
        XCTAssertEqual(try RemoteHelperInvocation.parse(["--version"]).command, .version)
    }

    func testInvocationRejectsForeignFlagsOptionsAndPassthroughByCommand() {
        for (arguments, expected) in [
            (["dispatch", "--json"], "unknown flag"),
            (["doctor", "--profile", "personal"], "unknown option"),
            (["doctor", "--json=yes"], "unknown option"),
            (["resume", "--", "extra"], "unexpected passthrough"),
            (["help", "--native-refs-remain"], "unknown flag"),
            (["rollback", "--native-refs-remain"], "unknown flag"),
            (["launch", "--bad_key", "value"], "unsafe option")
        ] {
            assertRemoteErrorContains(expected) { _ = try RemoteHelperInvocation.parse(arguments) }
        }
    }

    func testEveryCommandAndSupportedFlagHasAnExplicitShape() throws {
        for command in RemoteHelperInvocation.Command.allCases {
            XCTAssertEqual(try RemoteHelperInvocation.parse([command.rawValue]).command, command)
        }
        XCTAssertTrue(try RemoteHelperInvocation.parse(["doctor", "--json"]).hasFlag("json"))
        XCTAssertFalse(try RemoteHelperInvocation.parse(["doctor"]).hasFlag("json"))
        XCTAssertTrue(try RemoteHelperInvocation.parse(["guardian", "--fresh-sessions"]).hasFlag("fresh-sessions"))
        assertRemoteErrorContains("unknown flag") { _ = try RemoteHelperInvocation.parse(["launch", "--fresh-sessions"]) }
    }

    func testRequiredValuesRejectMissingWhitespaceAndNonNormalizedPaths() {
        let invocation = RemoteHelperInvocation(command: .launch, options: ["profile": "  ", "config": "/tmp/../tmp/config"], flags: [], passthrough: [])
        assertRemoteErrorContains("empty or missing") { _ = try invocation.requiredValue("missing") }
        assertRemoteErrorContains("empty or missing") { _ = try invocation.requiredValue("profile") }
        assertRemoteErrorContains("absolute path") { _ = try invocation.requiredPath("config") }
    }

    func testInvocationRejectsDuplicateFlagUnsafeEmptyAndDashPrefixedValues() {
        for (arguments, expected) in [
            (["doctor", "--json", "--json"], "duplicate option"),
            (["launch", "--=value"], "unsafe option"),
            (["launch", "--profile="], "empty"),
            (["launch", "--profile", "--bad"], "missing value")
        ] {
            assertRemoteErrorContains(expected) {
                let invocation = try RemoteHelperInvocation.parse(arguments)
                if arguments.contains("--profile=") { _ = try invocation.requiredValue("profile") }
            }
        }
    }

    func testPackageDeclaresStandaloneRemoteHelperProductAndTarget() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains(".executable(name: \"OuroWorkbenchRemote\", targets: [\"OuroWorkbenchRemote\"])"))
        XCTAssertTrue(package.contains(".executableTarget(\n            name: \"OuroWorkbenchRemote\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Sources/OuroWorkbenchRemote/main.swift").path))
    }

    func testPackageCommandAcceptsOnlyItsExplicitRequiredValues() throws {
        let invocation = try RemoteHelperInvocation.parse([
            "package", "--output", "/tmp/artifact", "--revision", "d57d344fc801fc005769223c13def91a4df01c25",
            "--expected-helper-sha256", String(repeating: "a", count: 64)
        ])
        XCTAssertEqual(try invocation.requiredPath("output"), "/tmp/artifact")
        XCTAssertEqual(try invocation.requiredValue("revision"), "d57d344fc801fc005769223c13def91a4df01c25")
        XCTAssertEqual(try invocation.requiredValue("expected-helper-sha256"), String(repeating: "a", count: 64))
        assertRemoteErrorContains("unknown option") {
            _ = try RemoteHelperInvocation.parse(["package", "--runtime-root", "/tmp/runtime"])
        }
    }

    func testReconcileCommandTargetsOneAttemptAndExposesNoRetryOrStateSurgeryControls() throws {
        let invocation = try RemoteHelperInvocation.parse([
            "reconcile",
            "--config", "/runtime/profiles.json",
            "--root", "/runtime/herdr",
            "--ledger", "/runtime/ledger",
            "--attempt", "run-123"
        ])

        XCTAssertEqual(invocation.command, .reconcile)
        XCTAssertEqual(try invocation.requiredPath("config"), "/runtime/profiles.json")
        XCTAssertEqual(try invocation.requiredPath("root"), "/runtime/herdr")
        XCTAssertEqual(try invocation.requiredPath("ledger"), "/runtime/ledger")
        XCTAssertEqual(try invocation.requiredValue("attempt"), "run-123")
        for (arguments, expected) in [
            (["reconcile", "--attempt", "run-123", "--resolution", "retry"], "unknown option"),
            (["reconcile", "--attempt", "run-123", "--phase", "exited"], "unknown option"),
            (["reconcile", "--attempt", "run-123", "--", "retry"], "unexpected passthrough")
        ] {
            assertRemoteErrorContains(expected) { _ = try RemoteHelperInvocation.parse(arguments) }
        }
    }

    func testSnapshotCommandsSeparateRoutineCaptureFromGenerationBoundEmptyAcknowledgement() throws {
        let common = [
            "--config", "/runtime/profiles.json",
            "--root", "/runtime/herdr",
            "--ledger", "/runtime/ledger",
            "--session-map", "/runtime/session-map.json",
            "--shim-directory", "/runtime/shims",
            "--zdotdir", "/runtime/zsh"
        ]
        let snapshot = try RemoteHelperInvocation.parse(["snapshot"] + common)
        XCTAssertEqual(snapshot.command, .snapshot)
        XCTAssertNil(snapshot.options["generation"])
        let empty = try RemoteHelperInvocation.parse(["acknowledge-empty"] + common + ["--generation", "ouro-live"])
        XCTAssertEqual(empty.command, .acknowledgeEmpty)
        XCTAssertEqual(try empty.requiredValue("generation"), "ouro-live")

        assertRemoteErrorContains("unknown option") {
            _ = try RemoteHelperInvocation.parse(["snapshot"] + common + ["--generation", "ouro-live"])
        }
        assertRemoteErrorContains("unknown option") {
            _ = try RemoteHelperInvocation.parse(["acknowledge-empty"] + common + ["--acknowledged-empty", "true"])
        }
        assertRemoteErrorContains("unexpected passthrough") {
            _ = try RemoteHelperInvocation.parse(["acknowledge-empty"] + common + ["--generation", "ouro-live", "--", "force"])
        }
    }
}
