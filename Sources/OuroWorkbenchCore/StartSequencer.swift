import Foundation

/// F11a Defect 2 — the typed step a (re)start should take, given whether a local
/// session is already live on the entry's `screen` socket.
public enum StartSequenceStep: Equatable, Sendable {
    /// A session is live on the socket: issue `screen -X quit` for `sessionName`
    /// and AWAIT it to completion before the relaunch, so the `-D -RR` never
    /// races the quit (yanked-mid-attach / `-RR` forks a fresh daemon and loses
    /// scrollback).
    case quitThenAwait(sessionName: String)
    /// Nothing is on the socket: there's no quit to await, launch immediately.
    case launchImmediately
}

/// Decides the start step for an entry. Pure; the App consults it before
/// tearing down/launching a `TerminalSessionController`.
public struct StartSequencer: Sendable {
    public init() {}

    public func step(
        forEntryId entryId: UUID,
        hasActiveSessionOnSocket: Bool
    ) -> StartSequenceStep {
        guard hasActiveSessionOnSocket else {
            return .launchImmediately
        }
        return .quitThenAwait(sessionName: PersistentTerminalSession.sessionName(for: entryId))
    }
}
