import XCTest
@testable import OuroWorkbenchCore

/// Live-aware agent-row readiness seam. The steady-state sidebar / "Installed agents"
/// rows used to render the scanner's CONFIG-ONLY `.ready` (agent.json present & enabled)
/// as a green "ready" dot + tooltip — a false green, because no live `ouro check` ever
/// ran. This pure seam folds the scanner status together with a live
/// `ProviderConnectionVerdict?` (from `runColdStartProviderCheck`) and an in-flight flag
/// into a single honest `LiveReadiness`, and never shows green unless the live check
/// actually returned `.working`.
///
/// HONESTY INVARIANTS pinned below:
///  (a) `dotColor(for:) == .green` IFF `r == .ready` IFF the only producing input is
///      `verdict == .working`.
///  (b) config-only `.ready` + `verdict == nil` + `isChecking == false` → `.unverified`
///      (NOT `.ready`, NOT green).
///  (c) config-only `.ready` + `verdict == nil` + `isChecking == true` → `.checking`
///      (NOT green).
final class LiveAgentReadinessPresentationTests: XCTestCase {

    private typealias P = InstalledAgentRowPresentation
    private typealias R = InstalledAgentRowPresentation.LiveReadiness

    // Every input axis, enumerated, so the truth table below is provably exhaustive.
    private let allStatuses: [OuroAgentBundleStatus] = [
        .ready, .disabled, .missingConfig, .invalidConfig,
    ]
    private let allVerdicts: [ProviderConnectionVerdict?] = [
        nil, .working, .unauthorized, .vaultLocked, .unreachable, .indeterminate,
    ]
    private let allChecking: [Bool] = [false, true]

    /// The single source of truth for the EXPECTED resolution — mirrors the documented
    /// order so the test asserts the rule, not the implementation's own restatement.
    private func expected(
        status: OuroAgentBundleStatus,
        verdict: ProviderConnectionVerdict?,
        isChecking: Bool
    ) -> R {
        // 1. Config problems dominate (verdict / isChecking are irrelevant).
        switch status {
        case .disabled: return .disabled
        case .missingConfig: return .missingConfig
        case .invalidConfig: return .invalidConfig
        case .ready: break
        }
        // 2. A live verdict, if we have one, decides.
        if let verdict {
            switch verdict {
            case .working: return .ready
            case .unauthorized: return .authExpired
            case .vaultLocked: return .vaultLocked
            case .unreachable: return .unreachable
            case .indeterminate: return .unverified
            }
        }
        // 3. No verdict yet but a check is in flight.
        if isChecking { return .checking }
        // 4. No verdict, not checking → unverified (NOT a false green).
        return .unverified
    }

    // MARK: - Exhaustive truth table over (status × verdict × isChecking)

    func testLiveReadinessTruthTable() {
        for status in allStatuses {
            for verdict in allVerdicts {
                for isChecking in allChecking {
                    let got = P.liveReadiness(status: status, verdict: verdict, isChecking: isChecking)
                    let want = expected(status: status, verdict: verdict, isChecking: isChecking)
                    XCTAssertEqual(
                        got, want,
                        "liveReadiness(status: \(status), verdict: \(String(describing: verdict)), isChecking: \(isChecking))"
                    )
                }
            }
        }
    }

    // MARK: - Invariant (a): green IFF .ready IFF only producer is verdict == .working

    func testGreenDotOnlyForReady() {
        for r in [R.ready, .checking, .authExpired, .vaultLocked, .unreachable, .unverified, .disabled, .missingConfig, .invalidConfig] {
            let isGreen = P.dotColor(for: r) == .green
            XCTAssertEqual(isGreen, r == .ready, "only .ready may be green; \(r) was green=\(isGreen)")
        }
    }

    func testReadyIsProducedOnlyByWorkingVerdict() {
        // Sweep every input: a `.ready` LiveReadiness may ONLY come from `verdict == .working`.
        for status in allStatuses {
            for verdict in allVerdicts {
                for isChecking in allChecking {
                    let r = P.liveReadiness(status: status, verdict: verdict, isChecking: isChecking)
                    if r == .ready {
                        XCTAssertEqual(verdict, .working, "only verdict==.working may yield .ready")
                        XCTAssertEqual(status, .ready, ".ready requires config-ready status")
                    }
                }
            }
        }
    }

    // MARK: - Invariant (b) & (c): the false-green cases the bug shipped

    func testConfigReadyButUnverifiedIsNotGreen() {
        // (b) The exact bug: config says ready, no live check has confirmed it, none in flight.
        let r = P.liveReadiness(status: .ready, verdict: nil, isChecking: false)
        XCTAssertEqual(r, .unverified)
        XCTAssertNotEqual(P.dotColor(for: r), .green)
        XCTAssertEqual(P.dotColor(for: r), .orange)
    }

