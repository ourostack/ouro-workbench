import Foundation

/// Returns the first result a throwing task group produces, or throws the given
/// error if the group completes without yielding one.
///
/// Extracted so the "group finished without a value" branch — otherwise
/// unreachable while the group always holds at least one task — is exercised in
/// isolation by feeding an empty group.
func firstTaskResult<R: Sendable>(
    of group: inout ThrowingTaskGroup<R, any Error>,
    orThrow error: any Error
) async throws -> R {
    guard let result = try await group.next() else {
        throw error
    }
    return result
}
