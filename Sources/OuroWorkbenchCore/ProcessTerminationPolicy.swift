import Foundation

public struct ProcessTerminationPolicy: Sendable {
    public init() {}

    public func statusAfterTermination(
        recoveryAction: RecoveryAction?,
        manuallyTerminated: Bool
    ) -> ProcessStatus {
        if !manuallyTerminated && (recoveryAction == .autoResume || recoveryAction == .respawn) {
            return .manualActionNeeded
        }
        return .exited
    }
}
