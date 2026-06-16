import XCTest
@testable import OuroWorkbenchCore

final class MailboxDashboardSnapshotReaderTests: XCTestCase {
    func testDefaultInitializerCanBuildUnavailableSnapshotFromInjectedFailures() {
        let defaultReader = MailboxDashboardSnapshotReader()
        XCTAssertEqual(defaultReader.configuration.requestTimeoutNanoseconds, 1_000_000_000)
        let configuration = MailboxClientConfiguration(
            baseURL: URL(string: "https://coverage-batch-2.test")!,
            requestTimeoutNanoseconds: 123
        )
        let configuredReader = MailboxDashboardSnapshotReader(configuration: configuration)
        XCTAssertEqual(configuredReader.configuration, configuration)
        let reader = MailboxDashboardSnapshotReader(dataLoader: { _, _ in
            throw MailboxClientError.timeout
        })

        let snapshot = reader.read(boss: BossAgentSelection(agentName: "slugger"))

        XCTAssertFalse(snapshot.availability.machineAvailable)
        XCTAssertTrue(snapshot.availability.issues.contains { $0.contains("machine:") && $0.contains("timeout") })
        XCTAssertTrue(snapshot.availability.issues.contains { $0.contains("needs-me:") && $0.contains("timeout") })
    }

    func testInjectedLoaderBadStatusAndBadJSONBecomeSectionIssues() {
        let reader = MailboxDashboardSnapshotReader(dataLoader: { url, _ in
            if url.path.contains("coding") {
                return (Data("not-json".utf8), 200)
            }
            return (Data("{}".utf8), 503)
        })

        let snapshot = reader.read(boss: BossAgentSelection(agentName: "slugger"))

        XCTAssertTrue(snapshot.availability.issues.contains { $0.contains("machine:") && $0.contains("HTTP 503") })
        XCTAssertTrue(snapshot.availability.issues.contains { $0.contains("coding:") })
    }

    func testDefaultDataLoaderHandlesHTTPErrorInvalidResponseErrorAndTimeout() throws {
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }
        let url = URL(string: "https://coverage-batch-2.test/api/machine")!

        CoverageBatch2URLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                Data(#"{"ok":true}"#.utf8)
            )
        }
        let success = try MailboxDashboardSnapshotReader.defaultDataLoader(url: url, timeoutSeconds: 0.1)
        XCTAssertEqual(success.1, 202)
        XCTAssertEqual(String(decoding: success.0, as: UTF8.self), #"{"ok":true}"#)

        CoverageBatch2URLProtocol.handler = { request in
            let body: String
            if request.url?.path == "/api/machine" {
                body = #"{"overview":null,"agents":[]}"#
            } else if request.url?.path.contains("needs-me") == true {
                body = #"{"items":[]}"#
            } else if request.url?.path.contains("coding") == true {
                body = #"{"totalCount":0,"activeCount":0,"blockedCount":0,"items":[]}"#
            } else {
                body = #"{"totalCount":0,"limit":5,"items":[]}"#
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let configuredReader = MailboxDashboardSnapshotReader(configuration: MailboxClientConfiguration(
            baseURL: URL(string: "https://coverage-batch-2.test")!,
            requestTimeoutNanoseconds: 100_000_000
        ))
        let configuredSnapshot = configuredReader.read(boss: BossAgentSelection(agentName: "slugger"))
        XCTAssertTrue(configuredSnapshot.availability.machineAvailable)

        CoverageBatch2URLProtocol.error = CoverageBatch2Error.boom
        XCTAssertThrowsError(try MailboxDashboardSnapshotReader.defaultDataLoader(url: url, timeoutSeconds: 0.1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("CoverageBatch2Error"))
        }
        CoverageBatch2URLProtocol.error = nil

        CoverageBatch2URLProtocol.handler = { request in
            (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        XCTAssertThrowsError(try MailboxDashboardSnapshotReader.defaultDataLoader(url: url, timeoutSeconds: 0.1)) { error in
            XCTAssertEqual(error as? MailboxClientError, .invalidURL)
        }

        CoverageBatch2URLProtocol.shouldHang = true
        XCTAssertThrowsError(try MailboxDashboardSnapshotReader.defaultDataLoader(url: url, timeoutSeconds: 0.0)) { error in
            XCTAssertEqual(error as? MailboxClientError, .timeout)
        }
    }

    func testSyncDataLoaderCoversNilDataInvalidResponseAndMissingResult() throws {
        let url = URL(string: "https://coverage-batch-2.test/api/machine")!

        let nilDataSuccess = try MailboxDashboardSnapshotReader.syncDataLoader(
            url: url,
            timeoutSeconds: 1,
            makeTask: { request, completion in
                MailboxDashboardSnapshotReader.MailboxSyncTask(
                    resume: {
                        completion(nil, HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil), nil)
                    },
                    cancel: {}
                )
            }
        )
        XCTAssertEqual(nilDataSuccess.0, Data())
        XCTAssertEqual(nilDataSuccess.1, 204)

        XCTAssertThrowsError(try MailboxDashboardSnapshotReader.syncDataLoader(
            url: url,
            timeoutSeconds: 1,
            makeTask: { _, completion in
                MailboxDashboardSnapshotReader.MailboxSyncTask(resume: { completion(nil, nil, nil) }, cancel: {})
            }
        )) { error in
            XCTAssertEqual(error as? MailboxClientError, .invalidURL)
        }

        XCTAssertThrowsError(try MailboxDashboardSnapshotReader.syncDataLoader(
            url: url,
            timeoutSeconds: 1,
            makeTask: { _, _ in MailboxDashboardSnapshotReader.MailboxSyncTask(resume: {}, cancel: {}) },
            waitOverride: { _, _ in .success }
        )) { error in
            XCTAssertEqual(error as? MailboxClientError, .timeout)
        }

        XCTAssertThrowsError(try MailboxDashboardSnapshotReader.resolvedURL(
            path: "http://%",
            baseURL: URL(string: "https://coverage-batch-2.test")!
        )) { error in
            XCTAssertEqual(error as? MailboxClientError, .invalidURL)
        }
    }
}
