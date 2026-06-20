#if os(macOS)
import Darwin
import Foundation
import OuroWorkbenchCore
import SwiftUI

/// Tiny cross-thread value holder for the `--onboarding-doctor` async boss check-in. The write
/// happens-before the semaphore signal and the read happens-after the wait, so there is no race.
private final class DoctorBox: @unchecked Sendable { var value = "(no result)" }

private func parseLaunchDiagnostics() -> WorkbenchLaunchDiagnostics {
    do {
        return try WorkbenchLaunchDiagnostics.parse(CommandLine.arguments)
    } catch {
        FileHandle.standardError.write(Data("Invalid Workbench launch arguments: \(error.localizedDescription)\n".utf8))
        Darwin.exit(2)
    }
}

let workbenchLaunchDiagnostics = parseLaunchDiagnostics()

if CommandLine.arguments.contains("--smoke-launch") {
    let swiftTermBundleURL = Bundle.main.resourceURL?
        .appendingPathComponent("SwiftTerm_SwiftTerm.bundle", isDirectory: true)
    guard let swiftTermBundleURL, FileManager.default.fileExists(atPath: swiftTermBundleURL.path) else {
        let resourcePath = Bundle.main.resourceURL?.path ?? "<missing resource directory>"
        FileHandle.standardError.write(Data("Missing SwiftTerm resource bundle under \(resourcePath)\n".utf8))
        Darwin.exit(1)
    }

    FileHandle.standardOutput.write(Data("OuroWorkbench smoke launch ok\n".utf8))
    Darwin.exit(0)
}

if workbenchLaunchDiagnostics.action == .factoryResetForE2E {
    let paths = WorkbenchPaths(rootURL: workbenchLaunchDiagnostics.appSupportRoot!)
    let defaultsDomain = "com.ourostack.workbench.e2e"
    let defaults = UserDefaults(suiteName: defaultsDomain) ?? .standard
    let result = WorkbenchFactoryReset.resetToFactoryDefaults(
        stateURL: paths.stateURL,
        defaults: defaults,
        defaultsDomain: defaultsDomain,
        timestamp: Date()
    )
    defaults.synchronize()
    let backup = result.backupURL?.path ?? "<none>"
    FileHandle.standardOutput.write(Data("factory reset ok\nbackup=\(backup)\nmarker=\(result.setupMarkerURL.path)\n".utf8))
    Darwin.exit(0)
}

if case let .dumpRecentSessions(scanHomeRoot) = workbenchLaunchDiagnostics.action {
    let scanner = RecentSessionScanner(homeURL: scanHomeRoot ?? FileManager.default.homeDirectoryForCurrentUser)
    let candidates = scanner.scan()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(candidates)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        Darwin.exit(0)
    } catch {
        FileHandle.standardError.write(Data("Failed to encode recent sessions: \(error.localizedDescription)\n".utf8))
        Darwin.exit(1)
    }
}

if case let .writeE2EState(fixture, stateURL) = workbenchLaunchDiagnostics.action {
    do {
        switch fixture {
        case .sidebarSessionControls:
            let rootPath = FileManager.default.homeDirectoryForCurrentUser.path
            let project = WorkbenchProject(name: "Fixture Workspace", rootPath: rootPath)
            let entry = ProcessEntry(
                projectId: project.id,
                name: "Fixture Running Session",
                kind: .terminalAgent,
                agentKind: .openAICodex,
                executable: "/bin/zsh",
                arguments: ["-lc", "while true; do sleep 60; done"],
                workingDirectory: rootPath,
                trust: .trusted,
                autoResume: true,
                lastSummary: "Fixture running session"
            )
            let state = WorkspaceState(
                selectedProjectId: project.id,
                selectedEntryId: entry.id,
                projects: [project],
                processEntries: [entry]
            )
            try WorkbenchStore(stateURL: stateURL).save(state)
        }
        FileHandle.standardOutput.write(Data("wrote e2e state \(stateURL.path)\n".utf8))
        Darwin.exit(0)
    } catch {
        FileHandle.standardError.write(Data("Failed to write e2e state: \(error.localizedDescription)\n".utf8))
        Darwin.exit(1)
    }
}

