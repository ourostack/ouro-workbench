import Foundation

/// The classified outcome of a single `ouro check --agent <name> --lane <lane>` run, derived
/// from the command's OUTPUT — never its exit code.
public enum ProviderConnectionVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    case working, vaultLocked, unauthorized, unreachable, indeterminate
}

/// Stub — replaced by the real implementation in Unit 0b.
public struct ProviderCheckClassifier: Sendable {
    public init() {}

    public func classify(exitCode: Int32, stdout: String, stderr: String) -> ProviderConnectionVerdict {
        .indeterminate
    }
}
