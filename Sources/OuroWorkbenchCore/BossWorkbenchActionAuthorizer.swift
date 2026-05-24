import Foundation

public struct BossWorkbenchActionAuthorization: Equatable, Sendable {
    public var isAllowed: Bool
    public var reason: String?

    public static func allowed() -> BossWorkbenchActionAuthorization {
        BossWorkbenchActionAuthorization(isAllowed: true, reason: nil)
    }

    public static func denied(_ reason: String) -> BossWorkbenchActionAuthorization {
        BossWorkbenchActionAuthorization(isAllowed: false, reason: reason)
    }
}

public struct BossWorkbenchActionAuthorizer: Sendable {
    public init() {}

    public func authorize(_ action: BossWorkbenchAction, for entry: ProcessEntry) -> BossWorkbenchActionAuthorization {
        guard !entry.isArchived else {
            return .denied("entry is archived")
        }
        guard entry.trust == .trusted else {
            return .denied("entry is untrusted")
        }
        return .allowed()
    }
}
