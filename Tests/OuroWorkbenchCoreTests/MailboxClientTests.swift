import XCTest
@testable import OuroWorkbenchCore

final class MailboxClientTests: XCTestCase {
    func testBuildsKnownMailboxEndpoints() throws {
        let client = MailboxClient(configuration: MailboxClientConfiguration(baseURL: URL(string: "http://127.0.0.1:6876")!))

        XCTAssertEqual(try client.url(for: .machine).absoluteString, "http://127.0.0.1:6876/api/machine")
        XCTAssertEqual(try client.url(for: .agent("slugger")).absoluteString, "http://127.0.0.1:6876/api/agents/slugger")
        XCTAssertEqual(try client.url(for: .needsMe("slugger")).absoluteString, "http://127.0.0.1:6876/api/agents/slugger/needs-me")
        XCTAssertEqual(try client.url(for: .coding("slugger")).absoluteString, "http://127.0.0.1:6876/api/agents/slugger/coding")
        XCTAssertEqual(try client.url(for: .sessions("slugger")).absoluteString, "http://127.0.0.1:6876/api/agents/slugger/sessions")
        XCTAssertEqual(try client.url(for: .attention("slugger")).absoluteString, "http://127.0.0.1:6876/api/agents/slugger/attention")
        XCTAssertEqual(try client.url(for: .events).absoluteString, "http://127.0.0.1:6876/api/events")
        XCTAssertEqual(try client.url(for: .agent("ari/slugger")).absoluteString, "http://127.0.0.1:6876/api/agents/ari%2Fslugger")
        XCTAssertEqual(try client.url(for: .habitRunSummaries("ari/slugger", limit: 5)).absoluteString, "http://127.0.0.1:6876/api/agents/ari%2Fslugger/habit-run-summaries?limit=5")
        XCTAssertEqual(try client.url(for: .habitRunSummaries("slugger", limit: nil)).absoluteString, "http://127.0.0.1:6876/api/agents/slugger/habit-run-summaries")
        XCTAssertEqual(try client.url(for: .habitRunSummary("slugger", selector: MailboxHabitSummarySelector(runId: "run 1"))).absoluteString, "http://127.0.0.1:6876/api/agents/slugger/habit-run-summary?runId=run%201")
        XCTAssertEqual(
            try client.url(for: .habitRunSummary(
                "slugger",
                selector: MailboxHabitSummarySelector(habitName: "weekly check", operationId: "habit:weekly/check", which: "latest-success")
            )).absoluteString,
            "http://127.0.0.1:6876/api/agents/slugger/habit-run-summary?habit=weekly%20check&operation-id=habit%3Aweekly%2Fcheck&which=latest-success"
        )
        XCTAssertEqual(try client.url(for: .habitRunSummary("slugger", selector: MailboxHabitSummarySelector())).absoluteString, "http://127.0.0.1:6876/api/agents/slugger/habit-run-summary")
    }

    func testFetchDecodesMachineView() async throws {
        let payload = """
        {
          "overview": {
            "observedAt": "2026-05-23T00:00:00Z",
            "primaryEntryPoint": "http://127.0.0.1:6876",
            "daemon": {
              "status": "running",
              "mode": "dev",
              "mailboxUrl": "http://127.0.0.1:6876"
            },
            "totals": {
              "openObligations": 2,
              "activeCodingAgents": 1,
              "blockedCodingAgents": 0
            }
          },
          "agents": [
            {
              "agentName": "slugger",
              "enabled": true,
              "attention": {
                "level": "active",
                "label": "active"
              },
              "obligations": {
                "openCount": 2
              },
              "coding": {
                "activeCount": 1,
                "blockedCount": 0
              }
            }
          ]
        }
        """
        let client = MailboxClient { url in
            XCTAssertEqual(url.path, "/api/machine")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(payload.utf8), response)
        }

        let view = try await client.fetch(.machine, as: MailboxMachineView.self)

