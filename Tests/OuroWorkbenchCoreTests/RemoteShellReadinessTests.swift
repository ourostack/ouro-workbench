import Darwin
import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteShellReadinessTests: XCTestCase {
    func testWrapperHandshakeRequiresLiveExactZshZDOTDIRAndFinalAbsoluteFunction() throws {
        let root = try remoteTemporaryDirectory("shell-ready")
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = root.appendingPathComponent("session-map.json")
        let zsh = URL(fileURLWithPath: "/bin/zsh").resolvingSymlinksInPath().standardizedFileURL.path
        let identity = remoteProcessIdentity(pid: 123, executable: zsh, generation: "ouro-a")
        let body = RemoteShellReadiness.copilotFunctionBody(helperPath: "/runtime/helper", configPath: "/runtime/config.json", sessionMapPath: mapURL.path)
        let environment = ["HERDR_SESSION": "ouro-a", "HERDR_PANE_ID": "desk:p1", "ZDOTDIR": "/runtime/zdotdir"]
        let record: (String, String, RemoteProcessIdentity?) throws -> Void = { functionBody, zdotdir, liveIdentity in
            try RemoteShellReadiness.record(
                sessionMapURL: mapURL,
                generation: "ouro-a",
                paneID: "desk:p1",
                shellPID: 123,
                zshExecutable: "/bin/zsh",
                zdotdir: zdotdir,
                helperPath: "/runtime/helper",
                configPath: "/runtime/config.json",
                functionBody: functionBody,
                environment: environment,
                parentPID: 123,
                processIdentityForPID: { _, _ in liveIdentity }
            )
        }

        XCTAssertFalse(RemoteShellReadiness.isReady(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "/bin/zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", processIdentityForPID: { _, _ in identity }), "an early shell exit leaves no handshake")
        XCTAssertThrowsError(try record(body, "/runtime/zdotdir", remoteProcessIdentity(pid: 123, executable: "/bin/bash", generation: "ouro-a")), "bash is not the configured zsh")
        XCTAssertThrowsError(try record("\tdispatch through shadowed copilot", "/runtime/zdotdir", identity), "a shadowed function body is not exact")
        XCTAssertThrowsError(try record("\treadonly legacy copilot", "/runtime/zdotdir", identity), "a readonly legacy function cannot masquerade as the final dispatcher")
        XCTAssertThrowsError(try record(body, "/runtime/other", identity), "the Ouro ZDOTDIR must be exact")

        try record(body, "/runtime/zdotdir", identity)
        XCTAssertTrue(RemoteShellReadiness.isReady(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "/bin/zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", processIdentityForPID: { _, _ in identity }))
        XCTAssertFalse(RemoteShellReadiness.isReady(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "/bin/zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", processIdentityForPID: { _, _ in remoteProcessIdentity(pid: 123, startIdentity: "reused", executable: zsh, generation: "ouro-a") }), "a stale marker cannot bless a reused pid")
        XCTAssertEqual(mode(at: root.appendingPathComponent("wrapper-ready")), 0o700)
        XCTAssertEqual(mode(at: root.appendingPathComponent("wrapper-ready/ouro-a")), 0o700)
        XCTAssertEqual(mode(at: root.appendingPathComponent("wrapper-ready/ouro-a/desk:p1.json")), 0o600)

        let markerURL = root.appendingPathComponent("wrapper-ready/ouro-a/desk:p1.json")
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
        malformed["schemaVersion"] = "one"
        try remoteJSONData(malformed).write(to: markerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        XCTAssertFalse(RemoteShellReadiness.isReady(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "/bin/zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", processIdentityForPID: { _, _ in identity }))
    }

    func testWrapperHandshakeRejectsDisagreeingAmbientIdentityAndCallerPID() throws {
        let root = try remoteTemporaryDirectory("shell-context")
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = root.appendingPathComponent("session-map.json")
        let zsh = URL(fileURLWithPath: "/bin/zsh").resolvingSymlinksInPath().standardizedFileURL.path
        let identity = remoteProcessIdentity(pid: 123, executable: zsh, generation: "ouro-a")
        let body = RemoteShellReadiness.copilotFunctionBody(helperPath: "/runtime/helper", configPath: "/runtime/config.json", sessionMapPath: mapURL.path)
        let base = ["HERDR_SESSION": "ouro-a", "HERDR_PANE_ID": "desk:p1", "ZDOTDIR": "/runtime/zdotdir"]
        for environment in [
            ["HERDR_PANE_ID": "desk:p1", "ZDOTDIR": "/runtime/zdotdir"],
            base.merging(["OURO_GENERATION": "ouro-other"]) { _, new in new },
            base.merging(["OURO_PANE_ID": "desk:p2"]) { _, new in new },
            base.merging(["ZDOTDIR": "/runtime/other"]) { _, new in new }
        ] {
            XCTAssertThrowsError(try RemoteShellReadiness.record(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "/bin/zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", functionBody: body, environment: environment, parentPID: 123, processIdentityForPID: { _, _ in identity }))
        }
        XCTAssertThrowsError(try RemoteShellReadiness.record(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "/bin/zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", functionBody: body, environment: base, parentPID: 124, processIdentityForPID: { _, _ in identity }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("wrapper-ready").path))
    }

    func testWrapperHandshakeRejectsUnsafePathsIdentifiersAndReadinessDirectories() throws {
        let root = try remoteTemporaryDirectory("shell-unsafe")
        defer { try? FileManager.default.removeItem(at: root) }
        let mapURL = root.appendingPathComponent("session-map.json")
        let zsh = URL(fileURLWithPath: "/bin/zsh").resolvingSymlinksInPath().standardizedFileURL.path
        let identity = remoteProcessIdentity(pid: 123, executable: zsh, generation: "ouro-a")
        let body = RemoteShellReadiness.copilotFunctionBody(helperPath: "/runtime/helper", configPath: "/runtime/config.json", sessionMapPath: mapURL.path)
        let environment = ["HERDR_SESSION": "ouro-a", "HERDR_PANE_ID": "desk:p1", "ZDOTDIR": "/runtime/zdotdir"]

        assertRemoteErrorContains("absolute normalized") {
            try RemoteShellReadiness.record(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "relative-zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", functionBody: body, environment: environment, parentPID: 123, processIdentityForPID: { _, _ in identity })
        }
        for (generation, paneID, shellPID) in [("bad", "desk:p1", Int32(123)), ("ouro-a", "/bad", Int32(123)), ("ouro-a", "desk:p1", Int32(0))] {
            XCTAssertFalse(RemoteShellReadiness.isReady(sessionMapURL: mapURL, generation: generation, paneID: paneID, shellPID: shellPID, zshExecutable: zsh, zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json"))
        }
        XCTAssertFalse(RemoteShellReadiness.isReady(sessionMapURL: mapURL, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: "relative-zsh", zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json"))

        let insecureRoot = root.appendingPathComponent("insecure", isDirectory: true)
        try FileManager.default.createDirectory(at: insecureRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: insecureRoot.path)
        assertRemoteErrorContains("0700") {
            try RemoteShellReadiness.record(sessionMapURL: insecureRoot.appendingPathComponent("session-map.json"), generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: zsh, zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", functionBody: RemoteShellReadiness.copilotFunctionBody(helperPath: "/runtime/helper", configPath: "/runtime/config.json", sessionMapPath: insecureRoot.appendingPathComponent("session-map.json").path), environment: environment, parentPID: 123, processIdentityForPID: { _, _ in identity })
        }

        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        assertRemoteErrorContains("unavailable") {
            let loopMap = loop.appendingPathComponent("nested/session-map.json")
            try RemoteShellReadiness.record(sessionMapURL: loopMap, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: zsh, zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", functionBody: RemoteShellReadiness.copilotFunctionBody(helperPath: "/runtime/helper", configPath: "/runtime/config.json", sessionMapPath: loopMap.path), environment: environment, parentPID: 123, processIdentityForPID: { _, _ in identity })
        }

        let unwritable = root.appendingPathComponent("unwritable", isDirectory: true)
        try FileManager.default.createDirectory(at: unwritable, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritable.path) }
        assertRemoteErrorContains("unavailable") {
            let deniedMap = unwritable.appendingPathComponent("child/session-map.json")
            try RemoteShellReadiness.record(sessionMapURL: deniedMap, generation: "ouro-a", paneID: "desk:p1", shellPID: 123, zshExecutable: zsh, zdotdir: "/runtime/zdotdir", helperPath: "/runtime/helper", configPath: "/runtime/config.json", functionBody: RemoteShellReadiness.copilotFunctionBody(helperPath: "/runtime/helper", configPath: "/runtime/config.json", sessionMapPath: deniedMap.path), environment: environment, parentPID: 123, processIdentityForPID: { _, _ in identity })
        }
    }

    private func mode(at url: URL) -> mode_t {
        var value = stat()
        XCTAssertEqual(lstat(url.path, &value), 0)
        return value.st_mode & mode_t(0o777)
    }
}
