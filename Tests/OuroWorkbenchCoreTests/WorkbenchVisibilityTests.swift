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
        // #U28: recoverable is now sourced from the recovery PLANS, not raw
        // `.needsRecovery` status. This needs-recovery entry is trusted but has
        // auto-resume OFF, so its plan is `.noAction` — there's nothing the boss
        // OR the operator can recover, so it correctly reads 0 (the old raw-status
        // count falsely reported 1).
        XCTAssertEqual(snapshot.workspace.recoverableSessions, 0)
        XCTAssertEqual(snapshot.workspace.recovery.reattach, 0)
        XCTAssertEqual(snapshot.workspace.recovery.autoResume, 0)
        XCTAssertEqual(snapshot.workspace.recovery.respawn, 0)
        XCTAssertEqual(snapshot.workspace.recovery.needsHuman, 0)
        XCTAssertEqual(snapshot.workspace.recovery.bossActionable, 0)
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
        let fakeRoot = try! coverageBatch2TemporaryDirectory()
        let oldPath = try! coverageBatch2InstallFakeOuro(
            in: fakeRoot,
            body: "cat <<'JSON'\n\(availableWorkCardJSON)\nJSON\n"
        )
        defer {
            setenv("PATH", oldPath, 1)
            try? FileManager.default.removeItem(at: fakeRoot)
        }

        let defaultReader = OuroWorkCardReader()
        if case let .available(card) = defaultReader.read(agent: "slugger") {
            XCTAssertEqual(card.agent, "slugger")
        } else {
            XCTFail("Expected default reader to execute the PATH-resolved ouro work card command")
        }
        let configuredDefaultRunner = OuroWorkCardReader(executable: "/usr/bin/env", timeout: 1)
        if case let .available(card) = configuredDefaultRunner.read(agent: "slugger") {
            XCTAssertEqual(card.claims.counts.verified, 7)
        } else {
            XCTFail("Expected configured reader to execute the default runner")
        }

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

        let available = availableWorkCardJSON
        let availableReader = OuroWorkCardReader(runner: { _, _, _ in
            WorkCardCommandResult(exitCode: 0, stdout: available, stderr: "")
        })
        switch availableReader.read(agent: "slugger") {
        case let .available(card):
            XCTAssertEqual(card.claims.counts.verified, 7)
        default:
            XCTFail("Expected non-degraded Work Card to be available")
        }

        var warningOnlyCard = try! JSONDecoder().decode(OuroWorkCard.self, from: Data(availableWorkCardJSON.utf8))
        warningOnlyCard.degraded.issues = [
            OuroWorkCardIssue(
                code: "notice",
                severity: "warning",
                source: OuroWorkCardSource(kind: "notice", locator: "arc/notice.json", freshness: "fresh", redaction: "summary"),
                detail: "Advisory issue should not degrade the Work Card."
            )
        ]
        let warningOnlyData = try! JSONEncoder().encode(warningOnlyCard)
        let warningOnlyReader = OuroWorkCardReader(runner: { _, _, _ in
            WorkCardCommandResult(exitCode: 0, stdout: String(decoding: warningOnlyData, as: UTF8.self), stderr: "")
        })
        switch warningOnlyReader.read(agent: "slugger") {
        case let .available(card):
            XCTAssertEqual(card.degraded.issues.first?.severity, "warning")
        default:
            XCTFail("Expected warning-only Work Card issues to remain available")
        }

        let emptyStderrReader = OuroWorkCardReader(runner: { _, _, _ in
            WorkCardCommandResult(exitCode: 2, stdout: "", stderr: "")
        })
        switch emptyStderrReader.read(agent: "slugger") {
        case let .unavailable(issue):
            XCTAssertEqual(issue.detail, "ouro work card exited 2.")
        default:
            XCTFail("Expected command failure without stderr")
        }

        let throwingReader = OuroWorkCardReader(runner: { _, _, _ in
            throw NSError(
                domain: "coverage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(FileManager.default.homeDirectoryForCurrentUser.path)\n\n\nsecret" + String(repeating: "x", count: 600)]
            )
        })
        switch throwingReader.read(agent: "slugger") {
        case let .unavailable(issue):
            XCTAssertTrue(issue.detail.contains("~"))
            XCTAssertFalse(issue.detail.contains("\n\n\n"))
            XCTAssertTrue(issue.detail.hasSuffix("..."))
        default:
            XCTFail("Expected thrown runner errors to become sanitized issues")
        }
    }

    func testVisibilityCodableRoundTripsNullableAndPresentOptionalFields() throws {
        let source = OuroWorkCardSource(kind: "claim", locator: "arc/claim.json", freshness: "fresh", redaction: "none")
        let visibility = AgentWorkVisibility(
            status: .available,
            agent: "slugger",
            generatedAt: "2026-01-01T00:00:00Z",
            projectionOwner: "arc",
            counts: AgentWorkCountsVisibility(
                owed: 1,
                returnObligations: 2,
                activePackets: 3,
                evolutionCases: 4,
                waitingOnHuman: 5,
                unverifiedClaims: 6,
                staleRiskyClaims: 7
            ),
            claims: AgentWorkClaimsVisibility(
                available: true,
                unavailableReason: "partial ledger",
                unverified: 8,
                partial: 9,
                failed: 10,
                unverifiable: 11,
                staleRisky: 12,
                verified: 13
            ),
            nextAction: AgentWorkNextActionVisibility(actor: "agent", summary: "Act", source: source),
            sources: [source],
            issues: [WorkbenchVisibilityIssue(code: "warn", severity: "degraded", source: "arc", detail: "detail")]
        )

        let decoded = try JSONDecoder().decode(AgentWorkVisibility.self, from: JSONEncoder().encode(visibility))

        XCTAssertEqual(decoded, visibility)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(visibility)) as? [String: Any])
        XCTAssertEqual(object["generatedAt"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual((object["nextAction"] as? [String: Any])?["summary"] as? String, "Act")
    }

    func testBuilderMapsAvailableWorkCardAndMostRecentRuns() throws {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(projectId: project.id, name: "Codex", kind: .terminalAgent, executable: "codex", workingDirectory: "/repo")
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            projects: [project],
            processEntries: [entry],
            processRuns: [
                ProcessRun(entryId: entry.id, status: .needsRecovery, startedAt: now),
                ProcessRun(entryId: entry.id, status: .running, startedAt: now.addingTimeInterval(10))
            ]
        )
        let card = try JSONDecoder().decode(OuroWorkCard.self, from: Data(availableWorkCardJSON.utf8))

        let snapshot = WorkbenchVisibilityBuilder().build(state: state, workCard: .available(card), now: now)

        XCTAssertEqual(snapshot.readiness.status, .available)
        XCTAssertEqual(snapshot.workspace.runningSessions, 1)
        XCTAssertEqual(snapshot.workspace.recoverableSessions, 0)
        XCTAssertEqual(snapshot.agentWork.status, .available)
        XCTAssertEqual(snapshot.agentWork.claims.verified, 7)
        XCTAssertEqual(snapshot.agentWork.nextAction.summary, "Proceed with the packet.")

        let text = WorkbenchVisibilityTextRenderer().render(snapshot)
        XCTAssertTrue(text.contains("Claims: available"))
        XCTAssertTrue(text.contains("owed=3"))
    }

    func testRecoveryBreakdownSourcesFromPlansNotRawStatus() throws {
        // #U28: a live reattach + an auto-resumable agent + a respawn vs an
        // untrusted manual-action session — the boss-facing scalar must split them
        // by class (and a needs-human one is NOT counted as boss-actionable).
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        // Reattach: trusted, its screen session is live.
        let reattach = ProcessEntry(projectId: project.id, name: "Live", kind: .terminalAgent, agentKind: .claudeCode, executable: "claude", workingDirectory: "/repo", trust: .trusted, autoResume: true)
        // Auto-resume: trusted + autoResume, native-resume metadata present.
        let resume = ProcessEntry(projectId: project.id, name: "Resumable", kind: .terminalAgent, agentKind: .claudeCode, executable: "claude", workingDirectory: "/repo", trust: .trusted, autoResume: true)
        // Needs-human: untrusted, so the plan is manualActionNeeded.
        let manual = ProcessEntry(projectId: project.id, name: "Untrusted", kind: .terminalAgent, agentKind: .claudeCode, executable: "claude", workingDirectory: "/repo", trust: .untrusted, autoResume: true)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            projects: [project],
            processEntries: [reattach, resume, manual],
            processRuns: [
                ProcessRun(entryId: reattach.id, status: .needsRecovery, startedAt: now),
                ProcessRun(entryId: resume.id, status: .needsRecovery, startedAt: now, terminalSessionId: "sess-123"),
                ProcessRun(entryId: manual.id, status: .needsRecovery, startedAt: now)
            ]
        )

        let snapshot = WorkbenchVisibilityBuilder().build(
            state: state,
            workCard: .unavailable(WorkbenchVisibilityIssue(code: "x", severity: "unavailable", source: "s", detail: "d")),
            now: now,
            liveSessionNames: [PersistentTerminalSession.sessionName(for: reattach.id)]
        )

        XCTAssertEqual(snapshot.workspace.recovery.reattach, 1)
        XCTAssertEqual(snapshot.workspace.recovery.autoResume, 1)
        XCTAssertEqual(snapshot.workspace.recovery.needsHuman, 1)
        // boss may self-trigger reattach + auto_resume + respawn, NOT needs_human.
        XCTAssertEqual(snapshot.workspace.recovery.bossActionable, 2)
        // recoverable total sums every class (matches the digest's actionable total).
        XCTAssertEqual(snapshot.workspace.recoverableSessions, 3)

        let text = WorkbenchVisibilityTextRenderer().render(snapshot)
        XCTAssertTrue(text.contains("Recovery: reattach=1 auto_resume=1 respawn=0 needs_human=1 boss_actionable=2"), "got:\n\(text)")
    }

    func testBuilderAddsDefaultClaimsIssueAndRedactedFallbackWithoutSource() throws {
        var card = try JSONDecoder().decode(OuroWorkCard.self, from: Data(sampleWorkCardJSON.utf8))
        card.degraded.issues = []
        card.claims.unavailableReason = nil
        card.nextAction.source = nil

        let snapshot = WorkbenchVisibilityBuilder().build(
            state: WorkspaceState(boss: BossAgentSelection(agentName: "slugger")),
            workCard: .degraded(card),
            now: now
        )

        XCTAssertEqual(snapshot.readiness.issues.first?.code, "claims_unavailable")
        XCTAssertEqual(snapshot.readiness.issues.first?.detail, "Claim verification is not yet wired into the Work Card.")
        XCTAssertEqual(snapshot.agentWork.nextAction.summary, "Review redacted Work Card next action.")
    }

    func testDefaultWorkCardRunnerCapturesOutputTruncatesAndTimesOut() throws {
        let success = try OuroWorkCardReader.defaultRunner(
            executable: "/bin/sh",
            arguments: ["-c", "printf ok; yes e | head -c 70000 >&2"],
            timeout: 2
        )

        XCTAssertEqual(success.exitCode, 0)
        XCTAssertEqual(success.stdout, "ok")
        XCTAssertTrue(success.stderr.contains("[output truncated]"))

        let timedOut = try OuroWorkCardReader.defaultRunner(
            executable: "/bin/sh",
            arguments: ["-c", "echo busy >&2; trap '' TERM; while true; do :; done"],
            timeout: 0.05
        )

        XCTAssertEqual(timedOut.exitCode, 124)
        XCTAssertTrue(timedOut.stderr.contains("busy"))

        let timedOutWithoutStderr = try OuroWorkCardReader.defaultRunner(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while true; do :; done"],
            timeout: 0.05
        )

        XCTAssertEqual(timedOutWithoutStderr.exitCode, 124)
        XCTAssertEqual(timedOutWithoutStderr.stderr, "ouro work card timed out.")
    }

    func testProcessOutputBufferCoversPartialChunkTruncationAndInvalidUTF8() {
        let partial = ProcessOutputBuffer(limit: 5)
        partial.append(Data("abc".utf8))
        partial.append(Data("defgh".utf8))
        XCTAssertEqual(partial.string, "abcde\n[output truncated]")

        let invalid = ProcessOutputBuffer(limit: 4)
        invalid.append(Data([0xFF, 0xFE]))
        XCTAssertEqual(invalid.string, "")
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

    private var availableWorkCardJSON: String {
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
            "status": "available",
            "issues": []
          },
          "counts": {
            "owed": 3,
            "returnObligations": 2,
            "activePackets": 1,
            "evolutionCases": 0,
            "waitingOnHuman": 0,
            "unverifiedClaims": 4,
            "staleRiskyClaims": 5
          },
          "claims": {
            "available": true,
            "unavailableReason": null,
            "counts": {
              "unverified": 1,
              "partial": 2,
              "failed": 3,
              "unverifiable": 4,
              "staleRisky": 5,
              "verified": 7
            }
          },
          "nextAction": {
            "actor": "agent",
            "summary": "Proceed with the packet.",
            "source": {
              "kind": "ponder_packet",
              "locator": "arc/packets/good.json",
              "freshness": "current",
              "redaction": "none"
            }
          },
          "sources": []
        }
        """
    }
}
