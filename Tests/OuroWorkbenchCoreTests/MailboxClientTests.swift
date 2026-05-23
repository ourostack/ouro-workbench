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
}
