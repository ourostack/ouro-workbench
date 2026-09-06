import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class RemoteOperationsTests: XCTestCase {
    func testDoctorReportsEveryStateSourceFreshnessAndRedactsSecrets() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let checks = RemoteHealthState.allCases.enumerated().map { index, state in
            RemoteHealthCheck(
                name: "check-\(index)",
                source: "fixture-source",
                observedAt: Date(timeIntervalSince1970: 1_999),
                state: state,
                detail: index == 0 ? "credential=fixture-secret" : "safe detail"
            )
        }
        let report = RemoteDoctor.report(checks: checks, now: now, staleAfter: 60, redacting: ["fixture-secret"])
        let data = try report.jsonData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(report.checks.map(\.state), RemoteHealthState.allCases)
        XCTAssertTrue(report.checks.allSatisfy { $0.source == "fixture-source" && $0.freshness == .fresh })
        XCTAssertFalse(text.contains("fixture-secret"))
        XCTAssertTrue(text.contains("[redacted]"))
        XCTAssertEqual(data, try report.jsonData())
    }

    func testDoctorConvertsStaleHealthyToUnknownAndPreservesUnavailableTruth() {
        let now = Date(timeIntervalSince1970: 2_000)
        let report = RemoteDoctor.report(
            checks: [
                .init(name: "old", source: "file", observedAt: Date(timeIntervalSince1970: 1_000), state: .healthy, detail: "was fine"),
                .init(name: "missing", source: "socket", observedAt: nil, state: .unavailable, detail: "not reachable")
            ],
            now: now,
            staleAfter: 60,
            redacting: []
        )

        XCTAssertEqual(report.checks[0].state, .unknown)
        XCTAssertEqual(report.checks[0].freshness, .stale)
        XCTAssertEqual(report.checks[1].state, .unavailable)
        XCTAssertEqual(report.checks[1].freshness, .unknown)
    }

    func testDoctorRedactsEveryPublishedStringAndFreshnessBoundaryIsInclusive() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let report = RemoteDoctor.report(
            checks: [
                .init(name: "fixture-secret-name", source: "fixture-secret-source", observedAt: Date(timeIntervalSince1970: 1_940), state: .healthy, detail: "fixture-secret-detail"),
                .init(name: "future", source: "clock", observedAt: Date(timeIntervalSince1970: 2_001), state: .degraded, detail: "safe")
            ],
            now: now,
            staleAfter: 60,
            redacting: ["", "fixture-secret"]
        )

        XCTAssertEqual(report.checks.map(\.freshness), [.fresh, .fresh])
        XCTAssertEqual(report.checks.map(\.state), [.healthy, .degraded])
        XCTAssertFalse(String(decoding: try report.jsonData(), as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(report.checks[0].name, "[redacted]-name")
        XCTAssertEqual(report.checks[0].source, "[redacted]-source")
    }

    func testObserverWritesOnlyBoundedMetricsAndCannotInvokeRuntimeMutation() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var writes: [URL] = []
        let observer = RemoteObserver(rootURL: root, maximumBytes: 512, writer: { data, url in
            writes.append(url)
            try data.write(to: url, options: .atomic)
        })
        let checks = [RemoteHealthCheck(name: "herdr", source: "status", observedAt: Date(timeIntervalSince1970: 10), state: .healthy, detail: "running")]

        let url = try observer.record(checks: checks, observedAt: Date(timeIntervalSince1970: 11))

        XCTAssertEqual(writes, [url])
        XCTAssertTrue(url.path.hasSuffix("observations/latest.json"))
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 512)
        XCTAssertFalse(String(data: try Data(contentsOf: url), encoding: .utf8)!.contains("start"))

        let oversized = [RemoteHealthCheck(name: "large", source: "fixture", observedAt: nil, state: .degraded, detail: String(repeating: "x", count: 1_000))]
        assertRemoteErrorContains("observation exceeds") {
            _ = try observer.record(checks: oversized, observedAt: Date())
        }
    }

    func testObserverPreservesPriorMetricsWhenAtomicWriteFails() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let latest = root.appendingPathComponent("observations/latest.json")
        try FileManager.default.createDirectory(at: latest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prior".utf8).write(to: latest)
        let observer = RemoteObserver(rootURL: root, writer: { _, _ in throw RemoteFixtureError.expected })

        assertRemoteErrorContains("observation write failed") {
            _ = try observer.record(
                checks: [.init(name: "herdr", source: "status", observedAt: nil, state: .unknown, detail: "unknown")],
                observedAt: Date()
            )
        }
        XCTAssertEqual(try Data(contentsOf: latest), Data("prior".utf8))
    }

    func testObserverCreatesPrivateDirectoriesAndRedactsBeforeWriting() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let observer = RemoteObserver(rootURL: root)

        let url = try observer.record(
            checks: [.init(name: "api", source: "fixture-secret-source", observedAt: nil, state: .unknown, detail: "token=fixture-secret")],
            observedAt: Date(timeIntervalSince1970: 12),
            redacting: ["fixture-secret"]
        )

        XCTAssertEqual(try permissions(at: root), 0o700)
        XCTAssertEqual(try permissions(at: url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: url), 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fixture-secret"))
    }

    func testObserverRejectsUnsafeRootsTargetsAndBoundsBeforeWriting() throws {
        let fixture = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        assertRemoteErrorContains("positive byte bound") {
            _ = try RemoteObserver(rootURL: fixture, maximumBytes: 0).record(checks: [], observedAt: Date())
        }

        let rootFile = fixture.appendingPathComponent("root-file")
        try Data().write(to: rootFile)
        assertRemoteErrorContains("observer root") {
            _ = try RemoteObserver(rootURL: rootFile).record(checks: [], observedAt: Date())
        }

        let realRoot = fixture.appendingPathComponent("real-root")
        let linkedRoot = fixture.appendingPathComponent("linked-root")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        assertRemoteErrorContains("observer root") {
            _ = try RemoteObserver(rootURL: linkedRoot).record(checks: [], observedAt: Date())
        }

        let targetRoot = fixture.appendingPathComponent("target-root")
        let observations = targetRoot.appendingPathComponent("observations")
        try FileManager.default.createDirectory(at: observations, withIntermediateDirectories: true)
        let outside = fixture.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: observations.appendingPathComponent("latest.json"), withDestinationURL: outside)
        assertRemoteErrorContains("observation target") {
            _ = try RemoteObserver(rootURL: targetRoot).record(checks: [], observedAt: Date())
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testObserverValidatesWhatItsWriterActuallyCreated() throws {
        let fixture = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let missing = RemoteObserver(rootURL: fixture.appendingPathComponent("missing"), writer: { _, _ in })
        assertRemoteErrorContains("observation target is missing") {
            _ = try missing.record(checks: [], observedAt: Date())
        }

        let oversized = RemoteObserver(rootURL: fixture.appendingPathComponent("oversized"), maximumBytes: 128, writer: { _, url in
            try Data(repeating: 1, count: 129).write(to: url)
        })
        assertRemoteErrorContains("written observation exceeds") {
            _ = try oversized.record(checks: [], observedAt: Date())
        }

        let directory = RemoteObserver(rootURL: fixture.appendingPathComponent("directory"), writer: { _, url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        })
        assertRemoteErrorContains("regular file") {
            _ = try directory.record(checks: [], observedAt: Date())
        }

        let fifoRoot = fixture.appendingPathComponent("fifo")
        let fifoDirectory = fifoRoot.appendingPathComponent("observations")
        try FileManager.default.createDirectory(at: fifoDirectory, withIntermediateDirectories: true)
        let fifo = fifoDirectory.appendingPathComponent("latest.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        assertRemoteErrorContains("regular file") {
            _ = try RemoteObserver(rootURL: fifoRoot).record(checks: [], observedAt: Date())
        }
    }

    func testObserverTranslatesInspectionCreationAndPermissionFailures() throws {
        let fixture = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let hiddenParent = fixture.appendingPathComponent("hidden")
        try FileManager.default.createDirectory(at: hiddenParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hiddenParent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hiddenParent.path) }
        assertRemoteErrorContains("could not be inspected") {
            _ = try RemoteObserver(rootURL: hiddenParent.appendingPathComponent("child")).record(checks: [], observedAt: Date())
        }

        let readOnlyParent = fixture.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: readOnlyParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyParent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyParent.path) }
        assertRemoteErrorContains("could not be created") {
            _ = try RemoteObserver(rootURL: readOnlyParent.appendingPathComponent("child")).record(checks: [], observedAt: Date())
        }

        let immutableRoot = fixture.appendingPathComponent("immutable")
        try FileManager.default.createDirectory(at: immutableRoot, withIntermediateDirectories: true)
        XCTAssertEqual(chflags(immutableRoot.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(immutableRoot.path, 0) }
        assertRemoteErrorContains("permissions could not be secured") {
            _ = try RemoteObserver(rootURL: immutableRoot).record(checks: [], observedAt: Date())
        }
    }

    func testArtifactVerifierAndInstallerCreateChecksummedVersionedRuntime() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        var checkpoints: [RemoteInstallCheckpoint] = []

        let provenance = try installer.install(
            artifactRoot: fixture.artifactRoot,
            expectedRevision: fixture.revision,
            checkpoint: { checkpoints.append($0) }
        )

        XCTAssertEqual(checkpoints, [.verified, .copied, .promoted])
        XCTAssertEqual(provenance.revision, fixture.revision)
        XCTAssertTrue(provenance.entries.allSatisfy { $0.ownership == .created })
        XCTAssertEqual(try String(contentsOf: fixture.currentPointerURL, encoding: .utf8), fixture.revision + "\n")
        XCTAssertEqual(try permissions(at: fixture.runtimeRoot), 0o700)
        XCTAssertEqual(try permissions(at: fixture.runtimeRoot.appendingPathComponent("versions")), 0o700)
        XCTAssertEqual(try permissions(at: fixture.versionRoot), 0o700)
        XCTAssertEqual(try permissions(at: fixture.versionRoot.appendingPathComponent("install-manifest.json")), 0o600)
        XCTAssertEqual(try permissions(at: fixture.currentPointerURL), 0o600)
        for file in fixture.manifest.files {
            let installed = fixture.versionRoot.appendingPathComponent(file.relativePath)
            XCTAssertEqual(RemoteArtifactVerifier.sha256(try Data(contentsOf: installed)), file.sha256)
            XCTAssertEqual(try permissions(at: installed), file.mode)
        }
        XCTAssertEqual(try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision), provenance)
    }

    func testInstallerRejectsArtifactTreePermissionDriftBeforeRuntimeMutation() throws {
        for target in ["root", "manifest", "directory"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            let url = target == "root"
                ? fixture.artifactRoot
                : target == "manifest"
                    ? fixture.manifestURL
                    : fixture.artifactRoot.appendingPathComponent("bin")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

            assertRemoteErrorContains("permissions") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(
                    artifactRoot: fixture.artifactRoot,
                    expectedRevision: fixture.revision
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeRoot.path))
        }
    }

    func testArtifactManifestIsStrictBoundedAndRequiresSafeCanonicalEntries() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("unknown file key", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["surprise"] = true
                object["files"] = files
            }),
            ("duplicate", { object in
                var files = object["files"] as! [[String: Any]]
                files.append(files[0])
                object["files"] = files
            }),
            ("empty", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = ""
                object["files"] = files
            }),
            ("dot component", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "bin/./OuroWorkbenchRemote"
                object["files"] = files
            }),
            ("empty component", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "bin//OuroWorkbenchRemote"
                object["files"] = files
            }),
            ("absolute", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "/bin/tool"
                object["files"] = files
            }),
            ("null byte", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["relativePath"] = "bin/\0tool"
                object["files"] = files
            }),
            ("hash", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["sha256"] = String(repeating: "A", count: 64)
                object["files"] = files
            }),
            ("mode", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["mode"] = 0o777
                object["files"] = files
            })
        ]
        for (expected, mutate) in mutations {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            var object = try fixture.manifestObject()
            mutate(&object)
            try remoteJSONData(object).write(to: fixture.manifestURL)
            assertRemoteErrorContains(expected) {
                _ = try RemoteArtifactVerifier.load(rootURL: fixture.artifactRoot)
            }
        }

        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        var oversized = try fixture.manifestObject()
        oversized["padding"] = String(repeating: "x", count: RemoteArtifactVerifier.maximumManifestBytes)
        try remoteJSONData(oversized).write(to: fixture.manifestURL)
        assertRemoteErrorContains("byte bound") {
            _ = try RemoteArtifactVerifier.load(rootURL: fixture.artifactRoot)
        }
    }

    func testArtifactManifestRequiresOneExactExecutableHelperAndPortableUniquePaths() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("exactly one executable helper", { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["mode"] = 0o644
                object["files"] = files
            }),
            ("exactly one executable helper", { object in
                var files = object["files"] as! [[String: Any]]
                files[1]["mode"] = 0o755
                object["files"] = files
            }),
            ("portable path collision", { object in
                var files = object["files"] as! [[String: Any]]
                var collision = files[1]
                collision["relativePath"] = "share/Profiles.Example.JSON"
                files.append(collision)
                object["files"] = files
            }),
            ("portable path collision", { object in
                var files = object["files"] as! [[String: Any]]
                var composed = files[1]
                composed["relativePath"] = "share/caf\u{00e9}.json"
                var decomposed = files[1]
                decomposed["relativePath"] = "share/cafe\u{0301}.json"
                files.append(contentsOf: [composed, decomposed])
                object["files"] = files
            })
        ]

        for (expected, mutate) in mutations {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            var object = try fixture.manifestObject()
            mutate(&object)
            try remoteJSONData(object).write(to: fixture.manifestURL)
            assertRemoteErrorContains(expected) {
                _ = try RemoteArtifactVerifier.load(rootURL: fixture.artifactRoot)
            }
        }
    }

    func testArtifactManifestRejectsEachInvalidIdentityAndFieldShape() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("invalid fields", { $0["files"] = ["not-an-object"] }),
            ("invalid fields", { $0["schemaVersion"] = "one" }),
            ("identity", { $0["schemaVersion"] = 2 }),
            ("identity", { $0["revision"] = String(repeating: "g", count: 40) }),
            ("identity", { $0["files"] = [] })
        ]
        for (expected, mutate) in mutations {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            var object = try fixture.manifestObject()
            mutate(&object)
            try remoteJSONData(object).write(to: fixture.manifestURL)
            assertRemoteErrorContains(expected) {
                _ = try RemoteArtifactVerifier.load(rootURL: fixture.artifactRoot)
            }
        }
    }

    func testArtifactVerifierRejectsMissingInvalidAndUnsafeManifestFiles() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        assertRemoteErrorContains("manifest is missing") {
            _ = try RemoteArtifactVerifier.load(rootURL: root.appendingPathComponent("missing"))
        }
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        assertRemoteErrorContains("manifest is missing") {
            _ = try RemoteArtifactVerifier.load(rootURL: empty)
        }

        let invalidRoot = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: invalidRoot.appendingPathComponent("manifest.json"))
        assertRemoteErrorContains("invalid JSON") {
            _ = try RemoteArtifactVerifier.load(rootURL: invalidRoot)
        }

        let arrayRoot = root.appendingPathComponent("array")
        try FileManager.default.createDirectory(at: arrayRoot, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: arrayRoot.appendingPathComponent("manifest.json"))
        assertRemoteErrorContains("top level") {
            _ = try RemoteArtifactVerifier.load(rootURL: arrayRoot)
        }

        let target = root.appendingPathComponent("manifest-target")
        try Data("{}".utf8).write(to: target)
        let linkedRoot = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent("manifest.json"), withDestinationURL: target)
        assertRemoteErrorContains("regular file") {
            _ = try RemoteArtifactVerifier.load(rootURL: linkedRoot)
        }

        let hardLinkedRoot = root.appendingPathComponent("hard-linked")
        try FileManager.default.createDirectory(at: hardLinkedRoot, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: target, to: hardLinkedRoot.appendingPathComponent("manifest.json"))
        assertRemoteErrorContains("multiple links") {
            _ = try RemoteArtifactVerifier.load(rootURL: hardLinkedRoot)
        }

        let realArtifactRoot = root.appendingPathComponent("real-artifact")
        let linkedArtifactRoot = root.appendingPathComponent("linked-artifact")
        try FileManager.default.createDirectory(at: realArtifactRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedArtifactRoot, withDestinationURL: realArtifactRoot)
        assertRemoteErrorContains("artifact root") {
            _ = try RemoteArtifactVerifier.load(rootURL: linkedArtifactRoot)
        }
    }

    func testInstallerRejectsSymlinkedOrHardLinkedArtifactContentAndRuntimeRoots() throws {
        for kind in ["symlink", "hardlink"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            let binary = fixture.artifactRoot.appendingPathComponent("bin/OuroWorkbenchRemote")
            let original = fixture.root.appendingPathComponent("original")
            try FileManager.default.moveItem(at: binary, to: original)
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: original)
            } else {
                try FileManager.default.linkItem(at: original, to: binary)
            }
            assertRemoteErrorContains(kind == "symlink" ? "symbolic link" : "multiple links") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentPointerURL.path))
        }

        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let realRuntime = fixture.root.appendingPathComponent("real-runtime")
        try FileManager.default.createDirectory(at: realRuntime, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.runtimeRoot, withDestinationURL: realRuntime)
        assertRemoteErrorContains("runtime root") {
            _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
        }
    }

    func testInstallerRejectsMissingUnreadableAndSymlinkedArtifactDirectoriesBeforeRuntimeMutation() throws {
        for failure in ["missing", "unreadable", "directory-symlink"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            if failure == "missing" {
                try FileManager.default.removeItem(at: fixture.artifactRoot.appendingPathComponent("share/profiles.example.json"))
            } else if failure == "unreadable" {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o000],
                    ofItemAtPath: fixture.artifactRoot.appendingPathComponent("share/profiles.example.json").path
                )
            } else {
                let share = fixture.artifactRoot.appendingPathComponent("share")
                let realShare = fixture.root.appendingPathComponent("real-share")
                try FileManager.default.moveItem(at: share, to: realShare)
                try FileManager.default.createSymbolicLink(at: share, withDestinationURL: realShare)
            }
            assertRemoteErrorContains(failure == "unreadable" ? "could not be read" : "artifact") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtimeRoot.path))
        }
    }

    func testInstallRejectsUnsafeExistingRuntimeVersionAndPointer() throws {
        let versionFile = try ArtifactFixture()
        defer { versionFile.remove() }
        try FileManager.default.createDirectory(at: versionFile.runtimeRoot.appendingPathComponent("versions"), withIntermediateDirectories: true)
        try Data().write(to: versionFile.versionRoot)
        assertRemoteErrorContains("runtime version") {
            _ = try RemoteRuntimeInstaller(rootURL: versionFile.runtimeRoot).install(artifactRoot: versionFile.artifactRoot, expectedRevision: versionFile.revision)
        }

        for pointerKind in ["corrupt", "symlink"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.runtimeRoot, withIntermediateDirectories: true)
            if pointerKind == "corrupt" {
                try Data("not-a-revision".utf8).write(to: fixture.currentPointerURL)
            } else {
                let outside = fixture.root.appendingPathComponent("pointer-target")
                try Data(String(repeating: "a", count: 40).utf8).write(to: outside)
                try FileManager.default.createSymbolicLink(at: fixture.currentPointerURL, withDestinationURL: outside)
            }
            assertRemoteErrorContains("runtime pointer") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
        }
    }

    func testArtifactInstallRejectsRevisionHashTraversalUnknownKeyAndChangedAdoptedFileBeforePromotion() throws {
        for failure in ["revision", "hash", "traversal", "unknown", "adopted"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            if failure == "hash" {
                try Data("tampered".utf8).write(to: fixture.artifactRoot.appendingPathComponent("bin/OuroWorkbenchRemote"))
            } else if failure == "traversal" || failure == "unknown" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL)) as? [String: Any])
                if failure == "traversal" {
                    var files = try XCTUnwrap(object["files"] as? [[String: Any]])
                    files[0]["relativePath"] = "../escape"
                    object["files"] = files
                } else {
                    object["surprise"] = true
                }
                try remoteJSONData(object).write(to: fixture.manifestURL)
            } else if failure == "adopted" {
                try FileManager.default.createDirectory(at: fixture.versionRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
                try Data("different".utf8).write(to: fixture.versionRoot.appendingPathComponent("bin/OuroWorkbenchRemote"))
            }
            let expected = failure == "revision" ? "different" : fixture.revision
            assertRemoteErrorContains(failure == "unknown" ? "unknown artifact key" : "artifact") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(artifactRoot: fixture.artifactRoot, expectedRevision: expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentPointerURL.path))
        }
    }

    func testInterruptedInstallKeepsPriorPointerAndRollbackRetainsActiveThenRemovesInactiveCreatedFiles() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.runtimeRoot, withIntermediateDirectories: true)
        let priorRevision = String(repeating: "a", count: 40)
        try Data("\(priorRevision)\n".utf8).write(to: fixture.currentPointerURL)
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)

        assertRemoteErrorContains("installation interrupted") {
            _ = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision, checkpoint: { point in
                if point == .copied { throw RemoteFixtureError.expected }
            })
        }
        XCTAssertEqual(try String(contentsOf: fixture.currentPointerURL, encoding: .utf8), "\(priorRevision)\n")

        try? FileManager.default.removeItem(at: fixture.versionRoot)
        try? FileManager.default.removeItem(at: fixture.currentPointerURL)
        let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
        let otherRevision = String(repeating: "b", count: 40)
        try Data("\(otherRevision)\n".utf8).write(to: fixture.currentPointerURL, options: .atomic)
        let retained = try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: true)
        XCTAssertEqual(retained, .retainedForNativeResume)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))

        let removed = try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false)
        XCTAssertEqual(removed, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
        XCTAssertEqual(try String(contentsOf: fixture.currentPointerURL, encoding: .utf8), otherRevision + "\n")
        XCTAssertNoThrow(try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false))
    }

    func testRollbackCannotDeleteTheActiveRuntimeWhenACallerClaimsNoNativeReferences() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)

        XCTAssertEqual(
            try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false),
            .retainedForNativeResume
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
        XCTAssertEqual(try String(contentsOf: fixture.currentPointerURL, encoding: .utf8), fixture.revision + "\n")
    }

    func testEveryInstallCheckpointPreservesThePriorPointerUntilPromotionCompletes() throws {
        for interruptedAt in RemoteInstallCheckpoint.allCases {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.runtimeRoot, withIntermediateDirectories: true)
            let priorRevision = String(repeating: "a", count: 40)
            try Data("\(priorRevision)\n".utf8).write(to: fixture.currentPointerURL)

            assertRemoteErrorContains("installation interrupted") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(
                    artifactRoot: fixture.artifactRoot,
                    expectedRevision: fixture.revision,
                    checkpoint: { point in
                        if point == interruptedAt { throw RemoteFixtureError.expected }
                    }
                )
            }
            XCTAssertEqual(try String(contentsOf: fixture.currentPointerURL, encoding: .utf8), "\(priorRevision)\n")
            if interruptedAt == .promoted {
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
            }
        }
    }

    func testInstallFailsClosedWhenRuntimePathsRacePromotion() throws {
        let versionRace = try ArtifactFixture()
        defer { versionRace.remove() }
        assertRemoteErrorContains("versioned runtime") {
            _ = try RemoteRuntimeInstaller(rootURL: versionRace.runtimeRoot).install(
                artifactRoot: versionRace.artifactRoot,
                expectedRevision: versionRace.revision,
                checkpoint: { point in
                    if point == .copied {
                        try FileManager.default.createDirectory(at: versionRace.versionRoot, withIntermediateDirectories: true)
                    }
                }
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: versionRace.currentPointerURL.path))

        let pointerRace = try ArtifactFixture()
        defer { pointerRace.remove() }
        assertRemoteErrorContains("runtime pointer") {
            _ = try RemoteRuntimeInstaller(rootURL: pointerRace.runtimeRoot).install(
                artifactRoot: pointerRace.artifactRoot,
                expectedRevision: pointerRace.revision,
                checkpoint: { point in
                    if point == .promoted {
                        try FileManager.default.createDirectory(at: pointerRace.currentPointerURL, withIntermediateDirectories: false)
                    }
                }
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pointerRace.versionRoot.path))
    }

    func testInstallReverifiesTheExactStagedTreeBeforePromotion() throws {
        for mutation in ["content", "mode", "extra", "provenance"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }

            assertRemoteErrorContains("staged runtime") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(
                    artifactRoot: fixture.artifactRoot,
                    expectedRevision: fixture.revision,
                    checkpoint: { point in
                        guard point == .copied else { return }
                        let versions = fixture.runtimeRoot.appendingPathComponent("versions")
                        let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".install-") })
                        let helper = stage.appendingPathComponent("bin/OuroWorkbenchRemote")
                        if mutation == "content" {
                            try Data("tampered-after-copy".utf8).write(to: helper)
                        } else if mutation == "mode" {
                            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
                        } else if mutation == "extra" {
                            try Data("unowned".utf8).write(to: stage.appendingPathComponent("unowned"))
                        } else {
                            let provenanceURL = stage.appendingPathComponent("install-manifest.json")
                            var provenance = try JSONDecoder().decode(RemoteProvenanceManifest.self, from: Data(contentsOf: provenanceURL))
                            provenance.entries[0].ownership = .adopted
                            try JSONEncoder().encode(provenance).write(to: provenanceURL, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: provenanceURL.path)
                        }
                    }
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
            let versions = fixture.runtimeRoot.appendingPathComponent("versions")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: versions.path).contains { $0.hasPrefix(".install-") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentPointerURL.path))
        }
    }

    func testInstallReverifiesPayloadAndProvenanceAfterPromotion() throws {
        for mutation in ["content", "provenance", "metadata-mode"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }

            assertRemoteErrorContains(mutation == "content" ? "runtime file" : mutation == "provenance" ? "installed provenance" : "metadata permissions") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(
                    artifactRoot: fixture.artifactRoot,
                    expectedRevision: fixture.revision,
                    checkpoint: { point in
                        guard point == .promoted else { return }
                        let provenanceURL = fixture.versionRoot.appendingPathComponent("install-manifest.json")
                        if mutation == "content" {
                            try Data("tampered-after-promotion".utf8).write(to: fixture.versionRoot.appendingPathComponent("bin/OuroWorkbenchRemote"))
                        } else if mutation == "provenance" {
                            var provenance = try JSONDecoder().decode(RemoteProvenanceManifest.self, from: Data(contentsOf: provenanceURL))
                            provenance.entries[0].ownership = .adopted
                            try JSONEncoder().encode(provenance).write(to: provenanceURL, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: provenanceURL.path)
                        } else {
                            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: provenanceURL.path)
                        }
                    }
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentPointerURL.path))
        }
    }

    func testInstallPinsItsPhysicalRuntimeAncestorAcrossPromotion() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("physical-first", isDirectory: true)
        let second = fixture.root.appendingPathComponent("physical-second", isDirectory: true)
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("container"), withIntermediateDirectories: true)
        }
        let alias = fixture.root.appendingPathComponent("runtime-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let requestedRuntime = alias.appendingPathComponent("container/runtime", isDirectory: true)

        assertRemoteErrorContains("physical") {
            _ = try RemoteRuntimeInstaller(rootURL: requestedRuntime).install(
                artifactRoot: fixture.artifactRoot,
                expectedRevision: fixture.revision,
                checkpoint: { point in
                    guard point == .copied else { return }
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
                }
            )
        }
        let firstVersions = first.appendingPathComponent("container/runtime/versions")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: firstVersions.path).contains { $0.hasPrefix(".install-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("container/runtime/current").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("container/runtime/current").path))
    }

    func testInstallAdoptsOnlyACompleteExactPreexistingVersion() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        for file in fixture.manifest.files {
            let source = fixture.artifactRoot.appendingPathComponent(file.relativePath)
            let destination = fixture.versionRoot.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: file.mode], ofItemAtPath: destination.path)
        }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
        try Data("\(String(repeating: "a", count: 40))\n".utf8).write(to: fixture.currentPointerURL, options: .atomic)
        XCTAssertEqual(provenance.entries.map(\.ownership), [.adopted, .adopted])
        XCTAssertEqual(try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false), .preservedAdopted)

        let partial = try ArtifactFixture()
        defer { partial.remove() }
        try FileManager.default.createDirectory(at: partial.versionRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: partial.artifactRoot.appendingPathComponent("bin/OuroWorkbenchRemote"),
            to: partial.versionRoot.appendingPathComponent("bin/OuroWorkbenchRemote")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: partial.versionRoot.appendingPathComponent("bin/OuroWorkbenchRemote").path
        )
        assertRemoteErrorContains("incomplete preexisting version") {
            _ = try RemoteRuntimeInstaller(rootURL: partial.runtimeRoot).install(artifactRoot: partial.artifactRoot, expectedRevision: partial.revision)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.currentPointerURL.path))

        let missingFile = try ArtifactFixture()
        defer { missingFile.remove() }
        for directory in ["bin", "share"] {
            try FileManager.default.createDirectory(at: missingFile.versionRoot.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let binary = missingFile.versionRoot.appendingPathComponent("bin/OuroWorkbenchRemote")
        try FileManager.default.copyItem(at: missingFile.artifactRoot.appendingPathComponent("bin/OuroWorkbenchRemote"), to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        assertRemoteErrorContains("incomplete preexisting version") {
            _ = try RemoteRuntimeInstaller(rootURL: missingFile.runtimeRoot).install(artifactRoot: missingFile.artifactRoot, expectedRevision: missingFile.revision)
        }
    }

    func testRollbackPreservesAdoptedFilesAndRejectsManifestOutsideRuntimeRoot() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        let first = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)

        var escaped = first
        escaped.runtimeRoot = "/tmp/not-the-runtime"
        assertRemoteErrorContains("provenance root") {
            _ = try installer.rollback(provenance: escaped, nativeSessionReferencesRemain: false)
        }
    }

    func testRollbackRejectsTamperedCreatedVersionsAndUnsafeProvenanceWithoutDeletingThem() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
        let binary = fixture.versionRoot.appendingPathComponent("bin/OuroWorkbenchRemote")
        try Data("changed".utf8).write(to: binary)
        assertRemoteErrorContains("runtime file changed") {
            _ = try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))

        var unsafe = provenance
        unsafe.revision = "../escape"
        assertRemoteErrorContains("provenance") {
            _ = try installer.rollback(provenance: unsafe, nativeSessionReferencesRemain: false)
        }
    }

    func testInstalledProvenanceRejectsUnknownInvalidOversizedAndMismatchedContent() throws {
        for failure in ["unknown", "invalid", "oversized", "mismatch"] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
            let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
            let manifestURL = fixture.versionRoot.appendingPathComponent("install-manifest.json")
            if failure == "unknown" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
                object["surprise"] = true
                try remoteJSONData(object).write(to: manifestURL)
            } else if failure == "invalid" {
                try Data("{".utf8).write(to: manifestURL)
            } else if failure == "oversized" {
                try Data(repeating: 1, count: RemoteArtifactVerifier.maximumManifestBytes + 1).write(to: manifestURL)
            } else {
                var other = provenance
                other.entries[0].sha256 = String(repeating: "0", count: 64)
                try JSONEncoder().encode(other).write(to: manifestURL)
            }
            assertRemoteErrorContains(failure == "oversized" ? "byte bound" : "provenance") {
                _ = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
        }
    }

    func testRollbackRejectsEveryUnsafeProvenanceEntryAndUnownedRuntimeFile() throws {
        let mutations: [(inout RemoteProvenanceManifest) -> Void] = [
            { $0.schemaVersion = 2 },
            { $0.entries = [] },
            { $0.entries[0].path = "/tmp/outside" },
            {
                let entry = $0.entries[0]
                $0.entries.append(entry)
            },
            { $0.entries[0].sha256 = "bad" }
        ]
        for mutate in mutations {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
            var provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
            mutate(&provenance)
            assertRemoteErrorContains("provenance") {
                _ = try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
        }

        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
        try Data("unowned".utf8).write(to: fixture.versionRoot.appendingPathComponent("unowned"))
        assertRemoteErrorContains("unowned file") {
            _ = try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
    }

    func testRollbackRejectsPortableProvenancePathCollisionsBeforeReadingTheRuntime() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        var provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
        var collision = provenance.entries[0]
        collision.path = collision.path.replacingOccurrences(of: "/bin/", with: "/BIN/")
        provenance.entries.append(collision)

        assertRemoteErrorContains("provenance entry is unsafe") {
            _ = try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.versionRoot.path))
    }

    func testRollbackPreservesAnotherActiveRevisionAndCleansAnAlreadyMissingVersion() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let installer = RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot)
        let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
        let otherRevision = String(repeating: "a", count: 40)
        try Data("\(otherRevision)\n".utf8).write(to: fixture.currentPointerURL, options: .atomic)

        XCTAssertEqual(try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false), .removed)
        XCTAssertEqual(try String(contentsOf: fixture.currentPointerURL, encoding: .utf8), "\(otherRevision)\n")

        let missing = try ArtifactFixture()
        defer { missing.remove() }
        let missingInstaller = RemoteRuntimeInstaller(rootURL: missing.runtimeRoot)
        let missingProvenance = try missingInstaller.install(artifactRoot: missing.artifactRoot, expectedRevision: missing.revision)
        try FileManager.default.removeItem(at: missing.versionRoot)
        XCTAssertEqual(try missingInstaller.rollback(provenance: missingProvenance, nativeSessionReferencesRemain: false), .retainedForNativeResume)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.currentPointerURL.path))
    }

    func testRollbackHandlesMissingRuntimeAndRejectsDifferentInstalledProvenance() throws {
        let missing = try ArtifactFixture()
        defer { missing.remove() }
        let missingInstaller = RemoteRuntimeInstaller(rootURL: missing.runtimeRoot)
        let missingProvenance = try missingInstaller.install(artifactRoot: missing.artifactRoot, expectedRevision: missing.revision)
        try FileManager.default.removeItem(at: missing.runtimeRoot)
        XCTAssertEqual(try missingInstaller.rollback(provenance: missingProvenance, nativeSessionReferencesRemain: false), .removed)

        let mismatched = try ArtifactFixture()
        defer { mismatched.remove() }
        let mismatchedInstaller = RemoteRuntimeInstaller(rootURL: mismatched.runtimeRoot)
        let expected = try mismatchedInstaller.install(artifactRoot: mismatched.artifactRoot, expectedRevision: mismatched.revision)
        var installed = expected
        installed.entries[0].ownership = .adopted
        try JSONEncoder().encode(installed).write(to: mismatched.versionRoot.appendingPathComponent("install-manifest.json"))
        assertRemoteErrorContains("does not match rollback provenance") {
            _ = try mismatchedInstaller.rollback(provenance: expected, nativeSessionReferencesRemain: false)
        }
    }

    func testReinstallRejectsTypedInvalidProvenanceAndInstalledRuntimeDrift() throws {
        let invalid = try ArtifactFixture()
        defer { invalid.remove() }
        let invalidInstaller = RemoteRuntimeInstaller(rootURL: invalid.runtimeRoot)
        _ = try invalidInstaller.install(artifactRoot: invalid.artifactRoot, expectedRevision: invalid.revision)
        let invalidManifestURL = invalid.versionRoot.appendingPathComponent("install-manifest.json")
        var invalidObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: invalidManifestURL)) as? [String: Any])
        invalidObject["schemaVersion"] = "one"
        try remoteJSONData(invalidObject).write(to: invalidManifestURL)
        assertRemoteErrorContains("provenance is invalid") {
            _ = try invalidInstaller.install(artifactRoot: invalid.artifactRoot, expectedRevision: invalid.revision)
        }

        let count = try ArtifactFixture()
        defer { count.remove() }
        let countInstaller = RemoteRuntimeInstaller(rootURL: count.runtimeRoot)
        var countProvenance = try countInstaller.install(artifactRoot: count.artifactRoot, expectedRevision: count.revision)
        countProvenance.entries.removeLast()
        try JSONEncoder().encode(countProvenance).write(to: count.versionRoot.appendingPathComponent("install-manifest.json"))
        assertRemoteErrorContains("does not match the artifact") {
            _ = try countInstaller.install(artifactRoot: count.artifactRoot, expectedRevision: count.revision)
        }

        let drift = try ArtifactFixture()
        defer { drift.remove() }
        let driftInstaller = RemoteRuntimeInstaller(rootURL: drift.runtimeRoot)
        _ = try driftInstaller.install(artifactRoot: drift.artifactRoot, expectedRevision: drift.revision)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: drift.versionRoot.appendingPathComponent("bin/OuroWorkbenchRemote").path)
        assertRemoteErrorContains("runtime file does not match") {
            _ = try driftInstaller.install(artifactRoot: drift.artifactRoot, expectedRevision: drift.revision)
        }
    }

    func testInstallerRejectsOversizedUnreadablePointerAndFilesystemRaces() throws {
        for pointer in [Data(repeating: 0x61, count: 129), Data([0xff])] {
            let fixture = try ArtifactFixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.runtimeRoot, withIntermediateDirectories: true)
            try pointer.write(to: fixture.currentPointerURL)
            assertRemoteErrorContains("runtime pointer") {
                _ = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)
            }
        }

        let removal = try ArtifactFixture()
        defer { removal.remove() }
        assertRemoteErrorContains("staging root could not be removed") {
            _ = try RemoteRuntimeInstaller(rootURL: removal.runtimeRoot).install(
                artifactRoot: removal.artifactRoot,
                expectedRevision: removal.revision,
                checkpoint: { point in
                    guard point == .copied else { return }
                    let versions = removal.runtimeRoot.appendingPathComponent("versions")
                    let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".install-") })
                    try FileManager.default.removeItem(at: stage)
                    throw RemoteFixtureError.expected
                }
            )
        }

        let write = try ArtifactFixture()
        defer { write.remove() }
        assertRemoteErrorContains("runtime root physical location changed") {
            _ = try RemoteRuntimeInstaller(rootURL: write.runtimeRoot).install(
                artifactRoot: write.artifactRoot,
                expectedRevision: write.revision,
                checkpoint: { point in
                    if point == .promoted { try FileManager.default.removeItem(at: write.runtimeRoot) }
                }
            )
        }
    }

    func testInstallManifestAndDoctorDescriptionsNeverContainFixtureCredentials() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let provenance = try RemoteRuntimeInstaller(rootURL: fixture.runtimeRoot).install(
            artifactRoot: fixture.artifactRoot,
            expectedRevision: fixture.revision
        )
        let encoded = try JSONEncoder().encode(provenance)
        let joined = String(data: encoded, encoding: .utf8)! + String(describing: provenance)
        XCTAssertFalse(joined.contains("fixture-secret"))
        XCTAssertFalse(joined.contains("GH_TOKEN"))
    }

    func testStandaloneArtifactBuilderPackagesItsExactExecutableAndRejectsUnsafeInputs() throws {
        let root = try remoteTemporaryDirectory("builder")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try remoteCleanGitRepository(at: root.appendingPathComponent("source"))
        let helper = root.appendingPathComponent("OuroWorkbenchRemote")
        try Data("standalone-helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let revision = source.revision
        let helperSHA256 = RemoteArtifactVerifier.sha256(Data("standalone-helper".utf8))
        let output = root.appendingPathComponent("artifact")
        var checkpoints: [RemoteArtifactBuildCheckpoint] = []

        let manifest = try RemoteArtifactBuilder.build(
            helperURL: helper,
            outputURL: output,
            sourceRootURL: source.url,
            revision: revision,
            expectedHelperSHA256: helperSHA256,
            checkpoint: { checkpoints.append($0) }
        )

        XCTAssertEqual(checkpoints, [.copied, .manifestWritten, .promoted])
        XCTAssertEqual(manifest, try RemoteArtifactVerifier.load(rootURL: output))
        XCTAssertEqual(manifest.files, [
            .init(relativePath: "bin/OuroWorkbenchRemote", sha256: RemoteArtifactVerifier.sha256(Data("standalone-helper".utf8)), mode: 0o755)
        ])
        XCTAssertEqual(try permissions(at: output), 0o700)
        XCTAssertEqual(try permissions(at: output.appendingPathComponent("manifest.json")), 0o600)

        let defaultCheckpointOutput = root.appendingPathComponent("default-checkpoint-artifact")
        XCTAssertEqual(
            try RemoteArtifactBuilder.build(helperURL: helper, outputURL: defaultCheckpointOutput, sourceRootURL: source.url, revision: revision, expectedHelperSHA256: helperSHA256),
            try RemoteArtifactVerifier.load(rootURL: defaultCheckpointOutput)
        )

        for failure in ["revision", "output", "permissions", "symlink", "hardlink"] {
            let candidate = root.appendingPathComponent("candidate-\(failure)")
            var candidateHelper = helper
            var candidateRevision = revision
            if failure == "revision" { candidateRevision = "not-a-revision" }
            if failure == "output" { try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false) }
            if failure == "permissions" {
                candidateHelper = root.appendingPathComponent("non-executable")
                try Data().write(to: candidateHelper)
            }
            if failure == "symlink" {
                candidateHelper = root.appendingPathComponent("linked-helper")
                try FileManager.default.createSymbolicLink(at: candidateHelper, withDestinationURL: helper)
            }
            if failure == "hardlink" {
                candidateHelper = root.appendingPathComponent("hard-linked-helper")
                try FileManager.default.linkItem(at: helper, to: candidateHelper)
            }
            assertRemoteErrorContains(failure == "revision" ? "revision" : failure == "output" ? "new path" : "helper") {
                _ = try RemoteArtifactBuilder.build(helperURL: candidateHelper, outputURL: candidate, sourceRootURL: source.url, revision: candidateRevision, expectedHelperSHA256: helperSHA256)
            }
            if failure == "hardlink" {
                try FileManager.default.removeItem(at: candidateHelper)
            }
        }

        let interrupted = root.appendingPathComponent("interrupted")
        assertRemoteErrorContains("interrupted") {
            _ = try RemoteArtifactBuilder.build(helperURL: helper, outputURL: interrupted, sourceRootURL: source.url, revision: revision, expectedHelperSHA256: helperSHA256) { point in
                if point == .manifestWritten { throw RemoteFixtureError.expected }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".artifact-") })

        let raced = root.appendingPathComponent("raced")
        assertRemoteErrorContains("promoted") {
            _ = try RemoteArtifactBuilder.build(helperURL: helper, outputURL: raced, sourceRootURL: source.url, revision: revision, expectedHelperSHA256: helperSHA256) { point in
                if point == .manifestWritten {
                    try FileManager.default.createDirectory(at: raced, withIntermediateDirectories: false)
                }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: raced.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".raced-") })
    }

    func testArtifactBuilderBindsTheManifestToAnExactCleanSourceHead() throws {
        let root = try remoteTemporaryDirectory("build-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("OuroWorkbenchRemote")
        let helperData = Data("trusted-build".utf8)
        try helperData.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let helperSHA256 = RemoteArtifactVerifier.sha256(helperData)
        let clean = try remoteCleanGitRepository(at: root.appendingPathComponent("clean"))

        let manifest = try RemoteArtifactBuilder.build(
            helperURL: helper,
            outputURL: root.appendingPathComponent("artifact"),
            sourceRootURL: clean.url,
            revision: clean.revision,
            expectedHelperSHA256: helperSHA256
        )
        XCTAssertEqual(manifest.revision, clean.revision)

        assertRemoteErrorContains("does not match the clean source HEAD") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: root.appendingPathComponent("wrong-revision"),
                sourceRootURL: clean.url,
                revision: String(repeating: "f", count: 40),
                expectedHelperSHA256: helperSHA256
            )
        }

        for dirt in ["staged", "unstaged", "untracked"] {
            let source = try remoteCleanGitRepository(at: root.appendingPathComponent(dirt))
            let tracked = source.url.appendingPathComponent("tracked.txt")
            if dirt == "staged" {
                try Data("staged".utf8).write(to: tracked)
                _ = try remoteGit(["add", "tracked.txt"], at: source.url)
            } else if dirt == "unstaged" {
                try Data("unstaged".utf8).write(to: tracked)
            } else {
                try Data("untracked".utf8).write(to: source.url.appendingPathComponent("untracked.txt"))
            }
            assertRemoteErrorContains("source checkout is not clean") {
                _ = try RemoteArtifactBuilder.build(
                    helperURL: helper,
                    outputURL: root.appendingPathComponent("artifact-\(dirt)"),
                    sourceRootURL: source.url,
                    revision: source.revision,
                    expectedHelperSHA256: helperSHA256
                )
            }
        }

        let notGit = root.appendingPathComponent("not-git")
        try FileManager.default.createDirectory(at: notGit, withIntermediateDirectories: false)
        assertRemoteErrorContains("trusted source HEAD") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: root.appendingPathComponent("artifact-not-git"),
                sourceRootURL: notGit,
                revision: clean.revision,
                expectedHelperSHA256: helperSHA256
            )
        }

        assertRemoteErrorContains("trusted source HEAD") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: root.appendingPathComponent("artifact-missing-source"),
                sourceRootURL: root.appendingPathComponent("missing-source"),
                revision: clean.revision,
                expectedHelperSHA256: helperSHA256
            )
        }

        let subdirectory = clean.url.appendingPathComponent("subdirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        assertRemoteErrorContains("exact Git worktree root") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: root.appendingPathComponent("artifact-subdirectory"),
                sourceRootURL: subdirectory,
                revision: clean.revision,
                expectedHelperSHA256: helperSHA256
            )
        }
    }

    func testArtifactBuilderReverifiesSourceAndExactStageBeforePromotion() throws {
        for mutation in ["source", "source-head", "manifest", "content", "mode", "extra", "extra-directory", "special"] {
            let root = try remoteTemporaryDirectory("build-reverify-\(mutation)")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try remoteCleanGitRepository(at: root.appendingPathComponent("source"))
            let helper = root.appendingPathComponent("OuroWorkbenchRemote")
            let helperData = Data("trusted-build".utf8)
            try helperData.write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let output = root.appendingPathComponent("artifact")

            let expected = mutation == "source" ? "source checkout is not clean" : mutation == "source-head" ? "source HEAD changed" : "staged artifact"
            assertRemoteErrorContains(expected) {
                _ = try RemoteArtifactBuilder.build(
                    helperURL: helper,
                    outputURL: output,
                    sourceRootURL: source.url,
                    revision: source.revision,
                    expectedHelperSHA256: RemoteArtifactVerifier.sha256(helperData),
                    checkpoint: { point in
                        guard point == .manifestWritten else { return }
                        if mutation == "source" {
                            try Data("late dirt".utf8).write(to: source.url.appendingPathComponent("late.txt"))
                            return
                        }
                        if mutation == "source-head" {
                            try Data("new head\n".utf8).write(to: source.url.appendingPathComponent("tracked.txt"))
                            _ = try remoteGit(["add", "tracked.txt"], at: source.url)
                            _ = try remoteGit(["commit", "--quiet", "-m", "new head"], at: source.url)
                            return
                        }
                        let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".artifact-") })
                        let stagedHelper = stage.appendingPathComponent("bin/OuroWorkbenchRemote")
                        if mutation == "manifest" {
                            let manifestURL = stage.appendingPathComponent("manifest.json")
                            var stagedManifest = try JSONDecoder().decode(RemoteArtifactManifest.self, from: Data(contentsOf: manifestURL))
                            stagedManifest.revision = String(repeating: "f", count: 40)
                            try JSONEncoder().encode(stagedManifest).write(to: manifestURL, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
                        } else if mutation == "content" {
                            try Data("tampered".utf8).write(to: stagedHelper)
                        } else if mutation == "mode" {
                            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedHelper.path)
                        } else if mutation == "extra" {
                            try Data("unowned".utf8).write(to: stage.appendingPathComponent("unowned"))
                        } else if mutation == "extra-directory" {
                            try FileManager.default.createDirectory(at: stage.appendingPathComponent("unowned"), withIntermediateDirectories: false)
                        } else {
                            try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent("unowned"), withDestinationURL: stagedHelper)
                        }
                    }
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".artifact-") })
        }
    }

    func testArtifactBuilderRejectsACoherentlyRewrittenManifestAfterPromotion() throws {
        let root = try remoteTemporaryDirectory("build-promoted-reverify")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try remoteCleanGitRepository(at: root.appendingPathComponent("source"))
        let helper = root.appendingPathComponent("OuroWorkbenchRemote")
        let helperData = Data("trusted-build".utf8)
        try helperData.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let output = root.appendingPathComponent("artifact")

        assertRemoteErrorContains("promoted artifact") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: output,
                sourceRootURL: source.url,
                revision: source.revision,
                expectedHelperSHA256: RemoteArtifactVerifier.sha256(helperData),
                checkpoint: { point in
                    guard point == .promoted else { return }
                    let manifestURL = output.appendingPathComponent("manifest.json")
                    var manifest = try JSONDecoder().decode(RemoteArtifactManifest.self, from: Data(contentsOf: manifestURL))
                    manifest.revision = String(repeating: "f", count: 40)
                    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
                }
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testArtifactBuilderPinsItsPhysicalOutputAncestorAcrossPromotion() throws {
        let root = try remoteTemporaryDirectory("build-physical")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try remoteCleanGitRepository(at: root.appendingPathComponent("source"))
        let helper = root.appendingPathComponent("OuroWorkbenchRemote")
        let helperData = Data("trusted-build".utf8)
        try helperData.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let first = root.appendingPathComponent("physical-first", isDirectory: true)
        let second = root.appendingPathComponent("physical-second", isDirectory: true)
        for target in [first, second] {
            try FileManager.default.createDirectory(at: target.appendingPathComponent("output"), withIntermediateDirectories: true)
        }
        let alias = root.appendingPathComponent("output-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let output = alias.appendingPathComponent("output/artifact")

        assertRemoteErrorContains("physical") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: output,
                sourceRootURL: source.url,
                revision: source.revision,
                expectedHelperSHA256: RemoteArtifactVerifier.sha256(helperData),
                checkpoint: { point in
                    guard point == .manifestWritten else { return }
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
                }
            )
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: first.appendingPathComponent("output").path).contains { $0.hasPrefix(".artifact-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("output/artifact").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("output/artifact").path))
    }

    func testArtifactBuilderPinsItsPhysicalSourceAncestorAcrossPromotion() throws {
        let root = try remoteTemporaryDirectory("build-source-physical")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("physical-first/container", isDirectory: true)
        let second = root.appendingPathComponent("physical-second/container", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let source = try remoteCleanGitRepository(at: first.appendingPathComponent("source"))
        try FileManager.default.copyItem(at: source.url, to: second.appendingPathComponent("source"))
        let alias = root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.deletingLastPathComponent())
        let requestedSource = alias.appendingPathComponent("container/source", isDirectory: true)
        let helper = root.appendingPathComponent("OuroWorkbenchRemote")
        let helperData = Data("trusted-build".utf8)
        try helperData.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let output = root.appendingPathComponent("artifact")

        assertRemoteErrorContains("physical") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: output,
                sourceRootURL: requestedSource,
                revision: source.revision,
                expectedHelperSHA256: RemoteArtifactVerifier.sha256(helperData),
                checkpoint: { point in
                    guard point == .manifestWritten else { return }
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second.deletingLastPathComponent())
                }
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".artifact-") })
    }

    func testArtifactBuildAndInstallRequireAnIndependentExpectedHelperDigest() throws {
        let root = try remoteTemporaryDirectory("trusted-digest")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("OuroWorkbenchRemote")
        let helperData = Data("reviewed-helper".utf8)
        try helperData.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let source = try remoteCleanGitRepository(at: root.appendingPathComponent("source"))
        let revision = source.revision
        let trustedDigest = RemoteArtifactVerifier.sha256(helperData)
        let artifact = root.appendingPathComponent("artifact")

        assertRemoteErrorContains("trusted helper digest is invalid") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: artifact,
                sourceRootURL: source.url,
                revision: revision,
                expectedHelperSHA256: "not-a-digest"
            )
        }
        assertRemoteErrorContains("trusted helper digest") {
            _ = try RemoteArtifactBuilder.build(
                helperURL: helper,
                outputURL: artifact,
                sourceRootURL: source.url,
                revision: revision,
                expectedHelperSHA256: String(repeating: "b", count: 64)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        _ = try RemoteArtifactBuilder.build(
            helperURL: helper,
            outputURL: artifact,
            sourceRootURL: source.url,
            revision: revision,
            expectedHelperSHA256: trustedDigest
        )

        let runtime = root.appendingPathComponent("runtime")
        let installer = RemoteRuntimeInstaller(rootURL: runtime)
        assertRemoteErrorContains("trusted helper digest is invalid") {
            _ = try installer.install(
                artifactRoot: artifact,
                expectedRevision: revision,
                expectedHelperSHA256: "not-a-digest"
            )
        }
        assertRemoteErrorContains("trusted helper digest") {
            _ = try installer.install(
                artifactRoot: artifact,
                expectedRevision: revision,
                expectedHelperSHA256: String(repeating: "b", count: 64)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertEqual(
            try installer.install(
                artifactRoot: artifact,
                expectedRevision: revision,
                expectedHelperSHA256: trustedDigest
            ).revision,
            revision
        )
    }

    func testRollbackPinsAnIntermediateSymlinkAncestorAcrossPhysicalValidation() throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let root = try remoteTemporaryDirectory("rollback-physical-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first/container", isDirectory: true)
        let second = root.appendingPathComponent("second/container", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.deletingLastPathComponent())
        let installer = RemoteRuntimeInstaller(rootURL: alias.appendingPathComponent("container"))
        let provenance = try installer.install(artifactRoot: fixture.artifactRoot, expectedRevision: fixture.revision)

        assertRemoteErrorContains("physical location changed") {
            _ = try installer.rollback(provenance: provenance, nativeSessionReferencesRemain: false) {
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second.deletingLastPathComponent())
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("versions/\(fixture.revision)").path))
    }

    func testPhysicalContainmentAndExactTreeInventoryFailClosedOnEscapeInspectionFailureAndDisappearance() throws {
        let root = try remoteTemporaryDirectory("tree-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        assertRemoteErrorContains("escapes its physical root") {
            try remoteRequirePhysicalContainment(root.deletingLastPathComponent(), in: root, label: "fixture", domain: .artifact)
        }

        let notDirectory = root.appendingPathComponent("not-directory")
        assertRemoteErrorContains("could not be inspected") {
            try remoteVerifyExactTreeInventory(rootURL: notDirectory, expectedFiles: [], expectedDirectories: [], label: "fixture")
        }

        let changing = root.appendingPathComponent("changing", isDirectory: true)
        try FileManager.default.createDirectory(at: changing, withIntermediateDirectories: false)
        let disappearing = changing.appendingPathComponent("file")
        try Data().write(to: disappearing)
        assertRemoteErrorContains("changed during inspection") {
            try remoteVerifyExactTreeInventory(rootURL: changing, expectedFiles: [disappearing.path], expectedDirectories: [], label: "fixture") { url in
                if url == disappearing { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    func testTrustedSourceRevisionTranslatesRunnerFailureAndRejectsInvalidOrChangingHead() throws {
        let root = try remoteTemporaryDirectory("trusted-source-seams")
        defer { try? FileManager.default.removeItem(at: root) }
        assertRemoteErrorContains("could not be verified") {
            _ = try remoteTrustedSourceRevision(rootURL: root, runGit: { _ in throw RemoteFixtureError.expected })
        }

        var invalidHeadCall = 0
        assertRemoteErrorContains("could not be verified") {
            _ = try remoteTrustedSourceRevision(rootURL: root, runGit: { _ in
                invalidHeadCall += 1
                return .init(exitCode: 0, stdout: Data((invalidHeadCall == 1 ? root.path : "not-a-head").utf8))
            })
        }

        let first = String(repeating: "a", count: 40)
        let second = String(repeating: "b", count: 40)
        var changingHeadCall = 0
        assertRemoteErrorContains("changed during verification") {
            _ = try remoteTrustedSourceRevision(rootURL: root, runGit: { _ in
                changingHeadCall += 1
                let output = changingHeadCall == 1 ? root.path : changingHeadCall == 2 ? first : changingHeadCall == 3 ? "" : second
                return .init(exitCode: 0, stdout: Data(output.utf8))
            })
        }
    }

    func testArtifactBuilderReportsManifestWriteFailureBeforePromotion() throws {
        let root = try remoteTemporaryDirectory("builder-write-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try remoteCleanGitRepository(at: root.appendingPathComponent("source"))
        let helper = root.appendingPathComponent("OuroWorkbenchRemote")
        let data = Data("helper".utf8)
        try data.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        assertRemoteErrorContains("manifest could not be written") {
            _ = try RemoteArtifactBuilder.build(helperURL: helper, outputURL: root.appendingPathComponent("artifact"), sourceRootURL: source.url, revision: source.revision, expectedHelperSHA256: RemoteArtifactVerifier.sha256(data)) { checkpoint in
                guard checkpoint == .copied else { return }
                let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".artifact-") })
                try FileManager.default.createDirectory(at: stage.appendingPathComponent("manifest.json"), withIntermediateDirectories: false)
            }
        }
    }
}

private extension RemoteRuntimeInstaller {
    func install(
        artifactRoot: URL,
        expectedRevision: String,
        checkpoint: (RemoteInstallCheckpoint) throws -> Void = { _ in }
    ) throws -> RemoteProvenanceManifest {
        let manifest = try RemoteArtifactVerifier.load(rootURL: artifactRoot)
        guard let helperSHA256 = manifest.files.first(where: { $0.relativePath == "bin/OuroWorkbenchRemote" })?.sha256 else {
            throw RemoteControlError.artifact("fixture helper digest is missing")
        }
        return try install(
            artifactRoot: artifactRoot,
            expectedRevision: expectedRevision,
            expectedHelperSHA256: helperSHA256,
            checkpoint: checkpoint
        )
    }
}

private final class ArtifactFixture {
    let root: URL
    let artifactRoot: URL
    let runtimeRoot: URL
    let revision = "d57d344fc801fc005769223c13def91a4df01c25"
    let manifest: RemoteArtifactManifest

    init() throws {
        root = try remoteTemporaryDirectory("artifact")
        artifactRoot = root.appendingPathComponent("artifact", isDirectory: true)
        runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let binary = Data("standalone-helper-binary".utf8)
        let profile = Data("{\"schemaVersion\":1}".utf8)
        manifest = RemoteArtifactManifest(
            schemaVersion: 1,
            revision: revision,
            files: [
                .init(relativePath: "bin/OuroWorkbenchRemote", sha256: RemoteArtifactVerifier.sha256(binary), mode: 0o755),
                .init(relativePath: "share/profiles.example.json", sha256: RemoteArtifactVerifier.sha256(profile), mode: 0o644)
            ]
        )
        try FileManager.default.createDirectory(at: artifactRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactRoot.appendingPathComponent("share"), withIntermediateDirectories: true)
        try binary.write(to: artifactRoot.appendingPathComponent("bin/OuroWorkbenchRemote"))
        try profile.write(to: artifactRoot.appendingPathComponent("share/profiles.example.json"))
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifactRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifactRoot.appendingPathComponent("bin").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifactRoot.appendingPathComponent("share").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: artifactRoot.appendingPathComponent("bin/OuroWorkbenchRemote").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: artifactRoot.appendingPathComponent("share/profiles.example.json").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    var manifestURL: URL { artifactRoot.appendingPathComponent("manifest.json") }
    var versionRoot: URL { runtimeRoot.appendingPathComponent("versions/\(revision)", isDirectory: true) }
    var currentPointerURL: URL { runtimeRoot.appendingPathComponent("current") }

    func manifestObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func permissions(at url: URL) throws -> Int {
    let value = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
}

private func remoteCleanGitRepository(at url: URL) throws -> (url: URL, revision: String) {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    _ = try remoteGit(["init", "--quiet"], at: url)
    _ = try remoteGit(["config", "user.name", "Remote Fixture"], at: url)
    _ = try remoteGit(["config", "user.email", "remote@example.test"], at: url)
    _ = try remoteGit(["config", "commit.gpgsign", "false"], at: url)
    try Data("tracked\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
    _ = try remoteGit(["add", "tracked.txt"], at: url)
    _ = try remoteGit(["commit", "--quiet", "-m", "fixture"], at: url)
    return (url, try remoteGit(["rev-parse", "--verify", "HEAD^{commit}"], at: url))
}

@discardableResult
private func remoteGit(_ arguments: [String], at rootURL: URL) throws -> String {
    let result = try RemoteSystemRunner(timeout: 10, maximumOutputBytes: 65_536).run(
        RemoteProcessRequest(
            executable: "/usr/bin/git",
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
            workingDirectory: rootURL.path
        )
    )
    guard result.exitCode == 0 else {
        throw RemoteFixtureError.expected
    }
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
