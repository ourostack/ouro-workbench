import Darwin
import Foundation
import OuroWorkbenchCore

let rawExecutable = CommandLine.arguments[0]
let executableURL = URL(fileURLWithPath: rawExecutable).resolvingSymlinksInPath().standardizedFileURL
let invokedName = URL(fileURLWithPath: rawExecutable).lastPathComponent
let environment = ProcessInfo.processInfo.environment
let workingDirectory = FileManager.default.currentDirectoryPath

do {
    if invokedName == "gh" || invokedName == "git" {
        try remoteRunShim(
            named: invokedName,
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: environment,
            workingDirectory: workingDirectory,
            helperPath: executableURL.path
        )
    }
    let invocation = try RemoteHelperInvocation.parse(Array(CommandLine.arguments.dropFirst()))
    let context = RemoteHelperContext(
        invocation: invocation,
        environment: environment,
        workingDirectory: workingDirectory,
        helperPath: executableURL.path
    )
    switch invocation.command {
    case .help:
        printRemoteHelp()
    case .version:
        print("OuroWorkbenchRemote 0.1.0")
    case .launch, .dispatch, .resume:
        try remoteRunManagedCommand(context)
    case .reconcile:
        try remoteRunReconcile(context)
    case .snapshot:
        try remoteRunSnapshot(context, acknowledgeEmpty: false)
    case .acknowledgeEmpty:
        try remoteRunSnapshot(context, acknowledgeEmpty: true)
    case .sessionMapHook:
        try remoteRunSessionMapHook(context)
    case .guardian:
        try remoteRunGuardian(context)
    case .observe:
        try remoteRunObserve(context)
    case .doctor:
        try remoteRunDoctor(context)
    case .package:
        try remoteRunPackage(context)
    case .install:
        try remoteRunInstall(context)
    case .rollback:
        try remoteRunRollback(context)
    case .shellBootstrap:
        try remoteRunShellBootstrap(context)
    case .wrapperHandshake:
        try remoteRunWrapperHandshake(context)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(remoteSafeError(error))\n".utf8))
    Darwin.exit(error is RemoteControlError ? RemoteHelperExit.runtimeFailure.rawValue : RemoteHelperExit.software.rawValue)
}

private func remoteSafeError(_ error: Error) -> String {
    if let control = error as? RemoteControlError { return control.localizedDescription }
    return "unexpected remote helper failure"
}

private func printRemoteHelp() {
    print("""
    OuroWorkbenchRemote — hardened Copilot and Herdr mobile control-plane helper

    Commands:
      launch            Start Copilot with one selected profile's managed credentials
      dispatch          Dispatch the Herdr shell's copilot command safely
      resume            Resume one exact native Copilot UUID under supervision
      reconcile         Abandon one ambiguous attempt after exact live-absence proof
      snapshot          Atomically capture a healthy non-empty last-known-good generation
      acknowledge-empty Capture an intentional empty fleet for one exact active generation
      session-map-hook  Join Copilot SessionStart evidence to the durable profile map
      guardian          Restore or verify the managed Herdr generation; add --fresh-sessions to replace dead workers without Copilot history
      observe           Record bounded read-only health evidence
      doctor            Print source-specific health; add --json for machine output
      package           Package this exact executable from the current clean Git root
      install           Verify and install a checksummed runtime artifact
      rollback          Roll back one provenance-owned runtime revision
      shell-bootstrap   Build the isolated Herdr ZDOTDIR

    Account guardrail:
      Profiles scrub ambient credentials and managed gh/git shims reject known cross-account targets. Copilot runs with --allow-all, so this reduces accidental account mixing but is not a sandbox against deliberate host-level bypass.
    """)
}