        XCTAssertEqual(view.overview?.totals?.openObligations, 2)
        XCTAssertEqual(view.agents.first?.agentName, "slugger")
        XCTAssertEqual(view.agents.first?.coding?.activeCount, 1)
    }

    func testFetchTimesOutQuickly() async {
        let client = MailboxClient(
            configuration: MailboxClientConfiguration(
                baseURL: URL(string: "http://127.0.0.1:6876")!,
                requestTimeoutNanoseconds: 10_000_000
            )
        ) { _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            throw MailboxClientError.invalidURL
        }

        await XCTAssertThrowsErrorAsync(try await client.fetch(.machine, as: MailboxMachineView.self)) { error in
            XCTAssertEqual(error as? MailboxClientError, .timeout)
        }
    }

    func testFetchReportsBadHTTPStatus() async {
        let client = MailboxClient { url in
            let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"agents":[]}"#.utf8), response)
        }

        await XCTAssertThrowsErrorAsync(try await client.fetch(.machine, as: MailboxMachineView.self)) { error in
            XCTAssertEqual(error as? MailboxClientError, .badStatus(503))
        }
    }

    func testMailboxClientErrorDescriptions() {
        XCTAssertEqual(MailboxClientError.invalidURL.errorDescription, "The Ouro mailbox URL is invalid.")
        XCTAssertEqual(MailboxClientError.badStatus(418).errorDescription, "The Ouro mailbox returned HTTP 418.")
        XCTAssertEqual(MailboxClientError.timeout.errorDescription, "The Ouro mailbox did not answer before the Workbench timeout.")
    }

    func testDefaultDataLoaderRejectsNonHTTPResponses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailboxClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("payload.json")
        try Data(#"{"ok":true}"#.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: root) }

        await XCTAssertThrowsErrorAsync(try await MailboxClient.defaultDataLoader(url: fileURL)) { error in
            XCTAssertEqual(error as? MailboxClientError, .invalidURL)
        }
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ errorHandler: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }

    func testDecodesNeedsMeAndCodingViews() throws {
        let needsMeJSON = """
        {
          "items": [
            {
              "urgency": "blocking-obligation",
              "label": "Review PR",
              "detail": "waiting for merge decision",
              "ref": { "tab": "work", "focus": "obl_1" },
              "ageMs": 42
            }
          ]
        }
        """
        let codingJSON = """
        {
          "totalCount": 1,
          "activeCount": 1,
          "blockedCount": 0,
          "items": [
            {
              "id": "codex-1",
              "runner": "codex",
              "status": "running",
              "workdir": "/repo",
              "lastActivityAt": "2026-05-23T00:00:00Z",
              "checkpoint": "tests green",
              "taskRef": "task.md"
            }
          ]
        }
        """

        let needsMe = try JSONDecoder().decode(MailboxNeedsMeView.self, from: Data(needsMeJSON.utf8))
        let coding = try JSONDecoder().decode(MailboxCodingSummary.self, from: Data(codingJSON.utf8))

        XCTAssertEqual(needsMe.items.first?.label, "Review PR")
        XCTAssertEqual(needsMe.items.first?.ref?.focus, "obl_1")
        XCTAssertEqual(coding.items.first?.runner, "codex")
        XCTAssertEqual(coding.items.first?.checkpoint, "tests green")
        XCTAssertEqual(needsMe.items.first?.id, "blocking-obligation-Review PR-waiting for merge decision")
        XCTAssertEqual(MailboxNavigationRef(tab: "work", focus: "obl_1"), needsMe.items.first?.ref)
    }

    func testMailboxModelInitializersExposeStoredValues() {
        let ref = MailboxNavigationRef(tab: "habit", focus: nil)
        let message = MailboxHabitSummaryMessage(recipient: "ari", channel: "sms", result: "queued")
        let produced = MailboxHabitSummaryProducedRef(kind: "receipt", locator: "receipts/run.json")

        XCTAssertEqual(ref.tab, "habit")
        XCTAssertNil(ref.focus)
        XCTAssertEqual(message.recipient, "ari")
        XCTAssertEqual(message.channel, "sms")
        XCTAssertEqual(message.result, "queued")
        XCTAssertEqual(produced.kind, "receipt")
        XCTAssertEqual(produced.locator, "receipts/run.json")
    }

    func testDecodesHabitSessionSummaryView() throws {
        let payload = """
        {
          "totalCount": 1,
          "limit": 5,
          "items": [
            {
              "runId": "run-http-summary",
              "habitName": "heartbeat",
              "operationId": "habit:heartbeat",
              "status": "surfaced",
              "triggeredAt": "2026-06-11T10:00:00.000Z",
              "completedAt": "2026-06-11T10:01:00.000Z",
              "summary": "Queued an iMessage and recorded the route.",
              "decisions": ["keep the route"],
              "pending": { "count": 1, "files": ["reply.json"] },
              "messagesSent": [
                { "recipient": "ari", "channel": "bluebubbles", "result": "queued" }
              ],
              "toolsUsed": ["send_message"],
              "producedRefs": [
                { "kind": "surface", "locator": "surface/ari/bluebubbles" }
              ],
              "errors": [],
              "warnings": [],
              "nextLikelyStep": "inspect iMessage delivery",
              "sources": {
                "receipt": "arc/flight-recorder/habit-receipts/run-http-summary.json",
                "session": "state/habit-sessions/run-http-summary/session.json",
                "pending": "state/habit-sessions/run-http-summary/pending",
                "runtimeState": "state/habits/heartbeat.json"
              }
            }
          ]
        }
        """

        let view = try JSONDecoder().decode(MailboxHabitSessionSummaryView.self, from: Data(payload.utf8))

        XCTAssertEqual(view.totalCount, 1)
        XCTAssertEqual(view.limit, 5)
        XCTAssertEqual(view.items.first?.id, "run-http-summary")
        XCTAssertEqual(view.items.first?.operationId, "habit:heartbeat")
        XCTAssertEqual(view.items.first?.pending.count, 1)
        XCTAssertEqual(view.items.first?.messagesSent.first?.channel, "bluebubbles")
        XCTAssertEqual(view.items.first?.producedRefs.first?.locator, "surface/ari/bluebubbles")
        XCTAssertEqual(view.items.first?.sources.receipt, "arc/flight-recorder/habit-receipts/run-http-summary.json")
    }

    func testFetchesHabitSessionSummaryViewFromExpectedEndpoint() async throws {
        let payload = """
        {
          "totalCount": 0,
          "limit": 2,
          "items": []
        }
        """
        let client = MailboxClient { url in
            XCTAssertEqual(url.path, "/api/agents/slugger/habit-run-summaries")
            XCTAssertEqual(url.query, "limit=2")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(payload.utf8), response)
        }

        let view = try await client.fetch(.habitRunSummaries("slugger", limit: 2), as: MailboxHabitSessionSummaryView.self)

        XCTAssertEqual(view.totalCount, 0)
        XCTAssertTrue(view.items.isEmpty)
    }

    func testSyncDashboardReaderCarriesHabitHistoryForMCPStatus() {
        let reader = MailboxDashboardSnapshotReader(
            configuration: MailboxClientConfiguration(baseURL: URL(string: "http://127.0.0.1:6876")!),
            dataLoader: { url, _ in
                switch (url.path, url.query) {
                case ("/api/machine", _):
                    return (Data(Self.machinePayload.utf8), 200)
                case ("/api/agents/slugger/needs-me", _):
                    return (Data(#"{"items":[]}"#.utf8), 200)
                case ("/api/agents/slugger/coding", _):
                    return (Data(#"{"totalCount":0,"activeCount":0,"blockedCount":0,"items":[]}"#.utf8), 200)
                case ("/api/agents/slugger/habit-run-summaries", "limit=5"):
                    return (Data(Self.habitHistoryPayload.utf8), 200)
                default:
                    XCTFail("unexpected endpoint \(url.absoluteString)")
                    return (Data(), 404)
                }
            }
        )

        let snapshot = reader.read(boss: BossAgentSelection(agentName: "slugger"))

        XCTAssertEqual(snapshot.daemonStatus, "running")
        XCTAssertTrue(snapshot.habitHistory.isAvailable)
        XCTAssertEqual(snapshot.habitHistory.rows.map(\.habitName), ["heartbeat"])
        XCTAssertEqual(snapshot.habitHistory.rows.first?.summary, "Queued an iMessage and recorded the route.")
    }

    func testSyncDashboardReaderMarksHabitHistoryUnavailableOnEndpointFailure() {
        let reader = MailboxDashboardSnapshotReader(
            configuration: MailboxClientConfiguration(baseURL: URL(string: "http://127.0.0.1:6876")!),
            dataLoader: { url, _ in
                switch url.path {
                case "/api/machine":
                    return (Data(Self.machinePayload.utf8), 200)
                case "/api/agents/slugger/needs-me":
                    return (Data(#"{"items":[]}"#.utf8), 200)
                case "/api/agents/slugger/coding":
                    return (Data(#"{"totalCount":0,"activeCount":0,"blockedCount":0,"items":[]}"#.utf8), 200)
                case "/api/agents/slugger/habit-run-summaries":
                    return (Data(), 503)
                default:
                    return (Data(), 404)
                }
            }
        )

        let snapshot = reader.read(boss: BossAgentSelection(agentName: "slugger"))

        XCTAssertFalse(snapshot.habitHistory.isAvailable)
        XCTAssertTrue(snapshot.habitHistory.rows.isEmpty)
        XCTAssertTrue(snapshot.habitHistory.statusMessage?.contains("Habit history unavailable: habit-history:") == true)
        XCTAssertTrue(snapshot.availability.issues.contains { $0.hasPrefix("habit-history:") })
    }

    func testDecodesHabitSessionSummaryWithNullOptionalsAndFailsOnMalformedItems() throws {
        let sparsePayload = """
        {
          "totalCount": 1,
          "limit": 20,
          "items": [
            {
              "runId": "run-fallback",
              "habitName": "heartbeat",
              "operationId": null,
              "status": "surfaced",
              "triggeredAt": "2026-06-11T10:00:00.000Z",
              "completedAt": "2026-06-11T10:01:00.000Z",
              "summary": "Habit heartbeat finished with surfaced.",
              "decisions": [],
              "pending": { "count": 0, "files": [] },
              "messagesSent": [],
              "toolsUsed": [],
              "producedRefs": [],
              "errors": [],
              "warnings": ["session file missing"],
              "nextLikelyStep": null,
              "sources": {
                "receipt": "arc/flight-recorder/habit-receipts/run-fallback.json",
                "session": "state/habit-sessions/run-fallback/session.json",
                "pending": "state/habit-sessions/run-fallback/pending",
                "runtimeState": "state/habits/heartbeat.json"
              }
            }
          ]
        }
        """
        let sparse = try JSONDecoder().decode(MailboxHabitSessionSummaryView.self, from: Data(sparsePayload.utf8))

        XCTAssertNil(sparse.items.first?.operationId)
        XCTAssertNil(sparse.items.first?.nextLikelyStep)
        XCTAssertEqual(sparse.items.first?.warnings, ["session file missing"])

        let malformed = """
        {
          "totalCount": 1,
          "limit": 20,
          "items": [
            { "runId": "missing-required-fields" }
          ]
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(MailboxHabitSessionSummaryView.self, from: Data(malformed.utf8)))
    }

    private static let machinePayload = """
    {
      "overview": {
        "observedAt": "2026-05-23T00:00:00Z",
        "primaryEntryPoint": "http://127.0.0.1:6876",
        "daemon": {
          "status": "running",
          "mode": "dev",
          "mailboxUrl": "http://127.0.0.1:6876"
        },
        "totals": {
          "openObligations": 0,
          "activeCodingAgents": 0,
          "blockedCodingAgents": 0
        }
      },
      "agents": [
        {
          "agentName": "slugger",
          "enabled": true,
          "attention": {
            "level": "active",
            "label": "active"
          },
          "obligations": {
            "openCount": 0
          },
          "coding": {
            "activeCount": 0,
            "blockedCount": 0
          }
        }
      ]
    }
    """

    private static let habitHistoryPayload = """
    {
      "totalCount": 1,
      "limit": 5,
      "items": [
        {
          "runId": "run-http-summary",
          "habitName": "heartbeat",
          "operationId": "habit:heartbeat",
          "status": "surfaced",
          "triggeredAt": "2026-06-11T10:00:00.000Z",
          "completedAt": "2026-06-11T10:01:00.000Z",
          "summary": "Queued an iMessage and recorded the route.",
          "decisions": ["keep the route"],
          "pending": { "count": 1, "files": ["reply.json"] },
          "messagesSent": [
            { "recipient": "ari", "channel": "bluebubbles", "result": "queued" }
          ],
          "toolsUsed": ["send_message"],
          "producedRefs": [
            { "kind": "surface", "locator": "surface/ari/bluebubbles" }
          ],
          "errors": [],
          "warnings": [],
          "nextLikelyStep": "inspect iMessage delivery",
          "sources": {
            "receipt": "arc/flight-recorder/habit-receipts/run-http-summary.json",
            "session": "state/habit-sessions/run-http-summary/session.json",
            "pending": "state/habit-sessions/run-http-summary/pending",
            "runtimeState": "state/habits/heartbeat.json"
          }
        }
      ]
    }
    """
}
