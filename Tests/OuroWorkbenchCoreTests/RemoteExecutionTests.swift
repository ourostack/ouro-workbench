import Darwin
import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteExecutionTests: XCTestCase {
    func testHelperContextUsesExplicitThenEnvironmentValuesAndRejectsUnsafeInputs() throws {
        let invocation = RemoteHelperInvocation(command: .guardian, options: ["config": "/explicit/config", "generation": "explicit-generation"], flags: [], passthrough: [])
        let context = RemoteHelperContext(
            invocation: invocation,
            environment: ["CONFIG": "/environment/config", "OURO_GENERATION": "explicit-generation", "HERDR_SESSION": "explicit-generation"],
            workingDirectory: "/tmp",
            helperPath: "/tmp/helper"
        )

        XCTAssertEqual(try context.value("config", environment: "CONFIG"), "/explicit/config")
        XCTAssertEqual(try context.path("config", environment: "CONFIG"), "/explicit/config")
        XCTAssertEqual(try context.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION"), "explicit-generation")
        let fallback = RemoteHelperContext(invocation: .init(command: .guardian, options: [:], flags: [], passthrough: []), environment: context.environment, workingDirectory: "/tmp", helperPath: "/tmp/helper")
        XCTAssertEqual(try fallback.value("config", environment: "CONFIG"), "/environment/config")
        XCTAssertEqual(try fallback.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION"), "explicit-generation")
        let herdrFallback = RemoteHelperContext(invocation: fallback.invocation, environment: ["HERDR_SESSION": "herdr-generation"], workingDirectory: "/tmp", helperPath: "/tmp/helper")
        XCTAssertEqual(try herdrFallback.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION"), "herdr-generation")
        let emptyOuroFallback = RemoteHelperContext(invocation: fallback.invocation, environment: ["OURO_GENERATION": "", "HERDR_SESSION": "herdr-generation"], workingDirectory: "/tmp", helperPath: "/tmp/helper")
        XCTAssertEqual(try emptyOuroFallback.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION"), "herdr-generation")
        let generationMismatch = RemoteHelperContext(invocation: invocation, environment: ["OURO_GENERATION": "other", "HERDR_SESSION": "explicit-generation"], workingDirectory: "/tmp", helperPath: "/tmp/helper")
        assertRemoteErrorContains("disagree") { _ = try generationMismatch.herdrValue("generation", ouroKey: "OURO_GENERATION", herdrKey: "HERDR_SESSION") }
        let paneMismatch = RemoteHelperContext(invocation: .init(command: .guardian, options: [:], flags: [], passthrough: []), environment: ["OURO_PANE_ID": "desk:p1", "HERDR_PANE_ID": "desk:p2"], workingDirectory: "/tmp", helperPath: "/tmp/helper")
        assertRemoteErrorContains("disagree") { _ = try paneMismatch.herdrValue("pane", ouroKey: "OURO_PANE_ID", herdrKey: "HERDR_PANE_ID") }
        assertRemoteErrorContains("empty or missing") { _ = try fallback.value("missing") }
        assertRemoteErrorContains("absolute path") {
            _ = try RemoteHelperContext(invocation: .init(command: .guardian, options: ["root": "relative"], flags: [], passthrough: []), environment: [:], workingDirectory: "/tmp", helperPath: "/tmp/helper").path("root")
        }
        assertRemoteErrorContains("Herdr context") { _ = try fallback.herdrValue("missing", ouroKey: "NOPE", herdrKey: "ALSO_NOPE") }
    }

    func testHerdrRootLocatorUsesOnlyExplicitNormalizedConfigurationRoots() throws {
        XCTAssertEqual(try RemoteHerdrRootLocator.locate(environment: ["OURO_HERDR_ROOT": "/runtime/herdr"]).path, "/runtime/herdr")
        XCTAssertEqual(try RemoteHerdrRootLocator.locate(environment: ["XDG_CONFIG_HOME": "/runtime/config"]).path, "/runtime/config/herdr")
        XCTAssertEqual(try RemoteHerdrRootLocator.locate(environment: ["HOME": "/Users/example"]).path, "/Users/example/.config/herdr")
        assertRemoteErrorContains("Herdr root") { _ = try RemoteHerdrRootLocator.locate(environment: [:]) }
        assertRemoteErrorContains("exact") { _ = try RemoteHerdrRootLocator.locate(environment: ["OURO_HERDR_ROOT": "/runtime/not-herdr"]) }
        assertRemoteErrorContains("absolute") { _ = try RemoteHerdrRootLocator.locate(environment: ["XDG_CONFIG_HOME": "relative"]) }
    }

    func testSystemRunnerCapturesExactStreamsInputEnvironmentAndWorkingDirectory() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try RemoteSystemRunner(timeout: 2, maximumOutputBytes: 512).run(.init(
            executable: "/bin/sh",
            arguments: ["-c", "read line; printf '%s:%s:%s' \"$line\" \"$TOKEN\" \"$PWD\"; printf err >&2; exit 7"],
            environment: ["TOKEN": "fixture"],
            workingDirectory: root.path,
            standardInput: Data("input\n".utf8)
        ))

        XCTAssertEqual(result.exitCode, 7)
        let physicalRoot = root.path.hasPrefix("/var/") ? "/private\(root.path)" : root.path
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "input:fixture:\(physicalRoot)")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
        XCTAssertEqual(try RemoteSystemRunner().run(.init(executable: "/usr/bin/true")).exitCode, 0)
    }

    func testSystemRunnerClosesItsInputWriterAcrossExecSoChildCanReadToEOF() throws {
        let result = try RemoteSystemRunner(timeout: 0.2).run(.init(
            executable: "/bin/cat",
            standardInput: Data("complete input".utf8)
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, Data("complete input".utf8))
    }

    func testSystemRunnerRejectsUnavailableStartFailureTimeoutAndEitherOutputOverflow() throws {
        assertRemoteErrorContains("unavailable") { _ = try RemoteSystemRunner().run(.init(executable: "relative")) }
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("invalid")
        try Data("not an executable format".utf8).write(to: invalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalid.path)
        assertRemoteErrorContains("could not start") { _ = try RemoteSystemRunner().run(.init(executable: invalid.path)) }
        assertRemoteErrorContains("timed out") {
            _ = try RemoteSystemRunner(timeout: 0.01).run(.init(executable: "/bin/sleep", arguments: ["2"]))
        }
        assertRemoteErrorContains("output exceeded") {
            _ = try RemoteSystemRunner(maximumOutputBytes: 1).run(.init(executable: "/bin/sh", arguments: ["-c", "printf xx"]))
        }
        assertRemoteErrorContains("output exceeded") {
            _ = try RemoteSystemRunner(maximumOutputBytes: 1).run(.init(executable: "/bin/sh", arguments: ["-c", "printf xx >&2"]))
        }
    }

    func testSystemRunnerTimeoutCannotHangOnADescendantHoldingItsPipesOpen() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let descendantPID = root.appendingPathComponent("descendant.pid")
        let started = Date()

        assertRemoteErrorContains("timed out") {
            _ = try RemoteSystemRunner(timeout: 0.5).run(.init(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 5 & child=$!; printf '%s' \"$child\" > \"$1\"; wait", "sh", descendantPID.path]
            ))
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "timeout must not wait for an inherited pipe to close")
        let pid = Int32((try String(contentsOf: descendantPID, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertNotEqual(kill(pid, 0), 0, "the runner must reap the whole dependency process group")
    }

    func testSystemRunnerBoundsEscapedDescendantsHoldingBothInputAndOutputPipes() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let descendantPID = root.appendingPathComponent("escaped.pid")
        let script = "import os,sys,time; os.setsid(); open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(5)"
        let started = Date()
        assertRemoteErrorContains("timed out") {
            _ = try RemoteSystemRunner(timeout: 0.2).run(.init(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/python3 -c \"$1\" \"$2\" & while [ ! -s \"$2\" ]; do :; done; wait", "sh", script, descendantPID.path],
                standardInput: Data(repeating: 0x41, count: 1_048_576)
            ))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        let pid = Int32((try String(contentsOf: descendantPID, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(kill(pid, 0), 0)
        _ = kill(pid, SIGKILL)
    }

    func testSystemRunnerTimeoutCannotBeBypassedByBlockedStandardInput() throws {
        let started = Date()
        assertRemoteErrorContains("timed out") {
            _ = try RemoteSystemRunner(timeout: 0.02).run(.init(
                executable: "/bin/sleep",
                arguments: ["2"],
                standardInput: Data(repeating: 0x41, count: 1_048_576)
            ))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "stdin delivery must remain subordinate to the process timeout")
    }

    func testInputWriterRetriesOnlyInterruptAndWouldBlockErrors() {
        XCTAssertFalse(RemoteInputWriter.shouldRetryWrite(0, error: 0))
        XCTAssertTrue(RemoteInputWriter.shouldRetryWrite(-1, error: EAGAIN))
        XCTAssertTrue(RemoteInputWriter.shouldRetryWrite(-1, error: EINTR))
        XCTAssertFalse(RemoteInputWriter.shouldRetryWrite(-1, error: EBADF))

        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let called = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        let writer = RemoteInputWriter(handle: pipe.fileHandleForWriting) { _, _, _ in
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            called.signal()
            switch calls {
            case 1: return (-1, EINTR)
            case 2: return (-1, EAGAIN)
            default: return (0, 0)
            }
        }
        writer.start(Data([0x41]))
        for _ in 0..<3 { XCTAssertEqual(called.wait(timeout: .now() + 1), .success) }
        writer.finish()
        XCTAssertEqual(calls, 3)
    }

    func testSupervisedProcessFactoryBoundsIdentityFailureCleanupAndPreservesSuccessfulWait() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        var rejectedPID: Int32 = 0
        let started = Date()
        XCTAssertThrowsError(try RemoteSupervisedProcessFactory.spawn(
            .init(executable: "/usr/bin/python3", arguments: ["-c", "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(sys.argv[1], 'w').close(); time.sleep(5)", ready.path], standardInput: Data(repeating: 0x41, count: 1_048_576)),
            identityForPID: { pid, _ in
                rejectedPID = pid
                let deadline = Date().addingTimeInterval(1)
                while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                return nil
            }
        )) { error in
            XCTAssertEqual(error as? RemoteSupervisedSpawnFailure, .afterKernel)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertGreaterThan(rejectedPID, 0)
        XCTAssertNotEqual(kill(rejectedPID, 0), 0)

        let child = try RemoteSupervisedProcessFactory.spawn(
            .init(executable: "/bin/sh", arguments: ["-c", "exit 7"], environment: ["OURO_GENERATION": "ouro-a"]),
            identityForPID: { pid, generation in remoteProcessIdentity(pid: pid, startIdentity: "fixture", executable: "/bin/sh", generation: generation) }
        )
        XCTAssertEqual(child.identity.generation, "ouro-a")
        XCTAssertEqual(try child.wait(), 7)

        var supervisedProcessGroup: Int32 = 0
        let terminated = try RemoteSupervisedProcessFactory.spawn(
            .init(executable: "/bin/sleep", arguments: ["5"]),
            identityForPID: { pid, generation in
                supervisedProcessGroup = getpgid(pid)
                return remoteProcessIdentity(pid: pid, startIdentity: "fixture", executable: "/bin/sleep", generation: generation)
            }
        )
        XCTAssertEqual(supervisedProcessGroup, getpgrp(), "interactive Copilot must inherit the helper's foreground process group")
        terminated.terminate()
        XCTAssertEqual(try terminated.wait(), SIGTERM)

        XCTAssertThrowsError(try RemoteSupervisedProcessFactory.spawn(.init(executable: "/definitely/missing"), identityForPID: { _, _ in nil })) { error in
            XCTAssertEqual(error as? RemoteSupervisedSpawnFailure, .beforeKernel)
        }
    }

    func testInteractiveSignalShieldKeepsSupervisorAliveAndResetsChildSignals() throws {
        let child = try RemoteSupervisedProcessFactory.spawn(
            .init(executable: "/bin/sleep", arguments: ["5"]),
            identityForPID: { pid, generation in remoteProcessIdentity(pid: pid, startIdentity: "fixture", executable: "/bin/sleep", generation: generation) }
        )
        XCTAssertEqual(kill(getpid(), SIGINT), 0, "the supervising helper must ignore the terminal interrupt while ownership is unresolved")
        XCTAssertEqual(kill(child.identity.pid, SIGINT), 0)
        XCTAssertEqual(try child.wait(), SIGINT, "the interactive child must retain the default interrupt disposition")
        XCTAssertEqual(kill(getpid(), SIGQUIT), 0)
        child.finish()
    }

    func testInteractiveSignalShieldFailureRestoresPriorDispositionsAndMapsToPreKernel() {
        XCTAssertThrowsError(try RemoteInteractiveSignalShield.install(failingSignalForTesting: SIGQUIT)) { error in
            XCTAssertTrue(error.localizedDescription.contains("signal shield"))
        }
        XCTAssertThrowsError(try RemoteSupervisedProcessFactory.spawn(.init(executable: "/bin/true"), identityForPID: { _, _ in nil }, failingSignalForTesting: SIGINT)) { error in
            XCTAssertEqual(error as? RemoteSupervisedSpawnFailure, .beforeKernel)
        }
    }

    func testPrivateFileReadsOnlyOwnedRegular0600FilesBelowItsBound() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.json")
        try Data("private".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try RemotePrivateFile.read(path: file.path), Data("private".utf8))
        XCTAssertEqual(try RemotePrivateFile.read(path: file.path, maximumBytes: 7), Data("private".utf8))
        assertRemoteErrorContains("absolute normalized") { _ = try RemotePrivateFile.read(path: "relative") }
        assertRemoteErrorContains("absolute normalized") { _ = try RemotePrivateFile.read(path: root.appendingPathComponent("../private.json").path) }
        assertRemoteErrorContains("unavailable") { _ = try RemotePrivateFile.read(path: root.appendingPathComponent("missing").path) }
        assertRemoteErrorContains("within the byte bound") { _ = try RemotePrivateFile.read(path: file.path, maximumBytes: 6) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        assertRemoteErrorContains("owned 0600") { _ = try RemotePrivateFile.read(path: file.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        assertRemoteErrorContains("unavailable") { _ = try RemotePrivateFile.read(path: link.path) }
        let hardLink = root.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: file, to: hardLink)
        assertRemoteErrorContains("owned 0600") { _ = try RemotePrivateFile.read(path: file.path) }
        try FileManager.default.removeItem(at: hardLink)
        let unsafe = root.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unsafe.path)
        assertRemoteErrorContains("directory is unavailable or unsafe") { _ = try RemotePrivateFile.read(path: unsafe.appendingPathComponent("file").path) }

        assertRemoteErrorContains("could not be read") {
            _ = try RemotePrivateFile.readAll(maximumBytes: 10) { _ in -1 }
        }
        assertRemoteErrorContains("exceeds the byte bound") {
            _ = try RemotePrivateFile.readAll(maximumBytes: 1) { buffer in
                buffer[0] = 0x41
                buffer[1] = 0x42
                return 2
            }
        }
        assertRemoteErrorContains("exceeds the byte bound") {
            _ = try RemotePrivateFile.readAll(maximumBytes: 100_000) { _ in 65_537 }
        }
    }

    func testRegistryLoaderUsesThePrivateFileBoundary() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("profiles.json")
        var object = remoteRegistryObject(profileCount: 1)
        var profiles = object["profiles"] as! [[String: Any]]
        let copilotHome = root.appendingPathComponent("copilot", isDirectory: true)
        let ghConfigDir = root.appendingPathComponent("gh", isDirectory: true)
        let gitConfigParent = root.appendingPathComponent("git", isDirectory: true)
        for directory in [copilotHome, ghConfigDir, gitConfigParent] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        profiles[0]["copilotHome"] = copilotHome.path
        profiles[0]["ghConfigDir"] = ghConfigDir.path
        profiles[0]["gitConfigGlobal"] = gitConfigParent.appendingPathComponent("config").path
        for key in ["copilotExecutable", "ghExecutable", "gitExecutable", "herdrExecutable", "zshExecutable"] {
            profiles[0][key] = "/bin/sh"
        }
        object["profiles"] = profiles
        try remoteJSONData(object).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        XCTAssertEqual(try remoteLoadRegistry(configPath: config.path).profiles.map(\.id), ["personal"])
    }

    func testProcessIdentityReaderRequiresExactPositivePIDMetadataAndExecutable() {
        let expected = RemoteProcessIdentity(pid: 41, startIdentity: "12.34", executable: "/bin/sh", generation: "g1")
        XCTAssertEqual(RemoteProcessIdentityReader.read(pid: 41, generation: "g1", metadata: { _ in (41, 12, 34) }, executablePath: { _ in "/bin/../bin/sh" }), expected)
        XCTAssertNil(RemoteProcessIdentityReader.read(pid: 0, generation: "g", metadata: { _ in (0, 1, 1) }, executablePath: { _ in "/bin/sh" }))
        XCTAssertNil(RemoteProcessIdentityReader.read(pid: 41, generation: "g", metadata: { _ in nil }, executablePath: { _ in "/bin/sh" }))
        XCTAssertNil(RemoteProcessIdentityReader.read(pid: 41, generation: "g", metadata: { _ in (42, 1, 1) }, executablePath: { _ in "/bin/sh" }))
        XCTAssertNil(RemoteProcessIdentityReader.read(pid: 41, generation: "g", metadata: { _ in (41, 1, 1) }, executablePath: { _ in nil }))
        XCTAssertEqual(remoteProcessIdentity(pid: getpid(), generation: "native")?.pid, getpid())
        XCTAssertNil(remoteProcessIdentity(pid: -1, generation: "native"))
        XCTAssertNil(RemoteNativeProcessIdentity.metadata(pid: Int32.max))
        XCTAssertNil(RemoteNativeProcessIdentity.executablePath(pid: Int32.max))
    }

    func testProcessArgumentDecoderAndNativeReaderRejectEveryMalformedBoundary() {
        XCTAssertEqual(RemoteProcessArguments.decode(argumentCount: 2, bytesAfterCount: Array("/bin/sh\0\0-c\0echo hi\0ENV=x\0".utf8)), ["-c", "echo hi"])
        XCTAssertNil(RemoteProcessArguments.decode(argumentCount: 0, bytesAfterCount: []))
        XCTAssertNil(RemoteProcessArguments.decode(argumentCount: 1, bytesAfterCount: Array("unterminated".utf8)))
        XCTAssertNil(RemoteProcessArguments.decode(argumentCount: 2, bytesAfterCount: Array("/bin/sh\0\0only-one\0".utf8)))
        XCTAssertNil(RemoteProcessArguments.decodeSnapshot(argumentCount: 1, bytesAfterCount: Array("/bin/sh\0\0/bin/sh\0UNTERMINATED".utf8)))
        XCTAssertNil(RemoteProcessArguments.decodeSnapshot(argumentCount: 1, bytesAfterCount: Array("/bin/sh\0\0/bin/sh\0MISSING-SEPARATOR\0".utf8)))
        XCTAssertNil(RemoteProcessArguments.decodeSnapshot(argumentCount: 1, bytesAfterCount: Array("/bin/sh\0\0/bin/sh\0=value\0".utf8)))
        XCTAssertNil(RemoteProcessArguments.decodeSnapshot(argumentCount: 1, bytesAfterCount: Array("/bin/sh\0\0/bin/sh\0KEY=one\0KEY=two\0".utf8)))
        XCTAssertNotNil(RemoteProcessArguments.read(pid: getpid()))
        XCTAssertNil(RemoteProcessArguments.read(pid: -1))
        XCTAssertNil(RemoteProcessArguments.read(pid: 1, querySize: { _ in (1, 4) }, queryBytes: { _, _ in XCTFail("unexpected query"); return (0, 4, []) }))
        XCTAssertNil(RemoteProcessArguments.read(pid: 1, querySize: { _ in (0, 3) }, queryBytes: { _, _ in XCTFail("unexpected query"); return (0, 4, []) }))
        XCTAssertNil(RemoteProcessArguments.read(pid: 1, querySize: { _ in (0, 1_048_577) }, queryBytes: { _, _ in XCTFail("unexpected query"); return (0, 4, []) }))
        XCTAssertNil(RemoteProcessArguments.read(pid: 1, querySize: { _ in (0, 4) }, queryBytes: { _, _ in (1, 4, [0, 0, 0, 0]) }))
        XCTAssertNil(RemoteProcessArguments.read(pid: 1, querySize: { _ in (0, 4) }, queryBytes: { _, _ in (0, 3, [0, 0, 0, 0]) }))
        XCTAssertNil(RemoteProcessArguments.read(pid: 1, querySize: { _ in (0, 4) }, queryBytes: { _, _ in (0, 5, [0, 0, 0, 0]) }))
    }

    func testNativeProcessSnapshotReadsExactArgvAndManagedIdentityEnvironment() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.arguments = ["alpha", "beta"]
        process.environment = ["OURO_PROFILE_ID": "personal", "OURO_GENERATION": "g1", "OURO_PANE_ID": "p1"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let snapshot = try XCTUnwrap(RemoteProcessArguments.readSnapshot(pid: process.processIdentifier))

        XCTAssertEqual(snapshot.arguments, ["/usr/bin/yes", "alpha", "beta"])
        XCTAssertEqual(snapshot.environment["OURO_PROFILE_ID"], "personal")
        XCTAssertEqual(snapshot.environment["OURO_GENERATION"], "g1")
        XCTAssertEqual(snapshot.environment["OURO_PANE_ID"], "p1")
    }

    func testNativePIDEnumerationAndHerdrScannerRequireStableExactServerProcesses() throws {
        XCTAssertTrue(try RemoteNativeProcessIDs.all().contains(getpid()))
        XCTAssertEqual(try RemoteNativeProcessIDs.all(estimatedCount: { 2 }, listedPIDs: { capacity in
            XCTAssertEqual(capacity, 66)
            return [1, 2]
        }), [1, 2])
        assertRemoteErrorContains("enumeration failed") { _ = try RemoteNativeProcessIDs.all(estimatedCount: { 0 }, listedPIDs: { _ in [] }) }
        assertRemoteErrorContains("incomplete") { _ = try RemoteNativeProcessIDs.all(estimatedCount: { 1 }, listedPIDs: { capacity in Array(repeating: 1, count: capacity) }) }
        assertRemoteErrorContains("enumeration failed") { _ = try RemoteNativeProcessIDs.validated(estimated: 1, capacity: 65, listed: -1, pids: []) }
        assertRemoteErrorContains("incomplete") { _ = try RemoteNativeProcessIDs.validated(estimated: 1, capacity: 65, listed: 2, pids: [1]) }

        let executable = "/fixtures/bin/herdr"
        var identities: [Int32: [RemoteProcessIdentity?]] = [
            2: [.init(pid: 2, startIdentity: "birth", executable: executable, generation: "process-inventory"), .init(pid: 2, startIdentity: "birth", executable: executable, generation: "process-inventory")],
            3: [.init(pid: 3, startIdentity: "other", executable: "/bin/sh", generation: "process-inventory")]
        ]
        let scanner = RemoteHerdrProcessScanner(
            herdrExecutable: executable,
            listProcessIDs: { [0, 2, 3] },
            processIdentityForPID: { pid, _ in identities[pid]?.removeFirst() ?? nil },
            processArgumentsForPID: { pid in pid == 2 ? [executable, "--session", "any-session", "server"] : ["/bin/sh"] }
        )
        XCTAssertEqual(try scanner.listServerSessions(), ["any-session"])

        let unstable = RemoteHerdrProcessScanner(
            herdrExecutable: executable,
            listProcessIDs: { [2] },
            processIdentityForPID: { _, _ in .init(pid: 2, startIdentity: UUID().uuidString, executable: executable, generation: "process-inventory") },
            processArgumentsForPID: { _ in [executable, "--session", "any-session", "server"] }
        )
        assertRemoteErrorContains("identity changed") { _ = try unstable.listServerSessions() }
        let missingArguments = RemoteHerdrProcessScanner(herdrExecutable: executable, listProcessIDs: { [2] }, processIdentityForPID: { _, _ in .init(pid: 2, startIdentity: "same", executable: executable, generation: "process-inventory") }, processArgumentsForPID: { _ in nil })
        assertRemoteErrorContains("identity changed") { _ = try missingArguments.listServerSessions() }
        let malformed = RemoteHerdrProcessScanner(herdrExecutable: executable, listProcessIDs: { [2] }, processIdentityForPID: { _, _ in .init(pid: 2, startIdentity: "same", executable: executable, generation: "process-inventory") }, processArgumentsForPID: { _ in [executable, "--session", "any-session", "server", "extra"] })
        assertRemoteErrorContains("arguments are not exact") { _ = try malformed.listServerSessions() }

        XCTAssertEqual(try RemoteHerdrProcessScanner(herdrExecutable: "/private/fixtures/no-running-herdr").listServerSessions(), [])
        let ownIdentity = try XCTUnwrap(remoteProcessIdentity(pid: getpid(), generation: "scanner-default"))
        let resolvedOwnExecutable = URL(fileURLWithPath: ownIdentity.executable).resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalOwnIdentity = RemoteProcessIdentity(
            pid: ownIdentity.pid,
            startIdentity: ownIdentity.startIdentity,
            executable: resolvedOwnExecutable,
            generation: ownIdentity.generation
        )
        let defaultArguments = RemoteHerdrProcessScanner(
            herdrExecutable: resolvedOwnExecutable,
            listProcessIDs: { [getpid()] },
            processIdentityForPID: { _, _ in canonicalOwnIdentity }
        )
        XCTAssertEqual(try defaultArguments.listServerSessions(), [])
    }

    func testWaitStatusAndExitStatusClassifyInterruptedUnavailableExitedAndSignaledChildren() throws {
        var calls = 0
        let waited = RemoteChildWaiter.readStatus(pid: 42) { pid, status in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            status.pointee = 7 << 8
            return pid
        }
        XCTAssertEqual(waited, 7 << 8)
        XCTAssertEqual(calls, 2)
        errno = ECHILD
        XCTAssertNil(RemoteChildWaiter.readStatus(pid: 42) { _, _ in -1 })
        XCTAssertEqual(try RemoteSystemRunner.exitCode(waitStatus: 7 << 8), 7)
        XCTAssertEqual(try RemoteSystemRunner.exitCode(waitStatus: SIGTERM), SIGTERM)
        assertRemoteErrorContains("status is unavailable") { _ = try RemoteSystemRunner.exitCode(waitStatus: nil) }
    }

    func testOwnedIsolatedProcessWaitReapsItsProcessGroup() throws {
        let process = try RemoteOwnedProcess.spawn(.init(executable: "/usr/bin/true"), nullOutput: true)
        XCTAssertEqual(try process.waitForExit(), 0)
    }
}