// Headless onboarding readiness doctor. Runs the REAL launch-time PATH capture
// (`WorkbenchViewModel.readLoginShellPath`) + the REAL provider-check command with the REAL
// `TerminalEnvironment().valuesWithResolvedPath()` — the exact code the wizard uses — and prints a
// verdict. Launch it from a MINIMAL environment (`env -i HOME=… SHELL=/bin/zsh PATH=/usr/bin:/bin
// "<app>" --onboarding-doctor --agent ouroboros`) to faithfully reproduce a Finder launch, where
// the interactive-vs-non-interactive login-shell distinction actually matters. Exists so the
// provider-check path — historically untested and the source of the multi-week "can't get past
// connect" bug — can be driven and verified without clicking the native GUI.
if CommandLine.arguments.contains("--onboarding-doctor") {
    func emit(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    func resolves(_ path: String, _ tool: String) -> Bool {
        for dir in path.split(separator: ":") {
            if FileManager.default.isExecutableFile(atPath: "\(dir)/\(tool)") { return true }
        }
        return false
    }
    var agent = "ouroboros"
    if let i = CommandLine.arguments.firstIndex(of: "--agent"), i + 1 < CommandLine.arguments.count {
        agent = CommandLine.arguments[i + 1]
    }

    emit("=== ONBOARDING DOCTOR (agent: \(agent)) ===")
    emit("inherited SHELL: \(ProcessInfo.processInfo.environment["SHELL"] ?? "(unset)")")
    emit("inherited PATH : \(ProcessInfo.processInfo.environment["PATH"] ?? "(unset)")")

    // 1) The REAL launch-time capture.
    let capStart = Date()
    let captured = WorkbenchViewModel.readLoginShellPath()
    let capSecs = Int(Date().timeIntervalSince(capStart).rounded())
    if let captured, !captured.isEmpty {
        TerminalEnvironment.loginShellPath = captured
        let hasOuro = resolves(captured, "ouro")
        let hasNode = resolves(captured, "node")
        emit("[1] login-shell PATH captured in \(capSecs)s — resolves ouro: \(hasOuro), node: \(hasNode)")
        if !hasOuro || !hasNode { emit("    ✗ CAPTURE INCOMPLETE — ouro/node missing means every check will fail") }
    } else {
        emit("[1] ✗ login-shell PATH capture returned nil (falls back to synthesized PATH)")
    }

    // 2) The PATH the checks will actually run with.
    let resolved = TerminalEnvironment().valuesWithResolvedPath()["PATH"] ?? ""
    emit("[2] resolved check PATH — resolves ouro: \(resolves(resolved, "ouro")), node: \(resolves(resolved, "node"))")

    // 3) The REAL check command, serially, exactly as the wizard now runs them.
    var providerChecks: [String: OnboardingProviderCheckResult] = [:]
    for lane in ["outward", "inner"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro", "check", "--agent", agent, "--lane", lane]
        process.environment = TerminalEnvironment().valuesWithResolvedPath()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let start = Date()
        var exit: Int32 = -1
        var tail = ""
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            exit = process.terminationStatus
            let out = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}[", with: "")
            tail = out.split(separator: "\n").last.map(String.init) ?? ""
        } catch {
            tail = "spawn error: \(error.localizedDescription)"
        }
        let secs = Int(Date().timeIntervalSince(start).rounded())
        let ok = exit == 0
        providerChecks[lane] = OnboardingProviderCheckResult(lane: lane, state: ok ? .passed : .failed, detail: tail)
        emit("[3] check \(lane): exit=\(exit) [\(secs)s] \(ok ? "✓" : "✗") \(tail.prefix(80))")
    }

    // 4) The REAL readiness computation — does the wizard actually advance?
    let boss = BossAgentSelection(agentName: agent)
    let agents = OuroAgentInventory().scan()
    let mcp = BossWorkbenchMCPRegistrar().snapshot(for: boss)
    let readiness = WorkbenchOnboardingAdvisor().readiness(
        boss: boss,
        agents: agents,
        mcpRegistration: mcp,
        providerChecks: providerChecks,
        daemonLiveness: .up
    )
    emit("[4] agents on disk: \(agents.map(\.name).sorted().joined(separator: ", "))")
    emit("[4] MCP registration: \(String(describing: mcp.status)) — binary: \(BossWorkbenchMCPRegistrar.defaultMCPExecutableURL().path)")
    emit("[4] readiness.isReady=\(readiness.isReady) state=\(String(describing: readiness.state))")
    if !readiness.isReady {
        emit("    BLOCKERS the wizard would show:")
        for step in readiness.repairSteps {
            emit("      - [\(step.id)] \(step.title): \(step.detail)")
        }
    }

    // 5) Boss check-in — does the boss actually RESPOND? (the "ouroboros didn't answer" symptom,
    //    and the prerequisite for the reconstruction hand-off). Spawned exactly as the wizard does:
    //    `ouro mcp-serve --agent <boss> --workbench-mcp <installed-binary>` so the boss has the
    //    discover/propose/create tools at runtime.
    emit("[5] boss check-in (status round-trip, Workbench MCP injected)…")
    let bossStart = Date()
    let bossSem = DispatchSemaphore(value: 0)
    let bossResult = DoctorBox()
    Task.detached {
        do {
            let client = BossAgentMCPClient(
                timeoutNanoseconds: 60_000_000_000,
                workbenchMCPPath: BossWorkbenchMCPRegistrar.defaultMCPExecutableURL().path
            )
            let s = try await client.status(agentName: agent)
            bossResult.value = "✓ responded: \(s.replacingOccurrences(of: "\n", with: " ").prefix(120))"
        } catch {
            bossResult.value = "✗ \(error)"
        }
        bossSem.signal()
    }
    bossSem.wait()
    emit("[5] [\(Int(Date().timeIntervalSince(bossStart).rounded()))s] \(bossResult.value)")

    let bossOK = bossResult.value.hasPrefix("✓")
    emit(readiness.isReady && bossOK
         ? "=== VERDICT: WIZARD WORKS ✓ (ready → boss responds → reconstruction) ==="
         : readiness.isReady
           ? "=== VERDICT: connect ADVANCES ✓ but boss check-in failed ✗ (reconstruction would stall) ==="
           : "=== VERDICT: WIZARD BLOCKED ✗ ===")
    Darwin.exit(readiness.isReady && bossOK ? 0 : 1)
}

OuroWorkbenchApp.main()
#endif
