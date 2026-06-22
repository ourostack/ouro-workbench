import Foundation

/// Why a read of the workbench state degraded — the pure classification the MCP
/// `workbench_status` handler consults so a newer-schema state file renders the
/// "upgrade Workbench" advisory as first-class CONTENT (isError:false) rather
/// than an error string.
///
/// Genuine corruption is deliberately NOT folded into a benign advisory: only
/// the schema case (`stateWrittenByNewerWorkbench`) becomes content. A truly
/// unreadable/corrupt file (`stateUnreadable`) is carried here only so a caller
/// CAN describe it, but the wiring keeps it surfacing honestly as an error via
/// the `WorkbenchStoreError: LocalizedError` safety net — masking data-loss as a
/// routine "all good, just upgrade" message would be a lie.
public enum DegradedReadReason: Equatable, Sendable {
    /// The state file's schema is newer than this build understands. Data is
    /// intact; the operator needs a newer Workbench to read it.
    case stateWrittenByNewerWorkbench(foundVersion: Int, supportedVersion: Int)
    /// The state file existed but couldn't be read/decoded. Carries the
    /// underlying reason for an honest message; NOT eligible for content-mode.
    case stateUnreadable(reason: String)

    /// The boss-facing, actionable line describing the degradation.
    public var advisory: String {
        switch self {
        case let .stateWrittenByNewerWorkbench(foundVersion, supportedVersion):
            return "This Workbench state was written by a newer Workbench "
                + "(state schema v\(foundVersion); this build understands "
                + "v\(supportedVersion)). Upgrade Workbench to read it. "
                + "Your data is intact and untouched."
        case let .stateUnreadable(reason):
            return "Workbench couldn't read its state: \(reason)."
        }
    }
}

/// Classify a thrown read error into a `DegradedReadReason`, or `nil` when it is
/// not a degraded-read condition we recognise (so the caller re-throws it and
/// `WorkbenchStoreError`'s `LocalizedError` conformance surfaces it honestly).
///
/// The `nil` arm is load-bearing: a non-`WorkbenchStoreError` must NOT be
/// classified as a degraded read, so genuine failures aren't masked.
public func degradedReadReason(for error: Error) -> DegradedReadReason? {
    guard let storeError = error as? WorkbenchStoreError else { return nil }
    switch storeError {
    case let .unsupportedStateVersion(version):
        return .stateWrittenByNewerWorkbench(
            foundVersion: version,
            supportedVersion: WorkspaceState.currentSchemaVersion
        )
    case let .unreadableState(_, reason):
        return .stateUnreadable(reason: reason)
    }
}
