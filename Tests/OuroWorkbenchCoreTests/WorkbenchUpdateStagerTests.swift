import CryptoKit
import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchUpdateStagerTests: XCTestCase {
    func testStageDownloadsVerifiesExpandsChecksSignatureAndReportsProgress() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let manifest = manifestData(archive: archive)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifest,
                plan.archiveURL: archive
            ],
            temp: temp,
            extractedBundleIdentifier: WorkbenchRelease.bundleIdentifier,
            extractedVersion: "9.9.9"
        )
        let stager = makeStager(recorder: recorder, currentVersion: "9.9.8")

        let staged = try await stager.stage(plan: plan) { step in
            recorder.recordProgress(step)
        }

        XCTAssertEqual(staged.stagingRoot, temp)
        XCTAssertEqual(staged.appURL.lastPathComponent, "\(WorkbenchRelease.appName).app")
        XCTAssertEqual(staged.version, "9.9.9")
        XCTAssertEqual(staged.build, "777")
        XCTAssertEqual(staged.releaseLabel, "9.9.9 (build 777)")
        XCTAssertEqual(recorder.progress, [
            "Downloading release manifest…",
            "Downloading \(plan.archiveName)…",
            "Verifying download…",
            "Expanding update…",
            "Checking signature…"
        ])
        XCTAssertEqual(recorder.downloads.map(\.url), [plan.manifestURL, plan.archiveURL])
        XCTAssertEqual(recorder.downloads.map(\.userAgent), [
            WorkbenchRelease.userAgent(version: "9.9.8"),
            WorkbenchRelease.userAgent(version: "9.9.8")
        ])
        XCTAssertEqual(recorder.processCalls.map(\.launchPath), ["/usr/bin/ditto", "/usr/bin/codesign"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appURL.path))
    }

    func testStageFailsOnBadManifestBeforeArchiveDownloadOrProcesses() async throws {
        let temp = try makeTempRoot()
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [plan.manifestURL: Data("not-json".utf8)],
            temp: temp
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            guard case .manifestDecode = error else {
                return XCTFail("expected manifestDecode, got \(error)")
            }
        }

        XCTAssertEqual(recorder.downloads.map(\.url), [plan.manifestURL])
        XCTAssertTrue(recorder.processCalls.isEmpty)
    }

    func testStageFailsVerificationBeforeUnzip() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive, sha256: String(repeating: "0", count: 64)),
                plan.archiveURL: archive
            ],
            temp: temp
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(
                error,
                .verification(.sha256Mismatch(expected: String(repeating: "0", count: 64), got: sha256(archive)))
            )
        }

        XCTAssertTrue(recorder.processCalls.isEmpty)
    }

    func testStageFailsWhenUnzipDoesNotProduceAppBundle() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            createExtractedApp: false
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(error, .missingStagedApp)
        }

        XCTAssertEqual(recorder.processCalls.map(\.launchPath), ["/usr/bin/ditto"])
    }

    func testStageFailsWhenUnzipCommandFailsWithStderr() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            dittoResult: .init(status: 2, stderr: "ditto nope")
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(error, .unzipFailed("ditto nope"))
        }

        XCTAssertEqual(recorder.processCalls.map(\.launchPath), ["/usr/bin/ditto"])
    }

    func testStageFailsWhenUnzipCommandFailsWithoutStderr() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            dittoResult: .init(status: 2)
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(error, .unzipFailed("ditto exited 2"))
        }
    }

    func testStageFailsWhenExtractedBundleIdentityDoesNotMatchManifest() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            extractedBundleIdentifier: "com.example.other",
            extractedVersion: "9.9.9"
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(
                error,
                .stagedIdentityMismatch("bundle id com.example.other != manifest \(WorkbenchRelease.bundleIdentifier)")
            )
        }

        XCTAssertEqual(recorder.processCalls.map(\.launchPath), ["/usr/bin/ditto"])
    }

    func testStageFailsWhenExtractedBundleIdentifierIsMissing() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            extractedBundleIdentifier: nil,
            extractedVersion: "9.9.9"
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(
                error,
                .stagedIdentityMismatch("bundle id nil != manifest \(WorkbenchRelease.bundleIdentifier)")
            )
        }
    }

    func testStageFailsWhenExtractedBundleVersionDoesNotMatchManifest() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            extractedBundleIdentifier: WorkbenchRelease.bundleIdentifier,
            extractedVersion: "1.2.3"
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(error, .stagedIdentityMismatch("version 1.2.3 != manifest 9.9.9"))
        }
    }

    func testStageFailsWhenExtractedBundleVersionIsMissing() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            extractedBundleIdentifier: WorkbenchRelease.bundleIdentifier,
            extractedVersion: nil
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(error, .stagedIdentityMismatch("version nil != manifest 9.9.9"))
        }
    }

    func testStageFailsWhenCodesignRejectsExtractedBundle() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            extractedBundleIdentifier: WorkbenchRelease.bundleIdentifier,
            extractedVersion: "9.9.9",
            codesignResult: .init(status: 1, stderr: "bad signature")
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(error, .codesignFailed("bad signature"))
        }

        XCTAssertEqual(recorder.processCalls.map(\.launchPath), ["/usr/bin/ditto", "/usr/bin/codesign"])
    }

    func testStageFailsWhenCodesignRejectsExtractedBundleWithoutStderr() async throws {
        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: temp,
            extractedBundleIdentifier: WorkbenchRelease.bundleIdentifier,
            extractedVersion: "9.9.9",
            codesignResult: .init(status: 2)
        )
        let stager = makeStager(recorder: recorder)

        do {
            _ = try await stager.stage(plan: plan) { _ in }
            XCTFail("expected stage to fail")
        } catch let error as WorkbenchUpdateStager.StageError {
            XCTAssertEqual(error, .codesignFailed("codesign exited 2"))
        }
    }

    func testDefaultInitializerUsesWorkbenchIdentity() {
        let stager = WorkbenchUpdateStager()

        XCTAssertEqual(stager.bundleIdentifier, WorkbenchRelease.bundleIdentifier)
        XCTAssertEqual(stager.currentVersion, WorkbenchRelease.version)
        XCTAssertNil(stager.currentBuild)
        XCTAssertEqual(stager.appName, WorkbenchRelease.appName)
        XCTAssertEqual(stager.userAgent, WorkbenchRelease.userAgent())
    }

    func testStageCanUseDefaultDataLoaderDependency() async throws {
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }

        let temp = try makeTempRoot()
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan(
            archiveURL: URL(string: "https://coverage-batch-2.test/app.zip")!,
            manifestURL: URL(string: "https://coverage-batch-2.test/app.manifest.json")!
        )
        let recorder = StageRecorder(responses: [:], temp: temp)
        let manifest = manifestData(archive: archive)
        CoverageBatch2URLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), WorkbenchRelease.userAgent(version: "9.9.8"))
            let body = request.url == plan.manifestURL ? manifest : archive
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }

        let stager = WorkbenchUpdateStager(
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            currentVersion: "9.9.8",
            currentBuild: "1",
            processRunner: recorder.run(launchPath:arguments:),
            temporaryRoot: { recorder.temp }
        )

        let staged = try await stager.stage(plan: plan) { _ in }

        XCTAssertEqual(staged.stagingRoot, temp)
        XCTAssertEqual(recorder.processCalls.map(\.launchPath), ["/usr/bin/ditto", "/usr/bin/codesign"])
    }

    func testStageCanUseDefaultProcessRunnerDependency() async throws {
        let temp = try makeTempRoot()
        let archive = Data("not-a-real-zip".utf8)
        let plan = makePlan()
        let responses = [
            plan.manifestURL: manifestData(archive: archive),
            plan.archiveURL: archive
        ]
        let stager = WorkbenchUpdateStager(
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            currentVersion: "9.9.8",
            currentBuild: "1",
            dataLoader: { url, _ in responses[url]! },
            temporaryRoot: { temp }
        )

        await XCTAssertStagerThrowsAsync(
            try await stager.stage(plan: plan) { _ in }
        ) { error in
            guard case let .unzipFailed(message) = error as? WorkbenchUpdateStager.StageError else {
                return XCTFail("expected unzipFailed, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testStageCanUseDefaultTemporaryRootDependency() async throws {
        let archive = Data("archive-bytes".utf8)
        let plan = makePlan()
        let recorder = StageRecorder(
            responses: [
                plan.manifestURL: manifestData(archive: archive),
                plan.archiveURL: archive
            ],
            temp: try makeTempRoot()
        )
        let stager = WorkbenchUpdateStager(
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            currentVersion: "9.9.8",
            currentBuild: "1",
            dataLoader: recorder.load(url:userAgent:),
            processRunner: recorder.run(launchPath:arguments:)
        )

        let staged = try await stager.stage(plan: plan) { _ in }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: staged.stagingRoot)
        }

        XCTAssertTrue(staged.stagingRoot.lastPathComponent.hasPrefix("ouro-workbench-update-"))
        XCTAssertNotEqual(staged.stagingRoot, recorder.temp)
    }

    func testStageErrorDescriptions() {
        XCTAssertEqual(
            WorkbenchUpdateStager.StageError.download("offline").errorDescription,
            "Download failed: offline"
        )
        XCTAssertEqual(
            WorkbenchUpdateStager.StageError.manifestDecode("bad json").errorDescription,
            "Could not read the release manifest: bad json"
        )
        XCTAssertEqual(
            WorkbenchUpdateStager.StageError.verification(.byteCountMismatch(expected: 10, got: 9)).errorDescription,
            "Downloaded archive size (9 bytes) did not match the manifest (10 bytes)."
        )
        XCTAssertEqual(
            WorkbenchUpdateStager.StageError.unzipFailed("bad zip").errorDescription,
            "Could not expand the downloaded archive: bad zip"
        )
        XCTAssertEqual(
            WorkbenchUpdateStager.StageError.missingStagedApp.errorDescription,
            "The downloaded archive did not contain \(WorkbenchRelease.appName).app."
        )
        XCTAssertEqual(
            WorkbenchUpdateStager.StageError.stagedIdentityMismatch("wrong app").errorDescription,
            "The downloaded app failed its identity check: wrong app"
        )
        XCTAssertEqual(
            WorkbenchUpdateStager.StageError.codesignFailed("unsigned").errorDescription,
            "The downloaded app failed its code-signature check: unsigned"
        )
    }

    func testDefaultDataLoaderReturnsDataAndSetsUserAgent() async throws {
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }

        CoverageBatch2URLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), WorkbenchRelease.userAgent(version: "9.9.8"))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("fixture".utf8)
            )
        }

        let data = try await WorkbenchUpdateStager.defaultDataLoader(
            url: URL(string: "https://coverage-batch-2.test/app.zip")!,
            userAgent: WorkbenchRelease.userAgent(version: "9.9.8")
        )
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "fixture")
    }

    func testDefaultDataLoaderMapsBadHTTPStatus() async throws {
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }

        CoverageBatch2URLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), WorkbenchRelease.userAgent(version: "9.9.8"))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        await XCTAssertStagerThrowsAsync(
            try await WorkbenchUpdateStager.defaultDataLoader(
                url: URL(string: "https://coverage-batch-2.test/app.zip")!,
                userAgent: WorkbenchRelease.userAgent(version: "9.9.8")
            )
        ) { error in
            XCTAssertEqual(error as? WorkbenchUpdateStager.StageError, .download("app.zip returned HTTP 503"))
        }
    }

    func testDefaultDataLoaderMapsTransportError() async throws {
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }

        CoverageBatch2URLProtocol.error = NSError(domain: "WorkbenchUpdateStagerTests", code: 42)

        await XCTAssertStagerThrowsAsync(
            try await WorkbenchUpdateStager.defaultDataLoader(
                url: URL(string: "https://coverage-batch-2.test/app.zip")!,
                userAgent: WorkbenchRelease.userAgent(version: "9.9.8")
            )
        ) { error in
            guard case let .download(message) = error as? WorkbenchUpdateStager.StageError else {
                return XCTFail("expected download error, got \(error)")
            }
            XCTAssertTrue(message.contains("app.zip:"))
            XCTAssertTrue(message.contains("WorkbenchUpdateStagerTests"))
        }
    }

    func testDefaultProcessRunnerCapturesStatusAndStderr() async throws {
        let result = try await WorkbenchUpdateStager.defaultProcessRunner(
            launchPath: "/bin/sh",
            arguments: ["-c", "printf 'nope' >&2; exit 7"]
        )

        XCTAssertEqual(result, .init(status: 7, stderr: "nope"))
    }

    func testDefaultProcessRunnerFallsBackToEmptyStderrForInvalidUTF8() async throws {
        let result = try await WorkbenchUpdateStager.defaultProcessRunner(
            launchPath: "/bin/sh",
            arguments: ["-c", "printf '\\377' >&2; exit 3"]
        )

        XCTAssertEqual(result, .init(status: 3, stderr: ""))
    }

    func testDefaultProcessRunnerSurfacesLaunchFailure() async {
        await XCTAssertStagerThrowsAsync(
            try await WorkbenchUpdateStager.defaultProcessRunner(
                launchPath: "/definitely/not/a/real/executable",
                arguments: []
            )
        ) { _ in }
    }

    func testDefaultTemporaryRootUsesWorkbenchUpdatePrefix() throws {
        let url = try WorkbenchUpdateStager.defaultTemporaryRoot()

        XCTAssertTrue(url.lastPathComponent.hasPrefix("ouro-workbench-update-"))
    }

    private func makeStager(
        recorder: StageRecorder,
        currentVersion: String = "9.9.8"
    ) -> WorkbenchUpdateStager {
        WorkbenchUpdateStager(
            bundleIdentifier: WorkbenchRelease.bundleIdentifier,
            currentVersion: currentVersion,
            currentBuild: "1",
            dataLoader: recorder.load(url:userAgent:),
            processRunner: recorder.run(launchPath:arguments:),
            temporaryRoot: { recorder.temp }
        )
    }

    private func makePlan(
        archiveURL: URL = URL(string: "https://example.test/app.zip")!,
        manifestURL: URL = URL(string: "https://example.test/app.manifest.json")!
    ) -> WorkbenchUpdatePlan {
        WorkbenchUpdatePlan(
            version: "9.9.9",
            build: "777",
            archiveURL: archiveURL,
            archiveName: "\(WorkbenchRelease.artifactNamePrefix)9.9.9-build.777-abcdef0.zip",
            manifestURL: manifestURL
        )
    }

    private func manifestData(
        archive: Data,
        sha256 forcedSHA: String? = nil,
        bytes forcedBytes: Int? = nil
    ) -> Data {
        Data(
            """
            {
              "appName": "\(WorkbenchRelease.appName)",
              "bundleIdentifier": "\(WorkbenchRelease.bundleIdentifier)",
              "version": "9.9.9",
              "build": "777",
              "archive": "\(WorkbenchRelease.artifactNamePrefix)9.9.9-build.777-abcdef0.zip",
              "sha256": "\(forcedSHA ?? sha256(archive))",
              "bytes": \(forcedBytes ?? archive.count)
            }
            """.utf8
        )
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-update-stager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class StageRecorder: @unchecked Sendable {
    struct Download: Equatable {
        var url: URL
        var userAgent: String
    }

    struct ProcessCall: Equatable {
        var launchPath: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private let responses: [URL: Data]
    let temp: URL
    private let createExtractedApp: Bool
    private let extractedBundleIdentifier: String?
    private let extractedVersion: String?
    private let dittoResult: WorkbenchUpdateStager.ProcessResult
    private let codesignResult: WorkbenchUpdateStager.ProcessResult
    private(set) var downloads: [Download] = []
    private(set) var processCalls: [ProcessCall] = []
    private(set) var progress: [String] = []

    init(
        responses: [URL: Data],
        temp: URL,
        createExtractedApp: Bool = true,
        extractedBundleIdentifier: String? = WorkbenchRelease.bundleIdentifier,
        extractedVersion: String? = "9.9.9",
        dittoResult: WorkbenchUpdateStager.ProcessResult = .init(status: 0),
        codesignResult: WorkbenchUpdateStager.ProcessResult = .init(status: 0)
    ) {
        self.responses = responses
        self.temp = temp
        self.createExtractedApp = createExtractedApp
        self.extractedBundleIdentifier = extractedBundleIdentifier
        self.extractedVersion = extractedVersion
        self.dittoResult = dittoResult
        self.codesignResult = codesignResult
    }

    func load(url: URL, userAgent: String) async throws -> Data {
        lock.withLock {
            downloads.append(Download(url: url, userAgent: userAgent))
        }
        guard let data = responses[url] else {
            throw WorkbenchUpdateStager.StageError.download("missing fixture for \(url.absoluteString)")
        }
        return data
    }

    func recordProgress(_ step: String) {
        lock.withLock {
            progress.append(step)
        }
    }

    func run(launchPath: String, arguments: [String]) async throws -> WorkbenchUpdateStager.ProcessResult {
        lock.withLock {
            processCalls.append(ProcessCall(launchPath: launchPath, arguments: arguments))
        }
        switch launchPath {
        case "/usr/bin/ditto":
            if dittoResult.status == 0 && createExtractedApp {
                try writeExtractedApp(at: URL(fileURLWithPath: arguments[3], isDirectory: true))
            }
            return dittoResult
        case "/usr/bin/codesign":
            return codesignResult
        default:
            return .init(status: 127, stderr: "unexpected process \(launchPath)")
        }
    }

    private func writeExtractedApp(at root: URL) throws {
        let app = root.appendingPathComponent("\(WorkbenchRelease.appName).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: String] = [:]
        if let extractedBundleIdentifier {
            info["CFBundleIdentifier"] = extractedBundleIdentifier
        }
        if let extractedVersion {
            info["CFBundleShortVersionString"] = extractedVersion
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

private func XCTAssertStagerThrowsAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected async expression to throw", file: file, line: line)
    } catch {
        handler(error)
    }
}
