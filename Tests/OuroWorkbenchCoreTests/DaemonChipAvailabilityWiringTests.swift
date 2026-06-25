import XCTest
@testable import OuroWorkbenchCore

/// Durable source-pin assertions for the daemon-chip staleness fix (same honesty
/// family as the readiness / registration / MCP-pill false-greens). The App target
/// isn't coverage-gated and can't be click-tested in CI, so — exactly like
/// `BossMCPPillVerdictWiringTests` / `ColdStartHonestWiringTests` — we pin the
/// structural wiring in source.
///
/// THE BUG: the boss dashboard's `daemon` and `mode` chips rendered through the
/// INERT `MetricChip`, while every sibling metric in the same strip routes through
/// the availability-gated `MetricStateChip`. Both daemon values come from
/// `/api/machine`'s self-report (`dashboard.daemonStatus` / `dashboard.daemonMode`),
/// which the machine read gates with `availability.machineAvailable`. So between a
/// daemon dropping and the next periodic refresh, these two chips showed the
/// LAST-KNOWN string ("running" / a mode) with NO unavailable affordance — a stale
/// signal presented as current.
///
/// THE FIX: route BOTH daemon chips through `MetricStateChip`, gated on the SAME
/// `availability.machineAvailable` flag the machine-sourced read already exposes
/// (mirroring how the sibling count metrics pass `availability.codingAvailable`
/// etc.). When the machine read genuinely fails/is stale the chip collapses to the
/// honest muted-dash "unavailable" state; a healthy read still shows the real status.
final class DaemonChipAvailabilityWiringTests: XCTestCase {

    // MARK: - Core: the string resolver keeps a HEALTHY daemon honest (inverse-bug lock)

    /// The pure resolver the daemon chips use: when the machine read SUCCEEDED
    /// (`isAvailable == true`) the running daemon's status passes through verbatim —
    /// the inverse-bug guard so a healthy daemon never reads "unavailable".
    func testDaemonStatusPassesThroughWhenMachineAvailable() {
        let presentation = MetricValuePresentation.resolve(
            text: "running",
            isAvailable: true,
            issue: nil
        )
        XCTAssertEqual(presentation.text, "running", "a healthy daemon still shows its real status string")
        XCTAssertFalse(presentation.isUnavailable, "an available machine read is NOT the unavailable state")
    }

    /// When the machine read FAILED (`isAvailable == false`) the chip must collapse to
    /// the honest not-a-value state — never the stale last-known string — and surface
    /// the machine issue as its reason.
    func testDaemonStatusCollapsesToUnavailableWhenMachineUnavailable() {
        let presentation = MetricValuePresentation.resolve(
            text: "running", // the STALE last-known value must NOT survive
            isAvailable: false,
            issue: "machine: connection refused"
        )
        XCTAssertEqual(
            presentation.text, MetricValuePresentation.unavailableText,
            "a failed machine read must show the muted dash, not the stale 'running' string"
        )
        XCTAssertTrue(presentation.isUnavailable, "a failed machine read is the unavailable state")
        XCTAssertTrue(
            presentation.reason.contains("machine: connection refused"),
            "the unavailable chip surfaces the specific machine issue, got '\(presentation.reason)'"
        )
        XCTAssertTrue(presentation.canRetry, "the unavailable daemon chip offers a one-click retry like its siblings")
    }

