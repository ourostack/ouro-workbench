import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBuildsTypedUnavailableWorkCardWithoutFalseZeroes() throws {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let running = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            attention: .waitingOnHuman
        )
        let blocked = ProcessEntry(
            projectId: project.id,
            name: "Claude",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/repo",
            attention: .blocked
        )
        let archived = ProcessEntry(
            projectId: project.id,
            name: "Old",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            isArchived: true,
            attention: .waitingOnHuman
        )
        let decision = BossInboxDecision(
            source: "boss:slugger",
            entryId: running.id,
            sessionName: running.name,
            prompt: "SECRET transcript text must not leak",
            kind: .escalate,
            reasoning: "needs a human"
        )
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            projects: [project],
            processEntries: [running, blocked, archived],
            processRuns: [
                ProcessRun(entryId: running.id, status: .running, startedAt: now, transcriptPath: "/tmp/transcript-secret.log"),
                ProcessRun(entryId: blocked.id, status: .needsRecovery, startedAt: now.addingTimeInterval(-10))
            ],
            actionLog: [
                WorkbenchActionLogEntry(source: "native", action: "refresh", result: "ok", succeeded: true),
                WorkbenchActionLogEntry(source: "boss", action: "sendInput", result: "denied", succeeded: false)
            ],
            decisionLog: [decision]
        )

        let snapshot = WorkbenchVisibilityBuilder().build(
            state: state,
            workCard: .unavailable(WorkbenchVisibilityIssue(
                code: "work_card_unreadable",
                severity: "unavailable",
                source: "ouro work card",
                detail: "command missing"
            )),
            now: now
        )

        XCTAssertEqual(snapshot.workspace.activeSessions, 2)
        XCTAssertEqual(snapshot.workspace.runningSessions, 1)
        XCTAssertEqual(snapshot.workspace.waitingOnHumanSessions, 1)
        XCTAssertEqual(snapshot.workspace.blockedSessions, 1)
        XCTAssertEqual(snapshot.workspace.recoverableSessions, 1)
        XCTAssertEqual(snapshot.decisions.openInbox, 1)
        XCTAssertEqual(snapshot.decisions.recentActions, 2)
        XCTAssertEqual(snapshot.decisions.failedRecentActions, 1)
        XCTAssertEqual(snapshot.agentWork.status, .unavailable)
        XCTAssertNil(snapshot.agentWork.counts.owed)
        XCTAssertNil(snapshot.agentWork.counts.unverifiedClaims)
        XCTAssertFalse(snapshot.agentWork.claims.available)
        XCTAssertEqual(snapshot.readiness.status, .degraded)

        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let agentWork = try XCTUnwrap(object["agentWork"] as? [String: Any])
        let counts = try XCTUnwrap(agentWork["counts"] as? [String: Any])
        XCTAssertTrue(counts["unverifiedClaims"] is NSNull)
        XCTAssertTrue(counts["staleRiskyClaims"] is NSNull)
        XCTAssertTrue(agentWork["generatedAt"] is NSNull)
        XCTAssertTrue(agentWork["projectionOwner"] is NSNull)
        let claims = try XCTUnwrap(agentWork["claims"] as? [String: Any])
        XCTAssertTrue(claims["unverified"] is NSNull)
        let nextAction = try XCTUnwrap(agentWork["nextAction"] as? [String: Any])
        XCTAssertTrue(nextAction["source"] is NSNull)

        let rendered = WorkbenchVisibilityTextRenderer().render(snapshot)
        XCTAssertTrue(rendered.contains("owed=unknown"))
        XCTAssertTrue(rendered.contains("Claims: unavailable"))
        XCTAssertFalse(rendered.contains("SECRET transcript text"))
        XCTAssertFalse(rendered.contains("/tmp/transcript-secret.log"))
    }

    func testDecodesHarnessWorkCardAndPreservesUnavailableClaims() throws {
        let data = Data(sampleWorkCardJSON.utf8)
        let card = try JSONDecoder().decode(OuroWorkCard.self, from: data)

        let snapshot = WorkbenchVisibilityBuilder().build(
            state: WorkspaceState(boss: BossAgentSelection(agentName: "slugger")),
            workCard: .degraded(card),
            now: now
        )

        XCTAssertEqual(snapshot.agentWork.status, .degraded)
        XCTAssertEqual(snapshot.agentWork.projectionOwner, "arc/work-card")
        XCTAssertEqual(snapshot.agentWork.counts.owed, 2)
        XCTAssertEqual(snapshot.agentWork.counts.unverifiedClaims, nil)
        XCTAssertFalse(snapshot.agentWork.claims.available)
        XCTAssertNil(snapshot.agentWork.claims.unverified)
        XCTAssertEqual(snapshot.agentWork.claims.unavailableReason, "Claim ledger is not wired yet.")
        XCTAssertTrue(snapshot.readiness.issues.contains { $0.code == "claims_unavailable" })
        XCTAssertEqual(snapshot.readiness.issues.filter { $0.code == "claims_unavailable" }.count, 1)
        XCTAssertEqual(snapshot.agentWork.nextAction.summary, "Review redacted Work Card source: arc/packets/broken.json.")

        let text = WorkbenchVisibilityTextRenderer().render(snapshot)
        XCTAssertTrue(text.contains("unverified_claims=unknown"))
        XCTAssertTrue(text.contains("arc_json_unreadable"))
        XCTAssertFalse(text.contains("Review the malformed packet."))
    }

    func testWorkCardReaderDecodesJSONAndReportsFailures() {
        let sample = sampleWorkCardJSON
        let goodReader = OuroWorkCardReader(runner: { _, _, _ in
            WorkCardCommandResult(exitCode: 0, stdout: sample, stderr: "")
        })

        switch goodReader.read(agent: " slugger ") {
        case let .degraded(card):
            XCTAssertEqual(card.agent, "slugger")
        default:
            XCTFail("Expected degraded Work Card")
        }

        let failingReader = OuroWorkCardReader(runner: { _, _, _ in
            WorkCardCommandResult(exitCode: 1, stdout: "", stderr: "boom")
        })
        switch failingReader.read(agent: "slugger") {
        case let .unavailable(issue):
            XCTAssertEqual(issue.code, "work_card_command_failed")
            XCTAssertEqual(issue.detail, "ouro work card exited 1: boom")
        default:
            XCTFail("Expected unavailable Work Card")
        }

        switch goodReader.read(agent: "../slugger") {
        case let .unavailable(issue):
            XCTAssertEqual(issue.code, "invalid_agent_name")
        default:
            XCTFail("Expected invalid agent name to be rejected before command execution")
        }
    }

    private var sampleWorkCardJSON: String {
        """
        {
          "schemaVersion": 1,
          "projection": {
            "owner": "arc/work-card",
            "scope": "durable-arc-work",
            "relationToActiveWorkFrame": "complements-live-turn-frame"
          },
          "agent": "slugger",
          "generatedAt": "2026-06-08T12:00:00.000Z",
          "degraded": {
            "status": "degraded",
            "issues": [
              {
                "code": "arc_json_unreadable",
                "severity": "degraded",
                "source": {
                  "kind": "ponder_packet",
                  "locator": "arc/packets/broken.json",
                  "freshness": "unknown",
                  "redaction": "summary"
                },
                "detail": "arc/packets/broken.json could not be parsed"
              },
              {
                "code": "claims_unavailable",
                "severity": "unavailable",
                "source": {
                  "kind": "claim_store",
                  "locator": "arc/claims",
                  "freshness": "unknown",
                  "redaction": "private_ref"
                },
                "detail": "Claim ledger is not wired yet."
              }
            ]
          },
          "counts": {
            "owed": 2,
            "returnObligations": 1,
            "activePackets": 1,
            "evolutionCases": 1,
            "waitingOnHuman": 1,
            "unverifiedClaims": null,
            "staleRiskyClaims": null
          },
          "claims": {
            "available": false,
            "unavailableReason": "Claim ledger is not wired yet.",
            "counts": {
              "unverified": null,
              "partial": null,
              "failed": null,
              "unverifiable": null,
              "staleRisky": null,
              "verified": null
            },
            "items": []
          },
          "nextAction": {
            "actor": "agent",
            "summary": "Review the malformed packet.",
            "source": {
              "kind": "ponder_packet",
              "locator": "arc/packets/broken.json",
              "freshness": "unknown",
              "redaction": "summary"
            }
          },
          "sources": [
            {
              "kind": "obligation",
              "locator": "arc/obligations/owed.json",
              "freshness": "current",
              "redaction": "summary"
            }
          ],
          "currentAsk": {
            "available": false,
            "source": "not_tracked_yet",
            "confidence": "unknown"
          },
          "owed": [],
          "returnObligations": [],
          "activeWork": [],
          "waitingOnOthers": [],
          "capabilityHealth": {
            "available": true
          }
        }
        """
    }
}
