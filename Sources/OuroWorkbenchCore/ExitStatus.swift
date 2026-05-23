import Foundation

public struct ProcessExitStatus: Equatable, Sendable {
    public var rawWaitStatus: Int32?
    public var exitCode: Int32?

    public init(rawWaitStatus: Int32?) {
        self.rawWaitStatus = rawWaitStatus
        if let rawWaitStatus {
            self.exitCode = Self.decodeExitCode(rawWaitStatus)
        } else {
            self.exitCode = nil
        }
    }

    private static func decodeExitCode(_ rawWaitStatus: Int32) -> Int32? {
        let signalMask: Int32 = 0x7f
        let signal = rawWaitStatus & signalMask
        guard signal == 0 else {
            return nil
        }
        return (rawWaitStatus >> 8) & 0xff
    }
}