    /// `machineAvailable` IS the gate the fix relies on, and BOTH daemon values are
    /// sourced from the same machine read it tracks — so gating the chips on it can
    /// never disagree with the daemon values themselves. Pin that the dashboard
    /// builder leaves the "unknown" sentinel when the machine read is absent AND that
    /// `availability.machineAvailable` reflects the machine issue.
    func testMachineAvailabilityGatesTheSameReadAsTheDaemonValues() {
        // No machine read → daemon values fall back to the "unknown" sentinel AND
        // machineAvailable is false: the chip's gate and value agree.
        let down = BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "boss"),
            machine: nil,
            needsMe: nil,
            coding: nil,
            availability: BossDashboardAvailability.mailbox(
                machineIssue: "machine: connection refused",
                needsMeIssue: nil,
                codingIssue: nil,
                habitHistoryIssue: nil
            )
        )
        XCTAssertFalse(
            down.availability.machineAvailable,
            "a failed machine read makes machineAvailable false — the gate the daemon chips read"
        )
        XCTAssertTrue(
            down.availability.issues.contains(where: { $0.hasPrefix("machine:") }),
            "the machine issue is label-prefixed 'machine:' so issue(prefix: \"machine:\") finds it"
        )
    }

    // MARK: - App: BOTH daemon chips render via MetricStateChip gated on machineAvailable

    /// Source-pin: inside `DashboardMetricsStrip`, the `daemon` chip must render via
    /// the availability-gated `MetricStateChip` (NOT the inert `MetricChip`), folding
    /// `dashboard.daemonStatus` through `MetricValuePresentation.resolve(text:...)`
    /// gated on `availability.machineAvailable` — exactly like its sibling metrics.
    func testDaemonStatusChipRoutesThroughMetricStateChipGatedOnMachineAvailable() throws {
        let body = try strippedStrip()
        XCTAssertFalse(
            body.contains("MetricChip( label: \"daemon\"") || body.contains("MetricChip(label: \"daemon\""),
            "the daemon chip must NOT render via the inert MetricChip — that's the stale-signal bug"
        )
        // The chunk owning the daemon chip: from its constructor up to the next chip
        // (`label: "needs me"`) — so a SIBLING chip's wiring can't satisfy it.
        let daemonChip = try chipChunk(in: body, label: "\"daemon\"", nextLabel: "\"needs me\"")
        XCTAssertTrue(
            daemonChip.contains("MetricStateChip("),
            "the daemon chip must render via MetricStateChip like its siblings"
        )
        XCTAssertTrue(
            daemonChip.contains("dashboard.daemonStatus"),
            "the daemon chip must still source its value from dashboard.daemonStatus"
        )
        XCTAssertTrue(
            daemonChip.contains("availability.machineAvailable"),
            "the daemon chip must gate on availability.machineAvailable — the same machine read that produced daemonStatus"
        )
    }

    /// Source-pin: the `mode` chip must likewise render via `MetricStateChip` gated on
    /// `availability.machineAvailable`, folding `dashboard.daemonMode`.
    func testDaemonModeChipRoutesThroughMetricStateChipGatedOnMachineAvailable() throws {
        let body = try strippedStrip()
        XCTAssertFalse(
            body.contains("MetricChip( label: \"mode\"") || body.contains("MetricChip(label: \"mode\""),
            "the mode chip must NOT render via the inert MetricChip — that's the stale-signal bug"
        )
        // The mode chip is the last in the strip — from its constructor to the end.
        let modeChip = try chipChunk(in: body, label: "\"mode\"", nextLabel: nil)
        XCTAssertTrue(
            modeChip.contains("MetricStateChip("),
            "the mode chip must render via MetricStateChip like its siblings"
        )
        XCTAssertTrue(
            modeChip.contains("dashboard.daemonMode"),
            "the mode chip must still source its value from dashboard.daemonMode"
        )
        XCTAssertTrue(
            modeChip.contains("availability.machineAvailable"),
            "the mode chip must gate on availability.machineAvailable — the same machine read that produced daemonMode"
        )
    }

    /// Source-pin: BOTH daemon chips must fold their value through the STRING resolver
    /// `MetricValuePresentation.resolve(text:` — the daemon values are strings, not the
    /// integer counts the sibling chips use.
    func testDaemonChipsUseTheStringPresentationResolver() throws {
        let body = try strippedStrip()
        let resolverCount = body.components(separatedBy: "MetricValuePresentation.resolve( text:").count - 1
        XCTAssertGreaterThanOrEqual(
            resolverCount, 2,
            "both daemon chips must fold their string value through MetricValuePresentation.resolve(text:...)"
        )
    }

    // MARK: - helpers (mirror BossMCPPillVerdictWiringTests)

    /// The `DashboardMetricsStrip` body with runs of whitespace collapsed to single
    /// spaces, so the assertions are robust to the concurrent-session reformatting of
    /// `OuroWorkbenchApp.swift` (indentation / line-break churn) the task warns about.
    private func strippedStrip() throws -> String {
        let body = try WorkbenchAppSource.sourceSlice(
            from: "struct DashboardMetricsStrip: View {",
            to: "struct MetricStateChip: View {"
        )
        return body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Narrow the (whitespace-normalized) strip to the chunk that renders a single
    /// labelled chip — from the chip-constructor call (`*Chip(`) that immediately
    /// precedes the chip's `label: "<x>"`, up to the next chip's label (or the end of
    /// the strip). Anchoring at the preceding constructor (not the label) means the
    /// chunk OWNS its own `MetricStateChip(` opening, so the assertion can't be
    /// satisfied by a SIBLING chip's constructor.
    private func chipChunk(in body: String, label: String, nextLabel: String?) throws -> String {
        let labelStart = try XCTUnwrap(body.range(of: label)?.lowerBound, "chip label \(label) not found")
        // Walk back to the nearest chip-constructor opening before this label. Prefer
        // the longest match (`MetricStateChip(`) so the chunk owns its full constructor
        // name, falling back to the inert `MetricChip(` when that's what's wired.
        let stateCtor = body.range(of: "MetricStateChip(", options: .backwards, range: body.startIndex..<labelStart)?.lowerBound
        let inertCtor = body.range(of: "MetricChip(", options: .backwards, range: body.startIndex..<labelStart)?.lowerBound
        let ctorStart = try XCTUnwrap(
            [stateCtor, inertCtor].compactMap { $0 }.max(),
            "no chip constructor precedes label \(label)"
        )
        guard let nextLabel,
              let end = body.range(of: nextLabel, range: labelStart..<body.endIndex)?.lowerBound else {
            return String(body[ctorStart..<body.endIndex])
        }
        return String(body[ctorStart..<end])
    }
}