    func testConfigReadyWhileCheckingIsCheckingNotGreen() {
        // (c) A check is in flight: show "checking…", never a premature green.
        let r = P.liveReadiness(status: .ready, verdict: nil, isChecking: true)
        XCTAssertEqual(r, .checking)
        XCTAssertNotEqual(P.dotColor(for: r), .green)
        XCTAssertEqual(P.dotColor(for: r), .orange)
    }

    func testAuthExpiredIsTheSluggerCase() {
        // Ground-truth slugger: `failed (401 … expired)` → .unauthorized → .authExpired, orange.
        let r = P.liveReadiness(status: .ready, verdict: .unauthorized, isChecking: false)
        XCTAssertEqual(r, .authExpired)
        XCTAssertEqual(P.dotColor(for: r), .orange)
    }

    // MARK: - dotColor: only invalidConfig is red; everything non-ready non-red is orange

    func testDotColorPalette() {
        XCTAssertEqual(P.dotColor(for: R.ready), .green)
        XCTAssertEqual(P.dotColor(for: R.invalidConfig), .red)
        for r in [R.checking, .authExpired, .vaultLocked, .unreachable, .unverified, .disabled, .missingConfig] {
            XCTAssertEqual(P.dotColor(for: r), .orange, "\(r) must be orange")
        }
    }

    // MARK: - label: a distinct human word per state

    func testLabels() {
        XCTAssertEqual(P.label(for: .ready), "ready")
        XCTAssertEqual(P.label(for: .checking), "checking…")
        XCTAssertEqual(P.label(for: .authExpired), "sign-in needed")
        XCTAssertEqual(P.label(for: .vaultLocked), "credentials locked")
        XCTAssertEqual(P.label(for: .unreachable), "can't reach provider")
        XCTAssertEqual(P.label(for: .unverified), "not verified")
        XCTAssertEqual(P.label(for: .disabled), "disabled")
        XCTAssertEqual(P.label(for: .missingConfig), "no config")
        XCTAssertEqual(P.label(for: .invalidConfig), "bad config")
    }

    func testLabelsAreAllDistinct() {
        let labels = [R.ready, .checking, .authExpired, .vaultLocked, .unreachable, .unverified, .disabled, .missingConfig, .invalidConfig]
            .map(P.label(for:))
        XCTAssertEqual(Set(labels).count, labels.count, "every state needs a distinct label")
    }

    // MARK: - help: fuller tooltip; invalidConfig embeds the raw detail

    func testHelpForReadyAndChecking() {
        XCTAssertTrue(P.help(for: .ready, detail: "ready").lowercased().contains("ready"))
        XCTAssertTrue(P.help(for: .checking, detail: "ready").lowercased().contains("check"))
    }

    func testHelpForAuthExpiredExplainsSignIn() {
        let help = P.help(for: .authExpired, detail: "ready")
        XCTAssertTrue(help.lowercased().contains("sign in") || help.lowercased().contains("sign-in"), "got: \(help)")
    }

    func testHelpForVaultLockedAndUnreachable() {
        XCTAssertTrue(P.help(for: .vaultLocked, detail: "x").lowercased().contains("credential") || P.help(for: .vaultLocked, detail: "x").lowercased().contains("lock"))
        XCTAssertTrue(P.help(for: .unreachable, detail: "x").lowercased().contains("reach") || P.help(for: .unreachable, detail: "x").lowercased().contains("network"))
    }

    func testHelpForUnverifiedExplainsNoLiveCheck() {
        let help = P.help(for: .unverified, detail: "ready")
        XCTAssertTrue(help.lowercased().contains("verif") || help.lowercased().contains("check"), "got: \(help)")
    }

    func testHelpForDisabledAndMissingConfig() {
        XCTAssertTrue(P.help(for: .disabled, detail: "disabled in agent.json").lowercased().contains("disabled"))
        XCTAssertTrue(P.help(for: .missingConfig, detail: "agent.json missing").lowercased().contains("config") || P.help(for: .missingConfig, detail: "agent.json missing").lowercased().contains("agent.json"))
    }

    func testHelpForInvalidConfigEmbedsDetail() {
        let detail = "The data couldn’t be read because it isn’t in the correct format."
        let help = P.help(for: .invalidConfig, detail: detail)
        XCTAssertTrue(help.contains("isn’t in the correct format"), "invalidConfig help must embed the raw detail; got: \(help)")
    }

    func testHelpForInvalidConfigWithEmptyDetailStillReads() {
        let help = P.help(for: .invalidConfig, detail: "")
        XCTAssertFalse(help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(help.lowercased().contains("config") || help.lowercased().contains("invalid"), "got: \(help)")
    }

    // MARK: - Equatable / Sendable surface (compile-time + cheap runtime check)

    func testLiveReadinessIsEquatable() {
        XCTAssertEqual(R.ready, R.ready)
        XCTAssertNotEqual(R.ready, R.unverified)
    }
}
