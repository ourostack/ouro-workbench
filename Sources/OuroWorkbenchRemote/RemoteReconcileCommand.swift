import Foundation
import OuroWorkbenchCore

func remoteRunReconcile(_ context: RemoteHelperContext) throws {
    let configPath = try context.path("config", environment: "OURO_REMOTE_CONFIG")
    let rootURL = URL(fileURLWithPath: try context.path("root", environment: "OURO_HERDR_ROOT"), isDirectory: true)
    guard rootURL.lastPathComponent == "herdr" else {
        throw RemoteControlError.guardian("reconcile root must be the exact Herdr config directory")
    }
    let ledgerURL = URL(fileURLWithPath: try context.path("ledger", environment: "OURO_LEDGER_ROOT"), isDirectory: true)
    let registry = try remoteLoadRegistry(configPath: configPath)
    let ledger = try RemoteResumeLedgerFactory.make(
        ledgerRootURL: ledgerURL,
        herdrRootURL: rootURL,
        registry: registry,
        inheritedEnvironment: context.environment
    )
    let attemptID = try context.value("attempt")
    try ledger.reconcile(attemptID: attemptID, resolution: .abandon)
    try remoteWriteJSON(["attempt": attemptID, "result": "abandoned"])
}
