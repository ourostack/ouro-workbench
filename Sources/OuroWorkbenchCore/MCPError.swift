import Foundation

/// F10a Core seam 2: the JSON-RPC protocol-error vocabulary for the Workbench
/// MCP server, as a pure, framework-free `LocalizedError`.
///
/// Two jobs:
///  1. `errorDescription` is never opaque — every case names its salient detail
///     so a client surfaces something actionable instead of a bare code.
///  2. `jsonRPCError` maps a case onto its canonical JSON-RPC `(code, message)`
///     — except `.toolFailure`, which by MCP convention is reported as a
///     `tools/call` result with `isError: true` (so the *model* sees it), NOT a
///     protocol-level error. Hence `.toolFailure` returns `nil`, and the wiring
///     routes it to `toolResult(...)` rather than `error(...)`.
///
/// `MCPToolFailure` (in the MCP target) is kept as the throw type for the many
/// existing tool-handler throw sites so they don't churn; this enum is the
/// dispatch-chokepoint vocabulary the wiring maps those into.
public enum MCPError: Error, Equatable, Sendable, LocalizedError {
    /// The line wasn't a single JSON-RPC object (JSON-RPC `-32700`).
    case parseError(detail: String)
    /// The dispatched method has no handler (JSON-RPC `-32601`).
    case methodNotFound(method: String)
    /// A request's params were structurally wrong (JSON-RPC `-32602`).
    case invalidParams(detail: String)
    /// A request with this envelope `id` is still running; the duplicate is
    /// rejected rather than double-executed. Surfaced on the JSON-RPC internal
    /// band (`-32603`) — it is a server-side condition, not a malformed request.
    case duplicateInFlight(id: String)
    /// A tool's own failure. NOT a protocol error — surfaced as an
    /// `isError: true` tools/call result, so `jsonRPCError` is `nil`.
    case toolFailure(message: String)
    /// An internal server fault, e.g. a response that couldn't be serialized
    /// (JSON-RPC `-32603`).
    case internalError(detail: String)

    public var errorDescription: String? {
        switch self {
        case let .parseError(detail):
            return "Parse error: \(detail)"
        case let .methodNotFound(method):
            return "Unknown method: \(method)"
        case let .invalidParams(detail):
            return "Invalid params: \(detail)"
        case let .duplicateInFlight(id):
            return "Duplicate request \(id) is already in flight"
        case let .toolFailure(message):
            return message
        case let .internalError(detail):
            return "Internal error: \(detail)"
        }
    }

    /// The canonical JSON-RPC `(code, message)` for this error, or `nil` for
    /// `.toolFailure` (which is surfaced as an `isError` tools/call result, not
    /// a protocol-level error). The message reuses `errorDescription` so the
    /// salient detail rides along verbatim.
    public var jsonRPCError: (code: Int, message: String)? {
        switch self {
        case .parseError:
            return (-32700, errorDescription ?? "Parse error")
        case .methodNotFound:
            return (-32601, errorDescription ?? "Unknown method")
        case .invalidParams:
            return (-32602, errorDescription ?? "Invalid params")
        case .duplicateInFlight:
            return (-32603, errorDescription ?? "Duplicate request in flight")
        case .toolFailure:
            return nil
        case .internalError:
            return (-32603, errorDescription ?? "Internal error")
        }
    }
}
