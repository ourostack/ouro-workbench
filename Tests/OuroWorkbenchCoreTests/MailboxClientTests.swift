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
}
